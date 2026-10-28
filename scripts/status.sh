#!/usr/bin/env bash
# Lists every jaagte-raho session on this machine, whether Claude is working in it, and whether the
# keep-awake lock is held, plus what the OS itself reports.

. "$(dirname "$0")/lockdir.sh"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) win=1 ;; *) win= ;; esac
[ -n "$dir" ] || { echo "No private directory for lock files (see README, Troubleshooting)."; exit 0; }

alive() {
  if [ -n "$win" ]; then tasklist //NH //FI "PID eq $1" 2>/dev/null | grep -q " $1 "
  else kill -0 "$1" 2>/dev/null; fi
}

echo "OS: $(uname -s)"
found=
for f in "$dir"/jaagte-raho-*.pid; do
  [ -f "$f" ] || continue
  found=1
  base=${f%.pid}
  sid=${base##*/jaagte-raho-}
  watcher=$(cat "$f")
  alive "$watcher" && w=running || w=gone
  [ -f "$base.busy" ] && busy=working || busy=idle
  if [ "$w" = running ] && [ -f "$base.held" ]; then state="AWAKE (lock held)"
  elif [ "$w" = running ]; then state="may sleep (lock not held)"
  else state="STALE (watcher gone)"; fi
  echo "Session ${sid:0:8}: Claude $busy | watcher PID $watcher $w | $state"
done
[ -n "$found" ] || echo "No sessions are being watched."

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
