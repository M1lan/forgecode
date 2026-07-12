# TLA+ model-check report — forge shell-plugin (session-pin + OSC-133)

Two narrow TLA+ specs, model-checked with TLC 2.19 (OpenJDK 21). Both finish in
under a second. Sources: `02-lifecycle.md` (§1 OSC-133, §2 session identity, §4
abort/resume) and `00-model.md` §4. State spaces kept tiny (2 TTYs / 3 cids;
Wire capped at 8 marks) and explicitly bounded via `free` (cid pool) and a
`Room` length guard so TLC is exhaustive.

## Artifacts

| File | Purpose |
|------|---------|
| `SessionPin.tla` | C-c C-c wrong-conversation bug; `Buggy` constant toggles buggy/fixed resolution |
| `SessionPin.cfg` | Buggy, all invariants (INV_CID_NONEMPTY fires first) |
| `SessionPinTtyPin.cfg` | Buggy, **only** INV_TTY_PIN → isolates the cross-tty LAST_ACTIVE leak |
| `SessionPinFixed.cfg` | Fixed resolution, all invariants → holds |
| `Osc133.tla` | OSC-133 A/B/C/D marker automaton, HOOK vs ZLE disjoint paths, `AllowAbort` toggle |
| `Osc133.cfg` | Abort disabled, well-formed invariants → hold |
| `Osc133Abort.cfg` | Abort enabled → INV_ABORT_PAIR reachable violation |

## Exact TLC commands

```bash
JAR=~/.local/share/tla/tla2tools.jar
cd ~/tmp/forge-shell-spec/spec

# parse
java -cp "$JAR" tla2sany.SANY SessionPin.tla
java -cp "$JAR" tla2sany.SANY Osc133.tla

# 1. buggy — INV_CID_NONEMPTY caught (empty-cid resend)
java -cp "$JAR" tlc2.TLC -config SessionPin.cfg        -deadlock SessionPin.tla
# 1b. buggy — INV_TTY_PIN only: the cross-tty leak trace
java -cp "$JAR" tlc2.TLC -config SessionPinTtyPin.cfg  -deadlock SessionPin.tla
# 2. fixed — all hold
java -cp "$JAR" tlc2.TLC -config SessionPinFixed.cfg   -deadlock SessionPin.tla
# 3. osc133 well-formed — all hold
java -cp "$JAR" tlc2.TLC -config Osc133.cfg            -deadlock Osc133.tla
# 4. osc133 abort — INV_ABORT_PAIR violated
java -cp "$JAR" tlc2.TLC -config Osc133Abort.cfg       -deadlock Osc133.tla
```

---

## 1. SessionPin — the C-c C-c wrong-conversation bug

### 1a. Buggy model, INV_TTY_PIN only → cross-tty LAST_ACTIVE leak (PRIMARY)

`INV_TTY_PIN == (execCid # Nil) => (owner[execCid] = execTty)`

TLC counterexample (verbatim, trimmed):

```
Error: Invariant INV_TTY_PIN is violated.
State 1: <Initial predicate>
/\ pin = (t1 :> "nil" @@ t2 :> "nil")
/\ owner = (c1 :> "nil" @@ c2 :> "nil" @@ c3 :> "nil")
/\ execCid = "nil"  /\ execTty = "nil"  /\ lastActive = "nil"  /\ free = {c1, c2, c3}

State 2: <StartConversation(t1)>        \ t1 lazy-creates + owns c1, publishes LAST_ACTIVE
/\ pin = (t1 :> c1 @@ t2 :> "nil")
/\ owner = (c1 :> t1 @@ c2 :> "nil" @@ c3 :> "nil")
/\ execCid = c1  /\ execTty = t1  /\ lastActive = c1  /\ free = {c2, c3}

State 3: <Resend(t2)>                    \ t2 resends off an EMPTY cid
/\ pin = (t1 :> c1 @@ t2 :> "nil")      \ t2 still unpinned
/\ owner = (c1 :> t1 @@ ...)            \ c1 owned by t1
/\ execCid = c1  /\ execTty = t2        \ VIOLATION: t2 executes against t1's c1
/\ lastActive = c1
```

Essence: `t1` runs a conversation (LAST_ACTIVE := c1). `t2` — a shell whose cid
is empty/unpinned (fresh, or left empty by C-c C-c per §2.6 / §4.4) — resends,
and the buggy resolver falls back to the shared `LAST_ACTIVE`, so `t2` executes
against `t1`'s conversation `c1` (and, since cwd is a field of the conversation,
restores `c1`'s cwd). This is exactly the documented wrong-conversation /
wrong-cwd defect (`02-lifecycle.md:166-170`). **TLC caught the LAST_ACTIVE leak.**

### 1b. Buggy model, all invariants → INV_CID_NONEMPTY also fires

Running `SessionPin.cfg` (all invariants), TLC halts even earlier on
`INV_CID_NONEMPTY == (execTty # Nil) => (execCid # Nil)`: a `Resend(t1)` off a
truly-empty cid with `LAST_ACTIVE = nil` executes with `execCid = "nil"`. A
second real defect on the same buggy path — an execute with no conversation at
all. (Verbatim: State 2 `<Resend>` has `execTty = t1 /\ execCid = "nil"`.)

### 2. Fixed model → all invariants hold

`SessionPinFixed.cfg` (`Buggy = FALSE`: an empty cid on resend re-pins to THAT
tty only with a fresh owned cid, never `LAST_ACTIVE`; hard-error when no cid is
free so an execute never proceeds off empty):

```
Model checking completed. No error has been found.
739 states generated, 181 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 7.
```

INV_CID_NONEMPTY, INV_TTY_PIN, INV_CWD_FOLLOWS all hold across every
interleaving. The fix is proven at the model level.

---

## 2. Osc133 — the marker automaton

### 3. Well-formed model (abort disabled) → all hold

`Osc133.cfg`:

```
Model checking completed. No error has been found.
19 states generated, 15 distinct states found, 0 states left on queue.
```

INV_PAIRED, INV_NO_DOUBLE_D, INV_PATH_DISJOINT hold across all HOOK-path and
ZLE-path (central and early-return branch) interleavings. D is only ever emitted
from OUTPUT (one per B); an in-flight command carries exactly one path.

### 4. Abort model (SIGINT between C and D on the ZLE path) → INV_ABORT_PAIR violated

`Osc133Abort.cfg`. Counterexample (verbatim, trimmed):

```
Error: Invariant INV_ABORT_PAIR is violated.
State 1: <Initial predicate>
/\ wire = <<>>  /\ st = "PROMPT"  /\ path = "none"  /\ open = FALSE

State 2: <ZleBegin("central")>          \ dispatcher.zsh:143,144 emit B then C
/\ wire = <<"B", "C">>  /\ st = "OUTPUT"  /\ path = "ZLE"  /\ open = TRUE

State 3: <ZleAbort>                       \ SIGINT before any D; no trap, child killed
/\ wire = <<"B", "C">>                   \ D NEVER emitted
/\ st = "PROMPT"  /\ path = "none"  /\ open = TRUE   \ VIOLATION: back at prompt with B;C open
```

Essence: on the ZLE path, a `C-c C-c` between `C` (dispatcher.zsh:144) and any
`D` returns the Wire to a fresh prompt with `B;C` left unpaired — the D is lost
because ZLE dispatch bypasses the precmd hook that would otherwise emit it
(`02-lifecycle.md:99-103, 270-272`). **This is a real, reachable defect, reported
here — not hidden.** It is the known-gap counterpart to the HOOK path, where `D`
lives in precmd and always runs, so the HOOK path cannot exhibit this violation.

---

## Summary

| Check | Config | Result |
|-------|--------|--------|
| SessionPin buggy, INV_TTY_PIN | `SessionPinTtyPin.cfg` | **VIOLATED** — cross-tty LAST_ACTIVE leak (3-state trace) |
| SessionPin buggy, all | `SessionPin.cfg` | **VIOLATED** — INV_CID_NONEMPTY (empty-cid execute) |
| SessionPin fixed, all | `SessionPinFixed.cfg` | **HOLDS** — 181 distinct states, no error |
| Osc133 well-formed | `Osc133.cfg` | **HOLDS** — 15 distinct states, no error |
| Osc133 abort | `Osc133Abort.cfg` | **VIOLATED** — INV_ABORT_PAIR unpaired B;C (3-state trace) |

The formal method earned its keep: it produced a concrete before/after for the
LAST_ACTIVE bug (buggy leaks, fixed holds) and independently rediscovered the
documented OSC-133 abort gap as a reachable unpaired-B;C violation.
