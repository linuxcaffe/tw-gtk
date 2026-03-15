#!/usr/bin/env bash
# tw-gtk.sh — GTK GUI library for Taskwarrior (powered by YAD)
#
# Source from extension scripts:
#   source "${HOME}/.task/scripts/tw-gtk.sh" || exit 1
#
# Requires: yad (sudo apt install yad), jq
# Install:  tw -I gtk
# Version:  0.1.0

# ── Guard against double-sourcing ────────────────────────────────────────────
[[ -n "${_TW_GTK_LOADED:-}" ]] && return 0
_TW_GTK_LOADED=1

# ── Backend check ─────────────────────────────────────────────────────────────
_GTK_READY=0
command -v yad &>/dev/null || {
    echo "[tw-gtk] yad not found — install with: sudo apt install yad" >&2
    _GTK_READY=1
}
command -v jq  &>/dev/null || {
    echo "[tw-gtk] jq not found  — install with: sudo apt install jq"  >&2
    _GTK_READY=1
}
[[ $_GTK_READY -eq 0 ]] || return 1

# ── Config ────────────────────────────────────────────────────────────────────
_GTK_RC="${HOME}/.task/config/gtk.rc"

_gtk_cfg() {
    # _gtk_cfg <key> [default]
    local key="$1" default="${2:-}"
    local val
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$_GTK_RC" 2>/dev/null \
        | head -1 | cut -d= -f2- \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//')
    echo "${val:-$default}"
}

# ── Colors (Pango foreground) ─────────────────────────────────────────────────
_GTK_COL_OVERDUE='#cc0000'   # red   — past due date
_GTK_COL_URGENT='#c07000'    # amber — high urgency (no due date)
_GTK_COL_ACTIVE=''           # bold  — currently started (no color override)

# ── Standard column spec for task lists ───────────────────────────────────────
# col 1 = UUID (hidden) — returned by --print-column=1; never displayed
_gtk_std_cols=(
    "--column=:HD"           # UUID  — hidden key
    "--column=ID:NUM"
    "--column=Description"
    "--column=Project"
    "--column=Due"
    "--column=P"             # priority (1 char)
    "--column=Urg:NUM"
    "--column=Tags"
)

# ── Internal task helpers ─────────────────────────────────────────────────────

_gtk_task() {
    # Hook-free mutation: fast, safe for reads/silent changes.
    task rc.hooks=off rc.confirmation=off rc.verbose=nothing "$@"
}

_gtk_task_hooked() {
    # Hook-aware mutation: spawns a terminal so interactive hooks get a /dev/tty.
    # Used when gtk.hooks=on in gtk.rc.
    # Falls back to _gtk_task() if no terminal emulator is found.
    local terminal
    terminal=$(_gtk_cfg gtk.terminal "${TERMINAL:-xterm}")

    if ! command -v "$terminal" &>/dev/null; then
        _gtk_task "$@"
        return
    fi

    # Write a temp script to avoid quoting issues with -e
    local tmpscript
    tmpscript=$(mktemp /tmp/gtk_hook_XXXXXX.sh)
    printf '#!/bin/bash\nexec task rc.confirmation=off rc.verbose=nothing %s\n' \
        "$(printf '%q ' "$@")" > "$tmpscript"
    chmod +x "$tmpscript"

    "$terminal" -e "$tmpscript" 2>/dev/null
    local ret=$?
    rm -f "$tmpscript"
    return $ret
}

_gtk_get() {
    # _gtk_get <uuid-or-id> <field>  → field value or empty
    task rc.hooks=off "$1" _get "$2" 2>/dev/null
}

_gtk_projects() {
    # Returns project list as YAD CBE combo string: "proj1!proj2!..."
    task rc.hooks=off _projects 2>/dev/null \
        | grep -v '^$' | sort -u | tr '\n' '!' | sed 's/!$//'
}

_gtk_contexts() {
    # Returns one context name per line (sorted); empty if none defined
    task rc.hooks=off show 2>/dev/null \
        | grep -E '^context\.[^.]+\.read' \
        | sed 's/^context\.\([^.]*\)\.read.*/\1/' \
        | sort -u
}

_gtk_escape_markup() {
    # Escape a string for safe use in Pango markup
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    echo "$s"
}

# ── Data pipeline ─────────────────────────────────────────────────────────────

_gtk_rows() {
    # Emit task data for YAD --list: one field per line, 8 fields per task.
    # Column order matches _gtk_std_cols exactly.
    # Args: Taskwarrior filter expression (default: +READY)
    local -a filter=("$@")
    [[ ${#filter[@]} -eq 0 ]] && filter=(+READY)

    local urgent_threshold
    urgent_threshold=$(_gtk_cfg gtk.urgent-hi 15)

    task rc.hooks=off rc.color=off "${filter[@]}" export 2>/dev/null \
    | jq -r \
        --arg overdue  "$_GTK_COL_OVERDUE" \
        --arg urgent   "$_GTK_COL_URGENT"  \
        --argjson uthr "$urgent_threshold" \
        '
        (now | strftime("%Y%m%d") | tonumber) as $today |
        .[] | select(.id > 0) |
        # Due date as integer YYYYMMDD for reliable comparison (no tz issues)
        (.due | if . then (.[0:8] | tonumber) else 0 end) as $due_num |
        (.start != null)                           as $is_active  |
        ($due_num > 0 and $due_num < $today)       as $is_overdue |
        ((.urgency // 0) >= $uthr)                 as $is_urgent  |
        # Pango-safe description with markup for status
        (.description
            | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
        ) as $safe |
        (if   $is_active   then "<b>\($safe)</b>"
         elif $is_overdue  then "<span foreground=\"\($overdue)\">\($safe)</span>"
         elif $is_urgent   then "<span foreground=\"\($urgent)\">\($safe)</span>"
         else $safe end)   as $markup |
        # Due date display: YYYY-MM-DD or empty
        (if .due then "\(.due[0:4])-\(.due[4:6])-\(.due[6:8])" else "" end) as $due_fmt |
        # Tags: lowercase only (skip virtual tags like PENDING, ACTIVE)
        ([(.tags // [])[] | select(test("^[a-z]"))] | join(" ")) as $tags |
        # One field per line — order must match _gtk_std_cols
        .uuid,
        (.id | tostring),
        $markup,
        (.project // ""),
        $due_fmt,
        (.priority // ""),
        ((.urgency // 0) | floor | tostring),
        $tags
        '
}

# ── Public API ────────────────────────────────────────────────────────────────

gtk_pick() {
    # Show task list; print UUID of selected task; return 1 if cancelled.
    #
    # Usage: gtk_pick [--title "..."] [--width N] [--height N]
    #                 [-- extra-yad-opts...] [filter-args...]
    #
    # Example:
    #   uuid=$(gtk_pick +READY --title "Pick a task") || exit 0

    local title width height
    title=$(_gtk_cfg  gtk.title       "Taskwarrior")
    width=$(_gtk_cfg  gtk.list-width  900)
    height=$(_gtk_cfg gtk.list-height 600)
    local -a filter_args=() yad_extra=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title)  title="$2";  shift 2 ;;
            --width)  width="$2";  shift 2 ;;
            --height) height="$2"; shift 2 ;;
            --)       shift; yad_extra=("$@"); break ;;
            *)        filter_args+=("$1"); shift ;;
        esac
    done
    [[ ${#filter_args[@]} -eq 0 ]] && filter_args=(+READY)

    # Header: context + filter + counts
    local ctx_name ctx_read_raw="" header_text
    ctx_name=$(task _get rc.context 2>/dev/null)
    [[ -n "$ctx_name" ]] && \
        ctx_read_raw=$(task rc.hooks=off _get "rc.context.${ctx_name}.read" 2>/dev/null)
    local -a ctx_fargs=()
    [[ -n "$ctx_read_raw" ]] && read -ra ctx_fargs <<< "$ctx_read_raw"
    local total ctx_count shown
    total=$(task rc.hooks=off rc.context= rc.verbose=nothing +PENDING count 2>/dev/null || true)
    [[ -n "$ctx_name" ]] && \
        ctx_count=$(task rc.hooks=off rc.context= rc.verbose=nothing \
                        "${ctx_fargs[@]}" +PENDING count 2>/dev/null || true)
    shown=$(task rc.hooks=off rc.context= rc.verbose=nothing \
                "${ctx_fargs[@]}" "${filter_args[@]}" count 2>/dev/null || true)
    local -a hdr_parts=()
    if [[ -n "$ctx_name" ]]; then
        hdr_parts+=("<b>$(_gtk_escape_markup "$ctx_name")</b> (${ctx_count:-?}/${total:-?})")
        hdr_parts+=("<b>$(_gtk_escape_markup "${filter_args[*]}")</b> (${shown:-?}/${ctx_count:-?})")
    else
        hdr_parts+=("<b>$(_gtk_escape_markup "${filter_args[*]}")</b> (${shown:-?}/${total:-?})")
    fi
    header_text=$(_gtk_build_header "${hdr_parts[@]}")

    local raw
    raw=$(_gtk_rows "${ctx_fargs[@]}" "${filter_args[@]}" \
        | yad --list \
            --title="$title" \
            --text="$header_text" \
            --width="$width" --height="$height" \
            --enable-markup \
            --search-column=3 \
            --print-column=1 \
            "${_gtk_std_cols[@]}" \
            --button="OK:0" --button="Cancel:1" \
            "${yad_extra[@]}" 2>/dev/null) || return 1

    # YAD appends the column separator; strip it
    printf '%s' "${raw%%|*}"
}

gtk_pick_multi() {
    # Like gtk_pick but allows multiple selection.
    # Prints one UUID per line; return 1 if cancelled.

    local title width height
    title=$(_gtk_cfg  gtk.title       "Taskwarrior")
    width=$(_gtk_cfg  gtk.list-width  900)
    height=$(_gtk_cfg gtk.list-height 600)
    local -a filter_args=() yad_extra=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title)  title="$2";  shift 2 ;;
            --width)  width="$2";  shift 2 ;;
            --height) height="$2"; shift 2 ;;
            --)       shift; yad_extra=("$@"); break ;;
            *)        filter_args+=("$1"); shift ;;
        esac
    done
    [[ ${#filter_args[@]} -eq 0 ]] && filter_args=(+READY)

    local raw
    raw=$(_gtk_rows "${filter_args[@]}" \
        | yad --list \
            --title="$title" \
            --width="$width" --height="$height" \
            --enable-markup \
            --search-column=3 \
            --print-column=1 \
            --multiple \
            "${_gtk_std_cols[@]}" \
            --button="OK:0" --button="Cancel:1" \
            "${yad_extra[@]}" 2>/dev/null) || return 1

    # --multiple returns "uuid1|uuid2|" — split to one UUID per line
    echo "$raw" | tr '|' '\n' | grep -v '^$'
}

gtk_form_add() {
    # Show add-task form; print UUID of created task; return 1 if cancelled.
    #
    # Usage: gtk_form_add [desc=...] [proj=...] [due=...] [sched=...] [pri=H|M|L] [tags=...]
    #
    # Date fields accept any Taskwarrior date expression: tomorrow, friday, 2w, 2026-03-20

    local desc="" proj="" due="" sched="" pri="" tags=""
    for arg in "$@"; do
        case "$arg" in
            desc=*)  desc="${arg#desc=}"  ;;
            proj=*)  proj="${arg#proj=}"  ;;
            due=*)   due="${arg#due=}"    ;;
            sched=*) sched="${arg#sched=}";;
            pri=*)   pri="${arg#pri=}"    ;;
            tags=*)  tags="${arg#tags=}"  ;;
        esac
    done

    local projects
    projects=$(_gtk_projects)

    local result
    result=$(yad --form \
        --title="Add Task" \
        --width="$(_gtk_cfg gtk.form-width 500)" \
        --field="Description" \
        --field="Project:CBE" \
        --field="Due  (e.g. tomorrow, fri, 2w)" \
        --field="Scheduled" \
        --field="Priority" \
        --field="Tags  (space-separated)" \
        "$desc" \
        "${proj}${projects:+!$projects}" \
        "$due" "$sched" \
        "$pri" \
        "$tags" \
        --button="Add Task:0" --button="Cancel:1" 2>/dev/null) || return 1

    local new_desc new_proj new_due new_sched new_pri new_tags
    IFS='|' read -r new_desc new_proj new_due new_sched new_pri new_tags \
        <<< "$result"

    [[ -n "$new_desc" ]] || return 1

    # rc.hooks=off intentionally omitted — on-add hooks should fire (auto-priority etc.)
    local -a cmd=(task rc.confirmation=off add "$new_desc")
    [[ -n "$new_proj" ]]                         && cmd+=("project:${new_proj}")
    [[ -n "$new_due" ]]                          && cmd+=("due:${new_due}")
    [[ -n "$new_sched" ]]                        && cmd+=("scheduled:${new_sched}")
    [[ -n "$new_pri" && "$new_pri" != " " ]]     && cmd+=("priority:${new_pri}")
    if [[ -n "$new_tags" ]]; then
        for tag in $new_tags; do cmd+=("+$tag"); done
    fi

    "${cmd[@]}" >/dev/null 2>&1 || return 1

    # Return UUID of the just-created task (read-only — hooks=off correct here)
    task rc.hooks=off +LATEST _get uuid 2>/dev/null
}

gtk_form_modify() {
    # Show pre-populated modify form for a task; return 0 on success.
    #
    # Usage: gtk_form_modify <uuid>

    local uuid="$1"

    # Fetch current values
    local desc proj due sched pri
    desc=$(_gtk_get  "$uuid" description)
    proj=$(_gtk_get  "$uuid" project)
    due=$(_gtk_get   "$uuid" due)
    sched=$(_gtk_get "$uuid" scheduled)
    pri=$(_gtk_get   "$uuid" priority)

    # Format TW dates (20260312T000000Z) → YYYY-MM-DD for display in form
    [[ -n "$due" ]]   && due="${due:0:4}-${due:4:2}-${due:6:2}"
    [[ -n "$sched" ]] && sched="${sched:0:4}-${sched:4:2}-${sched:6:2}"

    # Lowercase tags only (skip virtual: PENDING, ACTIVE, READY, etc.)
    local tags
    tags=$(task rc.hooks=off "$uuid" export 2>/dev/null \
        | jq -r '.[0].tags // [] | [.[] | select(test("^[a-z]"))] | join(" ")')

    local projects
    projects=$(_gtk_projects)

    local result
    result=$(yad --form \
        --title="Modify Task" \
        --width="$(_gtk_cfg gtk.form-width 500)" \
        --field="Description" \
        --field="Project:CBE" \
        --field="Due" \
        --field="Scheduled" \
        --field="Priority" \
        --field="Tags  (space-separated)" \
        "$desc" \
        "${proj}${projects:+!$projects}" \
        "$due" "$sched" \
        "$pri" \
        "$tags" \
        --button="Save:0" --button="Cancel:1" 2>/dev/null) || return 1

    local new_desc new_proj new_due new_sched new_pri new_tags
    IFS='|' read -r new_desc new_proj new_due new_sched new_pri new_tags \
        <<< "$result"

    [[ -n "$new_desc" ]] || return 1

    local -a cmd=(task rc.hooks=off rc.confirmation=off "$uuid" modify)

    # Description
    [[ "$new_desc" != "$desc" ]]   && cmd+=("$new_desc")
    # Date/project fields: pass always so empty value clears the field in TW
    [[ "$new_proj"  != "$proj"  ]] && cmd+=("project:${new_proj}")
    [[ "$new_due"   != "$due"   ]] && cmd+=("due:${new_due}")
    [[ "$new_sched" != "$sched" ]] && cmd+=("scheduled:${new_sched}")
    [[ "$new_pri"   != "$pri"   ]] && cmd+=("priority:${new_pri}")

    # Tags: diff old vs new — add new, remove dropped
    local -a old_arr new_arr
    read -ra old_arr <<< "$tags"
    read -ra new_arr <<< "$new_tags"
    for tag in "${new_arr[@]}"; do
        [[ " ${old_arr[*]} " == *" $tag "* ]] || cmd+=("+$tag")
    done
    for tag in "${old_arr[@]}"; do
        [[ " ${new_arr[*]} " == *" $tag "* ]] || cmd+=("-$tag")
    done

    "${cmd[@]}" >/dev/null 2>&1
}

gtk_action() {
    # Show radiolist of actions for a task; print chosen action; return 1 if cancelled.
    #
    # Usage: gtk_action <uuid> [action ...]
    # Default actions: start stop done modify annotate delete
    # Pass custom list to override: gtk_action "$uuid" start done modify

    local uuid="$1"
    shift
    local -a actions=("${@:-start stop done modify annotate delete}")

    local tid desc safe
    tid=$(_gtk_get "$uuid" id)
    desc=$(_gtk_get "$uuid" description)
    safe=$(_gtk_escape_markup "$desc")

    # Build context line: project · due · priority · tags
    local proj due pri urg tags info_parts=()
    proj=$(_gtk_get "$uuid" project)
    due=$(_gtk_get  "$uuid" due)
    pri=$(_gtk_get  "$uuid" priority)
    urg=$(_gtk_get  "$uuid" urgency)
    tags=$(task rc.hooks=off rc.verbose=nothing "$uuid" export 2>/dev/null \
        | jq -r '.[0].tags // [] | [.[] | select(test("^[a-z]"))] | join(" ")')
    [[ -n "$proj" ]] && info_parts+=("proj:<b>${proj}</b>")
    [[ -n "$due"  ]] && info_parts+=("due:<b>${due:0:10}</b>")
    [[ -n "$pri"  ]] && info_parts+=("pri:<b>${pri}</b>")
    [[ -n "$urg"  ]] && info_parts+=("urg:$(printf '%.1f' "$urg")")
    [[ -n "$tags" ]] && info_parts+=("tags:<i>${tags}</i>")
    local meta_line
    printf -v meta_line '%s' "$(IFS='  ·  '; echo "${info_parts[*]}")"

    local text_body="<b>${safe}</b>"
    [[ ${#info_parts[@]} -gt 0 ]] && text_body+="\n<small>${meta_line}</small>"

    # Build radiolist rows: FALSE "label" per action
    local -a rows=()
    for action in "${actions[@]}"; do
        rows+=(FALSE "$action")
    done

    local raw
    raw=$(yad --list --radiolist \
        --title="Task ${tid:-?}" \
        --text="${text_body}" \
        --enable-markup \
        --no-headers \
        --width=420 --height="$(( 110 + ${#actions[@]} * 36 ))" \
        --column=":CHK" --column="Action" \
        --print-column=2 \
        "${rows[@]}" \
        --button="OK:0" --button="Cancel:1" 2>/dev/null) || return 1

    printf '%s' "${raw%%|*}"
}

gtk_info() {
    # Show a full task info dialog (read-only).
    #
    # Usage: gtk_info <uuid>

    local uuid="$1"
    local json
    json=$(task rc.hooks=off rc.color=off "$uuid" export 2>/dev/null) || return 1

    local tid
    tid=$(echo "$json" | jq -r '.[0].id')

    local text
    text=$(echo "$json" | jq -r '
        .[0] |

        def fdate: if . then "\(.[0:4])-\(.[4:6])-\(.[6:8])" else null end;
        def fdatetime: if . then "\(.[0:4])-\(.[4:6])-\(.[6:8]) \(.[9:11]):\(.[11:13])" else null end;
        def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");

        [
          # ── Description (large, bold) ────────────────────────────────────
          "<span size=\"large\" weight=\"bold\">" + (.description | esc) + "</span>",
          "",

          # ── Core identifiers ─────────────────────────────────────────────
          ("<b>ID:</b>  " + (.id | tostring)
           + "   <b>Status:</b>  " + .status
           + "   <b>Urgency:</b>  " + ((.urgency // 0) * 10 | round / 10 | tostring)),

          # ── Project / Priority ───────────────────────────────────────────
          (if .project  then "<b>Project:</b>   " + (.project | esc) else empty end),
          (if .priority then "<b>Priority:</b>  " + (.priority | tostring) else empty end),
          "",

          # ── Dates ────────────────────────────────────────────────────────
          (if .due       then "<b>Due:</b>        " + (.due       | fdate) else empty end),
          (if .scheduled then "<b>Scheduled:</b>  " + (.scheduled | fdate) else empty end),
          (if .wait      then "<b>Wait:</b>       " + (.wait      | fdate) else empty end),
          (if .until     then "<b>Until:</b>      " + (.until     | fdate) else empty end),
          (if .start     then "<b>Active since:</b>  " + (.start  | fdatetime) else empty end),

          # ── Tags ─────────────────────────────────────────────────────────
          (if ([ (.tags // [])[] | select(test("^[a-z]")) ] | length) > 0 then
            "<b>Tags:</b>  +"
            + ([ (.tags // [])[] | select(test("^[a-z]")) ] | join("  +"))
          else empty end),
          "",

          # ── Housekeeping ─────────────────────────────────────────────────
          "<b>Created:</b>   " + (.entry    | fdatetime),
          "<b>Modified:</b>  " + (.modified | fdatetime),

          # ── Recurrence ───────────────────────────────────────────────────
          (if .recur then
            "<b>Recurs:</b>  " + .recur
            + (if .rtype then "  <small>(" + .rtype + ")</small>" else "" end)
          else empty end),

          # ── Dependencies ─────────────────────────────────────────────────
          (if (.depends // [] | length) > 0 then
            "",
            "<b>Depends on:</b>  "
            + ([ .depends[] | .[0:8] ] | join(",  "))
          else empty end),

          # ── Annotations ──────────────────────────────────────────────────
          (if (.annotations // [] | length) > 0 then
            "",
            "<b>Annotations:</b>",
            (.annotations[]
              | "  <small>" + (.entry | fdatetime) + "</small>  " + (.description | esc))
          else empty end),

          # ── UUID (footer) ────────────────────────────────────────────────
          "",
          "<small><span foreground=\"#888888\">" + .uuid + "</span></small>"

        ] | join("\n")
    ')

    local width
    width=$(_gtk_cfg gtk.info-width 520)

    yad --info \
        --title="Task ${tid}" \
        --text="$text" \
        --enable-markup \
        --width="$width" \
        --button="Close:0" 2>/dev/null
}

gtk_confirm() {
    # Yes/no confirmation dialog; return 0 (yes) or 1 (no/cancel).
    #
    # Usage: gtk_confirm <message> [<uuid>]
    # With uuid, shows the task description as context below the message.

    local msg="$1"
    local uuid="${2:-}"
    local text
    text=$(_gtk_escape_markup "$msg")

    if [[ -n "$uuid" ]]; then
        local desc
        desc=$(_gtk_escape_markup "$(_gtk_get "$uuid" description)")
        text="${text}\n\n<b>${desc}</b>"
    fi

    yad --question \
        --title="Taskwarrior" \
        --text="$text" \
        --enable-markup \
        --width=400 \
        --button="Yes:0" --button="No:1" 2>/dev/null
}

gtk_notify() {
    # Non-blocking desktop notification.
    # Uses notify-send if available; falls back to a self-closing YAD dialog.
    #
    # Usage: gtk_notify <message>

    local msg="$1"
    if command -v notify-send &>/dev/null; then
        notify-send \
            --app-name="Taskwarrior" \
            --expire-time=4000 \
            "Taskwarrior" "$msg" &
    else
        yad --info \
            --title="Taskwarrior" \
            --text="$(_gtk_escape_markup "$msg")" \
            --enable-markup \
            --width=320 \
            --timeout=4 \
            --no-focus 2>/dev/null &
        disown
    fi
}

gtk_progress() {
    # Run a command with a pulsing progress bar; return the command's exit code.
    #
    # Usage: gtk_progress <title> <command> [args...]
    # The command's stdout is suppressed (stderr is preserved for diagnostics).

    local title="$1"
    shift

    # Run command silently; echo 100 at the end to trigger YAD --auto-close
    { "$@" >/dev/null; echo 100; } \
    | yad --progress --pulsate --auto-close --auto-kill \
        --title="$title" \
        --width=400 \
        --text="Please wait…" \
        --button="Cancel:1" 2>/dev/null

    return "${PIPESTATUS[0]}"
}

# ── Private helper used by gtk-task.sh ────────────────────────────────────────

_gtk_annotate() {
    # Show annotation entry for a task.
    # Usage: _gtk_annotate <uuid>

    local uuid="$1"
    local tid desc safe
    tid=$(_gtk_get "$uuid" id)
    desc=$(_gtk_get "$uuid" description)
    safe=$(_gtk_escape_markup "$desc")

    local text
    text=$(yad --entry \
        --title="Annotate Task ${tid:-?}" \
        --text="Add annotation to:\n<b>${safe}</b>" \
        --enable-markup \
        --width=500 2>/dev/null) || return 1

    [[ -n "$text" ]] || return 1
    _gtk_task "$uuid" annotate "$text"
}

# ── Report generation / cache ─────────────────────────────────────────────────

_GTK_REPORT_CACHE="${HOME}/.task/config/.gtk_reports.json"

# Fixed jq program for dynamic report rendering.
# Caller passes:  --argjson cols '["id","markup","project",...]'
# Outputs one field per line per task: uuid, then one value per col key.
# Unknown keys fall back to getpath([k]) for UDA fields.
_GTK_REPORT_JQ='
(now | strftime("%Y%m%d") | tonumber) as $today |
def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
def fdate: if . then "\(.[0:4])-\(.[4:6])-\(.[6:8])" else "" end;
def fdatetime: if . then "\(.[0:4])-\(.[4:6])-\(.[6:8]) \(.[9:11]):\(.[11:13])" else "" end;
def age_str(t):
  (now - t) as $s |
  if   $s < 0         then "future"
  elif $s < 90        then "\($s|round)s"
  elif $s < 5400      then "\($s/60|round)m"
  elif $s < 172800    then "\($s/3600|round)h"
  elif $s < 1209600   then "\($s/86400|round)d"
  elif $s < 5184000   then "\($s/86400/7|round)w"
  else "\($s/86400/30|round)mo" end;
def tw_epoch: "\(.[0:4])-\(.[4:6])-\(.[6:8])T\(.[9:11]):\(.[11:13]):\(.[13:15])Z" | fromdate;
def due_epoch: (.due | if . then ("\(.[0:4])-\(.[4:6])-\(.[6:8])T00:00:00Z" | fromdate) else null end);
def col_val(k):
  if   k == "id"                then (.id | tostring)
  elif k == "markup"            then
    ((.start != null) as $act |
     (.due | if . then (.[0:8] | tonumber) else 0 end) as $dn |
     ($dn > 0 and $dn < $today) as $od |
     (.description | esc) as $s |
     if $act then "<b>\($s)</b>"
     elif $od then "<span foreground=\"#cc0000\">\($s)</span>"
     else $s end)
  elif k == "description"       then (.description | esc)
  elif k == "project"           then (.project // "")
  elif k == "due"               then (.due | fdate)
  elif k == "due.relative"      then (due_epoch | if . then age_str(.) else "" end)
  elif k == "scheduled"         then (.scheduled | fdate)
  elif k == "scheduled.relative" then (.scheduled | if . then ("\(.[0:4])-\(.[4:6])-\(.[6:8])T00:00:00Z" | fromdate | age_str(.)) else "" end)
  elif k == "wait"              then (.wait | fdate)
  elif k == "until"             then (.until | fdate)
  elif k == "entry"             then (.entry | fdate)
  elif k == "entry.age"         then (.entry    | if . then (tw_epoch | age_str(.)) else "" end)
  elif k == "modified"          then (.modified | fdate)
  elif k == "modified.age"      then (.modified | if . then (tw_epoch | age_str(.)) else "" end)
  elif k == "end"               then (.end | fdate)
  elif k == "start"             then (.start | fdatetime)
  elif k == "start.age"         then (.start    | if . then (tw_epoch | age_str(.)) else "" end)
  elif k == "priority"          then (.priority // "")
  elif k == "urgency"           then ((.urgency // 0) | floor | tostring)
  elif k == "tags"              then ([(.tags // [])[] | select(test("^[a-z]"))] | join(" "))
  elif k == "depends.count"     then ((.depends // []) | length | tostring)
  elif k == "depends.indicator" then (if ((.depends // []) | length) > 0 then "D" else "" end)
  elif k == "recur.indicator"   then (if .recur then "R" else "" end)
  elif k == "recur"             then (.recur // "")
  elif k == "start.active"      then (if .start then "A" else "" end)
  elif k == "annotations.count" then ((.annotations // []) | length | tostring)
  elif k == "status"            then (.status // "")
  elif k == "uuid"              then .uuid
  else (getpath([k]) | if . == null then "" elif type == "string" then . else tostring end)
  end;
.[] | select(.id > 0) |
.uuid,
($cols[] as $k | col_val($k))
'

_gtk_col_to_key() {
    # Map a TW report column spec → "jq_key|YAD_TYPE|display_label"
    # Returns empty for columns that should be silently skipped (raw numeric formats etc.)
    #
    # Also handles:
    #   - Format suffixes: .age / .relative / .formatted / .indicator etc.
    #   - UDA fields: fall through to dynamic jq getpath lookup
    local col="$1"
    local base="${col%%.*}"
    local suffix="${col#*.}"
    [[ "$suffix" == "$col" ]] && suffix=""  # no dot → no suffix

    # Skip raw/unusable formats
    case "$suffix" in
        epoch|julian|iso|countdown|remaining) return 0 ;;
    esac

    # Known column mappings
    case "$col" in
        id)                                        echo "id|NUM|ID" ;;
        description|description.desc|description.combined|description.truncated|description.truncated_count|description.oneline|description.count)
                                                   echo "markup|TEXT|Description" ;;
        project)                                   echo "project|TEXT|Project" ;;
        due|due.formatted)                         echo "due|TEXT|Due" ;;
        due.relative|due.age)                      echo "due.relative|TEXT|Due" ;;
        due.indicator)                             echo "due|TEXT|Due" ;;
        scheduled|scheduled.formatted)             echo "scheduled|TEXT|Scheduled" ;;
        scheduled.relative|scheduled.age)          echo "scheduled.relative|TEXT|Scheduled" ;;
        wait|wait.formatted)                       echo "wait|TEXT|Wait" ;;
        until|until.formatted)                     echo "until|TEXT|Until" ;;
        entry|entry.formatted)                     echo "entry|TEXT|Entry" ;;
        entry.age|entry.relative)                  echo "entry.age|TEXT|Age" ;;
        modified|modified.formatted)               echo "modified|TEXT|Modified" ;;
        modified.age|modified.relative)            echo "modified.age|TEXT|Modified" ;;
        end|end.formatted)                         echo "end|TEXT|End" ;;
        start|start.formatted)                     echo "start|TEXT|Started" ;;
        start.age|start.relative)                  echo "start.age|TEXT|Active" ;;
        start.active)                              echo "start.active|TEXT|A" ;;
        priority)                                  echo "priority|TEXT|P" ;;
        urgency)                                   echo "urgency|NUM|Urg" ;;
        tags|tags.list)                            echo "tags|TEXT|Tags" ;;
        depends|depends.list)                      echo "depends.count|NUM|Deps" ;;
        depends.count)                             echo "depends.count|NUM|Deps" ;;
        depends.indicator)                         echo "depends.indicator|TEXT|D" ;;
        recur|recur.formatted)                     echo "recur|TEXT|Recur" ;;
        recur.indicator)                           echo "recur.indicator|TEXT|R" ;;
        annotations|annotations.count)             echo "annotations.count|NUM|Ann" ;;
        status)                                    echo "status|TEXT|Status" ;;
        uuid)                                      echo "uuid|TEXT|UUID" ;;
        # UDA fields and unrecognised base fields: dynamic lookup
        *)
            # Skip virtual/internal TW fields
            case "$base" in
                imask|mask|parent|template|rtemplate|rtype|ranchor|rindex|rlast|rend|rscheduled|rwait|last|r)
                    return 0 ;;
            esac
            # UDA or other real field: dynamic jq lookup, display as string
            local label="${base^}"
            echo "${base}|TEXT|${label}" ;;
    esac
}

_gtk_sort_spec_to_jq() {
    # Convert a TW sort spec (e.g. "start-,priority-,edate+,urgency-") to a jq
    # sort_by() expression that can be applied to the raw export array.
    # Unknown fields are silently ignored.
    local sort_spec="$1"
    [[ -z "$sort_spec" ]] && { echo ""; return; }

    local -a keys=()
    IFS=',' read -ra specs <<< "$sort_spec"
    for spec in "${specs[@]}"; do
        spec="${spec// /}"
        [[ -z "$spec" ]] && continue
        local dir="${spec: -1}"
        local field="${spec%[-+]}"
        [[ "$dir" != "-" && "$dir" != "+" ]] && dir="+"

        local expr=""
        case "$field" in
            urgency)
                [[ "$dir" == "-" ]] \
                    && expr='((.urgency // 0) * -1)' \
                    || expr='(.urgency // 0)' ;;
            id)
                [[ "$dir" == "-" ]] \
                    && expr='(.id * -1)' \
                    || expr='(.id)' ;;
            priority)
                # H=0 M=1 L=2 ""=3 for descending (highest priority first)
                if [[ "$dir" == "-" ]]; then
                    expr='(if .priority == "H" then 0 elif .priority == "M" then 1 elif .priority == "L" then 2 else 3 end)'
                else
                    expr='(if .priority == "L" then 0 elif .priority == "M" then 1 elif .priority == "H" then 2 else 3 end)'
                fi ;;
            start)
                # start-: active (has start) first → 0; inactive → 1
                [[ "$dir" == "-" ]] \
                    && expr='(if .start then 0 else 1 end)' \
                    || expr='(if .start then 1 else 0 end)' ;;
            edate)
                # Effective date: due // scheduled // entry (string sort ascending)
                expr='(.due // .scheduled // .entry // "z")' ;;
            due)       expr='(.due // "z")' ;;
            scheduled) expr='(.scheduled // "z")' ;;
            entry)     expr='(.entry // "")' ;;
            modified)  expr='(.modified // "")' ;;
            project)   expr='(.project // "")' ;;
            description) expr='(.description // "")' ;;
            wait|until|end) expr="(.${field} // \"z\")" ;;
        esac
        [[ -n "$expr" ]] && keys+=("$expr")
    done

    if [[ ${#keys[@]} -eq 0 ]]; then
        echo ""
    else
        local joined
        printf -v joined '%s, ' "${keys[@]}"
        echo "sort_by([${joined%, }])"
    fi
}

_gtk_gen_report() {
    # Generate (or regenerate) one or more reports; writes to cache.
    # Usage: _gtk_gen_report name [name ...]
    local -a names=("$@")
    [[ ${#names[@]} -eq 0 ]] && { echo "[gtk] No report names given"; return 1; }

    # Load existing cache or start fresh
    local cache="{}"
    [[ -f "$_GTK_REPORT_CACHE" ]] && cache=$(< "$_GTK_REPORT_CACHE")

    local generated_any=0
    for name in "${names[@]}"; do
        echo "[gtk] Generating: $name"

        local cols_raw filter_raw sort_raw labels_raw
        cols_raw=$(task rc.hooks=off _get "rc.report.${name}.columns" 2>/dev/null)

        if [[ -z "$cols_raw" ]]; then
            echo "[gtk] Warning: no columns for report '$name' — skipping"
            continue
        fi

        filter_raw=$(task rc.hooks=off _get "rc.report.${name}.filter" 2>/dev/null)
        sort_raw=$(task   rc.hooks=off _get "rc.report.${name}.sort"   2>/dev/null)
        labels_raw=$(task rc.hooks=off _get "rc.report.${name}.labels" 2>/dev/null)

        # Build parallel arrays: yad column specs + jq key names
        local -a yad_cols=("--column=:HD")   # UUID always first (hidden)
        local -a cols_keys=()
        local -a label_arr=()
        local warned=""

        # Parse optional user labels (comma-separated, parallel to columns)
        IFS=',' read -ra label_arr <<< "$labels_raw"

        local idx=0
        IFS=',' read -ra col_specs <<< "$cols_raw"
        for spec in "${col_specs[@]}"; do
            spec="${spec// /}"
            local mapped
            mapped=$(_gtk_col_to_key "$spec")
            if [[ -z "$mapped" ]]; then
                warned="${warned:+$warned, }$spec"
                (( idx++ )) || true
                continue
            fi
            local key ytype label
            key="${mapped%%|*}"
            ytype=$(echo "$mapped" | cut -d'|' -f2)
            label=$(echo "$mapped" | cut -d'|' -f3)
            # User label takes precedence if present
            [[ -n "${label_arr[$idx]:-}" ]] && label="${label_arr[$idx]}"
            yad_cols+=("--column=${label}:${ytype}")
            cols_keys+=("$key")
            (( idx++ )) || true
        done

        [[ -n "$warned" ]] && echo "[gtk] Skipping columns: $warned"

        if [[ ${#cols_keys[@]} -eq 0 ]]; then
            echo "[gtk] Warning: no mappable columns for '$name' — skipping"
            continue
        fi

        local ts
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        local sort_jq
        sort_jq=$(_gtk_sort_spec_to_jq "$sort_raw")

        local yad_json cols_json
        yad_json=$(printf '%s\n' "${yad_cols[@]}"  | jq -R . | jq -s .)
        cols_json=$(printf '%s\n' "${cols_keys[@]}" | jq -R . | jq -s .)

        local entry
        entry=$(jq -n \
            --arg  filter   "$filter_raw" \
            --arg  sort     "$sort_raw" \
            --arg  sort_jq  "$sort_jq" \
            --arg  ts       "$ts" \
            --argjson yad_cols "$yad_json" \
            --argjson cols     "$cols_json" \
            '{filter:$filter, sort:$sort, sort_jq:$sort_jq, yad_cols:$yad_cols, cols:$cols, generated:$ts}')

        cache=$(echo "$cache" | jq --arg n "$name" --argjson e "$entry" '. + {($n): $e}')
        echo "[gtk] Cached: $name (${#cols_keys[@]} columns)"
        generated_any=1
    done

    if [[ $generated_any -eq 1 ]]; then
        mkdir -p "$(dirname "$_GTK_REPORT_CACHE")"
        echo "$cache" > "$_GTK_REPORT_CACHE"
        echo "[gtk] Saved $_GTK_REPORT_CACHE"
    fi
}

_gtk_build_header() {
    # Join pre-formatted Pango segments with a bullet separator.
    # Usage: _gtk_build_header "part1" "part2" ...
    local hdr=""
    for part in "$@"; do
        [[ -n "$hdr" ]] && hdr+="   ·   "
        hdr+="$part"
    done
    printf '%s' "$hdr"
}

# Action exit codes returned by _gtk_run_report / _gtk_show_list_buttons
_GTK_ACT_DONE=10
_GTK_ACT_DELETE=11
_GTK_ACT_START=12
_GTK_ACT_STOP=13
_GTK_ACT_INFO=14
_GTK_ACT_MODIFY=15
_GTK_ACT_ANNOTATE=16
_GTK_ACT_UNDO=17
_GTK_ACT_QUIT=1

_gtk_show_list_buttons() {
    # Show a YAD list with action footer buttons; return UUID on stdout + action as exit code.
    # Usage: _gtk_show_list_buttons row_data... -- title header_text search_col width height yad_col_specs...
    # The '--' sentinel separates row data from display options.
    # Prints selected UUID on stdout (empty if no row selected or global action like Undo).
    # Returns exit code = action (_GTK_ACT_* constant).

    local -a row_data=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        row_data+=("$1"); shift
    done
    [[ "$1" == "--" ]] && shift
    local title="${1:-Taskwarrior}"; shift
    local header_text="${1:-}";      shift
    local search_col="${1:-2}";      shift
    local width="${1:-900}";         shift
    local height="${1:-600}";        shift
    local -a yad_cols=("$@")

    # Use a temp helper script for --select-action to avoid quoting issues
    # (YAD splits the select-action string on whitespace before exec, so
    # 'bash -c "..." yad' approach fails. A script file has no quoting problems.)
    local _uuid_file _sel_script
    _uuid_file=$(mktemp /tmp/gtk_uuid_XXXXXX)
    _sel_script=$(mktemp /tmp/gtk_sel_XXXXXX)
    printf '#!/bin/sh\nprintf "%%s" "$1" > "%s"\n' "$_uuid_file" > "$_sel_script"
    chmod +x "$_sel_script"

    local raw
    raw=$(printf '%s\n' "${row_data[@]}" \
        | yad --list \
            --title="$title" \
            --text="$header_text" \
            --enable-markup \
            --search-column="$search_col" \
            --print-column=1 \
            --width="$width" --height="$height" \
            "${yad_cols[@]}" \
            --select-action="$_sel_script" \
            --button="_Done:${_GTK_ACT_DONE}" \
            --button="d_elete:${_GTK_ACT_DELETE}" \
            --button="_Start:${_GTK_ACT_START}" \
            --button="S_top:${_GTK_ACT_STOP}" \
            --button="_Info:${_GTK_ACT_INFO}" \
            --button="_Modify:${_GTK_ACT_MODIFY}" \
            --button="_Annotate:${_GTK_ACT_ANNOTATE}" \
            --button="_Undo:${_GTK_ACT_UNDO}" \
            --button="_Quit:${_GTK_ACT_QUIT}" \
            2>/dev/null)
    local ret=$?
    rm -f "$_sel_script"

    # Window-close (252) → caller treats as quit
    if [[ $ret -eq 252 ]]; then
        rm -f "$_uuid_file"
        return 1
    fi

    # Prefer --print-column result; fall back to --select-action temp file
    local uuid="${raw%%|*}"
    [[ -z "$uuid" && -s "$_uuid_file" ]] && uuid=$(< "$_uuid_file")
    rm -f "$_uuid_file"

    printf '%s' "$uuid"
    return $ret
}

_gtk_filter_list() {
    # Show a std-column task list with footer action buttons (filter mode).
    # Usage: _gtk_filter_list [filter-args...]
    # Prints selected UUID on stdout; returns exit code = action (_GTK_ACT_*).

    local -a filter_args=("$@")
    [[ ${#filter_args[@]} -eq 0 ]] && filter_args=(+READY)

    # Header: context + filter + counts
    local ctx_name ctx_read_raw=""
    ctx_name=$(task _get rc.context 2>/dev/null)
    [[ -n "$ctx_name" ]] && \
        ctx_read_raw=$(task rc.hooks=off _get "rc.context.${ctx_name}.read" 2>/dev/null)
    local -a ctx_fargs=()
    [[ -n "$ctx_read_raw" ]] && read -ra ctx_fargs <<< "$ctx_read_raw"
    local total ctx_count shown
    total=$(task rc.hooks=off rc.context= rc.verbose=nothing +PENDING count 2>/dev/null || true)
    if [[ -n "$ctx_name" ]]; then
        ctx_count=$(task rc.hooks=off rc.context= rc.verbose=nothing \
                        "${ctx_fargs[@]}" +PENDING count 2>/dev/null || true)
    fi
    shown=$(task rc.hooks=off rc.context= rc.verbose=nothing \
                "${ctx_fargs[@]}" "${filter_args[@]}" +PENDING count 2>/dev/null || true)
    local -a hdr_parts=()
    if [[ -n "$ctx_name" ]]; then
        hdr_parts+=("<b>$(_gtk_escape_markup "$ctx_name")</b> (${ctx_count:-?}/${total:-?})")
        hdr_parts+=("<b>$(_gtk_escape_markup "${filter_args[*]}")</b> (${shown:-?}/${ctx_count:-?})")
    else
        hdr_parts+=("<b>$(_gtk_escape_markup "${filter_args[*]}")</b> (${shown:-?}/${total:-?})")
    fi
    local header_text
    header_text=$(_gtk_build_header "${hdr_parts[@]}")

    # Collect row data
    local -a all_rows
    mapfile -t all_rows < <(_gtk_rows "${ctx_fargs[@]}" "${filter_args[@]}")

    local title width height
    title=$(_gtk_cfg gtk.title "Taskwarrior")
    width=$(_gtk_cfg  gtk.list-width  900)
    height=$(_gtk_cfg gtk.list-height 600)

    _gtk_show_list_buttons "${all_rows[@]}" \
        -- "$title" "$header_text" 3 "$width" "$height" \
        "${_gtk_std_cols[@]}"
}

_gtk_run_report() {
    # Show a cached report with action buttons in the footer.
    # Applies context explicitly (rc.hooks=off can suppress implicit context in TW 2.6).
    # Strips columns that are entirely empty for the current result set.
    # Applies the report's sort order via stored jq expression.
    #
    # Usage: _gtk_run_report <name> [extra-filter-args...]
    #
    # Prints selected UUID on stdout (empty for global actions like undo / no selection).
    # Returns exit code = action (see _GTK_ACT_* constants above).
    #   0/252 = window closed / double-click → treat as quit in caller
    #   1     = _Quit button

    local name="$1"; shift
    local -a extra_filter=("$@")

    [[ -f "$_GTK_REPORT_CACHE" ]] || {
        gtk_notify "No reports cached — run: tw -g --gen $name"
        return 1
    }

    local entry
    entry=$(jq -r --arg n "$name" '.[$n] // empty' "$_GTK_REPORT_CACHE")
    [[ -n "$entry" ]] || {
        gtk_notify "Report '$name' not cached — run: tw -g --gen $name"
        return 1
    }

    local filter sort_jq cols_json
    filter=$(echo   "$entry" | jq -r '.filter // ""')
    sort_jq=$(echo  "$entry" | jq -r '.sort_jq // ""')
    cols_json=$(echo "$entry" | jq -c '.cols')
    local -a cols_keys
    mapfile -t cols_keys < <(echo "$entry" | jq -r '.cols[]')
    local ncols=${#cols_keys[@]}
    local -a yad_cols
    mapfile -t yad_cols < <(echo "$entry" | jq -r '.yad_cols[]')

    # ── Build filter args ────────────────────────────────────────────────────
    local -a filter_args=()
    [[ -n "$filter" ]] && read -ra filter_args <<< "$filter"
    filter_args+=("${extra_filter[@]}")
    [[ ${#filter_args[@]} -eq 0 ]] && filter_args=(+PENDING)

    # ── Fetch and apply context explicitly ───────────────────────────────────
    # rc.hooks=off suppresses implicit context application in TW 2.6; work around it.
    local ctx_name ctx_read_raw=""
    ctx_name=$(task _get rc.context 2>/dev/null)
    [[ -n "$ctx_name" ]] && \
        ctx_read_raw=$(task rc.hooks=off _get "rc.context.${ctx_name}.read" 2>/dev/null)
    local -a ctx_fargs=()
    [[ -n "$ctx_read_raw" ]] && read -ra ctx_fargs <<< "$ctx_read_raw"

    # Full export filter: disable implicit context, add context filter + report filter
    local -a full_filter=("rc.context=" "${ctx_fargs[@]}" "${filter_args[@]}")

    # ── Counts for header ────────────────────────────────────────────────────
    local total ctx_count shown
    total=$(task rc.hooks=off rc.context= rc.verbose=nothing +PENDING count 2>/dev/null || true)
    if [[ -n "$ctx_name" ]]; then
        ctx_count=$(task rc.hooks=off rc.context= rc.verbose=nothing \
                        "${ctx_fargs[@]}" +PENDING count 2>/dev/null || true)
    fi
    shown=$(task rc.hooks=off rc.context= rc.verbose=nothing \
                "${ctx_fargs[@]}" "${filter_args[@]}" count 2>/dev/null || true)

    # ── Build header ─────────────────────────────────────────────────────────
    local filter_label="${extra_filter[*]:-$filter}"
    [[ -z "$filter_label" ]] && filter_label="${filter_args[*]}"
    local -a hdr_parts=()
    if [[ -n "$ctx_name" ]]; then
        hdr_parts+=("<b>$(_gtk_escape_markup "$ctx_name")</b> (${ctx_count:-?}/${total:-?})")
    fi
    if [[ -n "$ctx_name" ]]; then
        hdr_parts+=("<b>$(_gtk_escape_markup "$filter_label")</b> (${shown:-?}/${ctx_count:-?})")
    else
        hdr_parts+=("<b>$(_gtk_escape_markup "$filter_label")</b> (${shown:-?}/${total:-?})")
    fi
    local header_text
    header_text=$(_gtk_build_header "${hdr_parts[@]}")

    # ── Buffer rows (with sort if available) ─────────────────────────────────
    local raw_json
    raw_json=$(task rc.hooks=off rc.color=off "${full_filter[@]}" export 2>/dev/null)
    [[ -n "$sort_jq" ]] && raw_json=$(echo "$raw_json" | jq "$sort_jq" 2>/dev/null || echo "$raw_json")

    local -a all_rows
    mapfile -t all_rows < <(echo "$raw_json" | jq -r --argjson cols "$cols_json" "$_GTK_REPORT_JQ")

    local ntasks=0
    [[ ${#all_rows[@]} -gt 0 ]] && ntasks=$(( ${#all_rows[@]} / (ncols + 1) ))

    # ── Detect empty columns ──────────────────────────────────────────────────
    local -a keep=()
    for ((c=0; c<ncols; c++)); do keep[$c]=0; done
    for ((t=0; t<ntasks; t++)); do
        for ((c=0; c<ncols; c++)); do
            local li=$(( t * (ncols+1) + 1 + c ))
            [[ -n "${all_rows[$li]:-}" ]] && keep[$c]=1
        done
    done

    # ── Build filtered yad_cols; track description search column ─────────────
    local -a active_yad_cols=("${yad_cols[0]}")   # UUID hidden col always col 1
    local search_col=0
    local ycol_idx=1   # YAD is 1-indexed; col 1 = UUID (hidden)
    for ((c=0; c<ncols; c++)); do
        if [[ ${keep[$c]} -eq 1 ]]; then
            (( ycol_idx++ ))
            active_yad_cols+=("${yad_cols[$((c+1))]}")
            if [[ $search_col -eq 0 && \
                  ( "${cols_keys[$c]}" == "markup" || "${cols_keys[$c]}" == "description" ) ]]; then
                search_col=$ycol_idx
            fi
        fi
    done
    [[ $search_col -eq 0 ]] && search_col=2

    # ── Build filtered row data ───────────────────────────────────────────────
    local -a yad_data=()
    for ((t=0; t<ntasks; t++)); do
        local base=$(( t * (ncols+1) ))
        yad_data+=("${all_rows[$base]}")   # UUID
        for ((c=0; c<ncols; c++)); do
            [[ ${keep[$c]} -eq 1 ]] && yad_data+=("${all_rows[$((base+1+c))]}")
        done
    done

    # ── Show list + action buttons ────────────────────────────────────────────
    local title width height
    title=$(_gtk_cfg gtk.title "Taskwarrior — $name")
    width=$(_gtk_cfg  gtk.list-width  900)
    height=$(_gtk_cfg gtk.list-height 600)

    _gtk_show_list_buttons "${yad_data[@]}" \
        -- "$title" "$header_text" "$search_col" "$width" "$height" \
        "${active_yad_cols[@]}"
}
