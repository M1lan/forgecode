#!/usr/bin/env bash
# upstream.bash -- keep this fork current without rewriting its history.
#
#   upstream.bash status   how far behind, and what would merge. Read-only.
#   upstream.bash fetch    fetch upstream. Changes no branch.
#   upstream.bash sync     fetch, fast-forward local main, merge into HEAD.
#
# MERGE, NOT REBASE -- this is the whole design decision.
#
# This checkout is a fork: `origin` is the operator's fork, `upstream` is the
# project it was forked from. Local `main` tracks upstream/main and is a pure
# mirror; the work lives on `mymain`, which carried 56 commits at the time
# this was written, and there is a second linked worktree on another branch.
#
# Rebasing mymain onto main would rewrite all 56 SHAs. That invalidates the
# linked worktree, requires a force-push to origin, and destroys the merge
# bases of every other local branch. The old `rebase` recipe did exactly
# that -- and worse, it targeted `main`, the upstream line, while the default
# branch is `mymain`.
#
# A merge costs one commit per sync and keeps every SHA. The existing history
# already reads "Merge branch 'main' into mymain", so this matches what the
# repository has always done.
#
# Pure GNU Bash 5.3+.

# shellcheck source=tools.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/tools.bash"

set -uo pipefail

cd -- "$JUST_REPO_DIR" || exit 1

tools_need git || exit 1

readonly UPSTREAM_REMOTE=upstream
readonly MIRROR_BRANCH=main

have_upstream() {
  git remote get-url "$UPSTREAM_REMOTE" > /dev/null 2>&1
}

require_upstream() {
  have_upstream || just_die "no '$UPSTREAM_REMOTE' remote. add it:
  git remote add $UPSTREAM_REMOTE <url-of-the-project-you-forked>"
}

current_branch() {
  git symbolic-ref --quiet --short HEAD 2> /dev/null ||
    just_die 'detached HEAD -- check out a branch first'
}

do_fetch() {
  require_upstream
  printf 'fetching %s\n' "$UPSTREAM_REMOTE"
  git fetch "$UPSTREAM_REMOTE" --prune --tags
}

do_status() {
  require_upstream
  local branch behind ahead
  branch=$(current_branch)

  printf '%sbranch%s        %s\n' "$C_BOLD" "$C_RESET" "$branch"
  printf '%sorigin%s        %s\n' "$C_BOLD" "$C_RESET" "$(git remote get-url origin 2> /dev/null || printf '(none)')"
  printf '%supstream%s      %s\n' "$C_BOLD" "$C_RESET" "$(git remote get-url "$UPSTREAM_REMOTE")"

  if ! git rev-parse --verify --quiet "$UPSTREAM_REMOTE/$MIRROR_BRANCH" > /dev/null; then
    printf '\nno %s/%s locally -- run: just upstream-fetch\n' "$UPSTREAM_REMOTE" "$MIRROR_BRANCH"
    return 0
  fi

  behind=$(git rev-list --count "$branch..$UPSTREAM_REMOTE/$MIRROR_BRANCH")
  ahead=$(git rev-list --count "$UPSTREAM_REMOTE/$MIRROR_BRANCH..$branch")
  printf '\n%s commits from upstream are not in %s\n' "$behind" "$branch"
  printf '%s commits of your own are not upstream\n' "$ahead"

  if ((behind > 0)); then
    printf '\n%swould merge%s (newest first, max 20):\n' "$C_BOLD" "$C_RESET"
    git log --oneline --no-decorate -20 "$branch..$UPSTREAM_REMOTE/$MIRROR_BRANCH"
    printf '\nrun: just sync-upstream\n'
  fi

  local dirty
  dirty=$(git status --porcelain)
  [[ -n $dirty ]] && printf '\n%sworking tree is dirty -- sync will refuse%s\n' "$C_YELLOW" "$C_RESET"
  return 0
}

do_sync() {
  require_upstream
  local branch
  branch=$(current_branch)

  # A merge that hits conflicts on top of unrelated local edits is a mess to
  # unpick, so refuse before starting rather than half-way through.
  [[ -z $(git status --porcelain) ]] ||
    just_die 'working tree is dirty -- commit or stash before syncing'

  do_fetch || exit 1

  # Fast-forward the mirror branch WITHOUT checking it out, so the working
  # tree never leaves the branch you are actually on.
  if git rev-parse --verify --quiet "$MIRROR_BRANCH" > /dev/null; then
    if [[ $branch == "$MIRROR_BRANCH" ]]; then
      git merge --ff-only "$UPSTREAM_REMOTE/$MIRROR_BRANCH" || exit 1
    else
      git fetch . "$UPSTREAM_REMOTE/$MIRROR_BRANCH:$MIRROR_BRANCH" ||
        just_die "local '$MIRROR_BRANCH' has diverged from $UPSTREAM_REMOTE/$MIRROR_BRANCH.
it is meant to be a pure mirror. inspect it, then reset it deliberately."
      printf 'fast-forwarded %s to %s/%s\n' "$MIRROR_BRANCH" "$UPSTREAM_REMOTE" "$MIRROR_BRANCH"
    fi
  else
    git branch "$MIRROR_BRANCH" "$UPSTREAM_REMOTE/$MIRROR_BRANCH" || exit 1
    printf 'created mirror branch %s\n' "$MIRROR_BRANCH"
  fi

  [[ $branch == "$MIRROR_BRANCH" ]] && {
    printf 'on %s -- nothing further to merge\n' "$MIRROR_BRANCH"
    return 0
  }

  local behind
  behind=$(git rev-list --count "$branch..$MIRROR_BRANCH")
  ((behind == 0)) && {
    printf '%s is already up to date with upstream\n' "$branch"
    return 0
  }

  printf 'merging %s commits from %s into %s\n' "$behind" "$MIRROR_BRANCH" "$branch"
  if git merge --no-edit "$MIRROR_BRANCH"; then
    printf '\n%smerged.%s next: just verify\n' "$C_GREEN" "$C_RESET"
  else
    printf '\n%sconflicts.%s resolve them, then:\n' "$C_YELLOW" "$C_RESET" >&2
    printf '  git status            see what conflicts\n' >&2
    printf '  git merge --continue  when resolved\n' >&2
    printf '  git merge --abort     to back out entirely\n' >&2
    return 1
  fi
}

case "${1:-status}" in
  status) do_status ;;
  fetch) do_fetch ;;
  sync) do_sync ;;
  *)
    printf 'usage: upstream.bash {status|fetch|sync}\n' >&2
    exit 2
    ;;
esac
