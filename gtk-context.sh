#!/usr/bin/env bash
# gtk-context — GTK context switcher for Taskwarrior
#
# Usage: gtk-context
#
# Shows all defined contexts as a radiolist with the current context
# pre-selected. Selecting a context activates it; selecting (none) clears it.

source "${HOME}/.task/scripts/tw-gtk.sh" || exit 1

# ── Gather contexts ───────────────────────────────────────────────────────────
current=$(task rc.hooks=off _get rc.context 2>/dev/null)

mapfile -t ctx_names < <(_gtk_contexts)

if [[ ${#ctx_names[@]} -eq 0 ]]; then
    yad --info \
        --title="Taskwarrior" \
        --text="No contexts defined.\n\nDefine one in ~/.taskrc:\n  context.work.read = +work" \
        --width=380 2>/dev/null
    exit 0
fi

width=$(_gtk_cfg gtk.context-width 500)

# ── Build radiolist rows ──────────────────────────────────────────────────────
# Format: TRUE/FALSE  name  filter-preview
rows=()

# (none) row — selected if no active context
if [[ -z "$current" ]]; then
    rows+=(TRUE "(none)" "— no filter —")
else
    rows+=(FALSE "(none)" "— no filter —")
fi

for name in "${ctx_names[@]}"; do
    filter=$(task rc.hooks=off _get "rc.context.${name}.read" 2>/dev/null)
    [[ -z "$filter" ]] && filter=$(task rc.hooks=off _get "rc.context.${name}" 2>/dev/null)
    [[ -z "$filter" ]] && filter="(no filter)"

    if [[ "$name" == "$current" ]]; then
        rows+=(TRUE "$name" "$filter")
    else
        rows+=(FALSE "$name" "$filter")
    fi
done

# ── Show dialog ───────────────────────────────────────────────────────────────
chosen=$(yad --list --radiolist \
    --title="Context" \
    --text="Current: <b>${current:-(none)}</b>" \
    --enable-markup \
    --no-headers \
    --width="$width" --height=$(( 100 + (${#ctx_names[@]} + 1) * 36 )) \
    --column=":CHK" --column="Context" --column="Filter" \
    --print-column=2 \
    "${rows[@]}" \
    --button="Apply:0" --button="Cancel:1" 2>/dev/null) || exit 0

chosen="${chosen%%|*}"
[[ -z "$chosen" ]] && exit 0

# ── Apply ─────────────────────────────────────────────────────────────────────
if [[ "$chosen" == "(none)" ]]; then
    task context none 2>/dev/null
    gtk_notify "Context cleared"
else
    task context "$chosen" 2>/dev/null
    gtk_notify "Context: $chosen"
fi
