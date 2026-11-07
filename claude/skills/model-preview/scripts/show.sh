#!/bin/sh
# show.sh MODEL — show MODEL in the meshview pane beside this Claude session.
#
# Reuses the meshview pane already open in this tmux window (tagged with the
# pane option @meshview), switching it to MODEL if it shows something else;
# otherwise opens one as a split to the right without taking the keyboard.
# meshview watches the file, so re-exporting MODEL updates the pane by itself.
# Prints the pane id.
set -eu

[ $# -eq 1 ] || { echo "usage: show.sh MODEL" >&2; exit 2; }
[ -f "$1" ] || { echo "no such file: $1" >&2; exit 1; }
[ -n "${TMUX_PANE:-}" ] || { echo "not inside tmux" >&2; exit 1; }

model="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mv="$(command -v meshview || echo "$HOME/dotfiles/tmux/scripts/meshview.py")"
win="$(tmux display -p -t "$TMUX_PANE" '#{window_id}')"
pane="$(tmux list-panes -t "$win" -F '#{pane_id} #{@meshview}' | awk 'NF > 1 { print $1; exit }')"

if [ -n "$pane" ]; then
  if [ "$(tmux show -pqv -t "$pane" @meshview)" = "$model" ]; then
    echo "$pane"
    exit 0
  fi
  tmux respawn-pane -k -t "$pane" -- "$mv" "$model"
else
  pane="$(tmux split-window -h -d -l 50% -t "$TMUX_PANE" -c "$(dirname "$model")" -P -F '#{pane_id}' -- "$mv" "$model")"
fi
tmux set -p -t "$pane" @meshview "$model"
echo "$pane"
