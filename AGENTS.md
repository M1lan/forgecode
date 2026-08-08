# Agent Guidelines

This document contains guidelines and best practices for AI agents working with this codebase.

## Error Management

- Use `anyhow::Result` for error handling in services and repositories.
- Create domain errors using `thiserror`.
- Never implement `From` for converting domain errors, manually convert them

## Writing Tests

- All tests should be written in three discrete steps:

  ```rust,ignore
  use pretty_assertions::assert_eq; // Always use pretty assertions

  fn test_foo() {
      let setup = ...; // Instantiate a fixture or setup for the test
      let actual = ...; // Execute the fixture to create an output
      let expected = ...; // Define a hand written expected result
      assert_eq!(actual, expected); // Assert that the actual result matches the expected result
  }
  ```

- Use `pretty_assertions` for better error messages.

- Use fixtures to create test data.

- Use `assert_eq!` for equality checks.

- Use `assert!(...)` for boolean checks.

- Use unwraps in test functions and anyhow::Result in fixtures.

- Keep the boilerplate to a minimum.

- Use words like `fixture`, `actual` and `expected` in test functions.

- Fixtures should be generic and reusable.

- Test should always be written in the same file as the source code.

- Use `new`, Default and derive_setters::Setters to create `actual`, `expected` and specially `fixtures`. For example:

  **Good:**

  ```rust,ignore
  User::default().age(12).is_happy(true).name("John")
  User::new("Job").age(12).is_happy()
  User::test() // Special test constructor
  ```

  **Bad:**

  ```rust,ignore
  User {name: "John".to_string(), is_happy: true, age: 12}
  User::with_name("Job") // Bad name, should stick to User::new() or User::test()
  ```

- Use `unwrap()` unless the error information is useful. Use `expect` instead of `panic!` when error message is useful. For example:

  **Good:**

  ```rust,ignore
  users.first().expect("List should not be empty")
  ```

  **Bad:**

  ```rust,ignore
  if let Some(user) = users.first() {
      // ...
  } else {
      panic!("List should not be empty")
  }
  ```

- Prefer using `assert_eq` on full objects instead of asserting each field:

  **Good:**

  ```rust,ignore
  assert_eq!(actual, expected);
  ```

  **Bad:**

  ```rust,ignore
  assert_eq!(actual.a, expected.a);
  assert_eq!(actual.b, expected.b);
  ```

## Verification

Go through `just`. The Justfile is the single source of truth for every gate;
betterhook's git hooks call the same recipes, so a gate that passes locally
passes in the hook by construction. Full recipe reference: `docs/justfile.md`
(generated — run `just docs` after changing a recipe, `just docs-check` gates it).

**There is one gate: `just ci`.** It repairs before it judges — rustfmt,
`clippy --fix`, typos, rumdl and the generated docs all run first, then the
same tools run again in check mode. A lint that a tool can fix is not
something to report at a human.

1. `just check` — type-check the workspace. Fastest.
2. `just ci` — fix everything fixable, then prove the tree. **Use this.**
3. `just ci-check` — the same gate, read-only. What the pre-push hook runs.

`just ci` can modify files. That is the point; review and commit them.
`just ci-check` never writes.

**`just test` rewrites files.** Two of the four `tests/` dirs are generators:
`crates/forge_ci/tests/ci.rs` writes every `.github/workflows/*.yml`, and
`crates/forge_config/tests/schema.rs` writes `forge.schema.json`. `--accept`
also rewrites any drifted snapshot. Use `just test` when you intend to accept
snapshots; use `just test-check` when you are verifying. `just
verify-clean-tree` proves nothing was silently regenerated.

**No recipe skips silently.** A missing tool exits non-zero with the install
command attached. If something is missing, `just doctor` lists everything.

**Build guidelines**:

- **NEVER** run `cargo build --release` unless absolutely necessary. Use
  `just check`, `just test-check`, or `just build` (debug, one crate).
- `just build` builds only `forge_main`; `just build-workspace` builds all 25.
- `protoc` is a hard build dependency (`crates/forge_repo/build.rs`).

## Code intelligence — which tool answers which question

Five tools, five jobs, no overlap. Chosen by measurement on this repo
(2026-08-08), not by reputation. Do not reach for a second tool that answers
the question a cheaper one already answered.

| question | tool | why this one |
|---|---|---|
| what does the build system actually contain? | `cargo metadata --no-deps`, `just --dump --dump-format json` | deterministic, no index, no AI. Ground truth. |
| where is a thing whose **name** I know? | `rg` / `fd` | 17 ms and complete. Beat both graph tools on named symbols. |
| where is a thing I can only describe by **meaning**? | `grepai search "<prose>"` | 0.2 s, ~5 KB. The only semantic index that also covers `.bash`, `.zsh`, `.md` and `.sql`. |
| show me the **source and callers** of names I already have | `codegraph explore "Name1 Name2 Name3"` | returns verbatim, line-numbered source; replaces a Read. |
| what breaks if I change this symbol? | `gitnexus impact` | 137 ms, ~2 KB. Nothing else computes blast radius. |
| enforce or rewrite a code **pattern** | `ast-grep` (`sgconfig.yml`, `rules/`) | real AST rules for Rust and Bash. |

**`codegraph` takes names, never questions.** Given a natural-language
question it returned unrelated files in both measured trials; given a bag of
symbol names it found the right code every time. It also self-reports a small
per-project explore budget, so spend it deliberately.

**`ast-grep` cannot parse the Justfile** — there is no `just`/`make` grammar.
Use `rg` there.

**`repowise` was removed** on 2026-08-08: its synthesis timed out at 32 s
returning nothing, its index was 11 days stale, and every question it answered
was answered faster by one of the five above.

Index maintenance goes through one recipe: `just ai status|init|sync|search`.

## Git Operations — fork layout

This checkout is a fork. `origin` is the fork; `upstream` is the project it
was forked from. Local `main` is a pure mirror of `upstream/main`; the work
lives on `mymain`.

**Never rebase `mymain`.** It carries 56+ commits and there is a linked
worktree; a rebase rewrites every SHA, breaks the worktree and forces a push.
Use `just sync-upstream`, which fast-forwards the mirror and merges.
`just upstream-status` shows what would land, read-only.

`.github/workflows/*.yml` are **generated** from `crates/forge_ci` — edit the
Rust, then `just workflows`. Hand-edits are lost on the next `just test`.

## Writing Domain Types

- Use `derive_setters` to derive setters and use the `strip_option` and the `into` attributes on the struct types.

## Documentation

- **Always** write Rust docs (`///`) for all public methods, functions, structs, enums, and traits.
- Document parameters with `# Arguments` and errors with `# Errors` sections when applicable.
- **Do not include code examples** - docs are for LLMs, not humans. Focus on clear, concise functionality descriptions.

## Refactoring

- If asked to fix failing tests, always confirm whether to update the implementation or the tests.

## Git Operations

- Safely assume git is pre-installed
- Safely assume github cli (gh) is pre-installed
- Never add commit trailers of any kind (no `Co-Authored-By`, no `Assisted-By`) to git commits, PRs, or GitHub comments — operator global rule (2026-07-24) supersedes the former ForgeCode trailer requirement

## Service Implementation Guidelines

Services should follow clean architecture principles and maintain clear separation of concerns:

### Core Principles

- **No service-to-service dependencies**: Services should never depend on other services directly
- **Infrastructure dependency**: Services should depend only on infrastructure abstractions when needed
- **Single type parameter**: Services should take at most one generic type parameter for infrastructure
- **No trait objects**: Avoid `Box<dyn ...>` - use concrete types and generics instead
- **Constructor pattern**: Implement `new()` without type bounds - apply bounds only on methods that need them
- **Compose dependencies**: Use the `+` operator to combine multiple infrastructure traits into a single bound
- **Arc<T> for infrastructure**: Store infrastructure as `Arc<T>` for cheap cloning and shared ownership
- **Tuple struct pattern**: For simple services with single dependency, use tuple structs `struct Service<T>(Arc<T>)`

### Examples

#### Simple Service (No Infrastructure)

```rust,ignore
pub struct UserValidationService;

impl UserValidationService {
    pub fn new() -> Self { ... }

    pub fn validate_email(&self, email: &str) -> Result<()> {
        // Validation logic here
        ...
    }

    pub fn validate_age(&self, age: u32) -> Result<()> {
        // Age validation logic here
        ...
    }
}
```

#### Service with Infrastructure Dependency

```rust,ignore
// Infrastructure trait (defined in infrastructure layer)
pub trait UserRepository {
    fn find_by_email(&self, email: &str) -> Result<Option<User>>;
    fn save(&self, user: &User) -> Result<()>;
}

// Service with single generic parameter using Arc
pub struct UserService<R> {
    repository: Arc<R>,
}

impl<R> UserService<R> {
    // Constructor without type bounds, takes Arc<R>
    pub fn new(repository: Arc<R>) -> Self { ... }
}

impl<R: UserRepository> UserService<R> {
    // Business logic methods have type bounds where needed
    pub fn create_user(&self, email: &str, name: &str) -> Result<User> { ... }
    pub fn find_user(&self, email: &str) -> Result<Option<User>> { ... }
}
```

#### Tuple Struct Pattern for Simple Services

```rust,ignore
// Infrastructure traits
pub trait FileReader {
    async fn read_file(&self, path: &Path) -> Result<String>;
}

pub trait Environment {
    fn max_file_size(&self) -> u64;
}

// Tuple struct for simple single dependency service
pub struct FileService<F>(Arc<F>);

impl<F> FileService<F> {
    // Constructor without bounds
    pub fn new(infra: Arc<F>) -> Self { ... }
}

impl<F: FileReader + Environment> FileService<F> {
    // Business logic methods with composed trait bounds
    pub async fn read_with_validation(&self, path: &Path) -> Result<String> { ... }
}
```

### Anti-patterns to Avoid

```rust,ignore
// BAD: Service depending on another service
pub struct BadUserService<R, E> {
    repository: R,
    email_service: E, // Don't do this!
}

// BAD: Using trait objects
pub struct BadUserService {
    repository: Box<dyn UserRepository>, // Avoid Box<dyn>
}

// BAD: Multiple infrastructure dependencies with separate type parameters
pub struct BadUserService<R, C, L> {
    repository: R,
    cache: C,
    logger: L, // Too many generic parameters - hard to use and test
}

impl<R: UserRepository, C: Cache, L: Logger> BadUserService<R, C, L> {
    // BAD: Constructor with type bounds makes it hard to use
    pub fn new(repository: R, cache: C, logger: L) -> Self { ... }
}

// BAD: Usage becomes cumbersome
let service = BadUserService::<PostgresRepo, RedisCache, FileLogger>::new(...);
```

## Active known bug + deferred work (forge-zsh shell-plugin)

Operator note, 2026-06-15. Relevant here because `forge-zsh` lives in
`shell-plugin/`.

- KNOWN BUG (CRITICAL): after `C-c C-c` then re-sending a prompt via
  `:`, forge-zsh can resume the WRONG conversation in the WRONG cwd --
  a session started in a different Ghostty window -- even though cwd
  never changed. Suspected: `:` dispatch resolves "current
  conversation" from global/last-active state instead of pinning to
  this terminal. Investigation: `shell-plugin/lib/` (dispatcher,
  bindings, context). If session/cwd feels off after abort+resend,
  STOP and confirm identity first.
- DEFERRED: a multi-topic improvement draft (per-tty session pinning via
  a Ghostty-window-title short-id mirrored to a `~` entity tree; omf
  tool; readline/steering UX) is parked, NOT for ad-hoc execution.
- Canonical home: `~/prompts/experiments/forge-system-cohesion/`.

Respond terse like smart caveman. All technical substance stay. Only fluff die.

Rules:

- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan
Stop: "stop caveman" or "normal mode"

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.

<!-- gitnexus:start -->
## GitNexus — Code Intelligence

This project is indexed by GitNexus as **forgecode** (14157 symbols, 33288 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

### Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "mymain"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

### Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

### Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/forgecode/context` | Codebase overview, check index freshness |
| `gitnexus://repo/forgecode/clusters` | All functional areas |
| `gitnexus://repo/forgecode/processes` | All execution flows |
| `gitnexus://repo/forgecode/process/{name}` | Step-by-step execution trace |

### CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
