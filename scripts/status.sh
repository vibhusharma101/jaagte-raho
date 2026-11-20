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
    rm -f "$base".pid "$base".busy "$base".wait "$base".lid "$base".lid.err "$base".held "$base".cwd "$base".task "$base".sched "$base".until \
      "$base".log "$base".err
    stale=$((stale + 1))
    continue
  fi
  found=1
  folder=$(cat "$base.cwd" 2>/dev/null); folder=${folder%/}
  [ -f "$base.busy" ] && busy=working || busy=idle
  wait= since= until=
  [ "$busy" = working ] && { read -r since until wait < "$base.wait"; } 2>/dev/null && busy="waiting for your input"
  [ -f "$base.held" ] && state="AWAKE (lock held)" || state="may sleep (lock not held)"
  echo "Session ${sid:0:8}${folder:+ (${folder##*/})}: Claude $busy | watcher PID $watcher | $state"
  [ -n "$folder" ] && echo "  folder: $folder"
  [ -s "$base.task" ] && echo "  last prompt ($(ago "$base.task")): \"$(cat "$base.task")\""
  if [ "$busy" = "waiting for your input" ] && [ "$until" -gt 0 ] 2>/dev/null; then
    if [ "$until" -ge 9999999999 ]; then
      echo "  waiting for your input since $(clock "$since"): kept awake until you answer (JAAGTE_RAHO_INPUT_WAIT=never)"
    elif [ "$until" -gt "$(date +%s)" ]; then
      echo "  waiting for your input since $(clock "$since"): lets the computer sleep at $(clock "$until") if you haven't answered"
    else
      echo "  waiting for your input since $(clock "$since"): computer allowed to sleep since $(clock "$until")"
    fi
  fi
  until=$(cat "$base.until" 2>/dev/null)
  [ "$until" -gt "$(date +%s)" ] 2>/dev/null \
    && echo "  scheduled run due: kept awake until $(clock "$until") so it doesn't get skipped"
  [ -n "$folder" ] && grep -q '"cron"' "$folder/.claude/scheduled_tasks.json" 2>/dev/null \
    && echo "  durable scheduled jobs in .claude/scheduled_tasks.json: kept awake while this session is open"
done
[ -n "$found" ] || echo "No sessions are being watched."
[ "$stale" -eq 0 ] || echo "Removed leftover files from $stale ended session(s)."

# Logs and errors of sessions that have ended (no .pid). Kept while recent and non-empty, so a failed
# start can still be reported; dropped once empty or a day old.
now=$(date +%s)
for f in "$dir"/jaagte-raho-*.err "$dir"/jaagte-raho-*.log; do
  [ -f "$f" ] || continue
  b=${f%.log}; b=${b%.err}; b=${b%.lid}
  [ -f "$b.pid" ] && continue
  age=$(( now - $(mtime "$f") ))
  { [ ! -s "$f" ] && [ "$age" -gt 60 ]; } || [ "$age" -gt 86400 ] && rm -f "$f"
done

for f in "$dir"/jaagte-raho-*.err "$dir"/jaagte-raho-*.log; do
  [ -s "$f" ] && echo "Last error (${f##*/}): $(head -n1 "$f")"
done

echo "--- Notifications ---"
bash "$(dirname "$0")/notify.sh" status | head -n1

echo "--- OS report ---"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    MSYS_NO_PATHCONV=1 powercfg /requests 2>&1 | grep -B1 -i jaagte-raho \
      || echo "powercfg /requests shows nothing for jaagte-raho (it needs an admin terminal to show anything)" ;;
  Darwin) pmset -g assertions | grep -i caffeinate || echo "No caffeinate assertion found" ;;
  Linux) systemd-inhibit --list 2>&1 | grep -i "claude code" || echo "No Claude Code inhibitor found" ;;
esac

# The keep-awake lock covers the idle timer only. Closing the lid follows the OS lid setting, unless
# the lid override (/jaagte-raho:lid on, Windows and Linux) is on.
[ -f "$lidflag" ] && override=on || override=off
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "--- Closing the lid (lid override: $override) ---"
    root="$(cd "$(dirname "$0")/.." && pwd)"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$root/scripts/awake.ps1")" -Lid \
      -LidFlag "$(cygpath -w "$lidflag")" | tr -d '\r' \
      | sed '1s/^/Lid action: /'
    [ "$override" = on ] \
      || echo "To keep Claude working with the lid closed while plugged in: /jaagte-raho:lid on" ;;
  Darwin)
    echo "--- Closing the lid (lid override: $override) ---"
    maclid_orig="$(dirname "$lidflag")/lid.orig"
    if pmset -g | grep -Eq 'SleepDisabled[[:space:]]+1'; then
      if [ -f "$maclid_orig" ]; then
        echo "lid override: active, closing the lid won't sleep this Mac while Claude works; puts disablesleep back to $(cat "$maclid_orig") once Claude is done"
      else
        echo "Sleep is disabled system-wide (pmset disablesleep 1), so closing the lid won't sleep this Mac"
      fi
    else
      echo "Closing the lid sleeps this Mac. It stays awake only when on power with an external display (clamshell mode)"
      if [ "$override" = on ]; then
        echo "lid override: on, takes effect while Claude is working and the Mac is on power"
      else
        echo "To keep Claude working with the lid closed while on power: /jaagte-raho:lid on (asks for your password once)"
      fi
    fi
    pmset -g batt | head -n1 | grep -q "AC Power" || echo "On battery: closing the lid sleeps this Mac, lid override or not" ;;
  Linux)
    echo "--- Closing the lid (lid override: $override) ---"
    lid() { busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$1" 2>/dev/null | sed 's/^s "\(.*\)"$/\1/'; }
    echo "Lid action (logind): on battery: $(lid HandleLidSwitch || echo unknown), plugged in: $(lid HandleLidSwitchExternalPower || echo unknown)"
    if [ "$override" = on ]; then
      systemd-inhibit --list 2>/dev/null | grep -i "claude code" | grep -q handle-lid-switch \
        && echo "lid override: active, closing the lid won't sleep this machine while Claude works" \
        || echo "lid override: on, takes effect while Claude is working and the machine is plugged in"
    else
      echo "To keep Claude working with the lid closed while plugged in: /jaagte-raho:lid on"
    fi ;;
esac
