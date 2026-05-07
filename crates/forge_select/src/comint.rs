//! Line-prompt fallbacks used when the host terminal cannot drive the
//! crossterm-based picker UI (Emacs `comint-mode`, plain `TERM=dumb`,
//! piped invocations).
//!
//! Detection runs entirely off environment variables so this crate can stay
//! free of the `forge_main` dependency. The TTY frontend in `forge_main`
//! sets `FORGE_FRONTEND=comint` early in `main`; this module also honours
//! `INSIDE_EMACS` (when it contains `comint`) and `TERM=dumb` directly.

use std::io::{self, BufRead, Write as _};

use anyhow::Result;

/// Returns `true` when the current process is running under a dumb-terminal
/// frontend that cannot accept crossterm raw-mode input.
///
/// Signal sources, in order of authority:
/// - `FORGE_FRONTEND=comint` or `FORGE_FRONTEND=json` — set by
///   `forge_main::main` after CLI / env resolution. This is the canonical
///   signal. Both dumb frontends route selectors through the line-prompt
///   fallbacks below; the JSON frontend additionally emits a `select`
///   event upstream (handled in `forge_main::frontend`), but the actual
///   user response still arrives as a plain stdin line in the current
///   wire format.
/// - `INSIDE_EMACS` containing the substring `comint` — set by Emacs
///   `make-comint-in-buffer` and friends.
/// - `TERM=dumb` — generic dumb-terminal escape hatch.
pub fn is_comint() -> bool {
    if let Ok(value) = std::env::var("FORGE_FRONTEND")
        && (value == "comint" || value == "json")
    {
        return true;
    }
    if let Ok(value) = std::env::var("INSIDE_EMACS")
        && value.contains("comint")
    {
        return true;
    }
    if let Ok(value) = std::env::var("TERM")
        && value == "dumb"
    {
        return true;
    }
    false
}

/// Returns `true` when the active frontend is the structured JSON line
/// protocol (`FORGE_FRONTEND=json`).
///
/// Used by selector adapters that want to additionally announce a
/// `select` event on the JSON wire before prompting.
pub fn is_json() -> bool {
    matches!(std::env::var("FORGE_FRONTEND").as_deref(), Ok("json"))
}

/// Numbered line-prompt fallback for a single-choice selector.
///
/// Prints a header followed by a numbered list of `display` strings, then
/// reads one line from stdin. Accepted responses:
/// - a 1-based numeric index (e.g. `2`)
/// - the literal value of one of the entries (case-insensitive match)
/// - empty line / EOF / `q` / `quit` -> `Ok(None)`
///
/// Re-prompts on invalid input. Designed for low-frequency, low-stakes
/// selectors (e.g. provider picker, confirm-with-options) where the
/// crossterm picker is unavailable.
pub fn prompt_select_line(
    message: &str,
    options: &[String],
) -> Result<Option<usize>> {
    if options.is_empty() {
        return Ok(None);
    }

    println!("{message}");
    for (index, display) in options.iter().enumerate() {
        println!("  {}) {}", index + 1, display);
    }

    loop {
        print!("Choose [1-{}]: ", options.len());
        io::stdout().flush().ok();

        let mut line = String::new();
        let stdin = io::stdin();
        let bytes = stdin.lock().read_line(&mut line)?;

        // EOF: caller cancelled.
        if bytes == 0 {
            return Ok(None);
        }

        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("q") || trimmed.eq_ignore_ascii_case("quit") {
            return Ok(None);
        }

        // Numeric index (1-based).
        if let Ok(n) = trimmed.parse::<usize>()
            && n >= 1
            && n <= options.len()
        {
            return Ok(Some(n - 1));
        }

        // Exact / case-insensitive label match.
        if let Some(index) = options
            .iter()
            .position(|o| o.eq_ignore_ascii_case(trimmed))
        {
            return Ok(Some(index));
        }

        println!("Invalid choice: {trimmed:?}. Enter a number 1-{}, the option text, or 'q' to cancel.", options.len());
    }
}

/// Plain-text input fallback. Reads one line from stdin. Returns `Ok(None)`
/// on EOF or when `allow_empty` is `false` and the user cancels with an
/// empty line + Ctrl+D.
pub fn prompt_input_line(
    message: &str,
    default: Option<&str>,
    allow_empty: bool,
) -> Result<Option<String>> {
    let suffix = match default {
        Some(d) if !d.is_empty() => format!(" [{d}]"),
        _ => String::new(),
    };

    loop {
        print!("{message}{suffix}: ");
        io::stdout().flush().ok();

        let mut line = String::new();
        let stdin = io::stdin();
        let bytes = stdin.lock().read_line(&mut line)?;
        if bytes == 0 {
            return Ok(None);
        }

        let trimmed = line.trim().to_string();

        if trimmed.is_empty() {
            if let Some(d) = default {
                return Ok(Some(d.to_string()));
            }
            if allow_empty {
                return Ok(Some(String::new()));
            }
            // Re-prompt rather than cancelling on a single empty line —
            // matches the rustyline-based fallback's behaviour.
            continue;
        }

        return Ok(Some(trimmed));
    }
}

/// Plain-text yes/no fallback. Accepts `y`/`yes`/`n`/`no` (case-insensitive).
/// Empty line uses `default`; EOF cancels.
pub fn prompt_confirm_line(message: &str, default: Option<bool>) -> Result<Option<bool>> {
    let hint = match default {
        Some(true) => "Y/n",
        Some(false) => "y/N",
        None => "y/n",
    };

    loop {
        print!("{message} [{hint}]: ");
        io::stdout().flush().ok();

        let mut line = String::new();
        let stdin = io::stdin();
        let bytes = stdin.lock().read_line(&mut line)?;
        if bytes == 0 {
            return Ok(None);
        }

        let trimmed = line.trim().to_lowercase();
        if trimmed.is_empty() {
            if let Some(d) = default {
                return Ok(Some(d));
            }
            continue;
        }

        match trimmed.as_str() {
            "y" | "yes" => return Ok(Some(true)),
            "n" | "no" => return Ok(Some(false)),
            _ => continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    /// Helper: clear all comint-related env vars for the duration of the
    /// returned guard. Restores on drop.
    ///
    /// SAFETY: `set_var`/`remove_var` are `unsafe` on edition 2024. These
    /// tests touch process env. Cargo's test harness runs tests in
    /// parallel by default, which would race; we therefore serialise via
    /// a global mutex held for the lifetime of the guard.
    struct EnvGuard {
        inside: Option<String>,
        term: Option<String>,
        frontend: Option<String>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl EnvGuard {
        fn new() -> Self {
            // Single shared mutex so env-mutating tests serialise.
            static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
            let lock = LOCK.lock().unwrap_or_else(|e| e.into_inner());

            let inside = std::env::var("INSIDE_EMACS").ok();
            let term = std::env::var("TERM").ok();
            let frontend = std::env::var("FORGE_FRONTEND").ok();

            unsafe {
                std::env::remove_var("INSIDE_EMACS");
                std::env::remove_var("TERM");
                std::env::remove_var("FORGE_FRONTEND");
            }

            Self { inside, term, frontend, _lock: lock }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            unsafe {
                match &self.inside {
                    Some(v) => std::env::set_var("INSIDE_EMACS", v),
                    None => std::env::remove_var("INSIDE_EMACS"),
                }
                match &self.term {
                    Some(v) => std::env::set_var("TERM", v),
                    None => std::env::remove_var("TERM"),
                }
                match &self.frontend {
                    Some(v) => std::env::set_var("FORGE_FRONTEND", v),
                    None => std::env::remove_var("FORGE_FRONTEND"),
                }
            }
        }
    }

    #[test]
    fn test_is_comint_false_with_clean_env() {
        let _guard = EnvGuard::new();
        let actual = is_comint();
        let expected = false;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_is_comint_true_with_forge_frontend_set() {
        let _guard = EnvGuard::new();
        unsafe {
            std::env::set_var("FORGE_FRONTEND", "comint");
        }
        let actual = is_comint();
        let expected = true;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_is_comint_true_with_inside_emacs_comint() {
        let _guard = EnvGuard::new();
        unsafe {
            std::env::set_var("INSIDE_EMACS", "29.1,comint");
        }
        let actual = is_comint();
        let expected = true;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_is_comint_false_with_inside_emacs_vterm() {
        let _guard = EnvGuard::new();
        unsafe {
            std::env::set_var("INSIDE_EMACS", "29.1,vterm");
        }
        let actual = is_comint();
        let expected = false;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_is_comint_true_with_term_dumb() {
        let _guard = EnvGuard::new();
        unsafe {
            std::env::set_var("TERM", "dumb");
        }
        let actual = is_comint();
        let expected = true;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_is_comint_false_with_term_xterm() {
        let _guard = EnvGuard::new();
        unsafe {
            std::env::set_var("TERM", "xterm-256color");
        }
        let actual = is_comint();
        let expected = false;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_is_comint_true_with_forge_frontend_json() {
        // The JSON frontend is also a dumb-terminal-class frontend that
        // must use line-prompt fallbacks, since it cannot drive crossterm
        // raw mode.
        let _guard = EnvGuard::new();
        unsafe {
            std::env::set_var("FORGE_FRONTEND", "json");
        }
        let actual = is_comint();
        let expected = true;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_is_json_true_only_for_json_frontend() {
        let _guard = EnvGuard::new();
        unsafe {
            std::env::set_var("FORGE_FRONTEND", "json");
        }
        assert_eq!(is_json(), true);
    }

    #[test]
    fn test_is_json_false_for_comint_frontend() {
        let _guard = EnvGuard::new();
        unsafe {
            std::env::set_var("FORGE_FRONTEND", "comint");
        }
        assert_eq!(is_json(), false);
    }

    #[test]
    fn test_is_json_false_when_unset() {
        let _guard = EnvGuard::new();
        assert_eq!(is_json(), false);
    }
}
