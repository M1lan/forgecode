#!/usr/bin/env bash
# maint.bash -- bounded, evidence-first maintenance.
#
#   maint.bash evidence          advisories, typos, unused deps, lint summary
#   maint.bash audit-brief       one line per advisory
#   maint.bash typos-fix <file>  fix typos in ONE file, print the diff
#   maint.bash rumdl-fix <file>  format ONE markdown file, print the diff stat
#   maint.bash shellcheck-diff <file>   shellcheck's patch, for review only
#
# PROVENANCE. Ported from the agent-maint-justfile branch, which forked
# before the Justfile was restructured and so could not be merged textually.
# The original reasoning is preserved; the silent
# `command -v X || echo "X not installed -- skipping"` pattern is not --
# every entry point now fails loud through tools.bash.
#
# DELIBERATELY ABSENT, with the evidence that put them here (2026-07-24):
#   - bulk `cargo update`: most advisories here sit behind semver
#     walls (rustls 0.21, hyper-0.14, the aws-smithy chain, syntect). A
#     blanket update cannot fix them and will churn the lockfile. Inspect
#     one at a time with `just maint-pin-why <crate>`.
#   - blanket shellcheck auto-apply: scripts/benchmark.sh relies on
#     intentional word-splitting, so an automatic patch breaks it. Read the
#     diff, apply by hand.
#   - `cargo machete --fix`: false positives on macro-only dependencies.
#
# Pure GNU Bash 5.3+.

# shellcheck source=tools.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/tools.bash"

set -uo pipefail

cd -- "$JUST_REPO_DIR" || exit 1

section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"; }

# One line per advisory: ID crate@version fix title.
#
# Parses cargo-audit's TEXT report rather than its --json output. The JSON
# path would be shorter, but the top-level key it requires is a token that
# this machine's global commit hook rejects in file content (rule E012 in
# ~/.config/git/hooks/text-boundary.bash), and that hook offers only a
# filename-scoped vendor exemption -- not a content one. Working around a
# governance rule by obfuscating the string would defeat its purpose, so the
# text report it is. The fields below are stable across cargo-audit 0.2x.
#
# cargo audit exits non-zero when it finds anything. Here that is data, not
# failure, so the status is deliberately not propagated.
audit_brief() {
  tools_need cargo-audit || return 1
  # Records are flushed on the NEXT `Crate:` (and at END), not on `ID:`.
  # cargo-audit prints Crate, Version, Title, Date, ID, URL, Solution in that
  # order, and unmaintained/unsound warnings carry no Solution line at all --
  # so emitting at `ID:` attributed the previous record's fix to this one.
  cargo audit 2> /dev/null | awk '
    function flush() {
      if (id != "") {
        n++
        printf "%-20s %s@%s\n", id, crate, version
        printf "%-20s fix: %s\n", "", (fix != "" ? fix : "none published")
        printf "%-20s %s\n\n", "", title
      }
      crate = ""; version = ""; title = ""; id = ""; fix = ""
    }
    /^Crate:/    { flush(); crate = $2 }
    /^Version:/  { version = $2 }
    /^Title:/    { sub(/^Title:[[:space:]]*/, ""); title = $0 }
    /^ID:/       { id = $2 }
    /^Solution:/ { sub(/^Solution:[[:space:]]*/, ""); fix = $0 }
    END          { flush(); printf "%d advisories\n", n }
  ' || true
}

evidence() {
  section 'RUSTSEC advisories'
  audit_brief || printf '(cargo-audit or jq missing -- see just doctor)\n'

  section 'typos (typos.toml exempts deliberate fixtures)'
  if tool_present typos; then typos --format brief | head -30 || true; else
    printf 'typos missing -- %s\n' "$(tool_hint typos)"
  fi

  section 'unused deps (false positives on macro-only deps are expected)'
  if tool_present cargo-machete; then cargo machete 2> /dev/null | head -40 || true; else
    printf 'cargo-machete missing -- %s\n' "$(tool_hint cargo-machete)"
  fi

  section 'shell lint'
  if tool_present shellcheck; then
    "$JUST_HELPERS_DIR/lint-shell.bash" 2>&1 | tail -20 || true
  else
    printf 'shellcheck missing -- %s\n' "$(tool_hint shellcheck)"
  fi

  section 'markdown lint'
  if tool_present rumdl; then rumdl check . 2> /dev/null | tail -3 || true; else
    printf 'rumdl missing -- %s\n' "$(tool_hint rumdl)"
  fi
}

# One file, one change, one diff. Never a sweep: a typo "fix" inside a
# snapshot or a fixture changes test data, not prose.
typos_fix() {
  local file=${1:?file required}
  tools_need typos || return 1
  case $file in
    *.snap | *.snap.html | *fixtures* | *snapshots*)
      just_die "refusing generated/fixture file: $file"
      ;;
  esac
  [[ -f $file ]] || just_die "no such file: $file"
  typos --write-changes "$file"
  git --no-pager diff -- "$file"
  printf '\n%srun the owning crate tests before committing%s\n' "$C_YELLOW" "$C_RESET"
}

rumdl_fix() {
  local file=${1:?file required}
  tools_need rumdl || return 1
  [[ -f $file ]] || just_die "no such file: $file"
  rumdl check "$file" || true
  rumdl fmt "$file"
  git --no-pager diff --stat -- "$file"
}

shellcheck_diff() {
  local file=${1:?file required}
  tools_need shellcheck || return 1
  [[ -f $file ]] || just_die "no such file: $file"
  printf '%sreview only -- this patch is never applied automatically%s\n\n' "$C_DIM" "$C_RESET"
  shellcheck --exclude=SC1071 -f diff "$file" || true
}

case "${1:-evidence}" in
  evidence) evidence ;;
  audit-brief) audit_brief ;;
  typos-fix)
    shift
    typos_fix "$@"
    ;;
  rumdl-fix)
    shift
    rumdl_fix "$@"
    ;;
  shellcheck-diff)
    shift
    shellcheck_diff "$@"
    ;;
  *)
    printf 'usage: maint.bash {evidence|audit-brief|typos-fix <f>|rumdl-fix <f>|shellcheck-diff <f>}\n' >&2
    exit 2
    ;;
esac
