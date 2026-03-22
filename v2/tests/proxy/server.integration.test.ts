import { describe, it, expect, beforeAll, afterAll } from "vitest";
import type { FastifyInstance } from "fastify";
import { createProxyServer } from "@druzhok/proxy/server.js";

describe("proxy server", () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    app = await createProxyServer({
      registry: {
        instances: {
          test_key: { name: "test", tier: "default", enabled: true },
        },
      },
      config: {
        port: 0,
        providers: {},
        registryPath: "",
      },
    });
  });

  afterAll(async () => {
    await app.close();
  });

  it("GET /health returns ok", async () => {
    const res = await app.inject({ method: "GET", url: "/health" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toHaveProperty("status", "ok");
  });

  it("POST /v1/chat/completions without auth returns 401", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/chat/completions",
      payload: { model: "test", messages: [] },
    });
    expect(res.statusCode).toBe(401);
  });

  it("POST /v1/chat/completions with invalid key returns 401", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/chat/completions",
      headers: { authorization: "Bearer wrong_key" },
      payload: { model: "test", messages: [] },
    });
    expect(res.statusCode).toBe(401);
  });

  it("POST /v1/chat/completions with valid key but no provider returns 400", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/chat/completions",
      headers: { authorization: "Bearer test_key" },
      payload: { model: "openai/gpt-4o", messages: [] },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toContain("No provider configured");
  });

  it("POST /v1/chat/completions with missing model returns 400", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/chat/completions",
      headers: { authorization: "Bearer test_key" },
      payload: { messages: [] },
    });
    expect(res.statusCode).toBe(400);
  });

  it("POST /v1/embeddings without embedding provider returns 400", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/embeddings",
      headers: { authorization: "Bearer test_key" },
      payload: { input: "hello", model: "text-embedding-3-small" },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toContain("No embedding provider");
  });
});
