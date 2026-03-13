#!/usr/bin/env bash
# gtk-add — Quick-add task form (GTK)
#
# Usage: gtk-add [desc=...] [proj=...] [due=...] [sched=...] [pri=H|M|L] [tags=...]
#
# Examples:
#   gtk-add
#   gtk-add proj=work due=friday
#   gtk-add desc="Write release notes" proj=work pri=H
#
# Ideal as a keyboard shortcut or desktop panel button.

source "${HOME}/.task/scripts/tw-gtk.sh" || exit 1

uuid=$(gtk_form_add "$@") || exit 0

if [[ -n "$uuid" ]]; then
    desc=$(task rc.hooks=off "$uuid" _get description 2>/dev/null)
    gtk_notify "Added: ${desc}"
fi
