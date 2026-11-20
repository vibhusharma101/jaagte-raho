#!/usr/bin/env bash
# End-to-end check of the session lifecycle. A stand-in "Claude" (a node process) runs the
# SessionStart hook exactly as Claude Code does; the other hooks are fed the same JSON Claude sends.
# The lock must be held only while Claude is working, and everything must clean up on exit.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$root/scripts/awake.sh"
work="$(mktemp -d)"
fail() { echo "FAIL: $*"; exit 1; }
# On exit, pass or fail: put back a lid setting the lid test changed, and remove this run's files.
cleanup() {
  if [ -n "${lid_restore:-}" ]; then
    JAAGTE_RAHO_LID_FLAG="$work/lid" bash "$root/scripts/lid.sh" off >/dev/null 2>&1 || true
  fi
  if [ -s "$work/hookpid" ]; then
    if [ -n "$win" ]; then taskkill //PID "$(cat "$work/hookpid")" //F >/dev/null 2>&1; else kill "$(cat "$work/hookpid")" 2>/dev/null; fi
  fi
  [ -n "${dir:-}" ] && rm -f "$dir"/jaagte-raho-e2e-$$-*
  rm -rf "$work"
}
trap cleanup EXIT
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
  disown $!   # it gets killed on purpose later; don't let bash report "Terminated"
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

bash "$root/scripts/status.sh" | grep -E "Session ${sid:0:8}( (.*))?: Claude idle" >/dev/null || fail "status command does not show the idle session"
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
bash "$root/scripts/status.sh" | grep "waiting for your input" >/dev/null || fail "status does not show the session waiting for input"
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
read -r _ until_never _ < "$base.wait"
[ "$until_never" = 9999999999 ] || fail "JAAGTE_RAHO_INPUT_WAIT=never still set a grace period ($until_never)"
sleep 4; held || fail "lock released while waiting with JAAGTE_RAHO_INPUT_WAIT=never"
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
bash "$root/scripts/status.sh" | grep "scheduled run due" >/dev/null || fail "status does not show the due wakeup"
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

# --- Sessions 4 and 5: the lid override. It's one setting for the whole machine:
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
    lid_restore=1   # whatever happens, cleanup never leaves this machine's lid setting changed
    lid_on() { [ "$(lid_ac)" = "do nothing" ]; }
    lid_back() { [ "$(lid_ac)" = "$before" ] && [ ! -f "$work/lid.orig" ]; }
  elif [ "$(uname -s)" = Darwin ]; then
    # Never asks for a password: runs only where pmset disablesleep is already allowed without one
    # (CI runners, or a Mac where /jaagte-raho:lid on has set it up).
    sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 \
      || { echo "SKIP: lid override: pmset disablesleep needs a password here (run /jaagte-raho:lid on once)"; return 0; }
    pmset -g batt | head -n1 | grep -q "AC Power" || { echo "SKIP: lid override: this Mac is on battery"; return 0; }
    sd() { pmset -g | awk '/SleepDisabled/ { print $2; exit }'; }
    before=$(sd)
    [ "${before:-0}" = 0 ] || { echo "SKIP: lid override: sleep is already disabled on this Mac"; return 0; }
    lid_restore=1   # whatever happens, cleanup never leaves sleep disabled
    lid_on() { [ "$(sd)" = 1 ]; }
    lid_back() { [ "$(sd)" != 1 ] && [ ! -f "$work/lid.orig" ]; }
  else
    lid_on() { systemd-inhibit --list 2>/dev/null | grep -i "claude code" | grep -q handle-lid-switch; }
    lid_back() { ! lid_on; }
  fi
  bash "$root/scripts/lid.sh" on | grep "Lid override: on" >/dev/null || fail "lid on: $(bash "$root/scripts/lid.sh" on)"

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

  bash "$root/scripts/lid.sh" off | grep "Lid override: off" >/dev/null || fail "lid off failed"
  base=$base_b; hook_event busy "$sid_b"
  wait_for 10 held || fail "lock not held with the lid override off"
  sleep 3; lid_back || fail "lid override applied while switched off"
  pass "lid override off: idle lock only, lid setting untouched"
  hook_event end "$sid_b"
  if [ -n "$win" ]; then taskkill //PID "$claude_b" //F >/dev/null; else kill "$claude_b"; fi
  unset JAAGTE_RAHO_LID_FLAG
}
lid_test

# macOS, CI only (passwordless sudo, throwaway machine): the one-time setup installs a sudoers rule
# that visudo accepts, owned by root, mode 0440, allowing only pmset disablesleep; uninstall removes it.
if [ "$(uname -s)" = Darwin ] && [ -n "${CI:-}" ] && sudo -n true 2>/dev/null; then
  rule=/etc/sudoers.d/jaagte-raho
  out=$(bash "$root/scripts/lid.sh" setup)
  grep -q "Set up: $rule" <<< "$out" || fail "lid setup: $out"
  [ "$(stat -f '%Su %Sg %Lp' "$rule")" = "root wheel 440" ] || fail "sudoers rule has owner/mode $(stat -f '%Su %Sg %Lp' "$rule")"
  sudo -n /usr/sbin/visudo -cf "$rule" >/dev/null || fail "visudo rejects the installed rule"
  sudo -n cat "$rule" | grep -v '^#' | grep -Eq "^$(id -un) ALL=\(root\) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1$" \
    || fail "sudoers rule allows more than pmset disablesleep 0|1: $(sudo -n cat "$rule")"
  JAAGTE_RAHO_LID_FLAG="$work/lid" bash "$root/scripts/lid.sh" uninstall | grep "Removed $rule" >/dev/null || fail "lid uninstall didn't remove the rule"
  [ ! -e "$rule" ] || fail "sudoers rule still there after uninstall"
  pass "macOS setup: sudoers rule valid, root-owned, 0440, pmset disablesleep only; uninstall removes it"
fi

# --- Session 6: notifications. A stand-in Slack webhook records every message it gets.
: > "$work/hooks.txt"
OUT="$(native "$work/hooks.txt")" PORTF="$(native "$work/hookport")" PIDF="$(native "$work/hookpid")" node -e '
  const http = require("http"), fs = require("fs");
  fs.writeFileSync(process.env.PIDF, String(process.pid));
  const s = http.createServer((q, r) => {
    let b = ""; q.on("data", d => b += d);
    q.on("end", () => {
      if (q.url === "/fail") { r.statusCode = 500; return r.end("no"); }
      fs.appendFileSync(process.env.OUT, b + "\n"); r.end("ok");
    });
  });
  s.listen(0, "127.0.0.1", () => fs.writeFileSync(process.env.PORTF, String(s.address().port)));
' &
disown $!
wait_for 15 test -s "$work/hookport" || fail "stand-in webhook didn't start"
export JAAGTE_RAHO_NOTIFY_URL="http://127.0.0.1:$(cat "$work/hookport")/hook"
msgs() { wc -l < "$work/hooks.txt" | tr -d ' '; }
got() { grep -F "$1" "$work/hooks.txt" >/dev/null; }

sid="e2e-$$-f"
start_claude "$sid"
folder=$(basename "$work")
hook_event busy "$sid" ',"prompt":"Refactor the parser"'
JAAGTE_RAHO_NOTIFY_AFTER=10 hook_event stop "$sid" ',"background_tasks":[]'
sleep 4; [ "$(msgs)" = 0 ] || fail "pinged for a run shorter than JAAGTE_RAHO_NOTIFY_AFTER: $(cat "$work/hooks.txt")"
hook_event busy "$sid" ',"prompt":"Refactor the parser"'
JAAGTE_RAHO_NOTIFY_AFTER=0 hook_event stop "$sid" ',"background_tasks":[]'
wait_for 15 got "Claude finished" || fail "no ping when the run finished"
got "in $folder: \\\"Refactor the parser\\\"" || fail "finished ping doesn't name the folder and prompt: $(cat "$work/hooks.txt")"
got '{"text":"Claude finished' || fail "Slack webhook didn't get Slack's format: $(cat "$work/hooks.txt")"
pass "run finished: pinged, with folder and prompt; short runs: no ping"

out=$(JAAGTE_RAHO_NOTIFY_URL="http://127.0.0.1:$(cat "$work/hookport")/api/webhooks/1/abc" bash "$root/scripts/notify.sh" test)
grep -F "Sent a test message" <<< "$out" >/dev/null || fail "Discord test message not sent: $out"
got '{"content":"jaagte-raho test' || fail "Discord webhook didn't get Discord's format: $(cat "$work/hooks.txt")"
pass "Discord webhook URL: Discord's message format; anything else: Slack's"

hook_event busy "$sid" ',"prompt":"Refactor the parser"'
JAAGTE_RAHO_STALL_AFTER=2s hook_event wait "$sid" "$tjson"
wait_for 15 got "waiting for your input" || fail "no ping while Claude waited for input"
pass "waiting for input past JAAGTE_RAHO_STALL_AFTER: pinged"

n=$(msgs)
hook_event busy "$sid" ',"prompt":"Refactor the parser"'
JAAGTE_RAHO_STALL_AFTER=4s hook_event wait "$sid" "$tjson"
sleep 1; echo '{"type":"user"}' >> "$transcript"   # you answered
sleep 7; [ "$(msgs)" = "$n" ] || fail "pinged about a prompt that was already answered"
pass "prompt answered in time: no ping"

out=$(JAAGTE_RAHO_NOTIFY_URL="http://127.0.0.1:$(cat "$work/hookport")/fail" bash "$root/scripts/notify.sh" test)
grep -F "didn't accept" <<< "$out" >/dev/null || fail "a failing webhook wasn't reported: $out"
out=$(JAAGTE_RAHO_NOTIFY_URL="http://hooks.example.com/x" bash "$root/scripts/notify.sh" test)
grep -F "must start with https://" <<< "$out" >/dev/null || fail "a plain-http webhook was accepted: $out"
pass "failing or non-https webhook: reported, not sent"

# Connecting: connect slack prints (instead of opening, in tests) a create-app link whose manifest
# asks only for incoming-webhook; save takes the URL from the clipboard, never from the chat.
link=$(JAAGTE_RAHO_NO_BROWSER=1 bash "$root/scripts/notify.sh" connect slack | grep -o 'https://api.slack.com/apps?new_app=1&manifest_json=[^ ]*')
[ -n "$link" ] || fail "connect slack gave no create-app link"
LINK="$link" node -e '
  const m = JSON.parse(decodeURIComponent(process.env.LINK.split("manifest_json=")[1]));
  if (m.display_information.name !== "jaagte-raho" || JSON.stringify(m.oauth_config.scopes) !== "{\"bot\":[\"incoming-webhook\"]}") process.exit(1);
' || fail "create-app manifest isn't jaagte-raho with only the incoming-webhook scope"
hookurl="http://127.0.0.1:$(cat "$work/hookport")/saved"
cfg="$work/cfg"; mkdir -p "$cfg"
save() { JAAGTE_RAHO_LID_FLAG="$cfg/lid" JAAGTE_RAHO_NOTIFY_URL= JAAGTE_RAHO_TEST_CLIPBOARD="$1" bash "$root/scripts/notify.sh" save; }
out=$(save "not a webhook https://example.com/secret")
grep -F "Not saved" <<< "$out" >/dev/null && [ ! -e "$cfg/notify-url" ] || fail "saved something that isn't a webhook URL: $out"
grep -F "example.com" <<< "$out" >/dev/null && fail "save printed the clipboard's contents: $out"
out=$(save "$hookurl")
[ "$(cat "$cfg/notify-url")" = "$hookurl" ] || fail "save didn't store the webhook URL: $out"
grep -F "$hookurl" <<< "$out" >/dev/null && fail "save printed the webhook URL: $out"
wait_for 10 got "jaagte-raho is connected" || fail "save didn't send a test message: $out"
[ -n "$win" ] || [ "$(ls -l "$cfg/notify-url" | cut -c1-10)" = "-rw-------" ] || fail "notify-url is readable by others: $(ls -l "$cfg/notify-url")"
JAAGTE_RAHO_LID_FLAG="$cfg/lid" bash "$root/scripts/notify.sh" off >/dev/null
[ ! -e "$cfg/notify-url" ] || fail "notify off didn't remove the webhook URL"
pass "connect: Slack create-app link; save: from clipboard, validated, never printed, private; off removes it"
hook_event stop "$sid" ',"background_tasks":[]'
hook_event end "$sid"
if [ -n "$win" ]; then taskkill //PID "$claude" //F >/dev/null; else kill "$claude"; fi
unset JAAGTE_RAHO_NOTIFY_URL

# --- Session 3: SessionEnd (e.g. /clear) stops the watcher while Claude keeps running
sid="e2e-$$-b"
start_claude "$sid"
watcher=$(cat "$base.pid")
hook_event busy "$sid"
wait_for 10 held || fail "session 3: lock not held after a prompt"
hook_event end "$sid"
wait_for 15 eval '! alive "$watcher"' || fail "watcher $watcher still running after SessionEnd"
not_held || fail "held marker left behind after SessionEnd"
leftover=$(ls "$base".* 2>/dev/null || true)
[ -z "$leftover" ] || fail "files left behind after SessionEnd: $leftover"
pass "SessionEnd: lock released, watcher gone, no files left behind"

# Status drops logs of ended sessions once they're empty or old, but still reports a fresh error.
old="$dir/jaagte-raho-e2e-$$-x.log" fresh="$dir/jaagte-raho-e2e-$$-y.log"
: > "$old"; touch -t 202001010000 "$old"
echo "test error" > "$fresh"
out=$(bash "$root/scripts/status.sh")
[ ! -e "$old" ] || fail "status kept an empty log of an ended session"
[ -e "$fresh" ] && grep -q "test error" <<< "$out" || fail "status dropped or hid a fresh error"
pass "status: old empty logs removed, fresh errors still reported"
if [ -n "$win" ]; then taskkill //PID "$claude" //F >/dev/null; else kill "$claude"; fi
