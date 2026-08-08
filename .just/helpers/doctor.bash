#!/usr/bin/env bash
# doctor.bash -- dependency + project audit for the ForgeCode Justfile.
#
#   doctor.bash             full table
#   doctor.bash --summary   one-line toolbelt status (used by the info splash)
#   doctor.bash --factoid   single most important fact (splash countdown line)
#
# Exit codes (full-table mode only; --summary/--factoid always exit 0):
#   0  all REQUIRED deps present, project checks pass, and forge is either
#      the canonical ~/.cargo/bin/forge or simply not installed yet (a
#      fresh clone has no forge on PATH at all -- that is not a failure)
#   1  a REQUIRED dep is missing, or a project check failed
#   3  forge IS installed but the PATH winner is a shadow, not the fixed
#      canonical ~/.cargo/bin/forge (see `just install-audit`)
#
# Pure GNU Bash 5.3+. Colors: terminal defaults via tput only.

# shellcheck source=lib.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

set -uo pipefail

# --- dependency catalogue ---
# Three tiers: REQUIRED (gate breaks without them), RECOMMENDED, OPTIONAL.
REQUIRED=(bash just cargo rustc clippy rustfmt git rg fd jq)
RECOMMENDED=(gum fzf bat figlet cargo-insta shellcheck rumdl)
OPTIONAL=(cargo-nextest cargo-deny cargo-llvm-cov cargo-audit cargo-outdated
  cargo-watch cargo-machete cargo-bloat betterhook
  gitnexus codegraph grepai repowise ast-grep probe semgrep tokei)

# brew formula when it differs from the command name
declare -A PKG=(
  [rg]=ripgrep
)

# install source (brew, rustup, cargo, or other -- see WHY hints)
declare -A SRC=(
  [bash]=brew [just]=brew [git]=brew [rg]=brew [fd]=brew [jq]=brew
  [gum]=brew [fzf]=brew [bat]=brew [figlet]=brew
  [shellcheck]=brew [rumdl]=brew ['ast-grep']=brew [semgrep]=brew [tokei]=brew
  [cargo]=rustup [rustc]=rustup [clippy]=rustup [rustfmt]=rustup
  ['cargo-nextest']=cargo ['cargo-deny']=cargo ['cargo-llvm-cov']=cargo
  ['cargo-audit']=cargo ['cargo-outdated']=cargo ['cargo-watch']=cargo
  ['cargo-machete']=cargo ['cargo-bloat']=cargo ['cargo-insta']=cargo
  [betterhook]=cargo
  [gitnexus]=other [codegraph]=other [grepai]=other [repowise]=other [probe]=other
)

install_cmd() {
  local t="$1" src="${SRC[$1]:-brew}"
  # rustfmt is required at the NIGHTLY toolchain specifically (fmt/fmt-check
  # invoke it via `rustup run nightly`) -- `rustup component add rustfmt`
  # alone targets the default toolchain and would not fix the real gap.
  if [[ "$t" == rustfmt ]]; then
    printf 'rustup toolchain install nightly && rustup component add rustfmt --toolchain nightly'
    return
  fi
  case "$src" in
    rustup) printf 'rustup component add %s' "$t" ;;
    cargo) printf 'cargo install %s' "${PKG[$t]:-$t}" ;;
    other) printf 'see: ./scripts/ai-tools.bash doctor' ;;
    *) printf 'brew install %s' "${PKG[$t]:-$t}" ;;
  esac
}

declare -A WHY=(
  [bash]='helper runtime (GNU >= 5.3)'
  [just]='the task runner'
  [cargo]='build & test (Cargo workspace)'
  [rustc]='Rust compiler'
  [clippy]='lint gate (-D warnings)'
  [rustfmt]='format gate (nightly)'
  [git]='version control'
  [rg]='search (never grep)'
  [fd]='file finder (never find)'
  [jq]='just --dump JSON parsing (menu, this doctor)'
  [gum]='TUI: splash panels + menu parameter forms'
  [fzf]='TUI: menu list engine'
  [bat]='syntax-highlighted recipe previews'
  [figlet]='banner art on the splash'
  ['cargo-insta']='snapshot test runner (just test)'
  [shellcheck]='lint .just/helpers/ + scripts/*.bash'
  [rumdl]='markdown linting (just rumdl)'
  ['cargo-nextest']='fast parallel test runner (just test-nextest)'
  ['cargo-deny']='license + advisory audit (just deny)'
  ['cargo-llvm-cov']='coverage reports (just coverage)'
  ['cargo-audit']='security advisory scan (just audit)'
  ['cargo-outdated']='outdated dep report (just outdated)'
  ['cargo-watch']='live rebuild loop (just watch)'
  ['cargo-machete']='unused dependency check (just machete)'
  ['cargo-bloat']='binary size breakdown (just bloat)'
  [betterhook]='git hooks manager (just hooks)'
  [gitnexus]='AI code graph (just gitnexus)'
  [codegraph]='AI code graph (just codegraph)'
  [grepai]='AI semantic search (just grepai)'
  [repowise]='AI defect-risk wiki (just repowise)'
  ['ast-grep']='structural code search'
  [probe]='ranked token-budgeted code search'
  [semgrep]='pattern-based security scan'
  [tokei]='LOC / language stats (just loc)'
)

# --- check helpers ---
# clippy is invoked as `cargo clippy`; its binary is `cargo-clippy`, there is
# no `clippy` on PATH -- probe the real binary instead. rustfmt must be
# available on the NIGHTLY toolchain specifically (fmt/fmt-check run it via
# `rustup run nightly`) -- a stable-only rustfmt on PATH is not enough.
declare -A PROBE=(
  [clippy]=cargo-clippy
)
tool_present() {
  case "$1" in
    rustfmt) rustup run nightly rustfmt --version > /dev/null 2>&1 ;;
    *) has "${PROBE[$1]:-$1}" ;;
  esac
}
is_missing() { ! tool_present "$1"; }

check_tier() { # <tier_name> <tool...>
  local tier="$1" t missing=() present=()
  shift
  for t in "$@"; do
    if tool_present "$t"; then present+=("$t"); else missing+=("$t"); fi
  done
  printf '%s%s%s' "$C_BOLD" "$tier" "$C_RESET"
  printf ' (%d/%d)\n' "${#present[@]}" "$#"
  for t in "$@"; do
    if tool_present "$t"; then
      printf '  %s%-16s%s %s -- %s\n' "$C_GREEN" "$t" "$C_RESET" "ok" "${WHY[$t]:-}"
    else
      printf '  %s%-16s%s %s -- %s\n' "$C_RED" "$t" "$C_RESET" "MISSING" "${WHY[$t]:-}"
      printf '        hint: %s\n' "$(install_cmd "$t")"
    fi
  done
}

# --- project-specific checks ---
check_project() {
  printf '\n%sPROJECT CHECKS%s\n' "$C_BOLD" "$C_RESET"
  local ok=1

  if git -C "$JUST_REPO_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    printf '  %s%-20s%s ok\n' "$C_GREEN" 'git repo' "$C_RESET"
  else
    printf '  %s%-20s%s NOT A GIT REPO\n' "$C_RED" 'git repo' "$C_RESET"
    ok=0
  fi

  if rg -q '^\[workspace\]' "$JUST_REPO_DIR/Cargo.toml" 2> /dev/null; then
    printf '  %s%-20s%s workspace, %s crates\n' "$C_GREEN" 'Cargo.toml' "$C_RESET" "$(fact_workspace_crates)"
  else
    printf '  %s%-20s%s MISSING or not a workspace\n' "$C_RED" 'Cargo.toml' "$C_RESET"
    ok=0
  fi

  if [[ -f "$JUST_REPO_DIR/rust-toolchain.toml" ]]; then
    printf '  %s%-20s%s channel %s\n' "$C_GREEN" 'rust-toolchain.toml' "$C_RESET" "$(fact_toolchain)"
  else
    printf '  %s%-20s%s missing (rustup default channel used)\n' "$C_YELLOW" 'rust-toolchain.toml' "$C_RESET"
  fi

  if [[ -f "$JUST_REPO_DIR/betterhook.toml" ]]; then
    printf '  %s%-20s%s ok\n' "$C_GREEN" 'betterhook.toml' "$C_RESET"
  else
    printf '  %s%-20s%s missing (git hooks not wired)\n' "$C_YELLOW" 'betterhook.toml' "$C_RESET"
  fi

  ((ok)) || return 1
  return 0
}

# --- mode dispatch ---

# --summary: one-line overview for the info splash toolbelt panel
if [[ "${1:-}" == "--summary" ]]; then
  missing_req=() missing_rec=()
  for t in "${REQUIRED[@]}"; do is_missing "$t" && missing_req+=("$t"); done
  for t in "${RECOMMENDED[@]}"; do is_missing "$t" && missing_rec+=("$t"); done
  if ((${#missing_req[@]} > 0)); then
    printf 'REQUIRED missing: %s' "${missing_req[*]}"
  elif ((${#missing_rec[@]} > 0)); then
    printf 'ok  (missing recommended: %s)' "${missing_rec[*]}"
  else
    printf 'all required + recommended present'
  fi
  exit 0
fi

# --factoid: the single most actionable fact for the splash countdown line
if [[ "${1:-}" == "--factoid" ]]; then
  for t in "${REQUIRED[@]}"; do
    if is_missing "$t"; then
      printf 'required dep missing: %s -- %s' "$t" "$(install_cmd "$t")"
      exit 0
    fi
  done
  for t in "${RECOMMENDED[@]}"; do
    if is_missing "$t"; then
      printf 'recommended: %s not found -- %s' "$t" "$(install_cmd "$t")"
      exit 0
    fi
  done
  if git -C "$JUST_REPO_DIR" status --porcelain 2> /dev/null | rg -q .; then
    printf 'tree is dirty -- just lint to check before committing'
  elif [[ ! -x "$JUST_REPO_DIR/target/release/$PKGNAME" ]]; then
    printf 'no release build -- just install-release'
  else
    printf 'all green -- just verify before pushing'
  fi
  exit 0
fi

# --- full audit table ---
printf '\n%sFORGECODE DEPENDENCY AUDIT%s\n\n' "$C_BOLD$C_CYAN" "$C_RESET"
check_tier "REQUIRED" "${REQUIRED[@]}"
printf '\n'
check_tier "RECOMMENDED" "${RECOMMENDED[@]}"
printf '\n'
check_tier "OPTIONAL" "${OPTIONAL[@]}"

project_rc=0
check_project || project_rc=1

# Installed-forge audit: is the `forge` PATH resolves the one this repo
# builds? Deps are useless if the binary under test is a stale shadowed copy.
audit_rc=0
"$JUST_HELPERS_DIR/install-audit.bash" --table || audit_rc=$?

# exit non-zero when a REQUIRED dep is missing or a project check failed
# (makes this CI-runnable and gives `doctor` a meaningful exit status)
missing_required=0
for t in "${REQUIRED[@]}"; do is_missing "$t" && missing_required=1; done

((missing_required)) && exit 1
((project_rc)) && exit 1

# audit_rc: 0 clean, 2 not installed yet, 3 active PATH shadow. A fresh
# clone with no forge on PATH (2) is not a doctor failure -- it maps to the
# same clean exit as 0; only an active shadow (3) is a real problem worth
# surfacing here.
case "$audit_rc" in
  0 | 2) exit 0 ;;
  *) exit "$audit_rc" ;;
esac
