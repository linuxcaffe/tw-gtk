#!/usr/bin/env bash
# gtk-triage — Urgency-driven triage loop for Taskwarrior
#
# Usage: gtk-triage [filter-args...]
#
# Examples:
#   gtk-triage                 # triage all +PENDING tasks (highest urgency first)
#   gtk-triage project:work    # triage work project only
#   gtk-triage +next           # triage +next tasks
#
# For each selected task: set priority, due, project, start, done, or skip.

source "${HOME}/.task/scripts/tw-gtk.sh" || exit 1

# ── Filter from args (default: +PENDING) ─────────────────────────────────────
declare -a FILTER=("${@:-+PENDING}")
TITLE="Triage — ${FILTER[*]}"

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do

    uuid=$(gtk_pick "${FILTER[@]}" --title "$TITLE") || break

    action=$(gtk_action "$uuid" priority due project start done info skip) || continue

    tid=$(_gtk_get "$uuid" id)

    case "$action" in

        priority)
            cur_pri=$(_gtk_get "$uuid" priority)
            val=$(yad --entry \
                --title="Priority — Task ${tid}" \
                --text="Priority value (e.g. H, M, L, or your UDA values)" \
                --entry-text="$cur_pri" \
                --width=360 2>/dev/null) || continue
            [[ -n "$val" ]] || continue
            _gtk_task "$uuid" modify "priority:${val}"
            gtk_notify "Priority set to ${val}" ;;

        due)
            cur_due=$(_gtk_get "$uuid" due)
            [[ -n "$cur_due" ]] && cur_due="${cur_due:0:4}-${cur_due:4:2}-${cur_due:6:2}"
            val=$(yad --entry \
                --title="Due — Task ${tid}" \
                --text="Date expression (e.g. tomorrow, friday, 2w, 2026-04-01)" \
                --entry-text="$cur_due" \
                --width=420 2>/dev/null) || continue
            [[ -n "$val" ]] || continue
            _gtk_task "$uuid" modify "due:${val}"
            gtk_notify "Due set to ${val}" ;;

        project)
            cur_proj=$(_gtk_get "$uuid" project)
            projects=$(_gtk_projects)
            val=$(yad --form \
                --title="Project — Task ${tid}" \
                --width=380 \
                --field="Project:CBE" "${cur_proj}${projects:+!$projects}" \
                --button="Set:0" --button="Cancel:1" 2>/dev/null) || continue
            val="${val%%|*}"
            _gtk_task "$uuid" modify "project:${val}"
            gtk_notify "Project set to '${val}'" ;;

        start)
            _gtk_task "$uuid" start
            gtk_notify "Started task ${tid}" ;;

        done)
            if gtk_confirm "Mark as done?" "$uuid"; then
                _gtk_task "$uuid" done
                gtk_notify "✓ Completed task ${tid}"
            fi ;;

        info)
            gtk_info "$uuid" ;;

        skip)
            continue ;;

    esac

done
