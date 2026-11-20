---
description: Slack or Discord pings when a long run finishes or Claude waits for your input (status, or test)
argument-hint: status | test
allowed-tools: Bash(bash *scripts/notify.sh*)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" $ARGUMENTS`

Tell the user in a few lines what the output above says: whether notifications are on, to Slack or Discord, and when they ping. If they're off, explain how to turn them on: create a Slack incoming webhook (Slack app → Incoming Webhooks) or a Discord webhook (channel settings → Integrations → Webhooks), then put its URL on one line in the file named in the output, from their own terminal, e.g. `mkdir -p ~/.config/jaagte-raho && echo 'https://…' > ~/.config/jaagte-raho/notify-url && chmod 600 ~/.config/jaagte-raho/notify-url`. Then `/jaagte-raho:notify test`. Tell them not to paste the webhook URL into this chat: anyone with it can post to their channel. If a test failed, say why, and point them to the Troubleshooting section of the jaagte-raho README.
