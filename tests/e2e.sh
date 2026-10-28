#!/usr/bin/env bash
# End-to-end check: a stand-in "Claude" (a node process) runs the hook exactly as Claude Code does.
# While it lives, the hook must report success and hold the lock; after it exits, the lock must be gone.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
fail() { echo "FAIL: $*"; exit 1; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) win=1; dir=$(cygpath -u "$TEMP"); native() { cygpath -w "$1"; } ;;
  *) win=; dir="${TMPDIR:-/tmp}"; dir=${dir%/}; native() { echo "$1"; } ;;
esac

alive() {
  if [ -n "$win" ]; then tasklist //NH //FI "PID eq $1" 2>/dev/null | grep -q " $1 "
  else kill -0 "$1" 2>/dev/null; fi
}

held_by_os() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      out=$(MSYS_NO_PATHCONV=1 powercfg /requests 2>&1) || { echo "SKIP: powercfg /requests needs admin"; return 0; }
      grep -q jaagte-raho <<< "$out" ;;
    Darwin) pmset -g assertions | grep -qi caffeinate ;;
    Linux) systemd-inhibit --list | grep -qi "claude code" ;;
  esac
}

# Stand-in Claude: records its own PID, runs the hook, then stays alive until killed.
CLAUDE_PLUGIN_ROOT="$(native "$root")" BASH_BIN="$(native "$BASH")" \
HOOK="$(native "$root/scripts/awake.sh")" OUT="$(native "$work/out")" PIDFILE="$(native "$work/pid")" \
node -e '
  const fs = require("fs"), { execFileSync } = require("child_process");
  fs.writeFileSync(process.env.PIDFILE, String(process.pid));
  fs.writeFileSync(process.env.OUT, execFileSync(process.env.BASH_BIN, [process.env.HOOK]));
  setInterval(() => {}, 1000);
' &

for _ in $(seq 1 30); do [ -s "$work/out" ] && break; sleep 1; done
echo "hook output: $(cat "$work/out" 2>/dev/null)"
grep -q 'keeping this computer awake' "$work/out" || fail "hook did not report success"

claude=$(cat "$work/pid")
lock="$dir/jaagte-raho-$claude.pid"
[ -f "$lock" ] || fail "no lock file at $lock"
watcher=$(cat "$lock")
alive "$watcher" || fail "watcher $watcher is not running"
held_by_os || fail "the OS does not report a keep-awake request"
echo "PASS: lock held by watcher $watcher for stand-in Claude $claude"

bash "$root/scripts/status.sh" | grep -q "Claude PID $claude: running" || fail "status command does not show the session"
echo "PASS: status command reports the session"

if [ -n "$win" ]; then taskkill //PID "$claude" //F >/dev/null; else kill "$claude"; fi
for _ in $(seq 1 15); do alive "$watcher" || break; sleep 1; done
alive "$watcher" && fail "watcher $watcher still running after Claude exited"
[ -f "$lock" ] && fail "lock file left behind at $lock"
echo "PASS: lock released after Claude exited"
