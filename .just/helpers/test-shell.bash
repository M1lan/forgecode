#!/usr/bin/env bash
# test-shell.bash -- parse-check every shell file this repo ships or embeds.
#
# WHY THIS MATTERS MORE THAN A NORMAL LINT
#
# The whole of shell-plugin/ is compiled INTO the forge binary:
# crates/forge_main/src/zsh/plugin.rs uses include_dir! over shell-plugin/lib
# (recursive, including lib/actions/) plus include_str! for the bash and fish
# plugins, the theme, doctor.zsh, keyboard.zsh and all three setup blocks.
#
# A syntax error in any of those files compiles cleanly into a shipped
# binary and fails at the USER's shell startup. Before this script, only two
# of roughly nineteen embedded shell assets had any gate at all
# (`bash -n` on the bash plugin, `fish --no-execute` on the fish plugin) --
# and there was no `zsh -n` anywhere in the repository, leaving fifteen zsh
# files, ~1900 lines, completely unchecked.
#
# Fish is skipped when fish is absent, and says so loudly with a non-fatal
# marker. Everything else is mandatory.
#
# Pure GNU Bash 5.3+.

# shellcheck source=tools.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/tools.bash"

set -uo pipefail

cd -- "$JUST_REPO_DIR" || exit 1

rc=0
checked=0

ok() {
  printf '  %s%-6s%s %s\n' "$C_GREEN" 'ok' "$C_RESET" "$1"
  ((checked++))
  return 0
}
bad() {
  printf '  %s%-6s%s %s\n' "$C_RED" 'FAIL' "$C_RESET" "$1"
  rc=1
}

# --- zsh: the fifteen files nothing checked ---
printf '%szsh (embedded into the binary)%s\n' "$C_BOLD" "$C_RESET"
if has zsh; then
  mapfile -t zsh_files < <(git ls-files -- '*.zsh')
  if ((${#zsh_files[@]} == 0)); then
    printf '  none tracked\n'
  else
    for f in "${zsh_files[@]}"; do
      if zsh -n "$f" 2> /dev/null; then ok "$f"; else
        bad "$f"
        zsh -n "$f" 2>&1 | head -3 | sed 's/^/         /'
      fi
    done
  fi
else
  printf '  %szsh not found -- cannot verify %d embedded files%s\n' \
    "$C_RED" "$(git ls-files -- '*.zsh' | wc -l | tr -d ' ')" "$C_RESET"
  rc=1
fi

# --- bash: plugin + setup block ---
printf '\n%sbash%s\n' "$C_BOLD" "$C_RESET"
for f in shell-plugin/bash/forge.plugin.bash shell-plugin/bash/forge.setup.bash; do
  [[ -f $f ]] || continue
  if bash -n "$f" 2> /dev/null; then ok "$f"; else
    bad "$f"
    bash -n "$f" 2>&1 | head -3 | sed 's/^/         /'
  fi
done

# --- the Justfile's own helpers ---
printf '\n%s.just/helpers%s\n' "$C_BOLD" "$C_RESET"
for f in "$JUST_HELPERS_DIR"/*.bash; do
  if bash -n "$f" 2> /dev/null; then ok "${f#"$JUST_REPO_DIR"/}"; else
    bad "${f#"$JUST_REPO_DIR"/}"
    bash -n "$f" 2>&1 | head -3 | sed 's/^/         /'
  fi
done

# --- POSIX installer, including its own self-test ---
printf '\n%sPOSIX installer%s\n' "$C_BOLD" "$C_RESET"
if [[ -f cli ]]; then
  if sh -n cli 2> /dev/null; then ok 'cli (sh -n)'; else bad 'cli (sh -n)'; fi
  if FORGE_SELF_TEST_PATH=1 sh cli > /dev/null 2>&1; then
    ok 'cli --self-test PATH logic'
  else
    bad 'cli --self-test PATH logic'
  fi
else
  printf '  no ./cli in this tree\n'
fi

if [[ -x "$JUST_HELPERS_DIR/install-audit.bash" ]]; then
  if "$JUST_HELPERS_DIR/install-audit.bash" --self-test > /dev/null 2>&1; then
    ok 'install-audit --self-test'
  else
    bad 'install-audit --self-test'
  fi
fi

# --- fish: genuinely optional, and it says so ---
printf '\n%sfish%s\n' "$C_BOLD" "$C_RESET"
if has fish; then
  for f in shell-plugin/fish/forge.plugin.fish shell-plugin/fish/forge.setup.fish; do
    [[ -f $f ]] || continue
    if fish --no-execute "$f" 2> /dev/null; then ok "$f"; else bad "$f"; fi
  done
else
  printf '  %sSKIPPED -- fish not installed (install: brew install fish)%s\n' "$C_YELLOW" "$C_RESET"
fi

printf '\n%d files parse-checked\n' "$checked"
((rc == 0)) || printf '%sshell parse-check failed%s\n' "$C_RED" "$C_RESET" >&2
exit "$rc"
