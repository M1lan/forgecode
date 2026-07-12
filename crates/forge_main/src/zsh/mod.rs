//! ZSH shell integration.
//!
//! This module provides all ZSH-related functionality including:
//! - Plugin generation and installation
//! - Theme generation
//! - Shell diagnostics
//! - Right prompt (rprompt) display
//! - Prompt styling utilities

pub(crate) mod paste;
mod plugin;
mod rprompt;
mod style;

use clap::ValueEnum;

/// The shell flavor a shell-integration command targets.
///
/// Selects the embedded plugin/setup assets, the completion generator, and the
/// rc file that `setup_integration` rewrites. Defaults to [`ShellKind::Zsh`] to
/// preserve the historical `forge setup` / `forge doctor` behavior.
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq, ValueEnum)]
#[clap(rename_all = "lower")]
pub enum ShellKind {
    /// Z shell (default).
    #[default]
    Zsh,
    /// GNU Bash.
    Bash,
    /// Fish shell.
    Fish,
}

impl ShellKind {
    /// Returns the lowercase shell name used in user-facing messages.
    pub fn name(self) -> &'static str {
        match self {
            ShellKind::Zsh => "zsh",
            ShellKind::Bash => "bash",
            ShellKind::Fish => "fish",
        }
    }
}

/// Normalizes shell script content for cross-platform compatibility.
///
/// Strips carriage returns (`\r`) that appear when `include_str!` or
/// `include_dir!` embed files on Windows (where `git core.autocrlf=true`
/// converts LF to CRLF on checkout). Zsh cannot parse `\r` in scripts.
pub(crate) fn normalize_script(content: &str) -> String {
    content.replace("\r\n", "\n").replace('\r', "\n")
}

pub use plugin::{
    generate_plugin, generate_theme, run_doctor, run_keyboard, setup_integration,
};
pub use rprompt::ZshRPrompt;
