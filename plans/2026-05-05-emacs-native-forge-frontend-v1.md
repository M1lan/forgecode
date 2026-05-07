# Emacs‑Native Forge Frontend — Three Tracks From Cheap To Nuclear

> Goal (your words): "I no longer want to use eat / vterm to talk to Forge from
> inside Emacs. The #1 annoyance is the input line — it has to be a normal
> Emacs buffer with full editing. Look at how `erc` and `eshell` do it: big
> output buffer + small input buffer. Either make Forge work with dumb
> terminals / comint, or make Forge speak directly to Emacs over a clean
> protocol, or — worst case — embed Forge inside Emacs as a native module."

This plan answers that as **three independent tracks** ordered by cost. Pick
one, two, or all three; they compose. Track A unblocks you in days. Track B is
the durable answer. Track C is the "no compromises" answer if B's IPC ever
feels heavy.

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

## 2. Track A — "Dumb terminal" / comint mode (cheap, days)

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

## 3. Track B — JSON‑line frontend + first‑class `forge.el` (right answer, weeks)

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

## 4. Track C — Native Emacs dynamic module (nuclear, months)

> **Outcome**: `forge.so` (a Rust dylib built against `emacs-module.h`) is
> loaded by Emacs. No subprocess. Elisp calls into Rust, Rust calls back into
> Elisp via the module API. The "rewrite Forge in C and integrate it into the
> core of Emacs" idea, modernised.

### C.1 What it would look like

- Use the [`emacs`](https://crates.io/crates/emacs) crate (Rust bindings to
  `emacs-module.h`).
- Build a new crate `crates/forge_emacs/` that re‑exports a small surface:
  `(forge-init)`, `(forge-submit STRING)`, `(forge-cancel)`,
  `(forge-set-callback FN)`. Internally calls into `forge_app` / `forge_api`.
- All streaming flows through Elisp callbacks: Rust calls
  `funcall(callback, event)` for each chunk/tool/selector. The callbacks run
  on the Emacs main thread (Emacs modules require this), so streaming chunks
  must be queued and drained from a timer or process sentinel.
- The Tokio runtime runs on a background OS thread inside the module; events
  are pushed through an MPSC and drained into Elisp via `make-pipe-process`
  or a poll timer.

### C.2 Why park it

- **Build complexity**: Emacs dynamic modules ship as `.so`/`.dylib`/`.dll`
  per platform; you need a per‑platform CI matrix.
- **Crash isolation gone**: a Rust panic in the module can take Emacs with
  it. Subprocess in B is naturally isolated.
- **Rust async + Emacs main thread**: tokio + module callbacks is doable but
  fiddly; you'll re‑invent half of `make-process`'s lifecycle.
- **Marginal latency win**: B over a local pipe is already <1 ms per event.
  Module direct‑call latency is microseconds; you don't need it.
- **All of Forge's deps come along**: rustls, hyper, etc., all loaded into
  Emacs's address space. Surface area for breakage explodes.

C is worth doing only if B's process model proves inadequate (e.g. you want
to run Forge against an in‑Emacs buffer with zero‑copy region passing, or you
want Forge to share state with a Magit invocation in the same process). Until
then, B wins on every axis.

### C.3 Tasks (sketched, not committed)

- [ ] PoC crate `crates/forge_emacs/` exposing `forge-init`, `forge-eval`.
- [ ] Decide on async bridge: `make-pipe-process` vs polling timer.
- [ ] Per‑platform build matrix: macOS arm64/x86, Linux x86_64, Windows.
- [ ] Crash/panic guard at the FFI boundary.
- [ ] Decide what subset of `forge_main` is in‑module vs library.

---

## 5. Cross‑track work that pays off in any track

These are uncontroversial cleanups Track A needs and B/C inherit:

1. **Hoist input behind a trait.** `Console` becomes `Box<dyn UserInput>` in
   `UI`. Pure refactor, no behaviour change.
2. **Hoist selector behind a trait.** `forge_select` exposes `Selector` with
   the four operations (`input`, `select`, `multi`, `confirm`); reedline impl
   stays as `CrosstermSelector`.
3. **Tame ANSI colour at one switch.** Single function in `forge_display` /
   `forge_spinner` reads a `ColorMode { Always, Auto, Never }` and sets
   `colored::control::set_override` once at startup.
4. **`Spinner` → enum**, `Animated | Quiet | Status(EventEmitter)`. Picks at
   construction.
5. **Document the existing `--prompt` + `--conversation-id` pattern** in
   `docs/` so users have a path *today* (as A ships).

---

## 6. Decision gates

- **Gate A → B**: ship A, use it for two weeks. If you're still wishing for
  clickable file links, foldable tool calls, or richer selectors, B is
  justified. If A is "good enough", deprioritise B.
- **Gate B → C**: ship B. If you measure end‑to‑end input → first‑chunk
  latency >50 ms attributable to the pipe (it won't be), or you find yourself
  wanting Forge state in the same address space as Magit/Project.el, then C.
  Otherwise leave it.

---

## 7. What I need from you to start

1. **Pick the starting track** (recommend A → B; skip C unless you really
   want it).
2. **Confirm the comint UX is acceptable for v1** (single Emacs window
   running `forge-comint`, single output+input buffer with comint's standard
   layout). The two‑buffer erc/eshell shape only arrives in B.
3. **Confirm protocol versioning policy for B** (recommend: ship as `v0`
   behind `--unstable` for ~4 weeks, then promote to `v1`).

That's it — no further information needed to begin Track A. The Forge source
is fully owned by us; the Emacs source under `../emacs/` is only needed if we
go to Track C (we'd reference `src/emacs-module.h` for the FFI signatures).
