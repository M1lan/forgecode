# ── ForgeCode Justfile -- Build, test, lint, ship ──

set dotenv-load := false
set positional-arguments := true
set shell := ["bash", "-euo", "pipefail", "-c"]

export RUST_BACKTRACE := "1"

# Workspace crates directory
crates_dir := "crates"

# Binary name
bin := "forge"

# Install destination
install_dir := env("HOME") / ".local/bin"

# Cross-compilation targets (matches CI matrix)
cross_targets := "x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin x86_64-pc-windows-msvc aarch64-pc-windows-msvc aarch64-linux-android"

# ── Meta ──────────────────────────────────────────────────────────────────────

# Show all available recipes
default:
    @just --list --unsorted

# Print project name and tool versions
info:
    @echo "ForgeCode"
    @echo "─────────────────────────────"
    @echo "rust:      $(rustc --version)"
    @echo "cargo:     $(cargo --version)"
    @echo "just:      $(just --version)"
    @echo "os:        $(uname -srm)"
    @echo "─────────────────────────────"
    @if command -v fzf      >/dev/null 2>&1; then echo "fzf:       $(fzf --version)";       else echo "fzf:       not installed"; fi
    @if command -v bat      >/dev/null 2>&1; then echo "bat:       $(bat --version | head -1)"; else echo "bat:       not installed"; fi
    @if command -v rg       >/dev/null 2>&1; then echo "rg:        $(rg --version | head -1)";  else echo "rg:        not installed"; fi
    @if command -v gum      >/dev/null 2>&1; then echo "gum:       $(gum --version)";       else echo "gum:       not installed"; fi
    @if command -v nextest  >/dev/null 2>&1; then echo "nextest:   $(cargo nextest --version 2>/dev/null | head -1)"; else echo "nextest:   not installed"; fi
    @if command -v shellcheck >/dev/null 2>&1; then echo "shellcheck: $(shellcheck --version | rg '^version')"; else echo "shellcheck: not installed"; fi
    @if command -v rumdl    >/dev/null 2>&1; then echo "rumdl:     $(rumdl --version 2>/dev/null || echo 'installed')"; else echo "rumdl:     not installed"; fi

# ── Build ─────────────────────────────────────────────────────────────────────

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

# ── Run ───────────────────────────────────────────────────────────────────────

# Run forge in debug mode with arguments
run *args:
    cargo run -p forge_main -- {{ args }}

# Watch for changes and re-check (requires cargo-watch)
watch:
    @if command -v cargo-watch >/dev/null 2>&1; then cargo watch -x 'check --workspace'; else echo "cargo-watch not installed -- skipping"; fi

# Watch and run tests on change
watch-test:
    @if command -v cargo-watch >/dev/null 2>&1; then cargo watch -x 'insta test --accept'; else echo "cargo-watch not installed -- skipping"; fi

# Watch a specific crate's tests
watch-crate crate:
    @if command -v cargo-watch >/dev/null 2>&1; then cargo watch -x "insta test --accept -p {{ crate }}"; else echo "cargo-watch not installed -- skipping"; fi

# ── Test ──────────────────────────────────────────────────────────────────────

# Run all workspace tests with insta auto-accept
test *args:
    @if command -v cargo-insta >/dev/null 2>&1; then cargo insta test --accept {{ args }}; else cargo test --workspace {{ args }}; fi

# Run tests for a specific crate
test-crate crate *args:
    @if command -v cargo-insta >/dev/null 2>&1; then cargo insta test --accept -p {{ crate }} {{ args }}; else cargo test -p {{ crate }} {{ args }}; fi

# Run a single test by name pattern
test-one pattern:
    @if command -v cargo-insta >/dev/null 2>&1; then cargo insta test --accept -- {{ pattern }}; else cargo test --workspace -- {{ pattern }}; fi

# Run tests with nextest (parallel, better output)
test-nextest *args:
    @if command -v cargo-nextest >/dev/null 2>&1; then cargo nextest run --workspace {{ args }}; else echo "cargo-nextest not installed -- skipping"; fi

# Run TypeScript evals suite
eval *args:
    npm run eval -- {{ args }}

# ── Lint & Format ────────────────────────────────────────────────────────────

# Run clippy with warnings-as-errors (matches CI)
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

# Lint shell scripts with shellcheck (excludes zsh)
shellcheck:
    @if command -v shellcheck >/dev/null 2>&1; then shellcheck --exclude=SC1071 scripts/*.sh; else echo "shellcheck not installed -- skipping"; fi

# Lint markdown files with rumdl
rumdl:
    @if command -v rumdl >/dev/null 2>&1; then rumdl .; else echo "rumdl not installed -- skipping"; fi

# ── Check & Verify ───────────────────────────────────────────────────────────

# Full pre-push verification gate (format + lint + test)
verify: fmt-check clippy test

# Quick pre-push check: format + check + clippy (no full test run)
pre-push: fmt check clippy

# Run the full CI pipeline locally: check + lint + test
ci: check lint test

# Check for known security vulnerabilities
audit:
    @if command -v cargo-audit >/dev/null 2>&1; then cargo audit; else echo "cargo-audit not installed -- skipping"; fi

# Check for unused dependencies
machete:
    @if command -v cargo-machete >/dev/null 2>&1; then cargo machete; else echo "cargo-machete not installed -- skipping"; fi

# Supply chain license/ban/advisory check
deny:
    @if command -v cargo-deny >/dev/null 2>&1; then cargo deny check; else echo "cargo-deny not installed -- skipping"; fi

# ── Coverage ──────────────────────────────────────────────────────────────────

# Generate LCOV coverage report (matches CI)
coverage:
    @if command -v cargo-llvm-cov >/dev/null 2>&1; then cargo llvm-cov --all-features --workspace --lcov --output-path lcov.info; else echo "cargo-llvm-cov not installed -- skipping"; fi

# Generate and open HTML coverage report
coverage-html:
    @if command -v cargo-llvm-cov >/dev/null 2>&1; then cargo llvm-cov --all-features --workspace --html --open; else echo "cargo-llvm-cov not installed -- skipping"; fi

# ── Benchmark ─────────────────────────────────────────────────────────────────

# Run the zsh rprompt performance benchmark (CI threshold: 60ms)
bench-rprompt:
    ./scripts/benchmark.sh --threshold 60 zsh rprompt

# Run a custom performance benchmark
bench +args:
    ./scripts/benchmark.sh {{ args }}

# ── Database (Diesel / SQLite) ────────────────────────────────────────────────

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

# ── Release & Publish ─────────────────────────────────────────────────────────

# Cross-compile for a specific target (e.g. `just cross x86_64-unknown-linux-musl`)
cross target:
    cross build --release --target {{ target }}

# Regenerate the JSON schema from forge binary
schema:
    cargo run -p forge_main -- schema > forge.schema.json

# Install forge to ~/.local/bin (release build)
install-local:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Building release binary..."
    cargo build --release
    mkdir -p "{{ install_dir }}"
    cp -f target/release/{{ bin }} "{{ install_dir }}/{{ bin }}"
    echo "Installed {{ bin }} to {{ install_dir }}/{{ bin }}"
    "{{ install_dir }}/{{ bin }}" --version 2>/dev/null || true

# Install the debug binary via cargo install (~/.cargo/bin/forge)
install:
    cargo install --path crates/forge_main

# ── Shell Plugin ──────────────────────────────────────────────────────────────

# Run zsh format correctness + perf tests
test-zsh:
    zsh scripts/test-zsh-utils.sh

# Run all porcelain list commands
list-porcelain:
    ./scripts/list-all-porcelain.sh

# ── Clean ─────────────────────────────────────────────────────────────────────

# Remove build artifacts
clean:
    cargo clean

# Remove and rebuild from scratch
rebuild: clean build

# ── Git ───────────────────────────────────────────────────────────────────────

# Amend the last commit without editing the message
amend:
    git add -A && git commit --amend --no-edit

# Interactive rebase on main
rebase:
    git rebase -i main

# Show log as oneline graph
log:
    git log --oneline --graph --decorate -20

# ── Utilities ─────────────────────────────────────────────────────────────────

# Count lines of Rust code in the workspace
loc:
    @if command -v tokei >/dev/null 2>&1; then tokei {{ crates_dir }}/ -t Rust; else rg --files -t rust {{ crates_dir }}/ | xargs wc -l | tail -1; fi

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
    @if command -v cargo-outdated >/dev/null 2>&1; then cargo outdated --workspace --root-deps-only; else echo "cargo-outdated not installed -- skipping"; fi

# Show binary size breakdown (requires cargo-bloat)
bloat:
    @if command -v cargo-bloat >/dev/null 2>&1; then cargo bloat --release -n 20; else echo "cargo-bloat not installed -- skipping"; fi

# ── fzf Workflows ─────────────────────────────────────────────────────────────

# [fzf] Launcher -- categorized interactive menu
[no-exit-message]
fzf:
    #!/usr/bin/env bash
    set -euo pipefail
    choice=$(printf '%s\n' \
        '── BUILD ──' \
        '* build-pick     Build a single crate' \
        '── TEST ──' \
        '* test-pick      Test a single crate' \
        '  test-fn        Run a single test function' \
        '── CROSS ──' \
        '  cross-pick     Cross-compile for a target' \
        '── FILES ──' \
        '* edit           Open a source file' \
        '  search-fzf     Live-grep + open at line' \
        '  crate-open     Open a crate lib.rs' \
        '── GIT ──' \
        '  branch         Checkout a branch' \
        '  show           Inspect a commit' \
        '── META ──' \
        '  pick           Run any just recipe' \
        | fzf --prompt="forge> " --height=50% --reverse \
              --preview='just --show {1} 2>/dev/null || echo "(section header)"' \
              --header="ForgeCode fzf launcher" \
        || true)
    [[ -z "$choice" ]] && exit 0
    recipe=$(echo "$choice" | sed 's/^[* ]*//' | awk '{print $1}')
    [[ "$recipe" == ──* ]] && exit 0
    just "$recipe"

# [fzf] Pick any recipe to run
[no-exit-message]
pick:
    #!/usr/bin/env bash
    set -euo pipefail
    recipe=$(just --list --unsorted \
        | tail -n +2 \
        | sed 's/^[[:space:]]*//' \
        | fzf --prompt="just> " --height=40% --reverse \
              --preview='just --show {1} 2>/dev/null' \
        || true)
    [[ -z "$recipe" ]] && exit 0
    just "$(echo "$recipe" | awk '{print $1}')"

# [fzf] Pick a crate to build
[no-exit-message]
build-pick:
    #!/usr/bin/env bash
    set -euo pipefail
    crate=$(ls {{ crates_dir }} \
        | fzf --prompt="build> " --height=40% --reverse \
              --preview='bat --color=always --style=numbers --line-range=:80 {{ crates_dir }}/{}/src/lib.rs 2>/dev/null || bat --color=always --style=numbers --line-range=:80 {{ crates_dir }}/{}/src/main.rs 2>/dev/null || echo "no entry point found"' \
        || true)
    [[ -z "$crate" ]] && exit 0
    cargo build -p "$crate"

# [fzf] Pick a crate to test
[no-exit-message]
test-pick:
    #!/usr/bin/env bash
    set -euo pipefail
    crate=$(ls {{ crates_dir }} \
        | fzf --prompt="test> " --height=40% --reverse \
              --preview='bat --color=always --style=numbers --line-range=:80 {{ crates_dir }}/{}/src/lib.rs 2>/dev/null || echo "no lib.rs"' \
        || true)
    [[ -z "$crate" ]] && exit 0
    if command -v cargo-insta >/dev/null 2>&1; then cargo insta test --accept -p "$crate"; else cargo test -p "$crate"; fi

# [fzf] Pick a test function to run
[no-exit-message]
test-fn:
    #!/usr/bin/env bash
    set -euo pipefail
    test=$(cargo test --workspace -- --list 2>/dev/null \
        | rg ':\s*test$' \
        | sed 's/: test$//' \
        | fzf --prompt="test fn> " --height=40% --reverse \
        || true)
    [[ -z "$test" ]] && exit 0
    if command -v cargo-insta >/dev/null 2>&1; then cargo insta test --accept -- "$test"; else cargo test --workspace -- "$test"; fi

# [fzf] Pick a cross-compilation target
[no-exit-message]
cross-pick:
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(echo "{{ cross_targets }}" | tr ' ' '\n' \
        | fzf --prompt="cross target> " --height=40% --reverse \
        || true)
    [[ -z "$target" ]] && exit 0
    cross build --release --target "$target"

# [fzf] Open a source file in $EDITOR (bat preview)
[no-exit-message]
edit:
    #!/usr/bin/env bash
    set -euo pipefail
    file=$(rg --files -t rust {{ crates_dir }}/ \
        | fzf --prompt="edit> " --height=60% --reverse \
              --preview 'bat --color=always --style=numbers --line-range=:500 {}' \
        || true)
    [[ -z "$file" ]] && exit 0
    "${EDITOR:-vim}" "$file"

# [fzf] Live-grep across Rust files, pick a match, open at line (bat preview)
[no-exit-message]
search-fzf:
    #!/usr/bin/env bash
    set -euo pipefail
    match=$(rg --line-number --no-heading --color=always -t rust '.' {{ crates_dir }}/ \
        | fzf --ansi --prompt="search> " --height=70% --reverse \
              --delimiter=: --nth=3.. \
              --preview 'file=$(echo {} | cut -d: -f1); line=$(echo {} | cut -d: -f2); bat --color=always --style=numbers --highlight-line "$line" --line-range=$((line > 20 ? line - 20 : 1)):$((line + 40)) "$file"' \
        || true)
    [[ -z "$match" ]] && exit 0
    file=$(echo "$match" | cut -d: -f1)
    line=$(echo "$match" | cut -d: -f2)
    "${EDITOR:-vim}" "+$line" "$file"

# [fzf] Browse and open a crate directory
[no-exit-message]
crate-open:
    #!/usr/bin/env bash
    set -euo pipefail
    crate=$(ls {{ crates_dir }} \
        | fzf --prompt="crate> " --height=40% --reverse \
              --preview 'bat --color=always --style=numbers --line-range=:500 {{ crates_dir }}/{}/src/lib.rs 2>/dev/null || echo "no lib.rs"' \
        || true)
    [[ -z "$crate" ]] && exit 0
    "${EDITOR:-vim}" "{{ crates_dir }}/$crate/src/lib.rs"

# [fzf] Pick a git branch to checkout
[no-exit-message]
branch:
    #!/usr/bin/env bash
    set -euo pipefail
    b=$(git branch --all --format='%(refname:short)' \
        | fzf --prompt="branch> " --height=40% --reverse \
              --preview 'git log --oneline --graph --color -20 {}' \
        || true)
    [[ -z "$b" ]] && exit 0
    git checkout "$b"

# [fzf] Pick a recent commit to show
[no-exit-message]
show:
    #!/usr/bin/env bash
    set -euo pipefail
    commit=$(git log --oneline --color -50 \
        | fzf --ansi --prompt="commit> " --height=50% --reverse \
              --preview 'git show --stat --color {1}' \
        || true)
    [[ -z "$commit" ]] && exit 0
    git show "$(echo "$commit" | awk '{print $1}')"
