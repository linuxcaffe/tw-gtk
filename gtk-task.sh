#!/usr/bin/env bash
# gtk-task — GTK task manager for Taskwarrior
#
# Usage: gtk-task [--gen [name...] | report-name | filter-args...]
#
# Examples:
#   gtk-task                    # run default report (next) or +READY fallback
#   gtk-task next               # run cached 'next' report
#   gtk-task --gen next list    # generate/regenerate named reports
#   gtk-task --gen              # regenerate all cached reports
#   gtk-task +work              # filter mode: work-tagged tasks
#   gtk-task project:home       # filter mode: home project tasks

source "${HOME}/.task/scripts/tw-gtk.sh" || exit 1

# ── --gen flag: generate/regenerate reports and exit ─────────────────────────
if [[ "${1:-}" == "--gen" ]]; then
    shift
    if [[ $# -gt 0 ]]; then
        _gtk_gen_report "$@"
    else
        # Regenerate all currently cached reports
        if [[ -f "$_GTK_REPORT_CACHE" ]]; then
            mapfile -t _cached_names < <(jq -r 'keys[]' "$_GTK_REPORT_CACHE")
            if [[ ${#_cached_names[@]} -gt 0 ]]; then
                _gtk_gen_report "${_cached_names[@]}"
            else
                echo "[gtk] Cache is empty — specify report names: gtk-task --gen next list"
            fi
        else
            echo "[gtk] No cache found — specify report names: gtk-task --gen next list"
        fi
    fi
    exit 0
fi

# ── First-run bootstrap: auto-generate next + list if cache absent ────────────
if [[ ! -f "$_GTK_REPORT_CACHE" ]]; then
    echo "[gtk] First run — generating starter reports: next, list"
    echo "[gtk] To regenerate any report:  tw -g --gen <name> [name...]"
    echo "[gtk] To regenerate all:         tw -g --gen"
    _gtk_gen_report next list
fi

# ── Dispatch: report name, filter, or default ─────────────────────────────────
#
# No args → run 'next' from cache (TW default report).
# Single arg that matches a cached report name → run that report.
# Anything else → filter mode (existing gtk_pick behaviour).

_gtk_report_mode=""
_gtk_report_name=""

if [[ $# -eq 0 ]]; then
    # Default: try 'next' as a cached report
    if jq -e '.next' "$_GTK_REPORT_CACHE" &>/dev/null 2>&1; then
        _gtk_report_mode=report
        _gtk_report_name=next
    fi
elif [[ $# -eq 1 ]] && jq -e --arg n "$1" '.[$n]' "$_GTK_REPORT_CACHE" &>/dev/null 2>&1; then
    _gtk_report_mode=report
    _gtk_report_name="$1"
    shift
fi

# ── Report mode ───────────────────────────────────────────────────────────────
if [[ "$_gtk_report_mode" == "report" ]]; then
    while true; do
        uuid=$(_gtk_run_report "$_gtk_report_name" "$@")
        act=$?

        # Quit / window-close / no action
        [[ $act -eq $_GTK_ACT_QUIT || $act -eq 0 || $act -eq 252 ]] && break

        # Undo: global action, no task selection needed
        if [[ $act -eq $_GTK_ACT_UNDO ]]; then
            task rc.confirmation=off undo >/dev/null 2>&1 \
                && gtk_notify "Undo complete" \
                || gtk_notify "Nothing to undo"
            continue
        fi

        # All other actions need a selected task
        if [[ -z "$uuid" ]]; then
            gtk_notify "Select a task first"
            continue
        fi

        tid=$(_gtk_get "$uuid" id)

        case "$act" in
            "$_GTK_ACT_DONE")
                if gtk_confirm "Mark as done?" "$uuid"; then
                    _gtk_task "$uuid" done
                    gtk_notify "✓ Completed task ${tid}"
                fi ;;

            "$_GTK_ACT_DELETE")
                if gtk_confirm "Delete this task?" "$uuid"; then
                    _gtk_task "$uuid" delete
                    gtk_notify "Deleted task ${tid}"
                fi ;;

            "$_GTK_ACT_START")
                if [[ -n "$(_gtk_get "$uuid" start)" ]]; then
                    _gtk_task "$uuid" stop && gtk_notify "Stopped task ${tid}"
                else
                    _gtk_task "$uuid" start && gtk_notify "Started task ${tid}"
                fi ;;

            "$_GTK_ACT_STOP")
                _gtk_task "$uuid" stop && gtk_notify "Stopped task ${tid}" ;;

            "$_GTK_ACT_INFO")
                gtk_info "$uuid" ;;

            "$_GTK_ACT_MODIFY")
                gtk_form_modify "$uuid" && gtk_notify "Modified task ${tid}" ;;

            "$_GTK_ACT_ANNOTATE")
                _gtk_annotate "$uuid" && gtk_notify "Annotated task ${tid}" ;;
        esac
    done
    exit 0
fi

# ── Filter mode (default: +READY) ─────────────────────────────────────────────
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

    # Inner loop: info re-shows action dialog; any other action breaks out
    while true; do
        action=$(gtk_action "$uuid" $action_set) || { action=''; break; }
        [[ "$action" == "info" ]] || break
        gtk_info "$uuid"
    done
    [[ -n "$action" ]] || continue

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

        delete)
            if gtk_confirm "Delete this task?" "$uuid"; then
                _gtk_task "$uuid" delete
                gtk_notify "Deleted task ${tid}"
            fi ;;

    esac

done
