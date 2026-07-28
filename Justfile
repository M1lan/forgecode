# ── ForgeCode Justfile -- Build, test, inspect, ship ──
#
# `just menu` is the only interactive interface. It discovers every public
# recipe from this file, displays its source, collects parameters, and runs a
# reviewed command. All other recipes remain direct, scriptable commands.

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false
set positional-arguments := true

export RUST_BACKTRACE := "1"

crates_dir := "crates"
bin := "forge"
install_dir := env("HOME") / ".local/bin"
helpers := justfile_directory() / ".just" / "helpers"

# ── Meta ──────────────────────────────────────────────────────────────────────

# Show available public recipes.
[private]
default: help

# Print public recipe list for scripts and narrow terminals.
[group('meta')]
help:
    @just --list --unsorted

# Print compact project and tool status.
[group('meta')]
info:
    @'{{helpers}}/info-screen.bash'

# Launch the only interactive recipe browser and runner.
[group('meta')]
[no-exit-message]
menu:
    @'{{helpers}}/menu.bash'

# Check local developer tools and AI index availability.
[group('meta')]
doctor:
    @'{{helpers}}/doctor.bash'

# ── Build ─────────────────────────────────────────────────────────────────────

# Type-check workspace targets.
[group('build')]
check:
    cargo check --workspace --all-targets

# Build workspace in debug mode.
[group('build')]
build:
    cargo build --workspace

# Build release binary.
[group('build')]
build-release:
    cargo build --release

# Build one crate.
[group('build')]
build-crate crate:
    cargo build -p {{ crate }}

# Build forge binary in debug mode.
[group('build')]
build-debug:
    cargo build -p forge_main

# ── Run & Watch ───────────────────────────────────────────────────────────────

# Run forge with arguments.
[group('run')]
run *args:
    cargo run -p forge_main -- {{ args }}

# Watch and type-check changes.
[group('watch')]
watch:
    @if command -v cargo-watch >/dev/null 2>&1; then cargo watch -x 'check --workspace'; else printf 'cargo-watch not installed\n' >&2; fi

# Watch and run tests on changes.
[group('watch')]
watch-test:
    @if command -v cargo-watch >/dev/null 2>&1; then cargo watch -x 'insta test --accept'; else printf 'cargo-watch not installed\n' >&2; fi

# Watch one crate's tests.
[group('watch')]
watch-crate crate:
    @if command -v cargo-watch >/dev/null 2>&1; then cargo watch -x "insta test --accept -p {{ crate }}"; else printf 'cargo-watch not installed\n' >&2; fi

# ── Test ──────────────────────────────────────────────────────────────────────

# Run workspace tests with insta auto-accept.
[group('test')]
test *args:
    @if command -v cargo-insta >/dev/null 2>&1; then cargo insta test --accept {{ args }}; else cargo test --workspace {{ args }}; fi

# Run tests for one crate.
[group('test')]
test-crate crate *args:
    @if command -v cargo-insta >/dev/null 2>&1; then cargo insta test --accept -p {{ crate }} {{ args }}; else cargo test -p {{ crate }} {{ args }}; fi

# Run tests matching pattern.
[group('test')]
test-one pattern:
    @if command -v cargo-insta >/dev/null 2>&1; then cargo insta test --accept -- {{ pattern }}; else cargo test --workspace -- {{ pattern }}; fi

# Run workspace tests with nextest.
[group('test')]
test-nextest *args:
    @if command -v cargo-nextest >/dev/null 2>&1; then cargo nextest run --workspace {{ args }}; else printf 'cargo-nextest not installed\n' >&2; fi

# Run TypeScript eval suite.
[group('test')]
eval *args:
    npm run eval -- {{ args }}

# Run zsh format and performance tests.
[group('test')]
test-zsh:
    zsh scripts/test-zsh-utils.sh

# Parse-check embedded Bash plugin.
[group('test')]
test-bash:
    bash -n shell-plugin/bash/forge.plugin.bash

# Parse-check Fish plugin when installed.
[group('test')]
test-fish:
    @if command -v fish >/dev/null 2>&1; then fish --no-execute shell-plugin/fish/forge.plugin.fish; else printf 'fish not installed; skipping\n' >&2; fi

# ── Lint & Format ─────────────────────────────────────────────────────────────

# Run clippy with warnings denied.
[group('lint')]
clippy:
    RUSTFLAGS="-Dwarnings" cargo clippy --workspace --all-targets

# Apply clippy fixes.
[group('lint')]
clippy-fix:
    cargo clippy --workspace --all-targets --fix --allow-dirty --allow-staged

# Format Rust source with nightly rustfmt.
[group('lint')]
fmt:
    PATH="$(rustup run nightly rustc --print sysroot)/bin:$PATH" cargo fmt --all

# Check Rust formatting with nightly rustfmt.
[group('lint')]
fmt-check:
    PATH="$(rustup run nightly rustc --print sysroot)/bin:$PATH" cargo fmt --all -- --check

# Run Rust format and clippy checks.
[group('lint')]
lint: fmt-check clippy

# Apply Rust formatting and clippy fixes.
[group('lint')]
fix: fmt clippy-fix

# Lint Bash scripts and Justfile helpers.
[group('lint')]
shellcheck:
    @if command -v shellcheck >/dev/null 2>&1; then shellcheck --exclude=SC1071 --source-path=SCRIPTDIR -x scripts/*.sh scripts/*.bash '{{helpers}}'/*.bash; else printf 'shellcheck not installed\n' >&2; fi

# Lint Markdown files.
[group('lint')]
rumdl:
    @if command -v rumdl >/dev/null 2>&1; then rumdl .; else printf 'rumdl not installed\n' >&2; fi

# ── Verify ────────────────────────────────────────────────────────────────────

# Run full pre-push verification.
[group('verify')]
verify: fmt-check clippy test

# Run fast pre-push checks.
[group('verify')]
pre-push: fmt-check check clippy

# Run local CI checks.
[group('verify')]
ci: check lint test

# Check known Rust security vulnerabilities.
[group('verify')]
audit:
    @if command -v cargo-audit >/dev/null 2>&1; then cargo audit; else printf 'cargo-audit not installed\n' >&2; fi

# Check unused dependencies.
[group('verify')]
machete:
    @if command -v cargo-machete >/dev/null 2>&1; then cargo machete; else printf 'cargo-machete not installed\n' >&2; fi

# Check supply-chain licenses, bans, and advisories.
[group('verify')]
deny:
    @if command -v cargo-deny >/dev/null 2>&1; then cargo deny check; else printf 'cargo-deny not installed\n' >&2; fi

# ── Coverage & Benchmark ──────────────────────────────────────────────────────

# Generate LCOV coverage report.
[group('coverage')]
coverage:
    @if command -v cargo-llvm-cov >/dev/null 2>&1; then cargo llvm-cov --all-features --workspace --lcov --output-path lcov.info; else printf 'cargo-llvm-cov not installed\n' >&2; fi

# Generate and open HTML coverage report.
[group('coverage')]
coverage-html:
    @if command -v cargo-llvm-cov >/dev/null 2>&1; then cargo llvm-cov --all-features --workspace --html --open; else printf 'cargo-llvm-cov not installed\n' >&2; fi

# Run zsh rprompt benchmark.
[group('bench')]
bench-rprompt:
    ./scripts/benchmark.sh --threshold 60 zsh rprompt

# Run custom benchmark arguments.
[group('bench')]
bench *args:
    ./scripts/benchmark.sh {{ args }}

# ── Database ──────────────────────────────────────────────────────────────────

# Apply pending Diesel migrations.
[group('database')]
db-migrate:
    diesel migration run

# Revert latest Diesel migration.
[group('database')]
db-revert:
    diesel migration revert

# Regenerate Diesel schema.
[group('database')]
db-schema:
    diesel print-schema > crates/forge_repo/src/database/schema.rs

# Create a new Diesel migration.
[group('database')]
db-new name:
    diesel migration generate {{ name }}

# ── Release ───────────────────────────────────────────────────────────────────

# Cross-compile release target.
[group('release')]
cross target:
    cross build --release --target {{ target }}

# Regenerate Forge JSON schema.
[group('release')]
schema:
    cargo run -p forge_main -- schema > forge.schema.json

# Build and install release forge binary.
[group('release')]
install-release:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --release
    mkdir -p "{{ install_dir }}"
    cp -f target/release/{{ bin }} "{{ install_dir }}/{{ bin }}"
    if [[ "$(uname -s)" == "Darwin" ]]; then codesign --force --sign - "{{ install_dir }}/{{ bin }}"; fi
    "{{ install_dir }}/{{ bin }}" --version

# Build and install debug forge binary.
[group('release')]
install-debug: build-debug
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{ install_dir }}"
    cp -f target/debug/{{ bin }} "{{ install_dir }}/{{ bin }}-debug"
    if [[ "$(uname -s)" == "Darwin" ]]; then codesign --force --sign - "{{ install_dir }}/{{ bin }}-debug"; fi
    "{{ install_dir }}/{{ bin }}-debug" --version

# Install release and debug forge binaries.
[group('release')]
install-both: install-release install-debug

# Install release forge binary compatibility alias.
[group('release')]
install-local: install-release

# Install debug forge through cargo.
[group('release')]
install:
    cargo install --path crates/forge_main

# ── Utilities ─────────────────────────────────────────────────────────────────

# Remove build artifacts.
[group('clean')]
clean:
    cargo clean

# Remove artifacts and rebuild workspace.
[group('clean')]
rebuild: clean build

# Amend latest commit without changing message.
[group('git')]
amend:
    git add -A && git commit --amend --no-edit

# Start interactive rebase onto main.
[group('git')]
rebase:
    git rebase -i main

# Show recent commit graph.
[group('git')]
log:
    git log --oneline --graph --decorate -20

# Run all porcelain list commands.
[group('util')]
list-porcelain:
    ./scripts/list-all-porcelain.sh

# Search Rust source with ripgrep.
[group('util')]
search query:
    rg --line-number --type rust -- {{ query }} {{ crates_dir }}/

# Count Rust lines in workspace.
[group('util')]
loc:
    @if command -v tokei >/dev/null 2>&1; then tokei {{ crates_dir }}/ -t Rust; else rg --files -t rust {{ crates_dir }}/ | xargs wc -l; fi

# List workspace crates.
[group('util')]
crates:
    @ls {{ crates_dir }}

# Show workspace dependency tree.
[group('util')]
deps:
    cargo tree --workspace --depth 1

# Show one crate dependency tree.
[group('util')]
deps-crate crate depth='2':
    cargo tree -p {{ crate }} --depth {{ depth }}

# Check outdated dependencies.
[group('util')]
outdated:
    @if command -v cargo-outdated >/dev/null 2>&1; then cargo outdated --workspace --root-deps-only; else printf 'cargo-outdated not installed\n' >&2; fi

# Show release binary size breakdown.
[group('util')]
bloat:
    @if command -v cargo-bloat >/dev/null 2>&1; then cargo bloat --release -n 20; else printf 'cargo-bloat not installed\n' >&2; fi

# ── AI Code Intelligence ──────────────────────────────────────────────────────

# Check local AI-tool and index status.
[group('ai')]
ai-doctor:
    @./scripts/ai-tools.bash doctor

# Show all local AI index status.
[group('ai')]
ai-status:
    @./scripts/ai-tools.bash status

# Build missing local AI indexes.
[group('ai')]
ai-init:
    @./scripts/ai-tools.bash init

# Incrementally update local AI indexes.
[group('ai')]
ai-sync:
    @./scripts/ai-tools.bash sync

# Force full local AI re-index.
[group('ai')]
ai-resync:
    @./scripts/ai-tools.bash resync

# Remove local AI indexes after confirmation.
[group('ai')]
ai-clean:
    @./scripts/ai-tools.bash clean

# Search code semantically through grepai.
[group('ai')]
ai-search *query:
    @./scripts/ai-tools.bash search {{ query }}

# Pass arguments to gitnexus with local repository selection.
[group('ai')]
gitnexus *args:
    @./scripts/ai-tools.bash gitnexus {{ args }}

# Pass arguments to codegraph.
[group('ai')]
codegraph *args:
    @./scripts/ai-tools.bash codegraph {{ args }}

# Pass arguments to grepai.
[group('ai')]
grepai *args:
    @./scripts/ai-tools.bash grepai {{ args }}

# Pass arguments to repowise.
[group('ai')]
repowise *args:
    @./scripts/ai-tools.bash repowise {{ args }}

# ── Compatibility ─────────────────────────────────────────────────────────────

# Compatibility alias for muscle memory; the sole interface is `just menu`.
[private]
[no-exit-message]
fzf: menu
