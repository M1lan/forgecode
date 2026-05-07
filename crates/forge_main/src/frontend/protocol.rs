//! NDJSON wire protocol for the `--frontend=json` driver mode.
//!
//! Each line on stdin (client → forge) and stdout (forge → client) is one
//! JSON object terminated by a single `\n`. The schema is identified by a
//! `v` field; only `v = 1` is accepted in this revision. The protocol is
//! versioned at the *event* level rather than the connection level so future
//! revisions can ship new event kinds without re-handshaking.
//!
//! # Stability
//!
//! The whole module is **unstable**. While the binary is in `v0` the protocol
//! is gated behind `--frontend=json --unstable` (see
//! [`crate::cli::Cli::unstable`]). When the protocol promotes to `v1`, the
//! constants below stay; new events are added under `v: 1` and breaking
//! changes are bumped to `v: 2`.
//!
//! # Forward compatibility
//!
//! - **Unknown `kind`** in either direction must produce an error event
//!   rather than a crash. Use [`ServerEvent::Error`] for the forward channel
//!   and reject the client event with a structured `error` event.
//! - **Unknown fields** in known events are tolerated (`#[serde(default)]`
//!   where applicable). New fields land non-breakingly.
//!
//! # Cross-channel separation
//!
//! - `tracing` log output stays on the side-channel log file (see
//!   `forge_tracker::init_tracing`). It must **not** leak to stdout in JSON
//!   mode.
//! - Errors from the forge process write to stderr as plain text only when
//!   the JSON dispatch loop itself is broken (e.g. malformed line). All
//!   recoverable errors must be reported as [`ServerEvent::Error`].

use serde::{Deserialize, Serialize};

/// Current protocol version. All events emitted by this build carry this
/// value in the `v` field. Clients must check this on receive to decide
/// compatibility.
pub const PROTOCOL_VERSION: u32 = 1;

/// Identifier for a single client request. The client picks any non-empty
/// string that is unique within its session; the server echoes it back on
/// any direct response (e.g. command results, errors caused by that
/// request). Server-initiated events (chunks, status, etc.) carry their own
/// `turn_id` / `sel_id` instead.
pub type RequestId = String;

/// Identifier for a single assistant turn. Server-issued, monotonic within
/// a session. Wraps incoming chunks, tool calls, reasoning, and usage so
/// the client can group them visually.
pub type TurnId = String;

/// Identifier for a single selector prompt. Server-issued. The client
/// answers by emitting a [`ClientEvent::SelectResponse`] carrying the same
/// id in `target`.
pub type SelectId = String;

/// One event written by the **client** (e.g. `forge.el`) to forge's stdin.
///
/// Round-trip note: deserialisation is lenient (`#[serde(deny_unknown_fields)]`
/// is **not** set) so new fields added by future clients do not break older
/// forge builds. Adding a new `kind` is a breaking change at the protocol
/// level and must bump [`PROTOCOL_VERSION`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ClientEvent {
    /// Submit a new user turn. `attachments` reserved for future file
    /// attachments — currently must be an empty array.
    Submit {
        /// Schema version (must equal [`PROTOCOL_VERSION`]).
        v: u32,
        /// Client-assigned request id, echoed in any direct response.
        id: RequestId,
        /// User message text (raw, may contain markdown).
        text: String,
        /// Reserved for future use — file paths or blobs to attach to the
        /// turn. Empty array in v1.
        #[serde(default)]
        attachments: Vec<String>,
    },

    /// Cancel the in-flight turn. `target` is the [`TurnId`] from
    /// [`ServerEvent::TurnStart`].
    Cancel {
        v: u32,
        id: RequestId,
        /// The turn to cancel.
        target: TurnId,
    },

    /// Answer a selector prompt that the server has sent.
    SelectResponse {
        v: u32,
        id: RequestId,
        /// The selector id from the originating [`ServerEvent::Select`].
        target: SelectId,
        /// The chosen value. For multi-select, comma-separate or send a
        /// JSON array as a string. Schema for v1 is "raw string the client
        /// returns to forge"; v2 may switch to `serde_json::Value`.
        value: String,
    },

    /// Pre-fill the next prompt's input buffer. Mirrors the existing
    /// [`crate::input::UserInput::set_buffer`] semantics for the TTY and
    /// comint frontends.
    SetBuffer {
        v: u32,
        id: RequestId,
        /// Text to insert into the next input prompt.
        text: String,
    },

    /// Run a built-in slash/colon command (e.g. `new`, `exit`, `model`).
    /// `name` is the bare command name without the `/` or `:` prefix.
    Command {
        v: u32,
        id: RequestId,
        /// Bare command name, e.g. `"exit"`, `"new"`, `"model"`.
        name: String,
        /// Optional positional arguments, joined by spaces by the server
        /// before being parsed by [`crate::model::ForgeCommandManager::parse`].
        #[serde(default)]
        args: Vec<String>,
    },
}

impl ClientEvent {
    /// Returns the protocol-version field of any client event variant.
    #[allow(dead_code)] // Wired in the upcoming JsonFrontend dispatcher.
    pub fn version(&self) -> u32 {
        match self {
            Self::Submit { v, .. }
            | Self::Cancel { v, .. }
            | Self::SelectResponse { v, .. }
            | Self::SetBuffer { v, .. }
            | Self::Command { v, .. } => *v,
        }
    }

    /// Returns the request id this event is tagged with.
    #[allow(dead_code)] // Wired in the upcoming JsonFrontend dispatcher.
    pub fn id(&self) -> &str {
        match self {
            Self::Submit { id, .. }
            | Self::Cancel { id, .. }
            | Self::SelectResponse { id, .. }
            | Self::SetBuffer { id, .. }
            | Self::Command { id, .. } => id,
        }
    }
}

/// One event written by the **server** (forge) to stdout.
///
/// Each variant carries the protocol version `v` independently so the wire
/// format is self-describing line-by-line. This makes log captures and
/// snapshot tests trivially diffable.
///
/// `Eq` is intentionally not derived: [`Self::Usage`] carries an `f64`
/// cost. Use [`PartialEq`] for comparisons; in tests prefer comparing the
/// serde JSON value rather than the struct directly when float
/// equality matters.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ServerEvent {
    /// Emitted exactly once after startup, before any other server event,
    /// once the API factory has built the conversation. Carries enough
    /// context for the client to seed its UI (mode-line, status bar).
    Ready {
        v: u32,
        /// Active conversation id (UUID). Stable for the lifetime of the
        /// process; switches on `command:new`.
        conversation_id: String,
        /// Active agent id (e.g. `"forge"`, `"muse"`, `"sage"`).
        agent: String,
        /// Active model id (e.g. `"claude-opus-4-7"`). May be empty if
        /// no model has been resolved yet (e.g. provider login pending).
        model: String,
    },

    /// Marks the start of an assistant turn. All `chunk`, `reasoning`,
    /// `tool_call`, `tool_result`, `status`, `usage` events between this
    /// and the matching [`ServerEvent::TurnEnd`] belong to this turn.
    TurnStart { v: u32, turn_id: TurnId },

    /// A streamed text chunk produced by the assistant. Stream is
    /// `"assistant"` for normal output and `"reasoning"` for reasoning
    /// (chain-of-thought) streams when the active model emits them.
    /// Clients should append to a per-turn-per-stream buffer.
    Chunk {
        v: u32,
        turn_id: TurnId,
        /// Channel name. `"assistant"` is the visible response; other
        /// channels (e.g. `"reasoning"`) are advisory.
        stream: String,
        /// Raw text chunk. May contain partial UTF-8 sequences across
        /// chunk boundaries (the wire format normalises them, but clients
        /// should still buffer before rendering markdown).
        text: String,
    },

    /// Reasoning trace text. Optional convenience event for clients that
    /// want to display chain-of-thought separately from the main response;
    /// equivalent to [`ServerEvent::Chunk`] with `stream: "reasoning"`.
    Reasoning {
        v: u32,
        turn_id: TurnId,
        text: String,
    },

    /// Tool invocation announced by the assistant. The result arrives
    /// later as [`ServerEvent::ToolResult`] sharing the same `tool_id`.
    ToolCall {
        v: u32,
        turn_id: TurnId,
        tool_id: String,
        name: String,
        /// Tool arguments as a JSON value so the client can render
        /// per-tool views (file paths as buttons, code blocks, etc.).
        args: serde_json::Value,
    },

    /// Result of a tool invocation. Pairs with the matching
    /// [`ServerEvent::ToolCall`] by `tool_id`.
    ToolResult {
        v: u32,
        turn_id: TurnId,
        tool_id: String,
        /// `true` if the tool succeeded. `false` indicates the tool
        /// returned an error which the assistant will see in its context.
        ok: bool,
        /// Short human-readable summary suitable for a one-line preview
        /// (e.g. `"42 lines"`, `"3 changed files"`).
        summary: String,
    },

    /// Selector prompt. Client must reply with
    /// [`ClientEvent::SelectResponse`] using the same `sel_id`.
    Select {
        v: u32,
        sel_id: SelectId,
        prompt: String,
        /// Available choices in display order.
        options: Vec<String>,
        /// `true` if multiple values are accepted; client should answer
        /// with a comma-separated list.
        #[serde(default)]
        multi: bool,
        /// Default value the user can confirm with empty input. Empty
        /// string when no default is set.
        #[serde(default)]
        default: String,
    },

    /// Out-of-band status / progress event. `level` is `"info"`,
    /// `"warn"`, or `"error"`. Replaces the spinner under JSON mode.
    Status {
        v: u32,
        level: String,
        text: String,
    },

    /// Token usage / cost accounting for the current turn. Emitted at
    /// turn end (and optionally on token-count changes during streaming
    /// — clients should treat the latest value as authoritative).
    Usage {
        v: u32,
        turn_id: TurnId,
        input_tokens: u64,
        output_tokens: u64,
        cost: f64,
    },

    /// Marks the end of an assistant turn. After this event, the next
    /// turn must start with a fresh [`ServerEvent::TurnStart`].
    TurnEnd { v: u32, turn_id: TurnId },

    /// Recoverable error tied either to a specific client request (echo
    /// `id`) or to the session at large (omit `id`).
    Error {
        v: u32,
        /// The client request id that caused this error, if applicable.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<RequestId>,
        text: String,
        /// Optional cause / debug detail (formatted Display chain). May
        /// be empty.
        #[serde(default)]
        cause: String,
    },
}

impl ServerEvent {
    /// Returns the protocol-version field of any server event variant.
    #[allow(dead_code)] // Wired in the upcoming JsonFrontend dispatcher.
    pub fn version(&self) -> u32 {
        match self {
            Self::Ready { v, .. }
            | Self::TurnStart { v, .. }
            | Self::Chunk { v, .. }
            | Self::Reasoning { v, .. }
            | Self::ToolCall { v, .. }
            | Self::ToolResult { v, .. }
            | Self::Select { v, .. }
            | Self::Status { v, .. }
            | Self::Usage { v, .. }
            | Self::TurnEnd { v, .. }
            | Self::Error { v, .. } => *v,
        }
    }

    /// Constructs a v1 [`Self::Status`] info event.
    ///
    /// Convenience helper for callers that don't want to spell out the
    /// version every time.
    #[allow(dead_code)] // Used once the streaming pipeline lands.
    pub fn info_status(text: impl Into<String>) -> Self {
        Self::Status {
            v: PROTOCOL_VERSION,
            level: "info".into(),
            text: text.into(),
        }
    }

    /// Constructs a v1 [`Self::Error`] event tied to a specific request id.
    #[allow(dead_code)] // Wired into per-request error responses.
    pub fn error_for(id: impl Into<RequestId>, text: impl Into<String>) -> Self {
        Self::Error {
            v: PROTOCOL_VERSION,
            id: Some(id.into()),
            text: text.into(),
            cause: String::new(),
        }
    }

    /// Constructs a v1 [`Self::Error`] event without a specific request id.
    pub fn error(text: impl Into<String>) -> Self {
        Self::Error {
            v: PROTOCOL_VERSION,
            id: None,
            text: text.into(),
            cause: String::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_protocol_version_is_v1() {
        let actual = PROTOCOL_VERSION;
        let expected = 1u32;
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_client_submit_round_trip() {
        let fixture = ClientEvent::Submit {
            v: 1,
            id: "c1".into(),
            text: "refactor foo to bar".into(),
            attachments: vec![],
        };
        let actual: ClientEvent = serde_json::from_str(&serde_json::to_string(&fixture).unwrap())
            .unwrap();
        assert_eq!(actual, fixture);
    }

    #[test]
    fn test_client_submit_serialises_with_kind_tag() {
        let fixture = ClientEvent::Submit {
            v: 1,
            id: "c1".into(),
            text: "hi".into(),
            attachments: vec![],
        };
        let actual = serde_json::to_value(&fixture).unwrap();
        let expected = serde_json::json!({
            "kind": "submit",
            "v": 1,
            "id": "c1",
            "text": "hi",
            "attachments": []
        });
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_client_submit_attachments_default_to_empty() {
        let fixture = r#"{"kind":"submit","v":1,"id":"c1","text":"hi"}"#;
        let actual: ClientEvent = serde_json::from_str(fixture).unwrap();
        let expected = ClientEvent::Submit {
            v: 1,
            id: "c1".into(),
            text: "hi".into(),
            attachments: vec![],
        };
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_client_cancel_round_trip() {
        let fixture = ClientEvent::Cancel {
            v: 1,
            id: "c2".into(),
            target: "t1".into(),
        };
        let actual: ClientEvent = serde_json::from_str(&serde_json::to_string(&fixture).unwrap())
            .unwrap();
        assert_eq!(actual, fixture);
    }

    #[test]
    fn test_client_select_response_round_trip() {
        let fixture = ClientEvent::SelectResponse {
            v: 1,
            id: "c3".into(),
            target: "sel-7".into(),
            value: "yes".into(),
        };
        let actual: ClientEvent = serde_json::from_str(&serde_json::to_string(&fixture).unwrap())
            .unwrap();
        assert_eq!(actual, fixture);
    }

    #[test]
    fn test_client_command_default_args() {
        let fixture = r#"{"kind":"command","v":1,"id":"c5","name":"new"}"#;
        let actual: ClientEvent = serde_json::from_str(fixture).unwrap();
        let expected = ClientEvent::Command {
            v: 1,
            id: "c5".into(),
            name: "new".into(),
            args: vec![],
        };
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_client_event_helpers() {
        let fixture = ClientEvent::Submit {
            v: 1,
            id: "c1".into(),
            text: "hi".into(),
            attachments: vec![],
        };
        assert_eq!(fixture.version(), 1);
        assert_eq!(fixture.id(), "c1");
    }

    #[test]
    fn test_client_unknown_kind_errors() {
        let fixture = r#"{"kind":"bogus","v":1,"id":"c1"}"#;
        let actual = serde_json::from_str::<ClientEvent>(fixture);
        assert!(actual.is_err(), "unknown kind must not deserialise");
    }

    #[test]
    fn test_server_ready_round_trip() {
        let fixture = ServerEvent::Ready {
            v: 1,
            conversation_id: "abcd-1234".into(),
            agent: "forge".into(),
            model: "claude-opus-4-7".into(),
        };
        let actual: ServerEvent = serde_json::from_str(&serde_json::to_string(&fixture).unwrap())
            .unwrap();
        assert_eq!(actual, fixture);
    }

    #[test]
    fn test_server_chunk_serialises_with_kind_tag() {
        let fixture = ServerEvent::Chunk {
            v: 1,
            turn_id: "t1".into(),
            stream: "assistant".into(),
            text: "Looking at ".into(),
        };
        let actual = serde_json::to_value(&fixture).unwrap();
        let expected = serde_json::json!({
            "kind": "chunk",
            "v": 1,
            "turn_id": "t1",
            "stream": "assistant",
            "text": "Looking at "
        });
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_server_tool_call_carries_args_as_json_value() {
        let fixture = ServerEvent::ToolCall {
            v: 1,
            turn_id: "t1".into(),
            tool_id: "k1".into(),
            name: "read".into(),
            args: serde_json::json!({"path": "foo.rs"}),
        };
        let actual: ServerEvent = serde_json::from_str(&serde_json::to_string(&fixture).unwrap())
            .unwrap();
        assert_eq!(actual, fixture);
    }

    #[test]
    fn test_server_select_default_fields() {
        let fixture = r#"{"kind":"select","v":1,"sel_id":"sel-7","prompt":"Apply?","options":["yes","no"]}"#;
        let actual: ServerEvent = serde_json::from_str(fixture).unwrap();
        let expected = ServerEvent::Select {
            v: 1,
            sel_id: "sel-7".into(),
            prompt: "Apply?".into(),
            options: vec!["yes".into(), "no".into()],
            multi: false,
            default: String::new(),
        };
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_server_error_omits_id_when_none() {
        let fixture = ServerEvent::error("oops");
        let actual = serde_json::to_value(&fixture).unwrap();
        let expected = serde_json::json!({
            "kind": "error",
            "v": 1,
            "text": "oops",
            "cause": ""
        });
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_server_error_for_includes_id() {
        let fixture = ServerEvent::error_for("c1", "bad request");
        let actual = serde_json::to_value(&fixture).unwrap();
        let expected = serde_json::json!({
            "kind": "error",
            "v": 1,
            "id": "c1",
            "text": "bad request",
            "cause": ""
        });
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_server_info_status_helper() {
        let fixture = ServerEvent::info_status("streaming");
        let expected = ServerEvent::Status {
            v: 1,
            level: "info".into(),
            text: "streaming".into(),
        };
        assert_eq!(fixture, expected);
    }

    #[test]
    fn test_server_event_version_helper() {
        let fixture = ServerEvent::TurnStart {
            v: 1,
            turn_id: "t1".into(),
        };
        assert_eq!(fixture.version(), 1);
    }

    #[test]
    fn test_unknown_server_event_field_is_tolerated() {
        // Forward-compat: a future server adds a new field that older
        // clients don't know about. Deserialisation must succeed.
        let fixture = r#"{"kind":"turn_start","v":1,"turn_id":"t1","brand_new":"hello"}"#;
        let actual: ServerEvent = serde_json::from_str(fixture).unwrap();
        let expected = ServerEvent::TurnStart {
            v: 1,
            turn_id: "t1".into(),
        };
        assert_eq!(actual, expected);
    }
}
