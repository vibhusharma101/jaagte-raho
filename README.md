# jaagte-raho

**Keep your computer awake while Claude Code is working, and only then.**

[![test](https://github.com/vibhusharma101/jaagte-raho/actions/workflows/test.yml/badge.svg)](https://github.com/vibhusharma101/jaagte-raho/actions/workflows/test.yml)
![macOS | Windows | Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

You give Claude a two-hour task and go get lunch. Twenty minutes later your laptop goes to sleep, and the task stops with it.

jaagte-raho is a Claude Code plugin that holds off sleep while Claude is working. When Claude finishes, the computer goes back to sleeping normally. No config, no admin rights, nothing to remember to switch off.

<!-- TODO: demo GIF here, e.g. ![demo](docs/demo.gif) -->

```
/plugin marketplace add vibhusharma101/jaagte-raho
/plugin install jaagte-raho@jaagte-raho
```

Start a new session and you're done.

## What it does

| What's happening                                       | Computer          |
|--------------------------------------------------------|-------------------|
| Session open, nothing running                          | sleeps normally   |
| You sent a prompt, Claude is working                   | **kept awake**    |
| Claude finished, background agents/tasks still running | **kept awake**    |
| Claude finished, nothing in the background             | sleeps normally (within ~2 s) |
| You interrupted a turn (Esc)                           | sleeps normally (within ~60 s) |
| Claude exited or crashed                               | sleeps normally   |

With several sessions open, the computer stays awake while **any** of them is working. Leave four finished sessions open overnight and the laptop still sleeps.

## Why not just `caffeinate`, Amphetamine or PowerToys Awake?

Those tools keep the machine awake until you turn them off, or for a fixed time. You have to guess how long Claude will take, and if you forget to turn them off, your battery pays for it.

jaagte-raho follows what Claude is actually doing:

- **Awake only while a turn is running**, including background agents and tasks that outlive the turn.
- **Sleeps again on its own** once Claude is idle, interrupted, or closed.
- **Safe if something crashes.** The lock is tied to the Claude process, so if Claude dies, the OS releases the lock. Nothing is left holding your machine awake.
- **Handles many sessions.** Each session holds its own lock.
- **Same behaviour on macOS, Windows and Linux**, with nothing extra to install.

## You can always see whether it's working

Every session start shows one line:

```
jaagte-raho: on. Keeps this computer awake while Claude is working, lets it sleep when idle
```

It only says that after checking that this machine actually lets it take the lock. If it can't, it says so and why, instead of failing silently.

For details, run:

```
/jaagte-raho:status
```

It lists every watched session by its folder and the start of your last prompt, whether Claude is working in it, whether the lock is really held, any recent error, and what the OS itself reports. Paste this into bug reports.

```
Session d4bca0fb (session-city): Claude working | watcher PID 37516 | AWAKE (lock held)
  folder: C:/Users/you/code/session-city
  last prompt (2m ago): "Redo the labels so they don't overlap when 25 sessions are running"
```

Each session holds its own lock; the computer stays awake while any one of them shows `AWAKE`.

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

When Claude exits, normally or by crashing, the watcher exits and the OS releases the lock.

**Waiting for permission:** while Claude is waiting for you to approve a tool, the turn isn't over, so the computer stays awake. That's deliberate: if you approve from your phone via Remote Control, a sleeping laptop couldn't continue.

## Options

| Env var                 | Effect                                                                 |
|-------------------------|------------------------------------------------------------------------|
| `JAAGTE_RAHO_DISPLAY=0` | Windows: allow the screen to turn off. Saves battery, but on Modern Standby laptops (`powercfg /a` shows "S0 Low Power Idle") the screen turning off can put the machine into standby. |

## What it can't do

- **Closing the lid** follows your OS lid setting, not the idle timer. On Windows, set *Control Panel → Power Options → Choose what closing the lid does → Do nothing*. On macOS, the lid sleeps the Mac unless it's on power with an external display.
- **Cloud sessions** (claude.ai/code) run on Anthropic's servers and don't need your machine awake at all. This is for local sessions: terminal, IDE, Remote Control.
- **Battery.** It keeps the machine awake on battery until Claude finishes.

## Troubleshooting

| Message / status                         | Fix |
|------------------------------------------|-----|
| `Claude process not found`               | The hook couldn't find a `claude` or `node` process above it. Open an issue with your OS and how you launch Claude. |
| `no private directory for lock files` (Linux) | `$XDG_RUNTIME_DIR` isn't set and `/tmp/jaagte-raho-<uid>` exists but isn't yours. Remove it, or log in through a normal session so `$XDG_RUNTIME_DIR` is set. |
| `systemd-inhibit not found`              | Linux without systemd isn't supported yet. |
| `Access denied` (Linux)                  | Your session isn't allowed to inhibit sleep via polkit; usually happens over SSH. |
| `watcher did not start within 10s` (Windows) | PowerShell may be blocked by policy on your machine. Run `/jaagte-raho:status` and open an issue with the output. |
| `Removed leftover files from N ended session(s)` | Files left by a watcher that crashed or was killed. They held nothing; status cleans them up. |
| A session shows no folder or prompt      | It started before you updated the plugin. Restart it (`/exit`, then `claude --continue`). |
| Stays awake after an interrupted turn    | Expected for ~60 s, until Claude Code sends `idle_prompt`. If it lasts longer, run `/jaagte-raho:status` and open an issue. |

## Requirements

- Claude Code with plugin support
- Windows: Git Bash (already required by Claude Code) and Windows PowerShell
- Linux: systemd

## Why the name

*Jaagte raho* is Hindi for "stay awake". It's the call of India's night watchmen as they walk their rounds. This plugin does the same job for your laptop, and only while Claude is working.

## Development

`tests/e2e.sh` runs a stand-in Claude process and walks a session through its whole life: idle (not held), prompt (held, and the OS reports it), turn ending with background tasks (still held), turn ending with none (released), `idle_prompt` (released), Claude exiting mid-turn and `SessionEnd` (watcher gone, lock released). CI runs it on Windows, macOS and Linux on every push.

Before each release, also do the one thing CI can't — a real sleep test on each OS:

1. `claude --plugin-dir /path/to/jaagte-raho`, confirm the status line.
2. `/jaagte-raho:status` right away: the session shows `Claude idle`, lock not held.
3. Give it a long task and leave the machine untouched past its sleep timeout. Come back: the task kept running.
4. Once it's finished and idle, leave it again: the machine goes to sleep.

Issues and PRs welcome, especially support for Linux without systemd.

## License

MIT
