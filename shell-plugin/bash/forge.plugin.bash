#!/usr/bin/env bash
# forge.plugin.bash -- forge interactive plugin, BASH port (candidate B).
#
# STRUCTURAL APPROACH (candidate B divergence): ONE self-contained file with a
# flat dispatch table and a MINIMAL, hand-rolled in-widget preexec/precmd. No
# ble.sh, no vendored bash-preexec, no lib/ split. Every accepted line (colon
# and non-colon) flows through a single readline `bind -x` widget on \C-m, so
# OSC-133 emission and the terminal-context ring buffer are driven inline.
#
# PARITY POSTURE: T1 (forge subprocess argv+env+cwd) byte-identical to
# forge-zsh; OSC-133 (T2) byte-identical. The 16 line-editor primitives readline
# cannot reproduce are REDUCED and documented in SCORE.md -- best-effort or
# explicit no-op, never faked.
#
# zsh->bash idioms: $BUFFER/$CURSOR -> READLINE_LINE/READLINE_POINT ;
# $match[N] -> ${BASH_REMATCH[N]} ; ${v:l}/${v:u} -> ${v,,}/${v^^} ;
# print -s -> history -s ; local -x scoped export -> local -x (bash keeps it).

# ---- Config / mutable session state (config.zsh). Plain vars, NOT exported. --
_FORGE_BIN="${FORGE_BIN:-forge}"
_FORGE_MAX_COMMIT_DIFF="${FORGE_MAX_COMMIT_DIFF:-100000}"
_FORGE_COMMANDS=""
_FORGE_CONVERSATION_ID=""
_FORGE_ACTIVE_AGENT=""
_FORGE_PREVIOUS_CONVERSATION_ID=""
_FORGE_SESSION_MODEL=""
_FORGE_SESSION_PROVIDER=""
_FORGE_SESSION_REASONING_EFFORT=""
_FORGE_TERM="${FORGE_TERM:-true}"
_FORGE_TERM_MAX_COMMANDS="${FORGE_TERM_MAX_COMMANDS:-5}"
_FORGE_TERM_OSC133="${FORGE_TERM_OSC133:-auto}"
declare -a _FORGE_TERM_COMMANDS=()
declare -a _FORGE_TERM_EXIT_CODES=()
declare -a _FORGE_TERM_TIMESTAMPS=()

# ---- OSC-133 (context.zsh). Cached per-session gate. -------------------------
_FORGE_TERM_OSC133_CACHED=""
_forge_osc133_should_emit() {
  if [[ -n "$_FORGE_TERM_OSC133_CACHED" ]]; then
    [[ "$_FORGE_TERM_OSC133_CACHED" == "1" ]]; return
  fi
  case "$_FORGE_TERM_OSC133" in
    on)  _FORGE_TERM_OSC133_CACHED="1"; return 0 ;;
    off) _FORGE_TERM_OSC133_CACHED="0"; return 1 ;;
    auto)
      if [[ -n "${KITTY_PID:-}" ]]; then _FORGE_TERM_OSC133_CACHED="1"; return 0; fi
      case "${TERM_PROGRAM:-}" in
        WezTerm|iTerm.app|vscode|WarpTerminal) _FORGE_TERM_OSC133_CACHED="1"; return 0 ;;
      esac
      if [[ "${TERM:-}" == foot* ]]; then _FORGE_TERM_OSC133_CACHED="1"; return 0; fi
      if [[ "${TERM_PROGRAM:-}" == "ghostty" ]]; then _FORGE_TERM_OSC133_CACHED="1"; return 0; fi
      _FORGE_TERM_OSC133_CACHED="0"; return 1 ;;
    *) _FORGE_TERM_OSC133_CACHED="0"; return 1 ;;
  esac
}
_forge_osc133_emit() {
  _forge_osc133_should_emit || return 0
  printf '\e]133;%s\a' "$1"
}

# ---- forge exec helpers (helpers.zsh). --agent injected by _forge_exec* only --
_forge_export_term_ctx() {
  if [[ "$_FORGE_TERM" == "true" && ${#_FORGE_TERM_COMMANDS[@]} -gt 0 ]]; then
    local IFS=$'\x1f'
    local -x _FORGE_TERM_COMMANDS="${_FORGE_TERM_COMMANDS[*]}"
    local -x _FORGE_TERM_EXIT_CODES="${_FORGE_TERM_EXIT_CODES[*]}"
    local -x _FORGE_TERM_TIMESTAMPS="${_FORGE_TERM_TIMESTAMPS[*]}"
    IFS=$' \t\n'
    "$@"; return
  fi
  "$@"
}
_forge_exec() {
  local agent_id="${_FORGE_ACTIVE_AGENT:-forge}"
  [[ -n "$_FORGE_SESSION_MODEL" ]] && local -x FORGE_SESSION__MODEL_ID="$_FORGE_SESSION_MODEL"
  [[ -n "$_FORGE_SESSION_PROVIDER" ]] && local -x FORGE_SESSION__PROVIDER_ID="$_FORGE_SESSION_PROVIDER"
  [[ -n "$_FORGE_SESSION_REASONING_EFFORT" ]] && local -x FORGE_REASONING__EFFORT="$_FORGE_SESSION_REASONING_EFFORT"
  [[ -e "$HOME/.claude/.caveman-active" ]] && local -x FORGE_EXTRA_INSTRUCTIONS_PATH="$HOME/forge/skills/caveman/SKILL.md"
  _forge_export_term_ctx "$_FORGE_BIN" --agent "$agent_id" "$@"
}
_forge_exec_interactive() {
  local agent_id="${_FORGE_ACTIVE_AGENT:-forge}"
  [[ -n "$_FORGE_SESSION_MODEL" ]] && local -x FORGE_SESSION__MODEL_ID="$_FORGE_SESSION_MODEL"
  [[ -n "$_FORGE_SESSION_PROVIDER" ]] && local -x FORGE_SESSION__PROVIDER_ID="$_FORGE_SESSION_PROVIDER"
  [[ -n "$_FORGE_SESSION_REASONING_EFFORT" ]] && local -x FORGE_REASONING__EFFORT="$_FORGE_SESSION_REASONING_EFFORT"
  [[ -e "$HOME/.claude/.caveman-active" ]] && local -x FORGE_EXTRA_INSTRUCTIONS_PATH="$HOME/forge/skills/caveman/SKILL.md"
  local -a cmd=("$_FORGE_BIN" --agent "$agent_id" "$@")
  if [[ "$_FORGE_TERM" == "true" && ${#_FORGE_TERM_COMMANDS[@]} -gt 0 ]]; then
    local IFS=$'\x1f'
    local -x _FORGE_TERM_COMMANDS="${_FORGE_TERM_COMMANDS[*]}"
    local -x _FORGE_TERM_EXIT_CODES="${_FORGE_TERM_EXIT_CODES[*]}"
    local -x _FORGE_TERM_TIMESTAMPS="${_FORGE_TERM_TIMESTAMPS[*]}"
    IFS=$' \t\n'
  fi
  "${cmd[@]}" </dev/tty >/dev/tty
}
_forge_select() {
  [[ -n "$_FORGE_SESSION_MODEL" ]] && local -x FORGE_SESSION__MODEL_ID="$_FORGE_SESSION_MODEL"
  [[ -n "$_FORGE_SESSION_PROVIDER" ]] && local -x FORGE_SESSION__PROVIDER_ID="$_FORGE_SESSION_PROVIDER"
  [[ -n "$_FORGE_SESSION_REASONING_EFFORT" ]] && local -x FORGE_REASONING__EFFORT="$_FORGE_SESSION_REASONING_EFFORT"
  CLICOLOR_FORCE=0 "$_FORGE_BIN" select "$@" </dev/tty 2>/dev/tty
}
_forge_select_global() { CLICOLOR_FORCE=0 "$_FORGE_BIN" select "$@" </dev/tty 2>/dev/tty; }
_forge_select_with_query() {
  local query="$1"; shift
  if [[ -n "$query" ]]; then _forge_select "$@" --query "$query"; else _forge_select "$@"; fi
}
_forge_select_with_query_global() {
  local query="$1"; shift
  if [[ -n "$query" ]]; then _forge_select_global "$@" --query "$query"; else _forge_select_global "$@"; fi
}
declare -a _forge_reply=()
_forge_select_model_pair() {
  local result; result="$(_forge_select_with_query "$1" model)"
  _forge_reply=(); [[ -z "$result" ]] && return 1
  mapfile -t _forge_reply <<<"$result"; [[ ${#_forge_reply[@]} -ge 2 ]]
}
_forge_select_model_pair_global() {
  local result; result="$(_forge_select_with_query_global "$1" model)"
  _forge_reply=(); [[ -z "$result" ]] && return 1
  mapfile -t _forge_reply <<<"$result"; [[ ${#_forge_reply[@]} -ge 2 ]]
}
_forge_is_workspace_indexed() { "$_FORGE_BIN" workspace info "$1" >/dev/null 2>&1; }
_forge_start_background_sync() {
  local sync_enabled="${FORGE_SYNC_ENABLED:-true}"
  [[ "$sync_enabled" != "true" ]] && return 0
  local workspace_path; workspace_path="$(pwd -P)"
  ( set +m; exec >/dev/null 2>&1 </dev/null
    _forge_is_workspace_indexed "$workspace_path" || exit 0
    "$_FORGE_BIN" workspace sync "$workspace_path" ) &
  disown 2>/dev/null
}
_forge_start_background_update() {
  ( set +m; exec >/dev/null 2>&1 </dev/null
    "$_FORGE_BIN" update --no-confirm ) &
  disown 2>/dev/null
}

# ---- Conversation helpers (conversation.zsh) --------------------------------
_forge_switch_conversation() {
  local new_id="$1"
  if [[ -n "$_FORGE_CONVERSATION_ID" && "$_FORGE_CONVERSATION_ID" != "$new_id" ]]; then
    _FORGE_PREVIOUS_CONVERSATION_ID="$_FORGE_CONVERSATION_ID"
  fi
  _FORGE_CONVERSATION_ID="$new_id"
}
_forge_clear_conversation() {
  [[ -n "$_FORGE_CONVERSATION_ID" ]] && _FORGE_PREVIOUS_CONVERSATION_ID="$_FORGE_CONVERSATION_ID"
  _FORGE_CONVERSATION_ID=""
}

# ---- Action handlers (actions/*.zsh). argv byte-identical to forge-zsh. ------
_forge_action_new() {
  local input_text="$1"
  _forge_clear_conversation
  _FORGE_ACTIVE_AGENT="forge"
  if [[ -n "$input_text" ]]; then
    local new_id; new_id="$("$_FORGE_BIN" conversation new)"
    _forge_switch_conversation "$new_id"
    _forge_exec_interactive -p "$input_text" --cid "$_FORGE_CONVERSATION_ID"
    _forge_start_background_sync
    _forge_start_background_update
  else
    _forge_exec banner
  fi
}
_forge_action_info() {
  if [[ -n "$_FORGE_CONVERSATION_ID" ]]; then _forge_exec info --cid "$_FORGE_CONVERSATION_ID"
  else _forge_exec info; fi
}
_forge_handle_conversation_command() {
  local subcommand="$1"; shift
  [[ -z "$_FORGE_CONVERSATION_ID" ]] && return 0
  _forge_exec conversation "$subcommand" "$_FORGE_CONVERSATION_ID" "$@"
}
_forge_action_dump() {
  if [[ "$1" == "html" ]]; then _forge_handle_conversation_command dump --html
  else _forge_handle_conversation_command dump; fi
}
_forge_action_compact() { _forge_handle_conversation_command compact; }
_forge_action_retry()   { _forge_handle_conversation_command retry; }
_forge_action_help()    { "$_FORGE_BIN" list command; }
_forge_action_agent() {
  local input_text="$1"
  if [[ -n "$input_text" ]]; then
    local agent_id="$input_text" exists
    exists="$("$_FORGE_BIN" list agents --porcelain 2>/dev/null | tail -n +2 | grep -q "^${agent_id}\b" && echo true || echo false)"
    [[ "$exists" == "false" ]] && return 0
    _FORGE_ACTIVE_AGENT="$agent_id"; return 0
  fi
  local agent_id; agent_id="$(_forge_select_with_query "$input_text" agent)"
  [[ -n "$agent_id" ]] && _FORGE_ACTIVE_AGENT="$agent_id"; return 0
}
_forge_action_model() {
  if _forge_select_model_pair_global "$1"; then
    _forge_exec config set model "${_forge_reply[1]}" "${_forge_reply[0]}"
  fi
}
_forge_action_commit_model() {
  if _forge_select_model_pair "$1"; then
    _forge_exec config set commit "${_forge_reply[1]}" "${_forge_reply[0]}"
  fi
}
_forge_action_suggest_model() {
  if _forge_select_model_pair "$1"; then
    _forge_exec config set suggest "${_forge_reply[1]}" "${_forge_reply[0]}"
  fi
}
_forge_action_session_model() {
  if _forge_select_model_pair "$1"; then
    _FORGE_SESSION_MODEL="${_forge_reply[0]}"; _FORGE_SESSION_PROVIDER="${_forge_reply[1]}"
  fi; return 0
}
_forge_action_config_reload() {
  _FORGE_SESSION_MODEL=""; _FORGE_SESSION_PROVIDER=""; _FORGE_SESSION_REASONING_EFFORT=""; return 0
}
_forge_action_reasoning_effort() {
  local selected; selected="$(_forge_select_with_query "$1" reasoning-effort)"
  [[ -n "$selected" ]] && _FORGE_SESSION_REASONING_EFFORT="$selected"; return 0
}
_forge_action_config_reasoning_effort() {
  local selected; selected="$(_forge_select_with_query "$1" reasoning-effort)"
  [[ -n "$selected" ]] && _forge_exec config set reasoning-effort "$selected"; return 0
}
_forge_action_sync()        { _forge_exec_interactive workspace sync --init; }
_forge_action_sync_init()   { _forge_exec_interactive workspace init; }
_forge_action_sync_status() { _forge_exec workspace status "."; }
_forge_action_sync_info()   { _forge_exec workspace info "."; }
_forge_action_config() { _forge_exec config list; }
_forge_action_config_edit() {
  local editor_cmd="${FORGE_EDITOR:-${EDITOR:-nano}}"
  command -v "${editor_cmd%% *}" &>/dev/null || return 1
  local config_file; config_file="$("$_FORGE_BIN" config path 2>/dev/null)"
  [[ -z "$config_file" ]] && return 1
  local config_dir; config_dir="$(dirname "$config_file")"
  [[ -d "$config_dir" ]] || mkdir -p "$config_dir" || return 1
  [[ -f "$config_file" ]] || touch "$config_file" || return 1
  ( eval "$editor_cmd '$config_file'" </dev/tty >/dev/tty 2>&1 )
  _forge_reset
}
_forge_action_tools()  { local agent_id="${_FORGE_ACTIVE_AGENT:-forge}"; _forge_exec list tools "$agent_id"; }
_forge_action_skill()  { _forge_exec list skill; }
_forge_action_conversation() {
  local input_text="$1"
  if [[ "$input_text" == "-" ]]; then
    if [[ -z "$_FORGE_PREVIOUS_CONVERSATION_ID" ]]; then input_text=""
    else
      local temp="$_FORGE_CONVERSATION_ID"
      _FORGE_CONVERSATION_ID="$_FORGE_PREVIOUS_CONVERSATION_ID"
      _FORGE_PREVIOUS_CONVERSATION_ID="$temp"
      _forge_exec conversation show "$_FORGE_CONVERSATION_ID"
      _forge_exec conversation info "$_FORGE_CONVERSATION_ID"
      return 0
    fi
  fi
  if [[ -n "$input_text" ]]; then
    _forge_switch_conversation "$input_text"
    _forge_exec conversation show "$input_text"
    _forge_exec conversation info "$input_text"
    return 0
  fi
  local conversation_id; conversation_id="$(_forge_select conversation)"
  if [[ -n "$conversation_id" ]]; then
    _forge_switch_conversation "$conversation_id"
    _forge_exec conversation show "$conversation_id"
    _forge_exec conversation info "$conversation_id"
  fi; return 0
}
_forge_action_conversation_tree() { _forge_select conversation --parent "$_FORGE_CONVERSATION_ID"; }
_forge_action_rename() {
  local input_text="$1"
  [[ -z "$_FORGE_CONVERSATION_ID" ]] && return 0
  [[ -z "$input_text" ]] && return 0
  # shellcheck disable=SC2086
  _forge_exec conversation rename "$_FORGE_CONVERSATION_ID" $input_text
}
_forge_action_conversation_rename() {
  local input_text="$1"
  if [[ -n "$input_text" ]]; then
    local conversation_id="${input_text%% *}" new_name="${input_text#* }"
    [[ "$conversation_id" == "$new_name" ]] && return 0
    # shellcheck disable=SC2086
    _forge_exec conversation rename "$conversation_id" $new_name; return 0
  fi
  local conversation_id; conversation_id="$(_forge_select conversation)"
  if [[ -n "$conversation_id" ]]; then
    local new_name; read -r new_name </dev/tty
    # shellcheck disable=SC2086
    [[ -n "$new_name" ]] && _forge_exec conversation rename "$conversation_id" $new_name
  fi; return 0
}
_forge_action_copy() {
  [[ -z "$_FORGE_CONVERSATION_ID" ]] && return 0
  local content; content="$("$_FORGE_BIN" conversation show --md "$_FORGE_CONVERSATION_ID" 2>/dev/null)"
  [[ -z "$content" ]] && return 0
  if command -v pbcopy &>/dev/null; then printf '%s' "$content" | pbcopy
  elif command -v xclip &>/dev/null; then printf '%s' "$content" | xclip -selection clipboard
  elif command -v xsel &>/dev/null; then printf '%s' "$content" | xsel --clipboard --input; fi
  return 0
}
_forge_action_clone() {
  local clone_target="$1"
  if [[ -n "$clone_target" ]]; then _forge_clone_and_switch "$clone_target"; return 0; fi
  local conversation_id; conversation_id="$(_forge_select conversation)"
  [[ -n "$conversation_id" ]] && _forge_clone_and_switch "$conversation_id"; return 0
}
_forge_clone_and_switch() {
  local clone_target="$1" original="$_FORGE_CONVERSATION_ID" out rc
  out="$("$_FORGE_BIN" conversation clone "$clone_target" 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && return 0
  local new_id; new_id="$(printf '%s' "$out" | grep -oE '[a-f0-9-]{36}' | tail -1)"
  [[ -z "$new_id" ]] && return 0
  _forge_switch_conversation "$new_id"
  if [[ "$clone_target" != "$original" ]]; then
    _forge_exec conversation show "$new_id"
    _forge_exec conversation info "$new_id"
  fi; return 0
}
_forge_action_commit() {
  local additional_context="$1" commit_message
  if [[ -n "$additional_context" ]]; then
    # shellcheck disable=SC2086
    commit_message="$(FORCE_COLOR=true CLICOLOR_FORCE=1 "$_FORGE_BIN" commit --max-diff "$_FORGE_MAX_COMMIT_DIFF" $additional_context)"
  else
    commit_message="$(FORCE_COLOR=true CLICOLOR_FORCE=1 "$_FORGE_BIN" commit --max-diff "$_FORGE_MAX_COMMIT_DIFF")"
  fi
  _forge_reset
}
_forge_action_commit_preview() {
  local additional_context="$1" commit_message
  if [[ -n "$additional_context" ]]; then
    # shellcheck disable=SC2086
    commit_message="$(FORCE_COLOR=true CLICOLOR_FORCE=1 "$_FORGE_BIN" commit --preview --max-diff "$_FORGE_MAX_COMMIT_DIFF" $additional_context)"
  else
    commit_message="$(FORCE_COLOR=true CLICOLOR_FORCE=1 "$_FORGE_BIN" commit --preview --max-diff "$_FORGE_MAX_COMMIT_DIFF")"
  fi
  if [[ -n "$commit_message" ]]; then
    local q; printf -v q '%q' "$commit_message"
    if git diff --staged --quiet 2>/dev/null; then READLINE_LINE="git commit -am $q"
    else READLINE_LINE="git commit -m $q"; fi
    READLINE_POINT=${#READLINE_LINE}
  fi; return 0
}
_forge_action_login() {
  local provider; provider="$(_forge_select_with_query "$1" provider)"
  [[ -n "$provider" ]] && _forge_exec_interactive provider login "$provider"; return 0
}
_forge_action_logout() {
  local provider; provider="$(_forge_select_with_query "$1" provider --configured)"
  [[ -n "$provider" ]] && _forge_exec provider logout "$provider"; return 0
}
_forge_action_editor() {
  local initial_text="$1"
  local editor_cmd="${FORGE_EDITOR:-${EDITOR:-nano}}"
  command -v "${editor_cmd%% *}" &>/dev/null || return 1
  [[ -d ".forge" ]] || mkdir -p ".forge" || return 1
  local temp_file=".forge/FORGE_EDITMSG.md"
  touch "$temp_file" || return 1
  [[ -n "$initial_text" ]] && printf '%s\n' "$initial_text" >"$temp_file"
  ( eval "$editor_cmd '$temp_file'" </dev/tty >/dev/tty 2>&1 )
  local content; content="$(tr -d '\r' <"$temp_file")"
  rm -f "$temp_file"
  if [[ -z "$content" ]]; then READLINE_LINE=""; READLINE_POINT=0; return 0; fi
  READLINE_LINE=": $content"; READLINE_POINT=${#READLINE_LINE}; return 0
}
_forge_action_suggest() {
  local description="$1"
  [[ -z "$description" ]] && return 0
  local generated; generated="$(FORCE_COLOR=true CLICOLOR_FORCE=1 _forge_exec suggest "$description")"
  [[ -n "$generated" ]] && { READLINE_LINE="$generated"; READLINE_POINT=${#READLINE_LINE}; }
  return 0
}
_forge_get_commands() {
  if [[ -z "$_FORGE_COMMANDS" ]]; then
    _FORGE_COMMANDS="$(CLICOLOR_FORCE=0 "$_FORGE_BIN" list commands --porcelain 2>/dev/null)"
  fi
  printf '%s' "$_FORGE_COMMANDS"
}
_forge_action_default() {
  local user_action="$1" input_text="$2" command_type=""
  if [[ -n "$user_action" ]]; then
    local commands_list; commands_list="$(_forge_get_commands)"
    if [[ -n "$commands_list" ]]; then
      local command_row; command_row="$(printf '%s\n' "$commands_list" | grep "^${user_action}\b")"
      [[ -z "$command_row" ]] && return 0
      command_type="$(printf '%s' "$command_row" | awk '{print $2}')"
      if [[ "${command_type,,}" == "custom" ]]; then
        [[ -z "$_FORGE_CONVERSATION_ID" ]] && _FORGE_CONVERSATION_ID="$("$_FORGE_BIN" conversation new)"
        if [[ -n "$input_text" ]]; then
          _forge_exec cmd execute --cid "$_FORGE_CONVERSATION_ID" "$user_action" "$input_text"
        else
          _forge_exec cmd execute --cid "$_FORGE_CONVERSATION_ID" "$user_action"
        fi
        return 0
      fi
    fi
  fi
  if [[ -z "$input_text" ]]; then
    if [[ -n "$user_action" ]]; then
      [[ "${command_type,,}" != "agent" ]] && return 0
      _FORGE_ACTIVE_AGENT="$user_action"
    fi
    return 0
  fi
  [[ -z "$_FORGE_CONVERSATION_ID" ]] && _FORGE_CONVERSATION_ID="$("$_FORGE_BIN" conversation new)"
  [[ -n "$user_action" ]] && _FORGE_ACTIVE_AGENT="$user_action"
  _forge_exec_interactive -p "$input_text" --cid "$_FORGE_CONVERSATION_ID"
  _forge_start_background_sync
  _forge_start_background_update
}

# ---- In-widget preexec/precmd (minimal). Ring for non-colon commands. --------
_forge_ring_append() {
  local cmd="$1" code="$2" ts="$3"
  _FORGE_TERM_COMMANDS+=("$cmd"); _FORGE_TERM_EXIT_CODES+=("$code"); _FORGE_TERM_TIMESTAMPS+=("$ts")
  while (( ${#_FORGE_TERM_COMMANDS[@]} > _FORGE_TERM_MAX_COMMANDS )); do
    _FORGE_TERM_COMMANDS=("${_FORGE_TERM_COMMANDS[@]:1}")
    _FORGE_TERM_EXIT_CODES=("${_FORGE_TERM_EXIT_CODES[@]:1}")
    _FORGE_TERM_TIMESTAMPS=("${_FORGE_TERM_TIMESTAMPS[@]:1}")
  done
}
# REDUCED: readline has no reset-prompt/redisplay/invalidate. Clear buffer only.
_forge_reset() { READLINE_LINE=""; READLINE_POINT=0; return 0; }

# ---- The accept-line widget (dispatcher.zsh:90). Bound to \C-m. --------------
forge-accept-line() {
  local original_buffer="$READLINE_LINE"
  local user_action="" input_text=""
  local re1='^:([a-zA-Z][a-zA-Z0-9_-]*)( (.*))?$'
  local re2='^: (.*)$'
  if [[ "$READLINE_LINE" =~ $re1 ]]; then
    user_action="${BASH_REMATCH[1]}"
    if [[ -n "${BASH_REMATCH[2]}" ]]; then input_text="${BASH_REMATCH[3]}"; else input_text=""; fi
  elif [[ "$READLINE_LINE" =~ $re2 ]]; then
    user_action=""; input_text="${BASH_REMATCH[1]}"
  else
    # Non-colon line: REDUCED reimplementation of native accept-line (row 13).
    if [[ -z "$original_buffer" ]]; then READLINE_LINE=""; READLINE_POINT=0; return 0; fi
    history -s -- "$original_buffer"
    local ts; ts="$(date +%s)"
    _forge_osc133_emit "B"; _forge_osc133_emit "C"
    printf '\n'
    eval "$original_buffer"
    local ec=$?
    _forge_osc133_emit "D;$ec"
    [[ "$_FORGE_TERM" == "true" ]] && _forge_ring_append "$original_buffer" "$ec" "$ts"
    _forge_osc133_emit "A"
    READLINE_LINE=""; READLINE_POINT=0; return 0
  fi
  history -s -- "$original_buffer"
  READLINE_POINT=${#READLINE_LINE}
  case "$user_action" in
    ask)  user_action="sage" ;;
    plan) user_action="muse" ;;
  esac
  _forge_osc133_emit "B"; _forge_osc133_emit "C"
  printf '\n'
  local action_status=0
  case "$user_action" in
    new|n)                                _forge_action_new "$input_text" ;;
    info|i)                               _forge_action_info ;;
    dump|d)                               _forge_action_dump "$input_text" ;;
    compact)                              _forge_action_compact ;;
    retry|r)                              _forge_action_retry ;;
    help)                                 _forge_action_help ;;
    agent|a)                              _forge_action_agent "$input_text" ;;
    conversation|c)                       _forge_action_conversation "$input_text" ;;
    conversation-tree|ct)                 _forge_action_conversation_tree ;;
    config-model|cm)                      _forge_action_model "$input_text" ;;
    model|m)                              _forge_action_session_model "$input_text" ;;
    config-reload|cr|model-reset|mr)      _forge_action_config_reload ;;
    reasoning-effort|re)                  _forge_action_reasoning_effort "$input_text" ;;
    config-reasoning-effort|cre)          _forge_action_config_reasoning_effort "$input_text" ;;
    config-commit-model|ccm)              _forge_action_commit_model "$input_text" ;;
    config-suggest-model|csm)             _forge_action_suggest_model "$input_text" ;;
    tools|t)                              _forge_action_tools ;;
    config|env|e)                         _forge_action_config ;;
    config-edit|ce)                       _forge_action_config_edit ;;
    skill)                                _forge_action_skill ;;
    edit|ed)
      _forge_action_editor "$input_text"; action_status=$?
      _forge_osc133_emit "D;$action_status"; _forge_osc133_emit "A"; return $action_status ;;
    commit)                               _forge_action_commit "$input_text" ;;
    commit-preview)
      _forge_action_commit_preview "$input_text"; action_status=$?
      _forge_osc133_emit "D;$action_status"; _forge_osc133_emit "A"; return $action_status ;;
    suggest|s)
      _forge_action_suggest "$input_text"; action_status=$?
      _forge_osc133_emit "D;$action_status"; _forge_osc133_emit "A"; return $action_status ;;
    clone)                                _forge_action_clone "$input_text" ;;
    rename|rn)                            _forge_action_rename "$input_text" ;;
    conversation-rename)                  _forge_action_conversation_rename "$input_text" ;;
    copy)                                 _forge_action_copy ;;
    workspace-sync|sync)                  _forge_action_sync ;;
    workspace-init|sync-init)             _forge_action_sync_init ;;
    workspace-status|sync-status)         _forge_action_sync_status ;;
    workspace-info|sync-info)             _forge_action_sync_info ;;
    provider-login|login|provider)        _forge_action_login "$input_text" ;;
    logout)                               _forge_action_logout "$input_text" ;;
    *)                                    _forge_action_default "$user_action" "$input_text" ;;
  esac
  action_status=$?
  _forge_osc133_emit "D;$action_status"; _forge_osc133_emit "A"
  _forge_reset
  return 0
}

# ---- Key bindings (bindings.zsh). Enter -> widget; C-j stays native. ---------
if [[ $- == *i* ]]; then
  bind -x '"\C-m": forge-accept-line' 2>/dev/null
fi
