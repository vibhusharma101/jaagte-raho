#!/usr/bin/env bash
# Session watcher for macOS/Linux: watch.sh <base> <claude pid>.
# Holds the OS keep-awake lock while <base>.busy exists or a scheduled run is due, and marks it
# with <base>.held.
# Exits, releasing the lock, when Claude exits or <base>.pid no longer names this watcher.
base=$1 claude=$2 holder=
echo $$ > "$base.pid"

hold() {
  case "$(uname -s)" in
    Darwin) caffeinate -i -w "$claude" & ;;
    # setsid gives the holder its own process group, so release() also stops the child it runs.
    *) setsid systemd-inhibit --what=idle:sleep --who="Claude Code" --why="Claude is working (jaagte-raho)" \
         sleep infinity & ;;
  esac
  holder=$!
  : > "$base.held"
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

trap 'release; exit 0' TERM INT
while kill -0 "$claude" 2>/dev/null && [ "$(cat "$base.pid" 2>/dev/null)" = "$$" ]; do
  if [ -f "$base.busy" ] || due; then
    { [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; } || hold
  elif [ -n "$holder" ]; then
    release
  fi
  sleep 2
done
release
