#!/bin/sh
# Fuzzy-pick a project under ~/Code and make it the root of the current session.
# Usage: project-root.sh <pane_id>          (stage one, from run-shell)
#        project-root.sh --pick <pane_id>   (stage two, inside the popup)
#
# Bound to Alt+p. Two stages for the same reason claude-open.sh has two: stage
# one runs from run-shell, where #{pane_id} still expands, and opens the popup.
# Stage two *is* the popup, and a popup pane belongs to no window, so it could
# never have found the pane on its own -- hence the hand-off.
#
# "Root" here means two writes, not one, because in this config the session
# root alone is invisible. Every window, split and menu entry passes
# -c '#{pane_current_path}' (30 sites in tmux.conf, plus ssh-open.sh reading it
# back with `tmux display -p`), which overrides the session's own directory.
# So the pane is cd'd first -- that is the value everything downstream reads --
# and the session root is set after it, for the odd command that opens with no
# -c at all. Setting only the second would look like the key did nothing.
#
# Stage one ends in `exit 0` for the reason claude-open.sh spells out: run-shell
# reports a non-zero job by dropping the pane into copy mode with `'...'
# returned 2` in it, and Ctrl-C out of fzf is a non-zero exit. Cancelling has to
# be silent.
case "$1" in
  --pick) shift ;;
  *) tmux display-popup -E -w 75% -h 70% "'$0' --pick '$1'"; exit 0 ;;
esac

pane="$1"
ROOT="$HOME/Code"

die() {
  tmux display-message "project-root: $*"
  exit 0
}

command -v fzf >/dev/null || die "fzf not found on PATH"
[ -d "$ROOT" ] || die "$ROOT does not exist"

# Single-quote a value for re-parsing by a shell, escaping any embedded quote.
# /bin/sh has no printf %q, and these strings are pasted into `tmux send-keys`
# and `tmux run-shell` where an unquoted space would split the argument.
quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Repos, not directories: ~/Code is a mix of six top-level repos and containers
# holding the rest (Ikius 8, mvp 10, personal 4, school 3), so a flat listing of
# ~/Code/* would show `Ikius` as one row and hide everything inside it. Depth 3
# reaches Ikius/laturikotiin without descending into the projects themselves.
#
# -name .git with no -type matches a file as well as a directory, so linked
# worktrees and submodules -- which carry a .git *file* -- are listed too.
# node_modules is pruned because it is deep, common, and never the answer.
list=$(
  find "$ROOT" -maxdepth 3 \
    -name node_modules -prune -o \
    -name .git -print 2>/dev/null |
  sed -e 's|/\.git$||' -e "s|^$ROOT/||" |
  LC_ALL=C sort -f
)
[ -n "$list" ] || die "no git repos found under $ROOT"

# Alphabetical, not by recency: rows that keep their place mean the same few
# keystrokes always land on the same project. fzf does the narrowing anyway.
#
# --no-optional-locks so hovering a row never writes to the repo's index; the
# preview runs again on every keypress and a picker has no business taking
# git's lock on a repo you might have open elsewhere.
sel=$(
  printf '%s\n' "$list" |
  fzf --reverse --border=none --prompt='root > ' \
      --header='enter: set session root    esc: cancel' \
      --preview-window='right,55%,border-left' \
      --preview='d="'"$ROOT"'/{}"; \
        printf "\033[1m%s\033[0m\n\n" "{}"; \
        git -C "$d" --no-optional-locks status -sb 2>/dev/null | head -12; \
        echo; \
        git -C "$d" --no-optional-locks log --color=always --oneline -8 2>/dev/null'
) || exit 0
[ -n "$sel" ] || exit 0

dir="$ROOT/$sel"
[ -d "$dir" ] || die "$sel is gone"

# The cd is typed into the pane's shell, so there has to be a shell there to
# read it. In nvim or claude the same keystrokes would be swallowed as editor
# input -- `cd ...` appearing mid-buffer -- so refuse instead, and say what is
# in the way. pane_in_mode covers copy-mode, where keys are copy commands.
cmd=$(tmux display -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
case "$cmd" in
  zsh|bash|sh|fish|dash|ksh|tcsh) ;;
  *) die "pane is running $cmd -- switch to a shell first" ;;
esac
[ "$(tmux display -p -t "$pane" '#{pane_in_mode}' 2>/dev/null)" = "0" ] ||
  die "pane is in copy mode -- press q first"

# C-u before the cd: zsh is in emacs mode here (no bindkey -v in ~/.zshrc), so
# C-u is kill-whole-line and a half-typed command is discarded rather than
# having `cd ...` appended to it.
tmux send-keys -t "$pane" C-u
tmux send-keys -t "$pane" "cd -- $(quote "$dir")" Enter

# The session root, via run-shell rather than a plain `tmux attach-session`.
#
# attach-session is the only command that sets a session's working directory,
# and calling it straight from here fails: this popup has $TMUX set, so tmux
# refuses with "sessions should be nested with care" *before* it assigns the
# directory, and nothing changes. run-shell's child has no $TMUX and no tty, so
# the same command gets past that check, assigns the directory, and only then
# fails at "open terminal failed: not a terminal" -- after the write that was
# wanted, and with no chance of really attaching anything, since there is no
# terminal to attach to.
#
# That ordering is a side effect, not a promise, so the cd above is the load-
# bearing half: if a future tmux assigns the directory later than it opens the
# terminal, this line quietly stops working and Alt+p still lands you in the
# right place. `|| true` keeps run-shell from reporting the expected non-zero
# exit as `'...' returned 1`.
sess=$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null)
tmux run-shell "tmux attach-session -c $(quote "$dir") -t $(quote "$sess") >/dev/null 2>&1 || true"

tmux display-message "root: $sel"
