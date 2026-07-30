import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { generateKeyPairSync } from "node:crypto";
import { defineConfig } from "vitest/config";

const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const testSecrets = {
  APNS_PRIVATE_KEY_P8: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
  APNS_KEY_ID: "TESTKEY001",
  APNS_TEAM_ID: "TESTTEAM01",
};
Object.assign(process.env, testSecrets);

const migrations = await readD1Migrations(
  new URL("./migrations", import.meta.url).pathname,
);

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: migrations,
          TEST_BYPASS_RATE_LIMITS: "true",
          ...testSecrets,
        },
        outboundService: async (request) => {
          const token = new URL(request.url).pathname.split("/").at(-1);
          if (token === "de".repeat(32)) {
            return new Response(
              JSON.stringify({ reason: "Unregistered", timestamp: 1_800_000_000 }),
              {
                status: 410,
                headers: {
                  "apns-id": "test-apns-unregistered",
                  "content-type": "application/json",
                },
              },
            );
          }
          if (token === "fa".repeat(32)) {
            return new Response(JSON.stringify({ reason: "BadTopic" }), {
              status: 400,
              headers: { "content-type": "application/json" },
            });
          }
          if (token.startsWith("fb")) {
            return new Response(JSON.stringify({ reason: "TooManyRequests" }), {
              status: 429,
              headers: {
                "content-type": "application/json",
                "retry-after": "3600",
              },
            });
          }
          return new Response(null, {
            status: 200,
            headers: { "apns-id": "test-apns-id" },
          });
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.worker.test.mjs"],
    maxWorkers: 1,
    isolate: false,
    testTimeout: 10_000,
    hookTimeout: 10_000,
  },
});
