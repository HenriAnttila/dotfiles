#!/bin/sh
# Sum RSS over the process trees of every pane in a window.
# Usage: window-mem.sh <window_id>   (e.g. @3)
win="$1"
[ -n "$win" ] || exit 0
roots=$(tmux list-panes -t "$win" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ') || exit 0
[ -n "$roots" ] || exit 0

ps -eo pid,ppid,rss | awk -v roots="$roots" '
  BEGIN { n = split(roots, r, /[ \n]+/); for (i = 1; i <= n; i++) if (r[i] != "") want[r[i]] = 1 }
  NR > 1 { pid[NR] = $1; ppid[NR] = $2; rss[NR] = $3; last = NR }
  END {
    do {
      grew = 0
      for (i = 2; i <= last; i++)
        if (!(pid[i] in want) && (ppid[i] in want)) { want[pid[i]] = 1; grew = 1 }
    } while (grew)
    for (i = 2; i <= last; i++) if (pid[i] in want) total += rss[i]
    mb = total / 1024
    if (mb >= 1024) printf "%.1fG\n", mb / 1024; else printf "%dM\n", mb
  }'
