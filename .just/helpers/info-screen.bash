#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.bash"

main() {
  local branch

  branch=$(cd -- "$JUST_REPO_DIR" && git branch --show-current 2>/dev/null || printf 'detached')
  printf 'ForgeCode\n'
  printf 'branch: %s\n' "$branch"
  printf 'rust:   %s\n' "$(rustc --version)"
  printf 'cargo:  %s\n' "$(cargo --version)"
  printf 'just:   %s\n' "$(just --version)"
  printf 'menu:   just menu\n'
  printf 'health: just doctor\n'
  printf 'indexes: just ai-doctor\n'
}

main "$@"
