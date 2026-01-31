#!/bin/bash

POMODORO_FILE="/tmp/pomodoro_state"
WORK_DURATION=1500  # 25 minutes in seconds
BREAK_DURATION=300  # 5 minutes in seconds

get_status() {
    if [ ! -f "$POMODORO_FILE" ]; then
        echo "🍅 --:--"
        return
    fi

    read start_time mode < "$POMODORO_FILE"
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))

    if [ "$mode" = "work" ]; then
        remaining=$((WORK_DURATION - elapsed))
        prefix="🍅"
    else
        remaining=$((BREAK_DURATION - elapsed))
        prefix="☕"
    fi

    if [ $remaining -le 0 ]; then
        rm -f "$POMODORO_FILE"
        notify-send "Pomodoro" "Time's up!" 2>/dev/null
        echo "🍅 --:--"
        return
    fi

    minutes=$((remaining / 60))
    seconds=$((remaining % 60))
    printf "%s %02d:%02d\n" "$prefix" "$minutes" "$seconds"
}

toggle() {
    if [ -f "$POMODORO_FILE" ]; then
        # Stop timer
        rm -f "$POMODORO_FILE"
    else
        # Start work timer
        echo "$(date +%s) work" > "$POMODORO_FILE"
        notify-send "Pomodoro" "Work session started (25 min)" 2>/dev/null
    fi
}

case "$1" in
    status)
        get_status
        ;;
    toggle)
        toggle
        ;;
    *)
        echo "Usage: $0 {status|toggle}"
        exit 1
        ;;
esac
