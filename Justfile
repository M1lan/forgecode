# Justfile for ForgeCode
# https://github.com/casey/just

set dotenv-load := false
set positional-arguments := true
set shell := ["bash", "-euo", "pipefail", "-c"]

# Workspace crates directory
crates_dir := "crates"

# Cross-compilation targets (matches CI matrix)
cross_targets := "x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin x86_64-pc-windows-msvc aarch64-pc-windows-msvc aarch64-linux-android"

# Default: list available recipes
[doc("Show all available recipes")]
default:
    @just --list --unsorted

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Type-check the workspace (fastest feedback loop)
check:
    cargo check --workspace --all-targets

# Debug build of the full workspace
build:
    cargo build --workspace

# Release build (slow -- LTO + strip; avoid unless shipping)
build-release:
    cargo build --release

# Build a specific crate by name
build-crate crate:
    cargo build -p {{ crate }}

# [fzf] Pick a crate to build
build-pick:
    #!/usr/bin/env bash
    crate=$(ls {{ crates_dir }} | fzf --prompt="build> " --height=40% --reverse)
    [[ -n "$crate" ]] && cargo build -p "$crate"

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

# Run all workspace tests with insta auto-accept
test *args:
    cargo insta test --accept {{ args }}

# Run tests for a specific crate
test-crate crate *args:
    cargo insta test --accept -p {{ crate }} {{ args }}

# Run a single test by name pattern
test-one pattern:
    cargo insta test --accept -- {{ pattern }}

# Run tests with nextest (parallel, better output)
test-nextest *args:
    cargo nextest run --workspace {{ args }}

# [fzf] Pick a crate to test
test-pick:
    #!/usr/bin/env bash
    crate=$(ls {{ crates_dir }} | fzf --prompt="test> " --height=40% --reverse)
    [[ -n "$crate" ]] && cargo insta test --accept -p "$crate"

# [fzf] Pick a test function to run
test-fn:
    #!/usr/bin/env bash
    test=$(cargo test --workspace -- --list 2>/dev/null \
        | rg ':\s*test$' \
        | sed 's/: test$//' \
        | fzf --prompt="test fn> " --height=40% --reverse)
    [[ -n "$test" ]] && cargo insta test --accept -- "$test"

# ---------------------------------------------------------------------------
# Lint & Format
# ---------------------------------------------------------------------------

# Run clippy with warnings-as-errors (matches CI RUSTFLAGS=-Dwarnings)
clippy:
    RUSTFLAGS="-Dwarnings" cargo clippy --workspace --all-targets

# Clippy with auto-fix applied
clippy-fix:
    cargo clippy --workspace --all-targets --fix --allow-dirty --allow-staged

# Format all Rust code
fmt:
    cargo fmt --all

# Check formatting without modifying files
fmt-check:
    cargo fmt --all -- --check

# Full lint pass: format check + clippy
lint: fmt-check clippy

# Auto-fix everything: format + clippy fix
fix: fmt clippy-fix

# ---------------------------------------------------------------------------
# Coverage
# ---------------------------------------------------------------------------

# Generate LCOV coverage report (matches CI)
coverage:
    cargo llvm-cov --all-features --workspace --lcov --output-path lcov.info

# Generate and open HTML coverage report
coverage-html:
    cargo llvm-cov --all-features --workspace --html --open

# ---------------------------------------------------------------------------
# CI (local reproduction)
# ---------------------------------------------------------------------------

# Run the full CI pipeline locally: check + lint + test
ci: check lint test

# Quick pre-push check: format + check + clippy (no full test run)
pre-push: fmt check clippy

# ---------------------------------------------------------------------------
# Benchmarks & Performance
# ---------------------------------------------------------------------------

# Run the zsh rprompt performance benchmark (CI threshold: 60ms)
bench-rprompt:
    ./scripts/benchmark.sh --threshold 60 zsh rprompt

# Run a custom performance benchmark
bench +args:
    ./scripts/benchmark.sh {{ args }}

# Run TypeScript evals suite
eval *args:
    npm run eval -- {{ args }}

# ---------------------------------------------------------------------------
# Database (Diesel / SQLite)
# ---------------------------------------------------------------------------

# Run pending diesel migrations
db-migrate:
    diesel migration run

# Revert the last diesel migration
db-revert:
    diesel migration revert

# Regenerate diesel schema.rs from current DB
db-schema:
    diesel print-schema > crates/forge_repo/src/database/schema.rs

# Create a new diesel migration
db-new name:
    diesel migration generate {{ name }}

# ---------------------------------------------------------------------------
# Release & Cross-compilation
# ---------------------------------------------------------------------------

# Cross-compile for a specific target (e.g. `just cross x86_64-unknown-linux-musl`)
cross target:
    cross build --release --target {{ target }}

# [fzf] Pick a cross-compilation target
cross-pick:
    #!/usr/bin/env bash
    target=$(echo "{{ cross_targets }}" | tr ' ' '\n' \
        | fzf --prompt="cross target> " --height=40% --reverse)
    [[ -n "$target" ]] && cross build --release --target "$target"

# ---------------------------------------------------------------------------
# Code Generation
# ---------------------------------------------------------------------------

# Regenerate the JSON schema from forge binary
schema:
    cargo run -p forge_main -- schema > forge.schema.json

# ---------------------------------------------------------------------------
# Shell Plugin
# ---------------------------------------------------------------------------

# Run zsh format correctness + perf tests
test-zsh:
    zsh scripts/test-zsh-utils.sh

# Run all porcelain list commands
list-porcelain:
    ./scripts/list-all-porcelain.sh

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

# Remove build artifacts
clean:
    cargo clean

# Remove and rebuild from scratch
rebuild: clean build

# Count lines of Rust code in the workspace
loc:
    @tokei {{ crates_dir }}/ -t Rust 2>/dev/null || rg --files -t rust {{ crates_dir }}/ | xargs wc -l | tail -1

# List all workspace crates
crates:
    @ls {{ crates_dir }}

# Show workspace dependency tree (depth 1)
deps:
    cargo tree --workspace --depth 1

# Show dependency tree for a specific crate
deps-crate crate depth='2':
    cargo tree -p {{ crate }} --depth {{ depth }}

# Outdated dependencies
outdated:
    cargo outdated --workspace --root-deps-only 2>/dev/null || cargo outdated --root-deps-only

# Check for known security vulnerabilities
audit:
    cargo audit

# ---------------------------------------------------------------------------
# Git Shortcuts
# ---------------------------------------------------------------------------

# Amend the last commit without editing the message
amend:
    git add -A && git commit --amend --no-edit

# Interactive rebase on main
rebase:
    git rebase -i main

# Show log as oneline graph
log:
    git log --oneline --graph --decorate -20

# ---------------------------------------------------------------------------
# fzf-powered Workflows
# ---------------------------------------------------------------------------

# [fzf] Launcher -- pick an fzf workflow to run
fzf:
    #!/usr/bin/env bash
    declare -A cmds=(
        ["build-pick    Build a crate"]="build-pick"
        ["test-pick     Test a crate"]="test-pick"
        ["test-fn       Run a test function"]="test-fn"
        ["cross-pick    Cross-compile a target"]="cross-pick"
        ["edit          Open a source file"]="edit"
        ["search        Grep + open at line"]="search"
        ["crate-open    Open a crate lib.rs"]="crate-open"
        ["branch        Checkout a branch"]="branch"
        ["show          Inspect a commit"]="show"
        ["pick          Run any just recipe"]="pick"
    )
    label=$(printf '%s\n' "${!cmds[@]}" | sort \
        | fzf --prompt="fzf> " --height=40% --reverse)
    [[ -n "$label" ]] && just "${cmds[$label]}"

# [fzf] Pick any recipe to run
pick:
    #!/usr/bin/env bash
    recipe=$(just --list --unsorted \
        | tail -n +2 \
        | sed 's/^[[:space:]]*//' \
        | fzf --prompt="just> " --height=40% --reverse \
        | awk '{print $1}')
    [[ -n "$recipe" ]] && just "$recipe"

# [fzf] Open a source file in $EDITOR
edit:
    #!/usr/bin/env bash
    file=$(rg --files -t rust {{ crates_dir }}/ \
        | fzf --prompt="edit> " --height=40% --reverse --preview 'head -80 {}')
    [[ -n "$file" ]] && ${EDITOR:-vi} "$file"

# [fzf] Search for a pattern across all Rust files, pick a match, open it
search:
    #!/usr/bin/env bash
    match=$(rg --line-number --no-heading -t rust '.' {{ crates_dir }}/ \
        | fzf --prompt="search> " --height=60% --reverse \
              --preview 'file=$(echo {} | cut -d: -f1); line=$(echo {} | cut -d: -f2); head -n $((line + 30)) "$file" | tail -n 60' \
              --delimiter=: --nth=3..)
    if [[ -n "$match" ]]; then
        file=$(echo "$match" | cut -d: -f1)
        line=$(echo "$match" | cut -d: -f2)
        ${EDITOR:-vi} "+$line" "$file"
    fi

# [fzf] Browse and open a crate directory
crate-open:
    #!/usr/bin/env bash
    crate=$(ls {{ crates_dir }} | fzf --prompt="crate> " --height=40% --reverse)
    [[ -n "$crate" ]] && ${EDITOR:-vi} "{{ crates_dir }}/$crate/src/lib.rs"

# [fzf] Pick a git branch to checkout
branch:
    #!/usr/bin/env bash
    b=$(git branch --all --format='%(refname:short)' \
        | fzf --prompt="branch> " --height=40% --reverse)
    [[ -n "$b" ]] && git checkout "$b"

# [fzf] Pick a recent commit to show
show:
    #!/usr/bin/env bash
    commit=$(git log --oneline -50 \
        | fzf --prompt="commit> " --height=40% --reverse \
              --preview 'git show --stat --color {1}' \
        | awk '{print $1}')
    [[ -n "$commit" ]] && git show "$commit"

# ---------------------------------------------------------------------------
# Dev Convenience
# ---------------------------------------------------------------------------

# Run forge in debug mode with arguments
run *args:
    cargo run -p forge_main -- {{ args }}

# Watch for changes and re-check (requires cargo-watch)
watch:
    cargo watch -x 'check --workspace'

# Watch and run tests on change
watch-test:
    cargo watch -x 'insta test --accept'

# Watch a specific crate's tests
watch-crate crate:
    cargo watch -x 'insta test --accept -p {{ crate }}'

# Install the debug binary locally (~/.cargo/bin/forge)
install:
    cargo install --path crates/forge_main

# Print environment info useful for bug reports
info:
    @echo "rust:  $(rustc --version)"
    @echo "cargo: $(cargo --version)"
    @echo "just:  $(just --version)"
    @echo "os:    $(uname -srm)"
    @echo "fzf:   $(fzf --version 2>/dev/null || echo 'not installed')"
