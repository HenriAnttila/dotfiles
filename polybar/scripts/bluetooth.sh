#!/bin/bash

# Bluetooth status script for polybar
# Shows current bluetooth status and connected devices
# Click to open rofi menu for device selection

get_bluetooth_status() {
    if systemctl is-active --quiet bluetooth.service; then
        power_status=$(bluetoothctl show | grep "Powered" | awk '{print $2}')

        if [ "$power_status" = "yes" ]; then
            # Get connected devices
            connected_devices=$(bluetoothctl devices Connected | wc -l)

            if [ "$connected_devices" -gt 0 ]; then
                # Get first connected device name
                device_name=$(bluetoothctl devices Connected | head -1 | cut -d ' ' -f 3-)
                echo "󰂱 $device_name"
            else
                echo "󰂯 ON"
            fi
        else
            echo "󰂲 OFF"
        fi
    else
        echo "󰂲 N/A"
    fi
}

bluetooth_menu() {
    # Toggle bluetooth power
    power_status=$(bluetoothctl show | grep "Powered" | awk '{print $2}')

    if [ "$power_status" = "no" ]; then
        # Turn on bluetooth first
        bluetoothctl power on
        sleep 1
    fi

    # Enable pairable mode and agent for pairing
    bluetoothctl pairable on &>/dev/null
    bluetoothctl agent on &>/dev/null
    bluetoothctl default-agent &>/dev/null

    # Scan for devices
    bluetoothctl --timeout 5 scan on &>/dev/null &
    scan_pid=$!

    # Wait a bit for scan results
    sleep 2

    # Build menu with paired and scanned devices
    paired_devices=$(bluetoothctl devices Paired 2>/dev/null | awk '{$1=""; print substr($0,2)}')
    all_devices=$(bluetoothctl devices 2>/dev/null | awk '{$1=""; print substr($0,2)}')

    # Find unpaired devices by comparing all devices with paired
    unpaired_devices=""
    while IFS= read -r device; do
        if [ -n "$device" ] && ! echo "$paired_devices" | grep -qF "$device"; then
            unpaired_devices+="$device [NEW]\n"
        fi
    done <<< "$all_devices"

    # Build menu
    menu="Toggle Power\n---"

    if [ -n "$paired_devices" ]; then
        menu+="\n$paired_devices"
    fi

    if [ -n "$unpaired_devices" ]; then
        if [ -n "$paired_devices" ]; then
            menu+="\n---"
        fi
        menu+="\n$unpaired_devices"
    fi

    # Kill scan process
    kill $scan_pid 2>/dev/null
    bluetoothctl scan off &>/dev/null

    # Show rofi menu
    selected=$(echo -e "$menu" | rofi -dmenu -i -p "Bluetooth" -theme-str 'window {width: 400px;}')

    if [ -n "$selected" ]; then
        if [ "$selected" = "Toggle Power" ]; then
            if [ "$power_status" = "yes" ]; then
                bluetoothctl power off
                notify-send "Bluetooth" "Turned off"
            else
                bluetoothctl power on
                notify-send "Bluetooth" "Turned on"
            fi
        elif [ "$selected" != "---" ]; then
            # Remove [NEW] tag if present
            selected_clean=$(echo "$selected" | sed 's/ \[NEW\]$//')

            # Get device MAC address
            mac=$(bluetoothctl devices | grep "$selected_clean" | awk '{print $2}')

            if [ -n "$mac" ]; then
                # Check if device is paired
                if bluetoothctl info "$mac" | grep -q "Paired: no"; then
                    # Pair the device first
                    notify-send "Bluetooth" "Pairing with $selected_clean..."
                    bluetoothctl pair "$mac"
                    sleep 2
                    bluetoothctl trust "$mac"
                    bluetoothctl connect "$mac"
                    notify-send "Bluetooth" "Paired and connected to $selected_clean"
                else
                    # Check if device is connected
                    if bluetoothctl info "$mac" | grep -q "Connected: yes"; then
                        bluetoothctl disconnect "$mac"
                        notify-send "Bluetooth" "Disconnected from $selected_clean"
                    else
                        bluetoothctl connect "$mac"
                        if [ $? -eq 0 ]; then
                            notify-send "Bluetooth" "Connected to $selected_clean"
                        else
                            notify-send "Bluetooth" "Failed to connect to $selected_clean"
                        fi
                    fi
                fi
            fi
        fi
    fi
}

case "$1" in
    --menu)
        bluetooth_menu
        ;;
    *)
        get_bluetooth_status
        ;;
esac
