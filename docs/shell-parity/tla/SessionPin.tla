--------------------------- MODULE SessionPin ---------------------------
(***************************************************************************)
(* NARROW model of the forge-zsh C-c C-c wrong-conversation bug.           *)
(*                                                                         *)
(* Sources: 02-lifecycle.md sec 2 (SESSION IDENTITY / TERMINAL OWNERSHIP), *)
(*          00-model.md sec 4 (INV-TTY-PIN PRIMARY).                       *)
(*                                                                         *)
(* Each TTY has a per-shell pinned conversation id (cid); typeset -h so it *)
(* is private per shell (config.zsh:13). Every conversation carries a cwd  *)
(* (cwd lives on the binary/DB side, resolved from the cid -               *)
(* 02-lifecycle.md:127-131), so cwd is modeled as a FIELD of the           *)
(* conversation, never of the tty (INV-CWD-FOLLOWS-CID).                   *)
(*                                                                         *)
(* LAST_ACTIVE is the binary's shared "most-recently-used conversation",   *)
(* global across ALL ttys of the user (02-lifecycle.md:138-140) - the      *)
(* contamination source.                                                   *)
(*                                                                         *)
(* Actions:                                                                *)
(*   StartConversation(t) - lazy-create: unbound tty executes, creates a   *)
(*                          fresh cid it owns, sets LAST_ACTIVE            *)
(*                          (dispatcher.zsh:33-37/68-72, core.zsh:16-19).  *)
(*   ExecBound(t)         - a bound tty re-executes with its own cid       *)
(*                          (dispatcher.zsh:82, --cid cid), sets           *)
(*                          LAST_ACTIVE.                                   *)
(*   AbortAbort(t)        - C-c C-c leaves the shell global cid cleared/    *)
(*                          unpinned (the abort path that empties cid).     *)
(*   Resend(t)            - re-send a ':'-line. THIS is where the buggy vs  *)
(*                          fixed resolution differ.                        *)
(*                                                                         *)
(* Buggy resolution (Buggy = TRUE): an empty/unpinned cid on resend        *)
(*   resolves from LAST_ACTIVE (02-lifecycle.md:166-170) -> can pull       *)
(*   another window's cid + cwd.                                           *)
(* Fixed resolution (Buggy = FALSE): an empty cid on a tty is a hard error *)
(*   / re-pins to THAT tty only (fresh cid it owns), NEVER LAST_ACTIVE.    *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS TTY,       \* set of terminals, e.g. {t1, t2}
          Cid,       \* pool of conversation ids, e.g. {c1, c2, c3}
          Buggy      \* BOOLEAN: TRUE = buggy resolution, FALSE = fixed

Nil == "nil"         \* the empty / unpinned cid marker

ASSUME Nil \notin Cid

VARIABLES
  pin,        \* [TTY -> Cid \cup {Nil}]  each tty's pinned conversation
  owner,      \* [Cid -> TTY \cup {Nil}]  which tty created (owns) each cid
  lastActive, \* Cid \cup {Nil}           the shared binary-side LAST_ACTIVE
  free,       \* SUBSET Cid               cids not yet allocated (bounds state)
  execTty,    \* TTY \cup {Nil}           tty of the most recent execute
  execCid     \* Cid \cup {Nil}           cid resolved by the most recent execute

vars == << pin, owner, lastActive, free, execTty, execCid >>

\* cwd is a pure field of the conversation: distinct per cid (identity here).
Cwd(c) == c

TypeOK ==
  /\ pin \in [TTY -> Cid \cup {Nil}]
  /\ owner \in [Cid -> TTY \cup {Nil}]
  /\ lastActive \in Cid \cup {Nil}
  /\ free \subseteq Cid
  /\ execTty \in TTY \cup {Nil}
  /\ execCid \in Cid \cup {Nil}

Init ==
  /\ pin        = [t \in TTY |-> Nil]
  /\ owner      = [c \in Cid |-> Nil]
  /\ lastActive = Nil
  /\ free       = Cid
  /\ execTty    = Nil
  /\ execCid    = Nil

\* Unbound tty executes -> lazy-create a fresh cid, pin + own it, publish it.
StartConversation(t) ==
  /\ pin[t] = Nil
  /\ free # {}
  /\ \E c \in free:
       /\ pin'        = [pin   EXCEPT ![t] = c]
       /\ owner'      = [owner EXCEPT ![c] = t]
       /\ free'       = free \ {c}
       /\ lastActive' = c
       /\ execTty'    = t
       /\ execCid'    = c

\* Bound tty re-executes with its own cid (--cid cid). Publishes LAST_ACTIVE.
ExecBound(t) ==
  /\ pin[t] # Nil
  /\ lastActive' = pin[t]
  /\ execTty'    = t
  /\ execCid'    = pin[t]
  /\ UNCHANGED << pin, owner, free >>

\* C-c C-c: the abort path clears the shell-global cid (leaves it unpinned).
AbortAbort(t) ==
  /\ pin[t] # Nil
  /\ pin' = [pin EXCEPT ![t] = Nil]
  /\ UNCHANGED << owner, lastActive, free, execTty, execCid >>

\* Resend a ':'-line on tty t. Bound path is identical either way; the empty
\* path is where Buggy vs Fixed diverge.
Resend(t) ==
  IF pin[t] # Nil
  THEN \* bound: resolve to own cid (correct on both models)
       /\ lastActive' = pin[t]
       /\ execTty'    = t
       /\ execCid'    = pin[t]
       /\ UNCHANGED << pin, owner, free >>
  ELSE IF Buggy
       THEN \* BUG: empty cid falls back to the shared LAST_ACTIVE
            /\ execTty'    = t
            /\ execCid'    = lastActive
            /\ UNCHANGED << pin, owner, lastActive, free >>
       ELSE \* FIX: empty cid re-pins to THIS tty only (fresh owned cid),
            \* never LAST_ACTIVE. If no cid is free, the action is disabled
            \* (models the hard-error: an execute NEVER proceeds off empty).
            /\ free # {}
            /\ \E c \in free:
                 /\ pin'        = [pin   EXCEPT ![t] = c]
                 /\ owner'      = [owner EXCEPT ![c] = t]
                 /\ free'       = free \ {c}
                 /\ lastActive' = c
                 /\ execTty'    = t
                 /\ execCid'    = c

Next ==
  \E t \in TTY:
    \/ StartConversation(t)
    \/ ExecBound(t)
    \/ AbortAbort(t)
    \/ Resend(t)

Spec == Init /\ [][Next]_vars

------------------------------------------------------------------------
\* INVARIANTS

\* INV-CID-NONEMPTY-AT-EXECUTE: no execute ever runs with an empty cid.
INV_CID_NONEMPTY == (execTty # Nil) => (execCid # Nil)

\* INV-TTY-PIN (PRIMARY): the conversation an execute resolves for tty T must
\* be OWNED by T - a function of tty-local state only, never of LAST_ACTIVE
\* written by another tty.
INV_TTY_PIN == (execCid # Nil) => (owner[execCid] = execTty)

\* INV-CWD-FOLLOWS-CID: the resumed cwd is exactly the resolved conversation's
\* cwd (derived - wrong cwd is a symptom of a wrong cid, not independent).
INV_CWD_FOLLOWS == (execCid # Nil) => (Cwd(execCid) = execCid)

=======================================================================
