#!/usr/bin/env bash
# ci.bash -- the one gate. Fixes what it can, then proves the rest.
#
#   ci.bash          fix, then verify   (this is `just ci`)
#   ci.bash --check  verify only, writes nothing (hooks, pre-push)
#
# WHY THERE IS ONLY ONE
# There used to be `verify` and `ci` with different, overlapping step lists,
# so "did it pass?" depended on which one you happened to run. Worse, both
# only ever checked: a formatting drift or a machine-applicable clippy lint
# printed a complaint and made the operator go run the fixer by hand, every
# time. Anything a tool can repair, this repairs.
#
# PHASE 1 REPAIRS, PHASE 2 PROVES.
# Phase 2 re-runs the same tools in check mode. That is not redundant: it is
# what catches the lints that have no automatic fix, and it means a green
# `just ci` is a real statement about the tree rather than about the fixer.
#
# Pure GNU Bash 5.3+.

# shellcheck source=tools.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/tools.bash"

set -uo pipefail

cd -- "$JUST_REPO_DIR" || exit 1

FIX=1
[[ ${1:-} == --check ]] && FIX=0
readonly FIX

declare -i failed=0
declare -a failed_steps=()

banner() { printf '\n%s=== %s ===%s\n' "$C_BOLD" "$1" "$C_RESET"; }

step() { # <label> <command...>
  local label=$1
  shift
  printf '\n%s-> %s%s\n' "$C_DIM" "$label" "$C_RESET"
  if "$@"; then
    printf '   %s%s ok%s\n' "$C_GREEN" "$label" "$C_RESET"
  else
    printf '   %s%s FAILED%s\n' "$C_RED" "$label" "$C_RESET" >&2
    failed=1
    failed_steps+=("$label")
  fi
}

nightly_fmt() {
  PATH="$(rustup run nightly rustc --print sysroot)/bin:$PATH" cargo fmt --all "$@"
}

# WHICH FILES MAY A FIXER TOUCH?
#
# rustfmt and `clippy --fix` may touch anything: GitHub's autofix workflow
# runs the identical commands, so their output is what upstream converges on.
# Applying them here creates no divergence.
#
# Prose fixers are the opposite. Running `rumdl fmt .` once reformatted 106
# files -- including templates/, which are prompt templates compiled into
# the binary and asserted by snapshots (it broke three tests), and plans/,
# which is historical record. `typos --write-changes` rewrote identifiers in
# upstream crates. Every one of those edits is a permanent conflict point
# against `upstream/main` in exchange for cosmetics.
#
# So prose fixers run ONLY over paths this fork owns. Everything else is
# reported, and fixed deliberately one file at a time with
# `just maint-typos-fix <file>` / `just maint-rumdl-fix <file>`.
FORK_OWNED=(Justfile mise.toml typos.toml betterhook.toml '.just' 'docs/justfile.md')

fork_owned_files() { # <extension-glob>...
  local -a files=()
  mapfile -t files < <(git ls-files -- "${FORK_OWNED[@]}" | rg "$1")
  printf '%s\n' "${files[@]}"
}

typos_fix_scoped() {
  local -a files=()
  mapfile -t files < <(fork_owned_files '\.(rs|md|toml|bash|sh)$')
  ((${#files[@]} == 0)) && return 0
  typos --write-changes -- "${files[@]}"
}

rumdl_fix_scoped() {
  local -a files=()
  mapfile -t files < <(fork_owned_files '\.md$')
  ((${#files[@]} == 0)) && return 0
  rumdl fmt "${files[@]}"
}

# --- phase 1: repair ---
declare diff_before='' repaired=''

if ((FIX)); then
  banner 'FIX -- repairing what can be repaired'
  tools_need rustfmt clippy || exit 1
  diff_before=$(git diff --numstat | sort)

  step 'rustfmt (nightly, writes)' nightly_fmt
  step 'clippy --fix (writes)' \
    cargo clippy --workspace --all-targets --all-features \
    --fix --allow-dirty --allow-staged
  tool_present typos && step 'typos (fork-owned files)' typos_fix_scoped
  tool_present rumdl && step 'rumdl fmt (fork-owned files)' rumdl_fix_scoped
  step 'regenerate docs/justfile.md' "$JUST_HELPERS_DIR/docs.bash" --write

  # Report only what THIS phase changed, not the whole working tree. Comparing
  # `git diff --numstat` before and after isolates it: a file the operator had
  # already edited only shows up if a fixer changed its line counts too.
  repaired=$(comm -13 <(printf '%s' "$diff_before") <(git diff --numstat | sort))
  if [[ -n $repaired ]]; then
    printf '\n%srepaired by this run:%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s\n' "$repaired" | awk '{printf "  %-46s +%s -%s\n", $3, $1, $2}'
  else
    printf '\n%snothing needed repairing%s\n' "$C_DIM" "$C_RESET"
  fi
fi

# --- phase 2: prove ---
banner 'VERIFY -- proving the tree'
tools_need rustfmt clippy shellcheck cargo-nextest || exit 1

step 'formatting' nightly_fmt -- --check
step 'clippy -D warnings' env RUSTFLAGS=-Dwarnings \
  cargo clippy --workspace --all-targets --all-features
# The string-safety lane GitHub's autofix workflow runs. Two pre-existing
# violations in forge_select were fixed on this branch (see the FORK PATCH
# comments there) so this is now a real, passing gate rather than a
# permanently-red one.
step 'clippy string-safety lane' \
  cargo clippy --all-features --workspace -- \
  -D clippy::string_slice -D clippy::indexing_slicing -D clippy::disallowed_methods
step 'shell lint' "$JUST_HELPERS_DIR/lint-shell.bash"
step 'shell parse-check' "$JUST_HELPERS_DIR/test-shell.bash"
# CI=1 flips the schema test from write to assert, so a verification run
# cannot quietly regenerate forge.schema.json or the workflow YAML.
step 'tests (read-only)' env CI=1 cargo nextest run --workspace
step 'docs current' "$JUST_HELPERS_DIR/docs.bash" --check
tool_present typos && step 'spelling' typos

# --- verdict ---
printf '\n'
if ((failed)); then
  printf '%sFAILED:%s %s\n' "$C_RED" "$C_RESET" "${failed_steps[*]}" >&2
  ((FIX)) && printf 'anything auto-fixable was already fixed -- what is left needs a human.\n' >&2
  exit 1
fi
printf '%sPASS%s -- tree verified\n' "$C_GREEN" "$C_RESET"
[[ -n $repaired ]] &&
  printf '%snote: the fix phase modified files; review and commit them.%s\n' \
    "$C_YELLOW" "$C_RESET"
exit 0
