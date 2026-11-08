#!/bin/sh
# open-beside.sh [-d] [-n NAME] [-c DIR] PANE -- COMMAND [ARG...]
#
# Opens COMMAND next to PANE without squeezing it into a sliver: a 50% split to
# the right while PANE's row has one or two panes side by side, and a new window
# (tab) once it already has three or more, since a fourth column is too narrow
# for a browser or meshview. Only columns count: panes stacked above or below
# PANE (not overlapping its rows) are not beside it.
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

# Columns in PANE's row: panes whose rows overlap PANE's, by distinct left edge.
cols="$(tmux list-panes -t "$pane" -F '#{pane_id} #{pane_top} #{pane_bottom} #{pane_left}' \
  | awk -v p="$pane" '{ id[NR] = $1; t[NR] = $2; b[NR] = $3; l[NR] = $4; if ($1 == p) me = NR }
      END { for (i = 1; i <= NR; i++) if (t[i] <= b[me] && b[i] >= t[me]) seen[l[i]] = 1
            n = 0; for (k in seen) n++; print n }')"

if [ "$cols" -ge 3 ]; then
  win="$(tmux display -p -t "$pane" '#{window_id}')"
  # -a: right after PANE's window, so the new tab sits next to the conversation
  tmux new-window $detach -a -t "$win" -n "$name" -c "$dir" -P -F '#{pane_id}' -- "$@"
else
  tmux split-window -h $detach -l 50% -t "$pane" -c "$dir" -P -F '#{pane_id}' -- "$@"
fi
