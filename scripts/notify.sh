#!/usr/bin/env bash
# Pings you on Slack or Discord (an incoming webhook) when a long run finishes or Claude has been waiting
# for your input too long. Started in the background by the hooks in awake.sh, so it never slows
# Claude down:
#   notify.sh finished <base> <seconds it ran>     the turn ended (sent if it ran >= NOTIFY_AFTER)
#   notify.sh stalled <base> <since epoch s>       sleeps STALL_AFTER, then sends if still waiting
#   notify.sh test | status | off                  /jaagte-raho:notify
#   notify.sh connect slack|discord, then save    set it up: save reads the URL from the clipboard
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

# --- Connecting: /jaagte-raho:notify connect slack|discord, then save ---
# Slack's "create app from manifest" link: name jaagte-raho, only the incoming-webhook scope.
slack_new_app="https://api.slack.com/apps?new_app=1&manifest_json=%7B%22display_information%22%3A%7B%22name%22%3A%22jaagte-raho%22%2C%22description%22%3A%22Pings%20you%20when%20a%20Claude%20Code%20run%20finishes%20or%20waits%20for%20your%20input%22%2C%22background_color%22%3A%22%231d2333%22%7D%2C%22oauth_config%22%3A%7B%22scopes%22%3A%7B%22bot%22%3A%5B%22incoming-webhook%22%5D%7D%7D%2C%22settings%22%3A%7B%22org_deploy_enabled%22%3Afalse%2C%22socket_mode_enabled%22%3Afalse%2C%22token_rotation_enabled%22%3Afalse%7D%7D"

open_url() {
  [ -n "${JAAGTE_RAHO_NO_BROWSER:-}" ] && return 1   # tests
  case "$(uname -s)" in
    Darwin) open "$1" ;;
    MINGW*|MSYS*|CYGWIN*) powershell.exe -NoProfile -Command "Start-Process '$1'" ;;   # cmd's start breaks on &
    *) xdg-open "$1" >/dev/null 2>&1 ;;
  esac
}

clipboard() {
  if [ -n "${JAAGTE_RAHO_TEST_CLIPBOARD+x}" ]; then printf '%s\n' "$JAAGTE_RAHO_TEST_CLIPBOARD"; return; fi
  case "$(uname -s)" in
    Darwin) pbpaste ;;
    MINGW*|MSYS*|CYGWIN*) powershell.exe -NoProfile -Command Get-Clipboard ;;
    *) wl-paste 2>/dev/null || xclip -o -selection clipboard 2>/dev/null || xsel -b 2>/dev/null ;;
  esac
}

# Only real Slack or Discord webhook URLs (plus a local one, for tests or a self-hosted relay).
webhook_ok() {
  printf '%s' "$1" | grep -Eq \
    '^(https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+|https://((canary|ptb)\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+|http://(127\.0\.0\.1|localhost):[0-9]+/[A-Za-z0-9/_-]*)$'
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
  connect)
    case "$2" in
      slack)
        echo "Opening Slack in your browser, on a 'create app' page already filled in (name jaagte-raho, incoming webhooks)."
        echo "1. Log in and pick your workspace, then click Create."
        echo "2. Click Install to Workspace, choose the channel for the pings, and Allow."
        echo "3. Under Incoming Webhooks, click Copy next to the webhook URL."
        echo "4. Back here, run: /jaagte-raho:notify save   (it reads the URL from your clipboard)"
        open_url "$slack_new_app" || echo "Couldn't open a browser; open this link yourself: $slack_new_app" ;;
      discord)
        echo "In Discord (Discord can't link straight to these settings):"
        echo "1. Open the channel's settings (the gear next to its name), then Integrations, then Webhooks."
        echo "2. Click New Webhook, name it jaagte-raho, then Copy Webhook URL."
        echo "3. Back here, run: /jaagte-raho:notify save   (it reads the URL from your clipboard)" ;;
      *) echo "Usage: /jaagte-raho:notify connect slack   or   /jaagte-raho:notify connect discord" ;;
    esac ;;
  save)
    # Read the URL from the clipboard, so it's never typed into the chat or printed anywhere.
    new=$(clipboard | head -n1 | tr -d '\r[:space:]')
    if ! webhook_ok "$new"; then
      echo "Not saved: the clipboard doesn't hold a Slack or Discord webhook URL."
      echo "Copy it again (Slack: Incoming Webhooks > Copy; Discord: Copy Webhook URL), then run /jaagte-raho:notify save."
      exit 0
    fi
    mkdir -p "$conf" && (umask 077; printf '%s\n' "$new" > "$urlfile.tmp") && mv -f "$urlfile.tmp" "$urlfile" \
      || { echo "Couldn't write $urlfile"; exit 0; }
    url=$new
    case "$url" in */api/webhooks/*) service=Discord field=content ;; *) service=Slack field=text ;; esac
    echo "Saved your $service webhook in $urlfile (readable only by you)."
    [ -n "${JAAGTE_RAHO_NOTIFY_URL:-}" ] && echo "Note: JAAGTE_RAHO_NOTIFY_URL is set, and it takes precedence over this file."
    if send "jaagte-raho is connected: you'll get pings here $(where /nonexistent)"; then
      echo "Sent a test message: check your $service channel."
    else
      cat "$err"; rm -f "$err"
    fi ;;
  off)
    rm -f "$urlfile" && echo "Notifications: off (removed $urlfile)."
    [ -n "${JAAGTE_RAHO_NOTIFY_URL:-}" ] && echo "JAAGTE_RAHO_NOTIFY_URL is still set; unset it to stop pings." ;;
  test)
    if [ -z "$url" ]; then
      echo "Notifications: off. Connect with /jaagte-raho:notify connect slack (or discord)."
      exit 0
    fi
    if send "jaagte-raho test: notifications work $(where /nonexistent)"; then
      echo "Sent a test message to ${url%%/*}//$(printf '%s' "${url#*//}" | cut -d/ -f1)/…"
    else
      cat "$err"; rm -f "$err"   # shown here, so status needn't keep showing it
    fi ;;
  *)
    if [ -z "$url" ]; then
      echo "Notifications: off. Connect with /jaagte-raho:notify connect slack (or discord)."
    else
      echo "Notifications: on, to $service at $(printf '%s' "${url#*//}" | cut -d/ -f1) (from ${JAAGTE_RAHO_NOTIFY_URL:+JAAGTE_RAHO_NOTIFY_URL}${JAAGTE_RAHO_NOTIFY_URL:-$urlfile})"
      echo "Pings when a run that took $(mins "$after") or more finishes, and when Claude has waited $(mins "$stall") for your input."
    fi
    [ -s "$err" ] && echo "Last error: $(cat "$err")" ;;
esac
exit 0
