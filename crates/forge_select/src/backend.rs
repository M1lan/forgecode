//! Pluggable selector backend used to route widget calls to a non-TTY
//! frontend (e.g. the JSON line protocol).
//!
//! The TTY (`crossterm`) and comint (line-prompt) paths are inlined in
//! the four widget modules. The JSON path needs more state — it has to
//! emit a structured `select` event, then block on a matching
//! `select_response` arriving on a separate stdin reader thread. That
//! state lives in `forge_main` (which owns the JSON frontend), so this
//! crate just defines the trait and a process-global install cell that
//! `forge_main` populates at startup.
//!
//! Widgets call [`selector_backend`] before falling back to comint
//! line-prompts. If a backend is installed and we are running under the
//! JSON frontend, the backend handles the round trip; otherwise the
//! widget proceeds with the existing line-prompt fallback.

use std::sync::{Arc, Mutex};

use anyhow::Result;

/// A frontend-specific selector implementation.
///
/// All four methods follow the same contract as their corresponding
/// widget builders' `prompt` methods:
/// - `Ok(Some(_))` on a user response
/// - `Ok(None)` on user cancellation, EOF, or an empty option list
/// - `Err(_)` only on transport-level failures (broken pipe, malformed protocol
///   message, IO error)
///
/// Implementations may block the calling thread for an arbitrary amount
/// of time while waiting for the user.
pub trait SelectorBackend: Send + Sync {
    /// Single-choice selector. Returns the chosen index in `options`.
    fn select(
        &self,
        prompt: &str,
        options: &[String],
        default: Option<&str>,
    ) -> Result<Option<usize>>;

    /// Multi-choice selector. Returns the chosen indices in `options`.
    /// `defaults` is a parallel boolean mask indicating pre-selected
    /// options (same length as `options`); empty for "none preselected".
    fn multi(
        &self,
        prompt: &str,
        options: &[String],
        defaults: &[bool],
    ) -> Result<Option<Vec<usize>>>;

    /// Free-text input. Returns the entered string. `allow_empty`
    /// controls whether an empty-after-trimming response is accepted or
    /// re-prompts.
    fn input(
        &self,
        prompt: &str,
        default: Option<&str>,
        allow_empty: bool,
    ) -> Result<Option<String>>;

    /// Yes/no confirmation. `default` is used when the user provides no
    /// response.
    fn confirm(&self, prompt: &str, default: Option<bool>) -> Result<Option<bool>>;
}

/// Process-global installed backend. `None` means no override; widgets
/// fall through to their default code paths.
static BACKEND: Mutex<Option<Arc<dyn SelectorBackend>>> = Mutex::new(None);

/// Installs `backend` as the process-wide selector. Replaces any
/// previously installed backend. Typically called once at startup.
pub fn install_selector_backend(backend: Arc<dyn SelectorBackend>) {
    *BACKEND.lock().unwrap_or_else(|e| e.into_inner()) = Some(backend);
}

/// Removes any installed selector backend. Tests and shutdown paths use
/// this to keep state from leaking across runs.
pub fn clear_selector_backend() {
    *BACKEND.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

/// Returns the currently installed backend if any.
pub fn selector_backend() -> Option<Arc<dyn SelectorBackend>> {
    BACKEND.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use pretty_assertions::assert_eq;

    use super::*;

    /// Minimal in-memory backend used to assert install / dispatch
    /// semantics. Each call records its arguments and returns a
    /// pre-canned response.
    struct StubBackend {
        calls: Mutex<Vec<String>>,
        select_response: Option<usize>,
    }

    impl StubBackend {
        fn new(select_response: Option<usize>) -> Arc<Self> {
            Arc::new(Self { calls: Mutex::new(Vec::new()), select_response })
        }
    }

    impl SelectorBackend for StubBackend {
        fn select(
            &self,
            prompt: &str,
            options: &[String],
            _default: Option<&str>,
        ) -> Result<Option<usize>> {
            self.calls
                .lock()
                .unwrap()
                .push(format!("select:{prompt}:{}", options.len()));
            Ok(self.select_response)
        }

        fn multi(
            &self,
            _prompt: &str,
            _options: &[String],
            _defaults: &[bool],
        ) -> Result<Option<Vec<usize>>> {
            Ok(None)
        }

        fn input(
            &self,
            _prompt: &str,
            _default: Option<&str>,
            _allow_empty: bool,
        ) -> Result<Option<String>> {
            Ok(None)
        }

        fn confirm(&self, _prompt: &str, _default: Option<bool>) -> Result<Option<bool>> {
            Ok(None)
        }
    }

    /// Serialises tests that touch the global backend cell.
    fn lock_backend() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: Mutex<()> = Mutex::new(());
        LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn test_no_backend_installed_returns_none() {
        let _guard = lock_backend();
        clear_selector_backend();

        let actual = selector_backend().is_none();
        let expected = true;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_install_then_get_returns_same_backend() {
        let _guard = lock_backend();
        clear_selector_backend();

        let stub = StubBackend::new(Some(1));
        install_selector_backend(stub.clone());

        let fetched = selector_backend().expect("backend should be installed");
        let actual = Arc::ptr_eq(&fetched, &(stub as Arc<dyn SelectorBackend>));
        let expected = true;
        assert_eq!(actual, expected);

        clear_selector_backend();
    }

    #[test]
    fn test_clear_removes_backend() {
        let _guard = lock_backend();
        let stub = StubBackend::new(None);
        install_selector_backend(stub);
        clear_selector_backend();

        let actual = selector_backend().is_none();
        let expected = true;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_dispatch_to_backend_records_call() {
        let _guard = lock_backend();
        clear_selector_backend();

        let stub = StubBackend::new(Some(2));
        install_selector_backend(stub.clone());

        let backend = selector_backend().unwrap();
        let actual = backend
            .select("Pick", &["a".into(), "b".into(), "c".into()], None)
            .unwrap();
        let expected = Some(2);
        assert_eq!(actual, expected);

        let calls = stub.calls.lock().unwrap().clone();
        assert_eq!(calls, vec!["select:Pick:3".to_string()]);

        clear_selector_backend();
    }
}
