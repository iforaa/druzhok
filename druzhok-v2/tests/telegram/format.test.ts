import { describe, it, expect } from "vitest";
import { markdownToTelegramHtml, chunkText } from "@druzhok/telegram/format.js";

describe("markdownToTelegramHtml", () => {
  it("converts bold", () => { expect(markdownToTelegramHtml("**hello**")).toBe("<b>hello</b>"); });
  it("converts italic", () => { expect(markdownToTelegramHtml("*hello*")).toBe("<i>hello</i>"); });
  it("converts inline code", () => { expect(markdownToTelegramHtml("`code`")).toBe("<code>code</code>"); });
  it("converts code blocks with language", () => {
    expect(markdownToTelegramHtml("```js\nconst x = 1;\n```")).toBe('<pre><code class="language-js">const x = 1;</code></pre>');
  });
  it("converts code blocks without language", () => {
    expect(markdownToTelegramHtml("```\nhello\n```")).toBe("<pre><code>hello</code></pre>");
  });
  it("converts links", () => {
    expect(markdownToTelegramHtml("[click](https://example.com)")).toBe('<a href="https://example.com">click</a>');
  });
  it("escapes HTML entities in plain text", () => {
    expect(markdownToTelegramHtml("a < b & c > d")).toBe("a &lt; b &amp; c &gt; d");
  });
  it("handles plain text unchanged", () => { expect(markdownToTelegramHtml("just text")).toBe("just text"); });
  it("converts strikethrough", () => { expect(markdownToTelegramHtml("~~deleted~~")).toBe("<s>deleted</s>"); });
});

describe("chunkText", () => {
  it("returns single chunk for short text", () => { expect(chunkText("hello", 4096)).toEqual(["hello"]); });
  it("splits at newline boundary when possible", () => {
    const line = "x".repeat(100);
    const text = `${line}\n${line}\n${line}`;
    const chunks = chunkText(text, 210);
    expect(chunks.length).toBe(2);
    expect(chunks[0]).toBe(`${line}\n${line}`);
    expect(chunks[1]).toBe(line);
  });
  it("hard splits when no newline found", () => {
    const text = "x".repeat(200);
    const chunks = chunkText(text, 100);
    expect(chunks.length).toBe(2);
    expect(chunks[0].length).toBe(100);
    expect(chunks[1].length).toBe(100);
  });
  it("returns empty array for empty string", () => { expect(chunkText("", 4096)).toEqual([]); });
});
