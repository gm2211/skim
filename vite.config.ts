/// <reference types="vitest/config" />
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;
// @ts-expect-error process is a nodejs global
const devBridge = process.env.SKIM_DEV_BRIDGE;

/**
 * Serves the app to a normal browser by pointing `@tauri-apps/api` at the Rust
 * dev bridge instead of a webview (see src-tauri/src/devbridge.rs). Opt in with
 * `SKIM_DEV_BRIDGE=1 pnpm dev`; without it the build is untouched.
 */
function devBridgePlugin(endpoint: string): Plugin {
  const shim = readFileSync(
    fileURLToPath(new URL("./scripts/dev-bridge-shim.js", import.meta.url)),
    "utf8",
  );
  return {
    name: "skim-dev-bridge",
    apply: "serve",
    transformIndexHtml() {
      return [
        {
          tag: "script",
          attrs: { "data-bridge": endpoint },
          children: shim,
          injectTo: "head-prepend",
        },
      ];
    },
  };
}

// https://vite.dev/config/
export default defineConfig(async () => ({
  plugins: [
    react(),
    tailwindcss(),
    ...(devBridge
      ? [devBridgePlugin(devBridge === "1" ? "http://127.0.0.1:1421" : devBridge)]
      : []),
  ],

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },

  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/test/setup.ts"],
    css: false,
  },
}));
