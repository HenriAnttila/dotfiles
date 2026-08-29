#!/bin/sh
# Toggle SSH mode. Usage: ssh-mode.sh <on|off> <pane_id>
#
# SSH mode is a key table (tmux's version of a vim mode) that carries every
# normal binding over to the remote host: Alt+c, the Alt+n menu, the splits and
# the popups open on the server instead of the laptop, while window and session
# keys keep doing what they always did.
#
# Turning it on records the pane's ssh command in @ssh_mode_cmd, so the target
# host stays fixed while the mode is on even when the active pane is local --
# which is why it can only be switched on from a pane that is ssh'd somewhere.
action="$1"
pane="$2"
here=$(dirname "$0")

if [ "$action" = "off" ]; then
  tmux set-option -u key-table
  tmux set-option -u @ssh_mode_cmd
  tmux set-option -u @ssh_mode_host
  tmux refresh-client -S
  exit 0
fi

cmd=$("$here/ssh-target.sh" "$pane")
if [ -z "$cmd" ]; then
  tmux display-message "SSH mode: this pane is not ssh'd anywhere"
  exit 0
fi

tmux set-option @ssh_mode_cmd "$cmd"
tmux set-option @ssh_mode_host "$("$here/ssh-target.sh" --host "$pane")"
tmux set-option key-table sshmode
tmux refresh-client -S
