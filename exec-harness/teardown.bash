#!/usr/bin/env bash
# exec-harness teardown — P7 ONLY. Removes exec-harness/ in one commit
# after done-done. Full history remains in git. Operator pre-authorized
# this deletion (feedback 2026-07-24); still gated on --yes AND a fully
# closed LEDGER.
set -euo pipefail

[[ ${BASH_VERSINFO[0]} -ge 5 && ${BASH_VERSINFO[1]} -ge 3 ]] ||
  {
    printf 'need Bash >= 5.3 (got %s)\n' "$BASH_VERSION" >&2
    exit 69
  }

[[ ${1:-} == '--yes' ]] || {
  printf 'usage: %s --yes\n' "${0##*/}" >&2
  printf 'refuses without done-done: all LEDGER items [x] + operator word\n' >&2
  exit 64
}

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repo_root"

# refuse while any LEDGER task is open/in-progress/blocked
if rg -q '^\- \[( |~|!)\]' exec-harness/LEDGER.md; then
  printf 'LEDGER has open items — not done-done. Refusing.\n' >&2
  rg -n '^\- \[( |~|!)\]' exec-harness/LEDGER.md >&2
  exit 65
fi

git rm -r --quiet exec-harness
git commit --quiet -m 'remove exec-harness: deep-analysis done-done'
printf 'exec-harness removed; history preserved in git (%s)\n' \
  "$(git rev-parse --short HEAD)"
