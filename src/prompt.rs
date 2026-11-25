//! The web editor and AGY runner share one plain-text prompt.
pub const MAX_PROMPT_BYTES: usize = 64 * 1024;

pub fn default_prompt() -> String {
    from_legacy_method(include_str!("../runner/review-method.txt"))
}

/// Preserve the instructions used before the editor exposed the whole prompt.
pub fn from_legacy_method(method: &str) -> String {
    format!(
        "{}\nReviewer instructions:\n{}\n\nThe review workspace is ./workspace.",
        include_str!("../runner/prompt.txt").trim_end(),
        method.trim()
    )
}

pub fn valid(prompt: &str) -> bool {
    !prompt.trim().is_empty()
        && prompt.len() <= MAX_PROMPT_BYTES
        && !prompt
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\r' | '\n' | '\t'))
}
