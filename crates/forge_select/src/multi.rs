use std::io::IsTerminal;

use anyhow::Result;
use console::strip_ansi_codes;

use crate::preview::{SelectMode, SelectRow, SelectUiOptions};

/// Builder for multi-select prompts.
pub struct MultiSelectBuilder<T> {
    pub(crate) message: String,
    pub(crate) options: Vec<T>,
}

impl<T> MultiSelectBuilder<T> {
    /// Execute multi-select prompt.
    ///
    /// # Returns
    ///
    /// - `Ok(Some(Vec<T>))` when the user selects one or more options.
    /// - `Ok(None)` when no options are available or the user cancels.
    ///
    /// # Errors
    ///
    /// Returns an error if terminal setup, event handling, or rendering fails.
    pub fn prompt(self) -> Result<Option<Vec<T>>>
    where
        T: std::fmt::Display + Clone,
    {
        // Comint fallback: degrade multi-select to a single-pick line prompt.
        // Multi-pick over a dumb terminal would require a richer protocol
        // (Track B's `select_response` event); for v1 a single choice is the
        // safest predictable behaviour.
        if crate::comint::is_comint() {
            if self.options.is_empty() {
                return Ok(None);
            }

            let displays: Vec<String> = self
                .options
                .iter()
                .map(|item| strip_ansi_codes(&item.to_string()).trim().to_string())
                .collect();

            // Under the JSON frontend, dispatch through the installed
            // [`SelectorBackend`] which carries proper multi-select via
            // the `select_response` event (comma-separated values).
            if let Some(backend) = crate::comint::is_json()
                .then(crate::backend::selector_backend)
                .flatten()
            {
                let defaults = vec![false; displays.len()];
                let chosen = backend.multi(&self.message, &displays, &defaults)?;
                return Ok(chosen.map(|indices| {
                    indices
                        .into_iter()
                        .filter_map(|i| self.options.get(i).cloned())
                        .collect()
                }));
            }

            let chosen = crate::comint::prompt_select_line(&self.message, &displays)?;
            // FORK PATCH (mymain, 2026-08-08): `.get()` rather than `[]`.
            // CI's autofix workflow denies clippy::indexing_slicing, but
            // nothing local ever ran that lint, so this indexing shipped.
            // The index comes back from the frontend over the comint
            // protocol, i.e. from outside this process, so a stale or
            // malformed reply used to panic the whole CLI. Out of range now
            // means "no selection", matching the `.get(i).cloned()` filter
            // the backend branch above already uses.
            // On upstream merge: if this hunk conflicts, take upstream's
            // shape and re-apply `.get(..).cloned()`; run `just clippy-strict`.
            return Ok(chosen
                .and_then(|index| self.options.get(index).cloned())
                .map(|option| vec![option]));
        }

        if !std::io::stderr().is_terminal() {
            return Ok(None);
        }

        if self.options.is_empty() {
            return Ok(None);
        }

        let rows = self
            .options
            .iter()
            .enumerate()
            .map(|(index, item)| {
                let display = strip_ansi_codes(&item.to_string()).trim().to_string();
                SelectRow::new(index.to_string(), display.clone()).search(display)
            })
            .collect::<Vec<_>>();

        let selected = SelectUiOptions::new(format!("{} ❯ ", self.message), rows)
            .mode(SelectMode::Multi)
            .prompt_multi()?;

        Ok(selected.and_then(|rows| {
            let selected_items = rows
                .into_iter()
                .filter_map(|row| {
                    row.raw
                        .parse::<usize>()
                        .ok()
                        .and_then(|index| self.options.get(index).cloned())
                })
                .collect::<Vec<_>>();

            if selected_items.is_empty() {
                None
            } else {
                Some(selected_items)
            }
        }))
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use crate::ForgeWidget;

    #[test]
    fn test_multi_select_builder_creates() {
        let builder = ForgeWidget::multi_select("Select options:", vec!["a", "b", "c"]);
        assert_eq!(builder.message, "Select options:");
        assert_eq!(builder.options, vec!["a", "b", "c"]);
    }
}
