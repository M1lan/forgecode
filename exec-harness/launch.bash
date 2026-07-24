#!/usr/bin/env bash
# exec-harness launcher — starts `omc interop --yolo` (OMC leader + OMX
# worker split panes) in the forgecode repo, with bootstrap prompt on the
# clipboard for the OMC pane.
set -euo pipefail

[[ ${BASH_VERSINFO[0]} -ge 5 && ${BASH_VERSINFO[1]} -ge 3 ]] ||
  {
    printf 'need Bash >= 5.3 (got %s)\n' "$BASH_VERSION" >&2
    exit 69
  }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repo_root"

command -v omc > /dev/null 2>&1 || {
  printf 'omc not found on PATH\n' >&2
  exit 69
}

bootstrap='You are the OMC leader of the forgecode deep-analysis run. Read exec-harness/BRIEF.md, exec-harness/PLAN.md, exec-harness/LEDGER.md, exec-harness/EVIDENCE.md. Obey the BRIEF contract exactly: LEDGER is live state, EVIDENCE is append-only measurements, commit small, no commit trailers, route text-only subtasks to ollama cloud models via llm-fanout (-t 0 for reasoning models), OMX pane is your verifier. Start Phase P1 now. ultrawork'

if command -v pbcopy > /dev/null 2>&1; then
  printf '%s' "$bootstrap" | pbcopy
  printf 'bootstrap prompt copied to clipboard — paste into the OMC pane\n'
else
  printf -- '--- bootstrap prompt (copy manually) ---\n%s\n---\n' "$bootstrap"
fi

# omc interop requires a running rmux/tmux session; create one if absent
if [[ -z ${TMUX:-} ]]; then
  session='forgecode-exec'
  if command -v rmux > /dev/null 2>&1; then
    exec rmux new-session -A -s "$session" -c "$repo_root" 'omc interop --yolo'
  fi
  exec tmux new-session -A -s "$session" -c "$repo_root" 'omc interop --yolo'
fi

exec omc interop --yolo
