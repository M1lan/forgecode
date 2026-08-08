# --- ForgeCode Justfile -- the SDLC of this Rust workspace, and nothing else. ---
#
# Scope: build, run, test, lint, gate, install, sync with upstream, clean.
# Everything interactive or multi-step lives in .just/helpers/.
#
#   bare `just`   info splash -> menu
#   just menu     the only interactive launcher (fzf + gum)
#   just doctor   what is installed, what is missing, how to fix it
#   just docs     regenerate docs/justfile.md from this file
#
# Machine contract: `just --dump --dump-format json`. Do not scrape --list.
#
# TWO RULES THIS FILE FOLLOWS
#
# 1. NO SILENT SKIPS. A recipe whose tool is missing exits non-zero via
#    `tools.bash need`, printing the install command. The previous version
#    had nineteen `if command -v X; then …; else printf 'not installed'; fi`
#    blocks, all exiting 0 -- so `just verify` and `just ci` could both pass
#    having linted and tested nothing at all.
#
# 2. ARGUMENTS ARE ARGUMENTS. Variadic recipes use "$@", not {{ args }}.
#    `set positional-arguments` (below) has been on the whole time; nothing
#    used it. Textual interpolation word-split every quoted argument --
#    `just search "fn main"` searched for `fn` in a directory called `main`,
#    printed an error, and exited 0.

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false
set positional-arguments := true

# PERF: machine-global BASH_ENV (shell-id-boot -> agent-bash-env DEBUG-trap)
# costs 0.3-1.5s per non-interactive bash spawn; `just menu` spawns bash
# >=2x pre-draw. Neutralized here -> ~24ms/spawn. Escape hatch:
# JUST_BASH_ENV=<file> just <recipe>.
export BASH_ENV := env("JUST_BASH_ENV", "")

export RUST_BACKTRACE := "1"

crates_dir := "crates"
bin := "forge"
# The workspace has 25 members but exactly one [[bin]]: forge, from
# forge_main. `cargo build` without -p compiles all 25 -- under the release
# profile that means lto=true + codegen-units=1 across the whole tree for a
# binary that needs one crate's worth of linking.
main_crate := "forge_main"
helpers := justfile_directory() / ".just" / "helpers"
tools := justfile_directory() / ".just" / "helpers" / "tools.bash"

# Canonical install dir: fixed to ~/.cargo/bin, by explicit request --
# CARGO_HOME, CARGO_INSTALL_ROOT, and Cargo's own install.root config are
# deliberately NOT honored here. `install` always writes {{ bin }} to this
# one literal path; install-audit checks the same fixed path.
cargo_bin_dir := env("HOME") / ".cargo" / "bin"

# Sandbox for recipes that EXECUTE the binary.
#
# forge resolves its state dir as: $FORGE_CONFIG -> ~/forge if that exists
# -> ~/.forge (crates/forge_config/src/reader.rs:63-84, memoized for the
# process lifetime). On this machine ~/forge EXISTS -- it is the oh-my-forge
# agent home -- so an unsandboxed `just run` reads and writes the operator's
# live ~/forge/.forge.db, agents/, skills/, logs/ and history. A dev build
# with a migration bug would corrupt real state. Recipes that run the binary
# therefore point FORGE_CONFIG here; `run-live` is the explicit opt-out.
sandbox := justfile_directory() / ".forge-sandbox"

alias m := menu
alias t := test
alias b := build
alias c := check
alias d := doctor
alias i := info

# --- Meta ---

# bare-just splash: facts + countdown -> menu
[private]
[no-exit-message]
default:
    @'{{ helpers }}/info-screen.bash'

# machine/agent recipe list (parse `just --dump --dump-format json` when scripting)
[group('meta')]
help:
    @just --list --unsorted

# project+tool status screen (no countdown; splash variant)
[group('meta')]
[no-exit-message]
info:
    @'{{ helpers }}/info-screen.bash' --static

# the only interactive TUI: fzf over all recipes, gum forms for params
[group('meta')]
[no-exit-message]
menu:
    @'{{ helpers }}/menu.bash'

# what is installed, what is missing, and the exact command to fix it
[group('meta')]
[no-exit-message]
doctor:
    @'{{ helpers }}/doctor.bash'

# regenerate docs/justfile.md from this file (never hand-edit that file)
[group('meta')]
docs:
    @'{{ helpers }}/docs.bash' --write

# fail if docs/justfile.md has drifted from this file; part of `just ci`
[group('meta')]
docs-check:
    @'{{ helpers }}/docs.bash' --check

# --- Build ---

# Type-check the whole workspace including tests and benches. Fastest gate.
[group('build')]
check:
    cargo check --workspace --all-targets

# Build the forge binary (debug). One crate, not all 25.
[group('build')]
build:
    cargo build -p {{ main_crate }}

# Build the entire workspace (debug) -- only needed before a full test run.
[group('build')]
build-workspace:
    cargo build --workspace

# Build the forge binary with the release profile (lto, codegen-units=1: slow).
[group('build')]
build-release:
    cargo build --release -p {{ main_crate }}

# Build one crate by name.
[group('build')]
build-crate crate:
    cargo build -p "$1"

# --- Run & Dev ---

# Run the freshly built forge against an isolated state dir (see `sandbox`).
[group('run')]
run *args:
    @mkdir -p '{{ sandbox }}'
    FORGE_CONFIG='{{ sandbox }}' FORGE_TRACKER=false cargo run -p {{ main_crate }} -- "$@"

# Run against your REAL ~/forge state. Mutates live agents, skills and DB.
[group('run')]
run-live *args:
    cargo run -p {{ main_crate }} -- "$@"

# Delete the run sandbox state dir.
[group('run')]
run-sandbox-reset:
    @'{{ helpers }}/clean.bash' sandbox

# Type-check on every save.
[group('run')]
watch:
    @'{{ tools }}' need cargo-watch
    cargo watch -x 'check --workspace --all-targets'

# Run the test suite on every save.
[group('run')]
watch-test:
    @'{{ tools }}' need cargo-watch cargo-insta
    cargo watch -x 'insta test --accept'

# Watch one crate's tests.
[group('run')]
watch-crate crate:
    @'{{ tools }}' need cargo-watch cargo-insta
    cargo watch -x "insta test --accept -p $1"

# --- Test ---

# WARNING, and it is not obvious: `just test` REWRITES FILES. Two of the four
# tests/ dirs are generators -- crates/forge_ci/tests/ci.rs writes every
# .github/workflows/*.yml, crates/forge_config/tests/schema.rs writes
# forge.schema.json -- and --accept rewrites any drifted snapshot. A green
# `just test` can leave a dirty tree. `just test-check` is the read-only form.
#
# NOTE ON DOC COMMENTS IN THIS FILE: `just` takes only the LAST contiguous
# comment line as a recipe's doc, so long explanations live above a blank
# line and the one-line doc sits directly on top of the attributes.

# Workspace tests. insta drives nextest and ACCEPTS snapshots (writes files).
[group('test')]
test *args:
    @'{{ tools }}' need cargo-insta cargo-nextest
    cargo insta test --accept "$@"

# Read-only test run: fails on snapshot drift instead of accepting it.
[group('test')]
test-check *args:
    @'{{ tools }}' need cargo-nextest
    CI=1 cargo nextest run --workspace "$@"

# Tests for one crate.
[group('test')]
test-crate crate *args:
    @'{{ tools }}' need cargo-insta cargo-nextest
    cargo insta test --accept -p "$@"

# Tests matching a name filter.
[group('test')]
test-one pattern *args:
    @'{{ tools }}' need cargo-nextest
    cargo nextest run --workspace -E "test(/$1/)" "${@:2}"

# All of shell-plugin/ is include_dir!/include_str!-baked into forge
# (crates/forge_main/src/zsh/plugin.rs). A syntax error in a .zsh file
# compiles cleanly and only explodes in the user's shell at startup. Before
# this recipe, zsh was never parse-checked anywhere in the repo.

# Parse-check every shell file this repo embeds into the binary or ships.
[group('test')]
test-shell:
    @'{{ helpers }}/test-shell.bash'

# The zsh format/rprompt CLI tests (needs the debug binary).
[group('test')]
test-zsh: build
    @'{{ tools }}' need zsh
    zsh scripts/test-zsh-utils.zsh

# TypeScript LLM eval suite. pnpm, never npm.
[group('test')]
eval *args: node-install
    pnpm run eval -- "$@"

# Install the TypeScript toolchain for the eval suite.
[group('test')]
node-install:
    @'{{ tools }}' need pnpm
    pnpm install --frozen-lockfile

# --- Lint & Format ---

# Format Rust with the NIGHTLY rustfmt (.rustfmt.toml uses unstable options).
[group('lint')]
fmt:
    @'{{ tools }}' need rustfmt
    PATH="$(rustup run nightly rustc --print sysroot)/bin:$PATH" cargo fmt --all

# Verify formatting without writing.
[group('lint')]
fmt-check:
    @'{{ tools }}' need rustfmt
    PATH="$(rustup run nightly rustc --print sysroot)/bin:$PATH" cargo fmt --all -- --check

# Clippy, warnings denied. Matches what CI's autofix lane compiles.
[group('lint')]
clippy:
    @'{{ tools }}' need clippy
    RUSTFLAGS="-Dwarnings" cargo clippy --workspace --all-targets --all-features

# CURRENTLY FAILS, on upstream code, by design of this recipe.
#
# GitHub's autofix workflow runs exactly these three lints. Nothing local
# ever did, so nobody saw that the tree does not pass them. Verified
# 2026-08-08, two violations, both pre-existing:
#
#   crates/forge_select/src/multi.rs:62    self.options[index]
#   crates/forge_select/src/select.rs:122  self.options[absolute]
#
# Deliberately NOT a dependency of `lint` or `verify`: fixing them means
# editing upstream Rust that this fork will merge again, and that is a
# separate decision from wiring up the build system. Run it, read it, decide.

# The string-safety lane CI runs and this Justfile never did.
[group('lint')]
clippy-strict:
    @'{{ tools }}' need clippy
    cargo clippy --all-features --workspace -- \
      -D clippy::string_slice -D clippy::indexing_slicing -D clippy::disallowed_methods

# Apply clippy's machine-applicable fixes.
[group('lint')]
clippy-fix:
    @'{{ tools }}' need clippy
    cargo clippy --workspace --all-targets --all-features --fix --allow-dirty --allow-staged

# Shell lint over the Justfile system + the POSIX installer. Blocking.
[group('lint')]
shellcheck:
    @'{{ helpers }}/lint-shell.bash'

# Markdown lint.
[group('lint')]
rumdl:
    @'{{ tools }}' need rumdl
    rumdl .

# Spelling lint (typos.toml exempts deliberate test fixtures).
[group('lint')]
typos:
    @'{{ tools }}' need typos
    typos

# Everything that only reads: format check, clippy, shell, markdown, spelling.
[group('lint')]
lint: fmt-check clippy clippy-strict shellcheck rumdl typos

# Everything that writes: format, clippy fixes.
[group('lint')]
fix: fmt clippy-fix

# --- The gate ---

# THERE IS ONE GATE AND IT IS `just ci`.
#
# `verify` used to exist alongside it with a different, overlapping step
# list, so whether the tree "passed" depended on which of the two you ran.
# It is gone. `ci` is the answer to "is this good to push?".
#
# It repairs before it judges: rustfmt, `clippy --fix`, typos, rumdl and the
# generated docs all run in a fix phase first, and only then does the same
# set of tools run again in check mode. Printing "run cargo fmt" at a human
# who has a formatter installed is a waste of both of them.
#
# `just ci-check` is the read-only form, for hooks and for confirming a tree
# you do not want touched.

# Fix everything fixable, then prove the tree. The one gate.
[group('gate')]
ci:
    @'{{ helpers }}/ci.bash'

# The same gate, read-only: writes nothing, just reports.
[group('gate')]
ci-check:
    @'{{ helpers }}/ci.bash' --check

# Fast subset for a tight commit loop -- not a substitute for `just ci`.
[group('gate')]
pre-push: fmt-check check clippy

# Fail if any source file changed during a build/test run.
[group('gate')]
verify-clean-tree:
    @'{{ helpers }}/clean.bash' assert-clean

# Known Rust security advisories.
[group('verify')]
audit:
    @'{{ tools }}' need cargo-audit
    cargo audit

# One line per advisory: ID pkg@version fixed-in title.
[group('verify')]
audit-brief:
    @'{{ helpers }}/maint.bash' audit-brief

# Unused dependencies (false positives on macro-only deps are expected).
[group('verify')]
machete:
    @'{{ tools }}' need cargo-machete
    cargo machete

# Licenses, bans and advisories.
[group('verify')]
deny:
    @'{{ tools }}' need cargo-deny
    cargo deny check

# Verify Cargo.toml's rust-version claim is true (it claims 1.94; the pin is 1.97).
[group('verify')]
msrv:
    @'{{ tools }}' need cargo-msrv
    cargo msrv verify --path {{ crates_dir }}/{{ main_crate }}

# betterhook status.
[group('verify')]
hooks:
    @'{{ tools }}' need betterhook
    betterhook status

# Dry-run the pre-commit job plan.
[group('verify')]
hooks-plan:
    @'{{ tools }}' need betterhook
    betterhook run pre-commit --dry-run

# Run the pre-commit jobs now.
[group('verify')]
hooks-run:
    @'{{ tools }}' need betterhook
    betterhook run pre-commit

# --- Coverage & Benchmark ---

# LCOV report, same invocation as the GitHub build job.
[group('coverage')]
coverage:
    @'{{ tools }}' need cargo-llvm-cov
    cargo llvm-cov --all-features --workspace --lcov --output-path lcov.info

# HTML report, opened in a browser.
[group('coverage')]
coverage-html:
    @'{{ tools }}' need cargo-llvm-cov
    cargo llvm-cov --all-features --workspace --html --open

# The zsh rprompt latency gate CI runs. Needs the debug binary.
[group('coverage')]
bench-rprompt: build
    ./scripts/benchmark.sh --threshold 60 zsh rprompt

# Arbitrary benchmark arguments. Needs the debug binary.
[group('coverage')]
bench *args: build
    ./scripts/benchmark.sh "$@"

# --- Install (local) ---

# Build and install the release binary to the fixed {{ cargo_bin_dir }}/{{ bin }}.
[group('install')]
install:
    @'{{ helpers }}/install.bash' release

# A distinct FILENAME, not a distinct directory, so forge-debug can never
# shadow the canonical forge. Unstripped, so lldb has symbols that the
# release profile (strip = true) throws away.

# Build and install the debug binary as {{ bin }}-debug.
[group('install')]
install-debug:
    @'{{ helpers }}/install.bash' debug

# Install both binaries.
[group('install')]
install-both: install install-debug

# Rebuild from scratch and reinstall the release binary.
[group('install')]
reinstall: clean install

# Rebuild from scratch and reinstall both binaries.
[group('install')]
reinstall-both: clean install-both

# Enumerate PATH shadows for {{ bin }}; fails when the winner is not canonical.
[group('install')]
install-audit:
    @'{{ helpers }}/install-audit.bash' --table

# --- Upstream (fork maintenance) ---

# Merge, never rebase: this fork carries 56+ commits on mymain and a linked
# worktree. A rebase rewrites every one of those SHAs, breaks the worktree
# and forces a push. The old `rebase` recipe did exactly that, and aimed at
# `main` (the upstream line) while the default branch is `mymain`.

# Fetch upstream, fast-forward local main, then MERGE it into this branch.
[group('upstream')]
sync-upstream:
    @'{{ helpers }}/upstream.bash' sync

# How far behind upstream this fork is, and what would merge. Read-only.
[group('upstream')]
upstream-status:
    @'{{ helpers }}/upstream.bash' status

# Fetch upstream without merging anything.
[group('upstream')]
upstream-fetch:
    @'{{ helpers }}/upstream.bash' fetch

# --- Codegen ---

# There is no `forge schema` subcommand -- the old recipe ran one anyway, and
# because `>` truncates before cargo starts, it emptied this committed,
# test-asserted file on every invocation. The real generator is a test:
# crates/forge_config/tests/schema.rs writes the file when CI is unset.

# Regenerate forge.schema.json (via the forge_config schema test).
[group('codegen')]
schema:
    cargo test -p forge_config --test schema

# Assert forge.schema.json is current without rewriting it.
[group('codegen')]
schema-check:
    CI=1 cargo test -p forge_config --test schema

# Those YAML files are GENERATED (see their header). Hand-editing them is
# lost on the next `just test`, because forge_ci's "test" writes them.

# Regenerate .github/workflows/*.yml from crates/forge_ci.
[group('codegen')]
workflows:
    cargo test -p forge_ci --test ci

# --- Database (diesel: schema authoring only) ---

# The shipped binary never needs diesel-cli: migrations are embedded via
# embed_migrations! and applied at pool creation. These recipes exist to
# AUTHOR migrations, and they operate on the sandbox DB, never on the
# operator's live ~/forge/.forge.db.

# Create a new migration directory.
[group('database')]
db-new name:
    @'{{ tools }}' need diesel
    diesel migration generate "$1"

# Apply pending migrations to the sandbox database.
[group('database')]
db-migrate:
    @'{{ helpers }}/db.bash' migrate

# Revert the latest migration on the sandbox database.
[group('database')]
db-revert:
    @'{{ helpers }}/db.bash' revert

# Regenerate schema.rs from the sandbox database (path comes from diesel.toml).
[group('database')]
db-schema:
    @'{{ helpers }}/db.bash' schema

# --- Clean (this repo is large: target/ alone is tens of GB) ---

# Show what each cleanable location costs, in bytes on disk. Read-only.
[group('clean')]
clean-report:
    @'{{ helpers }}/clean.bash' report

# cargo clean: removes target/ entirely.
[group('clean')]
clean:
    @'{{ helpers }}/clean.bash' target

# Remove all build artifacts, then rebuild the forge binary from scratch.
[group('clean')]
rebuild: clean build

# Drop incremental-compilation caches and stale profile dirs, keep the rest.
[group('clean')]
clean-stale:
    @'{{ helpers }}/clean.bash' stale

# Move the local AI index dirs to Trash (recoverable). Asks first.
[group('clean')]
clean-indexes:
    @'{{ helpers }}/clean.bash' indexes

# Never touches ~/.cargo/registry, ~/.cargo/git, or anything outside this
# repository -- those caches are shared by every Rust checkout on the machine.

# Everything repo-local: target, indexes, node_modules, sandbox. Asks first.
[group('clean')]
clean-all:
    @'{{ helpers }}/clean.bash' all

# --- Maintenance (bounded, evidence-first) ---
#
# Ported from the agent-maint-justfile branch and rewritten to fail loud.
# Convention: maint-* is read-only evidence; maint-*-fix mutates exactly ONE
# file and prints the diff. Deliberately absent, with reasons:
#   - bulk `cargo update`: most advisories here sit behind semver walls
#     (rustls 0.21 / hyper-0.14 / aws-smithy / syntect). Use maint-pin-why.
#   - blanket shellcheck auto-apply: scripts/benchmark.sh relies on
#     intentional word-splitting. Use maint-shellcheck-diff and read it.
#   - `cargo machete --fix`: false positives on macro-only deps.

# Bounded evidence pack: advisories, typos, unused deps, shell + markdown lint.
[group('maint')]
maint-evidence:
    @'{{ helpers }}/maint.bash' evidence

# Who pins this crate? Inverted dependency tree, for advisory triage.
[group('maint')]
maint-pin-why pkg:
    cargo tree -i "$1" --depth 6

# Fix typos in exactly ONE file, then show the diff. Refuses snapshots/fixtures.
[group('maint')]
maint-typos-fix file:
    @'{{ helpers }}/maint.bash' typos-fix "$1"

# Lint then format exactly ONE markdown file, show the diff stat.
[group('maint')]
maint-rumdl-fix file:
    @'{{ helpers }}/maint.bash' rumdl-fix "$1"

# Shellcheck's auto-fix as a REVIEW diff -- never applied.
[group('maint')]
maint-shellcheck-diff file:
    @'{{ helpers }}/maint.bash' shellcheck-diff "$1"

# --- Debug (manual, on purpose) ---
#
# These wrap scripts in scripts/ that nothing calls automatically. That is
# the normal state for a script: it exists to be picked up deliberately when
# it is the right tool, not to be wired into a pipeline. The recipes exist so
# `just menu` can surface them -- a script nobody can find is the actual
# problem, not a script nobody calls.

# Tail today's forge log with highlighting (needs FORGE_TRACKER=false to have
# produced a file -- with tracking on, the writer is PostHog, not disk).
[group('debug')]
logs-follow:
    ./scripts/debug-follow-log.bash

# Run every `forge list --porcelain` variant and time it. Needs the debug binary.
[group('debug')]
list-porcelain: build
    ./scripts/list-all-porcelain.sh

# Manual e2e: prove a provider 400 surfaces its full response body.
# Variadic, not two defaulted params: the script uses ${1:-default}, and an
# empty positional is set, so defaulted params would defeat its own defaults.
# NEEDS LIVE PROVIDER CREDENTIALS and talks to the network -- never in a gate.
[group('debug')]
test-400 *args:
    ./scripts/test-400-error-message.sh "$@"

# Amend the last commit without changing its message.
[group('git')]
amend:
    git add -A && git commit --amend --no-edit

# --- Inspect ---

# Workspace package names, from cargo metadata (not a directory listing).
[group('inspect')]
crates:
    @cargo metadata --no-deps --format-version 1 | jq -r '.packages[].name' | sort

# Rust line counts.
[group('inspect')]
loc:
    @'{{ tools }}' need tokei
    tokei {{ crates_dir }}/ -t Rust

# Direct dependencies of every workspace member.
[group('inspect')]
deps:
    cargo tree --workspace --depth 1

# Dependency tree for one crate.
[group('inspect')]
deps-crate crate depth='2':
    cargo tree -p "$1" --depth "$2"

# Dependencies with newer versions available.
[group('inspect')]
outdated:
    @'{{ tools }}' need cargo-outdated
    cargo outdated --workspace --root-deps-only

# What takes up space in the release binary.
[group('inspect')]
bloat:
    @'{{ tools }}' need cargo-bloat
    cargo bloat --release -n 20

# Recent commit graph.
[group('inspect')]
log:
    git log --oneline --graph --decorate -20

# --- Local code intelligence ---

# One passthrough instead of eleven near-identical recipes. The tool contract
# (which tool answers which question) is documented in AGENTS.md.

# Local code-intelligence indexes: ai status|init|sync|search|<tool> ...
[group('ai')]
ai *args:
    @'{{ helpers }}/ai-tools.bash' "$@"

# --- Cross-compilation ---

# Cross-compile the release binary for one target triple.
[group('release')]
cross target:
    @'{{ tools }}' need cross
    cross build --release -p {{ main_crate }} --target "$1"
