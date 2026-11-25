//! Shared by the prompt preview and the executable that calls AGY.
pub const DEFAULT_METHOD: &str = include_str!("../runner/review-method.txt");
pub const MAX_METHOD_BYTES: usize = 8192;

pub fn valid(method: &str) -> bool {
    !method.trim().is_empty()
        && method.len() <= MAX_METHOD_BYTES
        && !method
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\r' | '\n' | '\t'))
}

pub fn render(method: &str, workspace: &str) -> String {
    format!(
        "{}\nReviewer instructions:\n{}\n\nThe review workspace is {workspace}.",
        include_str!("../runner/prompt.txt").trim_end(),
        method.trim()
    )
}
