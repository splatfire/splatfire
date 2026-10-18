#!/usr/bin/env bash
# Keeps Cursor (on your Mac) and Claude Code (in the cloud) in sync through
# GitHub, so whichever app you open next knows where you left off.
#
#   ./handoff.sh start            get the newest work + show HANDOFF.md
#   ./handoff.sh save "message"   save everything and send it to GitHub
#   ./handoff.sh status           show what's changed and not saved yet
#
# Rule: use one app at a time, and `save` before switching apps.
set -euo pipefail
cd "$(dirname "$0")"

BRANCH="claude/nice-bardeen-84bg5p"

on_branch() {
  local current
  current=$(git rev-parse --abbrev-ref HEAD)
  if [ "$current" != "$BRANCH" ]; then
    echo "You're on branch '$current' – switching to '$BRANCH'."
    git checkout "$BRANCH"
  fi
}

no_conflicts() {
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    echo "✗ Some files have unfinished merge conflicts:"
    git diff --name-only --diff-filter=U | sed 's/^/  /'
    echo "Ask the AI (Cursor or Claude) to fix them – don't delete anything yourself."
    exit 1
  fi
}

pull_newest() {
  git fetch -q origin "$BRANCH"
  if ! git pull -q --rebase --autostash origin "$BRANCH"; then
    echo "✗ Your changes and the newest version on GitHub clash."
    echo "Ask the AI to sort it out (tell it: 'handoff.sh start reported a conflict')."
    exit 1
  fi
}

case "${1:-}" in
  start)
    on_branch
    no_conflicts
    pull_newest
    echo "✓ Up to date with GitHub ($(git log -1 --format='%h %s' | cut -c1-70))"
    echo
    cat HANDOFF.md
    ;;
  save)
    MESSAGE="${2:-Save work in progress}"
    on_branch
    no_conflicts
    git add -A
    if git diff --cached --quiet; then
      echo "Nothing new to save."
    else
      git commit -q -m "$MESSAGE"
      echo "✓ Saved: $MESSAGE"
    fi
    pull_newest
    git push -q origin "HEAD:$BRANCH"
    echo "✓ Sent to GitHub. The other app will see it after its 'start'."
    ;;
  status)
    git status --short
    git fetch -q origin "$BRANCH" || true
    behind=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo "?")
    ahead=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo "?")
    echo "Not yet on this computer: $behind change(s). Not yet on GitHub: $ahead change(s)."
    ;;
  *)
    sed -n '2,10p' "$0"
    exit 1
    ;;
esac
