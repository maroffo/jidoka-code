//! Parse the hunk-only patches returned for individual files.

use crate::contracts::SNAPSHOT_TEXT_BYTES;
const NO_NEWLINE: &str = "\\ No newline at end of file";
type Line<'patch> = (Option<usize>, Option<usize>, &'patch str);

struct Range {
    start: usize,
    end: usize,
    position: usize,
}

impl Range {
    fn parse(input: &str) -> Option<Self> {
        let (start, count) = input.split_once(',').unwrap_or((input, "1"));
        let start = decimal(start)?;
        let count = decimal(count)?;
        // A nonempty range names its first line. An empty range names the line before it.
        let start = if count == 0 {
            start
        } else {
            start.checked_sub(1)?
        };
        let end = start.checked_add(count)?;
        Some(Self {
            start,
            end,
            position: start,
        })
    }

    fn take(&mut self) -> Option<usize> {
        if self.done() {
            return None;
        }
        self.position += 1;
        Some(self.position)
    }

    fn done(&self) -> bool {
        self.position == self.end
    }

    fn follows(&self, previous: &Self, ended: bool) -> bool {
        self.start >= previous.end
            && (self.start, self.end) != (previous.start, previous.end)
            && (!ended || (self.start == previous.end && self.start == self.end))
    }
}

fn decimal(input: &str) -> Option<usize> {
    if input.is_empty() || !input.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    input.parse().ok()
}

struct Hunk {
    base: Range,
    head: Range,
}

impl Hunk {
    fn parse(header: &str) -> Option<Self> {
        let (base, rest) = header.strip_prefix("@@ -")?.split_once(" +")?;
        let (head, section) = rest.split_once(" @@")?;
        if !section.is_empty() && !section.starts_with(' ') {
            return None;
        }
        let hunk = Self {
            base: Range::parse(base)?,
            head: Range::parse(head)?,
        };
        (!hunk.done()).then_some(hunk)
    }

    fn done(&self) -> bool {
        self.base.done() && self.head.done()
    }
}

/// Return original 1-based base and head positions with the exact borrowed line text.
/// An empty patch returns an empty vector. An invalid or incomplete patch returns None.
pub(crate) fn lines(patch: &str) -> Option<Vec<Line<'_>>> {
    if patch.len() > SNAPSHOT_TEXT_BYTES {
        return None;
    }

    let mut rows = Vec::new();
    let mut hunk: Option<Hunk> = None;
    let mut last_line = None;
    let (mut base_ended, mut head_ended) = (false, false);

    for raw in patch.split_terminator('\n') {
        // Allow CRLF on structural lines without stripping a CR from source text.
        let syntax = raw.strip_suffix('\r').unwrap_or(raw);
        if syntax.starts_with("@@") {
            let next = Hunk::parse(syntax)?;
            if let Some(previous) = hunk.as_ref()
                && (!previous.done()
                    || !next.base.follows(&previous.base, base_ended)
                    || !next.head.follows(&previous.head, head_ended))
            {
                return None;
            }
            hunk = Some(next);
            last_line = None;
            continue;
        }

        let current = hunk.as_mut()?;
        if syntax == NO_NEWLINE {
            let (base, head) = last_line.take()?;
            if (base && !current.base.done()) || (head && !current.head.done()) {
                return None;
            }
            base_ended |= base;
            head_ended |= head;
            continue;
        }

        let (marker, text) = raw.split_at_checked(1)?;
        let (base, head) = match marker {
            " " => (Some(current.base.take()?), Some(current.head.take()?)),
            "-" => (Some(current.base.take()?), None),
            "+" => (None, Some(current.head.take()?)),
            _ => return None,
        };
        last_line = Some((base.is_some(), head.is_some()));
        rows.push((base, head, text));
    }
    hunk.is_none_or(|hunk| hunk.done()).then_some(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_multiple_hunks_in_patch_order() {
        let patch = "@@ -9,4 +9,5 @@ section @@\n keep\n-old\n+new one\n+new two\n same\n tail\n\
                     @@ -30,2 +31 @@\n-gone\n final";
        assert_eq!(
            lines(patch).unwrap(),
            [
                (Some(9), Some(9), "keep"),
                (Some(10), None, "old"),
                (None, Some(10), "new one"),
                (None, Some(11), "new two"),
                (Some(11), Some(12), "same"),
                (Some(12), Some(13), "tail"),
                (Some(30), None, "gone"),
                (Some(31), Some(31), "final"),
            ]
        );
    }

    #[test]
    fn supports_sparse_offsets_and_the_largest_representable_line() {
        let last = usize::MAX;
        let patch = format!(
            "@@ -1 +1 @@\n-a\n+b\n@@ -{last} +{} @@\n-old\n+new",
            last - 1
        );
        assert_eq!(
            lines(&patch).unwrap(),
            [
                (Some(1), None, "a"),
                (None, Some(1), "b"),
                (Some(last), None, "old"),
                (None, Some(last - 1), "new"),
            ]
        );
    }

    #[test]
    fn supports_additions_deletions_empty_input_and_adjacent_ranges() {
        assert_eq!(lines("").unwrap(), []);
        assert_eq!(
            lines("@@ -0,0 +1,2 @@\n+\n+new\n").unwrap(),
            [(None, Some(1), ""), (None, Some(2), "new")]
        );
        assert_eq!(
            lines("@@ -1,2 +0,0 @@\n-old\n-\n").unwrap(),
            [(Some(1), None, "old"), (Some(2), None, "")]
        );
        let patch = "@@ -3 +3 @@\n-old\n+new\n@@ -3,0 +4 @@\n+later\n@@ -4 +5 @@\n-a\n+b";
        assert_eq!(
            lines(patch).unwrap(),
            [
                (Some(3), None, "old"),
                (None, Some(3), "new"),
                (None, Some(4), "later"),
                (Some(4), None, "a"),
                (None, Some(5), "b"),
            ]
        );
    }

    #[test]
    fn preserves_fake_headers_markers_whitespace_and_cr_in_line_text() {
        let patch = "@@ -8,2 +8,3 @@\r\n-@@ -1 +1 @@\r\n+@@ -0,0 +1 @@\n\
                     +\\ No newline at end of file\n \t café  \r\n";
        assert_eq!(
            lines(patch).unwrap(),
            [
                (Some(8), None, "@@ -1 +1 @@\r"),
                (None, Some(8), "@@ -0,0 +1 @@"),
                (None, Some(9), NO_NEWLINE),
                (Some(9), Some(10), "\t café  \r"),
            ]
        );
    }

    #[test]
    fn skips_no_newline_annotations_for_either_side_or_context() {
        let patch = format!("@@ -1 +1 @@\n-old\n{NO_NEWLINE}\n+new\n{NO_NEWLINE}");
        assert_eq!(
            lines(&patch).unwrap(),
            [(Some(1), None, "old"), (None, Some(1), "new")]
        );
        let patch = format!("@@ -1,2 +1,2 @@\n-a\n+b\n shared\n{NO_NEWLINE}");
        assert_eq!(lines(&patch).unwrap()[2], (Some(2), Some(2), "shared"));
    }

    #[test]
    fn rejects_malformed_headers_rows_and_counts() {
        for patch in [
            "diff --git a/a b/a\n@@ -1 +1 @@\n-a\n+b",
            "+no header",
            "\n",
            "@@ -1 +1 @\n-a\n+b",
            "@@ -1 +1 @@section\n-a\n+b",
            "@@ -1, +1 @@\n-a\n+b",
            "@@ -1  +1 @@\n-a\n+b",
            "@@ -+1 +1 @@\n-a\n+b",
            "@@ -1,-1 +1 @@\n-a\n+b",
            "@@ -0 +1 @@\n-a\n+b",
            "@@ -1 +0,1 @@\n-a\n+b",
            "@@ -0,0 +0,0 @@",
            "@@ -1 +1 @@\n-a",
            "@@ -1 +1 @@\n-a\n+b\n+c",
            "@@ -1,2 +1 @@\n-a\n+b\n@@ -4 +3 @@\n-c\n+d",
            "@@ -1 +1 @@\nnot a hunk line",
            "@@ -1 +1 @@\n😀",
            "@@ -1 +1 @@\n-a\n+b\n\n",
        ] {
            assert!(lines(patch).is_none(), "accepted {patch:?}");
        }
    }

    #[test]
    fn rejects_overlapping_backward_and_duplicate_empty_ranges() {
        for patch in [
            "@@ -4 +4 @@\n-a\n+b\n@@ -4 +5 @@\n-c\n+d",
            "@@ -4 +4 @@\n-a\n+b\n@@ -5 +3 @@\n-c\n+d",
            "@@ -4,2 +4 @@\n-a\n-b\n+c\n@@ -5,0 +5 @@\n+d\n@@ -5,0 +6 @@\n+e",
            "@@ -4,0 +5 @@\n+a\n@@ -3,0 +6 @@\n+b",
            "@@ -4 +4,0 @@\n-a\n@@ -5 +4,0 @@\n-b",
        ] {
            assert!(lines(patch).is_none(), "accepted {patch:?}");
        }
    }

    #[test]
    fn rejects_invalid_or_misplaced_no_newline_annotations() {
        for patch in [
            NO_NEWLINE.to_owned(),
            format!("@@ -1 +1 @@\n{NO_NEWLINE}\n-a\n+b"),
            format!("@@ -1 +1 @@\n-a\n{NO_NEWLINE}\n{NO_NEWLINE}\n+b"),
            format!("@@ -1,2 +1 @@\n-a\n{NO_NEWLINE}\n-b\n+c"),
            format!("@@ -1 +1 @@\n-a\n{NO_NEWLINE}\n+b\n@@ -3 +3 @@\n-c\n+d"),
            format!("@@ -1 +1 @@\n-a\n{NO_NEWLINE}\n+b\n@@ -2,0 +3 @@\n+c"),
            "@@ -1 +1 @@\n-a\n+b\n\\ unexpected annotation".to_owned(),
        ] {
            assert!(lines(&patch).is_none(), "accepted {patch:?}");
        }
    }

    #[test]
    fn rejects_overflow_and_limits_patch_bytes_without_count_based_allocations() {
        let max = usize::MAX;
        for patch in [
            format!("@@ -{max}0 +1 @@\n-a\n+b"),
            format!("@@ -{max},2 +1 @@\n-a\n-b\n+c"),
            format!("@@ -1 +1,{max}0 @@\n-a\n+b"),
            format!("@@ -1,{max} +1 @@\n-a\n+b"),
        ] {
            assert!(lines(&patch).is_none(), "accepted {patch:?}");
        }
        let header = "@@ -0,0 +1 @@\n+";
        let mut patch = format!("{header}{}", "x".repeat(SNAPSHOT_TEXT_BYTES - header.len()));
        assert_eq!(
            lines(&patch).unwrap()[0].2.len(),
            SNAPSHOT_TEXT_BYTES - header.len()
        );
        patch.push('x');
        assert!(lines(&patch).is_none());
    }
}
