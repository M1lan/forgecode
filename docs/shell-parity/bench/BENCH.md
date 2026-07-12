# Forge shell-plugin benchmark (hyperfine)

Metric A = plugin load+init time. Fresh **interactive** shell under a real pty
(`/usr/bin/script -q /dev/null`) that sources the plugin and exits, vs the same
shell with **no plugin** (baseline). A pty is mandatory: bash `bind -x` (guarded
by `[[ $- == *i* ]]`) and fish `bind` only register under a genuine interactive
tty. pty + shell-startup cost is constant across baseline/plugin, so the delta
isolates plugin overhead. All three plugins verified fully loaded under the pty
(zsh: 2 zle widgets + 2 hooks; bash: `bind -X` C-m registered; fish:
`_forge_accept_line` bound).

Pinned env: `TERM=xterm-256color COLUMNS=80 LINES=24 LC_ALL=C`,
`fish_features=no-mark-prompt`, no user rc (zsh `-f`; bash `--noprofile --rcfile`;
fish `-i -C`), fake `forge` shim prepended to PATH. hyperfine 1.20.0,
`--warmup 3 --runs 40`. macOS/Darwin 25.5, Homebrew zsh 5.9.1 / bash 5.3.15 /
fish 4.8.0.

## Metric A — load + init

| shell | baseline ms | with-plugin ms | plugin overhead ms | keystroke ms |
|-------|------------:|---------------:|-------------------:|:------------:|
| zsh   | 9.0 ± 1.2   | 14.0 ± 1.7     | **5.0**            | N/A (see B)  |
| bash  | 10.4 ± 1.4  | 12.0 ± 1.3     | **1.6**            | N/A (see B)  |
| fish  | 16.3 ± 1.1  | 16.2 ± 0.8     | **~0.0** (−0.1, within noise) | N/A (see B) |

Absolute numbers include the constant `sh -c` + `script` pty + shell-startup
wrap; that wrap cancels in the overhead column.

## Metric B — per-keystroke dispatch

**NOT-MEASURED-HEADLESS.** The accept-line handler in every shell
(`forge-accept-line` / `_forge_accept_line`) can only run inside a live line
editor — it calls `zle redisplay`/`zle accept-line` (zsh), `READLINE_*` (bash),
`commandline` (fish). Invoked in isolation zsh errors `widgets can only be
called when ZLE is active`. A one-off keystroke driven through a pty is
dominated by prompt re-render + the `forge` subprocess fork, not the handler, so
any number would be bogus.

## Interpretation

- **zsh is heaviest to load** (~5 ms overhead): it `source`s 16 separate
  `lib/*.zsh` files (file-I/O per source). bash (~1.6 ms) and fish (~0 ms) are
  single self-contained files.
- **fish plugin load is effectively free** (~0 ms, below the ±1 ms sigma):
  fish stores its ~40 function definitions without executing them; only config
  vars + binding/hook registration run at load.
- **No plugin's load overhead is user-perceptible** — all are well under the
  ~50 ms human-perception threshold (worst case zsh = 5 ms).

## Artifacts

- `runner.bash` — the benchmark runner.
- `zsh.json` / `bash.json` / `fish.json` — hyperfine JSON exports.
