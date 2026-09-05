"""Druzhok fetch worker: HTML or PDF in, markdown out, over an Erlang Port.

Framing is {:packet, 4}: every message is a 4-byte big-endian length followed
by one JSON object. Requests are {"kind": "html"|"pdf"|"text"|"feed", "url": ...,
"body_b64": ..., "charset": <Content-Type charset or null>}; replies are {"title": ..., "markdown": ...} or
{"error": "extract_failed"}. The worker has no network and no state: the
Elixir side fetched the bytes and applies every limit.
"""

import base64
import json
import re
import struct
import sys

import trafilatura
from lxml import etree
from lxml import html as lxml_html
from trafilatura.utils import decode_file
from urllib.parse import urljoin

MAX_CHARS = 200_000

# A listing page (a feed, a category, a front page) is a set of linked
# headlines, which article extractors treat as boilerplate and drop. When the
# extraction lost at least this many of the page's headings, they are appended
# as a linked list so "what are the top stories" can still be answered.
MIN_DROPPED_HEADINGS = 3
MAX_HEADINGS = 60

# A feed is the open door on a paywalled news site: its headlines, links and
# blurbs are what a bot needs for "what's in the news", so RSS and Atom are
# read as a dated headline list rather than refused as XML.
MAX_FEED_ITEMS = 60
MAX_SUMMARY_CHARS = 300


def read_message(stream):
    header = stream.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack(">I", header)
    payload = stream.read(length)
    if len(payload) < length:
        return None
    return json.loads(payload.decode("utf-8"))


def write_message(stream, obj):
    payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    stream.write(struct.pack(">I", len(payload)))
    stream.write(payload)
    stream.flush()


META_CHARSET = re.compile(rb"""<meta[^>]+charset\s*=\s*["']?\s*([\w.:-]+)""", re.IGNORECASE)


def decode_html(body, charset):
    """The page as text: the Content-Type charset, else the <meta> one, else
    strict UTF-8, else trafilatura's detection. Legacy windows-1251 pages are
    still common on Russian sites and must not come back as mojibake."""
    candidates = [charset]
    m = META_CHARSET.search(body[:4096])
    if m:
        candidates.append(m.group(1).decode("ascii", errors="ignore"))
    candidates.append("utf-8")
    for name in candidates:
        if not name:
            continue
        try:
            return body.decode(name)
        except (LookupError, UnicodeDecodeError):
            continue
    return decode_file(body) or body.decode("utf-8", errors="replace")


def html_title(html):
    m = re.search(r"<title[^>]*>(.*?)</title>", html, re.IGNORECASE | re.DOTALL)
    if not m:
        return ""
    return re.sub(r"\s+", " ", m.group(1)).strip()


def linked_headings(html, url):
    """(title, absolute href) for every h1-h3 whose text is a link."""
    try:
        tree = lxml_html.fromstring(html)
    except Exception:  # noqa: BLE001 — unparsable markup, no appendix
        return []
    out, seen = [], set()
    for node in tree.iter("h1", "h2", "h3"):
        link = node if node.tag == "a" else node.find(".//a")
        if link is None or not link.get("href"):
            continue
        title = re.sub(r"\s+", " ", node.text_content()).strip()
        href = urljoin(url, link.get("href"))
        if len(title) < 8 or href in seen:
            continue
        seen.add(href)
        out.append((title, href))
    return out[:MAX_HEADINGS]


def headline_appendix(html, url, text):
    headings = [(t, h) for t, h in linked_headings(html, url) if t not in text]
    if len(headings) < MIN_DROPPED_HEADINGS:
        return ""
    lines = "\n".join(f"- [{t}]({h})" for t, h in headings)
    return f"\n\n## Заголовки на странице\n\n{lines}\n"


def extract_html(url, body, charset=None):
    html = decode_html(body, charset)
    text = trafilatura.extract(
        html,
        url=url,
        output_format="markdown",
        include_links=True,
        include_tables=True,
        include_comments=False,
        include_images=False,
        favor_recall=True,
    ) or ""
    meta = trafilatura.extract_metadata(html, default_url=url)
    title = (meta.title if meta and meta.title else "") or html_title(html)
    if title and not text.lstrip().startswith("#"):
        text = f"# {title}\n\n{text}"
    text += headline_appendix(html, url, text)
    return {"title": title, "markdown": text}


def extract_pdf(url, body, charset=None):
    import pymupdf

    doc = pymupdf.open(stream=body, filetype="pdf")
    pages = []
    for page in doc:
        text = page.get_text("text").strip()
        if text:
            pages.append(text)
    title = (doc.metadata or {}).get("title") or url.rstrip("/").rsplit("/", 1)[-1]
    return {"title": title, "markdown": "\n\n---\n\n".join(pages)}


def local_name(node):
    return etree.QName(node).localname if isinstance(node.tag, str) else ""


def child_text(node, *names):
    """Text of the first child whose local name is in names, HTML stripped."""
    for child in node:
        if local_name(child) in names:
            text = child.text or ""
            if child.get("type") == "xhtml":
                text = etree.tostring(child, method="text", encoding="unicode")
            return plain_text(text)
    return ""


def child_link(node, url):
    for child in node:
        if local_name(child) != "link":
            continue
        href = child.get("href") or (child.text or "").strip()
        if href and child.get("rel", "alternate") == "alternate":
            return urljoin(url, href)
    return ""


def plain_text(fragment):
    fragment = (fragment or "").strip()
    if not fragment:
        return ""
    if "<" in fragment:
        try:
            fragment = lxml_html.fromstring(fragment).text_content()
        except Exception:  # noqa: BLE001 — leave the raw text
            pass
    return re.sub(r"\s+", " ", fragment).strip()


def feed_date(node):
    raw = child_text(node, "pubDate", "published", "updated", "date")
    m = re.search(r"\d{4}-\d{2}-\d{2}", raw)
    if m:
        return m.group(0)
    try:
        from email.utils import parsedate_to_datetime

        return parsedate_to_datetime(raw).date().isoformat()
    except Exception:  # noqa: BLE001 — undated item
        return ""


def extract_feed(url, body, charset=None):
    root = etree.fromstring(body, etree.XMLParser(recover=True, huge_tree=False))
    if root is None:
        raise ValueError("not xml")
    kind = local_name(root)
    if kind == "rss":
        channel = next((c for c in root if local_name(c) == "channel"), root)
        title = child_text(channel, "title")
        items = [c for c in channel if local_name(c) == "item"]
    elif kind == "feed":
        title = child_text(root, "title")
        items = [c for c in root if local_name(c) == "entry"]
    elif kind == "RDF":
        title = next((child_text(c, "title") for c in root if local_name(c) == "channel"), "")
        items = [c for c in root if local_name(c) == "item"]
    else:
        raise ValueError("not a feed")

    lines = []
    for item in items[:MAX_FEED_ITEMS]:
        heading = child_text(item, "title") or "(без заголовка)"
        link = child_link(item, url)
        date = feed_date(item)
        line = f"- [{heading}]({link})" if link else f"- {heading}"
        if date:
            line += f" — {date}"
        summary = child_text(item, "description", "summary", "content", "encoded")
        if summary:
            line += f"\n  {summary[:MAX_SUMMARY_CHARS]}"
        lines.append(line)
    title = title or url
    return {"title": title, "markdown": f"# {title}\n\n" + "\n".join(lines)}


def extract_text(url, body, charset=None):
    return {"title": url, "markdown": decode_html(body, charset)}


HANDLERS = {"html": extract_html, "pdf": extract_pdf, "text": extract_text, "feed": extract_feed}


def handle(request):
    kind = request.get("kind")
    handler = HANDLERS.get(kind)
    if handler is None:
        return {"error": "extract_failed"}
    body = base64.b64decode(request.get("body_b64", ""))
    result = handler(request.get("url", ""), body, request.get("charset"))
    result["markdown"] = result["markdown"][:MAX_CHARS]
    return result


def main():
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    while True:
        request = read_message(stdin)
        if request is None:
            return
        try:
            reply = handle(request)
        except Exception:  # noqa: BLE001 — one bad page must not kill the worker
            reply = {"error": "extract_failed"}
        write_message(stdout, reply)


if __name__ == "__main__":
    main()
