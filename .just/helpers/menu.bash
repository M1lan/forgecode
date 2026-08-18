#!/usr/bin/env bash
# menu.bash -- THE launcher. The single TUI surface for this Justfile.
#
# Flow, deliberately flat (no modes, no submenu):
#   1. fzf list: strict whole-word prefix search, live preview of the source.
#   2. Enter -> collect parameters, if the recipe has any:
#        singular params -> suggestion browser + gum input (pick_suggestion)
#        star/plus params -> ONE `extra arguments> ` gum input, empty = none
#   3. Recipe WITH params: print the command, preview it, `gum confirm`.
#      Recipe with NO params: run directly -- no confirm friction on the
#      common path.
#   4. `Return to menu?` loops back to the list.
#
# Cancelling any prompt (esc / ctrl-c) returns to the recipe list, never to
# a half-built command line.
#
# set-flag discipline: TUI helpers MUST NOT use `set -e` -- an fzf/gum rc
# under `-e` kills the script mid-prompt with no message. Every fzf/gum call
# captures its rc explicitly instead, and `|| true` is banned there because
# it swallows 130 and makes ctrl-c unkillable.
#
# NEVER clears the screen or the scrollback.

set -uo pipefail

# shellcheck source=lib.bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.bash"

trap 'exit 130' INT TERM HUP

just_require fzf
just_require jq
just_require gum

# Print the selected recipe name on stdout. rc 130 = user quit.
select_recipe() {
  local query='' selected rc shell_bin
  local -a lines=()
  shell_bin=$(command -v bash) || just_die 'bash not found'

  # fzf runs reload/preview snippets through $SHELL. Force bash and export
  # the helper functions + their env so the child resolves them directly,
  # with no fragile path embedding or nested quoting.
  export JUST_HELPERS_DIR JUST_REPO_DIR JUST_BIN
  export -f strict_candidates recipe_rows just_json preview_recipe

  while :; do
    rc=0
    selected=$(strict_candidates "$query" | SHELL="$shell_bin" fzf \
      --ansi \
      --delimiter=$'\t' \
      --with-nth=1,2,3,4 \
      --nth=1,2,3,4 \
      --no-sort \
      --disabled \
      --height=100% \
      --layout=reverse \
      --prompt='just> ' \
      --header='Whole-word prefixes only. Enter: fill in parameters and run.' \
      --bind='change:reload:strict_candidates {q}' \
      --preview='preview_recipe {1}' \
      --preview-window='right:60%:wrap' \
      --query="$query" \
      --print-query) || rc=$?

    # 130 = esc / ctrl-c -> leave. 1 = no match -> keep the query, retry.
    ((rc == 130)) && return 130
    ((rc != 0 && rc != 1)) && just_die "error: fzf failed (rc=$rc)"

    mapfile -t lines <<< "$selected"
    query=${lines[0]:-}
    ((${#lines[@]} >= 2)) || continue
    [[ -n ${lines[1]} ]] || continue
    printf '%s\n' "${lines[1]%%$'\t'*}"
    return 0
  done
}

pick_suggestion() {
  local name=$1 default=${2:-} choice rc
  local -a suggestions=()

  while IFS= read -r choice; do
    [[ -n $choice ]] && suggestions+=("$choice")
  done < <(suggest_values "$name")

  if ((${#suggestions[@]})); then
    rc=0
    choice=$(printf '%s\n' "${suggestions[@]}" | fzf \
      --exact \
      --no-sort \
      --query "$default" \
      --prompt="${name}> " \
      --header='Browse a suggestion, then edit or submit.' \
      --select-1 \
      --exit-0) || rc=$?
    ((rc != 0)) && return 1
    rc=0
    choice=$(gum input --prompt "${name}> " --value "$choice") || rc=$?
    ((rc != 0)) && return 1
  else
    rc=0
    choice=$(gum input --prompt "${name}> " --value "$default") || rc=$?
    ((rc != 0)) && return 1
  fi

  # Empty submit means "take the recipe's default" when there is one;
  # only an explicit cancel (esc/ctrl-c -> nonzero rc above) aborts.
  if [[ -z $choice ]]; then
    [[ -n $default ]] || return 1
    choice=$default
  fi
  printf '%s\n' "$choice"
}

collect_required_args() {
  local recipe=$1 name kind default line value rc
  local -a params=()

  # Read the parameter list up front: pick_suggestion runs a TUI, so the
  # loop must not hold a process substitution on its stdin.
  mapfile -t params < <(recipe_params "$recipe")
  for line in "${params[@]+"${params[@]}"}"; do
    IFS=$'\t' read -r name kind default <<< "$line"
    [[ $kind == singular ]] || continue
    rc=0
    value=$(pick_suggestion "$name" "$default") || rc=$?
    ((rc != 0)) && return 1
    printf '%s\n' "$value"
  done
}

collect_free_args() {
  local value rc=0
  local -a args=()

  value=$(gum input \
    --prompt='extra arguments> ' \
    --placeholder='space-separated; for example: --all-features -- --nocapture') || rc=$?
  ((rc != 0)) && return 1
  [[ -z $value ]] && return 0

  read -r -a args <<< "$value"
  ((${#args[@]})) || return 0
  printf '%s\n' "${args[@]}"
}

# Append newline-separated values from $2 into the array named by $1,
# skipping empty lines. Keeps run_recipe able to detect a cancelled
# sub-prompt via command-substitution exit status (a process
# substitution would silently swallow it).
append_args() {
  local -n _dst=$1
  local _line
  while IFS= read -r _line; do
    [[ -n $_line ]] && _dst+=("$_line")
  done <<< "$2"
  return 0
}

run_recipe() {
  local recipe=$1 out rc name kind default
  local has_params=0 variadic=0
  local -a args=()

  while IFS=$'\t' read -r name kind default; do
    [[ -n $name ]] || continue
    has_params=1
    [[ $kind == star || $kind == plus ]] && variadic=1
  done < <(recipe_params "$recipe")

  if ((has_params)); then
    rc=0
    out=$(collect_required_args "$recipe") || rc=$?
    ((rc != 0)) && return 0
    append_args args "$out"

    if ((variadic)); then
      rc=0
      out=$(collect_free_args) || rc=$?
      ((rc != 0)) && return 0
      append_args args "$out"
    fi

    printf '\n'
    print_command "$recipe" "${args[@]+"${args[@]}"}"
    preview_recipe "$recipe"
    printf '\n'

    rc=0
    gum confirm 'Run this recipe?' --default=false || rc=$?
    ((rc != 0)) && return 0
  fi

  (
    cd -- "$JUST_REPO_DIR" || exit 1
    "$JUST_BIN" "$recipe" "${args[@]+"${args[@]}"}"
  )
}

main() {
  local recipe rc

  while :; do
    rc=0
    recipe=$(select_recipe) || rc=$?
    ((rc != 0)) && return 0
    [[ -n $recipe ]] || continue

    run_recipe "$recipe"

    rc=0
    gum confirm 'Return to menu?' --default=true || rc=$?
    ((rc != 0)) && return 0
  done
}

main "$@"
