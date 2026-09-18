#!/bin/sh
# Build the sshmode key table as a copy of the root table.
#
# SSH mode must not take keys away: everything bound without a prefix has to go
# on working while it is on. Rather than maintaining a second copy of every
# binding by hand, mirror the root table -- list-keys prints bindings in the
# same syntax that source-file reads, so only the table name needs changing.
# tmux.conf then overrides the handful of keys that should aim at the server.
#
# Run after the plugins load: vim-tmux-navigator binds Ctrl+hjkl in root, and
# those have to come along too.
tmp=$(mktemp -t sshmode) || exit 0
tmux unbind-key -a -T sshmode 2>/dev/null
tmux list-keys -T root | sed 's/^bind-key  */bind-key /; s/^bind-key -T root /bind-key -T sshmode /' > "$tmp"
tmux source-file "$tmp"
rm -f "$tmp"

# ... then the handful of keys that should aim at the server instead.
[ -f "$HOME/.tmux/sshmode.conf" ] && tmux source-file "$HOME/.tmux/sshmode.conf"
exit 0
