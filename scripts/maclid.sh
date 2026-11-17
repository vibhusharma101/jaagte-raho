# Sourced (macOS). The lid override on a Mac: `pmset -a disablesleep 1` while a session needs it.
# That needs root, so /jaagte-raho:lid on installs a sudoers rule allowing exactly
# `/usr/bin/pmset -a disablesleep 0` and `... 1` without a password (see lid.sh).
#
# disablesleep is one setting for the whole Mac, shared by every session: the value found is saved
# once in lid.orig (next to the switch file), each session that needs the override marks <base>.lid,
# and whoever lets go last puts the saved value back. A watcher that finds a saved value with no live
# session behind it (after a crash or reboot) also puts it back, as does /jaagte-raho:lid off.
# Changes happen under a lock directory, so two sessions never save each other's value.
# Needs $dir and $lidflag (lockdir.sh); $base is this session's prefix, or empty.

PMSET=/usr/bin/pmset
maclid_orig="$(dirname "$lidflag")/lid.orig"
maclid_lock="$dir/jaagte-raho-lid.lock"
maclid_rule=/etc/sudoers.d/jaagte-raho

maclid_get() { $PMSET -g | awk '/SleepDisabled/ { print $2; exit }'; }
maclid_set() { sudo -n $PMSET -a disablesleep "$1" >/dev/null; }
maclid_allowed() {
  sudo -n -l $PMSET -a disablesleep 1 >/dev/null 2>&1 && sudo -n -l $PMSET -a disablesleep 0 >/dev/null 2>&1
}
maclid_on_ac() { $PMSET -g batt | head -n1 | grep -q "AC Power"; }

# The lid is closed and, with sleep allowed again, macOS says that should sleep it (no external
# display). Turning disablesleep off doesn't replay the lid-close, so sleep it ourselves.
maclid_sleep_if_closed() {
  local c
  c=$(ioreg -r -k AppleClamshellState -d 1 2>/dev/null)
  grep -q '"AppleClamshellState" = Yes' <<< "$c" && grep -q '"AppleClamshellCausesSleep" = Yes' <<< "$c" \
    && $PMSET sleepnow >/dev/null 2>&1
  return 0
}

maclid_locked() {   # maclid_locked <command...>: run it holding the lock
  local i p rc
  for i in $(seq 1 50); do
    if mkdir "$maclid_lock" 2>/dev/null; then
      echo $$ > "$maclid_lock/pid"
      "$@"; rc=$?
      rm -rf "$maclid_lock"
      return $rc
    fi
    p=$(cat "$maclid_lock/pid" 2>/dev/null)
    [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && rm -rf "$maclid_lock"   # its owner died
    sleep 0.2
  done
  echo "lid override: timed out waiting for $maclid_lock" >&2
  return 1
}

maclid_holders() {   # another live session has the override on
  local f p
  for f in "$dir"/jaagte-raho-*.lid; do
    [ -f "$f" ] || continue
    [ -n "${base:-}" ] && [ "$f" = "$base.lid" ] && continue
    p=$(cat "${f%.lid}.pid" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
    rm -f "$f"   # left by a watcher that's gone
  done
  return 1
}

maclid_restore_if_unused() {   # call under the lock
  local v
  [ -f "$maclid_orig" ] || return 0
  maclid_holders && return 0
  v=$(cat "$maclid_orig")
  case "$v" in
    0|1) maclid_set "$v" || { echo "lid override: couldn't put disablesleep back to $v (sudo -n pmset failed)" >&2; return 1; } ;;
  esac
  rm -f "$maclid_orig"
  [ "$v" = 0 ] && maclid_sleep_if_closed
  return 0
}

maclid_apply() {   # this session needs the override; call under the lock
  local v
  if [ ! -f "$maclid_orig" ]; then
    v=$(maclid_get); v=${v:-0}
    echo "$v" > "$maclid_orig"
    if [ "$v" != 1 ] && ! maclid_set 1; then
      rm -f "$maclid_orig"
      echo "lid override: sudo -n pmset -a disablesleep 1 failed; run /jaagte-raho:lid on to set it up" >&2
      return 1
    fi
  fi
  : > "$base.lid"
}

maclid_release() { rm -f "$base.lid"; maclid_restore_if_unused; }   # call under the lock
