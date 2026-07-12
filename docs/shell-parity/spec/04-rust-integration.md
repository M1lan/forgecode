# Forge — RUST INTEGRATION SURFACE for adding shells (bash, fish) alongside zsh

Repo: `/Users/milan.santosi/mysrc/forgecode`. Read-only survey. All paths absolute below are relative to that root.

Everything shell-specific lives in `crates/forge_main/src/zsh/` + the `shell-plugin/` asset tree + the `Zsh(ZshCommandGroup)` CLI wiring + the `ui.rs` dispatch arms. A new shell must replicate all four.

---

## 1. Script embedding + plugin build

### Embed points (all in `crates/forge_main/src/zsh/plugin.rs`)
- `plugin.rs:15` — `static ZSH_PLUGIN_LIB: Dir<'static> = include_dir!("$CARGO_MANIFEST_DIR/../../shell-plugin/lib");` embeds the whole `shell-plugin/lib/` tree (recursive; includes `lib/actions/*.zsh`).
- `plugin.rs:55` — `include_str!("../../../../shell-plugin/forge.theme.zsh")` (theme).
- `plugin.rs:181` — `include_str!("../../../../shell-plugin/doctor.zsh")` (doctor).
- `plugin.rs:191` — `include_str!("../../../../shell-plugin/keyboard.zsh")` (keyboard).
- `plugin.rs:255` — `include_str!("../../../../shell-plugin/forge.setup.zsh")` (the `.zshrc` init block body).
- NOTE: `shell-plugin/forge.plugin.zsh` (923B) exists on disk but is NOT embedded by the Rust build — the loader eval's `forge zsh plugin` output instead (see `forge.setup.zsh`).

### How the plugin string is built (`generate_zsh_plugin`, `plugin.rs:19-50`)
1. `forge_embed::files(&ZSH_PLUGIN_LIB)` (helper in `crates/forge_embed/src/lib.rs`) walks embedded files in deterministic order.
2. Per file: `super::normalize_script(bytes)` (strips `\r\n`/`\r` → `\n`; `zsh/mod.rs:20-22`), then **line-by-line comment/blank stripping**: `trimmed.is_empty() || trimmed.starts_with('#')` → dropped (`plugin.rs:27-33`). This is why every `lib/*.zsh` file's leading `#` comments vanish in the emitted plugin.
3. clap completions appended: `Cli::command()` → `clap_complete::generate(Zsh, &mut cmd, "forge", &mut completions)` (`plugin.rs:37-39`), pushed after a `\n# --- Clap Completions ---\n` separator.
4. Sentinel appended: `_FORGE_PLUGIN_LOADED=$(date +%s)` (`plugin.rs:47`). Theme appends `_FORGE_THEME_LOADED` (`plugin.rs:58`).

### Completion generators — Bash + Fish ALREADY EXIST
`clap_complete` 4.6.7 exports `pub use bash::Bash; pub use fish::Fish; pub use zsh::Zsh;` (verified: `~/.cargo/registry/.../clap_complete-4.6.7/src/aot/shells/mod.rs:10-15`). A bash generator is `generate(clap_complete::shells::Bash, &mut cmd, "forge", &mut buf)`; fish is `Fish`. No new dependency. `clap_complete` is already in `Cargo.lock` (`clap_complete` @1015) and used by `forge_main`.

---

## 2. Public API per shell (current zsh surface)

Re-exported at `crates/forge_main/src/zsh/mod.rs:24-28`. Signatures:

```rust
// plugin.rs
pub fn generate_zsh_plugin() -> Result<String>                 // :19
pub fn generate_zsh_theme()  -> Result<String>                 // :53
pub fn run_zsh_doctor()      -> Result<()>                     // :180  (spawns `zsh -c`/`zsh -f`)
pub fn run_zsh_keyboard()    -> Result<()>                     // :190  (spawns zsh)
pub fn setup_zsh_integration(disable_nerd_font: bool,
                             forge_editor: Option<&str>)
                             -> Result<ZshSetupResult>         // :249
// mod.rs
pub(crate) fn normalize_script(content: &str) -> String        // :20  (shell-agnostic; reuse as-is)
// rprompt.rs
pub struct ZshRPrompt { .. }                                   // :33  Display-based, %F{..}/%B zsh prompt escapes
pub fn ZshRPrompt::from_config(&ForgeConfig) -> Self           // :60
```

Internals worth noting:
- `execute_zsh_script_with_streaming(script, name)` (`plugin.rs:87`) hard-codes `Command::new("zsh")` with `-c` (unix) / `-f <tmpfile>` (windows). A new shell needs its own binary + neutral-rc flag (bash `--norc --noprofile`, fish `--no-config`).
- `setup_zsh_integration` (`plugin.rs:249-366`): reads `$ZDOTDIR|$HOME`, targets `.zshrc`, inserts/updates a block between `# >>> forge initialize >>>` and `# <<< forge initialize <<<` (`plugin.rs:253-254`), timestamped `.bak` backup, `parse_markers` state machine (`plugin.rs:215`). All of this is generic EXCEPT the rc filename + the comment-syntax of the markers (fish uses `#` too, so markers port unchanged).
- `ZshRPrompt::Display` emits **zsh-specific** prompt escapes (`%F{240}`, `%B`, `%f`, `%b`). Bash uses `\[\e[..m\]`; fish uses `set_color`. This is the ONE piece that cannot be shared verbatim — rendering must be parameterized per shell.

**RPrompt is a whole-conversion boundary.** For bash/fish the styling in `style.rs`/`rprompt.rs` needs a shell-kind-aware renderer, or a separate `BashRPrompt`/`FishRPrompt`.

---

## 3. CLI wiring + recommended generalization

### Current wiring
- `crates/forge_main/src/cli.rs:180-182` — `TopLevelCommand::Zsh(ZshCommandGroup)` with `#[command(subcommand, alias = "extension")]`.
- `ZshCommandGroup` enum: `cli.rs:583-611` — variants `Plugin, Theme, Doctor, Rprompt, Setup, Keyboard, Format { buffer }`.
- Top-level aliases: `TopLevelCommand::Setup` (`cli.rs:242-243`) and `TopLevelCommand::Doctor` (`cli.rs:245-246`), both delegating to zsh (`ui.rs:913-920`).
- Dispatch: `ui.rs:655-683` (the `Zsh` match), plus `on_zsh_*` methods `ui.rs:1950-1984`, `on_zsh_setup` `ui.rs:2016`, and `ZshRPrompt::from_config` at `ui.rs:4809`.
- CLI header comment (`cli.rs:1-6`) explicitly warns that the zsh plugin depends on this CLI structure — completions regenerate from `Cli::command()`, so the shape stays in sync automatically.

### RECOMMENDATION: single command group + `ShellKind` value enum (NOT parallel Bash/FishCommandGroup)

Add:
```rust
#[derive(Copy, Clone, Debug, ValueEnum, Default, PartialEq, Eq)]
#[clap(rename_all = "lower")]
pub enum ShellKind { #[default] Zsh, Bash, Fish }
```
Then rename the group `ZshCommandGroup` → `ShellCommandGroup` and thread a `ShellKind` into each subcommand (either a group-level `#[arg(long, value_enum, default_value_t)]` shared field via a `Parser` wrapper struct, mirroring `AgentCommandGroup`'s `porcelain` global-arg pattern at `cli.rs:385-393`, or a positional). Keep `TopLevelCommand::Zsh` as an **alias** (`alias = "shell"` / `alias = "extension"`) so `forge zsh plugin` keeps working; add `forge shell plugin --shell bash`.

Reasoning (minimal churn + AGENTS.md conventions):
- **One enum arm, one dispatch arm.** Parallel `BashCommandGroup`/`FishCommandGroup` triples the `match` in `ui.rs:655`, triples the CLI enum, and triples the completion/doctor plumbing — every future subcommand (like `Format`) must be added in three places. A `ShellKind` param is the single-axis-of-variation the AGENTS.md "single type parameter / compose, don't multiply" service ethos favors.
- **The functions become `generate_plugin(kind)`, `run_doctor(kind)`, `setup_integration(kind, ..)`.** Matches the "one generic parameter" guidance; the shell binary + rc-path + completion generator + rprompt renderer become a small `ShellKind` method table (`fn binary()`, `fn rc_path()`, `fn completion(cmd)`), no trait objects.
- **Back-compat preserved.** `Setup`/`Doctor` top-level aliases default `ShellKind::Zsh` (or auto-detect `$SHELL`), so existing `forge setup` / `forge doctor` behavior is unchanged; the 60+ CLI parse tests in `cli.rs` (e.g. `test_prompt_command` at `cli.rs:1663` asserting `TopLevelCommand::Zsh(ZshCommandGroup::Rprompt)`) need only the type-name update, not structural rewrites.

Auto-detection helper (mirrors `FrontendMode::resolve`, `cli.rs:149`): read `$SHELL` basename → `ShellKind`, so bare `forge setup` targets the user's actual shell.

---

## 4. NEW files/dirs + `.rc` targets per shell

Mirror the `shell-plugin/` layout per shell. RECOMMENDED: sibling top-level dirs (keeps `include_dir!` globs clean, no cross-shell file collisions, matches the existing flat `shell-plugin/` root):

```
shell-plugin-bash/           # or shell-plugin/bash/ — sibling preferred for include_dir simplicity
  lib/          (+ lib/actions/)   # bash port of dispatcher/helpers/context/bindings/completion/config/highlight + actions
  forge.theme.bash
  forge.setup.bash                 # body of the >>> forge initialize >>> block for .bashrc
  doctor.bash
  keyboard.bash
  # forge.plugin.bash optional (not embedded)
shell-plugin-fish/
  lib/          (+ lib/functions/) # fish uses functions/ + conf.d conventions
  forge.theme.fish
  forge.setup.fish
  doctor.fish
  keyboard.fish
```
New Rust modules: `crates/forge_main/src/bash/` and `crates/forge_main/src/fish/` (or a generalized `crates/forge_main/src/shell/` with a `ShellKind` param and per-kind embed constants). Each needs its own `include_dir!`/`include_str!` constants (macro args must be string literals — cannot be parameterized by a runtime `ShellKind`, so **one `include_dir!` per shell is unavoidable**; the dispatch function then selects the right `&Dir` by `ShellKind`).

`.rc` targets (used by `setup_integration`):
- zsh → `${ZDOTDIR:-$HOME}/.zshrc` (current)
- bash → `$HOME/.bashrc`
- fish → `${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish` (must `mkdir -p` the parent — `.config/fish/` may not exist; current zsh code never creates parent dirs, so this is a NEW requirement)

Markers (`# >>> forge initialize >>>` / `# <<< forge initialize <<<`) are `#`-comment based → valid in bash AND fish unchanged.

---

## 5. Tests to parameterize + Justfile

### `crates/forge_main/src/zsh/plugin.rs` tests (all `#[cfg(test)]`, same-file per AGENTS.md)
- `test_run_zsh_doctor_streaming` (`plugin.rs:381`) — spawns the shell; parameterize per `ShellKind` (and keep the "shell not available in CI" tolerance).
- `test_generated_plugin_wraps_zle_commands_with_osc133_markers` (`plugin.rs:416`) — asserts zsh ZLE + OSC133 strings; **zsh-only**, needs a bash/fish equivalent (bash: `bind -x` / `PROMPT_COMMAND`; fish: `fish_key_bindings`). Do NOT blindly parameterize — the emitted content differs.
- `test_generated_plugin_registers_zvm_after_init_hook` (`plugin.rs:442`) — zsh-vi-mode specific; zsh-only, no bash/fish analog.
- `test_setup_zsh_integration_*` (5 tests, `plugin.rs:454-801`) — marker insert/update/backup/nerd-font/editor. These are the most reusable: generalize the `HOME`/`ZDOTDIR` env fixture to per-shell rc paths (bash `.bashrc`, fish `config.fish`), assert the same marker + block behavior. The `ENV_LOCK` serial-mutex pattern (`plugin.rs:375`) stays.
- `rprompt.rs` tests (`rprompt.rs:199-439`, ~14 tests) assert literal zsh `%F{..}` escapes → each shell renderer needs its own expected-string suite.
- `cli.rs` parse tests referencing `TopLevelCommand::Zsh(ZshCommandGroup::..)` (e.g. `test_prompt_command` `cli.rs:1663`) — update type names; add `--shell bash|fish` parse coverage.

### Justfile (`/Users/milan.santosi/mysrc/forgecode/justfile`)
- `test-zsh` target at `justfile:227-229` → `zsh scripts/test-zsh-utils.sh`. Needs siblings `test-bash` (→ a `scripts/test-bash-utils.sh`) and `test-fish`. The menu/help listing at `justfile:393` references `test-zsh`.
- `bench-rprompt` (`justfile:171-173`) → `./scripts/benchmark.sh --threshold 60 zsh rprompt` — the benchmark script already takes a shell arg (`... zsh rprompt`); add `bash`/`fish` benchmark invocations.
- `shellcheck` (`justfile:128-130`) excludes zsh (`--exclude=SC1071`); new bash scripts SHOULD be shellcheck-clean, fish is out of shellcheck scope.

---

## Integration checklist (concrete, ordered)
1. Add `ShellKind {Zsh,Bash,Fish}` value enum in `cli.rs`; add `$SHELL` auto-detect helper (mirror `FrontendMode::resolve`).
2. Rename `ZshCommandGroup`→`ShellCommandGroup`; add group-level `shell: ShellKind` arg (mirror `AgentCommandGroup` global-arg pattern); keep `zsh`/`extension` aliases; add `shell` alias on `TopLevelCommand`.
3. Create `shell-plugin-bash/` and `shell-plugin-fish/` trees (lib + actions/functions, theme, setup, doctor, keyboard) — port the 7 `lib/*.zsh` + 7 `lib/actions/*.zsh` files.
4. Add per-shell `include_dir!`/`include_str!` constants (one set per shell — macro literals can't be `ShellKind`-parameterized); generalize `generate_*`, `run_*`, `setup_integration` to take `ShellKind`.
5. Parameterize completion gen: `match kind { Zsh=>Bash=>Fish=> } ` over `clap_complete::shells::{Zsh,Bash,Fish}` (already available, no dep change).
6. Generalize `execute_*_with_streaming` to select binary + neutral-rc flag by `ShellKind` (bash `--norc --noprofile`, fish `--no-config`).
7. Generalize `setup_integration` rc-path resolution per `ShellKind`; add `mkdir -p` for fish `~/.config/fish/`.
8. Add per-shell rprompt renderer (shell-kind-aware escapes) — the only non-portable core piece.
9. Update `ui.rs:655-683` dispatch to route `ShellKind`; update `Setup`/`Doctor` arms (`ui.rs:913-920`) + `on_zsh_*` methods to be shell-aware.
10. Parameterize/port tests (plugin.rs setup tests + rprompt suites); add `test-bash`/`test-fish` justfile targets; add `--shell` CLI parse tests.
11. Update the `cli.rs:1-6` header note to mention all three plugin trees.
