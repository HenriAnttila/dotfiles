#!/bin/bash

# Simple weather script using wttr.in
# Auto-detects location or you can set LOCATION variable below

# Set your location here (e.g., "Helsinki", "London", "New York")
# Leave empty for auto-detection based on IP
LOCATION=""

# Fetch weather data
if [ -z "$LOCATION" ]; then
    WEATHER=$(curl -s "wttr.in/?format=%l:+%t+%C" 2>/dev/null)
else
    WEATHER=$(curl -s "wttr.in/$LOCATION?format=%l:+%t+%C" 2>/dev/null)
fi

# Check if curl was successful
if [ $? -eq 0 ] && [ -n "$WEATHER" ]; then
    echo " $WEATHER"
else
    echo " Weather unavailable"
fi
