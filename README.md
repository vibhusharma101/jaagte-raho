# jaagte-raho

*Hindi for "stay awake".* A Claude Code plugin that keeps your computer from going to sleep while Claude is working, and lets it sleep normally the moment Claude is idle.

Give Claude a long task and walk away: the work keeps going. Leave four finished sessions open overnight: the laptop still sleeps.

| What's happening                                     | Computer          |
|------------------------------------------------------|-------------------|
| Session open, nothing running                        | sleeps normally   |
| You sent a prompt, Claude is working                 | **kept awake**    |
| Claude finished, background agents/tasks still running | **kept awake**  |
| Claude finished, nothing in the background           | sleeps normally (within ~2 s) |
| You interrupted a turn (Esc)                          | sleeps normally (within ~60 s) |
| Claude exited or crashed                             | sleeps normally   |

With several sessions open, the computer stays awake while **any** of them is working.

## Install

```
/plugin marketplace add vibhusharma101/jaagte-raho
/plugin install jaagte-raho@jaagte-raho
```

Start a new session. No config, no admin rights, nothing else to install.

Every session start shows one line, so you always know whether it's working:

```
jaagte-raho: on. Keeps this computer awake while Claude is working, lets it sleep when idle
```

It only says that after checking this machine actually lets it take the lock. If it can't, it says so and why, instead of failing silently.

## Check status

```
/jaagte-raho:status
```

Lists every watched session, whether Claude is working in it, whether the lock is really held, any recent error, and what the OS itself reports. Paste this into bug reports.

## How it works

On `SessionStart`, a hook finds the Claude Code process and starts a small background watcher for the session. The watcher holds the OS keep-awake lock only while the session is marked busy:

| Hook                              | Effect                                                        |
|-----------------------------------|---------------------------------------------------------------|
| `UserPromptSubmit`                | mark busy                                                     |
| `Stop`                            | clear busy, unless its `background_tasks` list is non-empty   |
| `Notification` (`idle_prompt`)    | clear busy. Claude Code sends it ~60 s after a turn ends, only once no background agent is running, so it also covers interrupted turns |
| `SessionEnd`                      | stop the watcher                                              |

The hooks only create or delete a flag file, so prompts are never slowed down. What holds the machine awake while busy:

| OS      | Lock                                                   |
|---------|--------------------------------------------------------|
| macOS   | `caffeinate -i -w <claude pid>`                        |
| Linux   | `systemd-inhibit --what=idle:sleep`                    |
| Windows | `PowerSetRequest` (system + execution + display)       |

When Claude exits, normally or by crashing, the watcher exits and the OS releases the lock. Nothing is left holding your machine awake.

**Waiting for permission:** while Claude is waiting for you to approve a tool, the turn isn't over, so the computer stays awake. That's deliberate: if you approve from your phone via Remote Control, a sleeping laptop couldn't continue.

## Options

| Env var                 | Effect                                                                 |
|-------------------------|------------------------------------------------------------------------|
| `JAAGTE_RAHO_DISPLAY=0` | Windows: allow the screen to turn off. Saves battery, but on Modern Standby laptops (`powercfg /a` shows "S0 Low Power Idle") the screen turning off can put the machine into standby. |

## What it can't do

- **Closing the lid** follows your OS lid setting, not the idle timer. On Windows, set *Control Panel → Power Options → Choose what closing the lid does → Do nothing*. On macOS, the lid sleeps the Mac unless it's on power with an external display.
- **Cloud sessions** (claude.ai/code) run on Anthropic's servers and don't need your machine awake at all. This is for local sessions: terminal, IDE, Remote Control.
- **Battery.** It keeps the machine awake on battery until the session ends.

## Troubleshooting

| Message / status                         | Fix |
|------------------------------------------|-----|
| `Claude process not found`               | The hook couldn't find a `claude` or `node` process above it. Open an issue with your OS and how you launch Claude. |
| `no private directory for lock files` (Linux) | `$XDG_RUNTIME_DIR` isn't set and `/tmp/jaagte-raho-<uid>` exists but isn't yours. Remove it, or log in through a normal session so `$XDG_RUNTIME_DIR` is set. |
| `systemd-inhibit not found`              | Linux without systemd isn't supported yet. |
| `Access denied` (Linux)                  | Your session isn't allowed to inhibit sleep via polkit; usually happens over SSH. |
| `watcher did not start within 10s` (Windows) | PowerShell may be blocked by policy on your machine. Run `/jaagte-raho:status` and open an issue with the output. |
| Status shows `STALE`                     | A leftover file from a crashed watcher. Harmless; it holds nothing and is replaced on the next session start. |
| Stays awake after an interrupted turn    | Expected for ~60 s, until Claude Code sends `idle_prompt`. If it lasts longer, run `/jaagte-raho:status` and open an issue. |

## Requirements

- Claude Code with plugin support
- Windows: Git Bash (already required by Claude Code) and Windows PowerShell
- Linux: systemd

## Development

`tests/e2e.sh` runs a stand-in Claude process and walks a session through its whole life: idle (not held), prompt (held, and the OS reports it), turn ending with background tasks (still held), turn ending with none (released), `idle_prompt` (released), Claude exiting mid-turn and `SessionEnd` (watcher gone, lock released). CI runs it on Windows, macOS and Linux on every push.

Before each release, also do the one thing CI can't — a real sleep test on each OS:

1. `claude --plugin-dir /path/to/jaagte-raho`, confirm the status line.
2. `/jaagte-raho:status` right away: the session shows `Claude idle`, lock not held.
3. Give it a long task and leave the machine untouched past its sleep timeout. Come back: the task kept running.
4. Once it's finished and idle, leave it again: the machine goes to sleep.

## License

MIT
