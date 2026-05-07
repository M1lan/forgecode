# Emacs-Native Forge + Ghostty -- Full Integration Plan

> **End-goal**: Forge AND Ghostty are integral parts of the user's custom
> GNU Emacs branch (`mymain`). A single `brew install emacs-plus@mymain`
> compiles Emacs with Ghostty terminal emulation built in and Forge
> installed alongside.

**Created:** 2026-05-05
**Updated:** 2026-05-08
**Plan version:** v2 (expanded from original Tracks A-C to full A-F)

---

## Status (revised 2026-05-08)

| Track | State | Notes |
|---|---|---|
| **A — comint frontend** | ✅ **shipped** | Branch `emacs-native-frontend-track-a`, commits `203427cfc` and `d08ad2d42`. Verified end‑to‑end inside a real Emacs `comint-mode` buffer (banner / `/exit` / EOF / empty lines / piped stdin). |
| **B — JSON line protocol** | ✅ **shipped (behind `--unstable`)** | Same branch, commits `f5b336d43`, `5f16299e7`, `785ae4916`. Protocol v1, tool events, usage events, native selector round‑trip. 2621 workspace tests green. |
| **C — Emacs dynamic module** | 🅿 **parked** | Decision 2026-05-08: not worth the cost yet. Track B over a local pipe is already <1 ms per event; module work is months. See §4 for a one‑page resumption guide so the next session starts in five minutes, not five days. |

→ **If you are resuming this work, jump to [§7 Resumption Guide](#7-resumption-guide).** It pins down every fact you need: branch state, local paths, library versions, prior decisions, and the exact first commands to run.

---


## 0. What's actually in the way today

| Path | Role | Branch |
|---|---|---|
| `~/mysrc/forgecode/` | Forge source (this repo) | `mymain` |
| `~/mysrc/emacs/` | GNU Emacs source | `mymain` |
| `~/mysrc/ghostty/` | Ghostty terminal (includes libghostty, libghostty-vt) | -- |
| `~/mysrc/ghostling/` | Minimal C terminal on libghostty-vt + Raylib (reference impl) | -- |
| `~/mysrc/emacs-ghostty-module/` | C module + elisp for Ghostty-in-Emacs (Track D) | -- |
| `~/mysrc/homebrew-emacs-plus/` | Homebrew formula | `mymain` |
| `~/.emacs.d/` | Emacs configuration | -- |
| `~/forge/` | Forge runtime configuration | -- |

---

## Track Status Overview

| Track | Description | Status |
|---|---|---|
| **A** | comint frontend (`--frontend=comint`) | **SHIPPED** |
| **B** | JSON line protocol (`--frontend=json --unstable`) | **SHIPPED** |
| **C** | Forge as Rust dynamic module | **PARKED** (pipe latency <1ms, not needed) |
| **D** | Ghostty terminal in Emacs | **Phase 1 COMPLETE**, interactive test pending |
| **E** | forge.el two-buffer UX (consumes Track B) | NOT STARTED |
| **F** | Homebrew formula (emacs-plus@mymain) | NOT STARTED |

---

## Execution Order

```
DONE:
  Track A (comint) ..................... SHIPPED
  Track B (JSONL) ..................... SHIPPED
  Track D Phase 1 (dyn module) ....... BUILT, REVIEWED, INSTALLED

NEXT:
  Track D Phase 1 interactive test ... restart Emacs, M-x ghostty-term
  Track D Phase 2 (in-tree DEFUN) .... ~/mysrc/emacs/src/ghostty-term.c
  Track E (forge.el) ................. can run in parallel with D Phase 2

LAST:
  Track F (homebrew formula) ......... depends on D Phase 2 + E
```

---

## 0. Analysis -- What's in the Way (original, still valid)

Findings from `crates/forge_main/`, `crates/forge_select/`,
`crates/forge_spinner/`, and `crates/forge_domain/src/console.rs`:

| Concern | Status |
|---|---|
| Output abstracted behind `ConsoleWriter` trait | solved (Track A) |
| Input locked to reedline raw mode | solved (Track A comint, Track B JSON) |
| Interactive selectors assume TTY | solved (Track A line-prompt, Track B JSON select) |
| Spinner ANSI garbage in dumb terminals | solved (Track A quiet spinner) |
| No structured events | solved (Track B NDJSON) |

---

## 1. Track A -- comint frontend [SHIPPED]

`forge --frontend=comint` reads line-buffered stdin, emits plain text.
`M-x forge-comint` opens a comint buffer with full Emacs editing.

Commits: `203427cfc`, `d08ad2d42`.

All tasks complete. No remaining work.

---

## 2. Track A — "Dumb terminal" / comint mode (cheap, days) ✅ SHIPPED

`forge --frontend=json --unstable` reads/writes NDJSON on stdin/stdout.
Full wire protocol v1 with typed events: chunks, tool calls, selectors,
usage, errors, reasoning.

Commits: `f5b336d43`, `5f16299e7`, `785ae4916`.
Tests: 2621 green.

All tasks complete. Protocol is stable behind `--unstable` flag.

---

## 3. Track B — JSON‑line frontend + first‑class `forge.el` (right answer, weeks) ✅ SHIPPED (Rust side)

Track B pipe latency is <1ms. No need for in-process embedding.
Revisit only if zero-copy buffer access becomes needed.

---

## 4. Track C — Native Emacs dynamic module (nuclear, months) 🅿 PARKED

> **Outcome (if ever pursued)**: `forge.dylib` (a Rust cdylib built against
> `emacs-module.h`) is loaded by Emacs. No subprocess. Elisp calls into Rust,
> Rust calls back into Elisp via the module API. The "rewrite Forge in C and
> integrate it into the core of Emacs" idea, modernised.

### Decision (2026-05-08): park C

- Track B over a local pipe already delivers structured events at sub‑ms
  latency. There is **no measured pain** that C would solve.
- Track C is months of FFI / async‑bridge / per‑platform CI work and erodes
  the crash isolation that B gives for free (a Rust panic in‑module crashes
  Emacs).
- **Gate to revisit**: only when B is shipping in production and you hit one
  of the *named* B‑can't‑solve problems below. Until then, C stays parked.

Concrete revival triggers (any one of these is enough):

- B's pipe latency exceeds 50 ms input → first chunk on your hardware. (Not
  expected; current local‑pipe latency is < 1 ms per event.)
- You want zero‑copy region/buffer passing between Emacs and Forge — e.g. to
  let Forge see live edits in a buffer without a serialise → pipe → parse
  round‑trip.
- You want Forge state to share Emacs's address space with another tool
  (Magit, Project.el, eglot) so they can call into Forge directly without
  IPC.
- Per‑process startup cost of `forge --frontend=json` becomes a problem
  (e.g. starting a session per file becomes the dominant UX path).

Embed `libghostty-vt` (Ghostty's VT-only library) into Emacs.

- Use the [`emacs` crate](https://crates.io/crates/emacs) (currently 0.21.0,
  March 2026; supports Emacs 28+, including 31.0.50). One call:
  `#[emacs::module]` on a `fn init(&Env) -> Result<()>` produces a working
  dynamic module.
- New crate `crates/forge_emacs/` (cdylib) re‑exporting a small surface:
  `(forge-init)`, `(forge-submit STRING)`, `(forge-cancel)`,
  `(forge-set-callback FN)`. Internally drives `forge_api` (the same library
  the JSON frontend already drives). The JSON frontend in `forge_main`
  becomes the reference embedding; `forge_emacs` is a second one.
- Streaming via Elisp callbacks. Module callbacks run on the Emacs main
  thread, so the Tokio runtime lives on a background OS thread and pushes
  `ServerEvent`s through an `mpsc` into a polling timer or, preferably, a
  `make-pipe-process` sink whose filter funcalls back into elisp on the
  main thread. The `ServerEvent` shape is already defined in
  `crates/forge_main/src/frontend/protocol.rs` — reuse it verbatim.
- Panic safety: every `#[defun]` boundary wraps its body in
  `std::panic::catch_unwind` and converts panics into elisp errors. This is
  one helper macro, not a per‑function cost.

### C.2 Why C is hard (read before un‑parking)

- **Build complexity**: dynamic modules ship as `.so`/`.dylib`/`.dll` per
  platform. Per‑platform CI (macOS arm64 + x86, Linux x86_64, Windows) is
  table stakes. Cross‑compilation needs the right `emacs-module.h` per
  target.
- **Crash isolation gone**: a Rust panic in the module can take Emacs with
  it. Subprocess in B is naturally isolated.
- **Rust async + Emacs main thread**: tokio + module callbacks is doable but
  fiddly; you'll re‑invent half of `make-process`'s lifecycle.
- **All of Forge's deps come along**: rustls, hyper, hickory‑dns, etc., all
  loaded into Emacs's address space. Surface area for breakage explodes.

### C.3 First‑touch checklist (when un‑parked)

Order matters. Each step is a discrete, atomic commit; expect 0.5–1 day each.

1. **Scaffold**: `crates/forge_emacs/` with `Cargo.toml`
   (`crate-type = ["cdylib"]`, depends on `emacs = "0.21"`),
   `src/lib.rs` containing `emacs::plugin_is_GPL_compatible!()`,
   `#[emacs::module(name = "forge")]`, and one trivial `#[defun]
   forge-version() -> String`. Verify it builds: `cargo build -p forge_emacs`
   produces `target/debug/libforge_emacs.dylib`.
2. **Smoke test the module loads**: from Emacs,
   `(module-load "/abs/path/libforge_emacs.dylib") (forge-version) ⇒ "..."`.
3. **Panic guard**: helper macro that wraps each `#[defun]` body in
   `catch_unwind` and converts panics to `env.signal('forge-error msg)`.
   Add a test `#[defun] forge-test-panic` that always panics; assert Emacs
   sees a structured error, not a crash.
4. **Decision: async bridge**. Recommended: `make-pipe-process` (Emacs
   feeds the pipe FD; Rust writes serialised `ServerEvent`s to it; an
   elisp filter funcalls registered handlers on the main thread). Avoids
   timer polling latency. Document the choice in `docs/track-c-design.md`.
5. **Wire `(forge-submit STRING)`** to `forge_api` and stream
   `ServerEvent`s through the chosen bridge. At this point you have a
   working in‑module turn — Track B's elisp client can now run on the
   module instead of a subprocess by changing one constructor.
6. **CI matrix**: GitHub Actions builds for macOS arm64, macOS x86_64,
   Linux x86_64, Windows x86_64. Each artifact is the platform `.dylib` /
   `.so` / `.dll`.
7. **Promote**: cut a release that ships both the `forge` binary (B) and
   the loadable module (C). Track B remains the default; C is opt‑in for
   users who want zero‑subprocess overhead.

### C.4 Local environment captured for resumption

| Fact | Value |
|---|---|
| Emacs runtime | 31.0.50 (`emacs-plus@31` from `~/mysrc/homebrew-emacs-plus/`) |
| `module-file-suffix` | `.dylib` (macOS arm64) |
| `exec-directory` | `/opt/homebrew/Cellar/emacs-plus@31/31.0.50/libexec/emacs/31.0.50/aarch64-apple-darwin25.1.0/` |
| `emacs-module.h` (system) | `/opt/homebrew/include/emacs-module.h` and `/opt/homebrew/Cellar/emacs-plus@31/31.0.50/include/emacs-module.h` |
| `emacs-module.h` (source) | `~/mysrc/emacs/src/emacs-module.h` |
| Rust `emacs` crate | `0.21.0` (March 2026), API stable since 0.18 |
| Forge user config | `~/.emacs.d/lisp/forge-*.el` (existing `forge-code.el` v1.0.0 already wraps `eat`; the C module would *replace* its `eat` backend, not greenfield) |


---

## 5. Track E -- forge.el Two-Buffer UX

These were uncontroversial cleanups Track A needed and B/C inherit. **All five
landed during A+B.**

1. ✅ **Hoist input behind a trait.** `console` field on `UI` is now a
   `UserInput` enum (`Console` / `CominInput` / `JsonInput`) selected by
   `FrontendMode` at startup. See `crates/forge_main/src/input.rs`.
2. ✅ **Hoist selector behind a trait.** `forge_select` exposes
   `SelectorBackend` with `select` / `multi` / `input` / `confirm`; per‑frontend
   impls register via `install_selector_backend`. The TTY path uses the
   crossterm widget; comint and JSON use the line‑prompt fallback or the
   `JsonSelectorBackend` respectively. See `crates/forge_select/src/backend.rs`.
3. ✅ **Tame ANSI colour at one switch.** `colored::control::set_override(false)`
   is set once in `crates/forge_main/src/main.rs` when
   `frontend.is_dumb()` is true.
4. ✅ **`Spinner` → quiet mode.** `SpinnerManager::set_quiet(true)` makes
   `start`/`stop` no‑ops while `write_ln`/`ewrite_ln` still work; selected at
   construction in `UI::init`. See `crates/forge_spinner/src/lib.rs`.
5. ⏸ **Document the existing `--prompt` + `--conversation-id` pattern** in
   `docs/`. Skipped — `--frontend=comint` and `--frontend=json` make the
   per‑turn workaround unnecessary, and the JSON wire is already documented
   at `docs/frontend-protocol.md`.

---

## 6. Track F -- Homebrew Formula Integration

- **Gate A → B**: ✅ both shipped. Used in production via comint;
  `--frontend=json` wire is ready for an editor client to consume.
- **Gate B → C**: 🅿 not triggered. Local‑pipe latency for B is < 1 ms per
  event; no measured pain. C revisited only on the named triggers in §4.

---

## 7. Resumption Guide

Read this section first when you next sit down to this work. Everything you
need to remember is here.

### 7.1 Where the work lives

| Repo / path | Contents |
|---|---|
| `~/mysrc/forgecode/` | This repo. Branch `emacs-native-frontend-track-a` carries A + B. |
| `~/mysrc/emacs/` | Emacs source. `src/emacs-module.h` is the FFI header for Track C. |
| `~/mysrc/homebrew-emacs-plus/` | Homebrew formula for `emacs-plus@31`. The `--with-native-comp` build is what's running. |
| `~/.emacs.d/` | The user's Emacs config. `lisp/forge-*.el` already contains a Forge session manager (`forge-code.el` v1.0.0) that today wraps `eat` — see §7.4 below. |

### 7.2 Branch state (commit walk)

Branch: `emacs-native-frontend-track-a` (5 commits ahead of `mymain`).

```
785ae4916 feat(forge_main,forge_select): wire native selector round-trip + emit_usage  ← Track B selector + usage
5f16299e7 feat(forge_main): wire json frontend lifecycle and chunk redirect            ← Track B lifecycle wiring
f5b336d43 feat(forge_main): json frontend foundation (protocol + adapters)             ← Track B foundation
d08ad2d42 fix(forge_main): skip hydrate_caches under comint frontend                   ← Track A polish
203427cfc feat(forge_main): comint frontend mode for Emacs and dumb terminals          ← Track A
```

Status: clean working tree, 2621 workspace tests pass, clippy clean.

### 7.3 What ships today (CLI surface)

```
forge --frontend=tty                  # default, unchanged behaviour
forge --frontend=comint               # for Emacs comint-mode / dumb terminals
forge --frontend=json --unstable      # NDJSON line protocol; --unstable required
INSIDE_EMACS=*comint* forge           # auto-selects comint
TERM=dumb forge                       # auto-selects comint
```

Wire format reference: `docs/frontend-protocol.md`.

### 7.4 Existing elisp surface (don't greenfield)

The user already has `~/.emacs.d/lisp/forge-*.el`:

```
forge-agent-client.el     forge-orchestration.el
forge-code.el             forge-prompt.el
forge-conversations.el    forge-reply.el
forge-integration.el      forge-skills.el
forge-modeline.el         forge-transient.el
```

`forge-code.el` v1.0.0 (header: "ForgeCode session manager for Emacs") today
runs Forge inside an `eat` terminal buffer with `*forge:<agent>:<project>*`
naming and a `C-c F` prefix. **Any future elisp work (`forge-comint.el`,
`forge.el` for Track B's two-buffer UX, or the Track C module client) should
extend this file or live alongside it — not replace it greenfield.**

The natural next elisp tasks (separate from this Rust repo, all in
`~/.emacs.d/lisp/`):

- `forge-comint.el` — the consumer of Track A's `--frontend=comint`.
  Skeleton in §2 of this plan still applies. Estimated 1 evening.
- `forge.el` — the two‑buffer ERC‑style consumer of Track B's
  `--frontend=json`. Skeleton in §3.B.4 of this plan still applies.
  Estimated 2–3 evenings.

### 7.5 First commands when you sit back down

```bash
cd ~/mysrc/forgecode
git checkout emacs-native-frontend-track-a
git status                                       # should be clean
git log --oneline -6                             # should match §7.2

# Confirm both frontends still work end-to-end
cargo build -p forge_main --bin forge
echo '/exit' | ./target/debug/forge --frontend=comint | head -5
printf '{"kind":"command","v":1,"id":"r1","name":"exit"}\n' \
    | ./target/debug/forge --frontend=json --unstable

# Confirm tests still green
cargo test --workspace --lib 2>&1 | rg "test result:" | tail -5
```

If any of those fail, something rotted in main; rebase before continuing.

### 7.6 Likely next session goals (pick one)

1. **Land an elisp client** (`forge-comint.el` or `forge.el`) so this work is
   actually used day‑to‑day. Highest value per hour.
2. **Promote Track B from `--unstable` to GA**: stabilise the protocol at
   v1, drop the `--unstable` gate, ship a release. Requires ~2 weeks of
   dogfooding first.
3. **Un‑park Track C** only if one of the §4 revival triggers fires.

### 7.7 Decisions already locked in (don't relitigate)

- **Three‑frontend axis**: tty / comint / json. No fourth. (`FrontendMode` enum
  in `crates/forge_main/src/cli.rs:99-167`.)
- **JSON protocol = NDJSON**, one event per line, `kind`‑tagged. v1.
  Versioning bumped on incompatible change.
- **JSON is opt‑in only** behind `--unstable`. Auto‑detect never selects it.
- **Selector backend is global**, installed once at startup via
  `forge_select::install_selector_backend`. One frontend per process.
- **Stdin is single‑owner under JSON**: the `EventRouter` background thread
  is the sole reader; everything else consumes via `mpsc::Receiver`.
- **`hydrate_caches()` is skipped** under comint/json to avoid the EOF
  shutdown race (commit `d08ad2d42`).
- **Spinner is quiet** (no animation) under any dumb frontend, to keep
  scrollback / wire output clean.
- **Track C parked**, not abandoned — see §4.

That's the whole context. Resume from §7.5.

