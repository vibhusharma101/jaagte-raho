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

mtime() { if [ "$(uname -s)" = Darwin ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }

ago() {
  local s=$(( $(date +%s) - $(mtime "$1") ))
  if [ "$s" -lt 60 ]; then echo "${s}s ago"
  elif [ "$s" -lt 3600 ]; then echo "$(( s / 60 ))m ago"
  else echo "$(( s / 3600 ))h ago"; fi
}

echo "OS: $(uname -s)"
echo "Each session holds its own lock. The computer stays awake while any session shows AWAKE."
found= stale=0
for f in "$dir"/jaagte-raho-*.pid; do
  [ -f "$f" ] || continue
  base=${f%.pid}
  sid=${base##*/jaagte-raho-}
  watcher=$(cat "$f")
  # A watcher that is gone holds nothing: drop its leftover files instead of listing them.
  if ! alive "$watcher"; then
    rm -f "$base".pid "$base".busy "$base".held "$base".cwd "$base".task
    stale=$((stale + 1))
    continue
  fi
  found=1
  folder=$(cat "$base.cwd" 2>/dev/null); folder=${folder%/}
  [ -f "$base.busy" ] && busy=working || busy=idle
  [ -f "$base.held" ] && state="AWAKE (lock held)" || state="may sleep (lock not held)"
  echo "Session ${sid:0:8}${folder:+ (${folder##*/})}: Claude $busy | watcher PID $watcher | $state"
  [ -n "$folder" ] && echo "  folder: $folder"
  [ -s "$base.task" ] && echo "  last prompt ($(ago "$base.task")): \"$(cat "$base.task")\""
done
[ -n "$found" ] || echo "No sessions are being watched."
[ "$stale" -eq 0 ] || echo "Removed leftover files from $stale ended session(s)."

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
