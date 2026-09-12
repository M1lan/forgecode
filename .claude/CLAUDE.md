<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->

## Correction to the block above, measured on this repo (2026-08-08)

CodeGraph's own text offers `codegraph explore "<symbol names **or question**>"`.
In this repo the question form does not work. Two trials, both natural-language:
it returned a Python file for "what CLI subcommands does forge_main expose?" and
missed `database/pool.rs` entirely for "where is the DB path decided?". The same
tool, given the bag of names `PoolConfig DatabasePool database_path Environment`,
found every correct file.

**Give CodeGraph names. Give prose to `grepai search`.**

The full five-tool contract — and which of `rg`, `grepai`, `codegraph`,
`gitnexus` and `ast-grep` owns which question — is in `AGENTS.md`, section
"Code intelligence". `repowise` was removed from this project on 2026-08-08.
