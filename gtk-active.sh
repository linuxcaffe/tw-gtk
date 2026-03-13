#!/usr/bin/env bash
# gtk-active — Active (started) task dashboard for Taskwarrior
#
# Usage: gtk-active
#
# Shows all currently started tasks with elapsed time.
# Actions: stop, done, annotate.

source "${HOME}/.task/scripts/tw-gtk.sh" || exit 1

# ── Custom column spec (replaces Due with Started + Elapsed) ──────────────────
_active_cols=(
    "--column=:HD"           # UUID  — hidden key
    "--column=ID:NUM"
    "--column=Description"
    "--column=Project"
    "--column=Started"
    "--column=Elapsed"
    "--column=Urg:NUM"
    "--column=Tags"
)

# ── Data pipeline ─────────────────────────────────────────────────────────────
_active_rows() {
    task rc.hooks=off rc.color=off +ACTIVE export 2>/dev/null \
    | jq -r '
        .[] |
        # Elapsed time from .start
        (.start | strptime("%Y%m%dT%H%M%SZ") | mktime) as $t0 |
        (now - $t0) as $secs |
        (($secs / 3600) | floor) as $h |
        (($secs % 3600 / 60) | floor) as $m |
        (($h | tostring) + "h " + ($m | tostring) + "m") as $elapsed |
        # Started display: YYYY-MM-DD HH:MM
        (.start | "\(.[0:4])-\(.[4:6])-\(.[6:8]) \(.[9:11]):\(.[11:13])") as $started |
        # Pango markup — all active tasks are bold
        (.description
            | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
        ) as $safe |
        "<b>\($safe)</b>" as $markup |
        # Tags: lowercase only
        ([(.tags // [])[] | select(test("^[a-z]"))] | join(" ")) as $tags |
        # One field per line — order matches _active_cols
        .uuid,
        (.id | tostring),
        $markup,
        (.project // ""),
        $started,
        $elapsed,
        ((.urgency // 0) | floor | tostring),
        $tags
        '
}

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do

    # Exit gracefully if nothing is active
    count=$(task rc.hooks=off +ACTIVE count 2>/dev/null)
    if [[ "${count:-0}" -eq 0 ]]; then
        gtk_notify "No active tasks"
        break
    fi

    width=$(_gtk_cfg  gtk.list-width  900)
    height=$(_gtk_cfg gtk.list-height 500)

    raw=$(_active_rows \
        | yad --list \
            --title="Active Tasks" \
            --width="$width" --height="$height" \
            --enable-markup \
            --search-column=3 \
            --print-column=1 \
            "${_active_cols[@]}" \
            --button="Refresh:2" \
            --button="OK:0" --button="Close:1" \
            2>/dev/null)
    ret=$?

    # Refresh button (exit code 2)
    [[ $ret -eq 2 ]] && continue
    # Cancel / close
    [[ $ret -ne 0 ]] && break

    uuid="${raw%%|*}"
    [[ -z "$uuid" ]] && continue

    action=$(gtk_action "$uuid" stop done annotate) || continue

    tid=$(_gtk_get "$uuid" id)

    case "$action" in

        stop)
            _gtk_task "$uuid" stop
            gtk_notify "Stopped task ${tid}" ;;

        done)
            if gtk_confirm "Mark as done?" "$uuid"; then
                _gtk_task "$uuid" done
                gtk_notify "✓ Completed task ${tid}"
            fi ;;

        annotate)
            _gtk_annotate "$uuid" && gtk_notify "Annotated task ${tid}" ;;

    esac

done
