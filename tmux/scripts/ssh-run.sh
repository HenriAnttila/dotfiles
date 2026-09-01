#!/bin/sh
# Run a program on the ssh host, in a window, split or popup.
# Usage: ssh-run.sh <-w|-h|-v|-p> <pane_id> <program...>
#
# The program goes through the remote login shell (exec $SHELL -lc) rather than
# straight to ssh: a bare `ssh host lazygit` runs without the remote .zshrc, so
# anything installed on a PATH set up there is simply not found.
#
# -t is inserted right after "ssh", not appended: everything after the
# destination is the remote command as far as ssh is concerned.
flag="$1"; pane="$2"; shift 2
prog="$*"
here=$(dirname "$0")
[ -n "$prog" ] || exit 0

# Same rule as ssh-open.sh: SSH mode decides, not what the pane is running.
remote=$(tmux show-option -qv @ssh_mode_cmd)
path=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)

if [ -z "$remote" ]; then           # no mode: run it here
  case "$flag" in
    -w) exec tmux new-window -c "$path" "$prog" ;;
    -p) exec tmux display-popup -E -w 90% -h 90% -d "$path" "$prog" ;;
    *)  exec tmux split-window "$flag" -t "$pane" -c "$path" "$prog" ;;
  esac
fi

esc=$(printf '%s' "$prog" | sed 's/"/\\"/g')
cmdline="${remote%% *} -t ${remote#* } 'exec \$SHELL -lc \"$esc\"'"

case "$flag" in
  -w) exec tmux new-window -c "$path" "$cmdline" ;;
  -p) exec tmux display-popup -E -w 90% -h 90% -d "$path" "$cmdline" ;;
  *)  exec tmux split-window "$flag" -t "$pane" -c "$path" "$cmdline" ;;
esac
