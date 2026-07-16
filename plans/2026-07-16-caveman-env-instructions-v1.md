# Plan: Enforce caveman compression across forge-zsh (and sibling shell plugins)

Date: 2026-07-16
Status: SUPERSEDED by `plans/2026-07-16-extra-instructions-env-hook-v1.md`

> Superseded 2026-07-16. Implementation moved to the successor plan (general
> `FORGE_EXTRA_INSTRUCTIONS_PATH` hook), which is the correct mechanism for the SAME goal.
>
> CORRECTION (do not trust the earlier review's "redundant" conclusion): a first review
> claimed §0a in `~/forge/AGENTS.md` already injects caveman on every launch, making this
> redundant. That was WRONG. `base_path` is overridden by the `FORGE_CONFIG` env var
> (`crates/forge_config/src/reader.rs:68-69`), and the operator's multi-account setup sets a
> per-slot `FORGE_CONFIG` (`~/.config/mein-zsh/snippets/forge-claude-accounts.zsh:103`).
> Under any such slot `global_agentsmd_path()` = `$FORGE_CONFIG/AGENTS.md`, NOT
> `~/forge/AGENTS.md`, so §0a is never loaded and caveman is inactive for forge-zsh `:`
> prompts (confirmed by direct operator observation). The env-var hook uses an ABSOLUTE
> path and is `base_path`-independent, so it fixes caveman in every slot — this feature is
> justified, not redundant. The only claim that survives from the review: this is text
> INJECTION, not mechanical enforcement of compression (RULE 0 wording).
Tracker: `br` epic `forgecode-8v8` (see `.beads/`)

## Objective

Today caveman-ultra compression is enforced only via prose in
`~/forge/AGENTS.md` §0a, which is auto-injected as custom instructions
(`crates/forge_services/src/instructions.rs:22-47` →
`crates/forge_app/src/system_prompt.rs:91-93,121`). This is content-level,
not mechanical (RULE 0 caveat), and has no connection to forge-zsh/bash/fish
plugin invocation specifically.

Add a mechanical env-var injection point: `ForgeCustomInstructionsService`
reads `FORGE_EXTRA_INSTRUCTIONS` (inline text) or
`FORGE_EXTRA_INSTRUCTIONS_PATH` (file path) and appends it to
`custom_instructions`. Shell plugins (zsh/bash/fish) export this var,
derived from the existing `~/.claude/.caveman-active` marker file, on every
`forge` invocation they make.

## Non-goals

- Not touching the `~/.claude/.caveman-active` marker mechanism itself.
- Not modifying `~/forge/AGENTS.md` §0a content.
- Not adding new CLI flags or `.forge.toml` config keys (env var only, per
  the existing `FORGE_SESSION__MODEL_ID` pattern already used by these
  plugins).
- Not changing agent-level `custom_rules` (`crates/forge_repo/src/agent_definition.rs:64-66`).

## Design

### Rust: `crates/forge_services/src/instructions.rs`

In `init()` (`instructions.rs:68-80`), after collecting AGENTS.md contents,
append:

1. `FORGE_EXTRA_INSTRUCTIONS` env var value, if set and non-empty (inline
   text, appended verbatim as one more entry in `custom_instructions`).
2. Else `FORGE_EXTRA_INSTRUCTIONS_PATH` env var, if set: read the file via
   existing `FileReaderInfra::read_utf8`, append contents on success, log +
   skip silently on failure (missing file should not crash a session).

Both read via `EnvironmentInfra` (needs a `get_env_var`/equivalent — verify
exact trait method name in `forge_app::EnvironmentInfra` before impl;
`shell-plugin/lib/helpers.zsh:21-26` comment references
`TerminalContextService` reading env vars the same way, confirming the
infra supports this pattern).

Order: AGENTS.md files first (existing order preserved), then the env-var
addition last, so it renders after existing rules in `custom_rules` join
(`system_prompt.rs:121`).

### Shell plugins: zsh / bash / fish

Export `FORGE_EXTRA_INSTRUCTIONS_PATH` (prefer path over inline to avoid
quoting/escaping issues across 3 shells) pointing at
`~/forge/skills/caveman/SKILL.md`, gated on
`~/.claude/.caveman-active` existing and being non-empty. Exported only for
the child forge process (`local -x` in zsh, matching existing pattern at
`shell-plugin/lib/helpers.zsh:40-42,74-76`), never leaked to the parent
shell.

Touch points (mirror the existing `_FORGE_SESSION_MODEL` export pattern in
each):

- `shell-plugin/lib/helpers.zsh` — `_forge_exec` (:40-42) and
  `_forge_exec_interactive` (:74-76), and `_forge_select`/`_forge_select_global`
  if those also spawn a full session context (verify at implementation time).
- `shell-plugin/bash/forge.plugin.bash` — equivalent exec helper(s).
- `shell-plugin/fish/forge.plugin.fish` — equivalent exec helper(s).

### Test

Add a unit/insta test in `instructions.rs` (or existing test module)
covering: env var set → appears in `custom_instructions`; env var unset →
unchanged behavior; path var pointing at missing file → no crash, no
addition.

## Tasks

- [ ] Confirm exact `EnvironmentInfra` method for reading arbitrary env vars
      (grep `get_env_var` usage in `crates/forge_domain` /
      `crates/forge_services`; confirm signature)
- [ ] Implement `FORGE_EXTRA_INSTRUCTIONS` / `FORGE_EXTRA_INSTRUCTIONS_PATH`
      handling in `crates/forge_services/src/instructions.rs`
- [ ] Add test(s) for the new instructions-service env-var behavior
- [ ] Export env var in `shell-plugin/lib/helpers.zsh` exec helpers
- [ ] Export equivalent env var in `shell-plugin/bash/forge.plugin.bash`
- [ ] Export equivalent env var in `shell-plugin/fish/forge.plugin.fish`
- [ ] Run `cargo insta test --accept` and `cargo check` across touched
      crates
- [ ] Manual smoke test: launch forge-zsh with marker file present, confirm
      caveman-compressed system prompt is active in a live session

## Verification criteria

- `cargo insta test --accept` green for `forge_services` (and any other
  touched crate)
- `cargo check` clean workspace-wide
- Manual: `~/.claude/.caveman-active` = `ultra`, launch forge via zsh
  plugin, confirm system prompt includes injected instructions (inspect via
  `:dump` or debug_requests) and replies are compressed
- Manual: marker file absent → no env var exported → no regression to
  current behavior (AGENTS.md-only enforcement still works)

## Risks

- `FORGE_EXTRA_INSTRUCTIONS_PATH` pointing at a large file could bloat every
  system prompt; mitigate by pointing only at the compact caveman ruleset,
  not the full AGENTS.md.
- Env var propagation only covers `forge` processes launched BY the shell
  plugins — does not cover `forge` invoked directly from a raw terminal
  without the plugin loaded. Out of scope per the task ("forge-zsh and
  other shell integrations").
- Divergence risk if `~/.claude/.caveman-active` format changes — plugin
  code must treat it as an opaque non-empty marker, not parse a specific
  value beyond presence, unless finer control (e.g. per-level file) is
  wanted later.
