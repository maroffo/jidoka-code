//! Pull requests ordered by their most recent review, with earlier runs kept in reach.
use super::*;

#[derive(Default, serde::Deserialize)]
#[serde(default)]
pub(super) struct HistoryQuery {
    q: String,
    page: usize,
}

pub(super) fn subject(connection: &Connection, id: i64) -> rusqlite::Result<Option<String>> {
    let title: Option<String> = connection.query_row(
        "SELECT coalesce((SELECT subject FROM review_subjects WHERE review_id=?1),(SELECT CASE WHEN json_valid(snapshot) THEN CASE WHEN json_type(snapshot, '$.intent[0]')='text' THEN substr(json_extract(snapshot, '$.intent[0]'),1,240) END END FROM review_runs WHERE review_id=?1))",
        [id], |row| row.get(0),
    )?;
    Ok(title.and_then(|s| {
        s.strip_prefix("Commit message\n")
            .unwrap_or(&s)
            .lines()
            .next()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    }))
}

/// The signal tone and the words beside it for one run. The words carry the outcome on their own.
fn outcome(status: &str, score: Option<i64>, findings: Option<usize>) -> (&'static str, String) {
    let count = |n: usize| match n {
        1 => "1 finding".to_owned(),
        n => format!("{n} findings"),
    };
    match (status, score, findings) {
        ("completed", Some(n), _) if n >= 90 => ("clear", format!("{n}/100 · Ready to merge")),
        ("completed", Some(n), _) => ("stop", format!("{n}/100 · Hold merge")),
        ("completed", None, Some(0)) => ("clear", "No findings".into()),
        ("completed", None, Some(n)) => ("stop", count(n)),
        ("partial", _, Some(n)) if n > 0 => ("stop", format!("Review incomplete · {}", count(n))),
        ("partial", _, _) => ("hold", "Review incomplete".into()),
        ("queued" | "running", _, _) => ("busy", status_label(status).into()),
        _ => ("off", status_label(status).into()),
    }
}

/// Name a UTC day relative to today, falling back to the weekday and date.
fn day_label(day: &str, today: &str, yesterday: &str) -> String {
    if day == today {
        return "Today".into();
    }
    if day == yesterday {
        return "Yesterday".into();
    }
    let mut parts = day.splitn(3, '-').map(|part| part.parse::<usize>().ok());
    let (Some(Some(year)), Some(Some(month)), Some(Some(date))) =
        (parts.next(), parts.next(), parts.next())
    else {
        return day.to_owned();
    };
    if !(1..=12).contains(&month) {
        return day.to_owned();
    }
    // Sakamoto's method for the Gregorian weekday.
    let shifted = if month < 3 {
        year.saturating_sub(1)
    } else {
        year
    };
    let weekday = (shifted + shifted / 4 - shifted / 100
        + shifted / 400
        + [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4][month - 1]
        + date)
        % 7;
    let weekday = [
        "Sunday",
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
    ][weekday];
    let month = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ][month - 1];
    if today.starts_with(&format!("{year:04}-")) {
        format!("{weekday} {date} {month}")
    } else {
        format!("{weekday} {date} {month} {year}")
    }
}

/// Render one pull request and return it with the UTC day of its latest run.
fn run_rows(db: &Connection, key: &str, latest: i64) -> rusqlite::Result<(String, String)> {
    let mut stmt = db.prepare("SELECT id,url,status,created_at,error,
        CASE WHEN json_valid(report) THEN json_array_length(report,'$.findings') END,
        CASE WHEN json_valid(report) THEN CASE WHEN json_type(report,'$.mergeability_score')='integer'
          AND coalesce(json_array_length(report,'$.limits'),0)=0 AND coalesce(json_array_length(report,'$.scan.limits'),0)=0
          THEN json_extract(report,'$.mergeability_score') END END,
        EXISTS(SELECT 1 FROM review_prompts p WHERE p.review_id=reviews.id AND p.dry_run)
        FROM reviews WHERE lower(rtrim(url,'/'))=? ORDER BY id DESC")?;
    let mut rows = stmt.query([key])?;
    let mut primary = String::new();
    let mut earlier = String::new();
    let mut count = 0;
    let mut day = String::new();
    let title = subject(db, latest)?;
    while let Some(row) = rows.next()? {
        let id: i64 = row.get(0)?;
        let url: String = row.get(1)?;
        let stored: String = row.get(2)?;
        let created: String = row.get(3)?;
        let error: Option<String> = row.get(4)?;
        let (status, _) = displayed_status(db, id, &stored, error.as_deref())?;
        let findings = row.get::<_, Option<usize>>(5)?;
        let score = row
            .get::<_, Option<i64>>(6)?
            .filter(|n| (0..=100).contains(n) && status == "completed");
        let (tone, words) = outcome(status, score, findings);
        // A scored row leads with the recommendation, so its finding count moves below.
        let detail = match (score, findings) {
            (Some(_), Some(1)) => "1 finding".to_owned(),
            (Some(_), Some(n)) => format!("{n} findings"),
            _ => String::new(),
        };
        let kind = if row.get::<_, bool>(7)? {
            "Dry run"
        } else {
            "Review"
        };
        let name = parse_pull_url(&url).map_or_else(
            || escape(&url),
            |(repo, number)| format!("{} <b>#{number}</b>", escape(repo)),
        );
        let subject = title.as_deref().filter(|_| id == latest).map(escape);
        let headline = subject.as_deref().unwrap_or(&name);
        let repo = if subject.is_some() {
            format!("{name} · ")
        } else {
            String::new()
        };
        // The day heading already dates the latest run; earlier runs can be older.
        let (dst, when) = if id == latest {
            day = created.get(..10).unwrap_or(&created).to_owned();
            (&mut primary, created.get(11..16).unwrap_or(&created))
        } else {
            count += 1;
            (&mut earlier, created.get(..16).unwrap_or(&created))
        };
        write!(dst,r#"<a class="history-row" href="/reviews/{id}">{}<span class="pr-identity"><strong>{headline}</strong><small>{repo}{kind} {id}</small></span><span class="row-outcome {tone}">{} <span class="diff-sr-only">{}</span><small>{detail}</small></span><time class="row-when">{} UTC</time></a>"#,lamp(tone),escape(&words),status_label(status),escape(when)).unwrap();
    }
    if count > 0 {
        let noun = if count == 1 { "run" } else { "runs" };
        write!(primary,r#"<details class="earlier"><summary>{count} earlier {noun}</summary>{earlier}</details>"#).unwrap();
    }
    Ok((day, format!("<li>{primary}</li>")))
}

pub(super) fn history(db: &Connection, query: &HistoryQuery) -> rusqlite::Result<String> {
    const PAGE: usize = 20;
    let term = query.q.trim();
    let number = term
        .strip_prefix('#')
        .filter(|v| !v.is_empty() && v.bytes().all(|c| c.is_ascii_digit()));
    let needle = number.map_or_else(|| term.to_lowercase(), |n| format!("/pull/{n}"));
    let matches = if number.is_some() {
        "substr(lower(rtrim(url,'/')), -length(?1))=?1"
    } else {
        "instr(lower(url),?1)>0"
    };
    let total: usize = db.query_row(
        &format!("SELECT count(DISTINCT lower(rtrim(url,'/'))) FROM reviews WHERE {matches}"),
        [&needle],
        |r| r.get(0),
    )?;
    let pages = total.div_ceil(PAGE).max(1);
    let page = query.page.clamp(1, pages);
    let mut stmt = db.prepare(&format!("SELECT lower(rtrim(url,'/')) AS pr,max(id) AS latest FROM reviews WHERE {matches} GROUP BY pr ORDER BY latest DESC LIMIT ?2 OFFSET ?3"))?;
    let mut rows = stmt.query(params![needle, PAGE, (page - 1) * PAGE])?;
    let (today, yesterday): (String, String) =
        db.query_row("SELECT date('now'), date('now','-1 day')", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?;
    let mut items = String::new();
    let mut current: Option<String> = None;
    while let Some(row) = rows.next()? {
        let (day, item) = run_rows(db, &row.get::<_, String>(0)?, row.get(1)?)?;
        if current.as_deref() != Some(&day) {
            if current.is_some() {
                items.push_str("</ul>");
            }
            write!(
                items,
                r#"<h3 class="day">{}</h3><ul class="history-list">"#,
                escape(&day_label(&day, &today, &yesterday))
            )
            .unwrap();
            current = Some(day);
        }
        items.push_str(&item);
    }
    if current.is_some() {
        items.push_str("</ul>");
    }
    let form = format!(
        r#"<form class="pr-search" method="get" action="/"><label class="diff-sr-only" for="q">Search by repository or PR number</label><input id="q" type="search" name="q" placeholder="Repository or #PR" value="{}"><button>Search</button></form>"#,
        escape(term)
    );
    let clear = if term.is_empty() {
        ""
    } else {
        r#"<a href="/">Clear search</a>"#
    };
    let listing = if total == 0 {
        if term.is_empty() {
            "<p class=empty>No reviews yet.</p>".into()
        } else {
            "<p class=empty>No matching pull requests.</p>".into()
        }
    } else {
        items
    };
    let mut paging = String::new();
    if pages > 1 {
        let link = |p: usize| {
            escape(
                &url::form_urlencoded::Serializer::new(String::from("/?"))
                    .append_pair("q", term)
                    .append_pair("page", &p.to_string())
                    .finish(),
            )
        };
        if page > 1 {
            write!(paging, r#"<a href="{}">← Previous</a>"#, link(page - 1)).unwrap();
        }
        write!(paging, "<span>Page {page} of {pages}</span>").unwrap();
        if page < pages {
            write!(paging, r#"<a href="{}">Next →</a>"#, link(page + 1)).unwrap();
        }
        paging = format!(r#"<nav class="paging" aria-label="History pages">{paging}</nav>"#);
    }
    Ok(format!(
        r#"<div class="list-toolbar"><h2>Pull requests <span>{total}</span></h2><div>{form}{clear}</div></div>{listing}{paging}"#
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_outcome_reads_without_its_signal_and_days_are_named_in_utc() {
        for (status, score, findings, tone, words) in [
            (
                "completed",
                Some(90),
                Some(2),
                "clear",
                "90/100 · Ready to merge",
            ),
            (
                "completed",
                Some(89),
                Some(0),
                "stop",
                "89/100 · Hold merge",
            ),
            ("completed", None, Some(0), "clear", "No findings"),
            ("completed", None, Some(1), "stop", "1 finding"),
            ("completed", None, None, "off", "Completed"),
            (
                "partial",
                None,
                Some(2),
                "stop",
                "Review incomplete · 2 findings",
            ),
            ("partial", None, Some(0), "hold", "Review incomplete"),
            ("running", None, None, "busy", "In progress"),
            ("canceled", None, None, "off", "Canceled"),
            ("failed", None, None, "off", "Failed"),
        ] {
            assert_eq!(
                outcome(status, score, findings),
                (tone, words.to_owned()),
                "{status}"
            );
        }
        let (today, yesterday) = ("2026-11-25", "2026-11-24");
        assert_eq!(day_label("2026-11-25", today, yesterday), "Today");
        assert_eq!(day_label("2026-11-24", today, yesterday), "Yesterday");
        assert_eq!(
            day_label("2026-11-23", today, yesterday),
            "Monday 23 November"
        );
        assert_eq!(
            day_label("2026-01-01", today, yesterday),
            "Thursday 1 January"
        );
        assert_eq!(
            day_label("2024-02-29", today, yesterday),
            "Thursday 29 February 2024"
        );
        assert_eq!(day_label("unknown", today, yesterday), "unknown");
    }

    #[test]
    fn dashboard_groups_runs_preserves_subject_and_matches_exact_pr_numbers() {
        let db = Connection::open_in_memory().unwrap();
        init_db(&db).unwrap();
        for (id, url) in [
            (1, "https://github.com/org/repo/pull/1"),
            (2, "https://github.com/Org/Repo/pull/1/"),
            (3, "https://github.com/org/repo/pull/12"),
        ] {
            db.execute(
                "INSERT INTO reviews(id,url,provider,status) VALUES(?,?,'test','completed')",
                params![id, url],
            )
            .unwrap();
        }
        db.execute(
            "INSERT INTO review_runs(review_id,snapshot) VALUES(2,?)",
            [r#"{"intent":["Fix <parser>\nMore detail"]}"#],
        )
        .unwrap();
        db.execute(
            "INSERT INTO review_runs(review_id,snapshot) VALUES(1,?)",
            [r#"{"intent":["Commit message\nHandle retries\nLonger details"]}"#],
        )
        .unwrap();
        assert_eq!(subject(&db, 1).unwrap().as_deref(), Some("Handle retries"));
        session::finish(&db, 2, "completed", "done").unwrap();
        assert_eq!(subject(&db, 2).unwrap().as_deref(), Some("Fix <parser>"));
        let html = history(
            &db,
            &HistoryQuery {
                q: "#1".into(),
                page: 999,
            },
        )
        .unwrap();
        assert!(html.contains("Fix &lt;parser&gt;"));
        assert_eq!(html.matches(r#"<h3 class="day">Today</h3>"#).count(), 1);
        assert!(html.contains(r#"<span class="lamp off" aria-hidden="true"></span>"#));
        assert!(html.contains(r#"<span class="diff-sr-only">Completed</span>"#));
        assert!(html.contains("1 earlier run"));
        assert!(html.find("/reviews/2").unwrap() < html.find("/reviews/1").unwrap());
        assert!(!html.contains("/reviews/3"));
        for n in 20..42 {
            db.execute(
                "INSERT INTO reviews(url,provider,status) VALUES(?,'test','completed')",
                [format!("https://github.com/org/repo/pull/{n}")],
            )
            .unwrap();
        }
        let page = history(
            &db,
            &HistoryQuery {
                q: "Org/Repo".into(),
                page: 2,
            },
        )
        .unwrap();
        assert!(page.contains("Page 2 of 2"));
        assert_eq!(page.matches(r#"<ul class="history-list">"#).count(), 1);
        assert!(page.contains("1 earlier run"));
        assert!(!page.contains("/reviews/25"));
    }
}
