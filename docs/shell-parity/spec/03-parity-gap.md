# 03 — Parity-Gap Ledger: forge zsh line-editor plugin → bash + fish

Read-only comprehension. Scope: port the forge zsh ZLE plugin to **bash**
(readline `bind -x` + `READLINE_LINE`/`READLINE_POINT` + bash-preexec, **NO
ble.sh**) and **fish** (`commandline`, `bind`, `fish_preexec`/`fish_postexec`).

Target posture:
- **bash = REDUCED parity.** readline has no widget system, no widget
  re-entry, no prompt-repaint-mid-edit, no first-party syntax highlighting or
  autosuggestions. Multiple primitives collapse to "documented degradation".
- **fish = fuller parity.** `commandline -f` gives repaint/complete/builtin
  re-entry, `fish_right_prompt` is native, syntax highlight + autosuggest are
  built in.

Files audited: `shell-plugin/lib/bindings.zsh`, `.../completion.zsh`,
`.../helpers.zsh`, `.../highlight.zsh`, `shell-plugin/keyboard.zsh`,
`shell-plugin/forge.theme.zsh`, `crates/forge_main/src/zsh/{rprompt,paste,style}.rs`.

Parity classes: **FULL** = behaviourally equivalent; **REDUCED** = works but
with a named user-facing degradation; **N/A** = concept does not exist / not
needed on that shell.

---

## Ledger

| # | zsh primitive (file:line) | what it does | bash equivalent (readline `bind -x` + `READLINE_LINE`/`POINT` + bash-preexec, NO ble.sh) | fish equivalent (`commandline -f`/`--cursor`, `bind`, `fish_preexec`/`postexec`) | bash class | fish class | notes |
|---|---|---|---|---|---|---|---|
| 1 | `$BUFFER` (completion.zsh:19,38; bindings.zsh:21-24; helpers.zsh:148,152) | Read/write the whole edit buffer | `READLINE_LINE` (readable + writable inside `bind -x` function) | `commandline` (get) / `commandline -r <text>` (replace) | FULL | FULL | Direct analogue on both. |
| 2 | `$CURSOR` (completion.zsh:20,39; bindings.zsh:25; helpers.zsh:153) | Get/set cursor byte offset in buffer | `READLINE_POINT` (int, writable) | `commandline --cursor [N]` | FULL | FULL | bash POINT is a **byte** offset like `$CURSOR`; multi-byte UTF-8 needs care (paste.rs already fixed a byte-boundary crash). fish `--cursor` is char-based → recompute offsets. |
| 3 | `$LBUFFER` (completion.zsh:6,18,19,20,28,30) | Buffer text left of cursor | `${READLINE_LINE:0:READLINE_POINT}` (compute) | `commandline --cut-at-cursor --current-buffer` (text before cursor) | FULL | FULL | Derived value; assignment to LBUFFER (line 18) becomes: rebuild `READLINE_LINE` + set `READLINE_POINT`. |
| 4 | `$RBUFFER` (completion.zsh:19) | Buffer text right of cursor | `${READLINE_LINE:READLINE_POINT}` (compute) | `commandline --cut-at-cursor` inverse (compute) | FULL | FULL | Same derive-and-recombine pattern. |
| 5 | `zle -N forge-accept-line` / `forge-completion` (bindings.zsh:6-7) | Register a named user widget | No named widgets — define a shell fn, bind directly: `bind -x '"\C-x\C-a": _forge_accept'` | Define a fish `function`, bind to a key: `bind \cx _forge_completion` | REDUCED | FULL | bash: no widget namespace/registry; the fn *is* the widget, invoked only via a keyseq. Degradation: cannot be re-invoked programmatically the way `zle widget-name` allows. |
| 6 | `bindkey '^M'/'^J'/'^I' <widget>` (bindings.zsh:42-44) | Bind Enter/C-J/Tab to widgets | `bind -x '"\C-m": _forge_accept'`, `'"\C-j":…'`, `'"\C-i": _forge_complete'` | `bind \r _forge_accept; bind \n …; bind \t _forge_completion` | REDUCED | FULL | bash caveat: rebinding `\C-m`/`\C-i` with `bind -x` **loses readline's native accept-line/complete unless you re-emit it** (`bind -x` can't chain to the builtin cleanly) — see rows 11 & 13. fish `bind` composes with `commandline -f execute`/`complete`. |
| 7 | `zle .$WIDGET "$@"` — builtin widget re-entry (bindings.zsh:16) | Call the *original* `bracketed-paste` widget from inside the override, then post-process | **No equivalent.** readline cannot call its builtin bracketed-paste from a `bind -x` fn. Must reimplement paste capture by hand (read the bracketed sequence off stdin until `ESC[201~`). | `commandline -f self-insert` / read paste via `bind` on paste + `commandline`; fish exposes builtin editor funcs to re-enter | REDUCED | REDUCED | **Hardest bash gap.** No widget re-entry at all. Degradation: forge must own the entire paste-capture loop; risk of diverging from terminal's own bracketed-paste semantics. fish is close but paste interception is also non-trivial. |
| 8 | `zle reset-prompt` (bindings.zsh:35; completion.zsh:23,42; helpers.zsh:156) | Recompute + repaint the prompt in place (used to refresh RPROMPT/highlight after edit) | **No clean equivalent.** readline has no "repaint prompt now" from a bound fn; hacks (`\e[…`, `RETURN`, redraw-current-line) are partial and flicker. | `commandline -f repaint` (native, clean) | REDUCED | FULL | **Second-hardest bash gap.** Degradation: RPROMPT/token-count won't refresh until the next Enter; paste/highlight refresh visibly lags or is dropped. fish repaints cleanly. |
| 9 | `zle redisplay` (bindings.zsh:31) | Force buffer redraw (critical for large/multiline paste visibility) | Reassigning `READLINE_LINE` triggers a redisplay implicitly; no explicit force. Large multiline paste may render partially. | `commandline -f repaint` | REDUCED | FULL | Degradation: multiline-paste rendering not guaranteed; may need manual `\r`/`tput` nudge. |
| 10 | `zle -I` — invalidate display (helpers.zsh:155) | Mark display stale so output printed under the prompt is cleared on next redraw | **No equivalent.** readline offers no display-invalidate hook. | `commandline -f repaint` covers the intent | REDUCED | FULL | Used by `_forge_reset` after printing padding lines (helpers.zsh:139-157). bash: the whole padding-line clearing trick (row 24) has no backing primitive. |
| 11 | `zle -N bracketed-paste forge-bracketed-paste` (bindings.zsh:41) | Replace the bracketed-paste widget with a wrapper that path-wraps `@[...]` | Bind the paste sequence: `bind '"\e[200~": …'` is builtin; to wrap you must `bind -x` a fn that consumes stdin to `\e[201~`, then call `forge zsh format` (paste.rs) | `bind` on paste + a fish fn calling `forge zsh format`; fish has structured paste handling | REDUCED | REDUCED | Ties to rows 7 & 8. paste.rs `wrap_pasted_text` is shell-agnostic and reusable verbatim; the *interception* is the gap, not the wrapping. |
| 12 | `zle expand-or-complete` — fallback to default completion (completion.zsh:47) | When not a `:`/`@` context, defer to normal shell completion | **No clean fallthrough.** A `bind -x` fn on Tab cannot hand control back to readline's `complete`. Workaround: detect non-forge context early and *don't* bind, or re-run `compgen`. | `commandline -f complete` (re-enters builtin completion) | REDUCED | FULL | Degradation: bash forge-completion on Tab must either fully own completion or conditionally unbind; can't transparently chain to default. |
| 13 | `zle -N` widget + `bindkey` accept-line override (bindings.zsh:6,42-43) — `forge-accept-line` | Custom Enter handler (submit forge line vs shell) | `bind -x` on `\C-m` that inspects `READLINE_LINE`; to submit you emit the line yourself (can't call builtin accept-line, so simulate via `bind '"\C-m": accept-line'` conditionally is impossible from within `-x`) | fish: fn on `\r` + `commandline -f execute` to submit | REDUCED | FULL | Degradation: bash must reimplement "accept this line" behaviour; edge cases (history, multiline continuation) may differ from native accept-line. |
| 14 | `RPROMPT='$(_forge_prompt_info)'` + `setopt PROMPT_SUBST` (forge.theme.zsh:4,27) | Native right-aligned prompt, re-evaluated each render, showing agent/model/tokens/cost/effort | **No native right prompt.** Emulate: in `PROMPT_COMMAND` compute width, `printf` the text right-aligned with `tput cuf`/save-restore cursor, or append to PS1. Fragile with resize + multiline. | `function fish_right_prompt` — native, first-class | REDUCED | FULL | Degradation: bash right-prompt is a hand-rolled cursor-math emulation; misaligns on resize/wrap. rprompt.rs output must be re-emitted in ANSI (not `%F{}`) for bash — see row 20. |
| 15 | `PROMPT_SUBST` re-eval of `$(...)` in prompt (forge.theme.zsh:4) | Prompt command substitution runs every render | `PROMPT_COMMAND` regenerates PS1 each prompt (equivalent mechanism) | fish prompt is a function, always re-run — inherently dynamic | FULL | FULL | Mechanism differs but intent (dynamic prompt each render) is fully achievable on both. |
| 16 | precmd hook — implicit via RPROMPT `$(...)` + background sync/update (forge.theme.zsh:27; helpers.zsh:206-242) | Run code before each prompt (rprompt refresh, background sync/update jobs) | bash-preexec `precmd_functions` / `PROMPT_COMMAND` | fish `fish_prompt` fn + `--on-event fish_prompt` | FULL | FULL | bash-preexec explicitly requested; provides `precmd`. Background `&!` disown jobs (helpers.zsh:228,241) → bash `… &` + `disown`; fish `… &; disown`. |
| 17 | preexec hook (not directly in these files; implied by `_FORGE_TERM_*` ring buffers, helpers.zsh:27-36,64-70) | Capture executed commands/exit codes/timestamps for terminal context | bash-preexec `preexec_functions` (that's its whole purpose) | fish `fish_preexec` / `fish_postexec` events | FULL | FULL | The `_FORGE_TERM_COMMANDS/_EXIT_CODES/_TIMESTAMPS` ring buffers are populated by a preexec-style hook; both shells have first-class support. |
| 18 | `bindkey -lL main` keymap detection (keyboard.zsh:62) | Detect whether vi or emacs keymap is active | `bind -v` / `set -o` / `$SHELLOPTS` contains `vi` | `fish_key_bindings` variable (`fish_default_key_bindings` vs `fish_vi_key_bindings`) | FULL | FULL | Informational only (help screen). Straightforward on both. |
| 19 | `zvm_after_init_commands += _forge_apply_keybindings` (bindings.zsh:50-51) | Re-apply bindings after zsh-vi-mode plugin rebuilds keymaps | Re-apply after `set -o vi`; no plugin clobber problem of this exact kind, but re-bind in `PROMPT_COMMAND` if a mode toggles | fish: `bind` re-applied via `--on-variable fish_key_bindings` handler | REDUCED | FULL | bash: no direct zsh-vi-mode analogue; degradation is different-not-worse (fewer third-party keymap rebuilders). fish has a clean variable-change hook. |
| 20 | zsh prompt escapes `%F{N}`/`%B`/`%b`/`%f` (style.rs:70-93; rprompt.rs Display) | Emit **zsh-native** prompt color/bold escapes for RPROMPT | Reimplement `ZshStyled` as an ANSI emitter wrapped in `\[…\]` (readline non-printing markers) so width math stays correct | Reimplement as fish `set_color`/`set_color --bold` … `set_color normal` | REDUCED | REDUCED | Not a ZLE gap but a **rendering-layer port**: rprompt.rs/style.rs hardcode `%F{}`/`%B` which neither bash nor fish understand. Needs a shell-tagged style backend (e.g. `--shell bash|fish`). Colors like `%F{240}` map to ANSI 256 / `set_color brblack`. |
| 21 | `$BUFFERLINES` (helpers.zsh:148) | Number of display lines the buffer occupies (for padding math in `_forge_reset`) | **No equivalent.** readline exposes no wrapped-line count; must estimate from `${#READLINE_LINE}`, `$COLUMNS`, and embedded newlines. | No direct var; `commandline` + width math to estimate | REDUCED | REDUCED | Feeds row 10/24 padding logic; without it the multiline-clear trick is approximate on both. |
| 22 | `%F{}`-based active/dim state logic (rprompt.rs:99-190) | Choose bright vs dimmed styling by token count; width-adaptive effort label | Pure Rust logic — shell-agnostic; only the *emitted escapes* differ (row 20) | Same | FULL | FULL | The decision logic ports verbatim; only the `ZshColor`→escape backend swaps. `terminal_width` already threads `$COLUMNS` (forge.theme.zsh:21). |
| 23 | `forge zsh format --buffer` paste path-wrap (bindings.zsh:22; paste.rs) | Wrap dropped file paths in `@[...]`; core logic in Rust `wrap_pasted_text` | Reuse Rust `wrap_pasted_text` unchanged; call `forge <shell> format` from the bash paste fn | Same, from fish paste fn | FULL | FULL | paste.rs is already shell-neutral (CRLF-normalise, quote/backslash strip, UTF-8-safe `.get()`); only the CLI subcommand name/entry differs. Rename `zsh format` → shell-agnostic subcommand. |
| 24 | `_forge_reset` padding-print + `zle -I` + `reset-prompt` (helpers.zsh:139-157) | Print blank pad lines = buffer line count, clear buffer, invalidate, repaint so conversation output isn't eaten | bash: print pad lines with `printf`, clear `READLINE_LINE`/`READLINE_POINT`, but **no invalidate/repaint** → residual artifacts likely | fish: `commandline -r ''; commandline --cursor 0; commandline -f repaint` | REDUCED | FULL | Composite of rows 8,10,21. bash degradation: buffer clears but stale prompt/output lines may linger until next keypress. |
| 25 | `/dev/tty` redirect for child interactive pickers (helpers.zsh:77,84,88) | Give forge child (rustyline/nucleo picker) a real tty since ZLE owns stdin/stdout | Same `</dev/tty >/dev/tty` works — but bash bound fns don't hijack stdio the way ZLE does, so it may even be simpler | Same `</dev/tty >/dev/tty` in fish | FULL | FULL | POSIX tty redirection is shell-agnostic. Note: the *reason* (ZLE owns the tty) is zsh-specific; bash/fish bound fns may not need it, but it's harmless and portable. |
| 26 | `ZSH_HIGHLIGHT_PATTERNS` + `ZSH_HIGHLIGHT_HIGHLIGHTERS` (highlight.zsh:8-16) | First-party syntax highlighting: `@[...]` cyan, `:command` yellow, args white — live as you type | **No first-party equivalent** (readline cannot color the input line; ble.sh is explicitly excluded) | fish has native live syntax highlighting via `fish_color_*`, but it colors *fish syntax*, not arbitrary `:cmd`/`@[]` patterns — custom token coloring needs a fish highlighter shim and is only partial | REDUCED | REDUCED | **Hard gap on both.** bash: no live line coloring at all → forge `:`/`@[]` input is monochrome. fish: can approximate but not the exact pattern rules; degradation = highlight not identical. |
| 27 | (implicit) zsh autosuggestions / highlight ecosystem hooks | Ghost-text autosuggest + highlight plugins forge coexists with | **No first-party autosuggestions** (needs ble.sh/plugin, excluded) → none | fish native autosuggestions (built in, first-party) | REDUCED | FULL | bash degradation: no ghost-text history/path suggestions while typing forge lines. fish gets it free. |

---

## Tally

- **FULL rows:** 12 → (bash) rows 1,2,3,4,15,16,17,18,22,23,25 = 11 bash-FULL; fish-FULL is higher. Counting the **bash target column** (the constraining one):
  - **bash FULL:** 11 (rows 1,2,3,4,15,16,17,18,22,23,25)
  - **bash REDUCED:** 16 (rows 5,6,7,8,9,10,11,12,13,14,19,20,21,24,26,27)
  - **bash N/A:** 0
  - **fish FULL:** 20; **fish REDUCED:** 7 (rows 7,11,20,21,26 + partials); **fish N/A:** 0
- **Total distinct primitives/rows: 27.**

Headline: bash lands **11 FULL / 16 REDUCED / 0 N/A**; fish lands **~20 FULL /
~7 REDUCED / 0 N/A**. Confirms brief: bash = REDUCED parity, fish = fuller.

## Top 5 hardest-to-port primitives (bash-constrained)

1. **`zle .$WIDGET` builtin widget re-entry** (bindings.zsh:16) — readline has
   no widget system and cannot call its own bracketed-paste; forge must own the
   entire paste-capture loop.
2. **`zle reset-prompt`** (bindings.zsh:35, completion.zsh:23/42,
   helpers.zsh:156) — no clean mid-edit prompt repaint in bash; RPROMPT/token
   count won't refresh until Enter.
3. **`ZSH_HIGHLIGHT_PATTERNS` live syntax highlighting** (highlight.zsh:8-16) —
   no first-party line coloring in bash without ble.sh; `:`/`@[]` input stays
   monochrome.
4. **`RPROMPT` native right prompt** (forge.theme.zsh:27) — bash has no right
   prompt; only a fragile cursor-math emulation that misaligns on resize.
5. **`zle -N bracketed-paste` override + `expand-or-complete` fallthrough**
   (bindings.zsh:41, completion.zsh:47) — bash `bind -x` cannot wrap the paste
   widget nor hand Tab back to default completion; both must be fully
   reimplemented.

(Honourable mention: the `%F{N}`/`%B` style backend in style.rs/rprompt.rs is
zsh-only and must gain a shell-tagged ANSI/`set_color` emitter — a rendering
port, not a ZLE gap.)

---

Full file: `/Users/milan.santosi/tmp/forge-shell-spec/03-parity-gap.md`
