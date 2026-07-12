# Differential Conformance Oracle — Results (P2 acceptance gate)

Oracle for interactive forge shell plugins. Drives a target shell under
`pexpect` with a pinned deterministic env, feeds named keystroke trace cases,
and captures two observables per case:

- **T1 (MUST, byte-identical):** the `forge` subprocess trace — argv + injected
  env + cwd — via a fake `forge` shim first on `$PATH` (`$FORGE_TRACE` JSON lines).
- **T2 (MUST-where-capable):** the OSC-133 marker sequence emitted on the pty,
  scraped from raw bytes; plus a `pyte` screen grid + cursor.

Scoring is **differential** and **per-capability** (not one scalar): each
candidate case is compared against the reference zsh run of the same case.
Exit code is non-zero if any T1 (MUST) fails.

Artifacts (this dir): `oracle.py`, `fake-forge/forge`, `cases.json`, `run.sh`,
`broken-plugin/` (the deliberately corrupted candidate).

Run env: `TERM=xterm-256color TERM_PROGRAM=ghostty COLUMNS=80 LINES=24
LC_ALL=C FORGE_SYNC_ENABLED=false`, zsh `-f` (no user rc), fresh zsh per case.
Python via `uvx --with pyte --with pexpect`.

## Capabilities covered

13 trace cases derived from the capability inventory (`00-model.md §3`,
`01-dispatch.md §1`): `new` (bare/banner + prompt+send), default agent send
`: text`, `info`, `config list`, **config-model `cm`** (global model set),
session **`model` `m`** (session-only override, no `config set`),
`reasoning-effort` session, `tools`, `help` (the direct no-`--agent` path),
`commit` (env injection `FORCE_COLOR`/`CLICOLOR_FORCE` + no-`--agent`),
**session-env-injection** (`:m` then `: send` — asserts `FORGE_SESSION__MODEL_ID`
/ `FORGE_SESSION__PROVIDER_ID` reach the child), and non-`:` passthrough.

## VALIDATION 1 — zsh-vs-zsh self-consistency (MUST be 100%)

```
### VALIDATION 1: selfcheck (zsh reference vs itself) -- 2026-07-11T23:17:34Z
$ ./run.sh selfcheck
new_bare             cap=conversation.new             t1=PASS t2=PASS score=1.0
new_prompt           cap=conversation.new+send        t1=PASS t2=PASS score=1.0
default_send         cap=agent.send                   t1=PASS t2=PASS score=1.0
info                 cap=info                         t1=PASS t2=PASS score=1.0
config_list          cap=config.list                  t1=PASS t2=PASS score=1.0
config_model_cm      cap=config-model(cm)             t1=PASS t2=PASS score=1.0
session_model_m      cap=model(session)               t1=PASS t2=PASS score=1.0
reasoning_effort     cap=reasoning-effort(re)         t1=PASS t2=PASS score=1.0
tools                cap=tools                        t1=PASS t2=PASS score=1.0
help                 cap=help(no --agent)             t1=PASS t2=PASS score=1.0
commit               cap=commit(env+no --agent)       t1=PASS t2=PASS score=1.0
session_then_send    cap=session-env-injection        t1=PASS t2=PASS score=1.0
passthrough          cap=non-colon.passthrough        t1=PASS t2=PASS score=1.0
summary: cases=13 t1=13/13 t2=13/13
EXIT=0
```

**Result: 100% (T1 13/13, T2 13/13, exit 0).** The reference is self-consistent
across independent zsh processes — the oracle's own noise floor is zero.

## VALIDATION 2 — broken-candidate discrimination (must catch exactly the defect)

The candidate is a full copy of the plugin with ONE line corrupted in the `cm`
(config-model) dispatch branch — `_forge_action_model` in
`broken-plugin/lib/actions/config.zsh:51`, argv order swapped:

```
-  _forge_exec config set model "$provider_id" "$model_id"
+  _forge_exec config set model "$model_id" "$provider_id"
```

```
### VALIDATION 2: broken candidate (reference vs corrupted cm branch) -- 2026-07-11T23:17:42Z
$ ./run.sh broken
new_bare             cap=conversation.new             t1=PASS t2=PASS score=1.0
new_prompt           cap=conversation.new+send        t1=PASS t2=PASS score=1.0
default_send         cap=agent.send                   t1=PASS t2=PASS score=1.0
info                 cap=info                         t1=PASS t2=PASS score=1.0
config_list          cap=config.list                  t1=PASS t2=PASS score=1.0
config_model_cm      cap=config-model(cm)             t1=FAIL t2=PASS score=0.5
    T1 {"cand": [{"argv": ["select", "model", "--query", "gpt"], "cwd": "/Users/milan.santosi/tmp/forge-shell-spec/oracle", "env": {"CLICOLOR_FORCE": "0"}}, {"argv": ["--agent", "forge", "config", "set", "model", "gpt-4o", "openai"], "cwd": "/Users/milan.santosi/tmp/forge-shell-spec/oracle", "env": {}}], "ref": [{"argv": ["select", "model", "--query", "gpt"], "cwd": "/Users/milan.santosi/tmp/forge-shell-spec/oracle", "env": {"CLICOLOR_FORCE": "0"}}, {"argv": ["--agent", "forge", "config", "set", "model", "openai", "gpt-4o"], "cwd": "/Users/milan.santosi/tmp/forge-shell-spec/oracle", "env": {}}]}
session_model_m      cap=model(session)               t1=PASS t2=PASS score=1.0
reasoning_effort     cap=reasoning-effort(re)         t1=PASS t2=PASS score=1.0
tools                cap=tools                        t1=PASS t2=PASS score=1.0
help                 cap=help(no --agent)             t1=PASS t2=PASS score=1.0
commit               cap=commit(env+no --agent)       t1=PASS t2=PASS score=1.0
session_then_send    cap=session-env-injection        t1=PASS t2=PASS score=1.0
passthrough          cap=non-colon.passthrough        t1=PASS t2=PASS score=1.0
summary: cases=13 t1=12/13 t2=13/13
EXIT=1
```

**Result: the oracle FAILS the candidate on exactly `config-model(cm)` (T1),
passes the other 12, exits 1.** The detail shows the defect precisely: candidate
argv `config set model gpt-4o openai` vs reference `config set model openai
gpt-4o` (provider/model transposed). The oracle discriminates a single-line
dispatch defect and does not rubber-stamp — no other capability is affected, and
T2 (the OSC-133 wire) is unchanged because the bug is argv-only.

## Nondeterminism normalization

- **cid / uuids:** the fake `forge conversation new` returns a FIXED uuid, so
  lazy-create yields identical `--cid` across runs.
- **timestamps:** `_FORGE_TERM_TIMESTAMPS` (wall-clock) is dropped from the T1
  env comparison.
- **detached background jobs:** `forge update --no-confirm` and the
  absolute-path `workspace sync/info` probes (helpers.zsh `&!`) are filtered from
  T1 by argv signature; background sync is additionally gated off with
  `FORGE_SYNC_ENABLED=false`.
- **capture race:** each case settles until the `$FORGE_TRACE` file stops growing
  (not merely terminal quiescence), so a late second forge call (e.g. the `cm`
  `config set`) can never be silently dropped into a false T1 match.

## UNTESTABLE-HEADLESS capabilities (observability gap, T3)

A headless pty + screen-grid cannot observe the T3 line-editor UX tier
(`00-model.md §1`, top risk §7). These are explicitly out of scope for this
oracle and MUST be covered by other means (manual/interactive or unit tests):

- **Mid-edit repaint** — `zle reset-prompt` / `zle -I` visual refresh during
  editing (`_forge_reset`, `bindings.zsh` bracketed-paste). Only the final grid
  is visible, not the redraw sequence.
- **Live syntax highlight** — `ZSH_HIGHLIGHT_PATTERNS` / `highlight.zsh` coloring
  as the user types.
- **Native `RPROMPT` / `style.rs` rendering** — right-prompt content and the
  `%F{}`/`%B` escape backend.
- **Bracketed-paste `@[]` path-wrapping** — `forge-bracketed-paste` calls
  `forge zsh format`; the wrap+cursor-math is a mid-edit transform, not a
  subprocess-dispatch or an OSC-133 event.
- **Cursor math during editing** (`$LBUFFER`/`$RBUFFER`/`CURSOR` mid-edit).
- **The BUFFER-rewrite of `edit`/`commit-preview`/`suggest`**: the *final*
  rewritten line is partially visible on the grid, but the early-return prompt
  handling and the interactive editor round-trip are not headless-observable and
  are therefore left UNTESTED-HEADLESS here.
- **INV-ABORT-PAIR** (SIGINT between OSC-133 `C` and `D` on the ZLE path): a
  timing-dependent abort race best proven by the TLA+ model, not this oracle.

## How to run

```
./run.sh selfcheck                 # zsh reference vs itself (expect 100%, exit 0)
./run.sh broken                    # reference vs corrupted candidate (expect cm FAIL, exit 1)
./run.sh diff <ref-dir> <cand-dir> # arbitrary differential (bash/fish port later)
# JSON (LLM-first): uvx --with pyte --with pexpect python oracle.py diff --ref R --cand C --json
```
