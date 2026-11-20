#!/usr/bin/env bash
# Pings you on Slack or Discord (an incoming webhook) when a long run finishes or Claude has been waiting
# for your input too long. Started in the background by the hooks in awake.sh, so it never slows
# Claude down:
#   notify.sh finished <base> <seconds it ran>     the turn ended (sent if it ran >= NOTIFY_AFTER)
#   notify.sh stalled <base> <since epoch s>       sleeps STALL_AFTER, then sends if still waiting
#   notify.sh test | status                        /jaagte-raho:notify
# The webhook URL is a secret: it's read from $JAAGTE_RAHO_NOTIFY_URL or the file
# ~/.config/jaagte-raho/notify-url, never from a command argument. Nothing configured: does nothing.
# Errors go to <dir>/jaagte-raho-notify.err, which /jaagte-raho:status shows.

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/lockdir.sh"
conf="$(dirname "$lidflag")"
urlfile="$conf/notify-url"
url=${JAAGTE_RAHO_NOTIFY_URL:-$(head -n1 "$urlfile" 2>/dev/null | tr -d '\r[:space:]')}
err="$dir/jaagte-raho-notify.err"
# Discord or Slack, from the URL: Discord webhooks (https://discord.com/api/webhooks/...) take
# {"content": ...}; Slack incoming webhooks (https://hooks.slack.com/services/...) and the many
# Slack-compatible ones (Mattermost, Google Chat, ...) take {"text": ...}.
case "$url" in */api/webhooks/*) service=Discord field=content ;; *) service=Slack field=text ;; esac

# Minutes from an env var (default $2). An "s" suffix means seconds (used by the tests).
secs() {
  case "$1" in
    *s) n=${1%s}; case "$n" in ''|*[!0-9]*) echo $(( $2 * 60 )) ;; *) echo "$n" ;; esac ;;
    ''|*[!0-9]*) echo $(( $2 * 60 )) ;;
    *) echo $(( $1 * 60 )) ;;
  esac
}
after=$(secs "${JAAGTE_RAHO_NOTIFY_AFTER:-}" 10)
stall=$(secs "${JAAGTE_RAHO_STALL_AFTER:-}" 5)

mins() { local m=$(( ($1 + 30) / 60 )); [ "$m" -ge 1 ] && echo "$m min" || echo "$1 s"; }
esc() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# where <base>: "on <host> in <folder>: "<prompt start>""
where() {
  local folder task host
  folder=$(cat "$1.cwd" 2>/dev/null); folder=${folder%/}; folder=${folder##*/}
  task=$(cat "$1.task" 2>/dev/null)
  host=$(hostname 2>/dev/null); host=${host%%.*}
  printf 'on %s' "${host:-this computer}"
  [ -n "$folder" ] && printf ' in %s' "$folder"
  [ -n "$task" ] && printf ': "%s"' "$task"
}

send() {
  [ -n "$url" ] || return 0
  case "$url" in https://*|http://127.0.0.1:*|http://localhost:*) ;;
    *) echo "notify: the webhook URL must start with https://" > "$err"; return 1 ;;
  esac
  command -v curl >/dev/null || { echo "notify: curl not found" > "$err"; return 1; }
  local out
  if out=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
             --data-binary "{\"$field\":\"$(esc "$1")\"}" "$url" 2>&1) && [ "${out#2}" != "$out" ]; then
    rm -f "$err"
  else
    echo "notify: the webhook didn't accept the message (${out:-no response})" > "$err"
    return 1
  fi
}

case "$1" in
  finished)
    [ "${3:-0}" -ge "$after" ] 2>/dev/null || exit 0
    send "Claude finished after $(mins "$3") $(where "$2")" ;;
  stalled)
    sleep "$stall"
    # Still waiting on the same prompt: the watcher drops <base>.wait once you answer, and the
    # hooks drop it when the turn ends or a new prompt starts.
    since=; { read -r since _ < "$2.wait"; } 2>/dev/null
    [ "$since" = "$3" ] && [ -f "$2.busy" ] || exit 0
    send "Claude has been waiting for your input for $(mins "$(( $(date +%s) - since ))") $(where "$2")" ;;
  test)
    if [ -z "$url" ]; then
      echo "Notifications: off. Put a Slack or Discord webhook URL in $urlfile (or set JAAGTE_RAHO_NOTIFY_URL)."
      exit 0
    fi
    if send "jaagte-raho test: notifications work $(where /nonexistent)"; then
      echo "Sent a test message to ${url%%/*}//$(printf '%s' "${url#*//}" | cut -d/ -f1)/…"
    else
      cat "$err"; rm -f "$err"   # shown here, so status needn't keep showing it
    fi ;;
  *)
    if [ -z "$url" ]; then
      echo "Notifications: off. Put a Slack or Discord webhook URL in $urlfile (or set JAAGTE_RAHO_NOTIFY_URL)."
    else
      echo "Notifications: on, to $service at $(printf '%s' "${url#*//}" | cut -d/ -f1) (from ${JAAGTE_RAHO_NOTIFY_URL:+JAAGTE_RAHO_NOTIFY_URL}${JAAGTE_RAHO_NOTIFY_URL:-$urlfile})"
      echo "Pings when a run that took $(mins "$after") or more finishes, and when Claude has waited $(mins "$stall") for your input."
    fi
    [ -s "$err" ] && echo "Last error: $(cat "$err")" ;;
esac
exit 0
