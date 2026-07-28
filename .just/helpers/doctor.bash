#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.bash"

version_or_missing() {
  local tool=$1 version=''

  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'missing'
    return
  fi

  IFS= read -r version < <("$tool" --version 2>/dev/null) || true
  printf '%s' "${version:-available}"
}

main() {
  local tool index state

  printf 'ForgeCode developer tooling\n'
  printf '%-12s %s\n' tool state
  printf '%-12s %s\n' '------------' '------------------------------'

  for tool in just fzf gum jq shellcheck gitnexus codegraph grepai repowise ast-grep probe semgrep tokei; do
    printf '%-12s %s\n' "$tool" "$(version_or_missing "$tool")"
  done

  printf '\nAI indexes\n'
  for index in .gitnexus .codegraph .grepai .repowise; do
    if [[ -e "$JUST_REPO_DIR/$index" ]]; then
      state=ready
    else
      state=missing
    fi
    printf '%-12s %s\n' "$index" "$state"
  done

  printf '\nNext: just ai-init; just ai-sync; just menu\n'
}

main "$@"
