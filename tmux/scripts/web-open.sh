#!/bin/sh
# Open a URL in terminal-browser, in a window or split, asking for the URL first.
# Usage: web-open.sh <-w|-h|-v> <pane_id>
#        web-open.sh --ask <-w|-h|-v> <pane_id>   (inside the popup)
#
# The same two stages as claude-open.sh, for the same reason: run-shell still
# knows #{pane_id}, the popup that reads the URL does not. An empty line opens
# localhost:3000, the usual dev server. Ctrl-C closes the popup without opening
# anything.
#
# `terminal-browser open` without --split draws into the pane it runs in and
# stays in the foreground until the browser is closed (ctrl+q), so the window or
# split goes away with it. It never merges into a browser in a neighbouring
# pane either: it only does that for --split.
#
# SSH mode is not honoured: the browser always runs on this machine.

case "$1" in
  --ask) shift ;;
  *) tmux display-popup -E -w 70% -h 7 "'$0' --ask '$1' '$2'"; exit 0 ;;
esac

flag="$1"
pane="$2"

printf '\n  \033[1mOpen in browser\033[0m   \033[2mEnter opens it (empty: localhost:3000), Ctrl-C cancels\033[0m\n\n  \033[1;34m>\033[0m '
read -r url || exit 0
[ -n "$url" ] || url=localhost:3000

path=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)

if [ "$flag" = "-w" ]; then
  set -- new-window -n web
else
  set -- split-window "$flag" -t "$pane"
fi

# The URL reaches the pane as an environment variable, the way claude-open.sh
# passes its prompt, so nothing in it needs escaping for fish, which runs the
# pane command.
exec tmux "$@" -e "WEB_URL=$url" -c "$path" 'exec terminal-browser open "$WEB_URL"'
