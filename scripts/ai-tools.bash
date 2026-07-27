#!/usr/bin/env bash
# ── ai-tools.bash — repo-local AI-coding tooling multiplexer ─────────────────
#
# One idempotent entrypoint for every code-intelligence index used in this
# repo: gitnexus, codegraph, grepai, repowise. Safe to re-run: `init` only
# builds what is missing, `sync` updates incrementally, `resync` forces a full
# rebuild. All indexing runs locally (no paid LLM calls, no network) — repowise
# stays in --index-only mode and grepai uses the local ollama embedder.
#
# Usage:
#   scripts/ai-tools.bash <command> [args]
#
# Global commands (fan out across all tools):
#   doctor              tool availability + versions + index presence
#   status              index status for every tool
#   init                build any missing index (idempotent; skips healthy)
#   sync                incremental update for every tool
#   resync              force full re-index for every tool
#   clean               remove every index (asks unless FORCE=1)
#   search <query>      semantic code search (grepai, TOON output)
#
# Per-tool commands (passthrough + curated idempotent actions):
#   gitnexus  <init|sync|resync|status|clean|query|context|impact|trace|wiki|raw ...>
#   codegraph <init|sync|resync|status|clean|query|explore|node|callers|callees|impact|raw ...>
#   grepai    <init|sync|resync|status|clean|search|trace|raw ...>
#   repowise  <init|sync|resync|status|clean|search|risk|health|raw ...>
#
# Env overrides:
#   FORCE=1                 skip confirmation on clean
#   GITNEXUS_ANALYZE_FLAGS  extra flags for `gitnexus analyze`
#                           (default: --skip-agents-md --skip-skills)
#
# Exit codes: 0 ok · 2 usage · 3 missing tool · 5 action failed

set -euo pipefail

# ── Bash floor guard ──────────────────────────────────────────────────────────
if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 3) )); then
  printf 'ai-tools: needs Bash >= 5.3 (got %s)\n' "$BASH_VERSION" >&2
  exit 3
fi

# ── Colors (tput, no raw ANSI; degrade to empty when not a tty) ───────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
  C_DIM=$(tput dim); C_BOLD=$(tput bold); C_RESET=$(tput sgr0)
  C_OK=$(tput setaf 2); C_WARN=$(tput setaf 3); C_ERR=$(tput setaf 1)
else
  C_DIM=''; C_BOLD=''; C_RESET=''; C_OK=''; C_WARN=''; C_ERR=''
fi

log()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_OK" "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit "${2:-5}"; }

# ── Repo root ─────────────────────────────────────────────────────────────────
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "not inside a git repository" 2
cd "$ROOT"

GITNEXUS_ANALYZE_FLAGS="${GITNEXUS_ANALYZE_FLAGS:---skip-agents-md --skip-skills}"

have() { command -v "$1" >/dev/null 2>&1; }

require() {
  have "$1" || die "missing tool: $1 (not on PATH)" 3
}

# The four indexers: name → binary, index dir.
TOOLS=(gitnexus codegraph grepai repowise)
declare -A TOOL_DIR=(
  [gitnexus]=.gitnexus
  [codegraph]=.codegraph
  [grepai]=.grepai
  [repowise]=.repowise
)

index_present() { [[ -e "${TOOL_DIR[$1]}" ]]; }

# ── gitnexus ──────────────────────────────────────────────────────────────────
gitnexus_init()   { require gitnexus; if index_present gitnexus; then ok "gitnexus already indexed"; else log "gitnexus: analyzing…"; # shellcheck disable=SC2086
                    gitnexus analyze $GITNEXUS_ANALYZE_FLAGS && ok "gitnexus indexed"; fi; }
gitnexus_sync()   { require gitnexus; log "gitnexus: incremental analyze…"; # shellcheck disable=SC2086
                    gitnexus analyze $GITNEXUS_ANALYZE_FLAGS && ok "gitnexus synced"; }
gitnexus_resync() { require gitnexus; log "gitnexus: full re-index…"; # shellcheck disable=SC2086
                    gitnexus analyze -f $GITNEXUS_ANALYZE_FLAGS && ok "gitnexus re-indexed"; }
gitnexus_status() { require gitnexus; gitnexus status; }
gitnexus_clean()  { require gitnexus; gitnexus clean --yes 2>/dev/null || gitnexus clean; }

# ── codegraph ─────────────────────────────────────────────────────────────────
codegraph_init()   { require codegraph; if index_present codegraph; then log "codegraph: syncing existing index…"; codegraph sync && ok "codegraph synced"; else log "codegraph: initializing…"; codegraph init && ok "codegraph indexed"; fi; }
codegraph_sync()   { require codegraph; log "codegraph: sync…"; codegraph sync && ok "codegraph synced"; }
codegraph_resync() { require codegraph; log "codegraph: full re-index…"; codegraph index && ok "codegraph re-indexed"; }
codegraph_status() { require codegraph; codegraph status; }
codegraph_clean()  { require codegraph; codegraph uninit; }

# ── grepai (local ollama embedder; watch daemon builds the index) ─────────────
grepai_init() {
  require grepai
  if [[ ! -f .grepai/config.yaml ]]; then
    log "grepai: init (defaults)…"
    grepai init --yes
  fi
  grepai_sync
}
grepai_sync() {
  require grepai
  log "grepai: watcher initial scan (background)…"
  grepai watch --background >/dev/null 2>&1 || true
  ok "grepai watcher running (index maintained live)"
}
grepai_resync() {
  require grepai
  log "grepai: stop watcher, drop index, rescan…"
  grepai watch --stop >/dev/null 2>&1 || true
  rm -f .grepai/index.gob .grepai/index.gob.lock 2>/dev/null || true
  grepai watch --background >/dev/null 2>&1 || true
  ok "grepai re-indexing (watcher running)"
}
grepai_status() { require grepai; grepai status 2>&1 || warn "grepai index not ready — run: $0 grepai resync"; }
grepai_clean()  { require grepai; grepai watch --stop >/dev/null 2>&1 || true; rm -rf .grepai && ok "grepai index removed"; }

# ── repowise (index-only: AST + graph + git + dead-code, no LLM/network) ──────
repowise_init() {
  require repowise
  local pages
  pages=$(repowise status 2>/dev/null | rg -o 'Total pages[^0-9]*([0-9]+)' -r '$1' | head -1 || echo 0)
  if index_present repowise && [[ "${pages:-0}" != "0" ]]; then
    ok "repowise already has ${pages} pages"
  else
    log "repowise: index-only ingest…"
    repowise init --index-only -y && ok "repowise ingested"
  fi
}
repowise_sync()   { require repowise; log "repowise: index-only re-ingest…"; repowise init --index-only -y && ok "repowise synced"; }
repowise_resync() { require repowise; log "repowise: force re-ingest…"; repowise init --index-only -y --force && ok "repowise re-indexed"; }
repowise_status() { require repowise; repowise status; }
repowise_clean()  { require repowise; repowise delete 2>/dev/null || rm -rf .repowise; ok "repowise data removed"; }

# ── Global fan-out ────────────────────────────────────────────────────────────
global_init()   { for t in "${TOOLS[@]}"; do if have "$t"; then "${t}_init";   else warn "$t not installed — skipped"; fi; done; }
global_sync()   { for t in "${TOOLS[@]}"; do if have "$t"; then "${t}_sync";   else warn "$t not installed — skipped"; fi; done; }
global_resync() { for t in "${TOOLS[@]}"; do if have "$t"; then "${t}_resync"; else warn "$t not installed — skipped"; fi; done; }

global_status() {
  for t in "${TOOLS[@]}"; do
    printf '\n%s── %s ──%s\n' "$C_BOLD" "$t" "$C_RESET" >&2
    if have "$t"; then "${t}_status" || true; else warn "$t not installed"; fi
  done
}

global_clean() {
  if [[ "${FORCE:-0}" != "1" ]]; then
    printf 'Remove ALL AI indexes (%s)? [y/N] ' "${TOOLS[*]}" >&2
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "aborted" 0
  fi
  for t in "${TOOLS[@]}"; do have "$t" && "${t}_clean" || true; done
}

global_doctor() {
  printf '%sAI tooling — %s%s\n' "$C_BOLD" "$ROOT" "$C_RESET"
  printf '%s%-10s %-7s %-8s %s%s\n' "$C_DIM" "TOOL" "INDEX" "STATUS" "BINARY" "$C_RESET"
  local t bin idx_word idx_c st_word st_c
  for t in "${TOOLS[@]}"; do
    if bin=$(command -v "$t" 2>/dev/null); then
      st_word="ok";      st_c="$C_OK"
    else
      bin="—"; st_word="MISSING"; st_c="$C_ERR"
    fi
    if index_present "$t"; then idx_word="built"; idx_c="$C_OK"; else idx_word="none"; idx_c="$C_WARN"; fi
    printf '%-10s %b%-7s%b %b%-8s%b %s\n' \
      "$t" "$idx_c" "$idx_word" "$C_RESET" "$st_c" "$st_word" "$C_RESET" "$bin"
  done
  # Adjacent structural/search tools (used by the Justfile ecosystem).
  printf '\n%sadjacent:%s ' "$C_DIM" "$C_RESET"
  local a
  for a in ast-grep probe semgrep tokei yek rg fd; do
    if have "$a"; then printf '%s%s%s ' "$C_OK" "$a" "$C_RESET"; else printf '%s%s%s ' "$C_ERR" "$a" "$C_RESET"; fi
  done
  printf '\n'
}

global_search() {
  [[ -n "${1:-}" ]] || die "search needs a query" 2
  require grepai
  grepai search "$*" --toon --limit 10
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
usage() {
  rg '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -46
  exit "${1:-2}"
}

cmd="${1:-doctor}"; shift || true

case "$cmd" in
  doctor)            global_doctor ;;
  status)            global_status ;;
  init)              global_init ;;
  sync)              global_sync ;;
  resync|re-sync)    global_resync ;;
  clean)             global_clean ;;
  search)            global_search "$@" ;;
  help|-h|--help)    usage 0 ;;

  gitnexus|codegraph|grepai|repowise)
    tool="$cmd"; action="${1:-status}"; shift || true
    case "$action" in
      init)           "${tool}_init" ;;
      sync)           "${tool}_sync" ;;
      resync|re-sync) "${tool}_resync" ;;
      status)         "${tool}_status" ;;
      clean)          "${tool}_clean" ;;
      raw)            require "$tool"; "$tool" "$@" ;;
      *)              # passthrough (query/context/impact/trace/…)
        require "$tool"
        # gitnexus keeps a global multi-repo registry; its graph queries need
        # -r/--repo to disambiguate. Auto-inject this repo's name when absent.
        if [[ "$tool" == gitnexus ]] \
           && [[ " query context impact trace cypher check detect-changes detect_changes " == *" $action "* ]] \
           && [[ " $* " != *" --repo "* && " $* " != *" -r "* ]]; then
          gitnexus "$action" "$@" --repo "$(basename "$ROOT")"
        else
          "$tool" "$action" "$@"
        fi
        ;;
    esac
    ;;

  *) warn "unknown command: $cmd"; usage 2 ;;
esac
