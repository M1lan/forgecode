#!/usr/bin/env bash
# lib.bash -- shared library for .just/helpers/*.bash. Sourced, never executed.
# shellcheck disable=SC2034  # C_*/G_ACCENT are consumed by sourcing scripts

[[ ${BASH_VERSINFO[0]:-0} -gt 5 || ${BASH_VERSINFO[0]:-0} -eq 5 && ${BASH_VERSINFO[1]:-0} -ge 3 ]] || {
  printf 'Bash >= 5.3 required; got %s\n' "$BASH_VERSION" >&2
  exit 1
}

JUST_HELPERS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly JUST_HELPERS_DIR
JUST_REPO_DIR=$(cd -- "$JUST_HELPERS_DIR/../.." && pwd -P) || exit 1
readonly JUST_REPO_DIR
readonly JUST_BIN=${JUST_BIN:-just}
readonly PKGNAME="forge"

has() { command -v -- "$1" > /dev/null 2>&1; }
is_tty() { [[ -t 1 ]]; }

just_die() {
  printf '%s\n' "$*" >&2
  exit 1
}

just_require() {
  command -v "$1" > /dev/null 2>&1 || just_die "missing required command: $1"
}

just_json() {
  (
    cd -- "$JUST_REPO_DIR" || exit 1
    "$JUST_BIN" --dump --dump-format json
  )
}

recipe_rows() {
  just_json | jq -r '
    .recipes
    | to_entries[]
    | select(.value.private | not)
    | [
        .key,
        (([.value.attributes[]? | select(type == "object" and has("group")) | .group] | first) // "other"),
        (.value.doc // "No description"),
        ([.value.parameters[]?.name] | join(", "))
      ]
    | @tsv
  '
}

strict_candidates() {
  local query=${1,,}
  local name group doc params haystack term
  local -a terms

  [[ $query =~ ^[[:alnum:][:space:]_-]*$ ]] || return 0
  read -r -a terms <<< "$query"

  while IFS=$'\t' read -r name group doc params; do
    haystack=${name,,}
    haystack+=" ${group,,} ${doc,,} ${params,,}"

    for term in "${terms[@]}"; do
      if ((${#term} == 1)); then
        [[ $haystack =~ (^|[^[:alnum:]])${term}([^[:alnum:]]|$) ]] || continue 2
      else
        [[ $haystack =~ (^|[^[:alnum:]])${term} ]] || continue 2
      fi
    done

    printf '%s\t%s\t%s\t%s\n' "$name" "$group" "$doc" "$params"
  done < <(recipe_rows)
}

recipe_params() {
  local recipe=$1
  just_json | jq -r --arg recipe "$recipe" '
    .recipes[$recipe].parameters[]?
    | [.name, .kind, (.default // "")]
    | @tsv
  '
}

suggest_values() {
  local name=$1

  case $name in
    crate)
      (
        cd -- "$JUST_REPO_DIR" || exit 1
        cargo metadata --no-deps --format-version 1 |
          jq -r '.packages[].name' |
          sort -u
      )
      ;;
    target)
      printf '%s\n' \
        aarch64-apple-darwin \
        aarch64-unknown-linux-gnu \
        aarch64-unknown-linux-musl \
        aarch64-pc-windows-msvc \
        aarch64-linux-android \
        x86_64-apple-darwin \
        x86_64-unknown-linux-gnu \
        x86_64-unknown-linux-musl \
        x86_64-pc-windows-msvc
      ;;
    depth)
      printf '%s\n' 1 2 3 4
      ;;
  esac
}

recommended_args() {
  local recipe=$1

  case $recipe in
    test | test-crate | test-nextest)
      printf '%s\n' '--all-features'
      ;;
  esac
}

preview_recipe() {
  local recipe=$1
  local source

  source=$(cd -- "$JUST_REPO_DIR" && "$JUST_BIN" --show "$recipe") || return
  if command -v bat > /dev/null 2>&1; then
    # `just` syntax highlighting when bat ships it; older bat builds lack the
    # "Just" sublime-syntax, so fall back to `make` (closest approximation)
    # and finally to plain text -- never let a missing syntax break preview.
    printf '%s\n' "$source" | bat --language=just --color=always --paging=never --style=numbers 2> /dev/null ||
      printf '%s\n' "$source" | bat --language=make --color=always --paging=never --style=numbers 2> /dev/null ||
      printf '%s\n' "$source"
  else
    printf '%s\n' "$source"
  fi
}

print_command() {
  local part
  printf 'just'
  for part in "$@"; do
    printf ' %q' "$part"
  done
  printf '\n'
}

# --- colors: terminal DEFAULT colors via tput only (no themes, no raw ANSI) ---
_ncolors=0
if is_tty && [[ -z "${NO_COLOR:-}" ]]; then
  _ncolors=$(tput colors 2> /dev/null || printf 0)
fi

if ((_ncolors >= 8)); then
  C_RESET=$(tput sgr0) C_BOLD=$(tput bold) C_DIM=$(tput dim)
  C_RED=$(tput setaf 1) C_GREEN=$(tput setaf 2) C_YELLOW=$(tput setaf 3)
  C_BLUE=$(tput setaf 4) C_MAGENTA=$(tput setaf 5) C_CYAN=$(tput setaf 6)
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
  C_BLUE='' C_MAGENTA='' C_CYAN=''
fi
G_ACCENT="6"

# --- terminal size ---
# `tput cols` inside $() sees a pipe (not the tty) and silently reports 80 --
# ask the controlling tty via stty instead. Precedence: COLUMNS/LINES env
# (test override) > stty on /dev/tty > tput > 80x24.
_term_size() {
  local sz=''
  if [[ -z "${COLUMNS:-}" || -z "${LINES:-}" ]] && [[ -r /dev/tty ]]; then
    sz=$(stty size 2> /dev/null < /dev/tty) || sz=''
  fi
  if [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]] && ((BASH_REMATCH[1] > 0 && BASH_REMATCH[2] > 0)); then
    _TERM_LINES=${LINES:-${BASH_REMATCH[1]}}
    _TERM_COLS=${COLUMNS:-${BASH_REMATCH[2]}}
  else
    _TERM_COLS=${COLUMNS:-$(tput cols 2> /dev/null || printf 80)}
    _TERM_LINES=${LINES:-$(tput lines 2> /dev/null || printf 24)}
  fi
  ((_TERM_COLS > 0)) || _TERM_COLS=80
  ((_TERM_LINES > 0)) || _TERM_LINES=24
}
term_cols() {
  _term_size
  printf '%s' "$_TERM_COLS"
}
term_lines() {
  _term_size
  printf '%s' "$_TERM_LINES"
}

fmt_tenths() { printf '%d.%d' "$(($1 / 10))" "$(($1 % 10))"; }

# Swallow pending stdin bytes before a hotkey read loop. gum/lipgloss can
# query the terminal (DSR, OSC) and the reply would otherwise be read as
# the first hotkey.
drain_tty_input() {
  local _junk
  while read -rsn1 -t 0.1 _junk; do
    while read -rsn1 -t 0.02 _junk; do :; done
  done
}

# --- fast project facts (file parsing + cheap git ops only -- never spawns
# cargo/rustc, never runs a LOC/tokei scan) ---
fact_crate_version() {
  local f="$JUST_REPO_DIR/Cargo.toml" v
  [[ -f $f ]] || {
    printf '?'
    return
  }
  v=$(rg -No '^version = "([^"]+)"' -r '$1' "$f" 2> /dev/null | head -1)
  printf '%s' "${v:-?}"
}

fact_rust_edition() {
  local f="$JUST_REPO_DIR/Cargo.toml" v
  [[ -f $f ]] || {
    printf '?'
    return
  }
  v=$(rg -No '^edition = "([^"]+)"' -r '$1' "$f" 2> /dev/null | head -1)
  printf '%s' "${v:-?}"
}

fact_msrv() {
  local f="$JUST_REPO_DIR/Cargo.toml" v
  [[ -f $f ]] || {
    printf 'unset'
    return
  }
  v=$(rg -No '^rust-version = "([^"]+)"' -r '$1' "$f" 2> /dev/null | head -1)
  printf '%s' "${v:-unset}"
}

fact_toolchain() {
  local f="$JUST_REPO_DIR/rust-toolchain.toml" v
  [[ -f $f ]] || {
    printf 'default'
    return
  }
  v=$(rg -No '^channel = "([^"]+)"' -r '$1' "$f" 2> /dev/null | head -1)
  printf '%s' "${v:-?}"
}

fact_workspace_crates() {
  local d="$JUST_REPO_DIR/crates" n
  [[ -d $d ]] || {
    printf '0'
    return
  }
  n=$(fd -t d --max-depth 1 . "$d" 2> /dev/null | wc -l | tr -d ' ')
  printf '%s' "${n:-?}"
}

fact_branch() {
  local b sha
  b=$(git -C "$JUST_REPO_DIR" symbolic-ref --quiet --short HEAD 2> /dev/null) && {
    printf '%s' "$b"
    return
  }
  sha=$(git -C "$JUST_REPO_DIR" rev-parse --short HEAD 2> /dev/null) && {
    printf 'detached@%s' "$sha"
    return
  }
  printf '(no git)'
}

fact_dirty() {
  git -C "$JUST_REPO_DIR" status --porcelain 2> /dev/null | wc -l | tr -d ' '
}

fact_last_commit() {
  git -C "$JUST_REPO_DIR" log -1 --format='%h %s' 2> /dev/null || printf '(none)'
}

fact_bin_kind() {
  [[ -x "$JUST_REPO_DIR/target/release/$PKGNAME" ]] && {
    printf 'release'
    return
  }
  [[ -x "$JUST_REPO_DIR/target/debug/$PKGNAME" ]] && printf 'debug'
}
