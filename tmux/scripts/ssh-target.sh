#!/bin/sh
# Reports the ssh session running in a pane, or nothing when the pane is local.
# Usage: ssh-target.sh [--host] <pane_id>   (e.g. %5)
#
# tmux does not record what was typed: ssh is started from the pane's shell, so
# #{pane_start_command} is empty and the argv only exists in the process table.
# The foreground process group on the pane's tty (the "+" in ps STAT) holds it.
#
# #{pane_current_command} is deliberately not used as the test: it names the
# process *group leader*, which is ssh for a hand-typed session but the wrapper
# shell in panes ssh-split.sh created (`ssh host; exec zsh`). Scanning the whole
# foreground group catches both.
#
#   (no flag)  full ssh command line, for re-running it in a new pane
#   --host     just the destination (user@host), for the status bar
mode="cmd"
[ "$1" = "--host" ] && { mode="host"; shift; }
pane="$1"
[ -n "$pane" ] || exit 0

tty=$(tmux display -p -t "$pane" '#{pane_tty}' 2>/dev/null)
[ -n "$tty" ] || exit 0

cmd=$(ps -t "$tty" -o stat=,args= 2>/dev/null | awk '
  $1 ~ /\+/ {
    $1 = ""; sub(/^[ \t]+/, "")
    if ($0 ~ /^([^ ]*\/)?ssh([ \t]|$)/) { print; exit }
  }')
[ -n "$cmd" ] || exit 0

[ "$mode" = "cmd" ] && { printf '%s\n' "$cmd"; exit 0; }

# Destination = first argument that is neither an option nor an option's value.
# The listed options take their value as a separate word; -p2222-style ones
# carry it in the same word and are skipped like any other flag.
printf '%s\n' "$cmd" | awk '{
  for (i = 2; i <= NF; i++) {
    if ($i ~ /^-/) { if ($i ~ /^-[bcDEeFIiJLlmOopQRSWw]$/) i++; continue }
    print $i; exit
  }
}'
