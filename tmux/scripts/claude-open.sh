#!/bin/sh
# Open claude in a window or split, asking for the first prompt first.
# Usage: claude-open.sh <-w|-h|-v> <pane_id>
#        claude-open.sh --ask <-w|-h|-v> <pane_id>   (inside the popup)
#
# Two stages, because the two things it needs cannot happen in one place. Stage
# one runs from run-shell, where #{pane_id} still expands, and opens the popup.
# Stage two *is* the popup: it reads one line, then opens the window or split
# running `claude <prompt>`. A popup pane is not part of any window, so stage
# two could not have found the pane to split on its own -- hence the hand-off.
#
# An empty line starts claude with no prompt, so the popup costs nothing on the
# times you did not want one. Ctrl-C closes it without opening anything.
#
# SSH mode is honoured the way ssh-open.sh and ssh-run.sh honour it: with the
# mode on the session lands on the pinned host instead of the laptop.

# Stage one ends in `exit 0` rather than exec'ing the popup: run-shell reports a
# non-zero job by dropping the pane into copy mode with `'...' returned 2` in
# it, and Ctrl-C out of the popup is a non-zero exit. Cancelling has to be
# silent, so the status is dropped here; a real failure still says so in the
# popup, which stays up long enough to read because the popup is what failed.
case "$1" in
  --ask) shift ;;
  *) tmux display-popup -E -w 70% -h 7 "'$0' --ask '$1' '$2'"; exit 0 ;;
esac

flag="$1"
pane="$2"

printf '\n  \033[1mNew claude session\033[0m   \033[2mEnter starts it, Ctrl-C cancels\033[0m\n\n  \033[1;34m>\033[0m '
IFS= read -r prompt || exit 0

path=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)

# -w is a window, so it takes no direction and no pane target: run-shell gave
# stage one the pane's session through $TMUX, and new-window appends there.
if [ "$flag" = "-w" ]; then
  set -- new-window -n claude
else
  set -- split-window "$flag" -t "$pane"
fi

# The mode is the only thing that sends a new pane to the server, same rule as
# ssh-open.sh: a pane that happens to be ssh'd somewhere does not.
remote=$(tmux show-option -qv @ssh_mode_cmd)

if [ -z "$remote" ]; then
  # The prompt is prose: it can hold quotes, $, backticks, newlines. -e hands it
  # to the new pane as an environment variable, which no shell ever parses, and
  # the pane's command reads it back from there -- so nothing needs escaping.
  [ -n "$prompt" ] || exec tmux "$@" -c "$path" claude
  exec tmux "$@" -e "CLAUDE_PROMPT=$prompt" -c "$path" 'exec claude "$CLAUDE_PROMPT"'
fi

# On the server the pane runs ssh, so the prompt has to survive being written
# into a command line, and three shells read that line before claude does: the
# local sh tmux starts the pane command with, the remote login shell ssh hands
# its command to, and the `$SHELL -lc` that loads the remote profile (without
# it, anything on a PATH set up in .zshrc is simply not found). Prose survives
# none of them, so it travels base64-encoded -- letters, digits and +/= only --
# and the innermost shell decodes it one step before claude.
#
# ssh-run.sh is not reused for this: it joins its program words with spaces and
# wraps them in double quotes the remote login shell expands, which is right for
# `npm run dev` and hopeless for a sentence.
if [ -n "$prompt" ]; then
  b64=$(printf '%s' "$prompt" | base64 | tr -d '\n')
  # Reads `exec claude "$(printf %s <b64> | base64 --decode)"` once the local sh
  # has taken a level of escaping off it.
  inner="exec claude \\\"\\\$(printf %s $b64 | base64 --decode)\\\""
else
  inner="exec claude"
fi

# -t goes right after "ssh", not at the end: to ssh, everything after the
# destination is the remote command.
cmdline="${remote%% *} -t ${remote#* } \"exec \\\$SHELL -lc '$inner'\""

exec tmux "$@" -c "$path" "$cmdline"
