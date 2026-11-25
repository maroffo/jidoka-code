// ABOUTME: Renders the Markdown a review model writes as HTML that is safe to place in a report page.
// ABOUTME: Raw HTML becomes text, only web links survive, images never load, and file:line citations can link.

//! Reviewer prose is untrusted: it comes from a model that read third-party code.

use pulldown_cmark::{CowStr, Event, Options, Parser, Tag, TagEnd, TextMergeStream, html};

/// Resolve a `path:line` citation to a link target, or decline to link it.
pub type Cite<'a> = &'a dyn Fn(&str, usize) -> Option<String>;

fn escape_attribute(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#x27;"),
            other => escaped.push(other),
        }
    }
    escaped
}

fn events(source: &str) -> impl Iterator<Item = Event<'_>> {
    TextMergeStream::new(Parser::new_ext(
        source,
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH,
    ))
}

fn web_link(destination: &str) -> bool {
    let lower = destination.to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://")
}

fn path_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"_./-".contains(&byte)
}

/// Split text around the `path:line` citations the resolver accepts.
fn cited<'a>(text: &str, cite: Cite<'_>, out: &mut Vec<Event<'a>>) {
    let bytes = text.as_bytes();
    let mut plain = 0;
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] != b':' {
            at += 1;
            continue;
        }
        let mut start = at;
        while start > plain && path_byte(bytes[start - 1]) {
            start -= 1;
        }
        let mut end = at + 1;
        while end < bytes.len() && bytes[end].is_ascii_digit() {
            end += 1;
        }
        let path = &text[start..at];
        let target = text[at + 1..end]
            .parse::<usize>()
            .ok()
            .filter(|_| path.contains(['.', '/']))
            .and_then(|line| cite(path, line));
        match target {
            Some(href) => {
                if start > plain {
                    out.push(Event::Text(text[plain..start].to_owned().into()));
                }
                out.push(Event::Html(
                    format!(r#"<a href="{}">"#, escape_attribute(&href)).into(),
                ));
                out.push(Event::Text(text[start..end].to_owned().into()));
                out.push(Event::Html("</a>".into()));
                plain = end;
                at = end;
            }
            None => at += 1,
        }
    }
    if plain < text.len() {
        out.push(Event::Text(text[plain..].to_owned().into()));
    }
}

/// Render a block of reviewer prose: paragraphs, lists, code and tables.
///
/// A line break the model wrote stays a line break. Headings become one modest level so prose
/// cannot restructure the page.
pub fn block(source: &str, cite: Cite<'_>) -> String {
    let mut out = Vec::new();
    let mut links = Vec::new();
    let mut code = false;
    for event in events(source) {
        match event {
            Event::Html(raw) | Event::InlineHtml(raw) => out.push(Event::Text(raw)),
            Event::Start(Tag::HtmlBlock) => out.push(Event::Start(Tag::Paragraph)),
            Event::End(TagEnd::HtmlBlock) => out.push(Event::End(TagEnd::Paragraph)),
            Event::Start(Tag::Link { dest_url, .. }) => {
                let keep = web_link(&dest_url);
                links.push(keep);
                if keep {
                    out.push(Event::Html(
                        format!(
                            r#"<a href="{}" rel="noreferrer noopener">"#,
                            escape_attribute(&dest_url)
                        )
                        .into(),
                    ));
                }
            }
            Event::End(TagEnd::Link) => {
                if links.pop() == Some(true) {
                    out.push(Event::Html("</a>".into()));
                }
            }
            // The alternative text stays; nothing is fetched from a host the model chose.
            Event::Start(Tag::Image { .. }) | Event::End(TagEnd::Image) => {}
            Event::Start(Tag::Heading { .. }) => out.push(Event::Html("<h4>".into())),
            Event::End(TagEnd::Heading(_)) => out.push(Event::Html("</h4>".into())),
            Event::Start(Tag::CodeBlock(kind)) => {
                code = true;
                out.push(Event::Start(Tag::CodeBlock(kind)));
            }
            Event::End(TagEnd::CodeBlock) => {
                code = false;
                out.push(Event::End(TagEnd::CodeBlock));
            }
            Event::SoftBreak => out.push(Event::HardBreak),
            Event::Text(text) if !code && links.is_empty() => cited(&text, cite, &mut out),
            other => out.push(other),
        }
    }
    let mut rendered = String::new();
    html::push_html(&mut rendered, out.into_iter());
    rendered
}

/// Render reviewer prose for a place that takes phrasing only, such as a title or a summary.
///
/// Emphasis and inline code survive. Block structure collapses to spaces and links to their text.
pub fn inline(source: &str) -> String {
    let mut out: Vec<Event<'_>> = Vec::new();
    for event in events(source) {
        match event {
            Event::Html(raw) | Event::InlineHtml(raw) => out.push(Event::Text(raw)),
            Event::Start(Tag::Emphasis | Tag::Strong | Tag::Strikethrough)
            | Event::End(TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough)
            | Event::Text(_)
            | Event::Code(_) => out.push(event),
            Event::SoftBreak | Event::HardBreak | Event::End(_) => {
                out.push(Event::Text(CowStr::Borrowed(" ")));
            }
            _ => {}
        }
    }
    let mut rendered = String::new();
    html::push_html(&mut rendered, out.into_iter());
    rendered.trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none(_: &str, _: usize) -> Option<String> {
        None
    }

    #[test]
    fn renders_structure_and_keeps_the_line_breaks_the_model_wrote() {
        let html = block(
            "Calls `parse(v)` twice.\nSecond line.\n\n1. first\n2. **second**\n\n```go\nx := <-ch\n```\n\n# Title",
            &none,
        );
        assert!(html.contains("<p>Calls <code>parse(v)</code> twice.<br />\nSecond line.</p>"));
        assert!(html.contains("<ol>\n<li>first</li>\n<li><strong>second</strong></li>\n</ol>"));
        assert!(html.contains("<pre><code class=\"language-go\">x := &lt;-ch\n</code></pre>"));
        assert!(html.contains("<h4>Title</h4>"));
        assert!(!html.contains("<h1"));
    }

    #[test]
    fn hostile_markup_links_and_images_cannot_reach_the_page() {
        let html = block(
            "<script>alert(1)</script>\n\nsee <img src=x onerror=alert(2)> and <b>bold</b>\n\n[run](javascript:alert(3)) [data](data:text/html,x) [ok](https://example.test/?q=\"><i>)\n\n![pixel](https://tracker.test/p.png)\n\n<https://example.test/auto>",
            &none,
        );
        for forbidden in [
            "<script",
            "<img",
            "<b>",
            "<i>",
            "javascript:",
            "data:text",
            "tracker.test",
        ] {
            assert!(!html.contains(forbidden), "{forbidden}: {html}");
        }
        assert!(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"));
        assert!(html.contains(
            r#"<a href="https://example.test/?q=&quot;&gt;&lt;i&gt;" rel="noreferrer noopener">ok</a>"#
        ));
        assert!(html.contains("run") && html.contains("data") && html.contains("pixel"));
        assert!(html.contains(
            r#"<a href="https://example.test/auto" rel="noreferrer noopener">https://example.test/auto</a>"#
        ));
    }

    #[test]
    fn links_only_the_citations_the_resolver_accepts_and_never_inside_code() {
        let cite = |path: &str, line: usize| {
            (path == "internal/hub_output_strict.go").then(|| format!("#file-1-head-{line}\"x"))
        };
        let html = block(
            "At internal/hub_output_strict.go:219,404 and (other/file.go:7); `internal/hub_output_strict.go:1` at 12:30 on host:8080.",
            &cite,
        );
        assert_eq!(html.matches("<a ").count(), 1);
        assert!(html.contains(
            r##"At <a href="#file-1-head-219&quot;x">internal/hub_output_strict.go:219</a>,404 and (other/file.go:7);"##
        ));
        assert!(html.contains("<code>internal/hub_output_strict.go:1</code>"));
    }

    #[test]
    fn inline_text_keeps_phrasing_and_drops_blocks_links_and_markup() {
        assert_eq!(
            inline(
                "Trailing `id` **fails** <script>x</script> [docs](https://example.test)\n\n- item"
            ),
            "Trailing <code>id</code> <strong>fails</strong> &lt;script&gt;x&lt;/script&gt; docs  item"
        );
        assert_eq!(
            inline("plain_snake_case and 2 * 3 * 4"),
            "plain_snake_case and 2 * 3 * 4"
        );
    }
}
