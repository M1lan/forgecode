# forge shell-plugin — behavioral model + semantic-parity definition (P0 synthesis)

Synthesizes `01-dispatch.md` (command surface), `02-lifecycle.md` (session/OSC-133/ring/abort),
`03-parity-gap.md` (line-editor ledger), `04-rust-integration.md` (Rust surface).
Purpose: the contract `forge-bash` + `forge-fish` are built + verified against. zsh stays untouched.

## 1. Semantic-parity definition (what "same as forge-zsh" MEANS)

A shell plugin is **at parity** iff, for every capability in §3, given identical user input it produces
the identical **observable outcome**, where "observable" = one of three tiers:

- **T1 Command semantics (MUST, byte-identical):** the `forge` subprocess invoked, its argv, injected
  env (`_FORGE_SESSION_*`), cwd, and the resulting session-state mutation. Shell-agnostic — lives in
  the dispatch layer. 100% parity required for all shells. This is the bulk of the value.
- **T2 Terminal protocol (MUST where the shell can, per ledger):** OSC-133 marker sequence + pairing,
  bracketed-paste handling, prompt/rprompt content. Verified on the pyte screen-grid, differential vs zsh.
- **T3 Line-editor UX (SHOULD, best-effort per shell):** mid-edit repaint, live highlight, widget
  re-entry, cursor math. bash REDUCED (16 primitives, no ble.sh); fish fuller. Each gap is a **ledgered,
  documented** degradation, not a silent miss.

"Full behavioral parity" = **T1 100% + T2 100%-where-capable + T3 to the per-shell ledger ceiling.**
Byte-identical *interactive rendering* is explicitly NOT the target (unreachable for bash; advisor consensus).

## 2. The core state machine (shell-agnostic — the reimplementation target)

`forge-accept-line` (dispatcher.zsh:90-279): parse `$BUFFER` → 2 regexes (`:cmd [args]`, `: <text>`) →
alias resolve (`ask→sage`, `plan→muse`) → ~40-way `case` → per-branch OSC-133 emit → subprocess → reset.
Mutable state (all per-tty, `typeset -h`): `_FORGE_CONVERSATION_ID`, `_FORGE_ACTIVE_AGENT`,
`_FORGE_PREVIOUS_CONVERSATION_ID`, `_FORGE_SESSION_{MODEL,PROVIDER,REASONING_EFFORT}`,
ring buffers `_FORGE_TERM_{COMMANDS,EXIT_CODES,TIMESTAMPS}`. Two `&!`-detached bg jobs (sync, self-update)
fire only on real prompt-send. `edit`/`commit-preview`/`suggest` early-return + rewrite the line; rest reset.

## 3. Capability inventory (each = oracle test cases)

~40 commands shelling to `forge`: conversation new/show/info/dump/compact/retry/rename/clone;
config set|list|path; select agent|model|conversation|provider|reasoning-effort;
list agents|tools|skill|command(s); commit; suggest; workspace sync|init|status|info;
provider login|logout; info; banner; cmd execute. Plus short aliases (n,i,d,c,ct,cm,m,cr/mr,re,cre,ccm,csm,t,e,ce,ed,s,rn).
Default `: <text>` → agent send. Non-`:` input → normal shell accept-line.
Dead code noted: `_forge_action_session_provider` (provider.zsh:9) unwired — do NOT port, flag.

## 4. Narrow TLA+ scope (P1 — model these, freeze)

From `02-lifecycle.md`, the checkable invariants (session + OSC-133 only, NO rendering):
- **INV-TTY-PIN** (PRIMARY — the documented C-c C-c bug): root cause is binary-side `LAST_ACTIVE`
  (shared across ttys), not the per-tty shell globals. Empty/unpinned cid on resend → resolves to another
  window's cid → restores its cwd. Model the tty↔cid↔cwd binding + resend path.
- **INV-CID-NONEMPTY-AT-EXECUTE**, **INV-CWD-FOLLOWS-CID**.
- **INV-PAIRED** / **INV-NO-DOUBLE-D** / **INV-PATH-DISJOINT** (OSC-133 A/B/C/D across hook vs ZLE paths).
- **INV-ABORT-PAIR** (reachable violation: SIGINT between `C` and `D` on ZLE path leaves unpaired `B;C`).
- Ring: **INV-EQUAL-LEN / INV-BOUNDED / INV-FIFO**.
TLC checks these over all interleavings. Value: catch the wrong-conversation class before 2 reimpls inherit it.

## 5. Parity-gap ledger summary (P3 targets)

27 line-editor primitives. bash: 11 FULL / 16 REDUCED / 0 N/A. fish: ~20 FULL / ~7 REDUCED.
Hardest bash gaps (T3, documented degradations): `zle .$WIDGET` re-entry, `zle reset-prompt` mid-edit repaint,
`ZSH_HIGHLIGHT_PATTERNS` live highlight, native `RPROMPT`, bracketed-paste wrap + `expand-or-complete` chain.
`paste.rs` = shell-neutral, reuse verbatim. `style.rs`/`rprompt.rs` = zsh `%F{}`/`%B` escapes → need a
shell-tagged ANSI/`set_color` backend (rendering port, not a ZLE gap).

## 6. Rust integration plan (P5)

Single `ShellCommandGroup` + `ShellKind{Zsh,Bash,Fish}` ValueEnum (NOT parallel groups). Core fns become
`generate_plugin(kind)`, `generate_theme(kind)`, `run_doctor(kind)`, `run_keyboard(kind)`,
`setup_integration(kind,..)`, per-shell rprompt renderer. One `include_dir!` const per shell (macro needs
literal paths). Targets: `~/.zshrc` / `~/.bashrc` / `~/.config/fish/config.fish` (fish needs `mkdir -p`).
`clap_complete::shells::{Bash,Fish,Zsh}` all already exist (no dep change). Back-compat: keep `forge zsh …`
+ `forge setup`/`doctor` aliases + `$SHELL` auto-detect. Justfile: add `test-bash`/`test-fish`. zsh-only
tests (OSC133/zvm, plugin.rs:416,442) NOT parameterized; the 5 setup_integration tests generalize.

## 7. Top risk + de-risk

Observability-gap overfitting: hardest ~20% is invisible redraw state a byte-diff can't see. De-risk =
pyte screen-grid differential vs untouched zsh + held-out trace set + per-capability gates (not one scalar).
