#!/usr/bin/env node
// Cross-platform replacement for the POSIX `mkdir -p && cp` chain that the
// Tauri `beforeBuildCommand` used to inline. Runs `cargo build` for
// ycode-notify, then stages the produced binary at
// `src-tauri/binaries/ycode-notify` so the bundler's `resources` entry
// resolves on every platform — Windows cmd.exe rejects the POSIX commands,
// which broke v0.1.2's release pipeline.

import { execSync } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const isWindows = process.platform === "win32";
const ext = isWindows ? ".exe" : "";

// Both helper binaries are staged under src-tauri/binaries/<name> (no .exe
// suffix) so the single `resources` entry per binary in tauri.conf.json
// resolves on every platform. ycode-mcp/ycode-notify are Unix-socket only
// today (no-op on Windows), but shipping the bytes keeps the bundle uniform.
const crates = ["ycode-notify", "ycode-mcp"];

const dstDir = join(repoRoot, "src-tauri", "binaries");
mkdirSync(dstDir, { recursive: true });

for (const crate of crates) {
  execSync(`cargo build --release -p ${crate}`, {
    cwd: repoRoot,
    stdio: "inherit",
  });
  const src = join(repoRoot, "target", "release", `${crate}${ext}`);
  const dst = join(dstDir, crate);
  copyFileSync(src, dst);
  console.log(`prep-notify-sidecar: ${src} → ${dst}`);
}
