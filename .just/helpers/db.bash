#!/usr/bin/env bash
# db.bash -- diesel migration authoring, against a sandbox database.
#
#   db.bash migrate   apply pending migrations to the sandbox DB
#   db.bash revert    revert the latest migration on the sandbox DB
#   db.bash schema    regenerate schema.rs from the sandbox DB
#
# TWO FACTS THE OLD db-* RECIPES GOT WRONG.
#
# 1. The shipped binary never needs diesel-cli. crates/forge_repo/src/
#    database/pool.rs uses embed_migrations! and applies them at pool
#    creation, so a locally installed forge self-migrates on first run.
#    diesel-cli is a schema-AUTHORING tool only.
#
# 2. There is no repo-local database. forge stores state under base_path,
#    resolved as $FORGE_CONFIG -> ~/forge if it exists -> ~/.forge, and the
#    DB is base_path/.forge.db. On the operator's machine ~/forge exists, so
#    `diesel migration run` with a naively derived DATABASE_URL would run
#    migrations against the LIVE 3 MB operator database.
#
# The old recipes set no DATABASE_URL at all, so they simply failed. Rather
# than pointing them at live state, everything here targets the same
# .forge-sandbox the `just run` recipe uses. Migrating real state stays a
# deliberate manual act.
#
# Pure GNU Bash 5.3+.

# shellcheck source=tools.bash disable=SC2154,SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/tools.bash"

set -uo pipefail

cd -- "$JUST_REPO_DIR" || exit 1

readonly SANDBOX_DIR="$JUST_REPO_DIR/.forge-sandbox"
readonly SANDBOX_DB="$SANDBOX_DIR/.forge.db"

tools_need diesel || exit 1

prepare() {
  mkdir -p -- "$SANDBOX_DIR" || exit 1
  export DATABASE_URL="$SANDBOX_DB"
  printf '%susing sandbox database%s %s\n' "$C_DIM" "$C_RESET" "$SANDBOX_DB"
  printf '%s(your live state at ${FORGE_CONFIG:-~/forge} is untouched)%s\n\n' "$C_DIM" "$C_RESET"
}

case "${1:-}" in
  migrate)
    prepare
    diesel migration run
    ;;
  revert)
    prepare
    diesel migration revert
    ;;
  schema)
    prepare
    # The schema is derived from applied migrations, so bring the sandbox DB
    # up to date first -- printing a schema from an empty database yields an
    # empty schema.rs and an uncompilable workspace.
    diesel migration run || exit 1

    # Generate to a temp file, then move into place. The old recipe wrote
    # `diesel print-schema > crates/.../schema.rs`, and the shell truncates
    # the target BEFORE diesel starts: any diesel failure left schema.rs
    # empty. Same truncate-before-write shape as the old `just schema`.
    target="$JUST_REPO_DIR/crates/forge_repo/src/database/schema.rs"
    tmp=$(mktemp) || exit 1
    trap 'rm -f -- "$tmp"' EXIT

    diesel print-schema > "$tmp" || just_die 'diesel print-schema failed; schema.rs untouched'
    [[ -s $tmp ]] || just_die 'diesel print-schema produced nothing; schema.rs untouched'

    if diff -q "$tmp" "$target" > /dev/null 2>&1; then
      printf 'schema.rs is current\n'
    else
      cp -f -- "$tmp" "$target" || exit 1
      printf 'schema.rs regenerated\n'
      git --no-pager diff --stat -- "$target"
    fi
    ;;
  *)
    printf 'usage: db.bash {migrate|revert|schema}\n' >&2
    exit 2
    ;;
esac
