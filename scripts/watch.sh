#!/usr/bin/env bash
# Session watcher for macOS/Linux: watch.sh <base> <claude pid> [<lid switch file>].
# Holds the OS keep-awake lock while <base>.busy exists (unless Claude has waited on your input past
# the grace period) or a scheduled run is due, and marks it
# with <base>.held.
# Exits, releasing the lock, when Claude exits or <base>.pid no longer names this watcher.
base=$1 claude=$2 lidflag=$3 holder= holder_lid= lid_failed=
echo $$ > "$base.pid"

# hold [lid]: take the lock. With "lid" (Linux, /jaagte-raho:lid on), closing the lid doesn't sleep
# the machine either. The inhibitor is tied to its process, so the OS lifts it when that ends.
hold() {
  case "$(uname -s)" in
    Darwin) caffeinate -i -w "$claude" & ;;
    # setsid gives the holder its own process group, so release() also stops the child it runs.
    *) setsid systemd-inhibit --what="idle:sleep${1:+:handle-lid-switch}" --who="Claude Code" \
         --why="Claude is working (jaagte-raho)" sleep infinity & ;;
  esac
  holder=$! holder_lid=$1
  : > "$base.held"
}

# Linux only: the lid override is switched on and the machine is plugged in (or has no battery).
# Unplugging lifts it within seconds, so a laptop in a bag still sleeps when its lid is closed.
lid_wanted() {
  [ "$(uname -s)" = Linux ] && [ -n "$lidflag" ] && [ -f "$lidflag" ] && [ -z "$lid_failed" ] || return 1
  local s bat=
  for s in /sys/class/power_supply/*; do
    case "$(cat "$s/type" 2>/dev/null)" in
      Mains|USB*) [ "$(cat "$s/online" 2>/dev/null)" = 1 ] && return 0 ;;
      Battery) bat=1 ;;
    esac
  done
  [ -z "$bat" ]
}

release() {
  if [ -n "$holder" ]; then kill -- "-$holder" 2>/dev/null || kill "$holder" 2>/dev/null; fi
  holder=
  rm -f "$base.held"
}

# A scheduled run is due: <base>.until (written by the sched hook) is still ahead, or the project has
# durable jobs in .claude/scheduled_tasks.json, which only run while a session is open.
cwd=$(cat "$base.cwd" 2>/dev/null)
due() {
  local until
  until=$(cat "$base.until" 2>/dev/null) && [ "$until" -gt "$(date +%s)" ] 2>/dev/null && return 0
  [ -n "$cwd" ] && grep -q '"cron"' "$cwd/.claude/scheduled_tasks.json" 2>/dev/null
}

mtime() { if [ "$(uname -s)" = Darwin ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }

# Newest change to the session transcript or its subagents' (<session>/subagents/*.jsonl): a
# subagent's permission prompt, once answered, only moves the subagent's transcript.
newest() {
  local m=0 t f
  for f in "$1" "${1%.jsonl}"/subagents/*.jsonl; do
    [ -f "$f" ] || continue
    t=$(mtime "$f" 2>/dev/null) && [ "$t" -gt "$m" ] && m=$t
  done
  echo "$m"
}

# Claude has been waiting for your input past the grace period (see awake.sh wait). A transcript
# changing after the wait began means you answered, so the wait is over.
asleep_ok() {
  local since until path
  { read -r since until path < "$base.wait"; } 2>/dev/null || return 1
  if [ -n "$path" ] && [ "$(newest "$path")" -gt "$since" ] 2>/dev/null; then
    rm -f "$base.wait"; return 1
  fi
  [ "$(date +%s)" -ge "$until" ] 2>/dev/null
}

# macOS: the lid override (maclid.sh) is on while this session holds the lock, the switch is on and
# the Mac is on AC power. Unplugging puts disablesleep back within seconds. A failed restore is
# retried about once a minute, so the log doesn't fill up.
maclid= retry=0
if [ "$(uname -s)" = Darwin ] && [ -n "$lidflag" ]; then
  dir=$(dirname "$base"); . "$(dirname "$0")/maclid.sh"; maclid=1
fi
mac_lid() {
  [ -n "$maclid" ] || return 0
  if [ -n "$holder" ] && [ -f "$lidflag" ] && [ -z "$lid_failed" ] && maclid_on_ac; then
    [ -f "$base.lid" ] || maclid_locked maclid_apply || lid_failed=1
  elif [ -f "$base.lid" ] || [ -f "$maclid_orig" ]; then
    [ "$retry" -gt 0 ] && { retry=$((retry - 1)); return 0; }
    maclid_locked maclid_release || retry=30
  fi
}

trap 'release; mac_lid; exit 0' TERM INT
while kill -0 "$claude" 2>/dev/null && [ "$(cat "$base.pid" 2>/dev/null)" = "$$" ]; do
  if { [ -f "$base.busy" ] && ! asleep_ok; } || due; then
    lid=; lid_wanted && lid=lid
    if ! { [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; } || [ "$lid" != "$holder_lid" ]; then
      release; hold $lid
      # The lid inhibitor needs polkit's permission. If it's refused, the error is in <base>.log
      # (shown by status); keep the idle lock and don't retry until the switch is turned off and on.
      if [ -n "$lid" ]; then sleep 1; kill -0 "$holder" 2>/dev/null || { lid_failed=1; release; hold; }; fi
    fi
  elif [ -n "$holder" ]; then
    release
  fi
  [ -n "$lidflag" ] && [ ! -f "$lidflag" ] && lid_failed=
  mac_lid
  sleep 2
done
release
retry=0; mac_lid
