#!/usr/bin/env bash
# tools.bash -- the ONE tool catalogue for the Justfile system.
#
# Sourced by doctor.bash (reporting) and executed by recipes (gating):
#
#   tools.bash need <tool>...   exit 1 with install hints if any are absent
#   tools.bash have <tool>      exit 0/1, silent
#   tools.bash hint <tool>      print the install command
#
# WHY THIS FILE EXISTS
# Recipes used to inline `if command -v X; then …; else printf 'X not
# installed' >&2; fi`, nineteen times. That construct EXITS 0. `just verify`
# and `just ci` therefore reported success on a machine with no shellcheck,
# no cargo-insta and no clippy extras -- gates that had linted and tested
# nothing. `need` replaces all nineteen: absent tool -> non-zero, with the
# exact command that fixes it.
#
# It also merges the two catalogues that used to drift: doctor.bash owned
# tiers and hints, scripts/ai-tools.bash owned its own list of the same
# tools and doctor punted to it (`see: ./scripts/ai-tools.bash doctor`).
# One list now, consumed by both.
#
# Pure GNU Bash 5.3+.

# shellcheck source=lib.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

# --- tiers ---
# REQUIRED     a blocking gate cannot run without it
# RECOMMENDED  a non-blocking gate or the TUI degrades without it
# OPTIONAL     nice to have; nothing in verify/ci touches it
#
# protoc is REQUIRED and was missing from every tier until 2026-08-08:
# crates/forge_repo/build.rs calls tonic_prost_build::compile_protos, and
# prost-build >= 0.11 stopped vendoring protoc. Without it the workspace
# does not build at all -- CI installs it explicitly at six workflow sites.
#
# pnpm, not npm: operator toolchain rule. `just eval` runs the TypeScript
# benchmark suite and there is no npm anywhere in this system.
TOOLS_REQUIRED=(bash just cargo rustc clippy rustfmt protoc git rg fd jq)
TOOLS_RECOMMENDED=(cargo-insta cargo-nextest shellcheck gum fzf bat pnpm rumdl typos zsh trash)
TOOLS_OPTIONAL=(figlet fish cargo-deny cargo-llvm-cov cargo-audit cargo-outdated
  cargo-watch cargo-machete cargo-bloat cargo-msrv betterhook diesel
  cross tokei ast-grep gitnexus codegraph grepai)

# package name when it differs from the command name
declare -A TOOLS_PKG=(
  [rg]=ripgrep
  [typos]=typos-cli
  [diesel]=diesel_cli
  ['ast-grep']=ast-grep
)

declare -A TOOLS_SRC=(
  [bash]=brew [just]=mise [git]=brew [rg]=brew [fd]=brew [jq]=brew
  [protoc]=brew [gum]=brew [fzf]=brew [bat]=brew [figlet]=brew
  [shellcheck]=mise ['ast-grep']=brew [tokei]=brew [pnpm]=corepack
  [zsh]=system [fish]=brew [trash]=brew
  [cargo]=rustup [rustc]=rustup [clippy]=rustup [rustfmt]=rustup
  ['cargo-insta']=mise ['cargo-nextest']=cargo ['cargo-deny']=cargo
  ['cargo-llvm-cov']=cargo ['cargo-audit']=cargo ['cargo-outdated']=cargo
  ['cargo-watch']=cargo ['cargo-machete']=cargo ['cargo-bloat']=cargo
  ['cargo-msrv']=cargo [betterhook]=cargo [cross]=cargo [diesel]=cargo
  [rumdl]=cargo [typos]=cargo
  [gitnexus]=other [codegraph]=other [grepai]=other
)

declare -A TOOLS_WHY=(
  [bash]='helper runtime (GNU >= 5.3, not macOS /bin/bash 3.2)'
  [just]='the task runner'
  [cargo]='build & test (Cargo workspace)'
  [rustc]='Rust compiler'
  [clippy]='lint gate (-D warnings)'
  [rustfmt]='format gate -- NIGHTLY, .rustfmt.toml uses unstable features'
  [protoc]='hard build dep: forge_repo/build.rs compiles proto/forge.proto'
  [git]='version control'
  [rg]='search (never grep)'
  [fd]='file finder (never find)'
  [jq]='just --dump JSON parsing (menu, doctor, docs)'
  ['cargo-insta']='snapshot tests -- just test; plain cargo test is NOT equivalent'
  ['cargo-nextest']='process-per-test runner that insta drives (insta.yaml)'
  [shellcheck]='blocking shell gate over .just/helpers + cli'
  [gum]='TUI: splash panels + menu parameter forms'
  [fzf]='TUI: menu list engine'
  [bat]='syntax-highlighted recipe previews'
  [pnpm]='TypeScript eval suite -- just eval (never npm)'
  [rumdl]='markdown lint -- just rumdl'
  [typos]='spelling lint -- just typos'
  [zsh]='parse-checks the 15 .zsh files baked into the binary -- just test-shell'
  [fish]='parse-checks the embedded fish plugin -- just test-shell'
  [trash]='deletions go to macOS Trash, never rm -rf -- just clean-*'
  [figlet]='banner art on the splash'
  ['cargo-deny']='license + advisory audit -- just deny'
  ['cargo-llvm-cov']='coverage -- just coverage (CI runs this)'
  ['cargo-audit']='security advisories -- just audit'
  ['cargo-outdated']='outdated deps -- just outdated'
  ['cargo-watch']='live rebuild loop -- just watch'
  ['cargo-machete']='unused deps -- just machete'
  ['cargo-bloat']='binary size -- just bloat'
  ['cargo-msrv']='verify the rust-version in Cargo.toml is real -- just msrv'
  [betterhook]='git hooks manager -- just hooks'
  [diesel]='schema authoring only; the binary self-migrates (embedded)'
  [cross]='cross-compilation -- just cross <target>'
  [tokei]='LOC stats -- just loc'
  ['ast-grep']='structural search/lint; sgconfig.yml + rules/ already exist'
  [gitnexus]='code graph -- blast radius before an edit'
  [codegraph]='code graph -- expand known symbol names into source'
  [grepai]='semantic search -- find by meaning, indexes shell + md too'
)

# clippy ships as `cargo-clippy`; there is no `clippy` on PATH.
declare -A TOOLS_PROBE=(
  [clippy]=cargo-clippy
)

# Is the tool usable for the job we need it for?
#
# rustfmt is special: fmt/fmt-check and both betterhook lanes invoke it as
# `rustup run nightly rustfmt`, because .rustfmt.toml sets unstable options
# that stable rustfmt silently mis-evaluates. A stable-only rustfmt on PATH
# is NOT enough, so probe the nightly toolchain directly.
tool_present() {
  case "$1" in
    rustfmt) rustup run nightly rustfmt --version > /dev/null 2>&1 ;;
    *) has "${TOOLS_PROBE[$1]:-$1}" ;;
  esac
}

tool_missing() { ! tool_present "$1"; }

tool_hint() {
  local t="$1" src="${TOOLS_SRC[$1]:-brew}" pkg="${TOOLS_PKG[$1]:-$1}"
  if [[ $t == rustfmt ]]; then
    printf 'rustup toolchain install nightly && rustup component add rustfmt --toolchain nightly'
    return
  fi
  case "$src" in
    rustup) printf 'rustup component add %s' "$t" ;;
    cargo) printf 'cargo install %s' "$pkg" ;;
    mise) printf 'mise install   # %s is pinned in mise.toml' "$t" ;;
    corepack) printf 'corepack enable pnpm' ;;
    system) printf '%s ships with macOS -- if it is missing, PATH is broken' "$t" ;;
    other) printf 'not managed here -- install %s yourself, then re-run' "$t" ;;
    *) printf 'brew install %s' "$pkg" ;;
  esac
}

tool_tier() {
  local t="$1" x
  for x in "${TOOLS_REQUIRED[@]}"; do [[ $x == "$t" ]] && {
    printf 'REQUIRED'
    return
  }; done
  for x in "${TOOLS_RECOMMENDED[@]}"; do [[ $x == "$t" ]] && {
    printf 'RECOMMENDED'
    return
  }; done
  for x in "${TOOLS_OPTIONAL[@]}"; do [[ $x == "$t" ]] && {
    printf 'OPTIONAL'
    return
  }; done
  printf 'UNLISTED'
}

# Gate a recipe on its tools. Prints every missing one with its fix, then
# exits 1 -- never 0. This is the whole point of the file.
tools_need() {
  local t missing=()
  for t in "$@"; do
    tool_present "$t" || missing+=("$t")
  done
  ((${#missing[@]} == 0)) && return 0

  printf '%s%s%s\n' "${C_RED:-}" "cannot run: missing $(
    ((${#missing[@]} == 1)) && printf 'tool' || printf 'tools'
  )" "${C_RESET:-}" >&2
  for t in "${missing[@]}"; do
    printf '  %-16s %s\n' "$t" "${TOOLS_WHY[$t]:-}" >&2
    printf '  %-16s install: %s\n' '' "$(tool_hint "$t")" >&2
  done
  printf '\n  see everything at once:  just doctor\n' >&2
  return 1
}

# --- CLI (only when executed, not when sourced) ---
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  set -uo pipefail
  case "${1:-}" in
    need)
      shift
      tools_need "$@"
      ;;
    have)
      tool_present "${2:?tool name required}"
      ;;
    hint)
      tool_hint "${2:?tool name required}"
      printf '\n'
      ;;
    tier)
      tool_tier "${2:?tool name required}"
      printf '\n'
      ;;
    *)
      printf 'usage: tools.bash {need <tool>... | have <tool> | hint <tool> | tier <tool>}\n' >&2
      exit 2
      ;;
  esac
fi
