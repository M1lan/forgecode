# Emacs-Native Forge + Ghostty -- Full Integration Plan

> **End-goal**: Forge AND Ghostty are integral parts of the user's custom
> GNU Emacs branch (`mymain`). A single `brew install emacs-plus@mymain`
> compiles Emacs with Ghostty terminal emulation built in and Forge
> installed alongside.

**Created:** 2026-05-05
**Updated:** 2026-05-08
**Plan version:** v2 (expanded from original Tracks A-C to full A-F)

---

## Working Directories

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

## 2. Track B -- JSON line protocol [SHIPPED]

`forge --frontend=json --unstable` reads/writes NDJSON on stdin/stdout.
Full wire protocol v1 with typed events: chunks, tool calls, selectors,
usage, errors, reasoning.

Commits: `f5b336d43`, `5f16299e7`, `785ae4916`.
Tests: 2621 green.

All tasks complete. Protocol is stable behind `--unstable` flag.

---

## 3. Track C -- Forge as Rust dynamic module [PARKED]

Track B pipe latency is <1ms. No need for in-process embedding.
Revisit only if zero-copy buffer access becomes needed.

---

## 4. Track D -- Ghostty Terminal in Emacs

### D.1 Architecture

Embed `libghostty-vt` (Ghostty's VT-only library) into Emacs.

- **C, not Zig/Rust** -- ghostling (`~/mysrc/ghostling/main.c`, 1604 lines)
  proves the full API is consumable from C. No FFI bridge needed.
- **Static link** -- `libghostty-vt.a` (7.5 MB, zero runtime deps except
  CoreFoundation on macOS).
- **Two phases**: dynamic module first (fast iteration), then migrate into
  Emacs source tree (DEFUN macros, configure.ac).

### D.2 Phase 1 -- Standalone Dynamic Module [COMPLETE]

| Deliverable | Location | Lines | Status |
|---|---|---|---|
| C module | `~/mysrc/emacs-ghostty-module/ghostty-term-module.c` | 1074 | Built, 2x reviewed, all 29 issues fixed |
| Elisp mode | `~/mysrc/emacs-ghostty-module/ghostty-term.el` | 852 | Written, reviewed, byte-compiled clean |
| Makefile | `~/mysrc/emacs-ghostty-module/Makefile` | 61 | macOS + Linux |
| Compiled | `~/.emacs.d/lisp/ghostty-term-module.dylib` | 1.5 MB | Static-linked, zero runtime deps |
| Installed | `~/.emacs.d/lisp/ghostty-term.el` | 852 | Ready to load |

**Quality:**

| Metric | Value |
|---|---|
| Review rounds | 2 (critic + code-reviewer each) |
| Issues found/fixed | 29/29 |
| Compiler warnings | 0 |
| Byte-compile warnings | 0 |
| Integration tests | 31/31 pass |
| Render perf (120x40) | 0.01 ms (500x under 5ms target) |

**C Module API (14 functions):**

| Function | Purpose |
|---|---|
| `ghostty-term--version` | Module version string |
| `ghostty-term--init` | Create terminal + PTY (COLS ROWS) -> handle |
| `ghostty-term--destroy` | Teardown + cleanup |
| `ghostty-term--pty-fd` | Get master PTY fd |
| `ghostty-term--alive-p` | Check child process |
| `ghostty-term--write` | Send bytes to PTY |
| `ghostty-term--process` | Drain PTY + update VT state |
| `ghostty-term--resize` | Resize terminal + PTY |
| `ghostty-term--render` | Extract dirty rows: (ROW-IDX TEXT . FACE-VEC) |
| `ghostty-term--cursor` | Cursor (X Y VISIBLE STYLE) |
| `ghostty-term--scroll` | Viewport scrollback |
| `ghostty-term--key` | Encode key event -> PTY |
| `ghostty-term--check-child` | Poll child exit code |

**Elisp Features:**
- `ghostty-term-mode` derived from `special-mode`
- 60fps timer render loop with dirty-row optimization
- RLE face batching for TrueColor (per-cell fg/bg RGB)
- Face cache with 4096-entry eviction
- Full Emacs event -> GhosttyKey code translation
- Cursor overlay (block/bar/underline)
- Resize via `window-size-change-functions` with ref-counting
- Scrollback via mouse wheel
- Bracketed paste (`C-c C-y`)
- `C-c` prefix: C-k destroy, C-c interrupt, C-z suspend

### D.3 Phase 1 Tasks

- [x] Build libghostty-vt: `zig build lib-vt` -> 7.5 MB `.a`
- [x] Create module project: `~/mysrc/emacs-ghostty-module/`
- [x] Write `ghostty-term-module.c` (1074 lines, 14 functions)
- [x] Compile: static-linked 1.5 MB `.dylib`, zero warnings
- [x] Smoke test: full lifecycle verified in `emacs --batch`
- [x] Code review round 1: 15 issues found and fixed (C module)
- [x] Re-verify: 16 tests pass (functional + error paths)
- [x] Performance benchmark: 0.01 ms/render
- [x] Write `ghostty-term.el` (852 lines)
- [x] Code review round 2: 14 issues found and fixed (elisp + C)
- [x] Byte-compile clean, 31/31 integration tests pass
- [x] Installed to `~/.emacs.d/lisp/`
- [ ] **Interactive test: restart Emacs, `M-x ghostty-term`, verify colors/input/resize**
- [ ] Add mouse click/drag support (mouse encoder)
- [ ] Add CJK/wide-character face alignment

### D.4 Phase 2 -- Compile into Emacs Source Tree

Convert the dynamic module to native DEFUN-style C compiled directly
into the Emacs binary. See `~/mysrc/emacs/plans/2026-05-08-ghostty-term-emacs-integration-v1.md`
for the detailed Emacs-side plan.

Key conversions: `env->make_integer` -> `make_fixnum`, `emacs_value` ->
`Lisp_Object`, `emacs_module_init` -> `syms_of_ghostty_term`, etc.

Build integration follows the xwidgets/tree-sitter pattern:
`--with-ghostty-term` flag, `HAVE_GHOSTTY_TERM` define, conditional `.o`.

**Phase 2 Tasks:**

- [ ] Create `~/mysrc/emacs/src/ghostty-term.c` (DEFUN conversion)
- [ ] Create `~/mysrc/emacs/src/ghostty-term.h`
- [ ] Patch `configure.ac`: `--with-ghostty-term`, `HAVE_GHOSTTY_TERM`
- [ ] Patch `src/Makefile.in`: conditional `ghostty-term.o`, link `libghostty-vt.a`
- [ ] Patch `src/emacs.c`: `syms_of_ghostty_term()`
- [ ] Copy + adapt `ghostty-term.el` to `lisp/ghostty-term.el`
- [ ] `./configure --with-ghostty-term && make` succeeds
- [ ] `src/emacs -Q --eval '(ghostty-term)'` works
- [ ] `htop`, `vim` work inside the terminal
- [ ] `make check` has no regressions
- [ ] Building WITHOUT `--with-ghostty-term` still works

### D.5 Key Decisions

- C, not Zig/Rust (ghostling proves the API)
- Static link `libghostty-vt.a` (zero deps)
- Render in elisp (crash isolation), escalate to C if needed
- PTY in C via `forkpty()` (same as ghostling)
- Deferred module loading (Phase 1)
- Pre-built `.a` for Phase 2 (no Zig dep in Emacs build itself)

### D.6 Risks

| Risk | Mitigation |
|---|---|
| libghostty-vt API instability | Pin to commit; headers say "WIP" |
| Zig build dep | Pre-built archive; Zig only needed to rebuild |
| DEFUN conversion bugs | Keep dynamic module working in parallel |

### D.7 Known Deferred Issues

- PTY write-back EAGAIN buffering (rare)
- Async child reaping (current 500ms sync block on destroy)
- Shifted punctuation via Kitty keyboard protocol
- Integer-packed face cache keys (perf micro-optimization)

---

## 5. Track E -- forge.el Two-Buffer UX

### E.1 Goal

`M-x forge-chat` opens an ERC-style two-buffer layout consuming Track B's
`--frontend=json`. Output buffer (read-only, markdown-fontified, tool calls
as collapsible blocks) + input buffer (full Emacs editing, `C-c C-c` send).

### E.2 Relationship to Existing Elisp

Extends existing `forge-code.el` v1.0.0 at `~/.emacs.d/lisp/forge-code.el`.
Does NOT greenfield -- builds on session management, agent cycling, and
keybinding infrastructure already there.

### E.3 Tasks

- [ ] Create `forge-chat.el` extending `forge-code.el`
- [ ] Output buffer: `forge-chat-output-mode` (special-mode, markdown faces)
- [ ] Input buffer: `forge-chat-input-mode` (text-mode, `C-c C-c` send)
- [ ] Process management: `make-process` with `--frontend=json`
- [ ] NDJSON parser: process filter splits lines, dispatches events
- [ ] Chunk events -> append to output with markdown fontification
- [ ] Tool call events -> collapsible overlays with file link buttons
- [ ] Select events -> `completing-read` or transient menu
- [ ] Usage events -> mode-line tokens/cost display
- [ ] History ring: `M-p`/`M-n` for previous/next submissions
- [ ] Window layout: side-window for input (5 lines bottom)
- [ ] Integration with existing `forge-code-*` keybindings

---

## 6. Track F -- Homebrew Formula Integration

### F.1 Goal

Modify `~/mysrc/homebrew-emacs-plus/` formula for `emacs-plus@mymain` to:

1. Build and install `libghostty-vt.a` (from ghostty source)
2. Compile Emacs with `--with-ghostty-term` (Track D Phase 2)
3. Install the `forge` binary alongside Emacs
4. Install `ghostty-term.el` and `forge-chat.el` to site-lisp

### F.2 Dependencies

- Track D Phase 2 complete (ghostty-term compiled into Emacs)
- Track E complete (forge-chat.el)
- Zig 0.15.x as build dependency (for libghostty-vt)

### F.3 Tasks

- [ ] Add Zig build dep to formula
- [ ] Add build step: `zig build lib-vt` in ghostty source
- [ ] Pass `--with-ghostty-term` to Emacs configure
- [ ] Pass `-I` / `-L` flags for ghostty headers and lib
- [ ] Install forge binary to `#{prefix}/bin/`
- [ ] Install elisp to `#{prefix}/share/emacs/site-lisp/`
- [ ] Test: `brew install emacs-plus@mymain` from scratch

---

## 7. Future: TOON Encoding (low priority)

TOON (`~/mysrc/toon-spec/`, `~/mysrc/toon/`) is an alternative structured
format. Consider as optional content-encoding inside the JSONL envelope for
heavy payloads (tool results, batch file listings). Evaluate after Track E
ships and real usage data exists.

JSONL remains the default wire protocol. TOON would be a `content-encoding`
header within the JSONL envelope, not a replacement.

---

## 8. Completion Criteria

The project is **done** when:

1. `./configure --with-ghostty-term && make` builds Emacs with Ghostty terminal
2. `M-x ghostty-term` opens a production-quality terminal (colors, Unicode, resize)
3. `M-x forge-chat` opens a two-buffer Forge UI (Track B JSON protocol)
4. `brew install emacs-plus@mymain` does all of the above from scratch
5. `htop`, `vim`, `forge` all work inside the Ghostty terminal
6. Standard Emacs `make check` passes with zero regressions
