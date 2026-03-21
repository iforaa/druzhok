export type OpenAICompatForwardOpts = { baseUrl: string; apiKey: string; model: string; body: unknown; stream: boolean };

export async function forwardToOpenAICompat(opts: OpenAICompatForwardOpts): Promise<Response> {
  const url = `${opts.baseUrl.replace(/\/$/, "")}/chat/completions`;
  const body = { ...(opts.body as Record<string, unknown>), model: opts.model };
  return fetch(url, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${opts.apiKey}`, "Accept-Encoding": "identity" }, body: JSON.stringify(body) });
}

export async function forwardEmbeddingsToOpenAICompat(opts: { baseUrl: string; apiKey: string; body: unknown }): Promise<Response> {
  const url = `${opts.baseUrl.replace(/\/$/, "")}/embeddings`;
  return fetch(url, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${opts.apiKey}`, "Accept-Encoding": "identity" }, body: JSON.stringify(opts.body) });
}
