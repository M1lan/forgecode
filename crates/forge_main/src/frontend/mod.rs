//! Frontend abstractions for the JSON line protocol track.
//!
//! See [`protocol`] for the wire format used by `--frontend=json`. This
//! module owns:
//!
//! - [`protocol`] — `ClientEvent` / `ServerEvent` types and the protocol
//!   version constant.
//! - [`console_writer::JsonConsoleWriter`] — `ConsoleWriter` adapter that
//!   wraps streaming-renderer byte writes into `chunk` events.
//! - [`orchestrator::JsonFrontend`] — high-level event-emit API the UI
//!   lifecycle calls into. One per process; held as
//!   `Option<Arc<JsonFrontend>>` on the [`crate::ui::UI`] struct.
//! - [`router::EventRouter`] — background stdin-reader thread that
//!   demultiplexes [`protocol::ClientEvent`]s into prompt-loop events
//!   and selector responses.
//! - [`selector_backend::JsonSelectorBackend`] —
//!   [`forge_select::SelectorBackend`] implementation that emits
//!   `select` events and blocks on matching `select_response`s.
//!
//! The JSON input side lives in [`crate::input::JsonInput`] (NDJSON
//! stdin reader) so that all four frontends (TTY, comint, JSON, future
//! drivers) share the same `UserInput::prompt` dispatch surface.

pub mod console_writer;
pub mod orchestrator;
pub mod protocol;
pub mod router;
pub mod selector_backend;

pub use console_writer::JsonConsoleWriter;
pub use orchestrator::JsonFrontend;
pub use router::EventRouter;
pub use selector_backend::JsonSelectorBackend;
