#!/bin/sh
# meshview-open.sh PANE — the "meshview" entry of the Alt+Shift+i split menu.
#
# Opens a popup listing the 3D models under PANE's directory (fd + fzf, type to
# filter); the one picked opens in meshview beside PANE: a split, or a new
# window if PANE's window already has two panes (open-beside.sh).
# The split is tagged @meshview like the model-preview skill's, so Claude reuses
# it. The picking runs inside the popup (--pick), so nothing has to wait on it.
set -eu

if [ "${1:-}" = "--pick" ]; then
  pane="$2" dir="$3"
  cd "$dir"
  model="$(fd -t f -e glb -e gltf -e obj -e stl -e ply -e blend . 2>/dev/null \
    | fzf --prompt='model> ' --height=100% --reverse || true)"
  [ -n "$model" ] || exit 0
  model="$dir/$model"
  new="$("$HOME/.tmux/scripts/open-beside.sh" -n meshview -c "$dir" "$pane" -- "$HOME/.local/bin/meshview" "$model")"
  tmux set -p -t "$new" @meshview "$model"
  exit 0
fi

pane="$1"
dir="$(tmux display -p -t "$pane" '#{pane_current_path}')"
if [ -z "$(cd "$dir" && fd -t f -e glb -e gltf -e obj -e stl -e ply -e blend . 2>/dev/null | head -1)" ]; then
  tmux display-message "no models under $dir"
  exit 0
fi
tmux display-popup -E -w 60% -h 60% -d "$dir" -T " model " -- "$0" --pick "$pane" "$dir"
