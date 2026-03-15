#!/usr/bin/env bash
# on-modify_gtk-notify.sh — YAD popup notifications for task state changes
#
# Shows a brief undecorated popup when a task is completed, started, or stopped.
# Part of tw-gtk. Install with: tw -I gtk
#
# Disable per-task: add tag +nonotify
# Disable globally: set gtk.notify=off in ~/.task/config/gtk.rc

# ── Read hook input (required by TW on-modify protocol) ──────────────────────
IFS= read -r _old_json
IFS= read -r _new_json

# Must echo new task JSON back to TW on stdout — do this first, unconditionally
printf '%s\n' "$_new_json"

# ── Guard: display, tools, config ────────────────────────────────────────────
[[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || exit 0
command -v yad &>/dev/null            || exit 0
command -v jq  &>/dev/null            || exit 0

_GTK_RC="${HOME}/.task/config/gtk.rc"
_gtk_cfg() {
    local key="$1" default="${2:-}"
    local val
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$_GTK_RC" 2>/dev/null \
        | head -1 | cut -d= -f2- \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//')
    printf '%s' "${val:-$default}"
}

[[ "$(_gtk_cfg gtk.notify on)" == "off" ]] && exit 0

# ── Detect what changed ───────────────────────────────────────────────────────
_desc=$(      printf '%s' "$_new_json" | jq -r '.description // ""')
_tags=$(      printf '%s' "$_new_json" | jq -r '[.tags // [] | .[]] | join(" ")')
_old_status=$(printf '%s' "$_old_json" | jq -r '.status // ""')
_new_status=$(printf '%s' "$_new_json" | jq -r '.status // ""')
_old_start=$( printf '%s' "$_old_json" | jq -r '.start  // ""')
_new_start=$( printf '%s' "$_new_json" | jq -r '.start  // ""')

# Per-task opt-out
[[ "$_tags" == *nonotify* ]] && exit 0

_msg=""
if   [[ "$_old_status" != "completed" && "$_new_status" == "completed" ]]; then
    _msg="✓  ${_desc}"
elif [[ -z "$_old_start" && -n "$_new_start" ]]; then
    _msg="▶  ${_desc}"
elif [[ -n "$_old_start" && -z "$_new_start" ]]; then
    _msg="⏹  ${_desc}"
fi

[[ -n "$_msg" ]] || exit 0

# ── Show notification (non-blocking) ─────────────────────────────────────────
# Prefer notify-send (native desktop notifications — instant, no focus steal,
# no FD inheritance). Fall back to yad with explicit FD closure.
_timeout_ms=$(( $(_gtk_cfg gtk.notify-timeout 4) * 1000 ))

if command -v notify-send &>/dev/null; then
    notify-send -t "$_timeout_ms" -i dialog-information "Taskwarrior" "$_msg" \
        </dev/null >/dev/null 2>&1 &
else
    yad --timeout="$(( _timeout_ms / 1000 ))" --no-buttons --borders=14 \
        --text="$_msg" --title="Taskwarrior" \
        --skip-taskbar --undecorated \
        --timeout-indicator=top \
        </dev/null >/dev/null 2>/dev/null &
fi

exit 0
