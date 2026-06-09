#!/bin/sh
# Outputs a styled git-branch segment for tmux status-right, or nothing
# when the pane's directory is not inside a git repo. Arg $1 = pane path.
dir="$1"
[ -d "$dir" ] || exit 0
branch=$(cd "$dir" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null)
accent=$(tmux show-option -gqv @accent); [ -z "$accent" ] && accent="#1688f0"
[ -n "$branch" ] && printf '#[fg=#575653]│ #[fg='"$accent"'] #[fg=#cecdc3]%s ' "$branch"
