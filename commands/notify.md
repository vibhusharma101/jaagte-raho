---
description: Slack or Discord pings when a long run finishes or Claude waits for your input (connect, save, test, off)
argument-hint: connect slack | connect discord | save | test | off | status
allowed-tools: Bash(bash *scripts/notify.sh*)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" $ARGUMENTS`

Tell the user in a few lines what the output above says. If it shows numbered steps (connect), repeat them clearly and tell them to run `/jaagte-raho:notify save` once they've copied the webhook URL. `save` reads the URL from the clipboard, so it never appears in this chat. If notifications are off, suggest `/jaagte-raho:notify connect slack` or `/jaagte-raho:notify connect discord`. Never ask the user to paste the webhook URL into this chat: anyone who has it can post to their channel. If they paste one anyway, don't repeat it; tell them to copy it and run `/jaagte-raho:notify save` instead, and to delete and recreate the webhook if this chat is shared. If something failed, say why, and point them to the Troubleshooting section of the jaagte-raho README.
