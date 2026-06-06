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
    @if command -v gum      >/dev/null 2>&1; then echo "gum:       $(gum --version)";       else echo "gum:       not installed (brew install gum)"; fi
    @if command -v bat      >/dev/null 2>&1; then echo "bat:       $(bat --version | head -1)"; else echo "bat:       not installed (brew install bat)"; fi
    @if command -v rg       >/dev/null 2>&1; then echo "rg:        $(rg --version | head -1)";  else echo "rg:        not installed (brew install ripgrep)"; fi
    @if command -v fd       >/dev/null 2>&1; then echo "fd:        $(fd --version)";        else echo "fd:        not installed (brew install fd)"; fi
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

# Format all Rust code (uses nightly to match CI; rustfmt.toml has nightly-only opts)
fmt:
    rustup run nightly cargo fmt --all

# Check formatting without modifying files (matches CI: autofix.yml uses +nightly)
fmt-check:
    rustup run nightly cargo fmt --all -- --check

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

# ── Interactive (gum) ─────────────────────────────────────────────────────────
#
# Tooling: gum (filter/style/confirm/input) + bat (themed preview) + rg.
# Search semantics: `gum filter --no-fuzzy --no-fuzzy-sort` → match from start
# of word (\b<query>), case-insensitive. Typing `te` matches `test`,
# `test-doc`, `test-matrix`; NOT `pretest`. Exactly the whole-word feel
# the project standard prescribes — no scattered single-char highlights.
#
# Themes: dark (default) / light. Switch from inside the menu, or:
#     just menu light

# Brand-themed interactive recipe menu (gum + bat).
[no-exit-message]
menu THEME='dark':
    #!/usr/bin/env bash
    set -euo pipefail

    if ! command -v gum >/dev/null 2>&1 || ! command -v bat >/dev/null 2>&1; then
        echo "menu requires gum + bat: brew install gum bat" >&2; exit 1
    fi

    theme="{{ THEME }}"
    case "$theme" in dark|light) ;; *) theme="dark" ;; esac

    # ── Brand palette (from ~/templates/design-minimals.txt) ──
    NAVY="#00003C"; INK="#00001B"; TEAL="#003C32"
    BLUE="#0071FF"; GREEN="#1BEB83"
    OFFWHITE="#F4F7F9"; BORDER_LIGHT="#CBD5E1"; BORDER_DARK="#94A3B8"
    MUTED="#64748B"; MUTED_LIGHT="#94A3B8"; WHITE="#FFFFFF"

    # ── Theme-conditional colours (BG_PANEL gives the menu its own card) ──
    if [[ "$theme" == "light" ]]; then
        FG="$NAVY";          BG_PANEL="$OFFWHITE"
        BG_MATCH="#E5F0FF";  BG_CURSOR="$BORDER_LIGHT"
        ACCENT="$BLUE";      ACCENT2="$TEAL";      MATCH_FG="$TEAL"
        BORDER="$BORDER_DARK"
        BANNER_FG="$BLUE";   SUBTLE="$MUTED"
        BAT_THEME="GitHub";  ALT_THEME="dark"
    else
        FG="$OFFWHITE";      BG_PANEL="$INK"
        BG_MATCH="$TEAL";    BG_CURSOR="$NAVY"
        ACCENT="$GREEN";     ACCENT2="$BLUE";      MATCH_FG="$GREEN"
        BORDER="$BORDER_DARK"
        BANNER_FG="$GREEN";  SUBTLE="$MUTED_LIGHT"
        BAT_THEME="Coldark-Dark"; ALT_THEME="light"
    fi

    export GUM_FILTER_INDICATOR_FOREGROUND="$ACCENT"
    export GUM_FILTER_INDICATOR_BACKGROUND="$BG_CURSOR"
    export GUM_FILTER_MATCH_FOREGROUND="$MATCH_FG"
    export GUM_FILTER_MATCH_BACKGROUND="$BG_MATCH"
    export GUM_FILTER_HEADER_FOREGROUND="$SUBTLE"
    export GUM_FILTER_PROMPT_FOREGROUND="$ACCENT"
    export GUM_FILTER_TEXT_FOREGROUND="$FG"
    export GUM_FILTER_CURSOR_TEXT_FOREGROUND="$ACCENT"
    export GUM_FILTER_CURSOR_TEXT_BACKGROUND="$BG_CURSOR"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$SUBTLE"
    export GUM_CONFIRM_PROMPT_FOREGROUND="$FG"
    export GUM_CONFIRM_SELECTED_BACKGROUND="$ACCENT2"
    export GUM_CONFIRM_SELECTED_FOREGROUND="$WHITE"
    export GUM_CONFIRM_UNSELECTED_FOREGROUND="$SUBTLE"

    # ── Recipe data (curated, categorized) ──
    items=$(printf '%s\n' \
        '── BUILD ──' \
        '  check              cargo check --workspace --all-targets' \
        '  build              debug build of the workspace' \
        '  build-release      release build (LTO + strip)' \
        '  build-pick         pick a crate to build' \
        '── RUN & WATCH ──' \
        '  watch              watch + cargo check' \
        '  watch-test         watch + insta test' \
        '── TEST ──' \
        '  test               workspace tests (insta auto-accept)' \
        '  test-nextest       cargo nextest if installed' \
        '  test-pick          pick a crate to test' \
        '  test-fn            pick a single test function' \
        '  eval               npm run eval' \
        '── LINT & FORMAT ──' \
        '  clippy             clippy --workspace -D warnings' \
        '  clippy-fix         clippy --fix' \
        '  fmt                cargo fmt --all' \
        '  fmt-check          cargo fmt --check' \
        '  lint               fmt-check + clippy' \
        '  fix                fmt + clippy-fix' \
        '  shellcheck         shellcheck scripts/*.sh' \
        '  rumdl              markdown lint' \
        '── VERIFY & CI ──' \
        '  verify             full pre-push gate (fmt + clippy + test)' \
        '  pre-push           quick pre-push check' \
        '  ci                 full CI pipeline locally' \
        '  audit              cargo-audit (CVEs)' \
        '  machete            cargo-machete (unused deps)' \
        '  deny               cargo-deny (licenses/bans/advisories)' \
        '── COVERAGE ──' \
        '  coverage           LCOV report (cargo-llvm-cov)' \
        '  coverage-html      HTML report, open in browser' \
        '── BENCHMARK ──' \
        '  bench-rprompt      zsh rprompt benchmark (CI threshold 60ms)' \
        '── DATABASE ──' \
        '  db-migrate         run pending diesel migrations' \
        '  db-revert          revert last migration' \
        '  db-schema          regenerate schema.rs' \
        '── RELEASE ──' \
        '  cross-pick         pick a cross-compilation target' \
        '  schema             regenerate forge JSON schema' \
        '  install-local      install release build to ~/.local/bin' \
        '  install            cargo install --path crates/forge_main' \
        '── SHELL PLUGIN ──' \
        '  test-zsh           zsh format + perf tests' \
        '  list-porcelain     run all porcelain list commands' \
        '── CLEAN ──' \
        '  clean              cargo clean' \
        '  rebuild            clean + build' \
        '── GIT ──' \
        '  amend              amend last commit (no edit)' \
        '  rebase             interactive rebase on main' \
        '  log                git oneline graph (last 20)' \
        '  branch             pick a branch to checkout' \
        '  show               pick a commit to inspect' \
        '── FILES ──' \
        '  edit               pick a source file to edit' \
        '  search             live-grep across Rust files' \
        '  crate-open         pick a crate to edit lib.rs/main.rs' \
        '── INFO & UTIL ──' \
        '  info               project + tool versions' \
        '  loc                lines of Rust code' \
        '  crates             list workspace crates' \
        '  deps               cargo tree --depth 1' \
        '  outdated           outdated deps (root only)' \
        '  bloat              binary size breakdown' \
        '── ⚙ THEME ──' \
        "  theme-${ALT_THEME}        switch the menu to ${ALT_THEME} theme" \
        '  quit               exit the menu' \
    )

    while true; do
        clear

        gum style --border=double --border-foreground="$BORDER" \
                  --background="$BG_PANEL" \
                  --foreground="$BANNER_FG" --bold --align=center \
                  --padding="1 4" --margin="1 0" --width=78 \
                  "ForgeCode · Justfile menu" \
                  "$(gum style --foreground="$SUBTLE" --background="$BG_PANEL" --italic \
                      "theme: ${theme}  ·  type to filter (whole-word from start)  ·  ↑↓ navigate  ·  Enter pick")"

        choice=$(printf '%s\n' "$items" | \
            gum filter --no-fuzzy --no-fuzzy-sort \
                --header="" \
                --placeholder="type to filter recipes..." \
                --prompt="search › " \
                --indicator="› " \
                --height=24 \
                --width=78 \
                --reverse \
            || echo "__cancel__")

        [[ "$choice" == "__cancel__" || -z "$choice" ]] && exit 0
        if [[ "$choice" =~ ^── ]]; then continue; fi

        recipe=$(echo "$choice" | awk '{print $1}')
        [[ -z "$recipe" ]] && continue

        case "$recipe" in
            quit|q|exit) exit 0 ;;
            theme-light) exec just menu light ;;
            theme-dark)  exec just menu dark  ;;
        esac

        clear
        gum style --border=rounded --border-foreground="$BORDER" \
                  --background="$BG_PANEL" \
                  --foreground="$ACCENT" --bold --padding="0 2" --margin="1 0" \
                  "preview · just $recipe"

        body=$(just --show "$recipe" 2>/dev/null || echo "(no body for $recipe)")
        cols=$(tput cols 2>/dev/null || echo 100)
        inner_width=$(( cols > 16 ? cols - 8 : cols ))

        # bat does NOT have a `just` syntax -- `make` is the closest match.
        printf '%s\n' "$body" | \
            bat --language=make --color=always --paging=never \
                --style=numbers --theme="$BAT_THEME" \
            | gum style --border=rounded --border-foreground="$BORDER" \
                        --padding="1 2" --margin="0 4" \
                        --width="$inner_width" --no-strip-ansi
        echo

        if gum confirm "Run \`just $recipe\`?" \
                --affirmative="Run" --negative="Back" --default; then
            clear
            gum style --foreground="$ACCENT" --bold --margin="1 0" \
                "→ just $recipe"
            exec just "$recipe"
        fi
        # Otherwise loop back to the filter.
    done

# Force-launch the menu in light theme (e.g. for keybindings).
menu-light: (menu "light")

# Backwards-compatible alias (`just fzf` -> menu) for muscle memory.
fzf: menu

# Pick any recipe to run -- auto-discovered via `just --list`.
[no-exit-message]
pick:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
    line=$(just --list --unsorted | tail -n +2 | sed 's/^[[:space:]]*//' \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=22 \
              --placeholder="type a recipe name or description..." \
              --prompt="just › " \
        || echo "__cancel__")
    [[ "$line" == "__cancel__" || -z "$line" ]] && exit 0
    recipe=$(echo "$line" | awk '{print $1}')
    [[ -z "$recipe" ]] && exit 0
    just "$recipe"

# Live-grep across Rust files. Pick a match → open in $EDITOR at line.
# `just search foo` runs immediately; `just search` prompts for the pattern.
[no-exit-message]
search QUERY='':
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    command -v bat >/dev/null 2>&1 || { echo "needs bat: brew install bat" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_INPUT_PROMPT_FOREGROUND="$BLUE"
    export GUM_INPUT_CURSOR_FOREGROUND="$BLUE"
    export GUM_INPUT_PLACEHOLDER_FOREGROUND="$MUTED"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"

    q="{{ QUERY }}"
    if [[ -z "$q" ]]; then
        q=$(gum input --placeholder="grep pattern (regex)" \
                      --prompt="rg › " --width=60 || true)
    fi
    [[ -z "$q" ]] && exit 0

    matches=$(rg --line-number --no-heading --color=never \
                 --type rust -- "$q" {{ crates_dir }}/ 2>/dev/null || true)
    if [[ -z "$matches" ]]; then
        gum style --foreground="$MUTED" --italic --margin="1 0" \
            "no matches for: $q"
        exit 0
    fi

    # Narrow further with gum filter -- list visible immediately.
    pick=$(printf '%s\n' "$matches" \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=24 \
              --placeholder="narrow further or pick a match..." \
              --prompt="match › " \
        || echo "__cancel__")
    [[ "$pick" == "__cancel__" || -z "$pick" ]] && exit 0

    file=$(echo "$pick" | cut -d: -f1)
    line=$(echo "$pick" | cut -d: -f2)
    [[ -z "$file" || -z "$line" ]] && exit 0

    # Show context, then jump in $EDITOR at line.
    bat --color=always --style=numbers --highlight-line "$line" \
        --line-range=$((line > 20 ? line - 20 : 1)):$((line + 40)) "$file" || true
    "${EDITOR:-vim}" "+$line" "$file"

# Backwards-compatible alias for muscle memory.
search-fzf: search

# Pick a Rust source file to open in $EDITOR.
[no-exit-message]
edit:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
    file=$(rg --files -t rust {{ crates_dir }}/ \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=22 \
              --placeholder="type to filter source files..." --prompt="edit › " \
        || echo "__cancel__")
    [[ "$file" == "__cancel__" || -z "$file" ]] && exit 0
    "${EDITOR:-vim}" "$file"

# Pick a workspace crate to build.
[no-exit-message]
build-pick:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
    crate=$(ls {{ crates_dir }} \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=20 \
              --placeholder="pick a crate to build..." --prompt="build › " \
        || echo "__cancel__")
    [[ "$crate" == "__cancel__" || -z "$crate" ]] && exit 0
    cargo build -p "$crate"

# Pick a workspace crate to test.
[no-exit-message]
test-pick:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
    crate=$(ls {{ crates_dir }} \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=20 \
              --placeholder="pick a crate to test..." --prompt="test › " \
        || echo "__cancel__")
    [[ "$crate" == "__cancel__" || -z "$crate" ]] && exit 0
    if command -v cargo-insta >/dev/null 2>&1; then
        cargo insta test --accept -p "$crate"
    else
        cargo test -p "$crate"
    fi

# Pick a single test function to run.
[no-exit-message]
test-fn:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
    test=$(cargo test --workspace -- --list 2>/dev/null \
        | rg ':\s*test$' | sed 's/: test$//' \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=22 \
              --placeholder="type a test name..." --prompt="test fn › " \
        || echo "__cancel__")
    [[ "$test" == "__cancel__" || -z "$test" ]] && exit 0
    if command -v cargo-insta >/dev/null 2>&1; then
        cargo insta test --accept -- "$test"
    else
        cargo test --workspace -- "$test"
    fi

# Pick a cross-compilation target.
[no-exit-message]
cross-pick:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
    target=$(echo "{{ cross_targets }}" | tr ' ' '\n' \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=20 \
              --placeholder="pick a target triple..." --prompt="cross › " \
        || echo "__cancel__")
    [[ "$target" == "__cancel__" || -z "$target" ]] && exit 0
    cross build --release --target "$target"

# Pick a crate and open its lib.rs (or main.rs) in $EDITOR.
[no-exit-message]
crate-open:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
    crate=$(ls {{ crates_dir }} \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=20 \
              --placeholder="pick a crate..." --prompt="crate › " \
        || echo "__cancel__")
    [[ "$crate" == "__cancel__" || -z "$crate" ]] && exit 0
    if   [[ -f "{{ crates_dir }}/$crate/src/lib.rs"  ]]; then "${EDITOR:-vim}" "{{ crates_dir }}/$crate/src/lib.rs"
    elif [[ -f "{{ crates_dir }}/$crate/src/main.rs" ]]; then "${EDITOR:-vim}" "{{ crates_dir }}/$crate/src/main.rs"
    else echo "no lib.rs/main.rs in {{ crates_dir }}/$crate/src/" >&2; exit 1
    fi

# Pick a git branch, preview last 10 commits, then checkout (with confirm).
[no-exit-message]
branch:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
    export GUM_CONFIRM_PROMPT_FOREGROUND="$BLUE"
    export GUM_CONFIRM_SELECTED_BACKGROUND="$BLUE"
    b=$(git branch --all --format='%(refname:short)' \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=22 \
              --placeholder="pick a branch to checkout..." --prompt="branch › " \
        || echo "__cancel__")
    [[ "$b" == "__cancel__" || -z "$b" ]] && exit 0
    echo
    git log --oneline --graph --color -10 "$b" 2>/dev/null || true
    echo
    if gum confirm "Checkout \`$b\`?" --affirmative="Checkout" --negative="Cancel"; then
        git checkout "$b"
    fi

# Pick a recent commit, show stat + diff.
[no-exit-message]
show:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gum >/dev/null 2>&1 || { echo "needs gum: brew install gum" >&2; exit 1; }
    BLUE="#0071FF"; GREEN="#1BEB83"; MUTED="#64748B"
    export GUM_FILTER_INDICATOR_FOREGROUND="$BLUE"
    export GUM_FILTER_MATCH_FOREGROUND="$GREEN"
    export GUM_FILTER_PROMPT_FOREGROUND="$BLUE"
    export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
    line=$(git log --oneline -50 \
        | gum filter --no-fuzzy --no-fuzzy-sort --reverse --height=24 \
              --placeholder="pick a commit to inspect..." --prompt="commit › " \
        || echo "__cancel__")
    [[ "$line" == "__cancel__" || -z "$line" ]] && exit 0
    sha=$(echo "$line" | awk '{print $1}')
    [[ -z "$sha" ]] && exit 0
    git show --stat --color "$sha" | (command -v bat >/dev/null 2>&1 && bat --paging=always --color=always --plain || cat)
