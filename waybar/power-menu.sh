#!/bin/sh
# Session menu behind waybar's power button (custom/power in config.jsonc).
# The button used to run `systemctl poweroff` on click; this asks first.
# Escape, clicking away, or "Cancel" all do nothing.
choice=$(
  printf '%s\n' "Power off" "Reboot" "Suspend" "Log out" "Cancel" |
  rofi -dmenu -i -no-custom -l 5 -p "Power"
) || exit 0

case "$choice" in
  "Power off") systemctl poweroff ;;
  "Reboot")    systemctl reboot ;;
  "Suspend")   systemctl suspend ;;
  "Log out")   hyprctl dispatch exit ;;
esac
