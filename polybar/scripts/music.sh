#!/bin/bash

# Get current player status
status=$(playerctl status 2>/dev/null)

if [ "$status" = "Playing" ]; then
    artist=$(playerctl metadata artist 2>/dev/null)
    title=$(playerctl metadata title 2>/dev/null)

    if [ -n "$artist" ] && [ -n "$title" ]; then
        # Truncate if too long
        output="♫ $artist - $title"
        if [ ${#output} -gt 50 ]; then
            output="${output:0:47}..."
        fi
        echo "$output"
    else
        echo "♫ Playing"
    fi
elif [ "$status" = "Paused" ]; then
    echo "♫ Paused"
else
    echo ""
fi
