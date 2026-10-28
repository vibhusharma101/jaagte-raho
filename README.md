# jaagte-raho

*Hindi for "stay awake".* A Claude Code plugin that keeps your computer from going to sleep while a Claude Code session is running, and lets it sleep normally once the session ends.

Switch to another app or walk away from the laptop: the work keeps going.

## Install

```
/plugin marketplace add vibhusharma101/jaagte-raho
/plugin install jaagte-raho@jaagte-raho
```

Start a new session. No config, no admin rights, nothing else to install.

Every session start shows one line, so you always know whether it's working:

```
jaagte-raho: keeping this computer awake while this session runs
```

If it can't, it says so and why, instead of failing silently.

## Check status

```
/jaagte-raho:status
```

Lists every session holding the computer awake, whether the lock is really held, any recent error, and what the OS itself reports. Paste this into bug reports.

## How it works

On `SessionStart`, a hook finds the Claude Code process that started it and launches a small background watcher tied to that process:

| OS      | What holds the machine awake                                        |
|---------|---------------------------------------------------------------------|
| macOS   | `caffeinate -i -w <claude pid>`                                     |
| Linux   | `systemd-inhibit --what=idle:sleep`, until the Claude process exits |
| Windows | `PowerSetRequest` (system + execution + display), until the Claude process exits |

When Claude exits — normally or by crashing — the watcher exits and the OS releases the lock. Nothing is left holding your machine awake. One watcher per Claude process; `/clear` and resume reuse it.

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
| Status shows `STALE`                     | A leftover lock from a crashed watcher. Harmless; it's ignored and replaced on the next session start. |

## Requirements

- Claude Code with plugin support
- Windows: Git Bash (already required by Claude Code) and Windows PowerShell
- Linux: systemd

## Development

`tests/e2e.sh` runs a stand-in Claude process, fires the hook, checks the lock is held (including what the OS reports), kills the stand-in, and checks the lock is released. CI runs it on Windows, macOS and Linux on every push.

Before each release, also do the one thing CI can't — a real sleep test on each OS:

1. `claude --plugin-dir /path/to/jaagte-raho`, confirm the status line.
2. Give it a long task and leave the machine untouched past its sleep timeout.
3. Come back: the task kept running, and `/jaagte-raho:status` shows the lock.
4. Exit Claude, run the status command from a new session: the old lock is gone.

## License

MIT
