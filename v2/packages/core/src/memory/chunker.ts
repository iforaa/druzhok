export type Chunk = { text: string; file: string; startLine: number; endLine: number };
type ChunkOpts = { targetTokens?: number; overlapTokens?: number };

export function chunkMarkdown(text: string, file: string, opts?: ChunkOpts): Chunk[] {
  if (!text.trim()) return [];
  const targetTokens = opts?.targetTokens ?? 400;
  const overlapTokens = opts?.overlapTokens ?? 80;
  const targetChars = targetTokens * 4;
  const overlapChars = overlapTokens * 4;
  const lines = text.split("\n");
  if (text.length <= targetChars) return [{ text, file, startLine: 1, endLine: lines.length }];

  const chunks: Chunk[] = [];
  let currentStart = 0;
  while (currentStart < lines.length) {
    let charCount = 0;
    let currentEnd = currentStart;
    while (currentEnd < lines.length && charCount < targetChars) { charCount += lines[currentEnd].length + 1; currentEnd++; }
    chunks.push({ text: lines.slice(currentStart, currentEnd).join("\n"), file, startLine: currentStart + 1, endLine: currentEnd });
    const advanceChars = targetChars - overlapChars;
    let advancedChars = 0;
    let nextStart = currentStart;
    while (nextStart < currentEnd && advancedChars < advanceChars) { advancedChars += lines[nextStart].length + 1; nextStart++; }
    if (nextStart <= currentStart) nextStart = currentStart + 1;
    if (nextStart >= lines.length) break;
    currentStart = nextStart;
  }
  return chunks;
}
