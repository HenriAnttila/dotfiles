#!/bin/sh
# Open a new pane or window, following ssh into it.
# Usage: ssh-open.sh <-h|-v|-w> <pane_id>   (-h/-v split, -w new window)
#
# `-c "#{pane_current_path}"` always opens a local shell, so splitting (or
# opening a window from) an ssh pane drops you back on the laptop in whatever
# local directory ssh was launched from. When the pane is remote, re-run the
# same ssh command in the new pane instead. The remote directory is not carried
# over: tmux has no way to know it (that would need OSC 7 from the remote
# shell), so the new pane starts in the remote $HOME.
#
# The command is recovered from ps, which prints argv unquoted, so an ssh
# invocation carrying quoted arguments with spaces (ssh host 'cmd --flag x',
# -o "ProxyCommand=sh -c ...") re-runs word-split differently. Plain
# `ssh [flags] host` -- what you type by hand -- is unaffected.
flag="${1:--h}"
pane="$2"

# -w is a window, so it takes no direction and no pane target: run-shell gives
# the script the pane's session through $TMUX, and new-window appends there.
if [ "$flag" = "-w" ]; then
  set -- new-window
else
  set -- split-window "$flag" -t "$pane"
fi

path=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
ssh_cmd=$("$(dirname "$0")/ssh-target.sh" "$pane")

if [ -z "$ssh_cmd" ]; then
  exec tmux "$@" -c "$path"
fi

# Hand over to a local shell when the connection ends, in the same directory
# the original pane started from: a dropped session leaves you somewhere
# useful, and an ssh error stays on screen instead of the pane vanishing.
shell=$(tmux show-option -gqv default-shell)
[ -n "$shell" ] || shell="${SHELL:-/bin/sh}"
exec tmux "$@" -c "$path" "$ssh_cmd; exec $shell"
