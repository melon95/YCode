import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const host = process.env.TAURI_DEV_HOST;

// Tauri 2 conventions: fixed port 1420, no screen-clear so the Cargo build
// log stays visible, and ignore the Rust workspace from the file watcher.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  clearScreen: false,
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
});
