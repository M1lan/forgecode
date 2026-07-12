# forge-zsh — Lifecycle / Session / OSC-133 Model (for a NARROW TLA+ spec)

Scope: `shell-plugin/lib/{context,helpers,dispatcher,bindings,config}.zsh`.
Read-only comprehension. All citations are `file:line` against the current
tree. This document is a state/transition/invariant enumeration, not prose.

---

## 0. Shared constants / config

- `_FORGE_TERM` master switch, default `"true"` — config.zsh:31.
- `_FORGE_TERM_MAX_COMMANDS` ring cap, default `5` — config.zsh:33.
- `_FORGE_TERM_OSC133` mode `auto|on|off`, default `auto` — config.zsh:35.
- Ring arrays declared empty: `_FORGE_TERM_COMMANDS`, `_FORGE_TERM_EXIT_CODES`,
  `_FORGE_TERM_TIMESTAMPS` — config.zsh:37-39.
- Session identity globals (all `typeset -h`, i.e. per-shell-instance):
  `_FORGE_CONVERSATION_ID` config.zsh:13, `_FORGE_ACTIVE_AGENT` config.zsh:14,
  `_FORGE_PREVIOUS_CONVERSATION_ID` config.zsh:17,
  `_FORGE_SESSION_MODEL/_PROVIDER/_REASONING_EFFORT` config.zsh:22-27.

---

## 1. OSC-133 MARKER STATE MACHINE

### 1.1 Emission primitive + gate

- `_forge_osc133_emit(mark)`: gate then `printf '\e]133;%s\a'` —
  context.zsh:52-55. Gate `_forge_osc133_should_emit` returns 0/1 from a
  cached per-session decision `_FORGE_TERM_OSC133_CACHED` — context.zsh:24-48.
  MODELING NOTE: the gate is a pure boolean constant per session; a TLA+ spec
  MAY model emit as either "write mark to Wire" or "skip", constant across the
  whole trace.

### 1.2 The four marks and their meaning

- `A` = prompt start (next prompt). `B` = prompt end / command start.
- `C` = command output start. `D;<code>` = command finished w/ exit code.
- Intended well-formed block on the Wire: `A` → `B` → `C` → `D;code` repeating.

### 1.3 Two disjoint emission PATHS (a command flows through exactly one)

PATH-HOOK (ordinary shell commands, via zsh preexec/precmd):
- `S_PREEXEC`: emit `B` (context.zsh:74) then `C` (context.zsh:76).
- `S_PRECMD`:  emit `D;$last_exit` UNCONDITIONALLY (context.zsh:88, before the
  `_FORGE_TERM != true` early return at :90), then, at end, emit `A`
  (context.zsh:110).
- Hooks registered only when `_FORGE_TERM == true`: preexec appended,
  precmd PREPENDED so it captures real `$?` before p10k/starship —
  context.zsh:118-121.

PATH-ZLE (`:`-commands, via `forge-accept-line`; BYPASSES preexec/precmd):
- Entry emits `B` (dispatcher.zsh:143) then `C` (dispatcher.zsh:144), with the
  documented rationale that ZLE dispatch skips the zsh hooks
  (dispatcher.zsh:140-142).
- Normal exit (centralized): emit `D;$action_status` (dispatcher.zsh:271) then
  `A` (dispatcher.zsh:272), then `_forge_reset` (dispatcher.zsh:277).
- Three EARLY-RETURN branches emit their OWN `D;A` and `return` before the
  centralized pair (so they never double-emit):
  - `edit|ed`         → `D` dispatcher.zsh:211, `A` :212, `return` :214.
  - `commit-preview`  → `D` dispatcher.zsh:222, `A` :223, `return` :225.
  - `suggest|s`       → `D` dispatcher.zsh:230, `A` :231, `return` :233.
  These branches intentionally keep BUFFER and do their own prompt reset
  (comments dispatcher.zsh:213/224/232); they SKIP `_forge_reset`.

### 1.4 States (per terminal Wire)

- `PROMPT` (last mark A or initial), `CMD_STARTED` (after B), `OUTPUT` (after
  C), `FINISHED` (after D). Well-formed cycle: PROMPT→CMD_STARTED→OUTPUT→
  FINISHED→PROMPT.

### 1.5 Guarded transitions

| From | Event | Emit | To | Guard / cite |
|------|-------|------|----|--------------|
| PROMPT | ordinary cmd starts | B;C | OUTPUT | preexec, context.zsh:74,76 |
| OUTPUT | ordinary cmd ends | D;code | FINISHED | precmd, context.zsh:88 |
| FINISHED | before next prompt | A | PROMPT | precmd, context.zsh:110 |
| PROMPT | `:`-cmd Enter | B;C | OUTPUT | ZLE, dispatcher.zsh:143,144 |
| OUTPUT | `:`-cmd normal end | D;code | FINISHED | dispatcher.zsh:271 |
| FINISHED | after `:`-cmd | A | PROMPT | dispatcher.zsh:272 |
| OUTPUT | `:`-cmd early (edit/commit-preview/suggest) | D;code | FINISHED | :211/:222/:230 |
| FINISHED | early branch tail | A | PROMPT | :212/:223/:231 |

### 1.6 OSC-133 INVARIANTS (safety)

- INV-PAIRED (the "never emit an unpaired sequence" contract): every `B` is
  eventually matched by a `D`, and `D` is emitted even when capture is
  disabled — precmd emits `D` before the enabled-check (context.zsh:87-90).
  Modeling target: on the Wire, marks form the regex `(A? B C D)*` with no
  `D` lacking a preceding `B/C` and no second `D` for one `B`.
- INV-NO-DOUBLE-D: each ZLE dispatch emits exactly one `D;A` pair — either the
  early-branch pair (:211-212 / :222-223 / :230-231, guarded by `return`) OR
  the centralized pair (:271-272), never both.
- INV-PATH-DISJOINT: a `:`-command travels PATH-ZLE only; it never triggers
  preexec/precmd (ZLE widget does not run the hooks), so its B/C/D/A come
  solely from dispatcher.zsh. Ordinary commands use PATH-HOOK only.
- LIVENESS: from any FINISHED, an `A` returns the Wire to PROMPT
  (context.zsh:110 or dispatcher.zsh:272 or early :212/:223/:231).
- KNOWN GAP to model as a possible violation: if a ZLE dispatch is aborted
  between `C` (dispatcher.zsh:144) and reaching any `D` (SIGINT during the
  action, see §4), the emitted B;C may have NO matching D on that path →
  INV-PAIRED can be violated on the ZLE path. (Hook path is safer: `D` is in
  precmd which still runs.)

---

## 2. SESSION IDENTITY / TERMINAL OWNERSHIP / CWD  (highest-value invariant)

### 2.1 What identifies "the current conversation"

- The per-shell global `_FORGE_CONVERSATION_ID` (config.zsh:13). Passed to the
  binary as `--cid "$_FORGE_CONVERSATION_ID"` on every execute:
  custom-cmd dispatcher.zsh:42/44, default prompt dispatcher.zsh:82,
  new/core core.zsh:22, info core.zsh:38, conversation subcmds core.zsh:84.
- Active agent: `_FORGE_ACTIVE_AGENT` (config.zsh:14), read as
  `${_FORGE_ACTIVE_AGENT:-forge}` in `_forge_exec`/`_forge_exec_interactive`
  (helpers.zsh:17,53), set on agent switch dispatcher.zsh:61/78.

### 2.2 How a command RESOLVES the conversation (lazy-create)

- If `_FORGE_CONVERSATION_ID` empty → `new_id=$($_FORGE_BIN conversation new)`;
  assign. Sites: custom-cmd dispatcher.zsh:33-37, default-prompt
  dispatcher.zsh:68-72, `:new` core.zsh:16-19.
- Otherwise the EXISTING shell-global cid is reused as-is.

### 2.3 cwd binding

- No `chpwd` hook; cwd is read only opportunistically for background sync via
  `pwd -P` at call time (helpers.zsh:214). The plugin does NOT stamp the tty's
  cwd onto the conversation at dispatch time; cwd association lives on the
  binary/DB side, resolved from whatever conversation the cid names.

### 2.4 STATES for the identity machine (per tty)

- `UNBOUND`: `_FORGE_CONVERSATION_ID == ""` (fresh shell, or after `:new`
  clears it — conversation.zsh:43).
- `BOUND(cid)`: `_FORGE_CONVERSATION_ID == cid`.
- Global/binary side (shared across ALL ttys of the user): `LAST_ACTIVE(cid')`
  — the binary's own notion of the most-recently-used conversation. NOT
  shell-scoped; this is the contamination source.

### 2.5 Transitions

| From | Event | To | cite |
|------|-------|----|------|
| UNBOUND | any execute-needing action | BOUND(new) via `conversation new` | dispatcher.zsh:34/69, core.zsh:18 |
| BOUND(cid) | execute | BOUND(cid), `--cid cid` | dispatcher.zsh:82 |
| BOUND(cid) | `:new` | UNBOUND (id reset "") | conversation.zsh:43 |
| BOUND(cid) | `:conversation -` | BOUND(prev) swap | conversation.zsh:61-62 |
| any | `:conversation <pick>` | BOUND(picked) | conversation.zsh:32 |

### 2.6 The C-c C-c-then-resend WRONG-conversation / WRONG-cwd BUG

Documented in AGENTS.md ("Active known bug + deferred work"): after `C-c C-c`
then re-sending via `:`, forge can resume the WRONG conversation in the WRONG
cwd — a session started in a DIFFERENT Ghostty window — although cwd never
changed. Suspected: `:` dispatch resolves "current conversation" from
global/last-active state instead of pinning to THIS tty.

How the model reproduces it:
1. tty-A creates/uses `cid_A` (BOUND, dispatcher.zsh:82). tty-B uses `cid_B`.
   Each shell global is private (`typeset -h`), so cross-tty leak is NOT via
   the shell variable.
2. The binary-side `LAST_ACTIVE` is global across ttys; the most recent
   execute (say tty-B) sets `LAST_ACTIVE = cid_B`.
3. In tty-A, if the resend path ever executes with an EMPTY or unpinned cid
   (abort left the shell global cleared, or a branch that does not pass the
   tty's `--cid`), the binary resolves the conversation from `LAST_ACTIVE`
   (cid_B) rather than tty-A's cid_A — and restores cid_B's stored cwd. Result:
   wrong conversation, wrong cwd, even though `pwd` in tty-A is unchanged.

INVARIANTS TO MODEL (this is the payload of the whole spec):
- INV-TTY-PIN (safety, currently VIOLATED): every execute for tty-T MUST use a
  cid owned by tty-T; the resolved conversation MUST be a function of tty-local
  state only, NEVER of the shared `LAST_ACTIVE`. Formally:
  `execute(T).resolved_cid = _FORGE_CONVERSATION_ID[T]` and MUST NOT read any
  global-last-active. A trace where `resolved_cid(T) = LAST_ACTIVE` and
  `LAST_ACTIVE` was last written by `T' != T` is a violation.
- INV-CID-NONEMPTY-AT-EXECUTE: no execute may run with cid `""`; lazy-create
  MUST fire first (dispatcher.zsh:33/68). Model must check no path reaches
  `_forge_exec ... --cid ""`.
- INV-CWD-FOLLOWS-CID: the resumed cwd is whatever the resolved conversation
  carries; therefore INV-TTY-PIN implies cwd correctness. Wrong cwd is a
  DERIVED symptom, not an independent variable — model cwd as a field of the
  conversation, not of the tty.

---

## 3. TERMINAL-CONTEXT RING BUFFERS

### 3.1 Variables / pending state

- Three parallel arrays config.zsh:37-39. Pending single-command staging:
  `_FORGE_TERM_PENDING_CMD` / `_FORGE_TERM_PENDING_TS` (context.zsh:64-65).

### 3.2 Transitions

| From | Event | Effect | cite |
|------|-------|--------|------|
| — | preexec | set PENDING_CMD=$1, PENDING_TS=now | context.zsh:71-72 |
| PENDING set | precmd, `_FORGE_TERM==true` | append cmd/exit/ts to the 3 arrays | context.zsh:94-96 |
| after append | length > MAX | `shift` all three (trim oldest) in a loop | context.zsh:99-103 |
| after trim | — | clear PENDING_CMD/TS | context.zsh:105-106 |
| PENDING empty | precmd | no append (guard) | context.zsh:93 |

### 3.3 Ring INVARIANTS (safety)

- INV-EQUAL-LEN: `#COMMANDS == #EXIT_CODES == #TIMESTAMPS` always. Preserved
  because all three are appended together (context.zsh:94-96) and trimmed
  together in the same loop (context.zsh:100-102).
- INV-BOUNDED: `#COMMANDS <= _FORGE_TERM_MAX_COMMANDS` after every precmd; the
  `while (( ># > MAX ))` loop (context.zsh:99) restores it. (Append is +1, so
  the loop runs at most once per precmd, but model as a loop for generality.)
- INV-APPEND-GUARD: an entry is appended iff a preexec set PENDING
  (context.zsh:93); no phantom rows.
- INV-FIFO: trimming removes the OLDEST (`shift`, context.zsh:100-102), so the
  buffer holds the most-recent ≤MAX commands in order.
- Export coupling (not a ring invariant but relevant): the arrays are joined
  with ASCII Unit Separator `\x1f` and exported only to the child forge
  process via `local -x` (helpers.zsh:31-36, 65-71), guarded by
  `_FORGE_TERM==true && #COMMANDS>0`. Equal-length must hold for the child to
  zip them correctly.

---

## 4. ABORT / RESUME DISPATCH LIFECYCLE

### 4.1 Mechanism

- A `:`-prompt executes via `_forge_exec_interactive` with the child forge
  wired to the real tty: `"${cmd[@]}" </dev/tty >/dev/tty` (helpers.zsh:77),
  because ZLE replaces stdin/stdout with pipes (helpers.zsh:46-51).
- There is NO explicit `trap` for SIGINT in these files; `C-c` delivers SIGINT
  to the foreground child (forge). `C-c C-c` = interrupt the running action.
- On abort, control returns into `forge-accept-line` after the dispatch `case`
  (dispatcher.zsh:270), which then emits `D;$action_status` / `A`
  (dispatcher.zsh:271-272) and `_forge_reset` (dispatcher.zsh:277) — UNLESS
  the aborted action was an early-return branch (edit/commit-preview/suggest),
  which already emitted its own `D;A` (§1.3) and returned.

### 4.2 States (dispatch)

- `IDLE` (prompt shown) → `DISPATCHING` (inside `case`, after B;C at :143-144)
  → `ABORTED` (SIGINT) or `DONE` → back to `IDLE` after D;A + reset.

### 4.3 Transitions

| From | Event | To | cite |
|------|-------|----|------|
| IDLE | `:`Enter (buffer matches `^:...`) | DISPATCHING (emit B;C) | dispatcher.zsh:99-116,143-144 |
| IDLE | Enter, non-`:` buffer | native `accept-line` | dispatcher.zsh:112-115 |
| DISPATCHING | action returns 0..n | DONE (emit D;A) | dispatcher.zsh:270-272 |
| DISPATCHING | SIGINT (C-c C-c) | ABORTED | no trap; child killed |
| DONE/ABORTED | tail | IDLE (`_forge_reset`) | dispatcher.zsh:277 |
| DISPATCHING(early) | edit/commit-preview/suggest done-or-abort | IDLE (own D;A, no _forge_reset) | :211-214/:222-225/:230-233 |

### 4.4 RESUME (re-send)

- Resend = user re-enters a `:`-line → re-enters `forge-accept-line` (IDLE→
  DISPATCHING). cid is whatever `_FORGE_CONVERSATION_ID[T]` holds. Because
  abort does NOT clear the shell global cid, resend normally reuses the SAME
  cid — correct WITHIN one tty. The bug (§2.6) is that resolution can fall to
  `LAST_ACTIVE` when the cid is empty/unpinned, pulling another tty's session.

### 4.5 Abort/resume INVARIANTS

- INV-RESET-EXCEPT-EARLY: every terminal dispatch outcome ends in `_forge_reset`
  (dispatcher.zsh:277) EXCEPT the three early-return branches, which manage
  their own BUFFER/prompt (dispatcher.zsh:213/224/232).
- INV-ABORT-PAIR (see §1.6 KNOWN GAP): abort between C (:144) and D on the ZLE
  path can leave B;C without a D — the one place INV-PAIRED can break; model it
  as a reachable bad state to prove/patch.
- INV-CID-STABLE-ON-ABORT: SIGINT does not mutate `_FORGE_CONVERSATION_ID`;
  resend keeps the same cid (no clearing code on the abort path). Combined with
  INV-TTY-PIN this would make resume deterministic per tty.

---

## 5. Key bindings lifecycle (supporting)

- Widgets `forge-accept-line`, `forge-completion` registered bindings.zsh:6-7.
- `_forge_apply_keybindings` binds `^M`/`^J`→forge-accept-line, `^I`→
  forge-completion, and rebinds bracketed-paste (bindings.zsh:40-45); called
  once (bindings.zsh:47) and RE-applied after zsh-vi-mode via
  `zvm_after_init_commands` (bindings.zsh:50-51) because zvm_init clobbers
  keymaps. Relevant only as: the `:`-dispatch entry point can be transiently
  unbound between zvm_init and re-apply (a liveness caveat, not a core state).

---

## 6. Invariant roll-up (named, for the TLA+ module)

Safety:
- INV-PAIRED, INV-NO-DOUBLE-D, INV-PATH-DISJOINT  (OSC-133).
- INV-TTY-PIN (PRIMARY), INV-CID-NONEMPTY-AT-EXECUTE, INV-CWD-FOLLOWS-CID.
- INV-EQUAL-LEN, INV-BOUNDED, INV-APPEND-GUARD, INV-FIFO  (ring).
- INV-RESET-EXCEPT-EARLY, INV-CID-STABLE-ON-ABORT.
Liveness:
- Every FINISHED eventually returns to PROMPT (A emitted).
Reachable violations to model (bugs):
- INV-ABORT-PAIR gap (unpaired B;C on ZLE abort).
- INV-TTY-PIN violation (resolve from LAST_ACTIVE ⇒ wrong conversation+cwd).
