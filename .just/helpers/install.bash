#!/usr/bin/env bash
# install.bash -- put a usable forge on PATH, and make it identifiable.
#
#   install.bash release   cargo install -> ~/.cargo/bin/forge
#   install.bash debug     copy target/debug/forge -> ~/.cargo/bin/forge-debug
#
# THE FIXED PATH IS DELIBERATE. CARGO_HOME, CARGO_INSTALL_ROOT and cargo's
# own install.root config are all ignored: both binaries always land in
# $HOME/.cargo/bin, which is the single path install-audit.bash checks for
# shadows. One canonical location, one thing to audit.
#
# VERSION STAMPING. crates/forge_main/build.rs reads APP_VERSION and falls
# back to "0.1.0-dev". Without it both binaries report the same string and
# `forge --version` cannot tell a three-week-old release build from a debug
# build made a minute ago -- which also made install-audit's version column
# useless. We stamp git describe + profile.
#
# CODESIGNING. macOS only, and load-bearing rather than cosmetic: arboard
# (clipboard) and machineid-rs touch platform APIs that misbehave when a
# binary is copied after signing. Every rebuild invalidates the signature of
# the source file, so the copy is re-signed each time.
#
# Pure GNU Bash 5.3+.

# shellcheck source=tools.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/tools.bash"

set -uo pipefail

cd -- "$JUST_REPO_DIR" || exit 1

readonly BIN_DIR="$HOME/.cargo/bin"
readonly MAIN_CRATE=forge_main

tools_need cargo protoc || exit 1

# git describe when there is a tag, else <branch>-<short sha>, plus -dirty.
app_version() {
  local v
  v=$(git describe --tags --always --dirty 2> /dev/null) || v=''
  [[ -n $v ]] || v="$(fact_branch)-$(git rev-parse --short HEAD 2> /dev/null || printf unknown)"
  printf '%s' "$v"
}

codesign_if_macos() {
  local path=$1
  [[ $(uname -s) == Darwin ]] || return 0
  codesign --force --sign - "$path" || just_die "codesign failed for $path"
}

install_release() {
  local version
  version=$(app_version)
  printf 'building %s release, APP_VERSION=%s\n' "$PKGNAME" "$version"

  APP_VERSION="$version" cargo install --path "crates/$MAIN_CRATE" --force --root "$HOME/.cargo" ||
    just_die 'cargo install failed'

  local bin_path="$BIN_DIR/$PKGNAME"
  codesign_if_macos "$bin_path"
  printf '\n%s\n' "$("$bin_path" --version)"
  printf 'installed %s\n' "$bin_path"
}

install_debug() {
  local version
  version=$(app_version)
  printf 'building %s debug, APP_VERSION=%s-debug\n' "$PKGNAME" "$version"

  APP_VERSION="$version-debug" cargo build -p "$MAIN_CRATE" || just_die 'cargo build failed'

  mkdir -p -- "$BIN_DIR" || exit 1
  local src="target/debug/$PKGNAME"
  local dst="$BIN_DIR/$PKGNAME-debug"
  [[ -x $src ]] || just_die "missing $src after build"

  # A distinct FILENAME, not a distinct directory: forge-debug can never
  # shadow or be shadowed by the canonical forge, whatever PATH does.
  cp -f -- "$src" "$dst" || exit 1
  codesign_if_macos "$dst"
  printf '\n%s\n' "$("$dst" --version)"
  printf 'installed %s (unstripped -- lldb has symbols)\n' "$dst"
}

case "${1:?release or debug}" in
  release) install_release ;;
  debug) install_debug ;;
  *)
    printf 'usage: install.bash {release|debug}\n' >&2
    exit 2
    ;;
esac
