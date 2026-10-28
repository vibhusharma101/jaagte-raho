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
  OUT="$(native "$work/out")" PIDFILE="$(native "$work/pid")" SID="$1" \
  node -e '
    const fs = require("fs"), { execFileSync } = require("child_process");
    fs.writeFileSync(process.env.PIDFILE, String(process.pid));
    const input = JSON.stringify({ session_id: process.env.SID, hook_event_name: "SessionStart", source: "startup" });
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

bash "$root/scripts/status.sh" | grep -q "Session ${sid:0:8}: Claude idle" || fail "status command does not show the idle session"
pass "status command reports the session"

hook_event busy "$sid"
wait_for 10 held || fail "lock not held after the second prompt"
hook_event idle "$sid"
wait_for 10 not_held || fail "lock still held after idle_prompt"
pass "idle_prompt (covers interrupted turns): lock released"

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

# --- Session 2: SessionEnd (e.g. /clear) stops the watcher while Claude keeps running
sid="e2e-$$-b"
start_claude "$sid"
watcher=$(cat "$base.pid")
hook_event busy "$sid"
wait_for 10 held || fail "session 2: lock not held after a prompt"
hook_event end "$sid"
wait_for 15 eval '! alive "$watcher"' || fail "watcher $watcher still running after SessionEnd"
not_held || fail "held marker left behind after SessionEnd"
pass "SessionEnd: lock released, watcher gone"
if [ -n "$win" ]; then taskkill //PID "$claude" //F >/dev/null; else kill "$claude"; fi
