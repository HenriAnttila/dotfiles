#!/usr/bin/env bash
# Restore the colours that were live before the saturn palette was applied.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dot="$(cd "$here/../.." && pwd)"

cp "$here/hypr/hyprland.conf" "$dot/hypr/hyprland.conf"
cp "$here/waybar/style.css" "$here/waybar/config.jsonc" "$dot/waybar/"
cp "$here/ghostty/config" "$dot/ghostty/config"
cp "$here/tmux.conf" "$dot/tmux.conf"
cp "$here/tmux/scripts/git-branch.sh" "$here/tmux/scripts/location.sh" "$dot/tmux/scripts/"
cp "$here/dunst/dunstrc" ~/.config/dunst/dunstrc
cp "$here/rofi/config.rasi" ~/.config/rofi/config.rasi

hyprctl reload >/dev/null || true
pkill -SIGUSR2 waybar || true
dunstctl reload >/dev/null || true
tmux source-file ~/.tmux.conf 2>/dev/null || true
pkill -SIGUSR2 -x ghostty || true
