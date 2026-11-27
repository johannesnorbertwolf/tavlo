// Test-only bindings added in vitest.config.ts; Vite's import.meta.glob for fixtures.
/// <reference types="vite/client" />
import type { D1Migration } from "cloudflare:test";

declare global {
  namespace Cloudflare {
    interface Env {
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}
