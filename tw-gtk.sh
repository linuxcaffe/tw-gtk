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
    # Wrapper with safety rc overrides — use for mutations
    task rc.hooks=off rc.confirmation=off rc.verbose=nothing "$@"
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

    local raw
    raw=$(_gtk_rows "${filter_args[@]}" \
        | yad --list \
            --title="$title" \
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

    local -a cmd=(task rc.hooks=off add "$new_desc")
    [[ -n "$new_proj" ]]                         && cmd+=("project:${new_proj}")
    [[ -n "$new_due" ]]                          && cmd+=("due:${new_due}")
    [[ -n "$new_sched" ]]                        && cmd+=("scheduled:${new_sched}")
    [[ -n "$new_pri" && "$new_pri" != " " ]]     && cmd+=("priority:${new_pri}")
    if [[ -n "$new_tags" ]]; then
        for tag in $new_tags; do cmd+=("+$tag"); done
    fi

    "${cmd[@]}" >/dev/null 2>&1 || return 1

    # Return UUID of the just-created task
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
        --no-wrap \
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
