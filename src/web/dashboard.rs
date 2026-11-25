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
        "SELECT coalesce((SELECT subject FROM review_subjects WHERE review_id=?1),(SELECT CASE WHEN json_valid(snapshot) THEN substr(json_extract(snapshot, '$.intent[0]'),1,240) END FROM review_runs WHERE review_id=?1))",
        [id], |row| row.get(0),
    )?;
    Ok(title.and_then(|s| {
        s.lines()
            .next()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    }))
}

fn run_rows(db: &Connection, key: &str, latest: i64) -> rusqlite::Result<String> {
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
    let title = subject(db, latest)?;
    while let Some(row) = rows.next()? {
        let id: i64 = row.get(0)?;
        let url: String = row.get(1)?;
        let stored: String = row.get(2)?;
        let created: String = row.get(3)?;
        let error: Option<String> = row.get(4)?;
        let (status, _) = displayed_status(db, id, &stored, error.as_deref())?;
        let findings = match row.get::<_, Option<usize>>(5)? {
            Some(1) => "1 finding".into(),
            Some(n) => format!("{n} findings"),
            None => String::new(),
        };
        let score = row
            .get::<_, Option<i64>>(6)?
            .filter(|n| (0..=100).contains(n) && status == "completed");
        let result = match score {
            Some(n) => format!(
                r#"<span class="recommend {}">{n}/100 · {}</span><span class="diff-sr-only">{}</span>"#,
                if n >= 90 { "ready" } else { "hold" },
                if n >= 90 {
                    "Ready to merge"
                } else {
                    "Hold merge"
                },
                status_label(status)
            ),
            None => status_badge(status),
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
        let dst = if id == latest {
            &mut primary
        } else {
            count += 1;
            &mut earlier
        };
        write!(dst,r#"<a class="history-row" href="/reviews/{id}"><span class="pr-identity"><strong>{headline}</strong><small>{repo}{kind} {id} · {} UTC</small></span><span class="row-outcome">{result}<small>{findings}</small></span><span class="arrow" aria-hidden="true">›</span></a>"#,escape(created.get(..16).unwrap_or(&created))).unwrap();
    }
    if count > 0 {
        let noun = if count == 1 { "run" } else { "runs" };
        write!(primary,r#"<details class="earlier"><summary>{count} earlier {noun}</summary>{earlier}</details>"#).unwrap();
    }
    Ok(format!("<li>{primary}</li>"))
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
    let mut items = String::new();
    while let Some(row) = rows.next()? {
        items.push_str(&run_rows(db, &row.get::<_, String>(0)?, row.get(1)?)?);
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
        format!(r#"<ul class="history-list">{items}</ul>"#)
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
        assert!(page.contains("1 earlier run"));
        assert!(!page.contains("/reviews/25"));
    }
}
