#!/bin/sh
# The "where am I" segment of tmux status-right.
# Usage: location.sh <pane_id> [tty] [path] [accent]
#
# status-right passes all four, so drawing the bar runs no tmux commands at
# all -- only ps and git. They are looked up when missing, for calling it by
# hand.
#
# Local pane:  folder + git branch, as before.
# ssh pane:    SSH + host instead. #{pane_current_path} on an ssh pane is the
#              local directory ssh happened to be launched from, so showing it
#              (and the branch of whatever local repo that is) is just wrong.
pane="$1"
tty="$2"
dir="$3"
accent="$4"
[ -n "$pane" ] || exit 0
here=$(dirname "$0")

[ -n "$accent" ] || accent=$(tmux show-option -gqv @accent)
[ -z "$accent" ] && accent="#1688f0"

host=$("$here/ssh-target.sh" --host "$pane" "$tty")
if [ -n "$host" ]; then
  printf '#[fg=%s]SSH #[fg=#cecdc3]%s ' "$accent" "$host"
  exit 0
fi

[ -n "$dir" ] || dir=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
[ -n "$dir" ] || exit 0
[ "$dir" = "$HOME" ] && name="~" || name=$(basename "$dir")
printf '#[fg=%s] #[fg=#cecdc3]%s ' "$accent" "$name"
"$here/git-branch.sh" "$dir" "$accent"
