#!/usr/bin/env bash
# gtk-task — GTK task manager for Taskwarrior
#
# Usage: gtk-task [filter-args...]
#
# Examples:
#   gtk-task               # show +READY tasks
#   gtk-task +work         # show work-tagged tasks
#   gtk-task project:home  # show home project tasks
#   gtk-task due:today     # show tasks due today

source "${HOME}/.task/scripts/tw-gtk.sh" || exit 1

# ── Filter from args (default: +READY) ───────────────────────────────────────
declare -a FILTER=("${@:-+READY}")
TITLE="Taskwarrior — ${FILTER[*]}"

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do

    uuid=$(gtk_pick "${FILTER[@]}" --title "$TITLE") || break

    # Decide whether to offer start or stop based on active state
    is_active=$(_gtk_get "$uuid" start)
    if [[ -n "$is_active" ]]; then
        action_set="stop done modify annotate info delete"
    else
        action_set="start done modify annotate info delete"
    fi

    action=$(gtk_action "$uuid" $action_set) || continue

    tid=$(_gtk_get "$uuid" id)

    case "$action" in

        start)
            _gtk_task "$uuid" start
            gtk_notify "Started task ${tid}" ;;

        stop)
            _gtk_task "$uuid" stop
            gtk_notify "Stopped task ${tid}" ;;

        done)
            if gtk_confirm "Mark as done?" "$uuid"; then
                _gtk_task "$uuid" done
                gtk_notify "✓ Completed task ${tid}"
            fi ;;

        modify)
            gtk_form_modify "$uuid" && \
                gtk_notify "Modified task ${tid}" ;;

        annotate)
            _gtk_annotate "$uuid" && \
                gtk_notify "Annotated task ${tid}" ;;

        info)
            gtk_info "$uuid" ;;

        delete)
            if gtk_confirm "Delete this task?" "$uuid"; then
                _gtk_task "$uuid" delete
                gtk_notify "Deleted task ${tid}"
            fi ;;

    esac

done
