# tw-gtk

A GTK GUI library for [Taskwarrior](https://taskwarrior.org/), powered by [YAD](https://github.com/v1cont/yad).

Provides a reusable Bash library (`tw-gtk.sh`) and two ready-to-run extensions:

| Script | Purpose |
|--------|---------|
| `gtk-task.sh` | Browse and manage tasks: start, stop, done, modify, annotate, delete |
| `gtk-add.sh` | Quick-add form — ideal as a keyboard shortcut or panel button |

---

## Requirements

- `yad` — `sudo apt install yad`
- `jq` — `sudo apt install jq`
- Taskwarrior 2.6.x

## Install

```bash
tw -I gtk
```

Or standalone:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/linuxcaffe/tw-gtk/main/gtk.install)
```

---

## Usage

### gtk-task

```bash
gtk-task                  # show +READY tasks
gtk-task +work            # work-tagged tasks
gtk-task project:home     # home project
gtk-task due:today        # tasks due today
```

Select a task → choose an action (start/stop, done, modify, annotate, delete).
Active tasks show **bold**; overdue tasks show in red; high-urgency tasks in amber.

### gtk-add

```bash
gtk-add                                    # empty form
gtk-add proj=work due=friday               # pre-filled form
gtk-add desc="Write release notes" pri=H   # with description and priority
```

Fires a desktop notification on success (via `notify-send` or a self-closing YAD dialog).

---

## Configuration

`~/.task/config/gtk.rc` (created on first install):

```ini
gtk.list-width  = 900     # task list window width
gtk.list-height = 600     # task list window height
gtk.form-width  = 520     # add/modify form width
gtk.title       = Taskwarrior
gtk.urgent-hi   = 15      # urgency threshold for amber highlight
```

Include in `~/.taskrc` to let Taskwarrior validate keys:

```ini
include ~/.task/config/gtk.rc
```

---

## Library API (`tw-gtk.sh`)

Source in your own scripts:

```bash
source "${HOME}/.task/scripts/tw-gtk.sh" || exit 1
```

| Function | Description |
|----------|-------------|
| `gtk_pick [filter…]` | Task-list dialog → UUID |
| `gtk_pick_multi [filter…]` | Multi-select dialog → one UUID per line |
| `gtk_form_add [key=val…]` | Add-task form → UUID |
| `gtk_form_modify <uuid>` | Pre-populated modify form |
| `gtk_action <uuid> [actions…]` | Radiolist action chooser → action name |
| `gtk_confirm <msg> [uuid]` | Yes/No dialog → exit code |
| `gtk_notify <msg>` | Non-blocking desktop notification |
| `gtk_progress <title> <cmd> [args…]` | Pulsing progress bar while command runs |

All functions return 1 (or non-zero) on Cancel/close — use `|| continue` / `|| break` idiom.

---

## Writing an Extension

```bash
#!/usr/bin/env bash
source "${HOME}/.task/scripts/tw-gtk.sh" || exit 1

uuid=$(gtk_pick +work --title "Work tasks") || exit 0
action=$(gtk_action "$uuid" start done modify) || exit 0

case "$action" in
    start)  task "$uuid" start ;;
    done)   task "$uuid" done  ;;
    modify) gtk_form_modify "$uuid" ;;
esac
```

---

## Planned Extensions

- `gtk-context.sh` — context switcher
- `gtk-triage.sh` — urgency triage workflow
- `gtk-active.sh` — active-task dashboard

---

## License

MIT — see [awesome-taskwarrior](https://github.com/linuxcaffe/awesome-taskwarrior) registry.
