//! `ConsoleWriter` adapter that converts byte-level writes into structured
//! [`ServerEvent`] frames on stdout for `--frontend=json`.
//!
//! Plugged into the existing [`crate::stream_renderer::StreamingWriter`]
//! pipeline as the leaf printer when JSON mode is active. The streaming
//! markdown renderer keeps producing terminal output as usual; this adapter
//! wraps each contiguous byte slice into a `chunk` event tagged with the
//! current turn id, then writes one NDJSON line per write.
//!
//! ANSI escape sequences arriving from `colored` / `streamdown` are stripped
//! before framing — JSON consumers should not have to parse VT escapes. This
//! happens at the seam rather than further upstream so the same renderer can
//! still feed the TTY frontend with full colour.
//!
//! Output is serialised through a single `Mutex<Box<dyn Write + Send>>` so
//! writes from multiple threads (the streaming renderer, tool result
//! emitters, status emitters) cannot interleave inside a JSON line.
//!
//! Most of the public surface here is currently exercised only by unit
//! tests; the full wiring into [`crate::stream_renderer::StreamingWriter`]
//! lands with the upcoming JSON `Frontend` trait commit. The module-level
//! `#[allow(dead_code)]` keeps the lib build quiet until that wiring is in
//! place.
#![allow(dead_code)]

use std::io::{self, Write};
use std::sync::Mutex;

use bstr::ByteSlice;
use forge_domain::ConsoleWriter;
use serde_json::json;

use super::protocol::{PROTOCOL_VERSION, ServerEvent, TurnId};

/// `ConsoleWriter` adapter that emits one `chunk` event per `write` call
/// (after stripping ANSI escapes) to a serialised JSON sink.
///
/// Use [`JsonConsoleWriter::set_turn`] before a turn begins so subsequent
/// writes carry the right `turn_id`. Use [`JsonConsoleWriter::set_stream`]
/// to flip between `"assistant"` and `"reasoning"` channels.
///
/// `write_err` writes are framed as `error`-level `status` events rather
/// than `chunk`s, since JSON consumers expect stderr to be out-of-band.
pub struct JsonConsoleWriter {
    inner: Mutex<Inner>,
}

/// Inner state held under a single mutex so writes never interleave.
struct Inner {
    sink: Box<dyn Write + Send>,
    turn_id: Option<TurnId>,
    stream: String,
}

impl JsonConsoleWriter {
    /// Creates a JSON adapter that frames writes onto `sink`. In production
    /// `sink` is `io::stdout().lock()` (boxed); in tests an in-memory
    /// `Vec<u8>` round-trips the events.
    pub fn new(sink: Box<dyn Write + Send>) -> Self {
        Self {
            inner: Mutex::new(Inner {
                sink,
                turn_id: None,
                stream: "assistant".into(),
            }),
        }
    }

    /// Sets the active turn id. Subsequent writes are tagged with this id
    /// until `set_turn` is called again.
    ///
    /// Pass `None` to drop the turn id (e.g. between turns); writes
    /// received with no active turn id emit a [`ServerEvent::Error`]
    /// instead of a chunk.
    pub fn set_turn(&self, turn_id: Option<TurnId>) {
        self.inner.lock().unwrap().turn_id = turn_id;
    }

    /// Sets the active stream channel for chunk events. Common values are
    /// `"assistant"` (default) and `"reasoning"`.
    pub fn set_stream(&self, stream: impl Into<String>) {
        self.inner.lock().unwrap().stream = stream.into();
    }

    /// Emits an arbitrary [`ServerEvent`] on the same serialised channel as
    /// chunk writes. Used by the surrounding frontend driver to send
    /// `turn_start`, `turn_end`, `tool_call`, `usage`, etc.
    pub fn emit(&self, event: &ServerEvent) -> io::Result<()> {
        let line = serde_json::to_string(event)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        let mut inner = self.inner.lock().unwrap();
        writeln!(inner.sink, "{line}")?;
        inner.sink.flush()
    }
}

impl ConsoleWriter for JsonConsoleWriter {
    /// Frames `buf` as a `chunk` event after stripping ANSI escapes.
    ///
    /// The `io::Write` contract requires returning the number of bytes
    /// consumed from `buf`, which is `buf.len()` here regardless of how
    /// the framed event is sized — we always consume the whole input.
    ///
    /// When no turn is active (e.g. startup banners, init titles, post-turn
    /// summaries) the bytes are framed as a `status { level: "info" }`
    /// event rather than dropped or converted to an error. This keeps
    /// every byte that *would* have hit stdout in TTY mode visible to
    /// the JSON consumer, just on an out-of-band channel.
    fn write(&self, buf: &[u8]) -> io::Result<usize> {
        let text = strip_ansi(buf);
        if text.trim().is_empty() {
            return Ok(buf.len());
        }
        let mut inner = self.inner.lock().unwrap();
        let value = match inner.turn_id.clone() {
            Some(turn_id) => json!({
                "kind": "chunk",
                "v": PROTOCOL_VERSION,
                "turn_id": turn_id,
                "stream": inner.stream.clone(),
                "text": text,
            }),
            None => json!({
                "kind": "status",
                "v": PROTOCOL_VERSION,
                "level": "info",
                "text": text,
            }),
        };
        writeln!(inner.sink, "{value}")?;
        inner.sink.flush()?;
        Ok(buf.len())
    }

    /// Frames `buf` as a `status { level: "error" }` event so the JSON
    /// consumer can surface stderr writes without violating the wire
    /// format.
    fn write_err(&self, buf: &[u8]) -> io::Result<usize> {
        let text = strip_ansi(buf);
        if text.is_empty() {
            return Ok(buf.len());
        }
        let value = json!({
            "kind": "status",
            "v": PROTOCOL_VERSION,
            "level": "error",
            "text": text,
        });
        let mut inner = self.inner.lock().unwrap();
        writeln!(inner.sink, "{value}")?;
        inner.sink.flush()?;
        Ok(buf.len())
    }

    fn flush(&self) -> io::Result<()> {
        self.inner.lock().unwrap().sink.flush()
    }

    fn flush_err(&self) -> io::Result<()> {
        self.inner.lock().unwrap().sink.flush()
    }
}

/// Strips ANSI escape sequences and decodes UTF-8 (lossy on error).
///
/// `streamdown` and `colored` produce output peppered with `\x1b[…m`
/// SGR codes. Editor clients should not have to parse them, so we drop
/// them at the protocol seam.
///
/// The implementation is a small SGR-only state machine: it covers
/// `\x1b[…m` and `\x1b[?…h/l` (private modes) which is everything the
/// streaming renderer emits. Cursor-movement escapes don't appear in the
/// pipeline because the JSON frontend disables them upstream
/// (`colored::control::set_override(false)` plus
/// `spinner_manager.set_quiet(true)`), but the matcher is liberal so
/// unexpected escapes are still stripped rather than printed verbatim.
fn strip_ansi(buf: &[u8]) -> String {
    let s = buf.to_str_lossy();
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' && chars.peek() == Some(&'[') {
            // Consume the `[`.
            chars.next();
            // Skip until the final byte of an ANSI CSI sequence
            // (ASCII 0x40..=0x7e).
            for ch in chars.by_ref() {
                if ('\x40'..='\x7e').contains(&ch) {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use pretty_assertions::assert_eq;
    use serde_json::Value;

    use super::*;

    /// Test sink that captures every byte written and exposes it as a
    /// borrowed slice. The `Arc<Mutex<Vec<u8>>>` lets the test inspect the
    /// captured bytes after the writer has consumed it.
    fn make_sink() -> (Box<dyn Write + Send>, Arc<std::sync::Mutex<Vec<u8>>>) {
        let buf = Arc::new(std::sync::Mutex::new(Vec::<u8>::new()));
        struct SharedWriter(Arc<std::sync::Mutex<Vec<u8>>>);
        impl Write for SharedWriter {
            fn write(&mut self, b: &[u8]) -> io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        (Box::new(SharedWriter(buf.clone())), buf)
    }

    fn captured_lines(buf: &Arc<std::sync::Mutex<Vec<u8>>>) -> Vec<Value> {
        let bytes = buf.lock().unwrap().clone();
        let text = String::from_utf8(bytes).expect("captured bytes must be utf-8");
        text.lines()
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_str::<Value>(l).expect("each line must be one json object"))
            .collect()
    }

    #[test]
    fn test_strip_ansi_removes_sgr_sequences() {
        let fixture = b"\x1b[31mred\x1b[0m text";
        let actual = strip_ansi(fixture);
        let expected = "red text".to_string();
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_strip_ansi_passes_plain_text_through() {
        let fixture = b"hello world";
        let actual = strip_ansi(fixture);
        let expected = "hello world".to_string();
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_strip_ansi_handles_lossy_utf8() {
        // Invalid UTF-8 byte sequence — must not panic.
        let fixture = &[0xff, 0xfe, b'a'][..];
        let actual = strip_ansi(fixture);
        assert!(actual.contains('a'));
    }

    #[test]
    fn test_write_emits_chunk_event_with_turn_id() {
        let (sink, captured) = make_sink();
        let writer = JsonConsoleWriter::new(sink);
        writer.set_turn(Some("t1".into()));

        let n = writer.write(b"hello").unwrap();
        assert_eq!(n, 5);

        let lines = captured_lines(&captured);
        assert_eq!(lines.len(), 1);
        let expected = json!({
            "kind": "chunk",
            "v": PROTOCOL_VERSION,
            "turn_id": "t1",
            "stream": "assistant",
            "text": "hello",
        });
        assert_eq!(lines[0], expected);
    }

    #[test]
    fn test_write_strips_ansi_before_framing() {
        let (sink, captured) = make_sink();
        let writer = JsonConsoleWriter::new(sink);
        writer.set_turn(Some("t1".into()));

        writer.write(b"\x1b[1mbold\x1b[0m").unwrap();

        let lines = captured_lines(&captured);
        let actual = lines[0]
            .get("text")
            .and_then(|v| v.as_str())
            .map(str::to_owned);
        let expected = Some("bold".to_string());
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_write_with_no_turn_emits_status_event() {
        let (sink, captured) = make_sink();
        let writer = JsonConsoleWriter::new(sink);

        writer.write(b"orphan").unwrap();

        let lines = captured_lines(&captured);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0]["kind"], "status");
        assert_eq!(lines[0]["level"], "info");
        assert_eq!(lines[0]["text"], "orphan");
    }

    #[test]
    fn test_write_skips_empty_after_ansi_strip() {
        // A pure ANSI escape sequence should not produce an empty chunk.
        let (sink, captured) = make_sink();
        let writer = JsonConsoleWriter::new(sink);
        writer.set_turn(Some("t1".into()));

        let n = writer.write(b"\x1b[2J").unwrap();
        assert_eq!(n, 4);

        let lines = captured_lines(&captured);
        assert!(lines.is_empty(), "no chunk should be emitted, got {lines:?}");
    }

    #[test]
    fn test_write_err_emits_error_status() {
        let (sink, captured) = make_sink();
        let writer = JsonConsoleWriter::new(sink);

        writer.write_err(b"boom").unwrap();

        let lines = captured_lines(&captured);
        assert_eq!(lines.len(), 1);
        let expected = json!({
            "kind": "status",
            "v": PROTOCOL_VERSION,
            "level": "error",
            "text": "boom",
        });
        assert_eq!(lines[0], expected);
    }

    #[test]
    fn test_emit_serialises_arbitrary_server_event() {
        let (sink, captured) = make_sink();
        let writer = JsonConsoleWriter::new(sink);

        let event = ServerEvent::TurnStart {
            v: PROTOCOL_VERSION,
            turn_id: "t1".into(),
        };
        writer.emit(&event).unwrap();

        let lines = captured_lines(&captured);
        let expected = json!({
            "kind": "turn_start",
            "v": PROTOCOL_VERSION,
            "turn_id": "t1",
        });
        assert_eq!(lines[0], expected);
    }

    #[test]
    fn test_set_stream_swaps_channel_label() {
        let (sink, captured) = make_sink();
        let writer = JsonConsoleWriter::new(sink);
        writer.set_turn(Some("t1".into()));
        writer.set_stream("reasoning");

        writer.write(b"thought").unwrap();

        let lines = captured_lines(&captured);
        assert_eq!(lines[0]["stream"], "reasoning");
    }
}
