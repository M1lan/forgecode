use std::io::{self, BufRead, BufReader, Write as _};
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

use forge_api::Environment;

use crate::editor::{ForgeEditor, ReadResult};
use crate::frontend::protocol::{ClientEvent, PROTOCOL_VERSION, ServerEvent};
use crate::model::{AppCommand, ForgeCommandManager};
use crate::prompt::ForgePrompt;
use crate::tracker;

/// Plain-text prompt prefix used by the comint frontend.
///
/// Emacs `comint-mode` matches this against `comint-prompt-regexp` so it
/// recognises Forge's "ready for input" state. Keep it ASCII and free of
/// ANSI escape codes — comint-mode renders escapes as literal text.
const COMINT_PROMPT_PREFIX: &str = "forge> ";

/// User input source for the interactive REPL.
///
/// Wraps the two interactive frontends behind a single dispatch enum so the
/// surrounding [`crate::ui::UI`] code can stay agnostic of which frontend is
/// active. We deliberately use an enum rather than `Box<dyn Trait>` because
/// the prompt method is `async` and async-trait erasure adds avoidable
/// allocation and lifetime ceremony for two known variants.
///
/// `Console` is boxed to keep the enum's stack size proportional to the
/// smaller variant — reedline pulls in a deep state machine that bloats the
/// inline footprint.
pub enum UserInput {
    /// Full TTY frontend: reedline + crossterm + history + completion menu.
    Console(Box<Console>),
    /// Dumb-terminal frontend: line-buffered stdin reads, plain prompt.
    Comint(CominInput),
    /// NDJSON line-protocol frontend: reads [`ClientEvent`]s from stdin and
    /// emits [`ServerEvent`]s on stdout. Unstable; gated behind
    /// `--frontend=json --unstable`. See `docs/frontend-protocol.md`.
    Json(JsonInput),
}

impl UserInput {
    /// Reads a single user turn, returning the parsed [`AppCommand`].
    ///
    /// Dispatches to the active frontend's prompt loop. The TTY frontend
    /// owns the terminal in raw mode; the comint frontend reads one
    /// newline-delimited line at a time from stdin; the JSON frontend
    /// reads one [`ClientEvent`] per line and translates it.
    pub async fn prompt(&self, prompt: &mut ForgePrompt) -> anyhow::Result<AppCommand> {
        match self {
            Self::Console(console) => console.prompt(prompt).await,
            Self::Comint(comint) => comint.prompt(prompt).await,
            Self::Json(json) => json.prompt(prompt).await,
        }
    }

    /// Pre-fills the next prompt's buffer with `content`.
    ///
    /// Used by `/edit`-style commands to seed the input area. In TTY mode
    /// this calls into reedline's edit-command queue. In comint mode,
    /// pre-fill is best-effort — comint subprocesses cannot inject text
    /// into their own input ring, so the content is buffered and emitted
    /// as a `[forge:prefill]…[/]` marker line on the next prompt. In JSON
    /// mode the content is emitted as a [`ServerEvent::Status`] of level
    /// `"prefill"` so the client can `(insert)` it server-side.
    pub fn set_buffer(&self, content: String) {
        match self {
            Self::Console(console) => console.set_buffer(content),
            Self::Comint(comint) => comint.set_buffer(content),
            Self::Json(json) => json.set_buffer(content),
        }
    }
}

/// Console implementation for handling user input via command line.
pub struct Console {
    command: Arc<ForgeCommandManager>,
    editor: Mutex<ForgeEditor>,
}

impl Console {
    /// Creates a new instance of `Console`.
    pub fn new(
        env: Environment,
        custom_history_path: Option<PathBuf>,
        command: Arc<ForgeCommandManager>,
    ) -> Self {
        let editor = Mutex::new(ForgeEditor::new(env, custom_history_path, command.clone()));
        Self { command, editor }
    }
}

impl Console {
    pub async fn prompt(&self, prompt: &mut ForgePrompt) -> anyhow::Result<AppCommand> {
        loop {
            let mut forge_editor = self.editor.lock().unwrap();
            let user_input = forge_editor.prompt(prompt)?;

            drop(forge_editor);
            match user_input {
                ReadResult::Continue => continue,
                ReadResult::Exit => return Ok(AppCommand::Exit),
                ReadResult::Empty => continue,
                ReadResult::Success(text) => {
                    tracker::prompt(text.clone());
                    return self.command.parse(&text);
                }
            }
        }
    }

    /// Sets the buffer content for the next prompt
    pub fn set_buffer(&self, content: String) {
        let mut editor = self.editor.lock().unwrap();
        editor.set_buffer(content);
    }
}

/// Line-buffered stdin reader for the comint dumb-terminal frontend.
///
/// Replaces the reedline-based [`Console`] when `--frontend=comint` (or
/// auto-detected via `INSIDE_EMACS=…comint…` / `TERM=dumb`). Reads one
/// newline-terminated line per turn from stdin, with no raw mode, no
/// crossterm events, no bracketed paste, and no ANSI styling on the
/// prompt prefix.
///
/// EOF on stdin (e.g. Ctrl+D from comint) is reported as
/// [`AppCommand::Exit`]; empty lines are ignored.
pub struct CominInput {
    command: Arc<ForgeCommandManager>,
    /// Pending pre-fill buffer emitted as a marker line on the next prompt.
    /// See [`UserInput::set_buffer`] for the rationale.
    prefill: Mutex<Option<String>>,
}

impl CominInput {
    /// Creates a new comint input reader bound to the given command manager.
    pub fn new(command: Arc<ForgeCommandManager>) -> Self {
        Self { command, prefill: Mutex::new(None) }
    }

    /// Reads a single line from stdin and parses it as an [`AppCommand`].
    ///
    /// Empty lines are skipped (the prompt re-displays). EOF returns
    /// [`AppCommand::Exit`]. The prompt is written to stdout on the first
    /// iteration and after each ignored empty line so the comint
    /// `comint-prompt-regexp` keeps tracking position.
    pub async fn prompt(&self, _prompt: &mut ForgePrompt) -> anyhow::Result<AppCommand> {
        // Drain any pending prefill into a marker line so the Emacs side can
        // strip it and `(insert ...)` the content into the input area.
        if let Some(pending) = self.prefill.lock().unwrap().take() {
            // Marker chosen to be unambiguous and easy to fontify away on the
            // Emacs side. Newlines in the payload are escaped to keep the
            // marker on a single line.
            let escaped = pending.replace('\n', "\\n");
            println!("[forge:prefill]{escaped}[/]");
        }

        loop {
            // Print the prompt prefix and flush so the editor sees it before
            // we block on read_line. stdout is line-buffered when connected
            // to a pipe, so an explicit flush is required.
            print!("{COMINT_PROMPT_PREFIX}");
            let _ = io::stdout().flush();

            let mut line = String::new();
            let stdin = io::stdin();
            let mut reader = BufReader::new(stdin.lock());
            let bytes = reader.read_line(&mut line)?;

            // EOF: comint subprocess was closed. Exit cleanly.
            if bytes == 0 {
                return Ok(AppCommand::Exit);
            }

            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            tracker::prompt(trimmed.to_string());
            return self.command.parse(trimmed);
        }
    }

    /// Buffers `content` to be emitted as a `[forge:prefill]…[/]` marker
    /// line on the next prompt. See [`UserInput::set_buffer`].
    pub fn set_buffer(&self, content: String) {
        *self.prefill.lock().unwrap() = Some(content);
    }
}

/// NDJSON line-protocol input reader for `--frontend=json`.
///
/// Receives [`ClientEvent`]s from the [`crate::frontend::router::EventRouter`]
/// background thread (which owns stdin) and translates each one into an
/// [`AppCommand`] for the surrounding event loop:
///
/// - [`ClientEvent::Submit`] → `AppCommand::Message(text)` via the same
///   `ForgeCommandManager::parse` that the other frontends use, so slash
///   commands embedded in `text` (e.g. `"/new"`) still route correctly.
/// - [`ClientEvent::Command`] with `name == "exit"` → [`AppCommand::Exit`].
///   Other named commands are joined with their args and parsed.
/// - [`ClientEvent::Cancel`] → currently dropped; the surrounding loop
///   re-prompts. Wiring lands when in-flight cancellation is plumbed.
/// - [`ClientEvent::SelectResponse`] is never observed here — the router
///   forwards it directly to the matching pending selector instead. The
///   variant is kept on the translation function to preserve the exhaustive
///   match if a future router change relaxes routing.
/// - [`ClientEvent::SetBuffer`] → buffered and emitted as a status event
///   on the next prompt cycle.
///
/// The router thread closing the channel (e.g. on EOF) returns
/// [`AppCommand::Exit`] from `prompt`.
pub struct JsonInput {
    command: Arc<ForgeCommandManager>,
    /// Receiver side of the router's prompt-event channel. Wrapped in
    /// `Mutex<Option<...>>` because `mpsc::Receiver` is `!Sync` and the
    /// surrounding [`UserInput`] is shared across the UI loop. The
    /// `Option` lets us drop the receiver after EOF so subsequent
    /// `prompt` calls return `Exit` immediately rather than blocking on
    /// a closed channel.
    receiver: Mutex<Option<mpsc::Receiver<ClientEvent>>>,
    /// Pending `set_buffer` payload to flush as a status event on the next
    /// prompt cycle. JSON clients are expected to mirror this back into
    /// their input buffer themselves.
    prefill: Mutex<Option<String>>,
}

impl JsonInput {
    /// Creates a new JSON input reader bound to the given command manager
    /// and router channel.
    pub fn new(command: Arc<ForgeCommandManager>, receiver: mpsc::Receiver<ClientEvent>) -> Self {
        Self {
            command,
            receiver: Mutex::new(Some(receiver)),
            prefill: Mutex::new(None),
        }
    }

    /// Test-only constructor that builds a `JsonInput` with no upstream
    /// router. Calling `prompt` returns `Exit` immediately. Used by
    /// translate-only unit tests.
    #[cfg(test)]
    fn new_disconnected(command: Arc<ForgeCommandManager>) -> Self {
        let (_tx, rx) = mpsc::channel();
        // Drop tx so rx is hung up: any blocking recv returns Disconnected.
        drop(_tx);
        Self {
            command,
            receiver: Mutex::new(Some(rx)),
            prefill: Mutex::new(None),
        }
    }

    /// Receives [`ClientEvent`]s from the router until one translates to
    /// an [`AppCommand`].
    ///
    /// Drains any pending pre-fill as a `Status { level: "prefill" }`
    /// event before reading.
    pub async fn prompt(&self, _prompt: &mut ForgePrompt) -> anyhow::Result<AppCommand> {
        // Flush any pending prefill so the JSON client can mirror it back
        // into its input area.
        if let Some(pending) = self.prefill.lock().unwrap().take() {
            let event = ServerEvent::Status {
                v: PROTOCOL_VERSION,
                level: "prefill".into(),
                text: pending,
            };
            emit_event(&event)?;
        }

        loop {
            // Hold the receiver lock only for the duration of one recv()
            // so the surrounding async runtime can be polled normally.
            let event = {
                let mut guard = self.receiver.lock().unwrap();
                let Some(rx) = guard.as_mut() else {
                    return Ok(AppCommand::Exit);
                };
                match rx.recv() {
                    Ok(ev) => ev,
                    Err(_) => {
                        // Router thread closed the channel: EOF on stdin
                        // or fatal IO error. Drop the receiver so future
                        // calls short-circuit.
                        *guard = None;
                        return Ok(AppCommand::Exit);
                    }
                }
            };

            if let Some(cmd) = self.translate(event)? {
                return Ok(cmd);
            }
            // Event accepted but no command produced (e.g. cancel,
            // set_buffer). Loop and read the next event.
        }
    }

    /// Translates a [`ClientEvent`] into an [`AppCommand`] when possible.
    /// Returns `Ok(None)` for events that should be silently consumed
    /// (cancel, select_response without an in-flight selector,
    /// set_buffer which only mutates state).
    fn translate(&self, event: ClientEvent) -> anyhow::Result<Option<AppCommand>> {
        match event {
            ClientEvent::Submit { text, .. } => {
                tracker::prompt(text.clone());
                self.command.parse(&text).map(Some)
            }
            ClientEvent::Command { name, args, .. } => {
                let trimmed = name.trim_start_matches('/').trim_start_matches(':');
                let mut joined = format!("/{trimmed}");
                if !args.is_empty() {
                    joined.push(' ');
                    joined.push_str(&args.join(" "));
                }
                self.command.parse(&joined).map(Some)
            }
            ClientEvent::SetBuffer { text, .. } => {
                self.set_buffer(text);
                Ok(None)
            }
            ClientEvent::Cancel { .. } | ClientEvent::SelectResponse { .. } => Ok(None),
        }
    }

    /// Buffers `content` to be emitted as a `Status { level: "prefill" }`
    /// event on the next prompt cycle.
    pub fn set_buffer(&self, content: String) {
        *self.prefill.lock().unwrap() = Some(content);
    }
}

/// Writes a single [`ServerEvent`] to stdout as one NDJSON line and flushes.
///
/// Used by [`JsonInput`] for out-of-band events (errors, prefill status).
/// The full streaming pipeline goes through [`crate::frontend::JsonConsoleWriter`]
/// (forthcoming) instead of this helper.
fn emit_event(event: &ServerEvent) -> anyhow::Result<()> {
    let line = serde_json::to_string(event)?;
    let mut out = io::stdout().lock();
    writeln!(out, "{line}")?;
    out.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_comint_prompt_prefix_is_plain_ascii() {
        // The comint prompt must be ANSI-free so comint-mode's regexp matcher
        // and read-only prompt machinery can reliably detect it.
        let actual = COMINT_PROMPT_PREFIX;
        let expected = "forge> ";
        assert_eq!(actual, expected);

        // Defensive: no control bytes.
        for byte in actual.bytes() {
            assert!((0x20..0x7f).contains(&byte), "non-ASCII byte: {byte:#x}");
        }
    }

    #[test]
    fn test_comint_input_set_buffer_stores_pending_content() {
        let command = Arc::new(ForgeCommandManager::default());
        let comint = CominInput::new(command);

        comint.set_buffer("hello".to_string());

        let actual = comint.prefill.lock().unwrap().clone();
        let expected = Some("hello".to_string());
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_comint_input_set_buffer_overwrites_previous() {
        let command = Arc::new(ForgeCommandManager::default());
        let comint = CominInput::new(command);

        comint.set_buffer("first".to_string());
        comint.set_buffer("second".to_string());

        let actual = comint.prefill.lock().unwrap().clone();
        let expected = Some("second".to_string());
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_json_input_translate_submit_to_message() {
        // `translate(Submit)` calls `tracker::prompt` which dispatches to a
        // tokio runtime; wrap the test in `#[tokio::test]` so a runtime is
        // available.
        let command = Arc::new(ForgeCommandManager::default());
        let json = JsonInput::new_disconnected(command);

        let event = ClientEvent::Submit {
            v: PROTOCOL_VERSION,
            id: "c1".into(),
            text: "hello world".into(),
            attachments: vec![],
        };
        let actual = json.translate(event).unwrap();
        let expected = Some(AppCommand::Message("hello world".into()));
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_json_input_translate_set_buffer_consumes_silently() {
        let command = Arc::new(ForgeCommandManager::default());
        let json = JsonInput::new_disconnected(command);

        let event = ClientEvent::SetBuffer {
            v: PROTOCOL_VERSION,
            id: "c2".into(),
            text: "draft".into(),
        };
        let actual = json.translate(event).unwrap();
        assert_eq!(actual, None);
        assert_eq!(
            json.prefill.lock().unwrap().clone(),
            Some("draft".to_string())
        );
    }

    #[test]
    fn test_json_input_translate_cancel_consumes_silently() {
        let command = Arc::new(ForgeCommandManager::default());
        let json = JsonInput::new_disconnected(command);

        let event = ClientEvent::Cancel {
            v: PROTOCOL_VERSION,
            id: "c3".into(),
            target: "t1".into(),
        };
        let actual = json.translate(event).unwrap();
        assert_eq!(actual, None);
    }

    #[test]
    fn test_json_input_translate_select_response_consumes_silently() {
        let command = Arc::new(ForgeCommandManager::default());
        let json = JsonInput::new_disconnected(command);

        let event = ClientEvent::SelectResponse {
            v: PROTOCOL_VERSION,
            id: "c4".into(),
            target: "sel-7".into(),
            value: "yes".into(),
        };
        let actual = json.translate(event).unwrap();
        assert_eq!(actual, None);
    }

    #[test]
    fn test_json_input_translate_command_exit() {
        // ForgeCommandManager parses "/exit" → AppCommand::Exit. Verify
        // that ClientEvent::Command{name:"exit"} routes the same way.
        let command = Arc::new(ForgeCommandManager::default());
        let json = JsonInput::new_disconnected(command);

        let event = ClientEvent::Command {
            v: PROTOCOL_VERSION,
            id: "c5".into(),
            name: "exit".into(),
            args: vec![],
        };
        let actual = json.translate(event).unwrap();
        let expected = Some(AppCommand::Exit);
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_json_input_translate_command_strips_leading_slash() {
        // Allow clients to send `name: "/exit"` or `name: "exit"`
        // interchangeably; both should parse the same.
        let command = Arc::new(ForgeCommandManager::default());
        let json = JsonInput::new_disconnected(command);

        let event = ClientEvent::Command {
            v: PROTOCOL_VERSION,
            id: "c5".into(),
            name: "/exit".into(),
            args: vec![],
        };
        let actual = json.translate(event).unwrap();
        let expected = Some(AppCommand::Exit);
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_json_input_set_buffer_stores_pending() {
        let command = Arc::new(ForgeCommandManager::default());
        let json = JsonInput::new_disconnected(command);

        json.set_buffer("hello".into());

        let actual = json.prefill.lock().unwrap().clone();
        let expected = Some("hello".to_string());
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_json_input_prompt_returns_exit_on_channel_close() {
        // Construct an explicitly-closed channel. The first `prompt`
        // call should observe the disconnect and return `Exit` rather
        // than blocking.
        let (tx, rx) = mpsc::channel::<ClientEvent>();
        drop(tx);
        let command = Arc::new(ForgeCommandManager::default());
        let json = JsonInput::new(command, rx);
        let mut prompt = ForgePrompt::new(std::path::PathBuf::from("/"), Default::default());

        let actual = json.prompt(&mut prompt).await.unwrap();
        let expected = AppCommand::Exit;
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_json_input_prompt_translates_submit_from_router() {
        let (tx, rx) = mpsc::channel::<ClientEvent>();
        tx.send(ClientEvent::Submit {
            v: PROTOCOL_VERSION,
            id: "c1".into(),
            text: "hello".into(),
            attachments: vec![],
        })
        .unwrap();
        let command = Arc::new(ForgeCommandManager::default());
        let json = JsonInput::new(command, rx);
        let mut prompt = ForgePrompt::new(std::path::PathBuf::from("/"), Default::default());

        let actual = json.prompt(&mut prompt).await.unwrap();
        let expected = AppCommand::Message("hello".into());
        assert_eq!(actual, expected);
    }
}
