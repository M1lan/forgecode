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
# installed' >&2; fi`, nineteen times. That construct EXITS 0. The aggregate gates
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
TOOLS_RECOMMENDED=(cargo-insta cargo-nextest shellcheck gum fzf bat pnpm rumdl typos zsh trash gitleaks)
TOOLS_OPTIONAL=(figlet fish cargo-deny cargo-llvm-cov cargo-audit cargo-outdated
  cargo-watch cargo-machete cargo-bloat cargo-msrv betterhook diesel
  cross tokei ast-grep gitnexus codegraph grepai)

# package name when it differs from the command name
declare -A TOOLS_PKG=(
  [rg]=ripgrep
  [typos]=typos-cli
  [diesel]=diesel_cli
  [betterhook]=betterhook-cli
  ['ast-grep']=ast-grep
)

declare -A TOOLS_SRC=(
  [bash]=brew [just]=mise [git]=brew [rg]=brew [fd]=brew [jq]=brew
  [protoc]=brew [gum]=brew [fzf]=brew [bat]=brew [figlet]=brew
  [shellcheck]=mise ['ast-grep']=brew [tokei]=brew [pnpm]=corepack
  [zsh]=system [fish]=brew [trash]=brew [gitleaks]=brew
  [cargo]=rustup [rustc]=rustup [clippy]=rustup [rustfmt]=rustup
  ['cargo-insta']=mise ['cargo-nextest']=cargo ['cargo-deny']=cargo
  ['cargo-llvm-cov']=cargo ['cargo-audit']=cargo ['cargo-outdated']=cargo
  ['cargo-watch']=cargo ['cargo-machete']=cargo ['cargo-bloat']=cargo
  ['cargo-msrv']=cargo [betterhook]=cargo [cross]=cargo [diesel]=cargo
  [rumdl]=cargo [typos]=cargo
  [gitnexus]=other [codegraph]=other [grepai]=other
)

# Gentoo package atoms for tools that Homebrew would provide on macOS. Used
# only when the host is Linux with portage; anything not listed falls back to
# `mise use -g`, which is cross-platform and already manages this repo's pins.
declare -A TOOLS_GENTOO=(
  [bash]=app-shells/bash [git]=dev-vcs/git [rg]=sys-apps/ripgrep [fd]=sys-apps/fd
  [jq]=app-misc/jq [protoc]=dev-libs/protobuf [gum]=app-misc/gum [fzf]=app-shells/fzf
  [bat]=sys-apps/bat [figlet]=app-misc/figlet [shellcheck]=dev-util/shellcheck
  [tokei]=dev-util/tokei [fish]=app-shells/fish [zsh]=app-shells/zsh
  ['cargo-nextest']=dev-util/cargo-nextest
)

# host_os: "macos" | "gentoo" | "linux". Cached after the first call.
host_os() {
  if [[ -z ${_HOST_OS:-} ]]; then
    case "$(uname -s)" in
      Darwin) _HOST_OS=macos ;;
      Linux) if command -v emerge > /dev/null 2>&1; then _HOST_OS=gentoo; else _HOST_OS=linux; fi ;;
      *) _HOST_OS=linux ;;
    esac
  fi
  printf '%s' "$_HOST_OS"
}

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
  [gitleaks]='secret scan -- betterhook pre-commit lane (builtin = gitleaks needs the binary)'
  [trash]='deletions go to the Trash (macOS trash, Linux trash-put or gio), never rm -rf -- just clean-*'
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
# Sidecar rustup: on hosts whose primary Rust is the distro toolchain (Gentoo's
# dev-lang/rust-bin on torque), a rustup on PATH would shadow /usr/bin/cargo.
# `just` therefore accepts a rustup installed with its own homes, off PATH,
# used only for the nightly rustfmt. Install:
#   RUSTUP_HOME=~/.local/opt/rustup/rustup CARGO_HOME=~/.local/opt/rustup/cargo \
#   sh <(curl -sSf https://sh.rustup.rs) -y --no-modify-path \
#     --default-toolchain nightly --profile minimal --component rustfmt
SIDECAR_RUSTUP=${SIDECAR_RUSTUP:-$HOME/.local/opt/rustup}

# Print the absolute path of a NIGHTLY rustfmt binary, or fail. Order: rustup
# on PATH (macOS, rustup-managed Linux), then the sidecar rustup, then a
# `rustfmt-nightly` on PATH. `cargo fmt` honours $RUSTFMT, so callers run
#   RUSTFMT="$(nightly_rustfmt_bin)" cargo fmt --all
nightly_rustfmt_bin() {
  local sysroot
  if has rustup && sysroot=$(rustup run nightly rustc --print sysroot 2> /dev/null) && [[ -x $sysroot/bin/rustfmt ]]; then
    printf '%s\n' "$sysroot/bin/rustfmt"
    return 0
  fi
  if [[ -x $SIDECAR_RUSTUP/cargo/bin/rustup ]] &&
    sysroot=$(RUSTUP_HOME=$SIDECAR_RUSTUP/rustup CARGO_HOME=$SIDECAR_RUSTUP/cargo "$SIDECAR_RUSTUP/cargo/bin/rustup" run nightly rustc --print sysroot 2> /dev/null) &&
    [[ -x $sysroot/bin/rustfmt ]]; then
    printf '%s\n' "$sysroot/bin/rustfmt"
    return 0
  fi
  if has rustfmt-nightly; then
    command -v rustfmt-nightly
    return 0
  fi
  return 1
}

# trash on macOS; on Linux either trash-cli's trash-put or GLib's gio trash.
# Prints the command words, or fails.
trash_cmd() {
  if has trash; then printf 'trash\n'
  elif has trash-put; then printf 'trash-put\n'
  elif has gio; then printf 'gio trash\n'
  else return 1; fi
}

tool_present() {
  case "$1" in
    rustfmt) nightly_rustfmt_bin > /dev/null 2>&1 ;;
    trash) trash_cmd > /dev/null 2>&1 ;;
    *) has "${TOOLS_PROBE[$1]:-$1}" ;;
  esac
}

tool_missing() { ! tool_present "$1"; }

tool_hint() {
  local t="$1" src="${TOOLS_SRC[$1]:-brew}" pkg="${TOOLS_PKG[$1]:-$1}"
  if [[ $t == rustfmt ]]; then
    if has rustup; then
      printf 'rustup toolchain install nightly && rustup component add rustfmt --toolchain nightly'
    else
      printf 'RUSTUP_HOME=%s/rustup CARGO_HOME=%s/cargo sh <(curl -sSf https://sh.rustup.rs) -y --no-modify-path --default-toolchain nightly --profile minimal --component rustfmt   # sidecar rustup, off PATH' "$SIDECAR_RUSTUP" "$SIDECAR_RUSTUP"
    fi
    return
  fi
  if [[ $t == trash && $(host_os) != macos ]]; then
    printf 'emerge -av app-misc/trash-cli   # or GLib gio (usually present)'
    return
  fi
  case "$src" in
    rustup) printf 'rustup component add %s' "$t" ;;
    cargo)
      if [[ $(host_os) == gentoo && -n ${TOOLS_GENTOO[$t]:-} ]]; then printf 'emerge -av %s   # binhost first; or cargo install %s' "${TOOLS_GENTOO[$t]}" "$pkg"
      else printf 'cargo install %s' "$pkg"; fi ;;
    mise) printf 'mise install   # %s is pinned in mise.toml' "$t" ;;
    corepack) printf 'corepack enable pnpm' ;;
    system)
      case "$(host_os)" in
        macos) printf '%s ships with macOS -- if it is missing, PATH is broken' "$t" ;;
        gentoo) printf 'emerge -av %s' "${TOOLS_GENTOO[$t]:-$t}" ;;
        *) printf 'install %s with the system package manager' "$t" ;;
      esac ;;
    other) printf 'not managed here -- install %s yourself, then re-run' "$t" ;;
    *)
      # "brew" tier: Homebrew on macOS, portage on Gentoo (binhost first, per
      # the operator's package ranking), mise everywhere else.
      case "$(host_os)" in
        macos) printf 'brew install %s' "$pkg" ;;
        gentoo)
          if [[ -n ${TOOLS_GENTOO[$t]:-} ]]; then printf 'emerge -av %s   # gbin %s checks the binhost first' "${TOOLS_GENTOO[$t]}" "$t"
          else printf 'mise use -g %s' "$pkg"; fi ;;
        *) printf 'mise use -g %s' "$pkg" ;;
      esac ;;
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
    rustfmt-bin)
      nightly_rustfmt_bin || { printf 'tools.bash: no nightly rustfmt -- %s\n' "$(tool_hint rustfmt)" >&2; exit 1; }
      ;;
    trash-cmd)
      trash_cmd || { printf 'tools.bash: no trash command -- %s\n' "$(tool_hint trash)" >&2; exit 1; }
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
      printf 'usage: tools.bash {need <tool>... | have <tool> | hint <tool> | tier <tool> | rustfmt-bin | trash-cmd}\n' >&2
      exit 2
      ;;
  esac
fi
