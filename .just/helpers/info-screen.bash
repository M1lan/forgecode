#!/usr/bin/env bash
# info-screen.bash -- the welcome shown by a bare `just`.
#
#   info-screen.bash            full splash + countdown (default recipe)
#   info-screen.bash --static   facts only, no countdown (the `info` recipe)
#
# Countdown hotkeys:
#   enter / m / f -> exec just menu   (the launcher)
#   d             -> exec just doctor
#   t             -> exec just test
#   any other     -> back to shell immediately
#   timeout       -> print ONE frugal factoid, exit 0
#
# Layout by terminal width:
#   wide     (cols >= 130)  three panel columns
#   square   (cols >= 96)   two panel columns
#   portrait (cols >= 78)   stacked single column
#   tiny / non-tty / no-gum -> degrade to --static (never to a bare list)
#
# Facts are FILE-PARSE + cheap git ops ONLY -- this script never spawns
# cargo/rustc and never runs a LOC/tokei scan (both cost 0.2-0.5s on this
# workspace, too slow for a screen shown on every bare `just`).
# Pure GNU Bash 5.3+. Colors: terminal defaults via tput only; panel boxes
# come from gum, which renders its own borders at runtime -- not authored
# line-art. No clear / tput clear anywhere: prints inline, appends to
# scrollback.

# shellcheck source=lib.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

set -uo pipefail

cd -- "$JUST_REPO_DIR" || exit 1

restore() { is_tty && tput cnorm 2> /dev/null; }
trap 'restore; exit 130' INT TERM HUP

STATIC=0
[[ "${1:-}" == "--static" ]] && STATIC=1

# --- degradation: bare `just` ALWAYS shows the info splash ---
if ((!STATIC)); then
  { is_tty && [[ -t 0 ]]; } || STATIC=1
fi
COLS=$(term_cols)
LINES_=$(term_lines)
if ! has gum || ((COLS < 78 || LINES_ < 24)); then
  STATIC=1
fi

# --- gather facts (file parsing + cheap git ops only) ---
branch=$(fact_branch)
dirty=$(fact_dirty)
last=$(fact_last_commit)
((${#last} > 40)) && last="${last:0:39}..."
crate_v=$(fact_crate_version)
edition=$(fact_rust_edition)
msrv=$(fact_msrv)
toolchain=$(fact_toolchain)
ws_crates=$(fact_workspace_crates)
bin_kind=$(fact_bin_kind)
toolbelt=$("$JUST_HELPERS_DIR/doctor.bash" --summary 2> /dev/null || true)

dirty_str="clean"
((dirty > 0)) && dirty_str="${dirty} dirty file(s)"

# --- banner ---
banner() {
  local art
  if has figlet; then
    art=$(figlet -f smslant -w "$COLS" "$PKGNAME" 2> /dev/null) ||
      art=$(figlet -f slant -w "$COLS" "$PKGNAME" 2> /dev/null) ||
      art=$(figlet -w "$COLS" "$PKGNAME" 2> /dev/null) ||
      art="$PKGNAME"
  else
    art="$PKGNAME"
  fi
  printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$art" "$C_RESET"
}

# --- content panels ---
panel_project() {
  printf '%sPROJECT%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
  printf '  %-10s %s\n' "name" "$PKGNAME"
  printf '  %-10s %s\n' "version" "$crate_v"
  printf '  %-10s %s\n' "edition" "$edition"
  printf '  %-10s %s\n' "msrv" "$msrv"
  printf '  %-10s %s\n' "toolchain" "$toolchain"
  printf '  %-10s %s crates\n' "workspace" "$ws_crates"
}

panel_repo() {
  printf '%sREPO%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
  printf '  %-10s %s\n' "branch" "$branch"
  printf '  %-10s %s\n' "status" "$dirty_str"
  printf '  %-10s %s\n' "last" "$last"
  local bin_line="not built"
  [[ -n "$bin_kind" ]] && bin_line="target/$bin_kind/$PKGNAME"
  printf '  %-10s %s\n' "binary" "$bin_line"
}

panel_quickstart() {
  printf '%sQUICKSTART%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
  printf '  %sjust build%s     compile workspace\n' "$C_BOLD" "$C_RESET"
  printf '  %sjust test%s      insta test suite\n' "$C_BOLD" "$C_RESET"
  printf '  %sjust lint%s      fmt-check + clippy\n' "$C_BOLD" "$C_RESET"
  printf '  %sjust ci%s        fix + verify gate\n' "$C_BOLD" "$C_RESET"
  printf '  %sjust ci%s        local CI mirror\n' "$C_BOLD" "$C_RESET"
  printf '  %sjust menu%s      interactive TUI\n' "$C_BOLD" "$C_RESET"
}

panel_toolbelt() {
  printf '%sTOOLBELT%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
  printf '  %s\n' "${toolbelt:-run just doctor for status}"
}

keys_bar_text() {
  printf '%senter/m/f%s menu   %sd%s doctor   %st%s test   any: back to shell\n' \
    "$C_BOLD$C_GREEN" "$C_RESET" \
    "$C_BOLD$C_GREEN" "$C_RESET" \
    "$C_BOLD$C_GREEN" "$C_RESET"
}

# --- panel layout ---
render_panels() {
  local style=(--border rounded --border-foreground "$G_ACCENT" --padding "0 1")
  local keystyle=(--border normal --border-foreground "3" --padding "0 1")

  if ((COLS >= 130)); then
    local w=$(((COLS - 12) / 3))
    local left mid right
    left=$({
      panel_project
      printf '\n'
      panel_repo
    } | gum style "${style[@]}" --width "$w")
    mid=$(panel_quickstart | gum style "${style[@]}" --width "$w")
    right=$(panel_toolbelt | gum style "${style[@]}" --width "$w")
    gum join --horizontal --align top "$left" "$mid" "$right"
    keys_bar_text | gum style "${keystyle[@]}" --width "$((COLS - 6))"
  elif ((COLS >= 96)); then
    local w=$(((COLS - 8) / 2))
    local left right
    left=$({
      panel_project
      printf '\n'
      panel_repo
    } | gum style "${style[@]}" --width "$w")
    right=$({
      panel_quickstart
      printf '\n'
      panel_toolbelt
    } | gum style "${style[@]}" --width "$w")
    gum join --horizontal --align top "$left" "$right"
    keys_bar_text | gum style "${keystyle[@]}" --width "$((COLS - 6))"
  else
    local w=$((COLS - 6))
    panel_project | gum style "${style[@]}" --width "$w"
    panel_repo | gum style "${style[@]}" --width "$w"
    panel_quickstart | gum style "${style[@]}" --width "$w"
    keys_bar_text | gum style "${keystyle[@]}" --width "$w"
  fi
}

# --- countdown ---
# JUST_SPLASH_SECS accepts an integer or integer.<one-digit> (e.g. "6",
# "6.7"); anything else (garbage, multi-digit fractions, values that would
# read as invalid octal to `$(( ))` once split) falls back to the 6.7s
# default rather than crashing the splash.
splash_tenths() {
  local s="${JUST_SPLASH_SECS:-6.7}" whole frac
  [[ $s =~ ^[0-9]+(\.[0-9])?$ ]] || s=6.7
  if [[ $s == *.* ]]; then
    whole=${s%.*}
    frac=${s#*.}
  else
    whole=$s
    frac=0
  fi
  # force base-10 so a leading zero (e.g. "06") is never read as octal
  printf '%s' "$((10#$whole * 10 + 10#$frac))"
}

countdown() {
  local t key rc total barw
  total=$(splash_tenths)
  barw=10
  tput civis 2> /dev/null
  drain_tty_input
  for ((t = total; t > 0; t--)); do
    local filled=$(((t * barw + total - 1) / total)) empty bar='' gap=''
    ((filled > barw)) && filled=barw
    empty=$((barw - filled))
    ((filled > 0)) && {
      printf -v bar '%*s' "$filled" ''
      bar=${bar// /#}
    }
    ((empty > 0)) && {
      printf -v gap '%*s' "$empty" ''
      gap=${gap// /-}
    }
    printf '\r  %s[%s%s%s%s]%s %ss  %senter/m/f%s menu  %sd%s doctor  %st%s test  any: shell' \
      "$C_DIM" "$C_YELLOW" "$bar" "$C_DIM" "$gap" "$C_RESET" "$(fmt_tenths "$t")" \
      "$C_BOLD$C_GREEN" "$C_RESET" \
      "$C_BOLD$C_GREEN" "$C_RESET" \
      "$C_BOLD$C_GREEN" "$C_RESET"
    is_tty && tput el 2> /dev/null
    rc=0
    read -rsn1 -t 0.1 key || rc=$?
    if ((rc == 0)); then
      printf '\r'
      is_tty && tput el 2> /dev/null
      restore
      case "$key" in
        '' | m | M | f | F) exec "$JUST_BIN" menu ;;
        d | D) exec "$JUST_BIN" doctor ;;
        t | T) exec "$JUST_BIN" test ;;
        *) return 0 ;;
      esac
    fi
    ((rc > 128)) || break # rc 1 = EOF
  done
  printf '\r'
  is_tty && tput el 2> /dev/null
  restore
  local factoid
  factoid=$("$JUST_HELPERS_DIR/doctor.bash" --factoid 2> /dev/null || true)
  printf '  %s>%s %s\n' "$C_BOLD$C_YELLOW" "$C_RESET" \
    "${factoid:-just menu anytime -- just help for the plain list}"
}

# --- main ---
banner
printf '\n'
if has gum; then
  render_panels
else
  panel_project
  printf '\n'
  panel_repo
  printf '\n'
  panel_quickstart
fi
printf '\n'
((STATIC)) || countdown
restore
exit 0
