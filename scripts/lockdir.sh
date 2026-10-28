# Sourced by the other scripts. Sets $dir to a directory only the current user can write, for lock
# files, or to "" if no safe one exists. Never the shared /tmp: another user could plant files there.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) dir=$(cygpath -u "$TEMP") ;;
  Darwin) dir="${TMPDIR:-/tmp}"; dir=${dir%/} ;;   # macOS TMPDIR is already per-user
  *)
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
      dir=$XDG_RUNTIME_DIR
    else
      dir="/tmp/jaagte-raho-$(id -u)"
      mkdir -m 700 -p "$dir" 2>/dev/null || true
      { [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ]; } || dir=
    fi ;;
esac
