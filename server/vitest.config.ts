// Tests run inside workerd via Miniflare (@cloudflare/vitest-plugin, the renamed
// @cloudflare/vitest-pool-workers): the top-level wrangler.jsonc config with local D1,
// Durable Objects and rate-limit bindings. D1 migrations are read here (Node) and
// applied per test file in test/setup.ts.
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: { bindings: { TEST_MIGRATIONS: migrations } },
      }),
    ],
    test: { setupFiles: ["./test/setup.ts"] },
  };
});
