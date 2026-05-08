# Emacs‑Native Forge + Ghostty Integration — Master Plan

> **Long‑term vision**: Forge AND Ghostty are integral parts of the user's
> custom GNU Emacs branch (`mymain` at `~/mysrc/emacs/`). A single
> `brew install emacs-plus@mymain` (via `~/mysrc/homebrew-emacs-plus/`)
> compiles Emacs with both capabilities baked in. The project is finished
> when:
>
> 1. **Forge** talks to Emacs over a first-class protocol (Track B JSON)
>    with a native `forge.el` two-buffer UX — no eat/vterm.
> 2. **Ghostty** terminal emulation is available inside Emacs as a
>    proper terminal buffer backed by libghostty-vt — replacing vterm
>    with production-quality VT emulation (full color, Unicode, Kitty
>    keyboard/graphics, mouse tracking, reflow).
> 3. Both are compiled into `emacs-plus@mymain` via the homebrew formula
>    with no external runtime dependencies beyond what's already linked.

## Working directories

| Path | Role |
|---|---|
| `~/mysrc/forgecode/` | Forge source (branch `emacs-native-frontend-track-a`) |
| `~/mysrc/emacs/` | GNU Emacs source (branch `mymain`, up-to-date) |
| `~/mysrc/ghostty/` | Ghostty terminal source (includes libghostty, libghostty-vt) |
| `~/mysrc/ghostling/` | Minimal single-file C terminal on libghostty-vt + Raylib — **reference impl** for Emacs integration |
| `~/mysrc/homebrew-emacs-plus/` | Homebrew formula (branch `mymain`) |
| `~/.emacs.d/` | User's Emacs configuration (`lisp/forge-*.el`) |
| `~/forge/` | Forge runtime configuration |

## Current build command (reference)

```
CFLAGS='-O3 -DFD_SETSIZE=10000 -DDARWIN_UNLIMITED_SELECT -I/opt/homebrew/opt/sqlite/include -I/opt/homebrew/opt/gcc/include -I/opt/homebrew/opt/libgccjit/include'
LDFLAGS='-L/opt/homebrew/opt/sqlite/lib -L/opt/homebrew/lib/gcc/15 -I/opt/homebrew/opt/gcc/include -I/opt/homebrew/opt/libgccjit/include'
brew install emacs-plus@31 --with-xwidgets --with-dragon-icon \
  --disable-dependency-tracking --disable-silent-rules \
  --enable-locallisppath=/opt/homebrew/share/emacs/site-lisp \
  --with-native-compilation=aot --with-xml2 --with-gnutls \
  --without-compress-install --without-dbus --with-imagemagick \
  --with-modules --with-rsvg --with-webp --with-ns \
  --disable-ns-self-contained --with-no-titlebar-and-round-corners
```

---

## Status (revised 2026-05-08)

| Track | State | Notes |
|---|---|---|
| **A — comint frontend** | ✅ **shipped** | Branch `emacs-native-frontend-track-a`, commits `203427cfc` and `d08ad2d42`. Verified end‑to‑end. |
| **B — JSON line protocol** | ✅ **shipped (behind `--unstable`)** | Same branch, commits `f5b336d43`, `5f16299e7`, `785ae4916`. Protocol v1, tool events, usage events, native selector round‑trip. 2621 tests green. |
| **C — Emacs dynamic module (Forge)** | 🅿 **parked** | Track B over a local pipe is already <1 ms per event. See §4 for resumption guide. |
| **D — Ghostty terminal in Emacs** | 🔧 **Phase 1 in progress** | C module built, reviewed, fixed (15 issues), benchmarked. `~/mysrc/emacs-ghostty-module/`. Next: `ghostty-term.el`. See §8. |
| **E — Forge.el two-buffer UX** | 🆕 **next up** | The elisp client that consumes Track B's JSON protocol. ERC-style output+input buffers. See §9. |
| **F — Homebrew formula integration** | 🆕 **pending** | Modify `emacs-plus@mymain` formula to build with libghostty-vt + install forge binary. See §10. |

→ **If resuming, jump to [§7 Resumption Guide](#7-resumption-guide).**

---


## 0. What's actually in the way today

Findings from a read‑through of `crates/forge_main/`, `crates/forge_select/`,
`crates/forge_spinner/`, and `crates/forge_domain/src/console.rs`:

| Concern | Location | Status |
|---|---|---|
| Output is **already abstracted** behind a trait | `crates/forge_domain/src/console.rs:6-15` (`ConsoleWriter`) | ✅ huge win — most output already routes through this |
| Streaming markdown writer is generic over `ConsoleWriter` | `crates/forge_main/src/stream_renderer.rs:108-165` | ✅ just plug a new sink |
| Spinner manager is generic over `ConsoleWriter` | `crates/forge_main/src/stream_renderer.rs:17-77`, `crates/forge_spinner/src/lib.rs` | ✅ same |
| Input uses **reedline + crossterm raw mode** | `crates/forge_main/src/editor.rs:7-105`, `crates/forge_main/src/input.rs:30-46` | ❌ requires a real PTY — this is the #1 blocker |
| `Console::set_buffer()` already exists | `crates/forge_main/src/input.rs:48-52` | ✅ pre‑fill hook is in place |
| Interactive selectors assume a TTY (`is_terminal()` checks) | `crates/forge_select/src/select.rs:79`, `multi.rs:29`, `input.rs:62`, `crates/forge_main/src/main.rs:96` | ❌ behave badly under Emacs comint |
| `--prompt` / `-p` already runs one‑shot non‑interactive | `crates/forge_main/src/cli.rs:21-22`, `crates/forge_main/src/ui.rs:377-392` | ✅ a poor‑man's Emacs integration already works (each turn = a fresh process) |
| `--conversation-id` resumes sessions | `crates/forge_main/src/cli.rs:40-41` | ✅ enables stitching one‑shots into a chat |
| Stream renderer uses `terminal_size()` for wrap width | `crates/forge_main/src/stream_renderer.rs:97-101` | ⚠ falls back to 80 cols if no TTY — fine, but worth wiring to an env var |
| Bracketed paste, ANSI colours, hinter, completion menu | `crates/forge_main/src/editor.rs:91-104` | ⚠ all reedline features that don't work under a dumb terminal |
| Spinner uses VT‑aware screen‑buffer tricks | `crates/forge_main/src/main.rs:24-44` (Windows comment), `forge_spinner` | ❌ leaves garbage in scrollback under non‑VT |

### Translation
- The **output half** is in good shape. `ConsoleWriter` is the seam we need; we
  can already redirect everything Forge prints to a sink we control.
- The **input half** is the real problem. Reedline owns the terminal in raw
  mode; under Emacs `eat`/`vterm` it works only because those packages emulate
  a real PTY. There is currently no code path that reads input as plain
  newline‑delimited text from stdin **interactively** (the `-p` and stdin‑pipe
  paths are one‑shot only — `crates/forge_main/src/main.rs:96-103`,
  `crates/forge_main/src/ui.rs:377-392`).
- The **prompt UI** (`crates/forge_main/src/prompt.rs`) and the spinner emit
  ANSI status decorations that comint mode would render as literal escape
  garbage.

So the smallest credible change is: **add a non‑raw‑mode interactive
frontend** that (a) reads input one line at a time from stdin, (b) emits
plain‑text or framed output, (c) suppresses raw‑mode features (spinner,
crossterm selectors, ANSI colour by default).

---

## 1. Recommendation up front

Do **Track A** now (days). It gives you a usable Emacs‑native UX immediately
with comint and zero protocol design.

Schedule **Track B** next (weeks). It is the right long‑term answer: a
documented JSON line protocol (`--frontend=json`) that any editor can drive,
and a real `forge.el` major mode with the erc/eshell two‑buffer UX you asked
for.

**Park Track C** unless Track B's process model proves insufficient. Embedding
Rust as a dynamic Emacs module is a big maintenance commitment and only pays
off if you hit a wall (latency, lifecycle, GIL‑style contention) that B can't
solve.

---

## 2. Track A — "Dumb terminal" / comint mode (cheap, days) ✅ SHIPPED

> **Outcome**: `M-x forge-comint` opens a comint buffer running
> `forge --frontend=comint`. The output area is the comint buffer. The input
> area is the comint input line at the bottom — full Emacs editing,
> minibuffer history, `M-p`/`M-n`, `comint-input-ring`, etc. No eat, no vterm.

### A.1 Forge‑side changes

1. **CLI flag** in `crates/forge_main/src/cli.rs`:
   - `--frontend=tty|comint|json` (default `tty`).
   - Auto‑detect if not set: if `INSIDE_EMACS` env var is non‑empty **and**
     contains `comint`, default to `comint`. If it contains `vterm`/`eat`,
     keep `tty`. Else `tty`.
   - Also honour `TERM=dumb` → force `comint`.

2. **New module** `crates/forge_main/src/comint.rs`:
   - A line‑buffered stdin reader that replaces `Console::prompt()`'s reedline
     loop when `frontend == comint`.
   - Reads `BufReader::new(stdin()).read_line()` loop. Each non‑empty line is
     submitted as a turn. Empty line = ignore. `EOF` = exit. A configurable
     "continuation marker" (e.g. trailing backslash, or a `>>` line opener)
     enables multi‑line input — but the v1 ships with single‑line only. Multi‑
     line via `comint-send-input` after `RET` works on the Emacs side because
     comint sends the full region, not per‑char.
   - No raw mode, no crossterm events, no bracketed paste.
   - Re‑uses the existing `Console::set_buffer()` semantics where possible so
     features like `/edit` still pre‑fill content (in comint mode, "pre‑fill"
     becomes `(insert ...)` into the input ring via an event we print —
     deferred to A.4 below).

3. **Wire up at construction** in `crates/forge_main/src/ui.rs:284-296`:
   - If `frontend == comint`, construct a `CominInput` instead of `Console`,
     behind a small enum or trait `Input { fn prompt(...) -> AppCommand }`.
   - Smallest viable refactor: make `console` field on `UI` a
     `Box<dyn UserInput>` where `UserInput` exposes `prompt(&self,
     &mut ForgePrompt) -> Result<AppCommand>` and `set_buffer(&self, String)`.
     Both `Console` (reedline) and `CominInput` implement it.

4. **Tame the output side for dumb terminals**:
   - In `comint` mode, set `colored::control::set_override(false)` and skip
     the `with_ansi_colors(true)` calls. Most ANSI is already conditional on
     `colored`'s detection, so this is one toggle.
   - `crates/forge_main/src/stream_renderer.rs:97-101`: when `frontend ==
     comint`, take wrap width from `$COLUMNS` (Emacs sets this on its comint
     subprocesses) or default 100, ignore `terminal_size`.
   - `forge_spinner`: in `comint` mode, replace the animated spinner with a
     single static line `[…]` printed once per phase change, or with **no
     spinner at all** plus a `[forge: thinking]` line when the model starts
     streaming. Decision: ship "no spinner" first; revisit if you miss it.
     Implementation: a `Spinner` enum with `Animated` and `Quiet` variants,
     selected at construction in `crates/forge_main/src/ui.rs:280-296`.
   - `crates/forge_select/src/{select,multi,input,confirm}.rs`: wrap each
     `is_terminal()` guard with: "if comint frontend, **fall back to
     line‑oriented prompt**" — print the question + numbered options, read a
     line, parse. Today these crates already check `is_terminal()` and bail;
     we replace the bail with a `LineSelector` impl that round‑trips through
     stdin. This is the only place where comint mode needs more than a flag —
     the selectors otherwise crash or print garbage.

5. **Banner / prompt decorations** in `crates/forge_main/src/prompt.rs` and
   `crates/forge_main/src/banner.rs`:
   - In comint mode, suppress ANSI styling and avoid cursor‑movement escapes.
     Print a plain‑text prompt prefix like `forge> ` so comint can pick it up
     as `comint-prompt-regexp`.

### A.2 Emacs‑side changes — `forge-comint.el`

Single file, ~150 lines. Lives in your `~/.emacs.d/lisp/` (not in this repo).

```elisp
(define-derived-mode forge-comint-mode comint-mode "Forge"
  "Major mode for chatting with Forge in a comint buffer."
  (setq comint-prompt-regexp "^forge> ")
  (setq comint-prompt-read-only t)
  (setq-local comint-input-sender #'forge-comint--send)
  ;; Render markdown read-only, fontify code blocks, etc.
  (add-hook 'comint-output-filter-functions #'forge-comint--fontify nil t))

(defun forge-comint ()
  (interactive)
  (let* ((default-directory (or (project-root (project-current)) default-directory))
         (buf (get-buffer-create "*forge*"))
         (process-environment (cons "INSIDE_EMACS=comint" process-environment)))
    (with-current-buffer buf
      (unless (comint-check-proc buf)
        (apply #'make-comint-in-buffer "forge" buf
               (executable-find "forge")
               nil
               '("--frontend" "comint")))
      (forge-comint-mode))
    (pop-to-buffer buf)))
```

Optional polish:
- Bind `C-c C-c` to `comint-interrupt-subjob` (maps to the existing Ctrl+C
  handling in `crates/forge_main/src/ui.rs:381-389` — already cancels the
  current turn cleanly).
- Bind `C-c C-l` to clear via `(comint-clear-buffer)`.
- Use `markdown-mode`'s fontification on the output region.

### A.3 Tasks (atomic)

- [ ] Add `--frontend` flag to `Cli` in `crates/forge_main/src/cli.rs:13-68`.
- [ ] Add `INSIDE_EMACS` / `TERM=dumb` autodetect in `crates/forge_main/src/main.rs` before building `UI`.
- [ ] Define `trait UserInput` in `crates/forge_main/src/input.rs`.
- [ ] Implement `CominInput` reading line‑buffered stdin; suppress raw mode.
- [ ] Switch `UI.console` field to `Box<dyn UserInput>`; pick impl by `--frontend`.
- [ ] Add `Spinner::Quiet` variant in `forge_spinner`; pick by frontend.
- [ ] Disable ANSI colours in comint mode (`colored::control::set_override(false)`).
- [ ] Wrap `is_terminal()` selector guards with comint line‑prompt fallback in `forge_select`.
- [ ] Plain `forge> ` prompt in `crates/forge_main/src/prompt.rs` for comint mode.
- [ ] Snapshot tests: `cargo insta test` for the four `forge_select` widgets in `comint` mode.
- [ ] Smoke test: `INSIDE_EMACS=comint forge --frontend=comint` from a plain shell, type a turn, see streaming text without ANSI garbage.
- [ ] `forge-comint.el` skeleton in `~/.emacs.d/lisp/` (out of scope for this repo).

### A.4 Known limitations of Track A

- Streaming markdown is rendered as plain text (no live syntax highlighting in
  Emacs). Acceptable v1; A.4 refit can add a `comint-output-filter-functions`
  hook to apply `markdown-mode` faces.
- No structured events for tool calls — they appear as plain printed lines.
  You won't get clickable file links until Track B.
- `set_buffer()` pre‑fill (used by `/edit`, commit flows) requires a side‑
  channel — comint can't easily inject text into its own input ring from the
  subprocess. Workaround: print a marker line `[forge:prefill]TEXT[/]` and
  have `forge-comint--fontify` strip it and call `(insert TEXT)` into the
  input area. Optional for v1.

### A.5 Risk

Low. Reedline path is untouched in TTY mode. All changes are gated behind
`--frontend=comint`. Reverting is trivial.

---

## 3. Track B — JSON‑line frontend + first‑class `forge.el` (right answer, weeks) ✅ SHIPPED (Rust side)

> **Outcome**: `forge --frontend=json` reads NDJSON requests on stdin, writes
> NDJSON events on stdout. `forge.el` provides two buffers: `*forge:output*`
> (read‑only, fontified, scrolling history) and `*forge:input*` (regular Emacs
> buffer with `RET` bound to send). Tool calls, status updates, selectors, and
> diffs all become typed events the editor can render natively (clickable
> links, fold/unfold, inline diffs).

### B.1 Why this is the right shape

- **Editor‑agnostic**: same protocol works for Neovim, Helix, Zed, VS Code.
- **Decouples rendering from CLI**: the markdown stream still works in TTY mode;
  JSON is just a second sink wired to the existing `ConsoleWriter` seam.
- **Cancellable, resumable, scriptable**: structured events make it trivial
  to add per‑message cancel, retry, fork, and replay without inventing a UX
  for each.
- **Natural test surface**: NDJSON snapshots replace ad‑hoc terminal capture
  in `cargo insta test`.

### B.2 Wire protocol (v0 sketch)

One JSON object per line, both directions. Schema versioned via `"v": 1`.

**Client → Forge** (from Emacs):
```jsonl
{"v":1,"id":"c1","kind":"submit","text":"refactor foo to bar","attachments":[]}
{"v":1,"id":"c2","kind":"cancel","target":"c1"}
{"v":1,"id":"c3","kind":"select_response","target":"sel-7","value":"yes"}
{"v":1,"id":"c4","kind":"set_buffer","text":"…"}
{"v":1,"id":"c5","kind":"command","name":"new"}
```

**Forge → Client** (to Emacs):
```jsonl
{"v":1,"kind":"ready","conversation_id":"…","agent":"forge","model":"claude-opus-4-7"}
{"v":1,"kind":"turn_start","turn_id":"t1"}
{"v":1,"kind":"chunk","turn_id":"t1","stream":"assistant","text":"Looking at "}
{"v":1,"kind":"chunk","turn_id":"t1","stream":"assistant","text":"`foo.rs`…"}
{"v":1,"kind":"reasoning","turn_id":"t1","text":"…"}
{"v":1,"kind":"tool_call","turn_id":"t1","tool_id":"k1","name":"read","args":{"path":"foo.rs"}}
{"v":1,"kind":"tool_result","turn_id":"t1","tool_id":"k1","ok":true,"summary":"42 lines"}
{"v":1,"kind":"select","sel_id":"sel-7","prompt":"Apply patch?","options":["yes","no","diff"]}
{"v":1,"kind":"status","level":"info","text":"streaming"}
{"v":1,"kind":"usage","input_tokens":12345,"output_tokens":678,"cost":0.04}
{"v":1,"kind":"turn_end","turn_id":"t1"}
{"v":1,"kind":"error","text":"…","cause":"…"}
```

### B.3 Forge‑side changes

1. **Frontend trait** in `crates/forge_main/src/lib.rs` (new module
   `frontend.rs`):
   ```rust,ignore
   pub trait Frontend: Send + Sync {
       fn next_event(&self) -> Result<ClientEvent>;     // blocking read of one ClientEvent
       fn emit(&self, event: ServerEvent) -> Result<()>; // write one ServerEvent
   }
   ```
   Two impls: `TtyFrontend` (today's behaviour, wraps `Console` + spinner +
   markdown stream renderer) and `JsonFrontend` (NDJSON over stdin/stdout).

2. **`JsonConsoleWriter`** implementing `forge_domain::ConsoleWriter`. Buffers
   bytes from the markdown stream, splits on newlines, wraps each chunk in a
   `chunk` event. Plug it into `StreamingWriter` exactly where today's
   `StdoutPrinter` plugs in — all the existing rendering machinery in
   `crates/forge_main/src/stream_renderer.rs:108-165` keeps working unchanged.

3. **Selector adapter** in `forge_select`: when running under `JsonFrontend`,
   `select`/`multi`/`confirm`/`input` emit a `select` event and block on a
   matching `select_response` from the client. Implemented as a thin
   `Selector` trait already implied by the four widgets.

4. **Tool‑call adapter** in `crates/forge_main/src/tools_display.rs` and
   `crates/forge_main/src/sync_display.rs:1-177`: in JSON mode, instead of
   pretty‑printing tool invocations, emit `tool_call` / `tool_result` events.
   The same data is already collected — the change is the sink.

5. **Spinner**: in JSON mode, the spinner becomes `status` events (`thinking`,
   `streaming`, `done`).

6. **Replace `read_line` loop in main**: in JSON mode, the input loop in
   `crates/forge_main/src/ui.rs:397-443` becomes "block on next `submit`
   ClientEvent, dispatch as turn".

7. **Cancellation**: `Ctrl+C` handling at `crates/forge_main/src/ui.rs:381-389`
   stays. JSON `cancel` events route to the same cancel signal.

### B.4 Emacs‑side — `forge.el` (separate elisp project, not in this repo)

Two‑buffer UX, ERC‑style:

- `*forge:output*` — major mode `forge-output-mode` derived from
  `special-mode`. Read‑only. Fontifies via `markdown-mode` faces. Tool
  calls render as collapsible blocks (overlays). File mentions are buttons.
- `*forge:input*` — major mode `forge-input-mode` derived from `text-mode`.
  Full normal Emacs editing. `RET` = newline, `C-c C-c` = send, `C-c C-l` =
  clear, `C-c C-k` = cancel current turn, `M-p`/`M-n` = previous/next
  submission, history persisted across sessions.
- Communication: a single `make-process` running `forge --frontend=json`,
  filter parses NDJSON line‑by‑line.
- Layout: `display-buffer-in-side-window` puts input in a 5‑line bottom side
  window, output fills the rest. Window config persisted.
- Selectors: `select` events open a `read-multiple-choice` or a `transient`
  menu and the answer goes back as `select_response`.
- Status line: `usage` events update mode‑line tokens/cost.

This buys you **exactly** the erc/eshell shape you described — output big,
input small, both native Emacs.

### B.5 Tasks

- [ ] Define `Frontend`, `ClientEvent`, `ServerEvent` types + serde derives in `crates/forge_main/src/frontend.rs`.
- [ ] `TtyFrontend` wrapping today's `Console` + `StreamingWriter`. No behaviour change in TTY mode.
- [ ] `JsonFrontend` reading NDJSON from `stdin`, writing to `stdout`.
- [ ] `JsonConsoleWriter: ConsoleWriter` adapter for streaming markdown.
- [ ] `Selector` trait in `forge_select`; per‑frontend impls.
- [ ] Tool‑call event emission in `tools_display.rs` and `sync_display.rs`.
- [ ] Status/usage events from `forge_spinner` and the usage path in `crates/forge_main/src/ui.rs:298-336`.
- [ ] Cancel/select wiring through `ui.rs` event loop.
- [ ] Versioned schema doc in `docs/frontend-protocol.md`.
- [ ] Insta snapshot tests for protocol round‑trips covering: turn, tool call, selector, error, cancel, usage.
- [ ] CI smoke test: spawn `forge --frontend=json`, drive a minimal session, assert event sequence.
- [ ] Ship `forge.el` as a separate package (out of repo).

### B.6 Risks & decisions

- **Schema lock‑in**: ship as v0 explicitly unstable, hide behind
  `--frontend=json --unstable` for the first month so we can iterate without
  breaking editor packages.
- **Backpressure**: stdin/stdout pipes are sufficient for token‑per‑chunk
  streams. If large tool results saturate, switch to a length‑prefixed framing
  later — but NDJSON is fine for v0.
- **Cross‑editor reuse**: keep schema editor‑agnostic. Don't bake Emacs idioms
  into event names.
- **Telemetry/log channels**: `tracing` already writes to a separate log path
  (`crates/forge_main/src/main.rs:294`). Stays unchanged.
- **Windows**: NDJSON over stdin/stdout works the same on Windows. No
  raw‑mode dance needed because we don't enable VT.

### B.7 Why not just use `--prompt` per turn?

You can today, and Emacs‑side that gives you exactly the UX you want. But:
- Per‑turn process startup adds ~hundreds of ms (rustls init, config parse,
  cache rebuild — see `crates/forge_main/src/ui.rs:447-458`).
- Streaming becomes per‑process, no continuity for tool approval flows.
- Selectors abort because there's no TTY (`crates/forge_main/src/main.rs:96`).
- You lose conversation context unless you juggle `--conversation-id` from
  Emacs and accept a fresh chat ring per call.

Track B is `--prompt`‑per‑turn done right: one long‑lived process, a real
protocol, structured events.

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

### C.1 What it would look like

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

## 5. Cross‑track work that pays off in any track

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

## 6. Decision gates

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

---

## 8. Track D — Ghostty Terminal in Emacs (the big one)

> **Outcome**: `M-x ghostty-term` opens a buffer backed by libghostty-vt.
> Full 24-bit color, Unicode with grapheme clusters, Kitty keyboard/graphics
> protocol, mouse tracking, text reflow on resize, scrollback — all the
> features Ghostty has, rendered inside an Emacs buffer. Replaces vterm/eat
> as the terminal of choice.

### 8.1 Architecture overview

```
┌─────────────────────────────────────────────────┐
│ Emacs (C core, branch mymain)                   │
│                                                 │
│  ghostty-term.c  ←── new C source file          │
│  ┌──────────────────────────────────────────┐   │
│  │  GhosttyTerminal (libghostty-vt opaque)  │   │
│  │  PTY master fd (forkpty)                 │   │
│  │  Emacs buffer ↔ render state sync        │   │
│  └──────────────────────────────────────────┘   │
│  ghostty-term.el ←── elisp major mode           │
│                                                 │
│  Links against: libghostty_vt.a (static)        │
└─────────────────────────────────────────────────┘
```

Two integration strategies evaluated:

| Strategy | Pros | Cons | Verdict |
|---|---|---|---|
| **A: Emacs dynamic module** (`.dylib` loaded at runtime) | No Emacs source changes; `--with-modules` already enabled; can iterate without recompiling Emacs | Crash isolation is poor (panic = Emacs crash); needs per-platform build; must ship separately from Emacs | **Start here** — fastest iteration, lowest risk, proven pattern (vterm-module does exactly this) |
| **B: Compile into Emacs source tree** | Single binary; native Lisp_Object integration; no `.dylib` to manage; can use internal Emacs APIs (redisplay, faces, process) | Must patch `configure.ac`, `Makefile.in`, `src/Makefile.in`; harder to upstream; couples to Emacs internals | **End state** — migrate to this once the module works and the API surface stabilises |

**Decision: start with Strategy A (dynamic module), evolve to Strategy B.**

### 8.2 Reference implementation analysis (ghostling/main.c)

The ghostling demo is 1604 lines of C in a single file. It shows the
**complete** libghostty-vt consumer pattern:

1. **PTY lifecycle** (`main.c:43-96`): `forkpty()` → non-blocking master fd → child execs shell.
2. **Terminal creation** (`ghostty_terminal_new()`): columns, rows, allocator.
3. **Input loop** (`main.c:158-400`): Raylib key events → `ghostty_terminal_key_event()` / `ghostty_terminal_mouse_event()`.
4. **VT data feed** (`main.c:132-156`): read PTY → `ghostty_terminal_vt_write(terminal, buf, len)`.
5. **Render loop** (`main.c:400+`): iterate render state → draw cells with font.
6. **Resize** (`main.c`): `ghostty_terminal_resize()` + `TIOCSWINSZ` on PTY.

For Emacs, we replace Raylib with:
- **Windowing/rendering**: Emacs redisplay (faces, text properties, overlays).
- **Input**: Emacs keyboard/mouse events translated to Ghostty key/mouse events.
- **PTY**: Emacs's own `make-process` / process filter, or direct `forkpty` in C.

### 8.3 The dynamic module approach (Strategy A — do this first)

A C dynamic module (`.dylib` / `.so`) that:

1. **Compiles against** `emacs-module.h` (at `~/mysrc/emacs/src/emacs-module.h`)
   and `ghostty/vt.h` (at `~/mysrc/ghostty/include/ghostty/vt.h`).
2. **Links** `libghostty_vt.a` statically (built via `zig build lib-vt` in
   `~/mysrc/ghostty/`).
3. **Exports** to Emacs:
   - `(ghostty-term--init COLS ROWS)` → creates terminal + PTY, returns handle
   - `(ghostty-term--write HANDLE STRING)` → feed input to PTY
   - `(ghostty-term--key HANDLE KEY MODS)` → translate and encode key event
   - `(ghostty-term--mouse HANDLE EVENT X Y MODS)` → mouse event
   - `(ghostty-term--resize HANDLE COLS ROWS)` → resize terminal + PTY
   - `(ghostty-term--render HANDLE)` → return render state as a vector of
     cell descriptors (codepoint, fg, bg, attrs, row, col)
   - `(ghostty-term--destroy HANDLE)` → cleanup
   - `(ghostty-term--pty-fd HANDLE)` → return the PTY fd for Emacs process
     integration (`make-pipe-process` or `set-process-filter`)
4. **Rendering** is done in elisp: the module returns cell data, elisp
   paints the buffer using `insert` + text properties (face, fg/bg colors).
   This keeps the module small and crash-safe.

### 8.4 Build: libghostty-vt static library

```bash
cd ~/mysrc/ghostty
zig build lib-vt -Doptimize=ReleaseFast
# produces: zig-out/lib/libghostty_vt.a
# headers:  include/ghostty/vt.h  +  include/ghostty/vt/*.h
```

### 8.5 Module project structure

```
~/mysrc/emacs-ghostty-module/        (new repo or subdir of ~/mysrc/emacs/)
  Makefile                           # or CMakeLists.txt
  ghostty-term-module.c              # the C dynamic module
  ghostty-term.el                    # elisp major mode
  README.md
```

Alternatively, this can live directly in `~/mysrc/emacs/src/` when we move to
Strategy B (compile into Emacs).

### 8.6 Tasks (Track D — atomic, ordered)

Phase 1: Standalone dynamic module (iterate fast)
- [x] Build libghostty-vt: `zig build lib-vt -Doptimize=ReleaseFast` in `~/mysrc/ghostty/` (7.5 MB `.a`)
- [x] Create module project: `~/mysrc/emacs-ghostty-module/` (Makefile + C source)
- [x] Write `ghostty-term-module.c`: init, write, destroy, pty-fd, process, render, cursor, resize, scroll, key, check-child, version (1070 lines C)
- [x] Compile: static-linked 1.5 MB `.dylib`, zero warnings (GCC 15 / clang)
- [x] Smoke test: `(module-load ...)` + full lifecycle verified in Emacs (version, init, process, render, cursor, write, resize, destroy)
- [x] Code review: critic + code-reviewer agents found 15 issues (2 critical, 6 warning, 7 info)
- [x] Fix all 15 issues: instance lifecycle (in_use flag, slot reuse), memory safety (face_vec clamp, dynamic codepoints, NULL checks), error handling (non_local_exit_check on all extract paths), signal_error via non_local_exit_signal, child reaping (poll+SIGKILL), check-child function, dirty-row optimization, integer range validation, Makefile portability
- [x] Re-verify: 11 functional tests + 5 error-path tests pass (invalid handle, double-destroy, overflow, slot reuse)
- [x] Performance benchmark: 120x40 full render = **0.01 ms** (500x under 5ms target), clean render = **0.001 ms**
- [x] Write `ghostty-term.el` (852 lines): major mode, 60fps timer render loop, RLE face batching, key translation, input dispatch, cursor overlay, resize, scrollback, bracketed paste, login shell
- [x] Review round 2: critic (ITERATE) + code-reviewer (REQUEST CHANGES) found 6 critical + 8 warning issues
- [x] Fix all issues: deferred module load, resize hook ref-counting, face cache eviction (4096 cap), nil handle guard, timer error protection, paint-row bounds check, C-c C-z/C-\/C-y bindings, login shell prefix, signal_error list format, C render nil-for-empty
- [x] Byte-compile: zero warnings. Integration test: 15/15 pass (module lifecycle, render, key translation, face cache, instance counter)
- [x] Installed to `~/.emacs.d/lisp/` (ghostty-term-module.dylib + ghostty-term.el)
- [ ] Interactive test: restart Emacs, `M-x ghostty-term`, verify colors/input/htop/vim/tmux
- [ ] Add mouse click/drag support (mouse encoder integration)
- [ ] Add CJK/wide-character face alignment

Phase 2: Compile into Emacs source tree (Strategy B)
- [ ] Copy `ghostty-term-module.c` → `~/mysrc/emacs/src/ghostty-term.c`
- [ ] Patch `~/mysrc/emacs/src/Makefile.in` to compile and link `ghostty-term.c` + `libghostty_vt.a`
- [ ] Patch `~/mysrc/emacs/configure.ac` to add `--with-ghostty-term` flag
- [ ] Convert module API calls (`env->make_*`) to native Lisp_Object / DEFUN macros
- [ ] Integrate with Emacs process/PTY infrastructure (`process.c` patterns)
- [ ] Move `ghostty-term.el` to `~/mysrc/emacs/lisp/ghostty-term.el`
- [ ] Verify: `./configure --with-ghostty-term && make && src/emacs -Q -e '(ghostty-term)'`

### 8.7 Key design decisions for Track D

- **Static link libghostty-vt**: no `.dylib` dependency at runtime. The Zig
  build produces a self-contained `.a` with no libc dependency (it's
  `--nostdlib` by default). This is ideal for embedding.
- **C, not Zig/Rust**: the module is pure C to match Emacs conventions.
  Ghostling already proves the full API is consumable from C.
  No FFI bridge needed — direct `#include <ghostty/vt.h>` calls.
- **Render in elisp, not C**: the module extracts cell data; elisp does the
  painting. This keeps the C side minimal and crash-safe. If perf is a
  problem, we can move rendering to C later (like vterm-module does).
- **PTY in C**: use `forkpty()` in the module (same as ghostling), expose
  the fd to Emacs. Emacs monitors the fd via its event loop. This avoids
  reinventing PTY management in elisp.

### 8.8 Risks

- **libghostty-vt API stability**: the header says "WARNING: incomplete,
  work-in-progress API." We pin to a specific commit (same as ghostling
  does: `fdb6e3d2c8543e2e756b7e07f44372efbc0fba4b`). Update deliberately.
- **Render performance**: vterm-module renders in C for speed. If elisp
  rendering is too slow, we escalate to C rendering. The module boundary
  makes this a contained change.
- **Zig build dependency**: building libghostty-vt requires Zig 0.15.x.
  For the homebrew formula, we pre-build the `.a` or add Zig as a build
  dep.

---

## 9. Track E — forge.el Two-Buffer UX

> **Outcome**: `M-x forge-chat` opens an ERC-style two-buffer layout
> consuming Track B's `--frontend=json`. Output buffer (read-only, markdown-
> fontified, tool calls as collapsible blocks) + input buffer (full Emacs
> editing, `C-c C-c` to send). Replaces the current `eat`-based
> `forge-code.el`.

### 9.1 Relationship to existing elisp

`~/.emacs.d/lisp/forge-code.el` v1.0.0 already provides session management,
`C-c F` prefix, agent selection, `*forge:<agent>:<project>*` buffer naming.
Track E extends this — does NOT greenfield.

### 9.2 Tasks (Track E — ordered)

- [ ] Write `forge-json.el` — NDJSON process filter that parses `ServerEvent`s
- [ ] Write `forge-output-mode` — `special-mode` derivative for the output buffer; markdown fontification via `markdown-mode` faces; tool calls as collapsible overlays; file mentions as buttons
- [ ] Write `forge-input-mode` — `text-mode` derivative; `C-c C-c` sends, `C-c C-k` cancels, `M-p`/`M-n` history
- [ ] Wire `make-process` to `forge --frontend=json --unstable` with the NDJSON filter
- [ ] Handle `select` events → `read-multiple-choice` or `transient` menu → send `select_response`
- [ ] Display `usage` events in the mode-line (tokens, cost)
- [ ] Layout: `display-buffer-in-side-window` (input 5-line bottom, output fills rest)
- [ ] Integrate with existing `forge-code.el` session management (reuse buffer naming, keybindings, agent switching)
- [ ] Test end-to-end: start forge.el, submit a turn, see streaming output, handle a tool call selector, see usage stats

### 9.3 Risk

Low. Track B wire protocol is already shipped and tested. This is pure elisp
work consuming a stable NDJSON stream. Can be iterated without touching the
Rust side.

---

## 10. Track F — Homebrew Formula Integration

> **Outcome**: `brew install emacs-plus@mymain` from
> `~/mysrc/homebrew-emacs-plus/` produces an Emacs binary with:
> - libghostty-vt statically linked (Track D Phase 2)
> - `ghostty-term.el` in the site-lisp path
> - `forge` binary installed alongside

### 10.1 Tasks (Track F — ordered)

- [ ] Modify `Formula/emacs-plus@31.rb` (or create `emacs-plus@mymain.rb`) to:
  - Add Zig as a build dependency (for libghostty-vt)
  - Clone/fetch ghostty source at the pinned commit
  - Run `zig build lib-vt -Doptimize=ReleaseFast`
  - Pass `--with-ghostty-term` to `./configure` (once Track D Phase 2 lands)
- [ ] Add a `forge` resource block that downloads the forge binary (or builds from source if Rust toolchain is available)
- [ ] Install `forge-*.el` and `ghostty-term.el` to `#{share}/emacs/site-lisp/`
- [ ] Test: `brew install --build-from-source emacs-plus@mymain` produces a working Emacs with both features
- [ ] Document the custom build flags in the formula

### 10.2 Dependencies

Track F depends on:
- Track D Phase 2 (ghostty-term compiled into Emacs source)
- Track E (forge.el files to install)
- A tagged forge release (or local build)

### 10.3 Risk

Medium. Homebrew formulas have strict conventions. Adding Zig as a build
dependency and a multi-step build (ghostty → Emacs) increases formula
complexity. May need to pre-build the static lib and distribute it as a
bottle.

---

## 11. Execution order and dependencies

```
Track A ─── ✅ done
Track B ─── ✅ done
                                    ┌─→ Track E (forge.el UX) ──────┐
                                    │                               │
                                    │   Track D Phase 1 (module) ───┤
                                    │     │                         │
                                    │     ▼                         │
                                    │   Track D Phase 2 (in-tree) ──┤
                                    │                               │
                                    └───────────────────────────────┘
                                                    │
                                                    ▼
                                            Track F (homebrew)
Track C ─── 🅿 parked (independent, unblock only if B proves insufficient)
```

**Recommended execution order:**
1. **Track D Phase 1** — standalone dynamic module. This is the most
   technically uncertain piece and needs to be de-risked first. Can be
   done in parallel with Track E.
2. **Track E** — forge.el two-buffer UX. Pure elisp, no Emacs recompilation
   needed. Highest daily-use value. Can be done in parallel with Track D.
3. **Track D Phase 2** — migrate module into Emacs source tree. Do this once
   the dynamic module is working and the API is stable.
4. **Track F** — homebrew formula. Final integration step; depends on D2+E.

### Future: TOON as alternative wire format (low priority)

TOON (Token-Oriented Object Notation, `~/mysrc/toon-spec/` spec v3.0,
`~/mysrc/toon/` reference impl) is a compact, human-readable encoding of the
JSON data model optimised for LLM token efficiency. Lossless JSON round-trip.

**JSONL vs TOON — when to use which:**

| Criterion | JSONL | TOON |
|---|---|---|
| **Machine parsing** | Native everywhere (every language, every tool) | Needs a dedicated parser; no ecosystem adoption yet |
| **Debuggability** | Readable but verbose; pipe through `jq` | More compact and arguably more readable for tabular data |
| **Token efficiency** | Baseline | ~30-50% fewer tokens for uniform arrays of objects (its sweet spot) |
| **Streaming** | One event per line, trivially splittable | Line-oriented too, but delimiter scoping rules add parser complexity |
| **Forge frontend wire** | Already shipped (Track B, v1) | Would be a v2 wire option |
| **Spec maturity** | RFC 8259 (decades-old standard) | Working Draft v3.0 (2025-11-24) |

**Recommendation:** Keep JSONL as the default wire format for the Forge
frontend protocol. TOON is interesting as an *optional* encoding for
payloads that are heavy on uniform structured data (e.g., large tool
results, batch file listings, multi-file diffs) where token savings
matter. The right place to introduce it is as a content-encoding option
inside the existing JSONL envelope — e.g., a `tool_result` event whose
`content_type` is `text/toon` instead of `text/plain`. This avoids
changing the framing protocol and lets consumers that don't understand
TOON fall back to JSON.

**When to revisit:** after Track E (forge.el) is shipping and we have
real usage data on which event kinds are token-heavy. Not before.

- [ ] (future) Evaluate TOON encoding for large tool results inside the JSONL protocol
- [ ] (future) Add `content_type: text/toon` support to `ServerEvent` payloads
- [ ] (future) Write a TOON decoder in elisp (or use the reference TS impl via a subprocess)

---

**Next immediate action:** Write `ghostty-term.el` (Track D Phase 1 remaining
task) — the C module is verified and fast. This is a pure-elisp task:
major mode, timer-driven render loop, input dispatch, face painting.
Track E can begin in parallel since it's independent.

