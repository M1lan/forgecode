---
name: check
description: Checks if the code is ready to be committed
---

- Run `just ci` — the one gate. It repairs what is fixable (rustfmt,
  `clippy --fix`, typos, rumdl, generated docs) and then re-runs the same
  tools in check mode, so a green run means the tree is ready.
- Use `just ci-check` instead when the tree must not be written to.
- Fix every issue it reports, then re-run until it passes. Do not substitute
  raw `cargo fmt` / `cargo clippy` / `cargo insta` invocations: they cover
  less than the gate and skip the shell, docs and spelling lanes.
