#!/bin/bash
# ~/.config/polybar/scripts/system-center.sh

# Get colors from Xresources
col_wifi=$(xrdb -query | grep '\*color6:' | head -1 | awk '{print $2}')
col_cpu=$(xrdb -query | grep '\*color5:' | head -1 | awk '{print $2}')
col_mem=$(xrdb -query | grep '\*color4:' | head -1 | awk '{print $2}')

# WiFi status - using nmcli
wifi_interface="wlan0"
wifi_state=$(cat /sys/class/net/$wifi_interface/operstate 2>/dev/null)

if [ "$wifi_state" = "up" ]; then
    # Try several methods to get signal strength

    # Method 1: nmcli (most reliable)
    wifi_signal=$(nmcli -t -f SIGNAL dev wifi | head -n1 2>/dev/null)

    # Method 2: if nmcli fails, try /proc/net/wireless
    if [ -z "$wifi_signal" ] || ! [[ "$wifi_signal" =~ ^[0-9]+$ ]]; then
        wifi_signal=$(awk 'NR==3 {print int($3 * 100 / 70)}' /proc/net/wireless 2>/dev/null)
    fi

    # Method 3: if still failing, try /sys
    if [ -z "$wifi_signal" ] || ! [[ "$wifi_signal" =~ ^[0-9]+$ ]]; then
        wifi_signal=$(cat /sys/class/net/$wifi_interface/wireless/link 2>/dev/null)
    fi

    # If all methods fail, set default 100
    if [ -z "$wifi_signal" ] || ! [[ "$wifi_signal" =~ ^[0-9]+$ ]]; then
        wifi_signal=100
    fi

    # Set icon based on signal strength (0-100%)
    if [ "$wifi_signal" -le 20 ]; then
        wifi_icon="󰤯"
    elif [ "$wifi_signal" -le 40 ]; then
        wifi_icon="󰤟"
    elif [ "$wifi_signal" -le 60 ]; then
        wifi_icon="󰤢"
    elif [ "$wifi_signal" -le 80 ]; then
        wifi_icon="󰤥"
    else
        wifi_icon="󰤨"
    fi

    wifi_display="$wifi_icon"
else
    wifi_icon="󰤮"
    wifi_display="$wifi_icon"
fi

# CPU usage
cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print int(100 - $1)}')
cpu_icon=""

# Memory usage
mem_used=$(free -h | awk '/^Mem:/ {print $3}')
mem_icon=""

# Output format
printf "%%{F%s}%s%%{F-}  %%{F%s}%s %s%%{F-}  %%{F%s}%s %s%%{F-}\n" \
    "$col_wifi" "$wifi_display" \
    "$col_cpu" "$cpu_icon" "${cpu_usage}%" \
    "$col_mem" "$mem_icon" "$mem_used"
