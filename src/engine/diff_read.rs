//! Read pages of the already indexed base/head rows without rebasing their citations.
use super::*;
use std::collections::{BTreeMap, BTreeSet};

const ROWS_PER_PAGE: usize = 32;
const MAX_ROW_BYTES: usize = 4 * MAX_QUOTE;

pub(super) fn page(path: &str, term: &str) -> Option<usize> {
    if path == "*" || path.starts_with("*:") {
        return None;
    }
    if term == "#diff" {
        return Some(1);
    }
    let digits = term.strip_prefix("#diff:")?;
    if digits.starts_with('0') || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// Only rows owned by active questions are included in follow-up requests.
#[derive(Default)]
pub(super) struct DiffPages<'a> {
    requests: BTreeMap<&'a str, BTreeSet<usize>>,
    status: Vec<Value>,
}

impl<'a> DiffPages<'a> {
    pub fn new(owners: &'a HashMap<(String, String), HashSet<u64>>, active: &HashSet<u64>) -> Self {
        let mut result = Self::default();
        for ((path, term), ids) in owners {
            if !ids.is_disjoint(active)
                && let Some(number) = page(path, term)
            {
                result.requests.entry(path).or_default().insert(number);
            }
        }
        result
    }

    /// Return (section, row) selections. Pages span section boundaries but never join them.
    pub fn open(&mut self, path: &str, sections: &[Value]) -> BTreeMap<usize, Vec<Range<usize>>> {
        let mut selected = BTreeMap::<usize, Vec<Range<usize>>>::new();
        let Some(pages) = self.requests.remove(path) else {
            return selected;
        };
        let total: usize = sections
            .iter()
            .filter_map(Value::as_array)
            .map(Vec::len)
            .sum();
        for number in pages {
            let start = (number - 1).saturating_mul(ROWS_PER_PAGE);
            let end = start.saturating_add(ROWS_PER_PAGE).min(total);
            let mut offset = 0;
            let mut returned = 0;
            let mut omitted = 0;
            for (section, rows) in sections.iter().filter_map(Value::as_array).enumerate() {
                let lo = start.saturating_sub(offset).min(rows.len());
                let hi = end.saturating_sub(offset).min(rows.len());
                for (i, row) in rows.iter().enumerate().take(hi).skip(lo) {
                    // An oversized uncitable line must not consume the entire model window.
                    if row[2]
                        .as_str()
                        .is_some_and(|text| text.len() <= MAX_ROW_BYTES)
                    {
                        selected.entry(section).or_default().push(i..i + 1);
                        returned += 1;
                    } else {
                        omitted += 1;
                    }
                }
                offset += rows.len();
                if offset >= end {
                    break;
                }
            }
            self.status.push(json!({
                "path":path, "page":number, "returned_rows":returned, "oversized_rows":omitted,
                "next": (end < total).then(|| format!("#diff:{}", number+1))
            }));
        }
        selected
    }

    pub fn finish(mut self) -> Vec<Value> {
        for (path, pages) in self.requests {
            for number in pages {
                self.status
                    .push(json!({"path":path,"page":number,"returned_rows":0,"next":null}));
            }
        }
        self.status
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pages_preserve_section_boundaries_and_bound_oversized_uncitable_rows() {
        let owners = HashMap::from([(("notes".into(), "#diff".into()), HashSet::from([1]))]);
        let active = HashSet::from([1]);
        let mut pages = DiffPages::new(&owners, &active);
        let mut second = vec![json!([null, null, "x".repeat(MAX_ROW_BYTES + 1)])];
        second.extend((0..32).map(|n| json!([format!("B{n}"), null, "next"])));
        let ranges = pages.open("notes", &[json!([["B0", null, "first"]]), json!(second)]);
        assert_eq!(ranges[&0][0], 0..1);
        assert_eq!(ranges[&1].first(), Some(&(1..2)));
        assert_eq!(ranges[&1].last(), Some(&(30..31)));
        let status = pages.finish();
        assert_eq!(status[0]["oversized_rows"], 1);
        assert_eq!(status[0]["returned_rows"], 31);
        assert_eq!(status[0]["next"], "#diff:2");
        assert_eq!(page("notes", "#diff:2"), Some(2));
        assert_eq!(page("*", "#diff"), None);
        assert_eq!(page("*:13", "#diff"), None);
    }
}
