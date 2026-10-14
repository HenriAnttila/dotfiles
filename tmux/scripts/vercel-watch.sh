#!/bin/bash
# Vercel build status in tmux status-right, driven by git push.
# Usage: run as a global pre-push hook (git config hook.vercel-watch.*).
#
# The hook reads the pushed SHA, forks a detached watcher and returns at once,
# so the push is never delayed. The watcher finds the Vercel deployment whose
# githubCommitSha matches, polls it until it settles, and writes the result to
# the tmux option @vercel_status, which status-right renders. Repos without
# .vercel/project.json are ignored. The newest push owns the segment: an older
# watcher stops as soon as it sees a different owner.

PATH="/opt/homebrew/bin:/opt/anaconda3/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

AUTH="$HOME/Library/Application Support/com.vercel.cli/auth.json"
POLL=5
FIND_TIMEOUT=120
BUILD_TIMEOUT=1800
LINGER=300

set_status() {
  tmux set -g @vercel_status "$1" 2>/dev/null
}

owns() {
  [ "$(tmux show -gv @vercel_owner 2>/dev/null)" = "$OWNER" ]
}

watch() {
  local root=$1 sha=$2
  local name token project team
  name=$(basename "$root")
  token=$(jq -r '.token // empty' "$AUTH" 2>/dev/null)
  project=$(jq -r '.projectId // empty' "$root/.vercel/project.json")
  team=$(jq -r '.orgId // empty' "$root/.vercel/project.json")
  [ -n "$token" ] && [ -n "$project" ] || exit 0

  OWNER="$$:$sha"
  tmux set -g @vercel_owner "$OWNER" 2>/dev/null
  local sep="#[fg=#{@faint}]│ "
  set_status "#[fg=#{@accent}]▲ #[fg=default]$name building… $sep"

  local start=$SECONDS uid="" state=""
  while owns; do
    sleep "$POLL"
    owns || exit 0
    if [ -z "$uid" ]; then
      uid=$(curl -s -m 10 -H "Authorization: Bearer $token" \
        "https://api.vercel.com/v6/deployments?projectId=$project&teamId=$team&limit=20" |
        jq -r --arg sha "$sha" '[.deployments[]? | select(.meta.githubCommitSha == $sha)][0].uid // empty')
      if [ -z "$uid" ]; then
        if (( SECONDS - start > FIND_TIMEOUT )); then
          set_status ""
          exit 0
        fi
        continue
      fi
    fi
    state=$(curl -s -m 10 -H "Authorization: Bearer $token" \
      "https://api.vercel.com/v13/deployments/$uid?teamId=$team" | jq -r '.readyState // empty')
    case $state in
      READY) final="#[fg=#98C379]▲ #[fg=default]$name build complete $sep" ;;
      ERROR) final="#[fg=#E06C75]▲ #[fg=default]$name build failed $sep" ;;
      CANCELED) final="#[fg=#{@muted}]▲ #[fg=default]$name build canceled $sep" ;;
      *)
        (( SECONDS - start > BUILD_TIMEOUT )) && { set_status ""; exit 0; }
        continue
        ;;
    esac
    owns || exit 0
    set_status "$final"
    sleep "$LINGER"
    owns && set_status ""
    exit 0
  done
}

if [ "$1" = "--watch" ]; then
  watch "$2" "$3"
  exit 0
fi

root=$(git rev-parse --show-toplevel 2>/dev/null)
sha=""
while read -r _local_ref local_sha _remote_ref _remote_sha; do
  case $local_sha in
    *[!0]*) [ -z "$sha" ] && sha=$local_sha ;;
  esac
done

[ -n "$root" ] && [ -n "$sha" ] && [ -f "$root/.vercel/project.json" ] || exit 0

nohup "$0" --watch "$root" "$sha" </dev/null >/dev/null 2>&1 &
exit 0
