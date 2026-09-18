#!/bin/sh
# Stamp @mem (summed RSS of every pane's process tree) on each window, and
# @smem with the session total (a separate name: window options shadow the
# session ones they inherit, so reusing @mem would hide the total).
# choose-tree then reads plain #{@mem} / #{@smem}. Stamping up front beats a
# #() per row: those run async, so the picker's first frame would be blank.
f=$(mktemp)
ps -eo pid,ppid,rss | awk -v panes="$(tmux list-panes -a -F '#{session_id} #{window_id} #{pane_pid}' | tr '\n' ';')" '
  BEGIN {
    np = split(panes, p, ";")
    for (i = 1; i <= np; i++) if (p[i] != "") { split(p[i], f, " "); sid[i] = f[1]; wid[i] = f[2]; root[i] = f[3] }
  }
  NR > 1 { pid[NR] = $1; ppid[NR] = $2; rss[NR] = $3; last = NR }
  END {
    for (i = 1; i <= np; i++) {
      if (root[i] == "") continue
      delete want; want[root[i]] = 1
      do {
        grew = 0
        for (j = 2; j <= last; j++)
          if (!(pid[j] in want) && (ppid[j] in want)) { want[pid[j]] = 1; grew = 1 }
      } while (grew)
      t = 0
      for (j = 2; j <= last; j++) if (pid[j] in want) t += rss[j]
      win[wid[i]] += t; sess[sid[i]] += t
    }
    for (w in win) printf "set -w -t %s @mem \"%s\"\n", w, fmt(win[w])
    for (s in sess) printf "set -t %s @smem \"%s\"\n", s, fmt(sess[s])
  }
  function fmt(kb) {
    mb = kb / 1024
    return (mb >= 1024) ? sprintf("%.1fG", mb / 1024) : sprintf("%dM", mb)
  }' > "$f" && tmux source-file "$f"; rm -f "$f"
