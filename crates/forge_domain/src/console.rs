use std::io;
use std::sync::{Arc, OnceLock};

/// Trait for synchronized output writing.
/// Provides two output channels (primary and error) with flush support.
/// Implementors must ensure thread-safe writes.
pub trait ConsoleWriter: Send + Sync {
    /// Writes bytes to primary output.
    fn write(&self, buf: &[u8]) -> io::Result<usize>;
    /// Writes bytes to error output.
    fn write_err(&self, buf: &[u8]) -> io::Result<usize>;
    /// Flushes primary output.
    fn flush(&self) -> io::Result<()>;
    /// Flushes error output.
    fn flush_err(&self) -> io::Result<()>;
}

/// Process-wide redirect sink for stdout/stderr writes.
///
/// When the JSON frontend is active, the top of the application registers
/// a [`ConsoleWriter`] here that frames every byte as a structured event.
/// All implementations of [`ConsoleWriter`] in the infrastructure layer
/// consult this cell first, falling back to the local writer when nothing
/// is installed (every other frontend).
///
/// Set once at startup; subsequent `install_redirect` calls are no-ops to
/// keep the redirect deterministic for the duration of the process.
static REDIRECT: OnceLock<Arc<dyn ConsoleWriter>> = OnceLock::new();

/// Installs a process-wide [`ConsoleWriter`] that intercepts every stdout
/// write. Returns `Ok(())` on first install; `Err` if a sink is already
/// installed (the new sink is dropped).
pub fn install_redirect(writer: Arc<dyn ConsoleWriter>) -> Result<(), Arc<dyn ConsoleWriter>> {
    REDIRECT.set(writer)
}

/// Returns the installed redirect sink, if any.
pub fn redirect() -> Option<&'static Arc<dyn ConsoleWriter>> {
    REDIRECT.get()
}
