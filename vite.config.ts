import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const host = process.env.TAURI_DEV_HOST;
const pkg = JSON.parse(
  readFileSync(path.resolve(__dirname, "package.json"), "utf8"),
) as { version: string };

// Tauri 2 conventions: fixed port 1420, no screen-clear so the Cargo build
// log stays visible, and ignore the Rust workspace from the file watcher.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  define: { __APP_VERSION__: JSON.stringify(pkg.version) },
  resolve: {
    alias: {
      "@bindings": path.resolve(__dirname, "crates/ycode-ipc/bindings"),
    },
  },
  server: {
    port: 1420,
    strictPort: true,
    host: host ?? false,
    hmr: host ? { protocol: "ws", host, port: 1421 } : undefined,
    watch: {
      ignored: ["**/src-tauri/**", "**/target/**", "**/crates/**"],
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    globals: true,
    server: {
      deps: {
        // @lobehub/ui ships ESM that imports Base UI subpaths without a file
        // extension ("@base-ui/react/merge-props"). Vitest's externalised
        // resolver can't follow those against the hoisted copy, so inline the
        // package and let Vite's own resolver — which reads the exports map —
        // handle it.
        inline: ["@lobehub/ui"],
      },
    },
  },
});
