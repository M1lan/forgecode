----------------------------- MODULE Osc133 -----------------------------
(***************************************************************************)
(* NARROW model of the OSC-133 marker automaton on one terminal Wire.      *)
(*                                                                         *)
(* Sources: 02-lifecycle.md sec 1 (OSC-133 MARKER STATE MACHINE) + sec 4   *)
(*          (ABORT / RESUME), 00-model.md sec 4.                           *)
(*                                                                         *)
(* Marks: A = prompt start, B = command start, C = output start,           *)
(*        D = finished (D;code, code elided). Well-formed block on the      *)
(*        Wire: (A? B C D)*  - 02-lifecycle.md:38,90.                       *)
(*                                                                         *)
(* Two DISJOINT paths a command can travel (02-lifecycle.md:40-64):        *)
(*   HOOK - ordinary shell command via preexec/precmd. B,C in preexec      *)
(*          (context.zsh:74,76); D in precmd UNCONDITIONALLY (context.zsh:  *)
(*          88) then A (context.zsh:110).                                   *)
(*   ZLE  - a ':'-command via forge-accept-line; BYPASSES preexec/precmd.   *)
(*          B,C at dispatcher.zsh:143,144; then either the centralized D;A  *)
(*          (dispatcher.zsh:271,272) OR an early-return branch's own D;A    *)
(*          (edit :211-212 / commit-preview :222-223 / suggest :230-231).   *)
(*          Exactly one D;A pair fires per dispatch (INV-NO-DOUBLE-D).      *)
(*                                                                         *)
(* KNOWN GAP (02-lifecycle.md:99-103, 270-272): on the ZLE path a SIGINT   *)
(* (C-c C-c) between C (dispatcher.zsh:144) and any D leaves B;C with NO    *)
(* matching D -> INV-ABORT-PAIR / INV-PAIRED violation. The HOOK path is    *)
(* safe because D is emitted in precmd which still runs. This action is     *)
(* gated by AllowAbort so the well-formed model and the gap can be checked  *)
(* separately.                                                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS MaxMarks,    \* cap on Wire length (bounds the state space)
          AllowAbort   \* BOOLEAN: enable the ZLE SIGINT-between-C-and-D action

VARIABLES
  wire,   \* Seq of marks emitted so far ("A","B","C","D")
  st,     \* "PROMPT" | "OUTPUT" | "FINISHED"
  path,   \* "none" | "HOOK" | "ZLE"  - path of the in-flight command
  branch, \* "none" | "central" | "early" - which ZLE done-branch is in play
  open    \* BOOLEAN: a B has been emitted with no matching D yet

vars == << wire, st, path, branch, open >>

Marks == {"A", "B", "C", "D"}

TypeOK ==
  /\ wire   \in Seq(Marks)
  /\ st     \in {"PROMPT", "OUTPUT", "FINISHED"}
  /\ path   \in {"none", "HOOK", "ZLE"}
  /\ branch \in {"none", "central", "early"}
  /\ open   \in BOOLEAN

Init ==
  /\ wire   = << >>
  /\ st     = "PROMPT"
  /\ path   = "none"
  /\ branch = "none"
  /\ open   = FALSE

Room == Len(wire) + 2 <= MaxMarks   \* headroom for a 2-mark emit

------------------------------------------------------------------------
\* HOOK PATH (ordinary command; preexec/precmd).

HookBegin ==
  /\ st = "PROMPT"
  /\ Room
  /\ wire'   = Append(Append(wire, "B"), "C")   \* preexec: B then C
  /\ st'     = "OUTPUT"
  /\ path'   = "HOOK"
  /\ open'   = TRUE
  /\ UNCHANGED branch

HookEnd ==
  /\ st = "OUTPUT"
  /\ path = "HOOK"
  /\ Len(wire) + 1 <= MaxMarks
  /\ wire'   = Append(wire, "D")                 \* precmd: D (unconditional)
  /\ st'     = "FINISHED"
  /\ open'   = FALSE
  /\ UNCHANGED << path, branch >>

HookPrompt ==
  /\ st = "FINISHED"
  /\ path = "HOOK"
  /\ Len(wire) + 1 <= MaxMarks
  /\ wire'   = Append(wire, "A")                 \* precmd: A (next prompt)
  /\ st'     = "PROMPT"
  /\ path'   = "none"
  /\ UNCHANGED << branch, open >>

------------------------------------------------------------------------
\* ZLE PATH (':'-command; forge-accept-line; skips the hooks).

ZleBegin(k) ==
  /\ st = "PROMPT"
  /\ Room
  /\ wire'   = Append(Append(wire, "B"), "C")   \* dispatcher.zsh:143,144
  /\ st'     = "OUTPUT"
  /\ path'   = "ZLE"
  /\ branch' = k                                 \* choose central vs early
  /\ open'   = TRUE

ZleEnd ==
  /\ st = "OUTPUT"
  /\ path = "ZLE"
  /\ Len(wire) + 1 <= MaxMarks
  /\ wire'   = Append(wire, "D")                 \* central :271 OR early :211/222/230
  /\ st'     = "FINISHED"
  /\ open'   = FALSE
  /\ UNCHANGED << path, branch >>

ZlePrompt ==
  /\ st = "FINISHED"
  /\ path = "ZLE"
  /\ Len(wire) + 1 <= MaxMarks
  /\ wire'   = Append(wire, "A")                 \* central :272 OR early :212/223/231
  /\ st'     = "PROMPT"
  /\ path'   = "none"
  /\ branch' = "none"
  /\ UNCHANGED open

\* KNOWN GAP: SIGINT after C (dispatcher.zsh:144) before any D. No trap; the
\* child is killed and control returns to a fresh prompt with NO D emitted.
\* Leaves open = TRUE at PROMPT -> unpaired B;C.
ZleAbort ==
  /\ AllowAbort
  /\ st = "OUTPUT"
  /\ path = "ZLE"
  /\ st'     = "PROMPT"
  /\ path'   = "none"
  /\ branch' = "none"
  /\ UNCHANGED << wire, open >>                  \* D deliberately NOT emitted

Next ==
  \/ HookBegin \/ HookEnd \/ HookPrompt
  \/ (\E k \in {"central", "early"}: ZleBegin(k))
  \/ ZleEnd \/ ZlePrompt \/ ZleAbort

Spec == Init /\ [][Next]_vars

------------------------------------------------------------------------
\* INVARIANTS

\* INV-PAIRED: the contract "never leave an unpaired sequence" - whenever the
\* Wire is back at a prompt, no B is left open (every B was matched by a D).
INV_PAIRED == (st = "PROMPT") => (open = FALSE)

\* INV-NO-DOUBLE-D: a D is only ever emitted from OUTPUT (one per B); the
\* automaton can never emit a second D for the same command. Equivalent
\* structural check: an open command is the only precondition for a D, and
\* emitting D clears open.
INV_NO_DOUBLE_D == (st = "FINISHED") => (open = FALSE)

\* INV-PATH-DISJOINT: an in-flight command travels exactly one path; its
\* B/C/D/A all come from that single path.
INV_PATH_DISJOINT == (open = TRUE) => (path \in {"HOOK", "ZLE"})

\* INV-ABORT-PAIR: same contract as INV-PAIRED, named for the specific
\* reachable violation - a ZLE SIGINT between C and D leaves B;C unpaired.
INV_ABORT_PAIR == (st = "PROMPT") => (open = FALSE)

=======================================================================
