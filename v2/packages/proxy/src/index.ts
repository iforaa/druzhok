import { createProxyServer } from "./server.js";
import { loadProxyConfig } from "./config.js";

async function main() {
  const config = loadProxyConfig();
  const server = await createProxyServer();

  await server.listen({ port: config.port, host: "0.0.0.0" });
  console.log(`Druzhok proxy listening on port ${config.port}`);
}

main().catch((err) => {
  console.error("Failed to start proxy:", err);
  process.exit(1);
});
