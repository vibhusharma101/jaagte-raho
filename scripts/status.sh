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

clock() { if [ "$(uname -s)" = Darwin ]; then date -r "$1" +%H:%M; else date -d "@$1" +%H:%M; fi; }

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
    rm -f "$base".pid "$base".busy "$base".held "$base".cwd "$base".task "$base".sched "$base".until
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
  until=$(cat "$base.until" 2>/dev/null)
  [ "$until" -gt "$(date +%s)" ] 2>/dev/null \
    && echo "  scheduled run due: kept awake until $(clock "$until") so it doesn't get skipped"
  [ -n "$folder" ] && grep -q '"cron"' "$folder/.claude/scheduled_tasks.json" 2>/dev/null \
    && echo "  durable scheduled jobs in .claude/scheduled_tasks.json: kept awake while this session is open"
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

# The keep-awake lock covers the idle timer only. Closing the lid follows the OS lid setting.
echo "--- Closing the lid (jaagte-raho can't prevent this) ---"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    root="$(cd "$(dirname "$0")/.." && pwd)"
    echo "Lid action: $(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$root/scripts/awake.ps1")" -Lid | tr -d '\r')"
    echo "To keep Claude working with the lid closed: Control Panel > Power Options > Choose what closing the lid does > Do nothing" ;;
  Darwin)
    if pmset -g | grep -Eq 'SleepDisabled[[:space:]]+1'; then
      echo "Sleep is disabled system-wide (pmset disablesleep 1), so closing the lid won't sleep this Mac"
    else
      echo "Closing the lid sleeps this Mac; macOS doesn't let apps prevent that. It stays awake only when on power with an external display (clamshell mode)"
    fi ;;
  Linux)
    lid() { busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$1" 2>/dev/null | sed 's/^s "\(.*\)"$/\1/'; }
    echo "Lid action (logind): on battery: $(lid HandleLidSwitch || echo unknown), plugged in: $(lid HandleLidSwitchExternalPower || echo unknown)" ;;
esac
