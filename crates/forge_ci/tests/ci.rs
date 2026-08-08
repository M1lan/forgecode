//! FORK PATCH (mymain, 2026-08-09): this file no longer GENERATES workflows.
//!
//! Upstream ships seven workflow generators here, each written as a `#[test]`
//! that writes into `.github/workflows/`. Two consequences made that wrong for
//! this fork.
//!
//! First, a plain `cargo test` rewrote seven tracked files as a side effect,
//! so a green test run could leave a dirty tree, and any hand edit to a
//! workflow was silently reverted by the next test.
//!
//! Second, and worse, six of the seven generated workflows are upstream's
//! release and bot machinery: publishing to `antinomyhq/*` npm packages and a
//! homebrew tap this fork cannot write to, with secrets it does not hold, plus
//! a release drafter, a label sync, an hourly stale bot and a daily bounty
//! job. `stale.yml` and `bounty.yml` trigger on schedules and on issue events
//! rather than on a branch, so unlike the rest they were not held back by the
//! `branches: [main]` filter. With Actions enabled they would have acted on
//! this fork's own issues and pull requests on a cron.
//!
//! So `.github/workflows/` is now fork-owned and hand-written, and holds one
//! minimal build-and-test workflow. These tests assert that, rather than
//! regenerate anything.
//!
//! The generators themselves are untouched in `forge_ci::workflows`, so if
//! upstream changes them this file is the only conflict, and re-applying the
//! patch means deleting the reintroduced `generate_*` calls again.
//!
//! To restore upstream behaviour, put back the `workflow::generate_*()` calls.

use std::path::PathBuf;

fn workflows_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../.github/workflows")
}

fn read_ci_workflow() -> String {
    let ci = workflows_dir().join("ci.yml");
    std::fs::read_to_string(&ci).unwrap_or_else(|e| panic!("{} is missing: {e}", ci.display()))
}

/// The fork's single hand-written workflow must exist and must not have been
/// replaced by a generated one.
#[test]
fn fork_owns_workflows() {
    let actual = read_ci_workflow();

    assert!(
        actual.contains("NOT GENERATED"),
        "ci.yml lost its fork-owned header -- something regenerated it. See \
         the module comment in this file."
    );
    assert!(
        !actual.contains("gh-workflow-gen"),
        "ci.yml was overwritten by the upstream generator"
    );
}

/// The upstream release and bot workflows must stay deleted. Each one either
/// targets repositories this fork cannot write to, or runs on a schedule that
/// would act on this fork's own issues and pull requests.
#[test]
fn upstream_only_workflows_stay_removed() {
    let dir = workflows_dir();
    let expected: Vec<PathBuf> = Vec::new();
    let actual: Vec<PathBuf> = [
        "autofix.yml",
        "bounty.yml",
        "labels.yml",
        "release-drafter.yml",
        "release.yml",
        "stale.yml",
    ]
    .iter()
    .map(|name| dir.join(name))
    .filter(|path| path.exists())
    .collect();

    assert_eq!(
        actual, expected,
        "upstream-only workflows are back; see the module comment in this file"
    );
}

/// CI must never invoke the Justfile. The Justfile is the LOCAL developer
/// interface and assumes GNU Bash 5.3+, mise-pinned tools and a warm cargo
/// cache. Operator rule, and easy to regress by pasting in a local command.
#[test]
fn ci_does_not_call_just() {
    let body = read_ci_workflow();

    let expected: Vec<String> = Vec::new();
    let actual: Vec<String> = body
        .lines()
        .enumerate()
        // Strip comments first: this file's own header explains the rule and
        // would otherwise trip the check it documents.
        .filter(|(_, line)| line.split('#').next().unwrap_or("").contains("just "))
        .map(|(i, line)| format!("{}: {}", i + 1, line.trim()))
        .collect();

    assert_eq!(actual, expected, "ci.yml invokes `just`");
}
