// Markdown from a bot's files (SOUL.md, memory, skills) as HTML the panel can
// show. The bot wrote these, so nothing it wrote may become markup of its own:
// marked renders, then only an allowlist of elements survives, with no
// attribute but a link's http(s) href. The page's policy (no inline script)
// is the second fence, not the first.

import { marked } from "marked"

const allowed = new Set([
  "P", "BR", "HR", "H1", "H2", "H3", "H4", "H5", "H6", "STRONG", "EM", "DEL", "CODE", "PRE",
  "BLOCKQUOTE", "UL", "OL", "LI", "A", "TABLE", "THEAD", "TBODY", "TR", "TH", "TD",
])

function clean(node: Node) {
  for (const child of Array.from(node.childNodes)) {
    if (child.nodeType === Node.TEXT_NODE) continue
    if (child.nodeType !== Node.ELEMENT_NODE) {
      child.remove()
      continue
    }
    const el = child as Element
    if (!allowed.has(el.tagName)) {
      // Keep the text, drop the element.
      el.replaceWith(document.createTextNode(el.textContent ?? ""))
      continue
    }
    const href = el.tagName === "A" ? el.getAttribute("href") : null
    for (const attr of Array.from(el.attributes)) el.removeAttribute(attr.name)
    if (href && /^https?:\/\//i.test(href)) el.setAttribute("href", href)
    clean(el)
  }
}

export function render(source: string): string {
  const html = marked.parse(source, { async: false, gfm: true, breaks: true }) as string
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, "text/html")
  clean(doc.body)
  return doc.body.innerHTML
}
