# LEDGER — live execution state (update every task)

Markers: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked.
Rule: flip marker before starting and after finishing. Append notes inline.

## P0 bootstrap (Forge planning session)

- [x] baseline stats, index probe, model inventory (2026-07-24, see EVIDENCE)
- [x] tri-model probe + falsification round 1 (H1/H2/H3)
- [x] harness dir created, committed

## P1 cartography

- [ ] verify + extend seeded crate dep graph (EVIDENCE §2) via .codegraph
- [ ] churn top-20 (`git log --format= --name-only | sort | uniq -c | sort -rn | head -20`)
- [ ] baseline: tokei snapshot, clippy warning count, typos count
- [ ] br epic + P1-P7 tickets created

## P2 hypotheses

- [ ] subsystem briefs written (orch, tools, providers, services, infra, domain, shell-plugin, config)
- [ ] tri-model independent hypothesis generation (`llm-fanout -a`, `-t 0`)
- [ ] hypotheses table in EVIDENCE (each with falsification command)

## P3 falsification

- [ ] every hypothesis measured (rg / ast-grep / Cargo.toml)
- [ ] numbers logged in EVIDENCE table

## P4 arbitration

- [ ] gpt-oss:120b-cloud verdicts (CONFIRMED / FALSIFIED / NUANCED)
- [ ] convergence weighting noted; lone hypotheses re-measured

## P5 deep dives (5-8 hot spots, pick by P4)

- [ ] orch loop `crates/forge_app/src/orch.rs:240`
- [ ] tool dispatch `crates/forge_app/src/orch.rs:58` + `crates/forge_app/src/tool_registry.rs:28`
- [ ] forge_domain tokio leak (CONFIRMED H1) — scope + blast radius
- [ ] forge_services size/cohesion audit
- [ ] error-handling conformance (anyhow/thiserror rules in repo AGENTS.md)
- [ ] unsafe inventory + semgrep security pass
- [ ] dependency audit (dep-auditor lane)

## P6 report

- [ ] REPORT.md written (plain English)
- [ ] critic gate: APPROVE required
- [ ] verify evidence attached
- [ ] mempalace drawer per phase written

## P7 teardown (ONLY after done-done + operator word)

- [ ] operator said done-done
- [ ] `./teardown.bash --yes` executed, harness removed, history in git
