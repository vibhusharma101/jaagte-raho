#!/usr/bin/env bash
# Session watcher for macOS/Linux: watch.sh <base> <claude pid>.
# Holds the OS keep-awake lock while <base>.busy exists and marks it with <base>.held.
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

trap 'release; exit 0' TERM INT
while kill -0 "$claude" 2>/dev/null && [ "$(cat "$base.pid" 2>/dev/null)" = "$$" ]; do
  if [ -f "$base.busy" ]; then
    { [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; } || hold
  elif [ -n "$holder" ]; then
    release
  fi
  sleep 2
done
release
