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

| Command | What it does |
|---------|--------------|
| `/jaagte-raho:status` | Shows whether each session is keeping the computer awake, and why |
| `/jaagte-raho:lid on` / `off` | Windows and Linux: keep Claude working with the lid closed while plugged in ([details](#closing-the-lid)) |

## What it does

| What's happening                                       | Computer          |
|--------------------------------------------------------|-------------------|
| Session open, nothing running                          | sleeps normally   |
| You sent a prompt, Claude is working                   | **kept awake**    |
| Claude finished, background agents/tasks still running | **kept awake**    |
| Claude finished, nothing in the background             | sleeps normally (within ~2 s) |
| Claude finished, a scheduled run is due (`/loop`, cron job) | **kept awake** until the run, so it isn't skipped |
| Claude is waiting for your answer (permission prompt, question) | **kept awake** for 10 minutes, then sleeps normally |
| You interrupted a turn (Esc)                           | sleeps normally (within ~60 s) |
| Claude exited or crashed                               | sleeps normally   |
| Lid closed while Claude works, plugged in, `/jaagte-raho:lid on` (Windows, Linux) | **kept awake**, then your lid setting is put back |
| Lid closed on battery                                  | sleeps normally, even with the lid override on |

With several sessions open, the computer stays awake while **any** of them is working. Leave four finished sessions open overnight and the laptop still sleeps.

## Why not just `caffeinate`, Amphetamine or PowerToys Awake?

Those tools keep the machine awake until you turn them off, or for a fixed time. You have to guess how long Claude will take, and if you forget to turn them off, your battery pays for it.

jaagte-raho follows what Claude is actually doing:

- **Awake only while a turn is running**, including background agents and tasks that outlive the turn.
- **Sleeps again on its own** once Claude is idle, interrupted, or closed.
- **Safe if something crashes.** The lock is tied to the Claude process, so if Claude dies, the OS releases the lock. Nothing is left holding your machine awake.
- **Handles many sessions.** Each session holds its own lock.
- **Optionally keeps working with the lid closed** (Windows and Linux): only while plugged in and only while Claude works, then your lid setting goes back exactly as it was. `caffeinate -i` can't do that.
- **Same behaviour on macOS, Windows and Linux**, with nothing extra to install. The one exception is the lid override, which is Windows and Linux for now.

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
| `PostToolUse` (`CronCreate`, `CronDelete`, `ScheduleWakeup`) | note when the next scheduled run is due, or that it was cancelled |
| `Notification` (`idle_prompt`)    | clear busy. Claude Code sends it ~60 s after a turn ends, only once no background agent is running, so it also covers interrupted turns |
| `Notification` (`permission_prompt`, `elicitation_dialog`) | note that Claude is waiting for you; the lock is released once the grace period runs out |
| `SessionEnd`                      | stop the watcher                                              |

The hooks only create or delete a flag file, so prompts are never slowed down.

**Scheduled runs:** a sleeping computer doesn't run anything, so a `/loop` wakeup or a cron job that falls due while it sleeps is silently skipped. jaagte-raho keeps the computer awake while one is due:

- a `/loop` wakeup or one-shot job: until 15 minutes past its due time, so the run can start
- a recurring job: until you delete it, or it expires after 7 days
- durable jobs in the project's `.claude/scheduled_tasks.json`: while the file lists any and the session is open

`/jaagte-raho:status` shows when a session is being kept awake for a scheduled run. Like everything else, it ends when Claude exits.

What holds the machine awake:

| OS      | Lock                                                   |
|---------|--------------------------------------------------------|
| macOS   | `caffeinate -i -w <claude pid>`                        |
| Linux   | `systemd-inhibit --what=idle:sleep`                    |
| Windows | `PowerSetRequest` (system + execution + display)       |

When Claude exits, normally or by crashing, the watcher exits and the OS releases the lock.

**Waiting for your input:** when Claude stops to ask you something (a permission prompt or a question), nothing moves until you answer. jaagte-raho keeps the computer awake for 10 minutes in case you're nearby, then lets it sleep so a forgotten prompt doesn't drain the battery for hours. Once you answer, it's kept awake again. A scheduled run that's due still keeps it awake. If you approve prompts from your phone via Remote Control, set `JAAGTE_RAHO_INPUT_WAIT=never`, since a sleeping laptop can't receive your answer. `/jaagte-raho:status` shows when a session is waiting and when it may sleep.

## Options

| Env var                 | Effect                                                                 |
|-------------------------|------------------------------------------------------------------------|
| `JAAGTE_RAHO_INPUT_WAIT=<minutes>` | How long to stay awake while Claude waits for your input before letting the computer sleep. Default `10`. `never` keeps it awake until you answer (use this with Remote Control). |
| `JAAGTE_RAHO_DISPLAY=0` | Windows: allow the screen to turn off. Saves battery, but on Modern Standby laptops (`powercfg /a` shows "S0 Low Power Idle") the screen turning off can put the machine into standby. |

## Closing the lid

By default, closing the lid follows your OS setting, and that usually means sleep. On **Windows and Linux** you can switch on the lid override:

```
/jaagte-raho:lid on
```

From then on, while Claude is working **and the machine is plugged in**, closing the lid doesn't sleep it. It follows the same rules as the rest of jaagte-raho, so it lets go as soon as Claude is done. Your setting comes back exactly as it was:

- **On battery, the lid sleeps the machine as usual.** Unplug it and close the lid, and it sleeps, so it never runs closed in a bag. Still, a closed laptop running Claude gets warm: keep it on a hard surface.
- **Windows** changes only the *plugged in* lid action of your power plan to *Do nothing*, and saves the old value first. It puts the old value back when the last session that needed it is done, including after a crash or reboot (the next session does it). `/jaagte-raho:lid off` puts it back too. No admin rights needed.
- **Linux** adds `handle-lid-switch` to the same `systemd-inhibit` lock. The OS lifts it the moment the lock ends, so nothing can be left behind. It's dropped within seconds of unplugging.
- **macOS** isn't supported yet (it needs admin rights).

`/jaagte-raho:lid off` turns it off; `/jaagte-raho:lid` shows whether it's on and what closing the lid does right now. The switch is kept in `~/.config/jaagte-raho/lid` and survives a restart. On Windows, the saved original lid value sits next to it (`lid.orig`), outside the Temp folder, so disk cleanup can't delete it while the setting is changed.

## What it can't do

- **Closing the lid on a Mac.** jaagte-raho stops *idle* sleep only on macOS, like `caffeinate -i`: the lid sleeps a Mac unless it's on power with an external display (clamshell mode). Keeping a Mac awake with its lid closed needs admin rights (`pmset disablesleep`), which isn't supported yet. On Windows and Linux, see [Closing the lid](#closing-the-lid).
- **tmux won't help either.** tmux keeps programs running when the terminal or SSH connection goes away, not when the computer sleeps. A tmux on a remote server survives your laptop lid only because the server never sleeps.
- **Cloud sessions** (claude.ai/code) run on Anthropic's servers and don't need your machine awake at all. This is for local sessions: terminal, IDE, Remote Control.
- **Battery.** It keeps the machine awake on battery until Claude finishes, and while a scheduled run is due. An hourly cron job means staying awake until you delete it.

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
| `lid override: ...` error in status (Linux) | Your session isn't allowed to inhibit the lid switch via polkit. The idle lock still works. |
| Lid stays on *Do nothing* (Windows) | Run `/jaagte-raho:lid off`; it puts back the value it saved. |
| Stays awake after an interrupted turn    | Expected for ~60 s, until Claude Code sends `idle_prompt`. If it lasts longer, run `/jaagte-raho:status` and open an issue. |

## Requirements

- Claude Code with plugin support
- Windows: Git Bash (already required by Claude Code) and Windows PowerShell
- Linux: systemd

## Why the name

*Jaagte raho* is Hindi for "stay awake". It's the call of India's night watchmen as they walk their rounds. This plugin does the same job for your laptop, and only while Claude is working.

## Development

`tests/e2e.sh` runs a stand-in Claude process and walks a session through its whole life: idle (not held), prompt (held, and the OS reports it), turn ending with background tasks (still held), turn ending with none (released), `idle_prompt` (released), a permission prompt (held for the grace period, released after it, held again once answered), the lid override with two sessions (on while either works, put back only after the last, and after a crash), Claude exiting mid-turn and `SessionEnd` (watcher gone, lock released). CI runs it on Windows, macOS and Linux on every push.

Before each release, also do the one thing CI can't — a real sleep test on each OS:

1. `claude --plugin-dir /path/to/jaagte-raho`, confirm the status line.
2. `/jaagte-raho:status` right away: the session shows `Claude idle`, lock not held.
3. Give it a long task and leave the machine untouched past its sleep timeout. Come back: the task kept running.
4. Once it's finished and idle, leave it again: the machine goes to sleep.

Issues and PRs welcome, especially support for Linux without systemd.

## License

MIT
