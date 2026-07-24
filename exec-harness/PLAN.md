# 執行計 — forgecode 深察 (exec-harness v1, 2026-07-24)

目: 察 forgecode 全庫。證據為王，臆而不量者誅。
畢則成 `exec-harness/REPORT.md`。終除此目，史存 git。
律: 段畢必更 `LEDGER.md`、增 `EVIDENCE.md`、小步 `git commit`。此目乃活器，行中恆新之。

## 役

- 帥: OMC (claude, interop 左格)。工: OMX (codex, 右格, verify/reason/second-opinion)。
- 文事(草、summarize、review、裁)付 ollama 三雲模:
  `gpt-oss:120b-cloud` `kimi-k2.7-code:cloud` `glm-5.2:cloud`。
- 殼道: `llm-fanout '事'` 一模; `-a` 三並; `-m 模` 擇; 思模必 `-t 0` (cap 噬思, 見 EVIDENCE)。私文 `-l` 局模。
- Forge 使: `ollama-architecture-analyst` (說/裁), `ollama-kimi-reviewer` `ollama-glm-reviewer` (diff 察), `cavecrew-*` (尋/小修/察, 縮語省 token)。
- 索備: `.codegraph` `.grepai` `.repowise`。構察必 `ast-grep`, 字察 `rg`, 名察 `fd`。
- 簿: `br` 立 epic + 段票 (庫已有 forgecode-* 票)。跡: mempalace wing `forgecode`。
- 技: ultrawork(並), team(分), ralph(不成不休), verify(證), critic(末檢)。

## P1 輿圖

crate 圖、入口、主環、器錄 — 種於 EVIDENCE, 驗而廣之。
churn 熱: `git log --format= --name-only | sort | uniq -c | sort -rn | head -20`。
基線數: `tokei`, `cargo clippy --workspace 2>&1 | tail -3`, `typos --format brief | wc -l`。
皆錄 EVIDENCE, LEDGER P1 記 [x]。

## P2 立說

子系(orch, tools, providers, services, infra, domain, shell-plugin, config)各立險說。
三模獨立同題 (`llm-fanout -a`), 合流者記之。說必可證偽, 必附量法(rg/ast-grep/Cargo)。

## P3 證偽

每說一量。行量, 錄數, 勿辯。EVIDENCE 表: 說 | 量令 | 數 | 判。

## P4 裁斷

`gpt-oss:120b-cloud` 裁: CONFIRMED / FALSIFIED / NUANCED, 各一由一後量。
三模合議者信高; 獨說須再量。

## P5 深察

熱點限五至八, 據 P4 果:
`crates/forge_app/src/orch.rs:240` 環; tool dispatch `orch.rs:58` + `tool_registry.rs:28`;
forge_domain tokio 漏 (已 CONFIRMED); forge_services 巨察; 誤處(anyhow/thiserror 規);
`unsafe` 錄; `semgrep` 安察; dep 審 (dep-auditor 使)。
各得 file:line 證, 錄 EVIDENCE。

## P6 錄書

REPORT.md 成 (常英文, 非文言): 圖、判表、險排、諫。
critic 檢之, verify 證之。LEDGER 全 [x] 方止。

## P7 除目

要件: LEDGER 全 [x] + REPORT commit + 主曰 done-done。
乃行 `./teardown.bash --yes` — 除 exec-harness, 一 commit, 史存 git。
主已預許此除 (2026-07-24 feedback)。未 done-done 勿行。
