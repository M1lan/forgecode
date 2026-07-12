# forge.plugin.fish -- fish-shell port of the forge-zsh interactive plugin.
# FULLER parity target (fish column of 03-parity-gap.md).
#
# Reimplements the dispatch state machine from shell-plugin/lib/dispatcher.zsh:
#   - parse the command line (`:cmd [args]`, `: <text>`, non-`:` = normal exec)
#   - alias map (ask->sage, plan->muse) + short aliases
#   - ~40-way dispatch, each shelling to the SAME `forge <subcmd>` argv as zsh
#     (T1 byte-identical incl injected _FORGE_SESSION_* env + cwd)
#   - OSC-133 A/B/C/D emission (02-lifecycle.md)
#   - per-fish-session state, cid pinned to THIS session (no LAST_ACTIVE leak)

# ---------------------------------------------------------------------------
# 0. Config (config.zsh) -- per fish session (global, not universal, so each
#    fish instance owns its own conversation/agent state: INV-TTY-PIN).
# ---------------------------------------------------------------------------
if set -q FORGE_BIN
    set -g _FORGE_BIN $FORGE_BIN
else
    set -g _FORGE_BIN forge
end
set -g _FORGE_MAX_COMMIT_DIFF (set -q FORGE_MAX_COMMIT_DIFF; and echo $FORGE_MAX_COMMIT_DIFF; or echo 100000)
set -g _FORGE_COMMANDS ""
# Unconditional fresh-empty per fish session (matches zsh `typeset -h`): never
# inherit a pre-existing universal/exported value -> no cross-tty state leak
# (INV-TTY-PIN).
set -g _FORGE_CONVERSATION_ID ''
set -g _FORGE_ACTIVE_AGENT ''
set -g _FORGE_PREVIOUS_CONVERSATION_ID ''
set -g _FORGE_SESSION_MODEL ''
set -g _FORGE_SESSION_PROVIDER ''
set -g _FORGE_SESSION_REASONING_EFFORT ''

set -g _FORGE_TERM (set -q FORGE_TERM; and echo $FORGE_TERM; or echo true)
set -g _FORGE_TERM_MAX_COMMANDS (set -q FORGE_TERM_MAX_COMMANDS; and echo $FORGE_TERM_MAX_COMMANDS; or echo 5)
set -g _FORGE_TERM_OSC133 (set -q FORGE_TERM_OSC133; and echo $FORGE_TERM_OSC133; or echo auto)
set -g _FORGE_TERM_COMMANDS
set -g _FORGE_TERM_EXIT_CODES
set -g _FORGE_TERM_TIMESTAMPS
set -g _FORGE_TERM_PENDING_CMD ""
set -g _FORGE_TERM_PENDING_TS ""
set -g _FORGE_TERM_OSC133_CACHED ""
set -g _FORGE_US (printf '\x1f')

# ---------------------------------------------------------------------------
# 1. OSC-133 (context.zsh) -- gate cached per session; emit \e]133;<mark>\a
# ---------------------------------------------------------------------------
function _forge_osc133_should_emit
    if test -n "$_FORGE_TERM_OSC133_CACHED"
        test "$_FORGE_TERM_OSC133_CACHED" = 1; and return 0; or return 1
    end
    switch "$_FORGE_TERM_OSC133"
        case on
            set -g _FORGE_TERM_OSC133_CACHED 1; return 0
        case off
            set -g _FORGE_TERM_OSC133_CACHED 0; return 1
        case auto
            if set -q KITTY_PID
                set -g _FORGE_TERM_OSC133_CACHED 1; return 0
            end
            switch "$TERM_PROGRAM"
                case WezTerm iTerm.app vscode WarpTerminal ghostty
                    set -g _FORGE_TERM_OSC133_CACHED 1; return 0
            end
            if string match -q 'foot*' -- "$TERM"
                set -g _FORGE_TERM_OSC133_CACHED 1; return 0
            end
            set -g _FORGE_TERM_OSC133_CACHED 0; return 1
        case '*'
            set -g _FORGE_TERM_OSC133_CACHED 0; return 1
    end
end

function _forge_osc133_emit
    _forge_osc133_should_emit; or return 0
    printf '\e]133;%s\a' $argv[1]
end

# ---------------------------------------------------------------------------
# 2. Child-env helpers (helpers.zsh) -- session overrides + ring buffer are
#    injected ONLY into the child forge process (via `env` prefix), never
#    leaked into the fish session.
# ---------------------------------------------------------------------------
function _forge_session_envs
    set -l e
    test -n "$_FORGE_SESSION_MODEL"; and set -a e "FORGE_SESSION__MODEL_ID=$_FORGE_SESSION_MODEL"
    test -n "$_FORGE_SESSION_PROVIDER"; and set -a e "FORGE_SESSION__PROVIDER_ID=$_FORGE_SESSION_PROVIDER"
    test -n "$_FORGE_SESSION_REASONING_EFFORT"; and set -a e "FORGE_REASONING__EFFORT=$_FORGE_SESSION_REASONING_EFFORT"
    for x in $e
        echo $x
    end
end

function _forge_ring_envs
    test "$_FORGE_TERM" = true; or return 0
    test (count $_FORGE_TERM_COMMANDS) -gt 0; or return 0
    echo "_FORGE_TERM_COMMANDS="(string join $_FORGE_US $_FORGE_TERM_COMMANDS)
    echo "_FORGE_TERM_EXIT_CODES="(string join $_FORGE_US $_FORGE_TERM_EXIT_CODES)
    echo "_FORGE_TERM_TIMESTAMPS="(string join $_FORGE_US $_FORGE_TERM_TIMESTAMPS)
end

# _forge_exec: always prefixes `--agent <agent>` (default forge).
function _forge_exec
    set -l agent forge
    test -n "$_FORGE_ACTIVE_AGENT"; and set agent $_FORGE_ACTIVE_AGENT
    set -l envs (_forge_session_envs) (_forge_ring_envs)
    env $envs $_FORGE_BIN --agent $agent $argv
end

# Like _forge_exec but wired to the real tty for interactive child pickers.
function _forge_exec_interactive
    set -l agent forge
    test -n "$_FORGE_ACTIVE_AGENT"; and set agent $_FORGE_ACTIVE_AGENT
    set -l envs (_forge_session_envs) (_forge_ring_envs)
    env $envs $_FORGE_BIN --agent $agent $argv </dev/tty >/dev/tty
end

# _forge_select: session overrides applied, CLICOLOR_FORCE=0, NEVER --agent.
function _forge_select
    set -l envs (_forge_session_envs) CLICOLOR_FORCE=0
    env $envs $_FORGE_BIN select $argv </dev/tty 2>/dev/tty
end

# _forge_select_global: NO session overrides (pick against true global config).
function _forge_select_global
    env CLICOLOR_FORCE=0 $_FORGE_BIN select $argv </dev/tty 2>/dev/tty
end

function _forge_select_with_query
    set -l query $argv[1]
    set -e argv[1]
    if test -n "$query"
        _forge_select $argv --query $query
    else
        _forge_select $argv
    end
end

function _forge_select_with_query_global
    set -l query $argv[1]
    set -e argv[1]
    if test -n "$query"
        _forge_select_global $argv --query $query
    else
        _forge_select_global $argv
    end
end

# Returns two-line model/provider pair via $reply (like zsh reply=()).
function _forge_select_model_pair
    set -g reply (_forge_select_with_query $argv[1] model)
    test (count $reply) -ge 2
end

function _forge_select_model_pair_global
    set -g reply (_forge_select_with_query_global $argv[1] model)
    test (count $reply) -ge 2
end

function _forge_get_commands
    if test -z "$_FORGE_COMMANDS"
        set -g _FORGE_COMMANDS (env CLICOLOR_FORCE=0 $_FORGE_BIN list commands --porcelain 2>/dev/null | string collect)
    end
    echo $_FORGE_COMMANDS
end

function _forge_is_workspace_indexed
    $_FORGE_BIN workspace info $argv[1] >/dev/null 2>&1
end

# Background sync/update fired ONLY on a real prompt-send (dispatcher default
# + `new` w/ prompt). Detached so nothing flashes to the terminal.
function _forge_start_background_sync
    set -l sync_enabled (set -q FORGE_SYNC_ENABLED; and echo $FORGE_SYNC_ENABLED; or echo true)
    test "$sync_enabled" = true; or return 0
    set -l wp (pwd -P)
    # Background block (no nested `fish -c`, no string interpolation): $wp is
    # passed as a real argv element, so the child argv stays exactly
    # `workspace info <path>` / `workspace sync <path>` even for paths with
    # quotes or spaces. Mirrors the zsh `{ ... } &!` block (helpers.zsh:217).
    begin
        $_FORGE_BIN workspace info $wp >/dev/null 2>&1
        and $_FORGE_BIN workspace sync $wp >/dev/null 2>&1
    end >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null
end

function _forge_start_background_update
    fish -c "$_FORGE_BIN update --no-confirm >/dev/null 2>&1" >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null
end

# fish repaints cleanly (row 8/24 FULL): clear buffer + repaint prompt.
function _forge_reset
    commandline -r ''
    commandline -f repaint
end

function _forge_log
    set -l level $argv[1]
    set -l message $argv[2]
    set -l ts (date '+%H:%M:%S')
    switch $level
        case error
            printf '\033[31m⏺\033[0m \033[90m[%s]\033[0m \033[31m%b\033[0m\n' $ts $message
        case info
            printf '\033[37m⏺\033[0m \033[90m[%s]\033[0m \033[37m%b\033[0m\n' $ts $message
        case success
            printf '\033[33m⏺\033[0m \033[90m[%s]\033[0m \033[37m%b\033[0m\n' $ts $message
        case warning
            printf '\033[93m⚠️\033[0m \033[90m[%s]\033[0m \033[93m%b\033[0m\n' $ts $message
        case debug
            printf '\033[36m⏺\033[0m \033[90m[%s]\033[0m \033[90m%b\033[0m\n' $ts $message
        case '*'
            printf '%b\n' $message
    end
end

# ---------------------------------------------------------------------------
# 3. Conversation state helpers (conversation.zsh)
# ---------------------------------------------------------------------------
function _forge_switch_conversation
    set -l new_id $argv[1]
    if test -n "$_FORGE_CONVERSATION_ID"; and test "$_FORGE_CONVERSATION_ID" != "$new_id"
        set -g _FORGE_PREVIOUS_CONVERSATION_ID $_FORGE_CONVERSATION_ID
    end
    set -g _FORGE_CONVERSATION_ID $new_id
end

function _forge_clear_conversation
    if test -n "$_FORGE_CONVERSATION_ID"
        set -g _FORGE_PREVIOUS_CONVERSATION_ID $_FORGE_CONVERSATION_ID
    end
    set -g _FORGE_CONVERSATION_ID ""
end

# ---------------------------------------------------------------------------
# 4. Action handlers (lib/actions/*.zsh)
# ---------------------------------------------------------------------------
function _forge_action_new
    set -l input_text $argv[1]
    _forge_clear_conversation
    set -g _FORGE_ACTIVE_AGENT forge
    echo
    if test -n "$input_text"
        set -l new_id ($_FORGE_BIN conversation new)
        _forge_switch_conversation $new_id
        _forge_exec_interactive -p $input_text --cid $_FORGE_CONVERSATION_ID
        _forge_start_background_sync
        _forge_start_background_update
    else
        _forge_exec banner
    end
end

function _forge_action_info
    echo
    if test -n "$_FORGE_CONVERSATION_ID"
        _forge_exec info --cid $_FORGE_CONVERSATION_ID
    else
        _forge_exec info
    end
end

function _forge_handle_conversation_command
    set -l subcommand $argv[1]
    set -e argv[1]
    echo
    if test -z "$_FORGE_CONVERSATION_ID"
        _forge_log error "No active conversation. Start a conversation first or use :conversation to see existing ones"
        return 0
    end
    _forge_exec conversation $subcommand $_FORGE_CONVERSATION_ID $argv
end

function _forge_action_dump
    if test "$argv[1]" = html
        _forge_handle_conversation_command dump --html
    else
        _forge_handle_conversation_command dump
    end
end

function _forge_action_compact
    _forge_handle_conversation_command compact
end

function _forge_action_retry
    _forge_handle_conversation_command retry
end

function _forge_action_help
    echo
    $_FORGE_BIN list command
end

function _forge_action_agent
    set -l input_text $argv[1]
    echo
    if test -n "$input_text"
        set -l agent_id $input_text
        if $_FORGE_BIN list agents --porcelain 2>/dev/null | tail -n +2 | grep -q "^$agent_id\b"
            set -g _FORGE_ACTIVE_AGENT $agent_id
            _forge_log success "Switched to agent \033[1m$agent_id\033[0m"
        else
            _forge_log error "Agent '\033[1m$agent_id\033[0m' not found"
        end
        return 0
    end
    set -l agent_id (_forge_select_with_query "$input_text" agent)
    if test -n "$agent_id"
        set -g _FORGE_ACTIVE_AGENT $agent_id
        _forge_log success "Switched to agent \033[1m$agent_id\033[0m"
    end
end

function _forge_action_conversation
    set -l input_text $argv[1]
    echo
    if test "$input_text" = -
        if test -z "$_FORGE_PREVIOUS_CONVERSATION_ID"
            set input_text ""
        else
            set -l tmp $_FORGE_CONVERSATION_ID
            set -g _FORGE_CONVERSATION_ID $_FORGE_PREVIOUS_CONVERSATION_ID
            set -g _FORGE_PREVIOUS_CONVERSATION_ID $tmp
            echo
            _forge_exec conversation show $_FORGE_CONVERSATION_ID
            _forge_exec conversation info $_FORGE_CONVERSATION_ID
            _forge_log success "Switched to conversation \033[1m$_FORGE_CONVERSATION_ID\033[0m"
            return 0
        end
    end
    if test -n "$input_text"
        set -l conversation_id $input_text
        _forge_switch_conversation $conversation_id
        echo
        _forge_exec conversation show $conversation_id
        _forge_exec conversation info $conversation_id
        _forge_log success "Switched to conversation \033[1m$conversation_id\033[0m"
        return 0
    end
    set -l conversation_id (_forge_select conversation)
    if test -n "$conversation_id"
        _forge_switch_conversation $conversation_id
        echo
        _forge_exec conversation show $conversation_id
        _forge_exec conversation info $conversation_id
        _forge_log success "Switched to conversation \033[1m$conversation_id\033[0m"
    end
end

function _forge_action_conversation_tree
    _forge_select conversation --parent $_FORGE_CONVERSATION_ID
end

function _forge_action_model
    set -l input_text $argv[1]
    echo
    if _forge_select_model_pair_global "$input_text"
        _forge_exec config set model $reply[2] $reply[1]
    end
end

function _forge_action_commit_model
    set -l input_text $argv[1]
    echo
    if _forge_select_model_pair "$input_text"
        _forge_exec config set commit $reply[2] $reply[1]
    end
end

function _forge_action_suggest_model
    set -l input_text $argv[1]
    echo
    if _forge_select_model_pair "$input_text"
        _forge_exec config set suggest $reply[2] $reply[1]
    end
end

function _forge_action_session_model
    set -l input_text $argv[1]
    echo
    if _forge_select_model_pair "$input_text"
        set -g _FORGE_SESSION_MODEL $reply[1]
        set -g _FORGE_SESSION_PROVIDER $reply[2]
        _forge_log success "Session model set to \033[1m$_FORGE_SESSION_MODEL\033[0m (provider: \033[1m$_FORGE_SESSION_PROVIDER\033[0m)"
    end
end

function _forge_action_config_reload
    echo
    if test -z "$_FORGE_SESSION_MODEL"; and test -z "$_FORGE_SESSION_PROVIDER"; and test -z "$_FORGE_SESSION_REASONING_EFFORT"
        _forge_log info "No session overrides active (already using global config)"
        return 0
    end
    set -g _FORGE_SESSION_MODEL ""
    set -g _FORGE_SESSION_PROVIDER ""
    set -g _FORGE_SESSION_REASONING_EFFORT ""
    _forge_log success "Session overrides cleared — using global config"
end

function _forge_action_reasoning_effort
    set -l input_text $argv[1]
    echo
    set -l selected (_forge_select_with_query "$input_text" reasoning-effort)
    if test -n "$selected"
        set -g _FORGE_SESSION_REASONING_EFFORT $selected
        _forge_log success "Session reasoning effort set to \033[1m$selected\033[0m"
    end
end

function _forge_action_config_reasoning_effort
    set -l input_text $argv[1]
    echo
    set -l selected (_forge_select_with_query "$input_text" reasoning-effort)
    if test -n "$selected"
        _forge_exec config set reasoning-effort $selected
    end
end

function _forge_action_config
    echo
    _forge_exec config list
end

function _forge_action_tools
    echo
    set -l agent_id forge
    test -n "$_FORGE_ACTIVE_AGENT"; and set agent_id $_FORGE_ACTIVE_AGENT
    _forge_exec list tools $agent_id
end

function _forge_action_skill
    echo
    _forge_exec list skill
end

function _forge_action_config_edit
    echo
    set -l editor_cmd (set -q FORGE_EDITOR; and echo $FORGE_EDITOR; or begin; set -q EDITOR; and echo $EDITOR; or echo nano; end)
    set -l bin (string split ' ' -- $editor_cmd)[1]
    if not command -v $bin >/dev/null 2>&1
        _forge_log error "Editor not found: $editor_cmd (set FORGE_EDITOR or EDITOR)"
        return 1
    end
    set -l config_file ($_FORGE_BIN config path 2>/dev/null)
    if test -z "$config_file"
        _forge_log error "Failed to resolve config path from '$_FORGE_BIN config path'"
        return 1
    end
    set -l config_dir (dirname $config_file)
    test -d $config_dir; or mkdir -p $config_dir
    test -f $config_file; or touch $config_file
    eval "$editor_cmd '$config_file'" </dev/tty >/dev/tty 2>&1
    _forge_reset
end

function _forge_action_sync
    echo
    _forge_exec_interactive workspace sync --init
end

function _forge_action_sync_init
    echo
    _forge_exec_interactive workspace init
end

function _forge_action_sync_status
    echo
    _forge_exec workspace status "."
end

function _forge_action_sync_info
    echo
    _forge_exec workspace info "."
end

function _forge_action_login
    set -l input_text $argv[1]
    echo
    set -l provider (_forge_select_with_query "$input_text" provider)
    if test -n "$provider"
        _forge_exec_interactive provider login $provider
    end
end

function _forge_action_logout
    set -l input_text $argv[1]
    echo
    set -l provider (_forge_select_with_query "$input_text" provider --configured)
    if test -n "$provider"
        _forge_exec provider logout $provider
    end
end

function _forge_action_copy
    echo
    if test -z "$_FORGE_CONVERSATION_ID"
        _forge_log error "No active conversation. Start a conversation first or use :conversation to see existing ones"
        return 0
    end
    set -l content ($_FORGE_BIN conversation show --md $_FORGE_CONVERSATION_ID 2>/dev/null | string collect)
    if test -z "$content"
        _forge_log error "No assistant message found in the current conversation"
        return 0
    end
    if command -v pbcopy >/dev/null 2>&1
        printf '%s' $content | pbcopy
    else if command -v xclip >/dev/null 2>&1
        printf '%s' $content | xclip -selection clipboard
    else if command -v xsel >/dev/null 2>&1
        printf '%s' $content | xsel --clipboard --input
    else
        _forge_log error "No clipboard utility found (pbcopy, xclip, or xsel required)"
        return 0
    end
    _forge_log success "Copied to clipboard"
end

function _forge_action_rename
    set -l input_text $argv[1]
    echo
    if test -z "$_FORGE_CONVERSATION_ID"
        _forge_log error "No active conversation. Start a conversation first or use :conversation to select one"
        return 0
    end
    if test -z "$input_text"
        _forge_log error "Usage: :rename <name>"
        return 0
    end
    # name passed UNQUOTED -> word-split into args (matches zsh rename:203)
    _forge_exec conversation rename $_FORGE_CONVERSATION_ID (string split --no-empty ' ' -- $input_text)
end

function _forge_action_conversation_rename
    set -l input_text $argv[1]
    echo
    if test -n "$input_text"
        set -l conversation_id (string split -m1 ' ' -- $input_text)[1]
        set -l new_name (string replace -r '^[^ ]* ' '' -- $input_text)
        if test "$conversation_id" = "$new_name"
            _forge_log error "Usage: :conversation-rename <id> <name>"
            return 0
        end
        _forge_exec conversation rename $conversation_id (string split --no-empty ' ' -- $new_name)
        return 0
    end
    set -l conversation_id (_forge_select conversation)
    if test -n "$conversation_id"
        echo -n "Enter new name: "
        read -l new_name </dev/tty
        if test -n "$new_name"
            _forge_exec conversation rename $conversation_id (string split --no-empty ' ' -- $new_name)
        else
            _forge_log error "No name provided, rename cancelled"
        end
    end
end

function _forge_action_clone
    set -l input_text $argv[1]
    echo
    if test -n "$input_text"
        _forge_clone_and_switch $input_text
        return 0
    end
    set -l conversation_id (_forge_select conversation)
    if test -n "$conversation_id"
        _forge_clone_and_switch $conversation_id
    end
end

function _forge_clone_and_switch
    set -l clone_target $argv[1]
    set -l original_conversation_id $_FORGE_CONVERSATION_ID
    _forge_log info "Cloning conversation \033[1m$clone_target\033[0m"
    set -l clone_output ($_FORGE_BIN conversation clone $clone_target 2>&1 | string collect)
    if test $status -eq 0
        set -l new_id (printf '%s\n' $clone_output | grep -oE '[a-f0-9-]{36}' | tail -1)
        if test -n "$new_id"
            _forge_switch_conversation $new_id
            _forge_log success "└─ Switched to conversation \033[1m$new_id\033[0m"
            if test "$clone_target" != "$original_conversation_id"
                echo
                _forge_exec conversation show $new_id
                echo
                _forge_exec conversation info $new_id
            end
        else
            _forge_log error "Failed to extract new conversation ID from clone output"
        end
    else
        _forge_log error "Failed to clone conversation: $clone_output"
    end
end

# Direct commit (clears buffer). Direct $_FORGE_BIN call (no --agent).
function _forge_action_commit
    set -l additional_context $argv[1]
    echo
    if test -n "$additional_context"
        env FORCE_COLOR=true CLICOLOR_FORCE=1 $_FORGE_BIN commit --max-diff $_FORGE_MAX_COMMIT_DIFF (string split ' ' -- $additional_context) >/dev/null
    else
        env FORCE_COLOR=true CLICOLOR_FORCE=1 $_FORGE_BIN commit --max-diff $_FORGE_MAX_COMMIT_DIFF >/dev/null
    end
    _forge_reset
end

# Early-return: rewrites the command line, keeps buffer, own OSC133.
function _forge_action_commit_preview
    set -l additional_context $argv[1]
    echo
    set -l commit_message
    if test -n "$additional_context"
        set commit_message (env FORCE_COLOR=true CLICOLOR_FORCE=1 $_FORGE_BIN commit --preview --max-diff $_FORGE_MAX_COMMIT_DIFF (string split ' ' -- $additional_context) | string collect)
    else
        set commit_message (env FORCE_COLOR=true CLICOLOR_FORCE=1 $_FORGE_BIN commit --preview --max-diff $_FORGE_MAX_COMMIT_DIFF | string collect)
    end
    if test -n "$commit_message"
        if git diff --staged --quiet 2>/dev/null
            commandline -r "git commit -am "(string escape -- $commit_message)
        else
            commandline -r "git commit -m "(string escape -- $commit_message)
        end
        commandline -f repaint
    else
        _forge_reset
    end
end

# Early-return: opens editor, seeds buffer with ": <content>".
function _forge_action_editor
    set -l initial_text $argv[1]
    echo
    set -l editor_cmd (set -q FORGE_EDITOR; and echo $FORGE_EDITOR; or begin; set -q EDITOR; and echo $EDITOR; or echo nano; end)
    set -l bin (string split ' ' -- $editor_cmd)[1]
    if not command -v $bin >/dev/null 2>&1
        _forge_log error "Editor not found: $editor_cmd (set FORGE_EDITOR or EDITOR)"
        return 1
    end
    set -l forge_dir .forge
    test -d $forge_dir; or mkdir -p $forge_dir
    set -l temp_file $forge_dir/FORGE_EDITMSG.md
    touch $temp_file
    test -n "$initial_text"; and echo $initial_text >$temp_file
    eval "$editor_cmd '$temp_file'" </dev/tty >/dev/tty 2>&1
    set -l content (cat $temp_file | tr -d '\r' | string collect)
    rm -f $temp_file
    if test -z "$content"
        _forge_log info "Editor closed with no content"
        commandline -r ''
        commandline -f repaint
        return 0
    end
    commandline -r ": $content"
    commandline -f repaint
end

# Early-return: generate shell command from NL, rewrites buffer.
function _forge_action_suggest
    set -l description $argv[1]
    if test -z "$description"
        _forge_log error "Please provide a command description"
        return 0
    end
    echo
    set -lx FORCE_COLOR true
    set -lx CLICOLOR_FORCE 1
    set -l generated_command (_forge_exec suggest $description | string collect)
    if test -n "$generated_command"
        commandline -r "$generated_command"
        commandline -f repaint
    else
        _forge_log error "Failed to generate command"
    end
end

# ---------------------------------------------------------------------------
# 5. Dispatcher (dispatcher.zsh) -- default handler + accept-line widget
# ---------------------------------------------------------------------------
function _forge_action_default
    set -l user_action $argv[1]
    set -l input_text $argv[2]
    set -l command_type ""
    if test -n "$user_action"
        set -l commands_list (_forge_get_commands)
        if test -n "$commands_list"
            set -l command_row (printf '%s\n' $commands_list | grep "^$user_action\b")
            if test -z "$command_row"
                echo
                _forge_log error "Command '\033[1m$user_action\033[0m' not found"
                return 0
            end
            set command_type (printf '%s\n' $command_row | awk '{print $2}' | string lower)
            if test "$command_type" = custom
                if test -z "$_FORGE_CONVERSATION_ID"
                    set -g _FORGE_CONVERSATION_ID ($_FORGE_BIN conversation new)
                end
                echo
                if test -n "$input_text"
                    _forge_exec cmd execute --cid $_FORGE_CONVERSATION_ID $user_action $input_text
                else
                    _forge_exec cmd execute --cid $_FORGE_CONVERSATION_ID $user_action
                end
                return 0
            end
        end
    end
    if test -z "$input_text"
        if test -n "$user_action"
            if test "$command_type" != agent
                echo
                _forge_log error "Command '\033[1m$user_action\033[0m' not found"
                return 0
            end
            echo
            set -g _FORGE_ACTIVE_AGENT $user_action
            _forge_log info "\033[1;37m"(string upper $_FORGE_ACTIVE_AGENT)"\033[0m \033[90mis now the active agent\033[0m"
        end
        return 0
    end
    if test -z "$_FORGE_CONVERSATION_ID"
        set -g _FORGE_CONVERSATION_ID ($_FORGE_BIN conversation new)
    end
    echo
    test -n "$user_action"; and set -g _FORGE_ACTIVE_AGENT $user_action
    _forge_exec_interactive -p $input_text --cid $_FORGE_CONVERSATION_ID
    _forge_start_background_sync
    _forge_start_background_update
end

function _forge_accept_line
    set -l buffer (commandline)
    set -l user_action ""
    set -l input_text ""
    if string match -rq '^:(?<m_act>[a-zA-Z][a-zA-Z0-9_-]*)(?<m_rest> (?<m_txt>.*))?$' -- $buffer
        set user_action $m_act
        if test -n "$m_rest"
            set input_text $m_txt
        else
            set input_text ""
        end
    else if string match -rq '^: (?<m_txt2>.*)$' -- $buffer
        set user_action ""
        set input_text $m_txt2
    else
        commandline -f execute
        return
    end

    # push raw typed line into history (best-effort)
    builtin history append -- $buffer 2>/dev/null

    # alias rewrite
    switch $user_action
        case ask
            set user_action sage
        case plan
            set user_action muse
    end

    _forge_osc133_emit B
    _forge_osc133_emit C

    switch $user_action
        case new n
            _forge_action_new $input_text
        case info i
            _forge_action_info
        case dump d
            _forge_action_dump $input_text
        case compact
            _forge_action_compact
        case retry r
            _forge_action_retry
        case help
            _forge_action_help
        case agent a
            _forge_action_agent $input_text
        case conversation c
            _forge_action_conversation $input_text
        case conversation-tree ct
            _forge_action_conversation_tree
        case config-model cm
            _forge_action_model $input_text
        case model m
            _forge_action_session_model $input_text
        case config-reload cr model-reset mr
            _forge_action_config_reload
        case reasoning-effort re
            _forge_action_reasoning_effort $input_text
        case config-reasoning-effort cre
            _forge_action_config_reasoning_effort $input_text
        case config-commit-model ccm
            _forge_action_commit_model $input_text
        case config-suggest-model csm
            _forge_action_suggest_model $input_text
        case tools t
            _forge_action_tools
        case config env e
            _forge_action_config
        case config-edit ce
            _forge_action_config_edit
        case skill
            _forge_action_skill
        case edit ed
            _forge_action_editor $input_text
            set -l st $status
            _forge_osc133_emit "D;$st"
            _forge_osc133_emit A
            return $st
        case commit
            _forge_action_commit $input_text
        case commit-preview
            _forge_action_commit_preview $input_text
            set -l st $status
            _forge_osc133_emit "D;$st"
            _forge_osc133_emit A
            return $st
        case suggest s
            _forge_action_suggest $input_text
            set -l st $status
            _forge_osc133_emit "D;$st"
            _forge_osc133_emit A
            return $st
        case clone
            _forge_action_clone $input_text
        case rename rn
            _forge_action_rename $input_text
        case conversation-rename
            _forge_action_conversation_rename $input_text
        case copy
            _forge_action_copy
        case workspace-sync sync
            _forge_action_sync
        case workspace-init sync-init
            _forge_action_sync_init
        case workspace-status sync-status
            _forge_action_sync_status
        case workspace-info sync-info
            _forge_action_sync_info
        case provider-login login provider
            _forge_action_login $input_text
        case logout
            _forge_action_logout $input_text
        case '*'
            _forge_action_default "$user_action" "$input_text"
    end

    set -l action_status $status
    _forge_osc133_emit "D;$action_status"
    _forge_osc133_emit A
    _forge_reset
    return $action_status
end

# ---------------------------------------------------------------------------
# 6. Terminal-context hooks (context.zsh) -- ring buffer + OSC on hook path.
#    Non-`:` commands travel this path (PATH-HOOK), disjoint from PATH-ZLE.
# ---------------------------------------------------------------------------
# Hooks are registered ONLY when _FORGE_TERM == true, mirroring zsh
# context.zsh:118-121 (where the precmd `D` is "unconditional" only because the
# hook itself is registered solely in that case). With capture off, the PATH-HOOK
# path emits nothing -- disjoint from PATH-ZLE (INV-PATH-DISJOINT).
if test "$_FORGE_TERM" = true
    function _forge_context_preexec --on-event fish_preexec
        set -g _FORGE_TERM_PENDING_CMD $argv[1]
        set -g _FORGE_TERM_PENDING_TS (date +%s)
        _forge_osc133_emit B
        _forge_osc133_emit C
    end

    function _forge_context_postexec --on-event fish_postexec
        set -l last_exit $status
        # D emitted unconditionally within the registered hook (context.zsh:88).
        _forge_osc133_emit "D;$last_exit"
        if test -n "$_FORGE_TERM_PENDING_CMD"
            set -a _FORGE_TERM_COMMANDS $_FORGE_TERM_PENDING_CMD
            set -a _FORGE_TERM_EXIT_CODES $last_exit
            set -a _FORGE_TERM_TIMESTAMPS $_FORGE_TERM_PENDING_TS
            while test (count $_FORGE_TERM_COMMANDS) -gt $_FORGE_TERM_MAX_COMMANDS
                set -e _FORGE_TERM_COMMANDS[1]
                set -e _FORGE_TERM_EXIT_CODES[1]
                set -e _FORGE_TERM_TIMESTAMPS[1]
            end
            set -g _FORGE_TERM_PENDING_CMD ""
            set -g _FORGE_TERM_PENDING_TS ""
        end
        _forge_osc133_emit A
    end
end

# ---------------------------------------------------------------------------
# 7. Bindings (bindings.zsh) -- Enter dispatches through the forge widget.
# ---------------------------------------------------------------------------
function _forge_apply_keybindings
    bind \r _forge_accept_line
    bind \n _forge_accept_line
end

# Re-apply if the key-binding mode changes (fish's clean variable hook,
# analogue of zvm_after_init_commands re-apply).
function _forge_rebind --on-variable fish_key_bindings
    _forge_apply_keybindings
end

_forge_apply_keybindings
