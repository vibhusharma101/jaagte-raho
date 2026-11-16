#!/usr/bin/env bash
# End-to-end check of the session lifecycle. A stand-in "Claude" (a node process) runs the
# SessionStart hook exactly as Claude Code does; the other hooks are fed the same JSON Claude sends.
# The lock must be held only while Claude is working, and everything must clean up on exit.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$root/scripts/awake.sh"
work="$(mktemp -d)"
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

. "$root/scripts/lockdir.sh"
[ -n "$dir" ] || fail "no private directory for lock files"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) win=1; native() { cygpath -w "$1"; } ;;
  *) win=; native() { echo "$1"; } ;;
esac

alive() {
  if [ -n "$win" ]; then tasklist //NH //FI "PID eq $1" 2>/dev/null | grep -q " $1 "
  else kill -0 "$1" 2>/dev/null; fi
}

# What the OS itself reports. Prints SKIP and succeeds when the OS won't tell us (Windows without admin).
os_reports_lock() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      out=$(MSYS_NO_PATHCONV=1 powercfg /requests 2>&1) || { echo "SKIP: powercfg /requests needs admin" >&2; return 2; }
      grep -q jaagte-raho <<< "$out" ;;
    Darwin) pmset -g assertions | grep -qi caffeinate ;;
    Linux) systemd-inhibit --list | grep -qi "claude code" ;;
  esac
}

# wait_for <seconds> <command...>: retry until the command succeeds.
wait_for() {
  local n=$1; shift
  for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 1; done
  return 1
}

hook_event() {  # hook_event <event> <session id> [extra JSON fields]
  printf '{"session_id":"%s","hook_event_name":"x"%s}' "$2" "${3:-}" | CLAUDE_PLUGIN_ROOT="$(native "$root")" bash "$hook" "$1"
}

# start_claude <session id>: launch a stand-in Claude that runs SessionStart, then stays alive.
# Sets $claude to its PID and $base to the session's lock file prefix.
start_claude() {
  rm -f "$work/out" "$work/pid"
  CLAUDE_PLUGIN_ROOT="$(native "$root")" BASH_BIN="$(native "$BASH")" HOOK="$(native "$hook")" \
  OUT="$(native "$work/out")" PIDFILE="$(native "$work/pid")" SID="$1" CWD="$(native "$work")" \
  node -e '
    const fs = require("fs"), { execFileSync } = require("child_process");
    fs.writeFileSync(process.env.PIDFILE, String(process.pid));
    const input = JSON.stringify({ session_id: process.env.SID, hook_event_name: "SessionStart", source: "startup", cwd: process.env.CWD });
    fs.writeFileSync(process.env.OUT, execFileSync(process.env.BASH_BIN, [process.env.HOOK, "start"], { input }));
    setInterval(() => {}, 1000);
  ' &
  wait_for 30 test -s "$work/out" || fail "SessionStart hook produced no output"
  echo "SessionStart output: $(cat "$work/out")"
  grep -q 'jaagte-raho: on' "$work/out" || fail "SessionStart did not report success"
  claude=$(cat "$work/pid")
  base="$dir/jaagte-raho-$1"
}

held() { [ -f "$base.held" ]; }
not_held() { [ ! -f "$base.held" ]; }

# --- Session 1: idle -> working -> background tasks -> idle -> working -> idle_prompt -> Claude exits
sid="e2e-$$-a"
start_claude "$sid"
watcher=$(cat "$base.pid")
alive "$watcher" || fail "watcher $watcher not running"
sleep 3; not_held || fail "lock held while the session is idle"
pass "session start: watcher $watcher running, computer free to sleep while idle"

hook_event busy "$sid"
wait_for 10 held || fail "lock not held after a prompt was submitted"
rc=0; os_reports_lock || rc=$?
[ "$rc" = 1 ] && fail "OS does not report the keep-awake lock while Claude is working"
pass "prompt submitted: lock held"

hook_event stop "$sid" ',"background_tasks":[{"id":"t1","type":"subagent"}]'
sleep 4; held || fail "lock released while background tasks were still running"
pass "turn ended with background tasks running: lock still held"

hook_event stop "$sid" ',"background_tasks":[]'
wait_for 10 not_held || fail "lock still held after the turn finished"
pass "turn finished with nothing in the background: lock released"

bash "$root/scripts/status.sh" | grep -Eq "Session ${sid:0:8}( (.*))?: Claude idle" || fail "status command does not show the idle session"
pass "status command reports the session"

hook_event busy "$sid"
wait_for 10 held || fail "lock not held after the second prompt"
hook_event idle "$sid"
wait_for 10 not_held || fail "lock still held after idle_prompt"
pass "idle_prompt (covers interrupted turns): lock released"

# Waiting for your input (permission prompt): held during the grace period, released after it,
# held again once you answer (the transcript changes).
transcript="$work/transcript.jsonl"; : > "$transcript"
tjson=",\"notification_type\":\"permission_prompt\",\"transcript_path\":\"$(native "$transcript" | sed 's/\\/\\\\/g')\""
hook_event busy "$sid"
wait_for 10 held || fail "lock not held after the prompt before the permission prompt"
hook_event wait "$sid" "$tjson"
sleep 4; held || fail "lock released during the grace period of a permission prompt"
pass "permission prompt within the grace period: lock still held"
sleep 1
JAAGTE_RAHO_INPUT_WAIT=0 hook_event wait "$sid" "$tjson"
wait_for 10 not_held || fail "lock still held after the permission prompt's grace period ran out"
bash "$root/scripts/status.sh" | grep -q "waiting for your input" || fail "status does not show the session waiting for input"
pass "permission prompt past the grace period: lock released, status says it's waiting"
sleep 1; echo '{"type":"user"}' >> "$transcript"
wait_for 10 held || fail "lock not held again after the permission prompt was answered"
[ ! -f "$base.wait" ] || fail "wait marker left behind after the prompt was answered"
pass "permission prompt answered: lock held again"
sleep 1
JAAGTE_RAHO_INPUT_WAIT=0 hook_event wait "$sid" "$tjson"
wait_for 10 not_held || fail "lock still held after a subagent's permission prompt grace period ran out"
sleep 1; mkdir -p "$work/transcript/subagents"; echo '{"type":"user"}' >> "$work/transcript/subagents/agent-x.jsonl"
wait_for 10 held || fail "lock not held again after a subagent's permission prompt was answered"
pass "subagent's permission prompt answered: lock held again"
JAAGTE_RAHO_INPUT_WAIT=never hook_event wait "$sid" "$tjson"
[ ! -f "$base.wait" ] || fail "JAAGTE_RAHO_INPUT_WAIT=never still set a grace period"
hook_event stop "$sid" ',"background_tasks":[]'
wait_for 10 not_held || fail "lock still held after the turn finished"
pass "JAAGTE_RAHO_INPUT_WAIT=never: stays awake while waiting"

hook_event busy "$sid"
wait_for 10 held || fail "lock not held after the third prompt"
if [ -n "$win" ]; then taskkill //PID "$claude" //F >/dev/null; else kill "$claude"; fi
wait_for 15 eval '! alive "$watcher"' || fail "watcher $watcher still running after Claude exited"
not_held || fail "held marker left behind after Claude exited"
if [ -n "${CI:-}" ]; then
  rc=0; os_reports_lock || rc=$?
  [ "$rc" = 0 ] && fail "OS still reports a keep-awake lock after Claude exited"
fi
pass "Claude exited mid-turn: lock released, watcher gone"

# --- Session 2: scheduled runs keep the computer awake while Claude is idle, until they're cancelled
sid="e2e-$$-c"
start_claude "$sid"
sleep 3; not_held || fail "session 2: lock held while idle with nothing scheduled"
sched() {  # sched <tool> <tool_response JSON>
  hook_event sched "$sid" ",\"tool_name\":\"$1\",\"tool_input\":{\"prompt\":\"say \\\"id\\\": 1\"},\"tool_response\":$2,\"tool_use_id\":\"t\""
}

sched ScheduleWakeup "{\"scheduledFor\":$(( ($(date +%s) + 300) * 1000 )),\"clampedDelaySeconds\":300,\"wasClamped\":false}"
wait_for 10 held || fail "lock not held while a /loop wakeup is due"
bash "$root/scripts/status.sh" | grep -q "scheduled run due" || fail "status does not show the due wakeup"
sched ScheduleWakeup '{"scheduledFor":0,"clampedDelaySeconds":0,"wasClamped":false,"stopped":true}'
wait_for 10 not_held || fail "lock still held after the loop was stopped"
pass "/loop wakeup due: lock held until the loop stopped"

sched CronCreate '{"id":"job1","humanSchedule":"every hour","recurring":true,"durable":false,"nextFireAt":1}'
sched CronCreate "{\"id\":\"job2\",\"humanSchedule\":\"once\",\"recurring\":false,\"nextFireAt\":$(( ($(date +%s) + 120) * 1000 ))}"
wait_for 10 held || fail "lock not held while cron jobs are scheduled"
sched CronDelete '{"id":"job1"}'
sleep 4; held || fail "lock released while a one-shot job was still due"
sched CronDelete '{"id":"job2"}'
wait_for 10 not_held || fail "lock still held after every cron job was deleted"
pass "cron jobs scheduled: lock held until they were deleted"

sched CronCreate "{\"id\":\"old\",\"recurring\":false,\"nextFireAt\":$(( ($(date +%s) - 3600) * 1000 ))}"
sleep 4; not_held || fail "lock held for a one-shot job that was due an hour ago"
pass "one-shot job long past its due time: not held"

mkdir -p "$work/.claude"
echo '[{"id":"d1","cron":"0 * * * *","prompt":"x","recurring":true}]' > "$work/.claude/scheduled_tasks.json"
wait_for 10 held || fail "lock not held while the project has durable scheduled jobs"
rm -f "$work/.claude/scheduled_tasks.json"
wait_for 10 not_held || fail "lock still held after the durable jobs were removed"
pass "durable jobs in .claude/scheduled_tasks.json: lock held while they exist"
hook_event end "$sid"
if [ -n "$win" ]; then taskkill //PID "$claude" //F >/dev/null; else kill "$claude"; fi

# --- Sessions 4 and 5: the lid override (Windows, Linux). It's one setting for the whole machine:
# on while either session works, put back only when the last one lets go, and after a crash.
lid_test() {
  export JAAGTE_RAHO_LID_FLAG="$work/lid"
  if [ -n "$win" ]; then
    lid_ac() {
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(native "$root/scripts/awake.ps1")" -Lid \
        -LidFlag "$(native "$work/lid")" | tr -d '\r' | sed -n '1s/^plugged in: \([^,]*\),.*/\1/p'
    }
    before=$(lid_ac)
    [ -n "$before" ] || { echo "SKIP: lid override: this machine's power plan has no lid setting"; return 0; }
    # Whatever happens, never leave this machine's lid setting changed.
    trap 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(native "$root/scripts/awake.ps1")" -RestoreLid -LidFlag "$(native "$work/lid")" >/dev/null' EXIT
    lid_on() { [ "$(lid_ac)" = "do nothing" ]; }
    lid_back() { [ "$(lid_ac)" = "$before" ] && [ ! -f "$work/lid.orig" ]; }
  else
    lid_on() { systemd-inhibit --list 2>/dev/null | grep -i "claude code" | grep -q handle-lid-switch; }
    lid_back() { ! lid_on; }
  fi
  bash "$root/scripts/lid.sh" on | grep -q "Lid override: on" || fail "lid on: $(bash "$root/scripts/lid.sh" on)"

  sid_a="e2e-$$-d"; start_claude "$sid_a"; claude_a=$claude; base_a=$base
  sid_b="e2e-$$-e"; start_claude "$sid_b"; claude_b=$claude; base_b=$base
  sleep 3; lid_back || fail "lid override on while both sessions are idle"
  hook_event busy "$sid_a"
  wait_for 15 lid_on || fail "lid override not applied while Claude is working"
  pass "lid override on, Claude working: closing the lid won't sleep the machine"
  hook_event busy "$sid_b"
  hook_event stop "$sid_a" ',"background_tasks":[]'
  sleep 5; lid_on || fail "lid setting put back while the other session was still working"
  hook_event stop "$sid_b" ',"background_tasks":[]'
  wait_for 15 lid_back || fail "lid setting not put back after the last session finished"
  pass "two sessions: lid setting put back only once the last one finished"

  hook_event busy "$sid_a"
  wait_for 15 lid_on || fail "lid override not applied again"
  if [ -n "$win" ]; then taskkill //PID "$claude_a" //F >/dev/null; else kill "$claude_a"; fi
  wait_for 20 lid_back || fail "lid setting not put back after Claude crashed"
  pass "Claude crashed with the lid override on: lid setting put back"

  bash "$root/scripts/lid.sh" off | grep -q "Lid override: off" || fail "lid off failed"
  base=$base_b; hook_event busy "$sid_b"
  wait_for 10 held || fail "lock not held with the lid override off"
  sleep 3; lid_back || fail "lid override applied while switched off"
  pass "lid override off: idle lock only, lid setting untouched"
  hook_event end "$sid_b"
  if [ -n "$win" ]; then taskkill //PID "$claude_b" //F >/dev/null; else kill "$claude_b"; fi
  unset JAAGTE_RAHO_LID_FLAG
}
[ "$(uname -s)" = Darwin ] || lid_test

# --- Session 3: SessionEnd (e.g. /clear) stops the watcher while Claude keeps running
sid="e2e-$$-b"
start_claude "$sid"
watcher=$(cat "$base.pid")
hook_event busy "$sid"
wait_for 10 held || fail "session 3: lock not held after a prompt"
hook_event end "$sid"
wait_for 15 eval '! alive "$watcher"' || fail "watcher $watcher still running after SessionEnd"
not_held || fail "held marker left behind after SessionEnd"
pass "SessionEnd: lock released, watcher gone"
if [ -n "$win" ]; then taskkill //PID "$claude" //F >/dev/null; else kill "$claude"; fi
