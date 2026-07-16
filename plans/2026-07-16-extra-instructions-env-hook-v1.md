# Plan: `FORGE_EXTRA_INSTRUCTIONS_PATH` — generic env-var extra-instructions hook

Date: 2026-07-16
Status: draft (ready to implement)
Supersedes: `plans/2026-07-16-caveman-env-instructions-v1.md`
Review: 4-specialist pass (oh-my-claudecode architect / critic / security-reviewer / test-engineer)

## Objective

Add a general mechanism to inject **session-specific** extra instructions into the
forge system prompt via an environment variable, without editing any committed
`AGENTS.md`. Complements the existing file-based discovery (base / git-root / cwd
`AGENTS.md`) in `ForgeCustomInstructionsService`.

## Primary motivation: caveman is NOT active for forge-zsh (root cause)

`base_path` is overridden by the `FORGE_CONFIG` env var (`reader.rs:68-69`). The
operator's multi-account setup sets a per-slot `FORGE_CONFIG`
(`~/.config/mein-zsh/snippets/forge-claude-accounts.zsh:103`). Under any such slot,
`global_agentsmd_path()` = `$FORGE_CONFIG/AGENTS.md`, NOT `~/forge/AGENTS.md`
(`env.rs:150-152`), so the §0a caveman ruleset in `~/forge/AGENTS.md` (`:164-210`) is
never loaded and caveman is inactive for forge-zsh `:` prompts (confirmed by direct
operator observation). An earlier review's "already always-on / redundant" claim was
based on the FORGE_CONFIG-unset case only and is wrong for real usage.

This hook exports an ABSOLUTE path (`$HOME/forge/skills/caveman/SKILL.md`) read from the
env var, independent of `base_path`, so caveman rules are injected in EVERY slot
regardless of `FORGE_CONFIG`. That is the gap this feature fills.

## RULE 0: injection, not enforcement

The one honest caveat that survives: this INJECTS instruction text into the system
prompt; it does not mechanically enforce compression — the model may still ignore it.
What is mechanical is env-var propagation + file injection. Commit/PR wording must say
"inject extra instructions via FORGE_EXTRA_INSTRUCTIONS_PATH", never "enforce caveman".

## Secondary use-cases (general hook, free once built)

- Wrapper tools (`omf`, task runners, CI) inject ephemeral per-invocation instructions
  without mutating any tracked file.
- Per-tty / per-session context or persona that must not be committed.
- Machine-generated instructions that cannot live in a static committed file.

## Non-goals

- No inline `FORGE_EXTRA_INSTRUCTIONS` env var (path only — YAGNI; avoids cross-shell
  quoting/escaping).
- No new CLI flag or `.forge.toml` key.
- No changes to `~/forge/AGENTS.md` §0a or the `~/.claude/.caveman-active` marker.
- No changes to agent-level `custom_rules` (`agent_definition.rs:64-66`).
- Shell-plugin export is NOT part of the core mechanism (see "Shell plugins" below).

## Design — `crates/forge_services/src/instructions.rs`

Fold the env source into `discover_agents_files()` (`:22-47`), reusing the existing
read loop rather than adding a parallel append step.

1. In `discover_agents_files()`, after `cwd_agent_md` is pushed (`:41-44`):
   read `self.infra.get_env_var("FORGE_EXTRA_INSTRUCTIONS_PATH")`
   (`EnvironmentInfra::get_env_var`, sync `-> Option<String>`, `infra.rs:25`, already
   in the `F` bound at `:17` — no new trait bound). Guard with
   `.filter(|s| !s.is_empty())` so a set-but-empty var is treated as unset. If
   `Some(path)`, push `PathBuf::from(path)` **last** (after cwd) so it renders last.
2. The existing loop (`:73-77`) already `read_utf8`'s each path and silently skips on
   `Err` (missing/unreadable/directory) — reuse it; no new error handling. Append-last
   -> renders last in `custom_rules.join("\n\n")` (`system_prompt.rs:91-93,121`).
3. Add a size cap + observability (security Low-1/Low-2):
   - `const MAX_EXTRA_INSTR_BYTES: usize = 32 * 1024;`
   - On successful read: `tracing::debug!(path = %path.display(), "injecting FORGE_EXTRA_INSTRUCTIONS_PATH")` (path only, NEVER contents). If `content.len() > MAX_EXTRA_INSTR_BYTES`, `tracing::warn!` and truncate.
   - On `Err`: `tracing::debug!(path, error, "unreadable; skipping")`.
     (Cap/log applies to the env source specifically — do not silently change behavior
     of the existing base/git/cwd sources.)
4. Update the `discover_agents_files` docstring (`:6-10`): it now documents 4 sources;
   state the new source is lowest priority (rendered after cwd) and note that "rendered
   after" is not a deterministic override of `agent.custom_rules`.

Cache note: `init()` result is memoized via `OnceCell` (`:14,:88`); the env var is read
once per process. Correct for a one-shot CLI — same semantics as AGENTS.md today. No
mid-session refresh (documented, not a regression).

## Shell plugins (optional follow-up, not core)

The caveman-driven `local -x` export is dropped (caveman is already global via §0a).
If a real caller wants shell-driven injection later, mirror the `_FORGE_SESSION_MODEL`
pattern (`helpers.zsh:40-42,74-76`; `forge.plugin.bash:75-77,96-98`;
`forge.plugin.fish:85`) with two hard rules learned in review:
- Use `"$HOME/..."`, NEVER `"~/..."` — tilde does not expand inside quotes, Rust does
  not expand `~`, so a quoted `~` path is a silent no-op.
- Gate on marker presence with `[[ -e ... ]]` / `[[ -f ... ]]`, NOT `-s` (a 0-byte
  `touch`-created marker would silently disable it).
- Skip `_forge_select` / `_forge_select_global` — they spawn the picker, no system
  prompt is built there.

## Tasks

- [ ] Fold `FORGE_EXTRA_INSTRUCTIONS_PATH` read into `discover_agents_files()`
      (`instructions.rs:22-47`); `.filter(|s| !s.is_empty())`; push last.
- [ ] Add `MAX_EXTRA_INSTR_BYTES` cap + `tracing` debug/warn (path only) around the
      env source.
- [ ] Update `discover_agents_files` docstring (`:6-10`) to 4 sources + precedence note.
- [ ] Add `#[cfg(test)]` module in `instructions.rs` (none exists today).
- [ ] Run `cargo check` + `cargo insta test --accept` on `forge_services`.

## Tests (mock-based; per test-engineer)

Pure-helper extraction rejected — it isolates ~zero logic; the risk is wiring
(correct env key, path plumbing, Vec position). Use the infra-mock pattern already
standard in this crate (`terminal_context.rs:116-157`, `tool_services/shell.rs:85-133`,
`discovery.rs:89-121`).

`discover_agents_files()` level (needs `EnvironmentInfra` + `CommandInfra`;
`FileReaderInfra` method unused here):
- env unset -> path list unchanged.
- env set -> extra path present, equal to configured value, at pinned last position.
- env set to `""` -> treated as unset (path list unchanged).

`init()` level (full 3-trait mock):
- env set + file readable -> content appears in returned `Vec<String>`.
- env set + file unreadable (`read_utf8` -> `Err`) -> silently absent, no panic
  (also backfills the currently-untested silent-skip for base/git/cwd).
- optional: file larger than cap -> truncated.

Mock gotcha (verified `forge_domain/src/shell.rs:11-13`): `CommandOutput::success()` =
`exit_code.is_none_or(|c| c >= 0)`, so `None` AND `Some(1)` both count as success. To
make `get_git_root()` return `None` (`instructions.rs:59`), the `CommandInfra` mock must
return `Err` from `execute_command` (or `Some(negative)`), NOT `Some(1)`.

Follow AGENTS.md test conventions: fixture / actual / expected, `pretty_assertions`,
`assert_eq!` on full objects, tests in-file, `Default`/`derive_setters` for fixtures.

## Verification criteria

- `cargo check` clean for `forge_services`.
- `cargo insta test --accept` green for `forge_services`.
- Manual: `FORGE_EXTRA_INSTRUCTIONS_PATH=$HOME/some/file.md forge ...`, confirm the
  file's text appears in the assembled system prompt (`:dump` / debug_requests) —
  absence of an error is NOT evidence of success (all failure modes are silent).
- Manual: env unset -> no regression to base/git/cwd `AGENTS.md` behavior.

## Risks

- All failure modes are silent by design (unset env, unreadable file). Manual
  verification must POSITIVELY confirm the text landed, not just "no error".
- Secret-leak corner: a caller pointing the var at a secret-bearing file ships those
  contents to the model provider. Size cap + path-only debug log are the cheap
  mitigations; a hard allowlist is out of scope for a local user-controlled CLI
  (security verdict: LOW, no new trust boundary vs the already-ungated cwd `AGENTS.md`
  injection).
- Precedence over `agent.custom_rules` is prompt-ordering, not a mechanical guarantee.
