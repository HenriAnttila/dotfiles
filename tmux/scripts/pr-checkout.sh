#!/usr/bin/env bash
# Fuzzy-pick an open PR and check out its branch.
#
# Bound to Alt+p in tmux.conf, run inside a display-popup so it overlays the
# current pane and disappears on success. Searching by PR title/author beats
# scrolling lazygit's remote-branches list, which shows bare branch names with
# no PR numbers or titles.
#
# Errors exit non-zero, which is why the binding uses -EE: the popup stays open
# on failure so the message is readable, and closes by itself on success.

set -uo pipefail

TAB=$'\t'

die() {
	printf '\n%s\n\n' "$*" >&2
	exit 1
}

for tool in gh fzf column; do
	command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $PWD"

# --jq is gh's built-in jq, so no external jq dependency.
if ! prs=$(gh pr list --limit 100 \
	--json number,title,author,headRefName \
	--jq '.[] | [.number, .title, .author.login, .headRefName] | @tsv' 2>&1); then
	die "gh pr list failed:\n$prs"
fi

[ -n "$prs" ] || die "no open PRs"

# column -t aligns the columns; fzf then splits on whitespace, so {1} is the
# PR number for both the preview and the final awk.
num=$(printf '%s\n' "$prs" |
	column -t -s "$TAB" |
	fzf --height=100% \
		--header='enter: checkout    ctrl-o: open in browser    esc: cancel' \
		--preview='gh pr view {1} --color=always' \
		--preview-window=right:55%:wrap \
		--bind='ctrl-o:execute-silent(gh pr view {1} --web)' |
	awk '{print $1}')

# Empty means escape — not an error, just leave.
[ -n "$num" ] || exit 0

gh pr checkout "$num" || die "checkout of #$num failed"
