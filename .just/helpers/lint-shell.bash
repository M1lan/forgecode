#!/usr/bin/env bash
# lint-shell.bash -- the blocking shell gate.
#
# Two lanes, both blocking, neither able to pass by accident:
#
#   helpers   .just/helpers/*.bash at -S warning. This repo's own harness;
#             new code here must be warning-clean to land.
#   tree      every tracked *.sh and *.bash at -S error. Upstream shell
#             files carry pre-existing warning-severity findings (SC2034,
#             SC2155, SC2206, SC2178 -- verified 2026-07-30), so gating the
#             whole tree at warning would block every commit until someone
#             does a dedicated cleanup pass. That is an operator decision,
#             not a lint-policy one.
#
# WHAT THIS REPLACES. The old `shellcheck` recipe wrapped itself in
# `if command -v shellcheck; then …; else printf 'not installed' >&2; fi`
# and so exited 0 when the tool was absent -- while its own doc comment
# called it a "blocking Justfile-system gate". It was a dependency of lint,
# verify and ci, all three of which could therefore report success having
# linted nothing. The old `shellcheck-legacy` recipe ended in
# `|| printf 'informational only'`, making it structurally incapable of
# failing.
#
# ZSH IS NOT SHELLCHECKABLE and pretending otherwise is worse than skipping
# it. shellcheck emits SC1071 for a zsh shebang; the old recipe passed
# --exclude=SC1071, which suppressed that error and produced exit 0 with no
# output -- reporting 6.4 KB of unanalysed zsh as clean. Zsh files are parse-
# checked by test-shell.bash with `zsh -n` instead, which actually works.
#
# Pure GNU Bash 5.3+.

# shellcheck source=tools.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/tools.bash"

set -uo pipefail

cd -- "$JUST_REPO_DIR" || exit 1

tools_need shellcheck git || exit 1

# SC1008/SC2096/SC2239/SC1115: forge's setup-managed block files open with a
# '# !!' marker rather than a shebang. shellcheck misreads that as a broken
# shebang. Those files are upstream-owned and not ours to reformat.
readonly TREE_EXCLUDES=SC1071,SC1008,SC2096,SC2239,SC1115

rc=0

printf '%s-- lane 1: .just/helpers at -S warning%s\n' "$C_BOLD" "$C_RESET"
if shellcheck -x -S warning --source-path="$JUST_HELPERS_DIR" "$JUST_HELPERS_DIR"/*.bash; then
  printf '%sclean%s\n' "$C_GREEN" "$C_RESET"
else
  rc=1
fi

printf '\n%s-- lane 2: the POSIX installer%s\n' "$C_BOLD" "$C_RESET"
if [[ -f cli ]]; then
  if shellcheck --shell=sh --exclude=SC2059 cli; then
    printf '%sclean%s\n' "$C_GREEN" "$C_RESET"
  else
    rc=1
  fi
else
  printf 'no ./cli in this tree -- skipping\n'
fi

printf '\n%s-- lane 3: every tracked *.sh / *.bash at -S error%s\n' "$C_BOLD" "$C_RESET"
mapfile -t shell_files < <(git ls-files -- '*.sh' '*.bash')
if ((${#shell_files[@]} == 0)); then
  printf 'none tracked\n'
elif shellcheck -x -S error --source-path=SCRIPTDIR --exclude="$TREE_EXCLUDES" "${shell_files[@]}"; then
  printf '%sclean (%d files)%s\n' "$C_GREEN" "${#shell_files[@]}" "$C_RESET"
else
  rc=1
fi

((rc == 0)) || printf '\n%sshell lint failed%s\n' "$C_RED" "$C_RESET" >&2
exit "$rc"
