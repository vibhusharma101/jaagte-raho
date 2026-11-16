#!/usr/bin/env bash
# /jaagte-raho:lid on|off|status. The lid override: while Claude is working and the machine is
# plugged in, closing the lid doesn't sleep it. The switch is a file ($lidflag); every session's
# watcher checks it, so it applies to open sessions within seconds.

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/lockdir.sh"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) os=windows ;; Darwin) os=mac ;; *) os=linux ;; esac

ps1() {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$root/scripts/awake.ps1")" "$@" \
    -LidFlag "$(cygpath -w "$lidflag")" | tr -d '\r'
}

if [ "$os" = mac ]; then
  echo "The lid override isn't available on macOS yet: it needs admin rights (pmset disablesleep)."
  echo "Until then, a Mac stays awake with the lid closed only on power with an external display."
  exit 0
fi

case "$1" in
  on)
    # Check up front that this machine allows it, so "on" is never a silent no-op.
    if [ "$os" = linux ]; then
      err=$(systemd-inhibit --what=handle-lid-switch --who="Claude Code" --why="jaagte-raho self-check" true 2>&1) \
        || { echo "Can't turn the lid override on: ${err:-systemd-inhibit failed}"; exit 0; }
    elif [ "$(ps1 -Lid | head -n1)" = unknown ]; then
      echo "Can't turn the lid override on: the active power plan has no lid setting to change."; exit 0
    fi
    mkdir -p "$(dirname "$lidflag")" && : > "$lidflag" || { echo "Can't create $lidflag"; exit 0; }
    echo "Lid override: on (saved in $lidflag)."
    echo "While Claude is working and this machine is plugged in, closing the lid won't sleep it."
    echo "On battery the lid sleeps it as usual. Once Claude is done, the lid setting goes back to how it was." ;;
  off)
    rm -f "$lidflag"
    echo "Lid override: off. Closing the lid follows your OS setting again."
    if [ "$os" = windows ]; then
      sleep 3   # let running watchers let go first; then undo anything a crashed one left behind
      r=$(ps1 -RestoreLid | tail -n1)
      [ "$r" = ok ] || echo "Couldn't put the lid setting back: ${r#error: }"
    fi ;;
  *)
    [ -f "$lidflag" ] && echo "Lid override: on" || echo "Lid override: off (turn it on with /jaagte-raho:lid on)" ;;
esac

case "$os" in
  windows) ps1 -Lid | sed '1s/^/Lid action now: /' ;;
  linux) systemd-inhibit --list 2>/dev/null | grep -i "claude code" | grep -q handle-lid-switch \
           && echo "Right now: a session is keeping the lid from sleeping this machine" ;;
esac
exit 0
