#!/usr/bin/env bash
# clean.bash -- reclaim disk, repo-locally, never silently.
#
#   clean.bash report        what each location costs. Read-only.
#   clean.bash target        cargo clean
#   clean.bash stale         incremental caches + stale profile dirs only
#   clean.bash indexes       local AI index dirs -> Trash, after confirming
#   clean.bash sandbox       the .forge-sandbox state dir -> Trash
#   clean.bash all           everything repo-local, after confirming
#   clean.bash assert-clean  exit 1 if git reports a dirty tree
#
# SCOPE IS A HARD BOUNDARY. Nothing here touches ~/.cargo/registry (1.9 GB),
# ~/.cargo/git, or any path outside this repository. Those caches are shared
# by every Rust project on the machine; clearing them from a project-local
# recipe would silently cost every other checkout a full re-download.
#
# DELETION POLICY. Anything that is not a build artifact goes to the macOS
# Trash via `trash`, never `rm -rf`, and only after an explicit confirmation.
# `cargo clean` is exempt: target/ is reproducible output, and cargo owns it.
#
# Pure GNU Bash 5.3+.

# shellcheck source=tools.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/tools.bash"

set -uo pipefail

cd -- "$JUST_REPO_DIR" || exit 1

readonly INDEX_DIRS=(.codegraph .grepai .gitnexus .repowise)
readonly SANDBOX_DIR=.forge-sandbox

# Human-readable size of a path, or "-" when it does not exist.
size_of() {
  [[ -e $1 ]] || {
    printf '-'
    return
  }
  du -sh -- "$1" 2> /dev/null | cut -f1
}

report() {
  printf '%s%-20s %10s%s\n' "$C_BOLD" 'location' 'on disk' "$C_RESET"
  local d
  for d in target node_modules "$SANDBOX_DIR" "${INDEX_DIRS[@]}" .git; do
    printf '%-20s %10s\n' "$d" "$(size_of "$d")"
  done
  # Shown for context only. These are shared by every Rust checkout on the
  # machine, so no recipe here may remove them -- see the header.
  printf '\n%soutside this repo -- NOT touched by any clean recipe%s\n' "$C_DIM" "$C_RESET"
  local shared
  for shared in "$HOME/.cargo/registry" "$HOME/.cargo/git"; do
    printf '%-20s %10s\n' "${shared/#"$HOME"/\~}" "$(size_of "$shared")"
  done
}

# Ask before destroying anything. Non-interactive callers must set
# JUST_CLEAN_YES=1 explicitly -- silence is never taken as consent.
confirm() {
  local prompt=$1
  if [[ ${JUST_CLEAN_YES:-} == 1 ]]; then
    printf '%s -- proceeding (JUST_CLEAN_YES=1)\n' "$prompt"
    return 0
  fi
  if ! is_tty; then
    printf '%s\nrefusing: not a terminal and JUST_CLEAN_YES is unset\n' "$prompt" >&2
    return 1
  fi
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ $reply == [yY] ]]
}

# Trash, never rm. Only paths inside the repo are ever passed here.
to_trash() {
  local p
  tools_need trash || return 1
  for p in "$@"; do
    [[ -e $p ]] || continue
    trash -- "$p" && printf '  trashed %s\n' "$p"
  done
}

clean_target() {
  printf 'target/ is %s\n' "$(size_of target)"
  cargo clean
  printf 'target/ removed\n'
}

# Incremental caches are the fastest-growing and least valuable part of
# target/. Dropping them keeps the dependency builds, which are the
# expensive half, so the next build is warm rather than cold.
clean_stale() {
  local before after d
  before=$(size_of target)
  local -a incr=()
  mapfile -t incr < <(fd -H -I -t d '^incremental$' target 2> /dev/null)
  if ((${#incr[@]} == 0)); then
    printf 'no incremental caches found\n'
  else
    for d in "${incr[@]}"; do
      rm -rf -- "$d" && printf '  dropped %s\n' "$d"
    done
  fi
  after=$(size_of target)
  printf 'target/: %s -> %s\n' "$before" "$after"
}

clean_indexes() {
  local d present=()
  for d in "${INDEX_DIRS[@]}"; do [[ -e $d ]] && present+=("$d"); done
  if ((${#present[@]} == 0)); then
    printf 'no index dirs present\n'
    return 0
  fi
  printf 'these are local AI indexes, rebuildable with `just ai init`:\n'
  for d in "${present[@]}"; do printf '  %-14s %s\n' "$d" "$(size_of "$d")"; done
  confirm 'move them to Trash?' || {
    printf 'cancelled\n'
    return 0
  }
  to_trash "${present[@]}"
}

clean_sandbox() {
  [[ -e $SANDBOX_DIR ]] || {
    printf 'no sandbox state dir\n'
    return 0
  }
  printf '%s is %s\n' "$SANDBOX_DIR" "$(size_of "$SANDBOX_DIR")"
  confirm 'move the run sandbox to Trash?' || {
    printf 'cancelled\n'
    return 0
  }
  to_trash "$SANDBOX_DIR"
}

clean_all() {
  report
  printf '\n'
  confirm 'clean target/, node_modules/, indexes and sandbox?' || {
    printf 'cancelled\n'
    return 0
  }
  cargo clean
  to_trash node_modules "$SANDBOX_DIR" "${INDEX_DIRS[@]}"
  printf '\nafter:\n'
  report
}

# Used by `just verify-clean-tree`. A green test run that quietly rewrote
# .github/workflows/*.yml, forge.schema.json or a snapshot is not green.
assert_clean() {
  local dirty
  dirty=$(git -C "$JUST_REPO_DIR" status --porcelain) || exit 1
  [[ -z $dirty ]] && {
    printf 'working tree clean\n'
    return 0
  }
  printf 'working tree is dirty after the run:\n\n%s\n\n' "$dirty" >&2
  printf 'generated files that a test run rewrites:\n' >&2
  printf '  .github/workflows/*.yml   crates/forge_ci/tests/ci.rs\n' >&2
  printf '  forge.schema.json         crates/forge_config/tests/schema.rs\n' >&2
  printf '  **/snapshots/*.snap       insta --accept\n' >&2
  return 1
}

case "${1:-report}" in
  report) report ;;
  target) clean_target ;;
  stale) clean_stale ;;
  indexes) clean_indexes ;;
  sandbox) clean_sandbox ;;
  all) clean_all ;;
  assert-clean) assert_clean ;;
  *)
    printf 'usage: clean.bash {report|target|stale|indexes|sandbox|all|assert-clean}\n' >&2
    exit 2
    ;;
esac
