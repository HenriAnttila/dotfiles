#!/bin/sh
# Open a new pane or window, following ssh into it.
# Usage: ssh-open.sh <-h|-v|-w> <pane_id> [window_index]
#        (-h/-v split, -w new window; the index is for the Alt+1..9 slots)
#
# Outside SSH mode this is a plain split or new window in the current
# directory. Inside it, the new pane re-runs the ssh command that the mode
# pinned in @ssh_mode_cmd, so it opens on the server -- whether or not the pane
# you pressed the key in is the one that is ssh'd. The remote directory is not
# carried over: tmux has no way to know it (that would need OSC 7 from the
# remote shell), so the new pane starts in the remote $HOME.
#
# The command is recovered from ps, which prints argv unquoted, so an ssh
# invocation carrying quoted arguments with spaces (ssh host 'cmd --flag x',
# -o "ProxyCommand=sh -c ...") re-runs word-split differently. Plain
# `ssh [flags] host` -- what you type by hand -- is unaffected.
flag="${1:--h}"
pane="$2"
index="$3"

# -w is a window, so it takes no direction and no pane target: run-shell gives
# the script the pane's session through $TMUX, and new-window appends there.
if [ "$flag" = "-w" ]; then
  set -- new-window
  [ -n "$index" ] && set -- new-window -t ":$index"
else
  set -- split-window "$flag" -t "$pane"
fi

path=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)

# The mode is the only thing that sends a new pane to the server. A pane that
# happens to be ssh'd somewhere does not: with the mode off, Alt+c and the
# splits are local, the way they were before any of this.
ssh_cmd=$(tmux show-option -qv @ssh_mode_cmd)

if [ -z "$ssh_cmd" ]; then
  exec tmux "$@" -c "$path"
fi

# Hand over to a local shell when the connection ends, in the same directory
# the original pane started from: a dropped session leaves you somewhere
# useful, and an ssh error stays on screen instead of the pane vanishing.
shell=$(tmux show-option -gqv default-shell)
[ -n "$shell" ] || shell="${SHELL:-/bin/sh}"
exec tmux "$@" -c "$path" "$ssh_cmd; exec $shell"
