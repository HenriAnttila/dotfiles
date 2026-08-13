#!/usr/bin/env bash
# Fuzzy-pick an open PR by branch name and check it out.
#
# Bound to Alt+p in tmux.conf, run inside a display-popup so it overlays the
# current pane and disappears on success. Left column is branch names; the
# preview pane shows details for whichever one is hovered.
#
# All PR data is fetched in ONE gh call up front and previewed from a local
# file via jq. Calling `gh pr view` per hover instead costs ~0.6s of network
# on every arrow key, which makes scrolling the list unusable.
#
# Errors exit non-zero, which is why the binding uses -EE: the popup stays open
# on failure so the message is readable, and closes by itself on success.

set -uo pipefail

die() {
	printf '\n%s\n\n' "$*" >&2
	exit 1
}

for tool in gh fzf jq; do
	command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $PWD"

tmpdir=$(mktemp -d -t pr-picker) || die "could not create temp dir"
trap 'rm -rf "$tmpdir"' EXIT
json="$tmpdir/prs.json"

# One network round-trip for everything the picker and preview need.
#
# Two things dominate how long this takes, both measured against a busy repo:
#   --limit 100 makes gh page through the API   ~6.0s -> 1.8s at limit 30
#   additions/deletions/changedFiles cost ~1.2s, since gh fetches each PR's
#   diff stats                                  ~1.8s -> 0.6s without them
# Hence limit 30 and no diffstat in the preview: ~10x faster to open, for one
# line of detail. Add the fields back to --json and to preview.jq if you want
# the +/- counts and can live with the wait.
LIMIT=30
if ! gh pr list --limit "$LIMIT" \
	--json number,title,author,headRefName,baseRefName,state,isDraft,updatedAt,body \
	>"$json" 2>"$tmpdir/err"; then
	die "gh pr list failed:\n$(cat "$tmpdir/err")"
fi

count=$(jq -r 'length' "$json")
[ "$count" != "0" ] || die "no open PRs"

# Say so rather than silently truncating: a full page means there may be more.
header='enter: checkout    ctrl-o: open in browser    esc: cancel'
[ "$count" -lt "$LIMIT" ] || header="showing first $LIMIT open PRs    $header"

# Preview filter lives in its own file so it needs no shell escaping.
cat >"$tmpdir/preview.jq" <<'JQ'
.[] | select(.headRefName == $b) |
  "#\(.number)  \(.title)\n\n" +
  "author   \(.author.login)\n" +
  "branch   \(.headRefName) -> \(.baseRefName)\n" +
  "state    \(.state)\(if .isDraft then " (draft)" else "" end)\n" +
  "updated  \(.updatedAt[0:10])\n\n" +
  "--------------------------------------------\n\n" +
  (if (.body // "") == "" then "(no description)" else .body end)
JQ

# ctrl-o needs the PR number, which means a jq lookup; a helper script keeps
# that out of the --bind string where the quoting gets unreadable.
cat >"$tmpdir/open.sh" <<EOF
#!/bin/sh
n=\$(jq -r --arg b "\$1" '.[] | select(.headRefName == \$b) | .number' "$json")
[ -n "\$n" ] && gh pr view "\$n" --web
EOF
chmod +x "$tmpdir/open.sh"

# Branch first so it reads as the left column, title after it so fzf can match
# on it. The title has to be visible to be searchable: --with-nth hides a field
# from the query as well as from the display, so there is no hidden-but-
# searchable option. Branch names cannot contain spaces, so {1} is always the
# whole branch even after column(1) turns the tab into padding.
branch=$(jq -r '.[] | [.headRefName, .title] | @tsv' "$json" |
	column -t -s "$(printf '\t')" |
	fzf --height=100% \
		--header="$header" \
		--preview="jq -r --arg b {1} -f '$tmpdir/preview.jq' '$json'" \
		--preview-window=right:50%:wrap \
		--bind="ctrl-o:execute-silent('$tmpdir/open.sh' {1})" |
	awk '{print $1}')

# Empty means escape — not an error, just leave.
[ -n "$branch" ] || exit 0

# Check out by number: `gh pr checkout <branch>` fails for PRs from forks,
# where the head branch does not exist in this repo.
num=$(jq -r --arg b "$branch" '.[] | select(.headRefName == $b) | .number' "$json")
[ -n "$num" ] || die "could not resolve a PR number for branch $branch"

gh pr checkout "$num" || die "checkout of #$num failed"
