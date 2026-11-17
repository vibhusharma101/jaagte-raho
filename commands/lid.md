---
description: Keep Claude working with the lid closed while plugged in (on, off, or status)
argument-hint: on | off | status | setup, uninstall (macOS)
allowed-tools: Bash(bash *scripts/lid.sh*)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/lid.sh" $ARGUMENTS`

Tell the user in a few lines what the output above says: whether the lid override is on or off, and what closing the lid does right now. It only works while Claude is working and the machine is plugged in; on battery the lid sleeps it as usual, and once Claude is done the lid setting goes back to how it was. On macOS, the first "on" asks for the password once to install a sudoers rule allowing only pmset disablesleep 0 and 1, "setup" reinstalls that rule, and "uninstall" removes it. If it couldn't be turned on, say why, and point them to the Troubleshooting section of the jaagte-raho README. If it's on, remind them that a laptop running with its lid closed gets warm: keep it on a hard surface, never in a bag.
