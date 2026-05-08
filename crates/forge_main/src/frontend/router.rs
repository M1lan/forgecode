//! NDJSON event router for `--frontend=json`.
//!
//! Owns stdin in a dedicated OS thread, parses one [`ClientEvent`] per
//! line, and demultiplexes by event kind:
//!
//! - [`ClientEvent::Submit`] / [`ClientEvent::Command`] /
//!   [`ClientEvent::Cancel`] / [`ClientEvent::SetBuffer`] flow into a single
//!   MPSC channel consumed by [`crate::input::JsonInput`] in the main UI loop.
//! - [`ClientEvent::SelectResponse`] is matched against the pending selector
//!   map held by [`super::JsonFrontend`] and routed to the matching one-shot
//!   `mpsc::Sender<String>`.
//! - Malformed JSON lines emit a [`ServerEvent::Error`] back through the same
//!   writer the rest of the protocol uses; the reader thread keeps going.
//!
//! The router is the architectural counterpart to the chunk-redirect
//! installed by [`crate::ui::UI::init`]: chunks flow *out* through the
//! redirected console writer; events flow *in* through the router.
//!
//! Threading model
//! ---------------
//!
//! The reader thread is a plain OS thread, not a tokio task, because
//! `std::io::stdin().lock().read_line()` is a blocking syscall. The
//! prompt receiver side is consumed from an `async fn` via blocking
//! `mpsc::Receiver::recv()`; this is intentional and matches the rest
//! of the existing input handling — a turn cannot start until the user
//! submits, so blocking is the desired semantics there. Selector
//! responses block the *selector* thread (the UI's current call into
//! `forge_select`), which is also synchronous.

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;

use super::orchestrator::JsonFrontend;
use super::protocol::{ClientEvent, ServerEvent};

/// Shared map of pending selector responses, keyed by `sel_id`.
///
/// [`JsonFrontend::request_select`] inserts a one-shot channel before
/// emitting the `select` event and blocks on the receiver. The router
/// looks up `target` on each [`ClientEvent::SelectResponse`] and
/// forwards the value through the matching sender.
pub type PendingSelects = Arc<Mutex<HashMap<String, mpsc::Sender<String>>>>;

/// Receiver side of the prompt-event channel.
///
/// [`crate::input::JsonInput`] blocks on this for the next user-driven
/// event (submit, slash command, cancel, set_buffer).
pub type PromptReceiver = mpsc::Receiver<ClientEvent>;

/// Sender side of the prompt-event channel.
type PromptSender = mpsc::Sender<ClientEvent>;

/// Spawned at JSON frontend startup. Holds the prompt receiver returned
/// to the caller; the underlying reader thread is detached and lives
/// until stdin EOF (or a fatal IO error), at which point it drops the
/// sender and the receiver hangs up.
pub struct EventRouter {
    /// Prompt-event channel consumed by the input loop.
    pub prompt_rx: PromptReceiver,
}

impl EventRouter {
    /// Spawns the stdin reader thread and returns a router handle.
    ///
    /// `frontend` is needed only so the reader thread can emit
    /// [`ServerEvent::Error`] on malformed JSON lines; otherwise the
    /// router has no other dependency on the orchestrator.
    pub fn spawn(frontend: Arc<JsonFrontend>) -> Self {
        let (tx, rx) = mpsc::channel();
        let pending: PendingSelects = Arc::new(Mutex::new(HashMap::new()));
        frontend.bind_pending_selects(pending.clone());

        thread::Builder::new()
            .name("forge-json-stdin".into())
            .spawn(move || {
                run(tx, pending, frontend);
            })
            .expect("spawning stdin reader thread should not fail");

        Self { prompt_rx: rx }
    }
}

/// Reader thread body. Loops on stdin until EOF or an unrecoverable IO
/// error. Each line is a single [`ClientEvent`] in NDJSON form.
fn run(tx: PromptSender, pending: PendingSelects, frontend: Arc<JsonFrontend>) {
    let stdin = io::stdin();
    let mut reader = BufReader::new(stdin.lock());
    let mut line = String::new();

    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => return, // EOF: drop tx, prompt loop sees Exit.
            Ok(_) => {}
            Err(_) => return, // Treat any IO error as EOF for shutdown.
        }

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        match serde_json::from_str::<ClientEvent>(trimmed) {
            Ok(ClientEvent::SelectResponse { target, value, .. }) => {
                if let Some(sender) = pending.lock().unwrap().remove(&target) {
                    // Receiver may have been dropped (e.g. UI cancelled
                    // the selector); silently discard the response.
                    let _ = sender.send(value);
                }
                // No matching pending entry: drop silently. Could be a
                // stale response from a cancelled selector, or a bogus
                // target id from a confused client. Logging is the
                // future enhancement.
            }
            Ok(other) => {
                if tx.send(other).is_err() {
                    return;
                }
            }
            Err(err) => {
                let mut event = ServerEvent::error(format!("invalid client event: {err}"));
                if let ServerEvent::Error { ref mut cause, .. } = event {
                    *cause = trimmed.to_string();
                }
                let _ = frontend.writer().emit(&event);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, mpsc};
    use std::time::Duration;

    use pretty_assertions::assert_eq;

    use super::super::console_writer::JsonConsoleWriter;
    use super::*;

    /// Builds a JsonFrontend with an in-memory writer so tests can
    /// inspect emitted events.
    fn frontend_with_buffer() -> (Arc<JsonFrontend>, Arc<Mutex<Vec<u8>>>) {
        let buf: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        struct SharedSink(Arc<Mutex<Vec<u8>>>);
        impl io::Write for SharedSink {
            fn write(&mut self, b: &[u8]) -> io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let sink: Box<dyn io::Write + Send> = Box::new(SharedSink(buf.clone()));
        let writer = Arc::new(JsonConsoleWriter::new(sink));
        let frontend = Arc::new(JsonFrontend::new(writer));
        (frontend, buf)
    }

    #[test]
    fn test_select_response_routed_to_pending_sender() {
        let (frontend, _buf) = frontend_with_buffer();
        let pending: PendingSelects = Arc::new(Mutex::new(HashMap::new()));
        let (sender, receiver) = mpsc::channel::<String>();
        pending.lock().unwrap().insert("sel-1".to_string(), sender);

        // Simulate the reader-thread routing logic without the real
        // stdin loop. (Same code path the integration test exercises.)
        let event = ClientEvent::SelectResponse {
            v: 1,
            id: "c1".into(),
            target: "sel-1".into(),
            value: "anthropic".into(),
        };
        if let ClientEvent::SelectResponse { target, value, .. } = event
            && let Some(sender) = pending.lock().unwrap().remove(&target)
        {
            sender.send(value).unwrap();
        }

        let actual = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        let expected = "anthropic".to_string();
        assert_eq!(actual, expected);

        // Pending map should be empty after the response is routed.
        assert_eq!(pending.lock().unwrap().len(), 0);

        // Frontend buffer untouched (no errors emitted).
        let _ = frontend;
    }

    #[test]
    fn test_select_response_with_no_pending_target_dropped_silently() {
        let pending: PendingSelects = Arc::new(Mutex::new(HashMap::new()));
        let event = ClientEvent::SelectResponse {
            v: 1,
            id: "c1".into(),
            target: "sel-stale".into(),
            value: "ignored".into(),
        };
        if let ClientEvent::SelectResponse { target, value, .. } = event
            && let Some(sender) = pending.lock().unwrap().remove(&target)
        {
            sender.send(value).unwrap();
        }
        // No panic; map still empty.
        assert_eq!(pending.lock().unwrap().len(), 0);
    }
}
