export type BM25Doc = { id: string; text: string };
export type BM25Result = { id: string; score: number };
type TokenizedDoc = { id: string; tokens: string[]; length: number };

function tokenize(text: string): string[] { return text.toLowerCase().split(/\W+/).filter(Boolean); }

const K1 = 1.5;
const B = 0.75;

export function createBM25Index(docs: BM25Doc[]) {
  const tokenizedDocs: TokenizedDoc[] = docs.map((d) => { const tokens = tokenize(d.text); return { id: d.id, tokens, length: tokens.length }; });
  const avgDocLength = tokenizedDocs.length > 0 ? tokenizedDocs.reduce((sum, d) => sum + d.length, 0) / tokenizedDocs.length : 0;
  const df = new Map<string, number>();
  for (const doc of tokenizedDocs) { const seen = new Set(doc.tokens); for (const token of seen) { df.set(token, (df.get(token) ?? 0) + 1); } }
  const N = tokenizedDocs.length;

  return {
    search(query: string): BM25Result[] {
      const queryTokens = tokenize(query);
      if (queryTokens.length === 0 || N === 0) return [];
      const results: BM25Result[] = [];
      for (const doc of tokenizedDocs) {
        let score = 0;
        const tf = new Map<string, number>();
        for (const token of doc.tokens) { tf.set(token, (tf.get(token) ?? 0) + 1); }
        for (const term of queryTokens) {
          const termFreq = tf.get(term) ?? 0;
          if (termFreq === 0) continue;
          const docFreq = df.get(term) ?? 0;
          const idf = Math.log((N - docFreq + 0.5) / (docFreq + 0.5) + 1);
          score += idf * ((termFreq * (K1 + 1)) / (termFreq + K1 * (1 - B + B * (doc.length / avgDocLength))));
        }
        if (score > 0) results.push({ id: doc.id, score });
      }
      return results.sort((a, b) => b.score - a.score);
    },
  };
}
