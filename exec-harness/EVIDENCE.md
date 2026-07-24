# EVIDENCE — append-only measurement log

Format per entry: claim | command | number/fact | file:line. Never edit
old rows; append corrections.

## 1. Baseline (2026-07-24, Forge P0)

- 25 workspace crates (`ls crates`), 482 .rs files, 107,435 Rust code LOC (tokei)
- Indexes present: `.codegraph` `.grepai` `.repowise`; no `.gitnexus`
- Ollama: gpt-oss:120b-cloud, kimi-k2.7-code:cloud, glm-5.2:cloud,
  ornith:latest, qwen3:4b, qwen3-embedding:0.6b; MLX CLI present
  (`mlx_lm.generate`, `mlx_lm.server`), no MLX chat model cached yet

## 2. Dependency direction (cavecrew-investigator, measured from Cargo.toml)

- entry: `crates/forge_main/src/main.rs:48` (tokio async main)
- `forge_main` deps: forge_app, forge_api, forge_domain (`crates/forge_main/Cargo.toml:17-19`)
- `forge_api` deps: forge_domain, forge_services, forge_infra, forge_app (`crates/forge_api/Cargo.toml:11-25`)
- `forge_app` deps: forge_domain (`crates/forge_app/Cargo.toml:8`)
- `forge_services` deps: forge_app, forge_domain (`crates/forge_services/Cargo.toml:45-49`)
- `forge_infra` deps: forge_domain, forge_services, forge_app (`crates/forge_infra/Cargo.toml:15-31`)
- `forge_domain`: no internal layer deps (`crates/forge_domain/Cargo.toml:30-37`)
- direction: main and api on top; infra implements traits of services/app; domain at bottom

## 3. Orchestration + tools map

- `Orchestrator::run` `crates/forge_app/src/orch.rs:240`
- main turn loop (`while !should_yield`) `crates/forge_app/src/orch.rs:268`
- `execute_chat_turn` `crates/forge_app/src/orch.rs:196`
- `execute_tool_calls` `crates/forge_app/src/orch.rs:58`
- `ToolCatalog` `crates/forge_domain/src/tools/catalog.rs:41`
- `ToolDefinition` `crates/forge_domain/src/tools/definition/tool_definition.rs:46`
- `ToolRegistry<S>` `crates/forge_app/src/tool_registry.rs:28`
- `tools_overview` `crates/forge_app/src/tool_registry.rs:243`

## 4. Hypothesis round 1 (tri-model: kimi, glm, gpt-oss arbiter)

| Hypothesis | Measurement | Result | Verdict |
|---|---|---|---|
| H1 forge_domain leaks async-runtime concerns | `rg "tokio|async_trait" crates/forge_domain/Cargo.toml`; `rg -l "tokio::" crates/forge_domain/src \| wc -l` | 2 dep hits; 7 files | CONFIRMED |
| H2 forge_app imports forge_infra concretely | `rg -l "use forge_infra" crates/forge_app/src \| wc -l` | 0 | FALSIFIED |
| H3 forge_infra depends on app/services (inversion) | `rg "forge_app\|forge_services" crates/forge_infra/Cargo.toml` | both present | NUANCED — correct hexagonal DI (infra implements upper traits) |

Arbiter (gpt-oss:120b-cloud) next measurements: H1 — check domain traits
returning futures; H3 — audit trait impls for swappability.

## 5. Harness defects found (meta)

- `llm-fanout -t N` counts thinking tokens toward cap; gpt-oss answer
  truncated at `-t 300` (913 raw tokens). Workaround `-t 0`. Logged in
  `~/.config/sh/HARNESS-ROADMAP.md` (config commit fd51c33).

## 6. Breadcrumbs

- mempalace: wing `forgecode`, room `analysis`,
  drawer `drawer_forgecode_analysis_2f1638771ed1ebe740aeb947`
- new forge agent: `~/forge/agents/ollama-architecture-analyst.md`
  (forge jj commit 2e0ef4ce)
