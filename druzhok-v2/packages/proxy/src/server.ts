import Fastify, { type FastifyInstance, type FastifyRequest, type FastifyReply } from "fastify";
import { createAuthenticator } from "./auth.js";
import { loadProxyConfig, loadRegistry, type ProxyConfig, type InstanceRegistry } from "./config.js";
import { registerHealthRoute } from "./health.js";
import { createRateLimiter } from "./rate-limit.js";
import { parseModelId, resolveProvider } from "./providers/router.js";
import { forwardToOpenAICompat, forwardEmbeddingsToOpenAICompat } from "./providers/openai-compat.js";
import { forwardToAnthropic, translateAnthropicStreamEvent, translateAnthropicResponse, createStreamState, type AnthropicStreamEvent } from "./providers/anthropic.js";
import { randomUUID } from "node:crypto";

const DEFAULT_TIERS = {
  default: { requestsPerMinute: 60 },
  limited: { requestsPerMinute: 20 },
};

export async function createProxyServer(overrides?: {
  config?: Partial<ProxyConfig>;
  registry?: InstanceRegistry;
}): Promise<FastifyInstance> {
  const config = { ...loadProxyConfig(), ...overrides?.config };
  const registry = overrides?.registry ?? loadRegistry(config.registryPath);
  const auth = createAuthenticator(registry);
  const rateLimiter = createRateLimiter(DEFAULT_TIERS);

  const app = Fastify({ logger: false });

  registerHealthRoute(app);

  // Add X-Request-Id to all requests
  app.addHook("onRequest", async (request, reply) => {
    const requestId = randomUUID();
    reply.header("X-Request-Id", requestId);
    (request as unknown as Record<string, unknown>).__requestId = requestId;
  });

  // Auth + rate limit hook for /v1/* routes
  app.addHook("preHandler", async (request: FastifyRequest, reply: FastifyReply) => {
    if (!request.url.startsWith("/v1/")) return;

    const key = auth.extractKey(request.headers.authorization);
    if (!key) {
      reply.code(401).send({ error: "Missing or invalid Authorization header" });
      return;
    }

    const authResult = auth.validate(key);
    if (!authResult.ok) {
      reply.code(401).send({ error: `Unauthorized: ${authResult.reason}` });
      return;
    }

    const rateResult = rateLimiter.check(key, authResult.instance.tier);
    if (!rateResult.allowed) {
      reply.code(429).header("Retry-After", String(rateResult.retryAfter))
        .send({ error: "Rate limit exceeded" });
      return;
    }

    (request as unknown as Record<string, unknown>).__instance = authResult.instance;
  });

  // POST /v1/chat/completions
  app.post("/v1/chat/completions", async (request, reply) => {
    const body = request.body as Record<string, unknown>;
    const modelId = body.model as string;
    if (!modelId) {
      reply.code(400).send({ error: "Missing model field" });
      return;
    }

    const parsed = parseModelId(modelId);
    const provider = resolveProvider(parsed.provider, config.providers);
    if (!provider) {
      reply.code(400).send({ error: `No provider configured for: ${parsed.provider}` });
      return;
    }

    const isStream = body.stream === true;

    try {
      if (provider.type === "openai-compat") {
        const upstream = await forwardToOpenAICompat({
          baseUrl: provider.baseUrl,
          apiKey: provider.apiKey,
          model: parsed.model,
          body,
          stream: isStream,
        });

        reply.code(upstream.status);
        for (const [k, v] of upstream.headers) {
          if (k.toLowerCase() !== "transfer-encoding") {
            reply.header(k, v);
          }
        }

        if (isStream && upstream.body) {
          reply.header("content-type", "text/event-stream");
          return reply.send(upstream.body);
        }

        const responseBody = await upstream.json();
        return reply.send(responseBody);
      }

      if (provider.type === "anthropic") {
        const upstream = await forwardToAnthropic({
          apiKey: provider.apiKey,
          baseUrl: provider.baseUrl,
          model: parsed.model,
          body,
          stream: isStream,
        });

        if (!isStream) {
          const anthropicResponse = await upstream.json() as Record<string, unknown>;
          reply.send(translateAnthropicResponse(anthropicResponse));
          return;
        }

        reply.raw.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        });

        const reader = upstream.body?.getReader();
        if (!reader) {
          reply.raw.end();
          return;
        }

        const decoder = new TextDecoder();
        const streamState = createStreamState();
        let buffer = "";

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";

          for (const line of lines) {
            if (!line.startsWith("data: ")) continue;
            const data = line.slice(6).trim();
            if (data === "[DONE]") {
              reply.raw.write("data: [DONE]\n\n");
              continue;
            }
            try {
              const event = JSON.parse(data) as AnthropicStreamEvent;
              const translated = translateAnthropicStreamEvent(event, streamState);
              if (translated === "[DONE]") {
                reply.raw.write("data: [DONE]\n\n");
              } else if (translated) {
                reply.raw.write(`data: ${JSON.stringify(translated)}\n\n`);
              }
            } catch {
              // Skip unparseable lines
            }
          }
        }

        reply.raw.end();
        return;
      }
    } catch (err) {
      reply.code(502).send({
        error: `Provider error: ${err instanceof Error ? err.message : String(err)}`,
      });
    }
  });

  // POST /v1/embeddings (passthrough to OpenAI-compat only)
  app.post("/v1/embeddings", async (request, reply) => {
    const provider = config.providers.openai
      ? { apiKey: config.providers.openai.apiKey, baseUrl: "https://api.openai.com/v1/" }
      : config.providers.nebius
        ? { apiKey: config.providers.nebius.apiKey, baseUrl: config.providers.nebius.baseUrl }
        : null;

    if (!provider) {
      reply.code(400).send({ error: "No embedding provider configured" });
      return;
    }

    try {
      const upstream = await forwardEmbeddingsToOpenAICompat({
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        body: request.body,
      });
      const responseBody = await upstream.json();
      reply.code(upstream.status).send(responseBody);
    } catch (err) {
      reply.code(502).send({
        error: `Embedding error: ${err instanceof Error ? err.message : String(err)}`,
      });
    }
  });

  return app;
}
