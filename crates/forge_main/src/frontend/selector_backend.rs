//! [`forge_select::SelectorBackend`] implementation for the JSON
//! frontend.
//!
//! Wraps an [`Arc<JsonFrontend>`] and turns each widget call into a
//! `select` server event followed by a blocking wait on a matching
//! `select_response` client event (routed by [`super::router::EventRouter`]).
//!
//! The four trait methods map onto the protocol as follows:
//!
//! | Trait method | Wire shape |
//! |---|---|
//! | `select`  | `select { multi: false, options: [...] }` → response is the chosen value (matched against `options` to recover an index) |
//! | `multi`   | `select { multi: true, options: [...] }` → response is a comma-separated list of chosen values |
//! | `input`   | `select { multi: false, options: [], prompt }` → response is free-text |
//! | `confirm` | `select { multi: false, options: ["yes","no"], default }` → response is `"yes"`/`"no"`/`"y"`/`"n"` (case-insensitive) |

use std::sync::Arc;

use anyhow::Result;
use forge_select::SelectorBackend;

use super::orchestrator::JsonFrontend;

/// Bridge from `forge_select` widget calls into JSON `select` events.
pub struct JsonSelectorBackend(Arc<JsonFrontend>);

impl JsonSelectorBackend {
    /// Wraps `frontend`. Cheap; just clones the `Arc`.
    pub fn new(frontend: Arc<JsonFrontend>) -> Self {
        Self(frontend)
    }
}

impl SelectorBackend for JsonSelectorBackend {
    fn select(
        &self,
        prompt: &str,
        options: &[String],
        default: Option<&str>,
    ) -> Result<Option<usize>> {
        let response =
            self.0
                .request_select(prompt, options.to_vec(), false, default.unwrap_or(""))?;
        Ok(response.and_then(|value| match_option(options, &value)))
    }

    fn multi(
        &self,
        prompt: &str,
        options: &[String],
        defaults: &[bool],
    ) -> Result<Option<Vec<usize>>> {
        // Encode preselected options as a comma-separated default. The
        // protocol leaves the exact format of `default` open; this
        // matches the multi-select response format so clients can
        // round-trip a selection symmetrically.
        let default_value = options
            .iter()
            .zip(defaults.iter().chain(std::iter::repeat(&false)))
            .filter_map(|(opt, &flag)| if flag { Some(opt.as_str()) } else { None })
            .collect::<Vec<_>>()
            .join(",");

        let response = self
            .0
            .request_select(prompt, options.to_vec(), true, &default_value)?;
        Ok(response.map(|value| {
            value
                .split(',')
                .map(|chunk| chunk.trim())
                .filter(|chunk| !chunk.is_empty())
                .filter_map(|chunk| match_option(options, chunk))
                .collect()
        }))
    }

    fn input(
        &self,
        prompt: &str,
        default: Option<&str>,
        allow_empty: bool,
    ) -> Result<Option<String>> {
        let response = self
            .0
            .request_select(prompt, Vec::new(), false, default.unwrap_or(""))?;
        Ok(response.and_then(|value| {
            if value.is_empty() && !allow_empty {
                default.map(str::to_string)
            } else {
                Some(value)
            }
        }))
    }

    fn confirm(&self, prompt: &str, default: Option<bool>) -> Result<Option<bool>> {
        let default_str = match default {
            Some(true) => "yes",
            Some(false) => "no",
            None => "",
        };
        let response =
            self.0
                .request_select(prompt, vec!["yes".into(), "no".into()], false, default_str)?;
        Ok(response.and_then(|value| parse_yes_no(&value, default)))
    }
}

/// Resolves `value` to an index into `options`, accepting either:
/// - a 1-based numeric index (e.g. `"2"`) — for clients that mirror the
///   line-prompt fallback's UI style;
/// - the option label itself (case-insensitive).
fn match_option(options: &[String], value: &str) -> Option<usize> {
    let trimmed = value.trim();
    if let Ok(n) = trimmed.parse::<usize>()
        && n >= 1
        && n <= options.len()
    {
        return Some(n - 1);
    }
    options
        .iter()
        .position(|opt| opt.eq_ignore_ascii_case(trimmed))
}

/// Parses a yes/no response, falling back to `default` for empty input.
fn parse_yes_no(value: &str, default: Option<bool>) -> Option<bool> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return default;
    }
    match trimmed.to_ascii_lowercase().as_str() {
        "y" | "yes" | "true" | "1" => Some(true),
        "n" | "no" | "false" | "0" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_match_option_by_index() {
        let options = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        let actual = match_option(&options, "2");
        let expected = Some(1);
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_match_option_by_label_case_insensitive() {
        let options = vec!["Anthropic".to_string(), "OpenAI".to_string()];
        let actual = match_option(&options, "openai");
        let expected = Some(1);
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_match_option_unknown_returns_none() {
        let options = vec!["a".to_string()];
        let actual = match_option(&options, "z");
        assert_eq!(actual, None);
    }

    #[test]
    fn test_match_option_index_out_of_range_returns_none() {
        let options = vec!["a".to_string()];
        // 0 is invalid (1-based), 5 is out of range.
        assert_eq!(match_option(&options, "0"), None);
        assert_eq!(match_option(&options, "5"), None);
    }

    #[test]
    fn test_parse_yes_no_accepts_common_forms() {
        assert_eq!(parse_yes_no("y", None), Some(true));
        assert_eq!(parse_yes_no("yes", None), Some(true));
        assert_eq!(parse_yes_no("YES", None), Some(true));
        assert_eq!(parse_yes_no("n", None), Some(false));
        assert_eq!(parse_yes_no("no", None), Some(false));
        assert_eq!(parse_yes_no("NO", None), Some(false));
    }

    #[test]
    fn test_parse_yes_no_uses_default_for_empty() {
        assert_eq!(parse_yes_no("", Some(true)), Some(true));
        assert_eq!(parse_yes_no("  ", Some(false)), Some(false));
        assert_eq!(parse_yes_no("", None), None);
    }

    #[test]
    fn test_parse_yes_no_rejects_garbage() {
        assert_eq!(parse_yes_no("maybe", Some(true)), None);
        assert_eq!(parse_yes_no("yup", None), None);
    }
}
