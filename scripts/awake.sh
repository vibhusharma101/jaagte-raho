#!/usr/bin/env bash
# Hook entry point: awake.sh <start|busy|stop|idle|end>, with the hook's JSON on stdin.
#   start  SessionStart      start this session's watcher and print the status line
#   busy   UserPromptSubmit  Claude is working: keep the computer awake
#   stop   Stop              turn finished: let it sleep, unless background tasks are still running
#   idle   Notification      idle_prompt: nothing has happened for ~60s (also covers interrupted turns)
#   end    SessionEnd        stop this session's watcher
# The watcher holds the OS lock only while <base>.busy exists, and exits when Claude exits or
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
  busy) : > "$base.busy"; exit 0 ;;
  stop)
    # A non-empty background_tasks list means agents or commands are still running.
    printf '%s' "$input" | grep -Eq '"background_tasks"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^][:space:]]' \
      || rm -f "$base.busy"
    exit 0 ;;
  idle) rm -f "$base.busy"; exit 0 ;;
  end) rm -f "$base.busy" "$base.pid"; exit 0 ;;
  start) ;;
  *) exit 0 ;;
esac

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
