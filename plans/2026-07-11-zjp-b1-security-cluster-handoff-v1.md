# Next-session handoff: zjp bug epic + B1 cluster + operator asks

Prepared 2026-07-11 by the forgecode debug session (pane s032) for the NEXT
agent team. Read-only investigation only; NO source changed this session.
Backed by 12 expert-agent investigations. Task markers: `[ ]` todo,
`[~]` in progress, `[x]` done, `[!]` blocked / needs operator decision.

## TL;DR for the next team

1. Start Phase 1 (three P0 trust-boundary escapes) — disjoint files, fully
   parallelizable, highest security value, NO operator decision needed.
2. Do NOT rush Phase 2 (B1 cluster) or the zjp.1 schema question — the critic
   flagged three items as NEEDS-DECISION / RISKY. Answers required first
   (see "Blocked on operator decisions").
3. Quick wins (zjp.5, zjp.7, zjp.8) and operator asks (Justfile dual-install,
   omf dispatcher) are safe to ship anytime — no dependency on the risky items.

## Blocked on operator decisions (critic verdicts) — ANSWER THESE FIRST

- [!] D1 (zjp.1): Should `--conversation-id` resume work across a DIFFERENT
  cwd/workspace? YES -> composite `(workspace_id, conversation_id)` key +
  Diesel migration (do not bundle into a bugfix sprint). NO -> keep global
  unique, reject cross-workspace access with a CLEAR error (not a silent new
  conversation). Current: `ConversationId` is a bare Uuid PK, no workspace
  column (`crates/forge_domain/src/conversation.rs:11-13`).
- [!] D2 (B1 / 1jb): Must `cli.conversation_id` override `state.conversation_id`
  only ON FIRST init, or EVERY REPL turn? Correct answer is almost certainly
  "cli wins ONCE at init, state wins thereafter." A naive branch swap at
  `crates/forge_main/src/ui.rs:3919-3921` REGRESSES mid-session `/new` and
  in-REPL switches (clobbers back to launch `--cid`). Do not do the raw swap.
- [!] D3 (zjp.4): Is symlink canonicalization applied ONLY for the security
  off-root gate, or also identity/dedup? It must NOT feed the policy gate
  unless the allow-list is canonicalized too, or legit `~`-rooted symlinks and
  macOS `/tmp`->`/private/tmp`, `$TMPDIR`, `~/.local/bin/forge` get denied.

## Phase 1 — P0 trust-boundary escapes (no decision needed, parallelizable)

- [ ] zjp.3 shell policy checks WRONG cwd (dir-scoped allow bypass). HIGH.
  Root cause: `crates/forge_app/src/tool_registry.rs:69-70` passes ambient
  `env.cwd` to `to_policy_operation`; execution uses `input.cwd`
  (`crates/forge_domain/src/tools/catalog.rs:998-1001`,
  `crates/forge_app/src/tool_executor.rs:268-273`); `Execute` dir rules match
  the wrong dir (`crates/forge_domain/src/policies/rule.rs:79-86`).
  Fix: extract `resolve_shell_cwd(input.cwd, env.cwd)` -> `normalize_path`,
  use it for BOTH the policy op and execution. Also fix the "Permissions
  Update" display at `tool_registry.rs:79-84` to show the real run dir.
  Tests: env.cwd != Shell.cwd for allow + deny/confirm; fallback when
  input.cwd is None.
- [ ] zjp.4 file tools don't canonicalize/bound symlink targets. HIGH.
  Root cause: `crates/forge_services/src/utils/path.rs:13-19` only checks
  `is_absolute()`; raw path flows to policy + IO in
  `fs_read.rs:116-130`, `fs_write.rs:52-70,109-111`, `fs_patch.rs:478-514`.
  A canonicalizer already exists unused: `crates/forge_services/src/sync.rs:25-28`.
  Fix: add `assert_bounded_path(path, roots) -> Result<PathBuf>` in
  `utils/path.rs` (canonicalize deepest existing ancestor + join tail for new
  files; reject if resolved path not under allowed roots; resolve symlinks +
  `..`). Return canonical PathBuf; use it for policy AND IO (kills lexical/real
  divergence). See D3 before wiring to the policy gate.
  Tests: inside-root ok, symlink->outside err, `..` escape err, new file under
  root ok, new file under symlinked-outside parent err (tempfile + unix symlink,
  cfg-gate Windows).
- [ ] zjp.6 workspace sync accepts off-root absolute paths. MEDIUM.
  Root cause: `crates/forge_app/src/workspace_status.rs:134-141` `absolutize()`
  returns already-absolute paths unchanged, no `base_dir` containment; both
  `file_statuses` (:53-92) and `get_sync_paths` (:99-119) then classify them
  for delete/upload; `sync.rs` `delete_files`/`upload_files` act blindly.
  Fix: filter at the single choke point in `file_statuses` — keep only paths
  where normalized `resolved.starts_with(base_dir)` (normalize `..` first);
  `tracing::warn!` each skipped path.
  Tests: off-root remote skipped, off-root local skipped, `..` escape rejected,
  in-root regression green; assert whole `SyncPaths` vec.

## Phase 2 — B1 conversation/cwd cluster (SERIAL; gated on D1+D2)

- [!] zjp.1 scope conversation lookup/upsert by workspace. Gated on D1.
  Root cause: `get_conversation` filters only by id and discards `_wid`
  (`crates/forge_repo/src/conversation/conversation_repo.rs:71-74`);
  `upsert_conversation` conflict target is `conversation_id` alone (:52) so a
  cross-workspace collision overwrites the other workspace row. Note
  `get_all/get_last/delete` ALREADY scope by workspace (:92,:118,:139) — get +
  upsert are the outliers. PK is global (`up.sql:3`).
  Fix depends on D1. Test: two repos sharing one pool, distinct WorkspaceHash;
  upsert in A, assert B `get` -> None and B upsert does not mutate A's row.
- [!] 1jb prefer explicit `--cid` over stale `state.conversation_id`. Gated on D2.
  Confirmed ~80%: `crates/forge_main/src/ui.rs:3919` checks state first, :3921
  cli fallback never reached once state set (:3962 makes it sticky). `on_new`
  clears `cli.conversation_id` (:238) but NOT `state.conversation_id`.
  Fix (per D2): cli wins at init only; clear state in `on_new` for symmetry.
- [ ] zjp.2 pin forge-zsh conversation id to cwd/tty/window. Dep: 1jb.
  Root cause: `_FORGE_CONVERSATION_ID` is a bare shell global
  (`shell-plugin/lib/config.zsh:13`), reused across cwd
  (`shell-plugin/lib/dispatcher.zsh:33-36,68-72,82`); switch/clear only mutate
  globals (`shell-plugin/lib/actions/conversation.zsh:22-43`).
  Fix: key active id by composite `${PWD}` + `${TTY}` (+ Ghostty window id) in
  `typeset -hA _FORGE_CONV_BY_CTX`; re-resolve on `chpwd`.
  Test: fake `forge` stub on PATH logging `--cid`; dir A -> `:` -> dir B ->
  `:` asserts different ids; back to A re-resolves A's id.
- [ ] 5g3 reproduce two-session bleed + per-turn cwd/session hard-fail assert.
  Dep: 1jb + zjp.2. Regression evidence ticket.

## Phase 3 — robustness (after zjp.3 + zjp.4, shared files)

- [ ] zjp.5 reject invalid fs_read ranges instead of clamp. MEDIUM.
  Root cause: `resolve_range` never errors (`crates/forge_services/src/range.rs:29,33`
  clamps with `.max(1)` / swap); `read()` clamps positions to last line
  (`crates/forge_services/src/tool_services/fs_read.rs:175-180`); `total_lines`
  known only at :172, AFTER range resolution.
  Fix: after `total_lines`, if `start_line > total_lines` (non-empty file) ->
  Err "start_line N beyond end of file (M lines)"; reject `start_line == 0` and
  `end_line < start_line`; keep end-clamp-to-EOF; empty string only for empty file.
  Tests in range.rs + fs_read.rs (MockFileService): start>EOF err, start=0 err,
  empty file ok(""), valid mid-range unchanged, end>EOF still clamps.

## Phase 4 — quick wins (<30 min, isolated)

- [ ] zjp.7 quote zsh rename args. QUICK. Dep: zjp.2 (same file).
  Root cause: unquoted `$input_text` / `$new_name` at
  `shell-plugin/lib/actions/conversation.zsh:203,224,238` word-split + glob.
  Fix: quote each. Verify `:rename foo *bar` in a dir with files -> literal name.
- [ ] zjp.8 add sonnet-5 to interleaved-thinking predicate + tests. QUICK. No dep.
  Root cause: `interleaved_thinking_required` excludes 4.x/mythos/fable but NOT
  `sonnet-5` (`crates/forge_repo/src/provider/anthropic.rs:98-107`), so Sonnet 5
  wrongly gets `interleaved-thinking-2025-05-14`, contradicting
  `model_specific_reasoning.rs:41-47` (AdaptiveFriendly) and `response.rs:88`.
  Fix: add `|| id.contains("sonnet-5")` to exclusion (:101-106); sync comment
  (:79-82); add `"claude-sonnet-5"` + `us.anthropic.` variant to test loop
  (:839). Verify `cargo insta test -p forge_repo`.

## Phase 5 — operator asks (isolated, no conflict with bugs)

- [ ] A. Justfile: co-install release `forge` + debug `forge-debug` to
  `~/.local/bin`, startable individually. QUICK-MEDIUM.
  Current: `install-local` (`Justfile:207-219`) does `cargo build --release`
  -> `cp target/release/forge ~/.local/bin/forge` -> codesign (Darwin) ->
  `--version`. `install` (:221-223) does `cargo install` -> `~/.cargo/bin`.
  Binary name `forge` (`crates/forge_main/Cargo.toml:7-9`). Release profile
  has LTO+strip (`Cargo.toml:11-15`). Logging is env-driven already
  (`FORGE_LOG` + daily rolling log; `forge logs`) — no code change for the
  debug variant.
  Design:
  | binary | profile | build | install path |
  |--------|---------|-------|--------------|
  | forge | release | `cargo build --release` | `~/.local/bin/forge` |
  | forge-debug | debug | `cargo build -p forge_main` | `~/.local/bin/forge-debug` |
  Debug differs via debug-assertions/overflow-checks + running with
  `FORGE_LOG=${FORGE_LOG:-debug}` (verbose traces to `~/forge/logs/`). Wire
  `forge-debug` as `cp target/debug/forge` (operator sets env) OR a tiny wrapper
  that `exec`s with the debug FORGE_LOG default.
  Recipes: keep `build-release`; add `build-debug` (`cargo build -p forge_main`),
  `install-release` (rename of install-local logic), `install-debug` (build +
  cp target/debug/forge -> forge-debug + codesign + `forge-debug --version`),
  `install-both: install-release install-debug` (dep chain, house style).
  NOTE: forgecode AGENTS.md forbids `cargo build --release` "unless necessary" —
  here release IS the deliverable; say so in the recipe doc-comment.
  Optional: move inline heredoc install logic to `.just/helpers/install.bash`
  (house-style thin-Justfile split; not required for correctness).
- [ ] B. Make `omf` do something real. LARGER. Lives at `~/forge/omf/`
  (OUTSIDE this repo). Working pieces today: `adapters/resume.bash` (omf resume
  -> vendored `fcr`), `adapters/hist.bash` (omf hist -> vendored `forge-hist`),
  vendored zsh under `adapters/vendor/`, `~/forge/omf-cockpit-input.el`.
  Placeholder: `~/forge/omf.toml` (schema_version=0, references nonexistent
  `omf/core/src/manifest.rs` + `omf/dispatch`). Epics `milansantosi-wav` (omf v2)
  and `milansantosi-kmf` (e.bash v4) are title-only stubs.
  Minimal first milestone (an afternoon): (1) real Bash `omf` dispatcher wiring
  `resume`/`hist`/`help`; (2) `omf doctor` (zsh present, snippets readable,
  vendored copies match `~/.config/mein-zsh/snippets/`); (3) defer the Go-core
  manifest/routing (leave omf.toml as design note); (4) backfill body +
  acceptance criteria on `milansantosi-wav` before more code.

## Security ROI note (from security-reviewer)

Highest-ROI single change: a canonicalize-and-bind-to-root path/cwd primitive
at the policy boundary (`utils/path.rs` + `tool_registry.rs:70`) feeding the
shell's real `input.cwd` into `to_policy_operation`. One primitive closes zjp.3
+ zjp.4 (both HIGH) and mitigates zjp.6 — same shared root cause: policy
evaluated on raw, non-canonical, wrong-source paths.

## Parallelization map

- Phase 1 items (zjp.3, zjp.4, zjp.6) touch disjoint files — run concurrently.
- Phase 2 (zjp.1 -> 1jb -> zjp.2 -> 5g3) is strictly serial and gated on D1+D2.
- zjp.5 must follow zjp.3 + zjp.4 (shares tool_executor.rs / fs_read.rs).
- zjp.7 must follow zjp.2 (same conversation.zsh).
- zjp.8, operator asks A + B are free-floating.
