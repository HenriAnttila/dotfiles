#!/bin/sh
# open-beside.sh [-d] [-n NAME] [-c DIR] PANE -- COMMAND [ARG...]
#
# Opens COMMAND next to PANE without squeezing it into a sliver: a 50% split to
# the right while PANE's window has one pane, and a new window (tab) once it
# already has two or more, since a third pane side by side is too narrow for a
# browser or meshview.
#   -d       leave the keyboard where it is (no focus on the new pane or window)
#   -n NAME  the new window's name, when it comes to that (default: the command)
#   -c DIR   its working directory (default: PANE's)
# Prints the new pane's id. Used by meshview (model-preview skill, the split
# menu) and by Claude for every split (tmux skill).
set -eu

detach="" name="" dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) detach="-d"; shift ;;
    -n) name="$2"; shift 2 ;;
    -c) dir="$2"; shift 2 ;;
    *) break ;;
  esac
done
[ $# -ge 3 ] && [ "$2" = "--" ] || { echo "usage: open-beside.sh [-d] [-n NAME] [-c DIR] PANE -- COMMAND [ARG...]" >&2; exit 2; }
pane="$1"; shift 2
[ -n "$pane" ] || { echo "open-beside.sh: empty PANE" >&2; exit 2; }
[ -n "$dir" ] || dir="$(tmux display -p -t "$pane" '#{pane_current_path}')"
[ -n "$name" ] || name="$(basename "$1")"

if [ "$(tmux display -p -t "$pane" '#{window_panes}')" -ge 2 ]; then
  win="$(tmux display -p -t "$pane" '#{window_id}')"
  # -a: right after PANE's window, so the new tab sits next to the conversation
  tmux new-window $detach -a -t "$win" -n "$name" -c "$dir" -P -F '#{pane_id}' -- "$@"
else
  tmux split-window -h $detach -l 50% -t "$pane" -c "$dir" -P -F '#{pane_id}' -- "$@"
fi
