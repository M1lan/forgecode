# BRIEF — bootstrap contract for executing agents

You are the OMC leader (left pane) of `omc interop --yolo` in
`~/mysrc/forgecode`. OMX (right pane) is your worker/verifier peer.
PLAN.md is wenyan-ultra caveman (operator preference) — LEDGER.md and
EVIDENCE.md carry the same structure in plain form. Read all three first.

## Contract (non-negotiable)

1. LEDGER.md = single source of execution state. Update marker
   (`[ ]`→`[~]`→`[x]`, `[!]` blocked) BEFORE and AFTER every task.
2. EVIDENCE.md = append-only measurement log. Every claim needs a
   measurement row (command + number + file:line). No measurement, no claim.
3. Commit small and often: at minimum after every phase, prefer after
   every task. Message style: `analysis: <what>` 4-8 words.
   NO commit trailers of any kind (no Co-Authored-By, no Assisted-By) —
   operator global rule, outranks the repo AGENTS.md trailer line;
   conflict already surfaced to operator 2026-07-24.
4. This harness dir is LIVE: update PLAN/LEDGER/EVIDENCE continuously
   during implementation, not at the end.
5. Model routing (frontier-once): text-only subtasks go to ollama first.
   - `llm-fanout 'task'` one cloud model; `-a` = all 3 in parallel
     (gpt-oss:120b-cloud, kimi-k2.7-code:cloud, glm-5.2:cloud);
     `-m MODEL` to pick; `-t 0` MANDATORY for reasoning models
     (cap counts thinking tokens — measured defect); `-l` local-only
     for anything sensitive.
   - Hypothesis generation: 3 models independently, same brief;
     convergence = confidence weight. Arbitration: gpt-oss:120b-cloud.
6. Tools: `ast-grep` for code structure, `rg` literal, `fd` names,
   `.codegraph`/`.grepai`/`.repowise` indexes exist — use them first.
   Bash 5.3 only (`/opt/homebrew/bin/bash`). `rtk` prefix for dev CLIs.
7. Tickets: `br` works in this repo. Create one epic
   "deep-analysis exec-harness" + one ticket per phase P1-P7; close as
   phases land.
8. Breadcrumbs: mempalace wing `forgecode`, room `analysis` — one drawer
   per phase result. Seed drawer:
   `drawer_forgecode_analysis_2f1638771ed1ebe740aeb947`.
9. Skills: ultrawork (parallelize independent tasks), team (split
   OMC/OMX streams), ralph (do not stop before verified), verify
   (evidence before done), critic (gate on REPORT.md).
10. OMX role: verification, falsification math, second opinions,
    adversarial review of OMC findings. Delegate deliberately via
    interop panes; A/B-check first.

## Definition of done-done

All LEDGER items `[x]`, REPORT.md committed, critic verdict APPROVE,
verify evidence attached, operator says done-done.

## Teardown (P7 — only after done-done)

Run `./exec-harness/teardown.bash --yes`. Deletes exec-harness/ in one
commit; full history stays in git. Operator pre-authorized this deletion
(feedback 2026-07-24). The script refuses while LEDGER has open items.
