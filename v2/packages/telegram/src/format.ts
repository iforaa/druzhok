function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function markdownToTelegramHtml(md: string): string {
  // Extract code blocks and inline code into placeholders to protect them
  const placeholders: string[] = [];

  let result = md;

  // Code blocks first
  result = result.replace(/```(\w+)?\n([\s\S]*?)```/g, (_, lang, code) => {
    const escaped = escapeHtml(code.replace(/\n$/, ""));
    const html = lang
      ? `<pre><code class="language-${lang}">${escaped}</code></pre>`
      : `<pre><code>${escaped}</code></pre>`;
    const idx = placeholders.length;
    placeholders.push(html);
    return `\x00${idx}\x00`;
  });

  // Inline code
  result = result.replace(/`([^`]+)`/g, (_, code) => {
    const html = `<code>${escapeHtml(code)}</code>`;
    const idx = placeholders.length;
    placeholders.push(html);
    return `\x00${idx}\x00`;
  });

  // Escape HTML in the remaining text (outside code)
  result = escapeHtml(result);

  // Bold (operates on already-escaped text)
  result = result.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>");

  // Strikethrough
  result = result.replace(/~~(.+?)~~/g, "<s>$1</s>");

  // Italic
  result = result.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, "<i>$1</i>");

  // Links — unescape href since it was HTML-escaped
  result = result.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
    // href may have been HTML-escaped, restore it
    const rawHref = href.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
    return `<a href="${rawHref}">${label}</a>`;
  });

  // Restore placeholders
  result = result.replace(/\x00(\d+)\x00/g, (_, idx) => placeholders[parseInt(idx, 10)]);

  return result;
}

export function chunkText(text: string, maxLength: number): string[] {
  if (!text) return [];
  if (text.length <= maxLength) return [text];
  const chunks: string[] = [];
  let remaining = text;
  while (remaining.length > 0) {
    if (remaining.length <= maxLength) { chunks.push(remaining); break; }
    const slice = remaining.slice(0, maxLength);
    const lastNewline = slice.lastIndexOf("\n");
    if (lastNewline > 0) {
      chunks.push(remaining.slice(0, lastNewline));
      remaining = remaining.slice(lastNewline + 1);
    } else {
      chunks.push(remaining.slice(0, maxLength));
      remaining = remaining.slice(maxLength);
    }
  }
  return chunks;
}
