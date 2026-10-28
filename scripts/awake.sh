#!/usr/bin/env bash
# Keeps the machine awake for as long as the Claude Code process that ran this hook is alive.
# Runs once per session start; a second start for the same Claude process (e.g. /clear) reuses the lock.
# Always prints one status line for the user and exits 0, so it can never block a session.

root="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}"

report() {
  local result="${1:-error: no output}" msg
  if [ "$result" = ok ]; then
    msg="jaagte-raho: keeping this computer awake while this session runs"
  else
    msg="jaagte-raho: could not keep this computer awake (${result#error: }). Run /jaagte-raho:status"
  fi
  msg=${msg//[\"\\]/}
  printf '{"systemMessage":"%s"}\n' "$msg"
  exit 0
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    report "$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root/scripts/awake.ps1" | tr -d '\r' | tail -n1)" ;;
esac

# Walk up the process tree to the Claude process (native binary "claude", or "node" for npm installs).
pid=$$
while [ "${pid:-0}" -gt 1 ]; do
  comm=$(ps -o comm= -p "$pid")
  case "${comm##*/}" in claude|node) break ;; esac
  pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
done
[ "${pid:-0}" -gt 1 ] || report "error: Claude process not found"

. "$root/scripts/lockdir.sh"
[ -n "$dir" ] || report "error: no private directory for lock files"
base="$dir/jaagte-raho-$pid"
[ -f "$base.pid" ] && kill -0 "$(cat "$base.pid")" 2>/dev/null && report ok

case "$(uname -s)" in
  Darwin)
    hold=(caffeinate -i -w "$pid") ;;
  Linux)
    command -v systemd-inhibit >/dev/null || report "error: systemd-inhibit not found"
    hold=(systemd-inhibit --what=idle:sleep --who="Claude Code" --why="Claude Code session running (jaagte-raho)"
          tail --pid="$pid" -f /dev/null) ;;
  *) report "error: unsupported OS $(uname -s)" ;;
esac

# No inherited stdio, so Claude doesn't wait on the background holder before continuing.
( "${hold[@]}"; rm -f "$base.pid" ) </dev/null >/dev/null 2>"$base.log" &
holder=$!
echo "$holder" > "$base.pid"

# Holders that can't take the lock (no permission, no logind) exit almost immediately.
sleep 1
if ! kill -0 "$holder" 2>/dev/null; then
  reason=$(head -n1 "$base.log" 2>/dev/null)
  report "error: ${reason:-holder exited}"
fi
report ok
