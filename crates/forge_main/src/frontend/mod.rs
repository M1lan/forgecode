//! Frontend abstractions for the JSON line protocol track.
//!
//! See [`protocol`] for the wire format used by `--frontend=json`. This
//! module owns the protocol types and the
//! [`console_writer::JsonConsoleWriter`] adapter that lets the existing
//! markdown streaming pipeline emit [`protocol::ServerEvent`] frames instead
//! of raw bytes. The full `Frontend` trait that [`crate::ui::UI`] will
//! eventually drive lands in a follow-up commit; until then the JSON input
//! side is handled by [`crate::input::JsonInput`] and the streaming output
//! adapter is exercised via its unit tests.

pub mod console_writer;
pub mod protocol;
