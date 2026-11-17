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
  . "$root/scripts/maclid.sh"

  # as_root <shell command>: run it as root. Passwordless sudo if this account already has it,
  # otherwise the macOS password dialog (commands run from Claude have no terminal for sudo).
  as_root() {
    if sudo -n true 2>/dev/null; then sudo -n sh -c "$1"
    else
      osascript -e "do shell script \"$1\" with administrator privileges with prompt \"jaagte-raho needs your password once, so it can switch Mac sleep off while Claude works with the lid closed, and back on when it's done.\"" >/dev/null
    fi
  }

  # The rule allows exactly two commands and nothing else. It's checked with visudo before it's
  # installed and again after (as root), and removed if that fails: a broken sudoers file would
  # break sudo for the whole Mac.
  install_rule() {
    local user tmp
    user=$(id -un)
    case "$user" in ''|*[!A-Za-z0-9._-]*) echo "Can't set up: unusual user name '$user'"; return 1 ;; esac
    tmp=$(mktemp "$dir/jaagte-raho-sudoers.XXXXXX") || return 1
    case "$tmp" in *[!A-Za-z0-9/._-]*) rm -f "$tmp"; echo "Can't set up: unusual temp path"; return 1 ;; esac
    printf '# Installed by jaagte-raho (/jaagte-raho:lid). Remove with /jaagte-raho:lid uninstall.\n%s ALL=(root) NOPASSWD: %s -a disablesleep 0, %s -a disablesleep 1\n' \
      "$user" "$PMSET" "$PMSET" > "$tmp"
    if ! /usr/sbin/visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; echo "Can't set up: the sudoers rule didn't validate"; return 1; fi
    as_root "/usr/bin/install -m 0440 -o root -g wheel $tmp $maclid_rule && /usr/sbin/visudo -cf $maclid_rule >/dev/null || { rm -f $maclid_rule; exit 1; }"
    local rc=$?
    rm -f "$tmp"
    [ "$rc" = 0 ] && maclid_allowed
  }

  case "$1" in
    setup)   # (re)install the rule, e.g. after it was removed by hand
      echo "Asking for your password to allow '$PMSET -a disablesleep 0|1' (only that) without one."
      install_rule && echo "Set up: $maclid_rule" || echo "Setup didn't finish (cancelled, or no permission)." ;;
    on)
      if ! maclid_allowed; then
        echo "One-time setup: asking for your password to allow '$PMSET -a disablesleep 0|1' (only that) without one."
        install_rule || { echo "Setup didn't finish (cancelled, or no permission), so the lid override stays off."; exit 0; }
        echo "Set up: $maclid_rule"
      fi
      mkdir -p "$(dirname "$lidflag")" && : > "$lidflag" || { echo "Can't create $lidflag"; exit 0; }
      echo "Lid override: on (saved in $lidflag)."
      echo "While Claude is working and this Mac is on power, closing the lid won't sleep it."
      echo "On battery it sleeps as usual. Once Claude is done, sleep goes back to how it was." ;;
    off|uninstall)
      rm -f "$lidflag"
      echo "Lid override: off. Closing the lid sleeps this Mac again."
      sleep 3   # let running watchers let go first; then undo anything a crashed one left behind
      maclid_locked maclid_restore_if_unused || echo "Couldn't put sleep back; run: sudo pmset -a disablesleep $(cat "$maclid_orig" 2>/dev/null || echo 0)"
      if [ "$1" = uninstall ] && [ -f "$maclid_rule" ]; then
        as_root "rm -f $maclid_rule" && echo "Removed $maclid_rule." || echo "Couldn't remove $maclid_rule (cancelled?)."
      fi ;;
    *)
      [ -f "$lidflag" ] && echo "Lid override: on" || echo "Lid override: off (turn it on with /jaagte-raho:lid on)"
      [ -f "$maclid_rule" ] && echo "Set up: $maclid_rule allows pmset disablesleep 0|1" ;;
  esac
  [ "$(maclid_get)" = 1 ] && echo "Right now: sleep is disabled (pmset disablesleep 1)" || echo "Right now: sleep is enabled"
  [ -f "$maclid_orig" ] && echo "Saved value to put back once Claude is done: disablesleep $(cat "$maclid_orig")"
  maclid_on_ac || echo "On battery: the lid override doesn't apply until it's plugged in"
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
