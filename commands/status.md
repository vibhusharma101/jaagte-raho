---
description: Check whether jaagte-raho is keeping this computer awake
allowed-tools: Bash(bash *scripts/status.sh*)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"`

Summarize the jaagte-raho status above for the user in a few lines: is this computer being kept awake right now, and if not, why. Name each session by its folder and last prompt, not only its ID. Each session has its own independent lock; never suggest the lock moves between sessions. The session running this command may show idle, because the check runs as part of the command itself; don't call that a fault. If something failed, point them to the Troubleshooting section of the jaagte-raho README.
