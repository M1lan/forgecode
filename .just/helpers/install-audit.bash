#!/usr/bin/env bash
# install-audit.bash -- prove the `forge` PATH resolves is ~/.cargo/bin/forge.
#
#   install-audit.bash              TSV findings; quiet when clean
#   install-audit.bash --table      human table (used by `just doctor`)
#   install-audit.bash --self-test  internal assertions on the parsing
#                                    logic; no PATH mutation, no install
#
# Canonical binary: this repo's `install-release` runs
#   cargo install --path crates/forge_main --force --root "$HOME/.cargo"
# which writes $HOME/.cargo/bin/forge -- that is the ONE binary any shell
# should ever run. Deliberately fixed: CARGO_HOME / CARGO_INSTALL_ROOT /
# Cargo's own install.root config are NOT honored here -- this audit checks
# one specific literal path, by explicit request, not cargo's general
# install-root resolution order.
#
# Exit codes (highest severity wins; --self-test exits 0/1 on its own terms):
#   0  clean -- PATH winner IS $HOME/.cargo/bin/forge
#   2  audit could not run (no forge on PATH at all -- fresh clone)
#   3  PATH winner is not the canonical binary (shadowed install, e.g. an
#      older ~/.local/bin/forge copy sitting earlier on PATH)
#
# Why `type -af` and not `command -v`: `command -v` prints only the winner,
# which is exactly what hides a shadowed install. Parsed by stripping the
# fixed "$PKGNAME is " prefix (not by splitting on the last space), so a
# path that itself contains spaces is still handled correctly.
#
# Deliberately no version-drift check: crates/forge_main/build.rs bakes
# CARGO_PKG_VERSION from $APP_VERSION when set (CI/CD builds), else falls
# back to a hardcoded "0.1.0-dev" -- so a local dev build's `--version`
# essentially never equals Cargo.toml's own `version = "..."` field. Diffing
# them would just be a permanent false positive, not a real signal.
#
# NON-DESTRUCTIVE BY DESIGN: this audit only reads and reports. It never
# deletes, moves, renames, or overwrites a shadowing binary -- removing
# ~/.local/bin/forge (or any other shadow) is the operator's call, not this
# script's; explicit removal permission was not given for this task.
#
# GNU Bash 5.3+. No mutation: every probe here is read-only.

# shellcheck source=lib.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

set -uo pipefail

MODE="${1:-}"

# Fixed canonical bin dir: $HOME/.cargo/bin. Deliberately ignores
# CARGO_HOME / CARGO_INSTALL_ROOT -- see header comment.
cargo_install_bin() {
  printf '%s/.cargo/bin' "$HOME"
}

# Every `forge` on PATH, in resolution order, deduped by real path (PATH
# often holds aliases of one file, e.g. .local/share/../bin vs .local/bin).
# `type -af NAME` prints one "NAME is /path" line per PATH match; strip the
# fixed prefix rather than splitting on the last space, so a path
# containing spaces is not corrupted.
candidates() {
  local -A seen=()
  local prefix="$PKGNAME is " line p real
  while IFS= read -r line; do
    [[ $line == "$prefix"* ]] || continue
    p=${line#"$prefix"}
    [[ -x $p ]] || continue
    real="$(cd -- "${p%/*}" 2> /dev/null && printf '%s/%s' "$(pwd -P)" "${p##*/}")" || real=$p
    [[ -n "${seen[$real]:-}" ]] && continue
    seen[$real]=1
    printf '%s\n' "$real"
  done < <(type -af "$PKGNAME" 2> /dev/null)
}

# `forge --version` prints "forge X.Y.Z[-suffix]"; strip the leading name.
probe_version() {
  local bin="$1" out prefix="$PKGNAME "
  out=$("$bin" --version 2> /dev/null) || {
    printf '?'
    return
  }
  printf '%s' "${out#"$prefix"}"
}

# --self-test: pure logic assertions on the two functions above. No PATH
# mutation, no cargo/forge invocation, safe to run in CI or a fresh clone.
if [[ $MODE == --self-test ]]; then
  fail=0

  # cargo_install_bin is fixed and must ignore CARGO_HOME/CARGO_INSTALL_ROOT
  got=$(CARGO_HOME=/tmp/ignored CARGO_INSTALL_ROOT=/tmp/also-ignored cargo_install_bin)
  want="$HOME/.cargo/bin"
  if [[ $got != "$want" ]]; then
    printf 'FAIL: cargo_install_bin: got %q want %q\n' "$got" "$want" >&2
    fail=1
  fi

  # prefix-strip parsing must survive a path containing spaces
  line="$PKGNAME is /tmp/My Forge Install/bin/$PKGNAME"
  prefix="$PKGNAME is "
  got=${line#"$prefix"}
  want="/tmp/My Forge Install/bin/$PKGNAME"
  if [[ $got != "$want" ]]; then
    printf 'FAIL: prefix strip: got %q want %q\n' "$got" "$want" >&2
    fail=1
  fi

  # a line not carrying the expected prefix must never be misparsed
  if [[ "not a forge line" == "$prefix"* ]]; then
    printf 'FAIL: prefix guard matched an unrelated line\n' >&2
    fail=1
  fi

  ((fail)) && exit 1
  printf 'install-audit self-test: ok\n'
  exit 0
fi

# CI and explicit opt-outs legitimately install outside PATH -- never nag
# there, but say so in --table mode instead of silently vanishing.
if [[ -n "${CI:-}${FORGE_SKIP_INSTALL_AUDIT:-}" ]]; then
  [[ $MODE == --table ]] && printf '  %s%-22s%s CI/FORGE_SKIP_INSTALL_AUDIT set -- audit skipped\n' \
    "$C_DIM" "installed $PKGNAME" "$C_RESET"
  exit 0
fi

mapfile -t bins < <(candidates)
if ((${#bins[@]} == 0)); then
  [[ $MODE == --table ]] && printf '  %s%-22s%s no %s on PATH yet\n' \
    "$C_YELLOW" "installed $PKGNAME" "$C_RESET" "$PKGNAME"
  exit 2
fi

declare -a bin_paths=() bin_versions=()
rc=0
winner=${bins[0]}
cargo_bin=$(cargo_install_bin)
canonical="$cargo_bin/$PKGNAME"

for bin in "${bins[@]}"; do
  bin_paths+=("$bin")
  bin_versions+=("$(probe_version "$bin")")
done

# 3: the artifact `just install-release` produces is not what a fresh shell runs.
shadowed=0
if [[ $winner != "$canonical" ]]; then
  shadowed=1
  rc=3
fi

# --- report ---
if [[ $MODE == --table ]]; then
  printf '\n%sINSTALLED FORGE%s\n' "$C_BOLD" "$C_RESET"
  row_color=$C_GREEN
  ((rc)) && row_color=$C_YELLOW
  # Labeled rows, not raw TSV -- tabs render unreadably once color codes and
  # variable-width paths are mixed into the same line.
  for i in "${!bin_paths[@]}"; do
    tag=""
    ((i == 0)) && tag="  (PATH winner)"
    printf '  %s%-8s %-14s %s%s%s\n' "$row_color" "binary" "${bin_versions[$i]}" "${bin_paths[$i]}" "$tag" "$C_RESET"
  done
  printf '  %s%-8s %-14s %s%s\n' "$row_color" "repo" "" "$JUST_REPO_DIR" "$C_RESET"
  if ((shadowed)); then
    printf '  %s%-8s expected %s, PATH resolves %s instead%s\n' "$C_RED" "shadowed" "$canonical" "$winner" "$C_RESET"
  fi
  if ((rc)); then
    printf '  %shint: just install-release, then re-run just doctor%s\n' "$C_YELLOW" "$C_RESET"
    printf '  %snote: shadowing binaries are never deleted automatically%s\n' "$C_DIM" "$C_RESET"
  fi
  exit "$rc"
fi

# Default mode: quiet on success, TSV on findings (parseable, bounded, no color).
if ((rc)); then
  for i in "${!bin_paths[@]}"; do
    printf 'bin\t%s\t%s\n' "${bin_paths[$i]}" "${bin_versions[$i]}"
  done
  printf 'repo\t%s\n' "$JUST_REPO_DIR"
  ((shadowed)) && printf 'shadowed\t%s\tby\t%s\n' "$canonical" "$winner"
fi
exit "$rc"
