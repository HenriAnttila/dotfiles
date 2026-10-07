#!/bin/sh
# The "where am I" segment of tmux status-right.
# Usage: location.sh <pane_id> [tty] [path] [accent]
#
# status-right passes all four, so drawing the bar runs no tmux commands at
# all -- only ps and git. They are looked up when missing, for calling it by
# hand.
#
# Local pane:  folder + git branch, as before.
# ssh pane:    SSH + host instead. #{pane_current_path} on an ssh pane is the
#              local directory ssh happened to be launched from, so showing it
#              (and the branch of whatever local repo that is) is just wrong.
pane="$1"
tty="$2"
dir="$3"
accent="$4"
[ -n "$pane" ] || exit 0
here=$(dirname "$0")

[ -n "$accent" ] || accent=$(tmux show-option -gqv @accent)
[ -z "$accent" ] && accent="#67ADFB"

host=$("$here/ssh-target.sh" --host "$pane" "$tty")
if [ -n "$host" ]; then
  printf '#[fg=%s]SSH #[fg=#CECBE5]%s ' "$accent" "$host"
  exit 0
fi

[ -n "$dir" ] || dir=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
[ -n "$dir" ] || exit 0
# Folder name, plus as many parent levels as it takes to be unique within the
# git repo: "the_project", but "log_output/manifests" when the repo has several
# "manifests". Folders come from git's file list (tracked + untracked, minus
# ignored), so node_modules and friends never count as a clash. Outside a repo
# it is just the folder name.
root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
if [ "$dir" = "$HOME" ]; then
  name="~"
elif [ -z "$root" ] || [ "$dir" = "$root" ]; then
  name=$(basename "$dir")
else
  name=$({ git -C "$root" ls-files; git -C "$root" ls-files --others --exclude-standard; } |
    awk -v rel="${dir#"$root"/}" '
      { n = split($0, p, "/"); d = ""
        for (i = 1; i < n; i++) { d = d (i > 1 ? "/" : "") p[i]; dirs[d] = 1 } }
      END {
        m = split(rel, c, "/")
        for (k = 1; k <= m; k++) {
          suf = c[m]; for (i = m - 1; i > m - k; i--) suf = c[i] "/" suf
          hits = 0
          for (d in dirs) if (d == suf || substr(d, length(d) - length(suf)) == "/" suf) hits++
          if (hits <= 1) break
        }
        print suf
      }')
fi
printf '#[fg=%s] #[fg=#CECBE5]%s ' "$accent" "$name"
"$here/git-branch.sh" "$dir" "$accent"
