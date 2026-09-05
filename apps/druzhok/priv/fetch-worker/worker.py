"""Druzhok fetch worker: HTML or PDF in, markdown out, over an Erlang Port.

Framing is {:packet, 4}: every message is a 4-byte big-endian length followed
by one JSON object. Requests are {"kind": "html"|"pdf"|"text", "url": ...,
"body_b64": ...}; replies are {"title": ..., "markdown": ...} or
{"error": "extract_failed"}. The worker has no network and no state: the
Elixir side fetched the bytes and applies every limit.
"""

import base64
import json
import re
import struct
import sys

import trafilatura

MAX_CHARS = 200_000


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


def html_title(html):
    m = re.search(r"<title[^>]*>(.*?)</title>", html, re.IGNORECASE | re.DOTALL)
    if not m:
        return ""
    return re.sub(r"\s+", " ", m.group(1)).strip()


def extract_html(url, body):
    html = body.decode("utf-8", errors="replace")
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
    return {"title": title, "markdown": text}


def extract_pdf(url, body):
    import pymupdf

    doc = pymupdf.open(stream=body, filetype="pdf")
    pages = []
    for page in doc:
        text = page.get_text("text").strip()
        if text:
            pages.append(text)
    title = (doc.metadata or {}).get("title") or url.rstrip("/").rsplit("/", 1)[-1]
    return {"title": title, "markdown": "\n\n---\n\n".join(pages)}


def extract_text(url, body):
    return {"title": url, "markdown": body.decode("utf-8", errors="replace")}


HANDLERS = {"html": extract_html, "pdf": extract_pdf, "text": extract_text}


def handle(request):
    kind = request.get("kind")
    handler = HANDLERS.get(kind)
    if handler is None:
        return {"error": "extract_failed"}
    body = base64.b64decode(request.get("body_b64", ""))
    result = handler(request.get("url", ""), body)
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
