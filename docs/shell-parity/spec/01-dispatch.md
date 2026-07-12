# forge-zsh — COMMAND / DISPATCH SEMANTIC CONTRACT

Source root: `/Users/milan.santosi/mysrc/forgecode/shell-plugin/lib/`
Scope of this doc: `dispatcher.zsh`, `config.zsh`, `actions/*.zsh`, plus the
shared helpers in `helpers.zsh` that every action shells out through.
Purpose: normative spec that bash + fish ports must reproduce.

Legend: `$FB` = `$_FORGE_BIN` (the `forge` binary, `config.zsh:6`).
All `$FB` invocations that go through `_forge_exec` / `_forge_exec_interactive`
are prefixed with `--agent <agent_id>` (default `forge`); calls that go through
`_forge_select*` or call `$FB`/`$_FORGE_BIN` **directly** do NOT get `--agent`.

---

## 0. Entry point & buffer parse

Widget: `forge-accept-line` (`dispatcher.zsh:90`). Bound in `bindings.zsh`
(registered as a ZLE widget; replaces Enter). It parses `$BUFFER` (the current
command line) BEFORE any subshell, in parent-shell context.

### 0.1 Line regex parse (`dispatcher.zsh:99-116`)

| Branch | zsh regex | Result |
|--------|-----------|--------|
| 1 | `^:([a-zA-Z][a-zA-Z0-9_-]*)( (.*))?$` (`:99`) | `user_action=$match[1]`; if `$match[2]` non-empty → `input_text=$match[3]` else `""` |
| 2 | `^: (.*)$` (`:108`) | `user_action=""`, `input_text=$match[1]` (the default/"send to agent" path) |
| else | — | `zle accept-line; return` — normal shell command, plugin does nothing (`:114`) |

Key semantics:
- Command token must START with an ASCII letter, then `[a-zA-Z0-9_-]*`.
  So `:?`, `:!`, `:1` do NOT match branch 1 — despite `editor.zsh:73`
  documenting `:? <description>` for suggest, `:?` is unreachable via this parser.
- `$match[2]` is the whole `" (.*)"` group (leading space included); it is the
  presence test that distinguishes `:foo` (no args) from `:foo ` / `:foo x`.
  `$match[3]` is the arg text without the leading space.
- `: ` (colon-space) with empty tail still needs the tail `(.*)` — `":"` alone
  matches branch 1 group... actually `":"` fails branch 1 (needs ≥1 letter) and
  branch 2 (needs `": "`), so a bare `:` falls through to `zle accept-line`.

### 0.2 Post-parse side effects (before dispatch)

1. `print -s -- "$original_buffer"` (`:119`) — push raw typed line into history.
2. `CURSOR=${#BUFFER}; zle redisplay` (`:121-122`).
3. Alias rewrite (`:125-132`): see §1.1.
4. Emit OSC 133 `B` then `C` (`:143-144`, `_forge_osc133_emit` lives in
   `context.zsh`) — prompt/command-output markers for Ghostty, because ZLE
   dispatch bypasses zsh `preexec`/`precmd`.
5. `case "$user_action"` dispatch (`:147-268`).
6. After dispatch (for the non-early-return commands): capture
   `action_status=$?`, emit OSC133 `D;$status` and `A` (`:270-272`), then
   `_forge_reset` (`:277`) to clear BUFFER and repaint the prompt.

### 0.3 Early-return commands (bypass the centralized tail)

`edit`/`ed`, `commit-preview`, `suggest`/`s` each `return $action_status`
from inside the case arm AFTER emitting their own `D;$status` + `A`
(`:208-234`). They intentionally leave `BUFFER` populated (they stage a command
for the user to run) and do NOT call `_forge_reset`. Port note: these three are
the only commands whose post-effect is "rewrite the command line", not "clear it".

---

## 1. Command / action table

### 1.1 Alias map

Two-stage aliasing.

Stage A — semantic aliases rewritten before dispatch (`dispatcher.zsh:125-132`):

| Typed | Rewritten `user_action` |
|-------|-------------------------|
| `ask` | `sage` |
| `plan` | `muse` |

`sage`/`muse` are not case arms → they fall to `*` → `_forge_action_default`,
i.e. they resolve as **agent names** (validated against `forge list commands`).

Stage B — short aliases handled as extra `case` labels (per-command, below).

### 1.2 Full dispatch table (`dispatcher.zsh:147-268`)

Columns: Command (+aliases) · Handler (`file:line`) · Input · Effect / `forge` subcommand shelled out.

| Command (aliases) | Handler | Input | forge subcommand(s) & effect |
|---|---|---|---|
| `new` `n` | `_forge_action_new` (core.zsh:6) | opt prompt | `_forge_clear_conversation`; agent←`forge`. If prompt: `$FB conversation new` → switch → `_forge_exec_interactive -p <txt> --cid <id>` → bg sync + bg update. Else `$FB banner`. |
| `info` `i` | `_forge_action_info` (core.zsh:35) | none | `forge info [--cid <id>]` (adds `--cid` only if convo set). |
| `dump` `d` | `_forge_action_dump` (core.zsh:45) | opt `html` | `_forge_handle_conversation_command dump [--html]` → `forge conversation dump <id> [--html]`. |
| `compact` | `_forge_action_compact` (core.zsh:55) | none | `forge conversation compact <id>`. |
| `retry` `r` | `_forge_action_retry` (core.zsh:60) | none | `forge conversation retry <id>`. |
| `help` | `_forge_action_help` (core.zsh:65) | none | `$FB list command` (direct, no `--agent`). |
| `agent` `a` | `_forge_action_agent` (config.zsh:6) | opt agent-id | With id: validate via `$FB list agents --porcelain` (`tail -n +2`, grep `^id\b`), set `_FORGE_ACTIVE_AGENT`. Without: `_forge_select_with_query "" agent` → `forge select agent`. |
| `conversation` `c` | `_forge_action_conversation` (conversation.zsh:47) | opt id / `-` | `-`→toggle prev (swap ids) then `forge conversation show/info <id>`. id→`_forge_switch_conversation`+show/info. none→`forge select conversation`→switch+show/info. |
| `conversation-tree` `ct` | `_forge_action_conversation_tree` (conversation.zsh:121) | none | `forge select conversation --parent <id>`. |
| `config-model` `cm` | `_forge_action_model` (config.zsh:43) | opt query | `_forge_select_model_pair_global` → `forge select model` (GLOBAL, session overrides NOT applied) → `forge config set model <provider> <model>`. |
| `model` `m` | `_forge_action_session_model` (config.zsh:116) | opt query | `_forge_select_model_pair` → `forge select model`; sets `_FORGE_SESSION_MODEL`+`_FORGE_SESSION_PROVIDER` (session only, no `config set`). |
| `config-reload` `cr` `model-reset` `mr` | `_forge_action_config_reload` (config.zsh:131) | none | No forge call. Clears the 3 session override vars. |
| `reasoning-effort` `re` | `_forge_action_reasoning_effort` (config.zsh:150) | opt query | `forge select reasoning-effort`; sets `_FORGE_SESSION_REASONING_EFFORT` (session only). |
| `config-reasoning-effort` `cre` | `_forge_action_config_reasoning_effort` (config.zsh:166) | opt query | `forge select reasoning-effort` → `forge config set reasoning-effort <e>`. |
| `config-commit-model` `ccm` | `_forge_action_commit_model` (config.zsh:57) | opt query | `_forge_select_model_pair`→`forge select model`→`forge config set commit <provider> <model>`. |
| `config-suggest-model` `csm` | `_forge_action_suggest_model` (config.zsh:71) | opt query | `_forge_select_model_pair`→`forge select model`→`forge config set suggest <provider> <model>`. |
| `tools` `t` | `_forge_action_tools` (config.zsh:237) | none | `forge list tools <agent_id>` (agent defaults `forge`). |
| `config` `env` `e` | `_forge_action_config` (config.zsh:179) | none | `forge config list`. |
| `config-edit` `ce` | `_forge_action_config_edit` (config.zsh:185) | none | `$FB config path` to resolve file; `mkdir -p`/`touch`; open `$FORGE_EDITOR`/`$EDITOR`/`nano` on `</dev/tty >/dev/tty`; `_forge_reset`. |
| `skill` | `_forge_action_skill` (config.zsh:245) | none | `forge list skill`. |
| `edit` `ed` | `_forge_action_editor` (editor.zsh:6) | opt seed | Opens editor on `.forge/FORGE_EDITMSG.md`; on save sets `BUFFER=": <content>"`. **Early return**, own OSC133. |
| `commit` | `_forge_action_commit` (git.zsh:8) | opt context | `FORCE_COLOR=true CLICOLOR_FORCE=1 $FB commit --max-diff <N> [context]` (direct); then `_forge_reset`. |
| `commit-preview` | `_forge_action_commit_preview` (git.zsh:29) | opt context | `$FB commit --preview --max-diff <N> [ctx]`; if output, sets `BUFFER=git commit [-a]m <msg>` (staged-aware). **Early return**. |
| `suggest` `s` | `_forge_action_suggest` (editor.zsh:74) | required desc | `_forge_exec suggest <desc>` → sets `BUFFER=<generated cmd>`. **Early return**. |
| `clone` | `_forge_action_clone` (conversation.zsh:126) | opt id | `forge conversation clone <target>`; extract UUID (`grep -oE '[a-f0-9-]{36}' \| tail -1`); switch + show/info. none→`forge select conversation` first. |
| `rename` `rn` | `_forge_action_rename` (conversation.zsh:188) | required name | `forge conversation rename <id> $name` (name passed UNQUOTED → word-split into args). |
| `conversation-rename` | `_forge_action_conversation_rename` (conversation.zsh:208) | opt `<id> <name>` | Split on first space; else `forge select conversation` + `read new_name </dev/tty`; `forge conversation rename <id> $name`. |
| `copy` | `_forge_action_copy` (conversation.zsh:149) | none | `$FB conversation show --md <id>` → pbcopy/xclip/xsel. |
| `workspace-sync` `sync` | `_forge_action_sync` (config.zsh:84) | none | `_forge_exec_interactive workspace sync --init`. |
| `workspace-init` `sync-init` | `_forge_action_sync_init` (config.zsh:94) | none | `_forge_exec_interactive workspace init`. |
| `workspace-status` `sync-status` | `_forge_action_sync_status` (config.zsh:101) | none | `forge workspace status "."`. |
| `workspace-info` `sync-info` | `_forge_action_sync_info` (config.zsh:107) | none | `forge workspace info "."`. |
| `provider-login` `login` `provider` | `_forge_action_login` (auth.zsh:6) | opt query | `_forge_select_with_query <q> provider`→`forge select provider [--query]`; `_forge_exec_interactive provider login <p>`. |
| `logout` | `_forge_action_logout` (auth.zsh:19) | opt query | `forge select provider --configured`; `forge provider logout <p>`. |
| *(default)* | `_forge_action_default` (dispatcher.zsh:10) | action + text | See §1.3. Custom command OR agent switch OR prompt send. |

### 1.3 Default handler `_forge_action_default` (dispatcher.zsh:10-88)

Precedence:
1. If `user_action` non-empty: fetch `_forge_get_commands` (cached
   `forge list commands --porcelain`), grep `^<action>\b`. Not found → error, return.
   Read TYPE column (`awk '{print $2}'`); lower via `${type:l}`.
2. TYPE==`custom` (`:31`): ensure convo (`$FB conversation new` if unset);
   `_forge_exec cmd execute --cid <id> <action> [input]`.
3. Empty `input_text` (`:52`): require TYPE==`agent` else error; set
   `_FORGE_ACTIVE_AGENT=<action>` (agent switch, no exec).
4. Non-empty input: ensure convo; if `user_action` given set it as active agent;
   `_forge_exec_interactive -p <input> --cid <id>`; then bg sync + bg update.

This is the path `: <text>` (branch 2, empty action → straight prompt send) and
alias-resolved `ask`/`plan` (→ agent `sage`/`muse`) land in.

### 1.4 Defined-but-UNWIRED

`_forge_action_session_provider` (provider.zsh:9) — sets `_FORGE_SESSION_PROVIDER`
via `forge select provider`. **No case arm dispatches to it** in `dispatcher.zsh`.
Dead/pending entry point; a port may omit or expose it (e.g. `:provider-session`).

---

## 2. Mutable global state variables

Declared in `config.zsh` with `typeset -h` (hidden). Lifetime = shell session.

| Var | Decl | Set at | Read at | Meaning |
|-----|------|--------|---------|---------|
| `_FORGE_BIN` | config.zsh:6 (`${FORGE_BIN:-forge}`) | init | everywhere | forge binary path. |
| `_FORGE_CONVERSATION_ID` | config.zsh:13 | dispatcher:34,36,71; core.zsh new via switch; conversation.zsh switch(:32)/clear(:43)/toggle(:62) | core info/dump/…, conversation.zsh, copy, rename, `_forge_exec*` cid args | active conversation UUID. Empty ⇒ auto-create on next prompt. |
| `_FORGE_ACTIVE_AGENT` | config.zsh:14 | dispatcher:61,78; core.zsh:10 (`new`→`forge`); config.zsh:23 (agent) | helpers `_forge_exec`:17, `_forge_exec_interactive`:53, tools:240 (default `forge`) | current agent; injected as `--agent`. |
| `_FORGE_PREVIOUS_CONVERSATION_ID` | config.zsh:17 | conversation.zsh switch(:28)/clear(:39)/toggle(:63) | conversation.zsh toggle(:55,61) | `cd -`-style previous convo. |
| `_FORGE_SESSION_MODEL` | config.zsh:22 | config.zsh session_model:121; cleared reload:139 | helpers:40,74,81 → exports `FORGE_SESSION__MODEL_ID` | per-session model override. |
| `_FORGE_SESSION_PROVIDER` | config.zsh:23 | config.zsh:122; provider.zsh:17; cleared:140 | helpers:41,75,82 → `FORGE_SESSION__PROVIDER_ID` | per-session provider override. |
| `_FORGE_SESSION_REASONING_EFFORT` | config.zsh:27 | config.zsh:158; cleared:141 | helpers:42,76,83 → `FORGE_REASONING__EFFORT` | per-session reasoning effort. |
| `_FORGE_COMMANDS` | config.zsh:10 | helpers.zsh:9 (lazy `forge list commands --porcelain`) | `_forge_get_commands`, default handler | command-list cache. |
| `_FORGE_TERM` | config.zsh:31 (`${FORGE_TERM:-true}`) | init | helpers:27,64; context.zsh hooks | master switch for terminal-context capture. |
| `_FORGE_TERM_MAX_COMMANDS` | config.zsh:33 | init | context.zsh ring trim | ring size. |
| `_FORGE_TERM_OSC133` | config.zsh:35 (`auto`) | init | context.zsh OSC emit | `auto`/`on`/`off`. |
| `_FORGE_TERM_COMMANDS[]` / `_EXIT_CODES[]` / `_TIMESTAMPS[]` | config.zsh:37-39 (`-ha`) | context.zsh preexec/precmd | helpers:27-37,64-71 (joined `\x1F`, exported same-named) | command ring buffer sent to forge. |

Session-override injection (helpers.zsh:40-42, 74-76, 81-83): each session var,
when non-empty, is `local -x`-exported under its `FORGE_*` name for the child
`forge` process only. `_forge_select` (:80) applies them; `_forge_select_global`
(:87) and `_forge_select_model_pair_global` deliberately do NOT (used by
`config-model`/`cm` to pick against the true global config).

---

## 3. Background jobs fired mid-dispatch

Both are launched detached with zsh `&!` (fork + immediate disown) inside a
`{ … }` block that does `exec >/dev/null 2>&1 </dev/null` and
`setopt NO_NOTIFY NO_MONITOR` so nothing flashes to the terminal.

| Job | Def | Fired from | Effect |
|-----|-----|-----------|--------|
| `_forge_start_background_sync` | helpers.zsh:206 | default handler (dispatcher:85); `new` w/ prompt (core.zsh:24) | If `FORGE_SYNC_ENABLED!=false` and `_forge_is_workspace_indexed $(pwd -P)` (`$FB workspace info`), runs `$FB workspace sync <path>` in background. No-op if unindexed. |
| `_forge_start_background_update` | helpers.zsh:233 | default handler (dispatcher:87); `new` w/ prompt (core.zsh:27) | Runs `$FB update --no-confirm` detached (silent self-update). |

Trigger sites = exactly the two "a real prompt was sent to the agent" paths.
Not fired by pure state commands (agent switch, config, conversation nav).

---

## 4. Shell-idiom-specific control flow (port divergences)

| zsh idiom | Where | bash equivalent | fish equivalent |
|-----------|-------|-----------------|-----------------|
| `[[ $BUFFER =~ RE ]]` + `$match[1..3]` | dispatcher:99-111 | `[[ $line =~ RE ]]` + `${BASH_REMATCH[1..3]}` — NB indices: zsh `$match[N]` == bash `${BASH_REMATCH[N]}`, but bash groups shift if RE differs; the optional `( (.*))?` group makes `$match[2]` the presence flag and `$match[3]` the payload — replicate the two-group structure. | `string match -rq '(...)' -- $line` then `$string_match` capture vars, or manual `string sub`. |
| `$BUFFER` / `$LBUFFER` / `$RBUFFER` / `$CURSOR` / `$BUFFERLINES` | throughout, esp. reset (helpers:139-157), editor/commit/suggest | readline: `$READLINE_LINE` / `$READLINE_POINT` (no L/R split; compute manually) | `commandline`, `commandline -C` (cursor), `commandline -t` (token). |
| `zle accept-line` / `redisplay` / `reset-prompt` / `-I` / `-R` | dispatcher, helpers `_forge_reset`, editor, git, suggest | `bind -x` widget; re-exec via `READLINE_LINE=…` + return; no true reset-prompt | `bind` + `commandline -f repaint` / `commandline -r`. |
| `print -s -- "$buf"` (append history) | dispatcher:119 | `history -s "$buf"` | `builtin history append` / `commandline` re-entry. |
| `${var:l}` / `${var:u}` (lower/upper) | default:31,54; dispatcher:62 (`:u`) | `${var,,}` / `${var^^}` | `string lower` / `string upper`. |
| `${(qq)msg}` (quote for eval) | git.zsh:50,53 | `printf -v q '%q' "$msg"` | `string escape`. |
| `${(@f)result}` (split on \n → array) | helpers:122,135 | `mapfile -t arr <<<"$result"` | `string split \n`. |
| `reply=(...)` array-return convention | helpers model-pair; config.zsh model actions read `${reply[1..2]}` | nameref / echo two lines & read | function output + `read`. |
| `&!` (bg + disown) | helpers:228,241 | `( cmd & disown )` or `nohup cmd &` | `cmd &; disown` (fish `&` backgrounds; `disown`). |
| `setopt NO_NOTIFY NO_MONITOR` | helpers:222,239 | `set +m` | `status job-control none` (subshell) — fish differs. |
| `local -x VAR=…` (scoped export to child) | helpers:40-42,74-76,81-83 | `VAR=… cmd` prefix or `export`+subshell | `VAR=… cmd` inline (fish `env`/inline). |
| `typeset -h` / `typeset -ha` | config.zsh | `declare` / `declare -a` (no hide flag) | `set -g` / `set -g` list. |
| `read -r new_name </dev/tty` | conversation.zsh:235 | same | `read` from `/dev/tty`. |
| `$input_text` passed UNQUOTED to split args | rename:203, conv-rename:224 | must replicate word-split deliberately (`$name` unquoted under `IFS`) | fish auto-splits differently — use explicit tokens. |
| `_forge_reset` padding via `$BUFFERLINES` + `zle -I` | helpers:139-157 | no equivalent; needs manual line accounting | `commandline -f repaint`. |
| OSC133 emit (`_forge_osc133_emit B/C/D;n/A`) | dispatcher:143-144,211-272; context.zsh | plain `printf '\e]133;…\a'` — portable, keep verbatim | same `printf`. |

Notes for porters:
- The whole widget runs in the interactive line editor's context; the parse must
  stay in the parent shell (no subshell) so `$_FORGE_*` state mutations persist.
- Three commands (`edit`, `commit-preview`, `suggest`) REWRITE the command line
  and must NOT clear it; all others clear via `_forge_reset`.
- `_forge_exec` always injects `--agent`; `_forge_select*` never do. Preserve
  this split or model/agent resolution changes.
- Session overrides are env-var injection to the child, never persisted config;
  `cm`/`config-model` bypass them on purpose.
