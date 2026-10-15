#!/bin/sh
# Open codegraph (~/dotfiles/codegraph) for the pane's project in a popup: the
# project as a graph, with the current change lit up on it.
# Usage: codegraph-open.sh <pane_id>   (from run-shell -b)
#
# The project is the nearest folder at or above the pane's directory that has a
# sourcemap.json, the file Rojo writes and codegraph reads.
#
# The server lives only as long as the popup. It starts here, on the first free
# port from 7420 up, and is stopped when the popup closes (ctrl+q closes
# terminal-browser, and the popup with it). It starts in well under a second,
# so there is nothing worth keeping running between looks.
#
# The popup's command goes through the tmux skill's popup.py --inside, which
# fills in the popup's size in pixels before terminal-browser starts. tmux
# leaves a popup's at 0, and terminal-browser renders the page at the wrong
# scale without it.
#
# The menu runs this with run-shell -b, so tmux is not held up while the popup
# is open. Every way out is exit 0, for the reason claude-open.sh gives:
# run-shell shows a non-zero exit as "'...' returned 1" over the pane. For the
# same reason nothing is printed: run-shell shows any output over the pane too,
# and sh reports the stopped server as "Terminated: 15". Messages go through
# tmux display-message instead.

pane="$1"
exec >/dev/null 2>&1

die() {
  tmux display-message "codegraph: $*"
  exit 0
}

dir=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
[ -n "$dir" ] || die "no pane $pane"

project="$dir"
while [ ! -f "$project/sourcemap.json" ]; do
  [ "$project" = "/" ] && die "no sourcemap.json in $dir or above it"
  project=$(dirname "$project")
done

bun=$(command -v bun || echo "$HOME/.bun/bin/bun")
[ -x "$bun" ] || die "bun not found"

log=$(mktemp -t codegraph) || die "mktemp failed"
"$bun" "$HOME/dotfiles/codegraph/server.ts" "$project" >"$log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null; rm -f "$log"' EXIT

# The server prints "codegraph: <name> on http://localhost:<port>" once it listens.
url=
tries=0
while [ "$tries" -lt 50 ]; do
  url=$(sed -n 's|^codegraph: .* on \(http://[^ ]*\)$|\1|p' "$log")
  [ -n "$url" ] && break
  kill -0 "$server" 2>/dev/null || die "$(sed -n '1s/^codegraph: //p' "$log")"
  sleep 0.1
  tries=$((tries + 1))
done
[ -n "$url" ] || die "the server did not start"

cell=$(tmux display -p -t "$pane" '#{client_cell_width}x#{client_cell_height}')
tmux display-popup -E -w 90% -h 90% -t "$pane" -T " codegraph " \
  python3 -I "$HOME/.claude/skills/tmux/scripts/popup.py" --inside "$cell" terminal-browser open "$url"
exit 0
