- Project: https://github.com/linuxcaffe/tw-gtk
- Issues:  https://github.com/linuxcaffe/tw-gtk/issues

# tw-gtk

A GTK GUI toolkit for Taskwarrior — browse, act on, and add tasks through native desktop dialogs.

---

## TL;DR

- `gtk-task` — browse any filter or named report in a resizable list; act on tasks with footer buttons
- `gtk-add` — quick-add form as a keyboard shortcut or panel button; hooks fire normally
- `gtk-context` — radiolist context switcher; shows current context pre-selected
- `gtk-triage` — urgency-sorted review loop; set priority, due date, project, or start/done each task in turn
- `gtk-active` — dashboard of running tasks with live elapsed time; stop or complete from the list
- Desktop notifications on task state changes via `on-modify_gtk-notify.sh`
- Two operating modes: hook-free (fast, default) and hook-aware (spawns a terminal for interactive hooks)
- Requires Taskwarrior 2.6.x, `yad`, and `jq`

---

## Why this exists

Taskwarrior's terminal interface is efficient for power users, but not always the right tool. Clicking a keyboard shortcut to log a task without switching focus, picking a context from a list rather than typing it, or glancing at a dashboard of running tasks — these are interactions that benefit from a graphical dialog.

YAD (Yet Another Dialog) provides native GTK dialogs from Bash. It handles lists, forms, radio buttons, confirmations, and progress bars. `tw-gtk.sh` wraps YAD with Taskwarrior-aware helpers so extensions can build on a consistent set of building blocks rather than duplicating the plumbing.

The bundled extensions cover the interactions that come up most often. The library is there if you want to build your own.

---

## What this means for you

You get a small set of purpose-built GTK dialogs that fit into your existing workflow — a panel button for quick capture, a keyboard shortcut to switch context, a triage loop when you need to work through your backlog. None of them replace the terminal; they complement it for the moments when a dialog is faster.

---

## Core concepts

**tw-gtk.sh** — the shared library. All extensions source this file. It provides task-list dialogs, form dialogs, notifications, and the two mutation paths described below.

**Hook-free path** — the default. Mutations (`done`, `start`, `stop`, etc.) run with `rc.hooks=off` for speed. Non-interactive hooks (timelog, recurrence, context tracking) won't fire on these actions.

**Hook-aware path** — enabled by `gtk.hooks=on` in `gtk.rc`. Mutations spawn a terminal emulator running the task command so that interactive hooks (subtask prompts, hledger-add, annotation prompts) get a real TTY.

**Report cache** — `gtk-task` can display any named Taskwarrior report (next, list, ready, custom) from a pre-generated JSON cache. Generate the cache with `gtk-task --gen`.

---

## Installation

### Option 1 — Install script

```bash
curl -fsSL https://raw.githubusercontent.com/linuxcaffe/tw-gtk/main/gtk.install -o gtk.install
bash gtk.install          # installs scripts, hook, and starter config
```

Installs to `~/.task/scripts/` and `~/.task/hooks/`. Creates `~/.task/config/gtk.rc` if absent.

### Option 2 — Via [awesome-taskwarrior](https://github.com/linuxcaffe/awesome-taskwarrior)

```bash
tw -I gtk
```

### Option 3 — Manual

```bash
SCRIPTS=~/.task/scripts
HOOKS=~/.task/hooks
BASE=https://raw.githubusercontent.com/linuxcaffe/tw-gtk/main

mkdir -p "$SCRIPTS" "$HOOKS"

# Library and extensions
for f in tw-gtk.sh gtk-task.sh gtk-add.sh gtk-context.sh gtk-triage.sh gtk-active.sh; do
    curl -fsSL "$BASE/$f" -o "$SCRIPTS/$f" && chmod +x "$SCRIPTS/$f"
done

# Notification hook
curl -fsSL "$BASE/on-modify_gtk-notify.sh" -o "$HOOKS/on-modify_gtk-notify.sh"
chmod +x "$HOOKS/on-modify_gtk-notify.sh"

# Config (skip if already present)
curl -fsSL "$BASE/gtk.rc" -o ~/.task/config/gtk.rc
```

Add to `~/.taskrc` to let Taskwarrior validate config keys:

```ini
include ~/.task/config/gtk.rc
```

Verify: `gtk-task --gen next && gtk-task`

---

## Configuration

`~/.task/config/gtk.rc` — created on first install, safe to edit:

```ini
# Window dimensions
gtk.list-width  = 900    # task list window
gtk.list-height = 600
gtk.form-width  = 520    # add/modify form
gtk.context-width = 500  # context switcher

# Task list display
gtk.title     = Taskwarrior
gtk.urgent-hi = 15       # urgency threshold for amber highlight

# Mutation mode
# off → fast hook-free path (default; rc.hooks=off)
# on  → spawns a terminal so interactive hooks get a real TTY
gtk.hooks = off

# Terminal to use when gtk.hooks=on (must accept: terminal -e script)
# gtk.terminal = xterm

# Notifications (on-modify_gtk-notify.sh)
gtk.notify         = on
gtk.notify-timeout = 4   # seconds
```

Per-task opt-out of notifications: add the `+nonotify` tag.

---

## Usage

### gtk-task — task browser

```bash
gtk-task                    # default: cached 'next' report (auto-generated on first run)
gtk-task list               # any cached report by name
gtk-task --gen next list    # generate or refresh named reports
gtk-task --gen              # refresh all cached reports

gtk-task +work              # filter mode: work-tagged tasks
gtk-task project:home       # filter mode: home project
gtk-task due:today +READY   # filter mode: multiple arguments
```

In the list, footer buttons act on the selected task: **Done**, **Start/Stop**, **Modify**, **Annotate**, **Delete**, **Info**, **Undo**. Active tasks are **bold**; overdue tasks are red; high-urgency tasks are amber.

### gtk-add — quick-add form

```bash
gtk-add                              # blank form
gtk-add proj=work due=friday         # pre-filled project and due date
gtk-add desc="Write release notes" pri=H
```

Fires a desktop notification on success. All `on-add` hooks run normally (hooks are not suppressed).

### gtk-context — context switcher

```bash
gtk-context
```

Shows all defined contexts as a radiolist with the current context pre-selected. Select `(none)` to clear. Confirm to apply.

### gtk-triage — urgency review loop

```bash
gtk-triage              # review +PENDING tasks, highest urgency first
gtk-triage +work        # triage only work-tagged tasks
```

For each task you select: set priority (H/M/L), set due date, assign project, start it, mark done, or skip. The list refreshes after each action.

### gtk-active — active task dashboard

```bash
gtk-active
```

Lists all `+ACTIVE` tasks with elapsed time. Actions: Stop, Done, Annotate. Exits with a notification if no tasks are active.

### Via the tw dispatcher

If you use the `tw` wrapper from awesome-taskwarrior:

```bash
tw -g                   # gtk-task (default report)
tw -g next              # gtk-task next report
tw -g --gen             # regenerate all cached reports
tw -g +work             # gtk-task filter mode
tw add                  # gtk-add
tw @_                   # gtk-context
tw triage               # gtk-triage
tw active               # gtk-active
```

---

## Example workflow

Starting the day:

1. `tw @_` — switch to the right context from a list
2. `tw -g` — open the task list; pick the first task and hit **Start**
3. Work. When done, hit **Done** — a desktop notification confirms it.
4. `tw -g` again for the next task.

Quick capture from a panel button bound to `gtk-add`:

1. Press keyboard shortcut → form appears
2. Type description, set project and due date
3. Click Add → notification: "Task added: Write release notes"
4. Back to work.

End of day triage:

1. `tw triage` — work through the backlog: set priorities, push due dates, skip anything that can wait

---

## Project status

Active development. The library API and config keys are stable. The report cache format may change in a future version.

---

## Further reading

- [awesome-taskwarrior](https://github.com/linuxcaffe/awesome-taskwarrior) — package manager; `tw -I gtk` install, `tw -u gtk` update

---

## Metadata

- License: MIT
- Language: Bash
- Requires: Taskwarrior 2.6.x, yad, jq
- Platforms: Linux (X11/Wayland with XWayland)
- Version: 1.2.2
