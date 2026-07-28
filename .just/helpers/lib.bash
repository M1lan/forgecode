#!/usr/bin/env bash

[[ ${BASH_VERSINFO[0]:-0} -gt 5 || ${BASH_VERSINFO[0]:-0} -eq 5 && ${BASH_VERSINFO[1]:-0} -ge 3 ]] || {
  printf 'Bash >= 5.3 required; got %s\n' "$BASH_VERSION" >&2
  exit 1
}

JUST_HELPERS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly JUST_HELPERS_DIR
JUST_REPO_DIR=$(cd -- "$JUST_HELPERS_DIR/../.." && pwd -P) || exit 1
readonly JUST_REPO_DIR
readonly JUST_BIN=${JUST_BIN:-just}

just_die() {
  printf '%s\n' "$*" >&2
  exit 1
}

just_require() {
  command -v "$1" >/dev/null 2>&1 || just_die "missing required command: $1"
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
        cargo metadata --no-deps --format-version 1 \
          | jq -r '.packages[].name' \
          | sort -u
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
    test|test-crate|test-nextest)
      printf '%s\n' '--all-features'
      ;;
  esac
}

preview_recipe() {
  local recipe=$1
  local source

  source=$(cd -- "$JUST_REPO_DIR" && "$JUST_BIN" --show "$recipe") || return
  if command -v bat >/dev/null 2>&1; then
    printf '%s\n' "$source" | bat --language=make --color=always --paging=never --style=numbers
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
