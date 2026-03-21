import { defineConfig } from "vitest/config";
import path from "node:path";

export default defineConfig({
  test: {
    include: ["tests/**/*.test.ts"],
    environment: "node",
  },
  resolve: {
    alias: {
      "@druzhok/shared": path.resolve(__dirname, "packages/shared/src"),
      "@druzhok/proxy": path.resolve(__dirname, "packages/proxy/src"),
      "@druzhok/core": path.resolve(__dirname, "packages/core/src"),
      "@druzhok/telegram": path.resolve(__dirname, "packages/telegram/src"),
    },
  },
});
