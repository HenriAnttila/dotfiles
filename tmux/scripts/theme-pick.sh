#!/usr/bin/env bash
# Fuzzy-pick a theme (any installed nvim colorscheme) for the whole terminal.
# Run in a popup from the Alt+o menu. Moving through the list previews each
# theme live in Ghostty and tmux; Enter applies it for good (Ghostty config,
# tmux, nvim -- see theme-apply.sh); Esc puts the current theme back.

apply="$(dirname "$(readlink -f "$0")")/theme-apply.sh"
last="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/last_colorscheme.txt"
current="$(cat "$last" 2>/dev/null)"

printf 'loading themes from nvim...\r'
names="$("$apply" --list)"
pos="$(grep -nxF -- "$current" <<< "$names" | cut -d: -f1)"

pick="$(fzf --prompt 'theme> ' --layout reverse --info inline \
  --header "now: ${current:-none}   enter apply · esc cancel" \
  ${pos:+--bind "load:pos($pos)"} \
  --bind "focus:execute-silent('$apply' --preview {})" <<< "$names")"

if [ -n "$pick" ]; then
  "$apply" "$pick"
else
  "$apply" --preview "$current"
fi
