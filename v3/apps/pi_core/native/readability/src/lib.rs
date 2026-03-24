use readabilityrs::Readability;
use std::collections::HashMap;

/// Extract readable content from HTML.
/// Returns Result<HashMap, String> which Rustler auto-encodes as {:ok, map} / {:error, string}.
#[rustler::nif]
fn extract(html: String) -> Result<HashMap<String, String>, String> {
    match Readability::new(&html, None, None) {
        Ok(reader) => {
            match reader.parse() {
                Some(article) => {
                    let title = article.title.unwrap_or_default();
                    // article.content is Option<String> with HTML — strip tags to get plain text
                    let text = strip_html_tags(&article.content.unwrap_or_default());
                    let excerpt = article.byline.unwrap_or_default();

                    let mut map = HashMap::new();
                    map.insert("title".to_string(), title);
                    map.insert("text".to_string(), text);
                    map.insert("excerpt".to_string(), excerpt);
                    Ok(map)
                }
                None => Err("Readability extraction returned no content".to_string())
            }
        }
        Err(e) => Err(format!("Parse error: {:?}", e))
    }
}

/// Strip all HTML tags, returning plain text. Fallback when Readability fails.
#[rustler::nif]
fn strip_tags(html: String) -> String {
    strip_html_tags(&html)
}

fn strip_html_tags(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut in_tag = false;
    let mut in_script = false;
    let mut tag_name = String::new();

    for c in html.chars() {
        if c == '<' {
            in_tag = true;
            tag_name.clear();
            continue;
        }
        if in_tag {
            if c == '>' {
                in_tag = false;
                let lower = tag_name.to_lowercase();
                if lower == "script" || lower == "style" {
                    in_script = true;
                } else if lower == "/script" || lower == "/style" {
                    in_script = false;
                }
                tag_name.clear();
            } else if c != '/' || tag_name.is_empty() {
                if c != ' ' && tag_name.len() < 20 {
                    tag_name.push(c);
                }
            }
            continue;
        }
        if !in_script {
            result.push(c);
        }
    }

    let mut collapsed = String::with_capacity(result.len());
    let mut last_was_ws = false;
    for c in result.chars() {
        if c.is_whitespace() {
            if !last_was_ws {
                collapsed.push('\n');
                last_was_ws = true;
            }
        } else {
            collapsed.push(c);
            last_was_ws = false;
        }
    }

    collapsed.trim().to_string()
}

rustler::init!("Elixir.PiCore.Native.Readability");
