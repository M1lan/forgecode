#!/opt/homebrew/bin/bash
# run.sh -- drive the differential conformance oracle.
# Usage:
#   ./run.sh selfcheck            # zsh reference vs itself (must be 100%)
#   ./run.sh broken              # reference vs the corrupted candidate
#   ./run.sh diff <ref> <cand>   # arbitrary differential
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="/Users/milan.santosi/mysrc/forgecode/shell-plugin"
BROKEN="$HERE/broken-plugin"
PY=(uvx --with pyte --with pexpect python "$HERE/oracle.py")

case "${1:-selfcheck}" in
  selfcheck) "${PY[@]}" selfcheck --plugin "$REF" ;;
  broken)    "${PY[@]}" diff --ref "$REF" --cand "$BROKEN" ;;
  diff)      "${PY[@]}" diff --ref "$2" --cand "$3" ;;
  *) printf 'usage: run.sh {selfcheck|broken|diff <ref> <cand>}\n' >&2; exit 2 ;;
esac
