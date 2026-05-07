//! `JsonFrontend` orchestrator: high-level event-emit API on top of the
//! [`JsonConsoleWriter`] adapter.
//!
//! The UI lifecycle calls into this struct at well-defined points (init,
//! turn start/end, tool call/result, status updates, errors, selectors)
//! so the JSON wire stays self-consistent without scattering
//! `serde_json::to_string` calls across the codebase.
//!
//! `Arc<JsonFrontend>` is cheap to clone — internally everything is held
//! behind a single `Mutex` inside [`JsonConsoleWriter`], so concurrent
//! emitters never produce interleaved JSON lines.
//!
//! Most of the `emit_*` API is currently exercised only by unit tests;
//! the wiring into [`crate::ui::UI`] lifecycle methods (`run_inner`,
//! `on_chat`, `handle_chat_response`) lands in the same series of
//! commits. The module-level `#[allow(dead_code)]` keeps the lib build
//! quiet until that wiring catches up.
#![allow(dead_code)]

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;

use super::console_writer::JsonConsoleWriter;
use super::protocol::{PROTOCOL_VERSION, ServerEvent, TurnId};

/// Coordinates JSON wire output for `--frontend=json`.
///
/// Created once in [`crate::ui::UI::init`] when the active frontend is
/// JSON and is [`None`] for every other frontend. The UI thread calls
/// the typed `emit_*` methods at the right points; everything else
/// remains framework-agnostic.
pub struct JsonFrontend {
    writer: Arc<JsonConsoleWriter>,
    /// Monotonic counter for server-issued turn ids ("t1", "t2", …).
    next_turn: AtomicU64,
    /// Monotonic counter for server-issued select ids ("sel-1", "sel-2", …).
    next_select: AtomicU64,
}

impl JsonFrontend {
    /// Creates a `JsonFrontend` writing through the supplied
    /// `Arc<JsonConsoleWriter>`. Sharing the writer (via `Arc`) lets the
    /// same instance be installed as the process-wide
    /// [`forge_domain::install_redirect`] sink so `chunk` events flow
    /// through the same serialised channel as `turn_*` / `tool_*` /
    /// `usage` / `status` events.
    pub fn new(writer: Arc<JsonConsoleWriter>) -> Self {
        Self {
            writer,
            next_turn: AtomicU64::new(0),
            next_select: AtomicU64::new(0),
        }
    }

    /// Convenience: builds a frontend that writes directly to stdout.
    pub fn stdout() -> Self {
        Self::new(Arc::new(JsonConsoleWriter::new(Box::new(io::stdout()))))
    }

    /// Returns a clone of the underlying [`JsonConsoleWriter`] handle.
    /// Used by [`crate::ui::UI::init`] to register the same writer as
    /// the process-wide [`forge_domain::install_redirect`] sink.
    pub fn writer(&self) -> Arc<JsonConsoleWriter> {
        self.writer.clone()
    }

    /// Allocates the next server-issued turn id.
    pub fn next_turn_id(&self) -> TurnId {
        let n = self.next_turn.fetch_add(1, Ordering::Relaxed) + 1;
        format!("t{n}")
    }

    /// Allocates the next server-issued select id.
    #[allow(dead_code)] // Wired in the selector adapter.
    pub fn next_select_id(&self) -> String {
        let n = self.next_select.fetch_add(1, Ordering::Relaxed) + 1;
        format!("sel-{n}")
    }

    /// Emits a [`ServerEvent::Ready`] event. Should be called exactly once
    /// after API/conversation init, before any other server event.
    pub fn emit_ready(
        &self,
        conversation_id: impl Into<String>,
        agent: impl Into<String>,
        model: impl Into<String>,
    ) -> io::Result<()> {
        self.writer.emit(&ServerEvent::Ready {
            v: PROTOCOL_VERSION,
            conversation_id: conversation_id.into(),
            agent: agent.into(),
            model: model.into(),
        })
    }

    /// Marks the start of a turn. Returns the allocated [`TurnId`] so the
    /// caller can tag chunks/tool events with it.
    pub fn emit_turn_start(&self) -> io::Result<TurnId> {
        let turn_id = self.next_turn_id();
        self.writer.set_turn(Some(turn_id.clone()));
        self.writer.emit(&ServerEvent::TurnStart {
            v: PROTOCOL_VERSION,
            turn_id: turn_id.clone(),
        })?;
        Ok(turn_id)
    }

    /// Marks the end of a turn. Clears the active turn tag on the writer
    /// so any stray subsequent writes raise an error event rather than
    /// being silently mis-tagged.
    pub fn emit_turn_end(&self, turn_id: &str) -> io::Result<()> {
        self.writer.emit(&ServerEvent::TurnEnd {
            v: PROTOCOL_VERSION,
            turn_id: turn_id.to_string(),
        })?;
        self.writer.set_turn(None);
        Ok(())
    }

    /// Emits a `status { level: "info" | "warn" | "error", text }` event.
    /// Used by the spinner and out-of-band status updates.
    pub fn emit_status(&self, level: &str, text: impl Into<String>) -> io::Result<()> {
        self.writer.emit(&ServerEvent::Status {
            v: PROTOCOL_VERSION,
            level: level.to_string(),
            text: text.into(),
        })
    }

    /// Emits an `error` event with no associated request id. Use
    /// [`Self::emit_error_for`] when an error is tied to a specific
    /// client request.
    pub fn emit_error(&self, text: impl Into<String>) -> io::Result<()> {
        self.writer.emit(&ServerEvent::error(text.into()))
    }

    /// Emits an `error` event tied to a specific client request id.
    #[allow(dead_code)] // Wired when client-request error paths land.
    pub fn emit_error_for(
        &self,
        id: impl Into<String>,
        text: impl Into<String>,
    ) -> io::Result<()> {
        self.writer.emit(&ServerEvent::error_for(id, text))
    }

    /// Emits a `tool_call` event. Pair with [`Self::emit_tool_result`]
    /// using the same `tool_id`.
    pub fn emit_tool_call(
        &self,
        turn_id: &str,
        tool_id: impl Into<String>,
        name: impl Into<String>,
        args: Value,
    ) -> io::Result<()> {
        self.writer.emit(&ServerEvent::ToolCall {
            v: PROTOCOL_VERSION,
            turn_id: turn_id.to_string(),
            tool_id: tool_id.into(),
            name: name.into(),
            args,
        })
    }

    /// Emits a `tool_result` event closing the loop on a previous
    /// `tool_call` of the same `tool_id`.
    pub fn emit_tool_result(
        &self,
        turn_id: &str,
        tool_id: impl Into<String>,
        ok: bool,
        summary: impl Into<String>,
    ) -> io::Result<()> {
        self.writer.emit(&ServerEvent::ToolResult {
            v: PROTOCOL_VERSION,
            turn_id: turn_id.to_string(),
            tool_id: tool_id.into(),
            ok,
            summary: summary.into(),
        })
    }

    /// Emits a `usage` event with token counts and accumulated cost.
    #[allow(dead_code)] // Wired when usage emission lands in run_inner.
    pub fn emit_usage(
        &self,
        turn_id: &str,
        input_tokens: u64,
        output_tokens: u64,
        cost: f64,
    ) -> io::Result<()> {
        self.writer.emit(&ServerEvent::Usage {
            v: PROTOCOL_VERSION,
            turn_id: turn_id.to_string(),
            input_tokens,
            output_tokens,
            cost,
        })
    }

    /// Emits a `select` prompt event. Returns the allocated `sel_id` so
    /// the caller can later route the matching `select_response` event.
    #[allow(dead_code)] // Wired in the selector adapter.
    pub fn emit_select(
        &self,
        prompt: impl Into<String>,
        options: Vec<String>,
        multi: bool,
        default: impl Into<String>,
    ) -> io::Result<String> {
        let sel_id = self.next_select_id();
        self.writer.emit(&ServerEvent::Select {
            v: PROTOCOL_VERSION,
            sel_id: sel_id.clone(),
            prompt: prompt.into(),
            options,
            multi,
            default: default.into(),
        })?;
        Ok(sel_id)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use pretty_assertions::assert_eq;
    use serde_json::Value;
    use serde_json::json;

    use super::*;

    /// Test harness that captures every byte written through a frontend
    /// and exposes the captured NDJSON lines as parsed `serde_json::Value`s.
    struct CapturedFrontend {
        frontend: JsonFrontend,
        captured: Arc<Mutex<Vec<u8>>>,
    }

    impl CapturedFrontend {
        fn new() -> Self {
            let captured = Arc::new(Mutex::new(Vec::<u8>::new()));
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
            let sink: Box<dyn io::Write + Send> = Box::new(SharedSink(captured.clone()));
            let writer = Arc::new(JsonConsoleWriter::new(sink));
            Self {
                frontend: JsonFrontend::new(writer),
                captured,
            }
        }

        fn lines(&self) -> Vec<Value> {
            let bytes = self.captured.lock().unwrap().clone();
            let text = String::from_utf8(bytes).expect("captured must be utf-8");
            text.lines()
                .filter(|l| !l.is_empty())
                .map(|l| serde_json::from_str::<Value>(l).expect("each line is one json object"))
                .collect()
        }
    }

    #[test]
    fn test_emit_ready_writes_one_ready_line() {
        let h = CapturedFrontend::new();
        h.frontend
            .emit_ready("conv-1", "forge", "claude-opus-4-7")
            .unwrap();

        let lines = h.lines();
        assert_eq!(lines.len(), 1);
        let expected = json!({
            "kind": "ready",
            "v": PROTOCOL_VERSION,
            "conversation_id": "conv-1",
            "agent": "forge",
            "model": "claude-opus-4-7"
        });
        assert_eq!(lines[0], expected);
    }

    #[test]
    fn test_emit_turn_start_allocates_monotonic_ids() {
        let h = CapturedFrontend::new();
        let actual = (
            h.frontend.emit_turn_start().unwrap(),
            h.frontend.emit_turn_start().unwrap(),
        );
        let expected = ("t1".to_string(), "t2".to_string());
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_turn_start_then_end_round_trip() {
        let h = CapturedFrontend::new();
        let turn_id = h.frontend.emit_turn_start().unwrap();
        h.frontend.emit_turn_end(&turn_id).unwrap();

        let lines = h.lines();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["kind"], "turn_start");
        assert_eq!(lines[0]["turn_id"], "t1");
        assert_eq!(lines[1]["kind"], "turn_end");
        assert_eq!(lines[1]["turn_id"], "t1");
    }

    #[test]
    fn test_emit_status_writes_level_and_text() {
        let h = CapturedFrontend::new();
        h.frontend.emit_status("info", "Thinking…").unwrap();

        let lines = h.lines();
        assert_eq!(lines.len(), 1);
        let expected = json!({
            "kind": "status",
            "v": PROTOCOL_VERSION,
            "level": "info",
            "text": "Thinking…"
        });
        assert_eq!(lines[0], expected);
    }

    #[test]
    fn test_emit_error_omits_id_when_none() {
        let h = CapturedFrontend::new();
        h.frontend.emit_error("session blew up").unwrap();

        let lines = h.lines();
        assert_eq!(lines[0]["kind"], "error");
        assert_eq!(lines[0].get("id"), None);
        assert_eq!(lines[0]["text"], "session blew up");
    }

    #[test]
    fn test_emit_error_for_includes_id() {
        let h = CapturedFrontend::new();
        h.frontend.emit_error_for("c1", "bad event").unwrap();

        let lines = h.lines();
        assert_eq!(lines[0]["id"], "c1");
        assert_eq!(lines[0]["text"], "bad event");
    }

    #[test]
    fn test_emit_tool_call_then_result_round_trip() {
        let h = CapturedFrontend::new();
        h.frontend
            .emit_tool_call("t1", "k1", "read", json!({"path": "src/lib.rs"}))
            .unwrap();
        h.frontend
            .emit_tool_result("t1", "k1", true, "100 lines")
            .unwrap();

        let lines = h.lines();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["kind"], "tool_call");
        assert_eq!(lines[0]["tool_id"], "k1");
        assert_eq!(lines[0]["name"], "read");
        assert_eq!(lines[0]["args"]["path"], "src/lib.rs");
        assert_eq!(lines[1]["kind"], "tool_result");
        assert_eq!(lines[1]["tool_id"], "k1");
        assert_eq!(lines[1]["ok"], true);
        assert_eq!(lines[1]["summary"], "100 lines");
    }

    #[test]
    fn test_emit_select_allocates_sel_ids() {
        let h = CapturedFrontend::new();
        let sel_a = h
            .frontend
            .emit_select(
                "Pick provider:",
                vec!["anthropic".into(), "openai".into()],
                false,
                "",
            )
            .unwrap();
        let sel_b = h
            .frontend
            .emit_select("Pick model:", vec!["a".into()], false, "")
            .unwrap();

        assert_eq!(sel_a, "sel-1");
        assert_eq!(sel_b, "sel-2");
    }

    #[test]
    fn test_emit_usage_round_trip() {
        let h = CapturedFrontend::new();
        h.frontend.emit_usage("t1", 1234, 567, 0.0125).unwrap();

        let lines = h.lines();
        let expected = json!({
            "kind": "usage",
            "v": PROTOCOL_VERSION,
            "turn_id": "t1",
            "input_tokens": 1234,
            "output_tokens": 567,
            "cost": 0.0125
        });
        assert_eq!(lines[0], expected);
    }
}
