#!/usr/bin/env bash
# Lists every jaagte-raho lock on this machine, whether it is really held, and what the OS reports.

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) win=1; dir=$(cygpath -u "$TEMP") ;;
  *) win=; dir="${TMPDIR:-/tmp}"; dir=${dir%/} ;;
esac

alive() {
  if [ -n "$win" ]; then tasklist //NH //FI "PID eq $1" 2>/dev/null | grep -q " $1 "
  else kill -0 "$1" 2>/dev/null; fi
}

echo "OS: $(uname -s)"
found=
for f in "$dir"/jaagte-raho-*.pid; do
  [ -f "$f" ] || continue
  found=1
  claude=${f##*/jaagte-raho-}; claude=${claude%.pid}
  holder=$(cat "$f")
  alive "$claude" && c=running || c=gone
  alive "$holder" && h=running || h=gone
  if [ "$c$h" = runningrunning ]; then state="AWAKE (lock held)"; else state="STALE (lock not held)"; fi
  echo "Claude PID $claude: $c | watcher PID $holder: $h | $state"
done
[ -n "$found" ] || echo "No sessions are holding the computer awake."

for f in "$dir"/jaagte-raho-*.err "$dir"/jaagte-raho-*.log; do
  [ -s "$f" ] && echo "Last error (${f##*/}): $(head -n1 "$f")"
done

echo "--- OS report ---"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    MSYS_NO_PATHCONV=1 powercfg /requests 2>&1 | grep -B1 -i jaagte-raho \
      || echo "powercfg /requests shows nothing for jaagte-raho (it needs an admin terminal to show anything)" ;;
  Darwin) pmset -g assertions | grep -i caffeinate || echo "No caffeinate assertion found" ;;
  Linux) systemd-inhibit --list 2>&1 | grep -i "claude code" || echo "No Claude Code inhibitor found" ;;
esac
