#!/usr/bin/env bash
# Hook entry point: awake.sh <start|busy|stop|idle|end>, with the hook's JSON on stdin.
#   start  SessionStart      start this session's watcher and print the status line
#   busy   UserPromptSubmit  Claude is working: keep the computer awake
#   stop   Stop              turn finished: let it sleep, unless background tasks are still running
#   idle   Notification      idle_prompt: nothing has happened for ~60s (also covers interrupted turns)
#   wait   Notification      permission_prompt / elicitation_dialog: Claude is waiting for your input
#   sched  PostToolUse       a run was scheduled or cancelled (CronCreate, CronDelete, ScheduleWakeup)
#   end    SessionEnd        stop this session's watcher
# The watcher holds the OS lock only while <base>.busy exists or a scheduled run is due (see sched),
# and exits when Claude exits or
# <base>.pid is removed. Always exits 0, so it can never block Claude.

root="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}"

report() {
  local result="${1:-error: no output}" msg
  if [ "$result" = ok ]; then
    msg="jaagte-raho: on. Keeps this computer awake while Claude is working, lets it sleep when idle"
  else
    msg="jaagte-raho: could not keep this computer awake (${result#error: }). Run /jaagte-raho:status"
  fi
  msg=${msg//[\"\\]/}
  printf '{"systemMessage":"%s"}\n' "$msg"
  exit 0
}

input=$(cat)
sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
sid=${sid//[^A-Za-z0-9_-]/}
. "$root/scripts/lockdir.sh"
if [ -z "$sid" ] || [ -z "$dir" ]; then
  [ "$1" = start ] && report "error: no session id or no private directory for lock files"
  exit 0
fi
base="$dir/jaagte-raho-$sid"

case "$1" in
  busy)
    : > "$base.busy"
    rm -f "$base.wait"
    # The start of the prompt, so /jaagte-raho:status can say what each session is doing.
    # Escaped backslashes and quotes are swapped for control characters while the string is cut out.
    printf '%s' "$input" | sed 's/\\\\/\x02/g; s/\\"/\x01/g' \
      | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 \
      | sed 's/\\[nrt]/ /g; s/\x01/"/g; s/\x02/\\/g; s/[[:space:]]\{1,\}/ /g' | cut -c1-80 > "$base.task"
    exit 0 ;;
  stop)
    # A non-empty background_tasks list means agents or commands are still running.
    printf '%s' "$input" | grep -Eq '"background_tasks"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^][:space:]]' \
      || rm -f "$base.busy"
    rm -f "$base.wait"
    exit 0 ;;
  wait)
    # Claude is waiting for you (a permission prompt or a question). Nothing moves until you answer,
    # so let the computer sleep once the grace period runs out: <base>.wait holds
    # "<since epoch s> <sleep-allowed epoch s> <transcript path>". The watcher drops it once the
    # transcript changes after <since>, i.e. you answered. JAAGTE_RAHO_INPUT_WAIT is the grace period
    # in minutes (default 10); anything that isn't a number (e.g. "never") keeps it awake while waiting.
    mins=${JAAGTE_RAHO_INPUT_WAIT:-10}
    case "$mins" in ''|*[!0-9]*) exit 0 ;; esac
    [ -f "$base.busy" ] || exit 0
    now=$(date +%s)
    path=$(printf '%s' "$input" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 | sed 's/\\\\/\\/g')
    echo "$now $(( now + mins * 60 )) $path" > "$base.wait.tmp" && mv -f "$base.wait.tmp" "$base.wait"
    exit 0 ;;
  sched)
    # PostToolUse for CronCreate / CronDelete / ScheduleWakeup. A sleeping computer skips scheduled
    # runs, so remember until when one is due: <base>.sched holds "<job> <until epoch s>" lines, and
    # <base>.until the latest of them, which the watcher keeps the computer awake until.
    now=$(date +%s)
    resp=$(printf '%s' "$input" | sed 's/.*"tool_response"[[:space:]]*:[[:space:]]*//')
    field() { printf '%s' "$resp" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([A-Za-z0-9_-]*\).*/\1/p" | head -n1; }
    tool=$(printf '%s' "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    grace=900   # keep awake this long past the due time, so the run can start and get going
    key= until=
    case "$tool" in
      ScheduleWakeup)   # a /loop wakeup; each new one replaces the last
        key=wakeup
        [ "$(field stopped)" = true ] || { ms=$(field scheduledFor); [ -n "$ms" ] && until=$(( ms / 1000 + grace )); } ;;
      CronCreate)
        key=$(field id)
        if [ "$(field recurring)" = true ]; then until=$(( now + 7 * 86400 ))   # recurring jobs expire after 7 days
        else ms=$(field nextFireAt); [ -n "$ms" ] && until=$(( ms / 1000 + grace )); fi ;;
      CronDelete)
        key=$(field id)
        [ "$(field endedLoopWakeup)" = true ] && { grep -v '^wakeup ' "$base.sched" > "$base.sched.tmp"; mv -f "$base.sched.tmp" "$base.sched"; } 2>/dev/null ;;
    esac
    key=${key//[^A-Za-z0-9_-]/}
    [ -n "$key" ] || exit 0
    { grep -v "^$key " "$base.sched" 2>/dev/null; [ -n "$until" ] && echo "$key $until"; } \
      | awk -v now="$now" '$2 > now' > "$base.sched.tmp"
    mv -f "$base.sched.tmp" "$base.sched"
    if [ -s "$base.sched" ]; then
      awk '$2 > m { m = $2 } END { print m }' "$base.sched" > "$base.until.tmp" && mv -f "$base.until.tmp" "$base.until"
    else
      rm -f "$base.sched" "$base.until"
    fi
    exit 0 ;;
  idle) rm -f "$base.busy" "$base.wait"; exit 0 ;;
  end) rm -f "$base.busy" "$base.wait" "$base.pid" "$base.cwd" "$base.task" "$base.sched" "$base.until"; exit 0 ;;
  start) ;;
  *) exit 0 ;;
esac

# The folder Claude was started in, so /jaagte-raho:status can name the session.
printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 \
  | sed 's/\\\\/\//g' > "$base.cwd"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    report "$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root/scripts/awake.ps1" -Session "$sid" | tr -d '\r' | tail -n1)" ;;
esac

# Walk up the process tree to the Claude process (native binary "claude", or "node" for npm installs).
# Match on argv[0] as well as comm: on Linux, newer Node renames its main thread, so comm is "MainThread".
pid=$$
while [ "${pid:-0}" -gt 1 ]; do
  comm=$(ps -o comm= -p "$pid")
  argv0=$(ps -o args= -p "$pid"); argv0=${argv0%% *}
  case "${comm##*/} ${argv0##*/}" in claude\ *|node\ *|*\ claude|*\ node) break ;; esac
  pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
done
[ "${pid:-0}" -gt 1 ] || report "error: Claude process not found"

[ -f "$base.pid" ] && kill -0 "$(cat "$base.pid")" 2>/dev/null && report ok

# Check up front that this machine lets us take the lock, so the status line tells the truth.
case "$(uname -s)" in
  Darwin) command -v caffeinate >/dev/null || report "error: caffeinate not found" ;;
  Linux)
    command -v systemd-inhibit >/dev/null || report "error: systemd-inhibit not found"
    systemd-inhibit --what=idle:sleep --who="Claude Code" --why="jaagte-raho self-check" true 2>"$base.log" \
      || report "error: $(head -n1 "$base.log")" ;;
  *) report "error: unsupported OS $(uname -s)" ;;
esac

# No inherited stdio, so Claude doesn't wait on the background watcher before continuing.
nohup bash "$root/scripts/watch.sh" "$base" "$pid" </dev/null >/dev/null 2>"$base.log" &
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$base.pid" ] && report ok; sleep 0.2; done
report "error: watcher did not start"
