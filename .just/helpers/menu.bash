#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.bash
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.bash"

just_require fzf
just_require jq
just_require gum

select_recipe() {
  local query='' selected key shell_bin
  shell_bin=$(command -v bash) || just_die 'bash not found'

  # fzf runs reload/preview snippets through $SHELL. Force bash and export
  # the helper functions + their env so the child resolves them directly,
  # with no fragile path embedding or nested quoting.
  export JUST_HELPERS_DIR JUST_REPO_DIR JUST_BIN
  export -f strict_candidates recipe_rows just_json preview_recipe

  while :; do
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
      --header='Whole-word prefixes only. Alt-a: free-form extras. Enter: guided.' \
      --bind='change:reload:strict_candidates {q}' \
      --expect=alt-a \
      --preview='preview_recipe {1}' \
      --preview-window='right:60%:wrap' \
      --query="$query" \
      --print-query) || return 1

    query=${selected%%$'\n'*}
    selected=${selected#*$'\n'}
    key=${selected%%$'\n'*}
    selected=${selected#*$'\n'}
    [[ -n $selected ]] || continue
    printf '%s\t%s\n' "${selected%%$'\t'*}" "${key:-enter}"
    return 0
  done
}

pick_suggestion() {
  local name=$1 default=${2:-} choice
  local -a suggestions=()

  while IFS= read -r choice; do
    [[ -n $choice ]] && suggestions+=("$choice")
  done < <(suggest_values "$name")

  if ((${#suggestions[@]})); then
    choice=$(printf '%s\n' "${suggestions[@]}" | fzf \
      --exact \
      --no-sort \
      --query "$default" \
      --prompt="${name}> " \
      --header='Browse a suggestion, then edit or submit.' \
      --select-1 \
      --exit-0) || return 1
    choice=$(gum input --prompt "${name}> " --value "$choice") || return 1
  else
    choice=$(gum input --prompt "${name}> " --value "$default") || return 1
  fi

  [[ -n $choice ]] || return 1
  printf '%s\n' "$choice"
}

collect_required_args() {
  local recipe=$1 name kind default value

  while IFS=$'\t' read -r name kind default; do
    [[ $kind == singular ]] || continue
    value=$(pick_suggestion "$name" "$default") || return 1
    printf '%s\n' "$value"
  done < <(recipe_params "$recipe")
}

pick_optional_args() {
  local recipe=$1 choice value
  local -a options=()

  mapfile -t options < <(recommended_args "$recipe")
  ((${#options[@]})) || return 0

  choice=$(printf '%s\n' "${options[@]}" | gum choose \
    --no-limit \
    --selected "${options[0]}" \
    --header='Optional recommended arguments; select zero or more.') || return 1

  while IFS= read -r value; do
    [[ -n $value ]] && printf '%s\n' "$value"
  done <<< "$choice"
}

collect_free_args() {
  local value
  local -a args=()

  value=$(gum input \
    --prompt='extra arguments> ' \
    --placeholder='space-separated; for example: --all-features -- --nocapture') || return 1
  [[ -z $value ]] && return 0

  read -r -a args <<< "$value"
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
}

run_recipe() {
  local recipe=$1 mode=$2 out
  local -a args=()

  out=$(collect_required_args "$recipe") || return 0
  append_args args "$out"

  case $mode in
    guided)
      out=$(pick_optional_args "$recipe") || return 0
      append_args args "$out"
      ;;
    free)
      out=$(collect_free_args) || return 0
      append_args args "$out"
      ;;
  esac

  printf '\n'
  print_command "$recipe" "${args[@]}"
  preview_recipe "$recipe"
  printf '\n'

  gum confirm 'Run this recipe?' --default=false || return 0
  (
    cd -- "$JUST_REPO_DIR" || exit 1
    "$JUST_BIN" "$recipe" "${args[@]}"
  )
}

main() {
  local selection recipe key action

  while selection=$(select_recipe); do
    recipe=${selection%%$'\t'*}
    key=${selection#*$'\t'}
    if [[ $key == alt-a ]]; then
      run_recipe "$recipe" free
    else
      action=$(gum choose --header="$recipe" \
        'Guided: required values + recommended options' \
        'Free-form: required values + custom extras' \
        'Back') || return 0
      case $action in
        Guided:*) run_recipe "$recipe" guided ;;
        Free-form:*) run_recipe "$recipe" free ;;
        Back) continue ;;
      esac
    fi
    gum confirm 'Return to menu?' --default=true || return 0
  done
}

main "$@"
