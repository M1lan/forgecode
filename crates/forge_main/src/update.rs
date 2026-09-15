use std::sync::Arc;

use colored::Colorize;
use forge_api::API;
use forge_config::{Update, UpdateFrequency};
use forge_select::ForgeWidget;
use forge_tracker::VERSION;
use update_informer::{Check, Version, registry};

/// Runs the official installation script to update Forge, failing silently.
/// When `auto_update` is true, exits immediately after a successful update
/// without prompting the user.
async fn execute_update_command(api: Arc<impl API>, auto_update: bool) {
    // Spawn a new task that won't block the main application
    let output = api
        .execute_shell_command_raw("curl -fsSL https://forgecode.dev/cli | sh")
        .await;

    match output {
        Err(err) => {
            // Send an event to the tracker on failure
            // We don't need to handle this result since we're failing silently
            let _ = send_update_failure_event(&format!("Auto update failed {err}")).await;
        }
        Ok(output) => {
            if output.success() {
                let should_exit = if auto_update {
                    true
                } else {
                    let answer = forge_select::ForgeWidget::confirm(
                        "You need to close forge to complete update. Do you want to close it now?",
                    )
                    .with_default(true)
                    .prompt();
                    answer.unwrap_or_default().unwrap_or_default()
                };
                if should_exit {
                    std::process::exit(0);
                }
            } else {
                let exit_output = match output.code() {
                    Some(code) => format!("Process exited with code: {code}"),
                    None => "Process exited without code".to_string(),
                };
                let _ =
                    send_update_failure_event(&format!("Auto update failed, {exit_output}",)).await;
            }
        }
    }
}

async fn confirm_update(version: Version) -> bool {
    let answer = ForgeWidget::confirm(format!(
        "Confirm upgrade from {} -> {} (latest)?",
        VERSION.to_string().bold().white(),
        version.to_string().bold().white()
    ))
    .with_default(true)
    .prompt();

    match answer {
        Ok(Some(result)) => result,
        Ok(None) => false, // User canceled
        Err(_) => false,   // Error occurred
    }
}

fn should_check_for_updates(frequency: &UpdateFrequency) -> bool {
    !matches!(frequency, UpdateFrequency::Never)
}

/// Returns true only for a published release version (`MAJOR.MINOR.PATCH`,
/// digits and dots only). Pre-release suffixes, `git describe` output and the
/// `0.1.0-dev` fallback from `build.rs` are local builds.
fn is_release_version(version: &str) -> bool {
    let mut parts = version.split('.');
    let numeric =
        |s: Option<&str>| s.is_some_and(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
    numeric(parts.next())
        && numeric(parts.next())
        && numeric(parts.next())
        && parts.next().is_none()
}

/// Checks if there is an update available
pub async fn on_update(api: Arc<impl API>, update: Option<&Update>) {
    let update = update.cloned().unwrap_or_default();
    let frequency = update.frequency.unwrap_or_default();

    if !should_check_for_updates(&frequency) {
        return;
    }

    let auto_update = update.auto_update.unwrap_or_default();

    // Skip the update check for development builds. A release build carries a
    // plain `MAJOR.MINOR.PATCH` version; anything else (`0.1.0-dev`, the
    // `git describe` form `2.13.21-104-gb0e3b5625`) is a local build. Semver
    // orders such pre-release strings below the release they are based on, so
    // without this guard the installer would run on every launch and replace a
    // locally built binary with the published release.
    if !is_release_version(VERSION) {
        return;
    }

    let informer = update_informer::new(registry::GitHub, "tailcallhq/forgecode", VERSION)
        .interval(frequency.into());

    if let Some(version) = informer.check_version().ok().flatten()
        && (auto_update || confirm_update(version).await)
    {
        execute_update_command(api, auto_update).await;
    }
}

/// Sends an event to the tracker when an update fails
async fn send_update_failure_event(error_msg: &str) -> anyhow::Result<()> {
    tracing::error!(error = error_msg, "Update failed");
    // Always return Ok since we want to fail silently
    Ok(())
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_should_skip_update_check_when_frequency_is_never() {
        let fixture = UpdateFrequency::Never;

        let actual = should_check_for_updates(&fixture);

        let expected = false;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_is_release_version_accepts_plain_release() {
        assert!(is_release_version("2.13.21"));
        assert!(is_release_version("0.1.0"));
    }

    #[test]
    fn test_is_release_version_rejects_local_builds() {
        assert!(!is_release_version("0.1.0-dev"));
        assert!(!is_release_version("2.13.21-104-gb0e3b5625"));
        assert!(!is_release_version("2.13.21-rc1"));
        assert!(!is_release_version("2.13"));
        assert!(!is_release_version("v2.13.21"));
    }
}
