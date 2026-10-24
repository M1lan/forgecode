//! Herdr agent-state self-reporting integration.
//!
//! Reports Forge's lifecycle state to a running Herdr terminal multiplexer
//! over its Unix-socket JSON-RPC so Herdr can display and manage Forge as a
//! first-class agent (see `herdr agent list`).
//!
//! Herdr's native detection covers claude and codex only. Forge integrates via
//! Herdr's self-report protocol: the agent opens the socket announced by
//! `HERDR_SOCKET_PATH` (injected by Herdr into every pane it hosts) and sends
//! `pane.report_agent` / `pane.release_agent` requests itself. Everything is
//! best-effort: if the env vars are absent (not running under Herdr) or the
//! socket is gone (Herdr was killed), reporting silently disables.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU64, Ordering};

/// JSON-RPC method names from Herdr's schema.
const METHOD_REPORT: &str = "pane.report_agent";
const METHOD_RELEASE: &str = "pane.release_agent";

/// Monotonic counter for JSON-RPC id / seq ordering.
static SEQ: AtomicU64 = AtomicU64::new(0);

/// Best-effort JSON-RPC notification over the Herdr Unix socket.
///
/// Sends the given method as a single NDJSON line. Never returns an error:
/// failures (missing env vars, socket absent/refused/timeout) are logged at
/// debug and swallowed — state reporting must never break the chat loop.
fn herdr_notify(
    method: &str,
    state: Option<&str>,
    message: Option<&str>,
    resume: Option<Vec<String>>,
    sync: bool,
) {
    let Ok(pane) = std::env::var("HERDR_PANE_ID") else {
        return;
    };
    let Ok(socket) = std::env::var("HERDR_SOCKET_PATH") else {
        return;
    };
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);

    let request = serde_json::json!({
        "id": format!("forge:{method}:{seq}"),
        "method": method,
        "params": {
            "pane_id": pane,
            "source": "forge:forgecode",
            "agent": "forge",
            "seq": seq,
            "state": state,
            "message": message,
            "resume_argv": resume,
        },
    });
    let mut body = match serde_json::to_string(&request) {
        Ok(body) => body,
        Err(err) => {
            tracing::debug!(error = ?err, "herdr: serialize request failed");
            return;
        }
    };
    body.push('\n');

    // Serialize on a detached thread — tiny payload, but the 1s socket
    // timeout must never stall the event loop. `release` runs synchronously
    // instead: it is the last thing before process exit, and a detached
    // thread could be killed before its socket write lands.
    let send = move || {
        let stream = UnixStream::connect(&socket).and_then(|stream| {
            stream.set_write_timeout(Some(std::time::Duration::from_secs(1)))?;
            stream.set_read_timeout(Some(std::time::Duration::from_secs(1)))?;
            Ok(stream)
        });
        let mut stream = match stream {
            Ok(stream) => stream,
            Err(err) => {
                tracing::debug!(error = ?err, "herdr: connect failed");
                return;
            }
        };
        if stream.write_all(body.as_bytes()).is_err() || stream.flush().is_err() {
            tracing::debug!("herdr: socket write failed");
            return;
        }
        // Herdr replies with a JSON-RPC response; drain it so the connection
        // isn't left lingering until the peer closes.
        let mut buf = [0u8; 4096];
        let _ = Read::read(&mut stream, &mut buf);
    };
    if sync {
        send();
    } else {
        std::thread::spawn(send);
    }
}

/// Report agent lifecycle state to Herdr.
pub fn report(state: &str, message: Option<&str>) {
    herdr_notify(METHOD_REPORT, Some(state), message, None, false);
}

/// Report with resume argv (used at session start). `resume` is the command
/// Herdr should run to re-attach this agent session after a Herdr restart.
pub fn report_with_resume(state: &str, message: Option<&str>, resume: Vec<String>) {
    herdr_notify(METHOD_REPORT, Some(state), message, Some(resume), false);
}

/// Announce Forge as the pane's agent at session start.
pub fn announce() {
    report_with_resume("idle", None, vec!["forge".into()]);
}

/// Tell Herdr this pane's agent is gone (process exiting).
pub fn release() {
    herdr_notify(METHOD_RELEASE, None, None, None, true);
}

/// Reports `working` on creation and `idle` on drop (all return paths).
pub struct WorkingGuard;

impl WorkingGuard {
    pub fn new() -> Self {
        herdr_notify(METHOD_REPORT, Some("working"), None, None, false);
        Self
    }
}

impl Default for WorkingGuard {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for WorkingGuard {
    fn drop(&mut self) {
        herdr_notify(METHOD_REPORT, Some("idle"), None, None, false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_report_no_env_no_crash() {
        // Must be a no-op (not panic) when Herdr env vars are absent.
        report("idle", None);
        release();
    }
}
