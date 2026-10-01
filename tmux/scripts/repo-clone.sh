#!/usr/bin/env bash
# Fuzzy-pick one of your GitHub repos and clone it into the current directory.
#
# Bound to "clone repo" in the Alt+o menu, run inside a display-popup with -d
# '#{pane_current_path}', so the clone lands wherever the pane already is.
# Left column is repo names; the preview pane shows details for the hovered one.
#
# Same shape as pr-checkout.sh, for the same reason: all repo data comes from ONE
# gh call up front and the preview reads it back from a local file with jq.
# Calling `gh repo view` per hover instead costs a network round-trip on every
# arrow key, which makes scrolling the list unusable.
#
# Errors exit non-zero, which is why the binding uses -EE: the popup stays open
# on failure so the message is readable, and closes by itself on success. That
# also means git clone's progress output is visible while it runs.

set -uo pipefail

die() {
	printf '\n%s\n\n' "$*" >&2
	exit 1
}

for tool in gh fzf jq; do
	command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/repo-picker.XXXXXX") || die "could not create temp dir"
trap 'rm -rf "$tmpdir"' EXIT
json="$tmpdir/repos.json"

# One network round-trip for everything the picker and preview need.
#
# defaultBranchRef is deliberately absent: asking for it takes the call from
# ~1.1s to ~3.4s, since gh resolves the ref per repo, and a fresh clone checks
# that branch out anyway. Same trade-off as the diffstat fields in
# pr-checkout.sh -- one line of detail is not worth tripling the time to open.
LIMIT=100
if ! gh repo list --limit "$LIMIT" \
	--json name,nameWithOwner,description,pushedAt,visibility,isFork,isArchived,primaryLanguage,diskUsage \
	>"$json" 2>"$tmpdir/err"; then
	die "gh repo list failed:\n$(cat "$tmpdir/err")"
fi

count=$(jq -r 'length' "$json")
[ "$count" != "0" ] || die "no repos found"

# Say so rather than silently truncating: a full page means there may be more.
header="clone into $PWD"$'\n''enter: clone    ctrl-o: open in browser    esc: cancel'
[ "$count" -lt "$LIMIT" ] || header="showing first $LIMIT repos"$'\n'"$header"

# Preview filter lives in its own file so it needs no shell escaping.
cat >"$tmpdir/preview.jq" <<'JQ'
.[] | select(.name == $n) |
  "\(.nameWithOwner)\n\n" +
  "visibility  \(.visibility | ascii_downcase)\(if .isFork then ", fork" else "" end)\(if .isArchived then ", archived" else "" end)\n" +
  "language    \(.primaryLanguage.name // "-")\n" +
  "size        \(.diskUsage) KB\n" +
  "pushed      \((.pushedAt // "never")[0:10])\n\n" +
  "--------------------------------------------\n\n" +
  (if (.description // "") == "" then "(no description)" else .description end)
JQ

# ctrl-o needs the owner/name pair, which means a jq lookup; a helper script
# keeps that out of the --bind string where the quoting gets unreadable.
cat >"$tmpdir/open.sh" <<EOF
#!/bin/sh
r=\$(jq -r --arg n "\$1" '.[] | select(.name == \$n) | .nameWithOwner' "$json")
[ -n "\$r" ] && gh repo view "\$r" --web
EOF
chmod +x "$tmpdir/open.sh"

# Name first so it reads as the left column, description after it so fzf can
# match on it. The description has to be visible to be searchable: --with-nth
# hides a field from the query as well as from the display, so there is no
# hidden-but-searchable option. Repo names cannot contain spaces, so {1} is
# always the whole name even after column(1) turns the tab into padding.
name=$(jq -r '.[] | [.name, (.description // "")] | @tsv' "$json" |
	column -t -s "$(printf '\t')" |
	fzf --height=100% \
		--header="$header" \
		--preview="jq -r --arg n {1} -f '$tmpdir/preview.jq' '$json'" \
		--preview-window=right:50%:wrap \
		--bind="ctrl-o:execute-silent('$tmpdir/open.sh' {1})" |
	awk '{print $1}')

# Empty means escape -- not an error, just leave.
[ -n "$name" ] || exit 0

# Refuse rather than let git fail into a half-explained error, and never touch
# what is already there: a name collision here is usually the repo you wanted,
# already cloned.
[ ! -e "$name" ] || die "$PWD/$name already exists"

repo=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .nameWithOwner' "$json")
[ -n "$repo" ] || die "could not resolve an owner for $name"

# gh, not git: it uses the protocol configured in `gh auth status` (ssh here)
# and needs no remote URL spelled out.
printf '\ncloning %s into %s\n\n' "$repo" "$PWD"
gh repo clone "$repo" || die "clone of $repo failed"
