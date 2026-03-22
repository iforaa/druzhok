export type EmbeddingOpts = { proxyUrl: string; proxyKey: string; model?: string };

export async function getEmbeddings(texts: string[], opts: EmbeddingOpts): Promise<number[][]> {
  const model = opts.model ?? "text-embedding-3-small";
  const response = await fetch(`${opts.proxyUrl.replace(/\/$/, "")}/v1/embeddings`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${opts.proxyKey}` },
    body: JSON.stringify({ input: texts, model }),
  });
  if (!response.ok) throw new Error(`Embedding request failed: ${response.status} ${response.statusText}`);
  const data = (await response.json()) as { data: Array<{ embedding: number[] }> };
  return data.data.map((d) => d.embedding);
}

export function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0, normA = 0, normB = 0;
  for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; normA += a[i] * a[i]; normB += b[i] * b[i]; }
  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom === 0 ? 0 : dot / denom;
}
