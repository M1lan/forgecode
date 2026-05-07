use std::io::{self, BufRead, BufReader, Write as _};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use forge_api::Environment;

use crate::editor::{ForgeEditor, ReadResult};
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
}

impl UserInput {
    /// Reads a single user turn, returning the parsed [`AppCommand`].
    ///
    /// Dispatches to the active frontend's prompt loop. The TTY frontend
    /// owns the terminal in raw mode; the comint frontend reads one
    /// newline-delimited line at a time from stdin.
    pub async fn prompt(&self, prompt: &mut ForgePrompt) -> anyhow::Result<AppCommand> {
        match self {
            Self::Console(console) => console.prompt(prompt).await,
            Self::Comint(comint) => comint.prompt(prompt).await,
        }
    }

    /// Pre-fills the next prompt's buffer with `content`.
    ///
    /// Used by `/edit`-style commands to seed the input area. In TTY mode
    /// this calls into reedline's edit-command queue. In comint mode,
    /// pre-fill is best-effort — comint subprocesses cannot inject text
    /// into their own input ring, so the content is buffered and emitted
    /// as a `[forge:prefill]…[/]` marker line on the next prompt.
    pub fn set_buffer(&self, content: String) {
        match self {
            Self::Console(console) => console.set_buffer(content),
            Self::Comint(comint) => comint.set_buffer(content),
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
}
