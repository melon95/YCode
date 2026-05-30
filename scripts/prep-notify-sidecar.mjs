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
const srcName = isWindows ? "ycode-notify.exe" : "ycode-notify";

execSync("cargo build --release -p ycode-notify", {
  cwd: repoRoot,
  stdio: "inherit",
});

const dstDir = join(repoRoot, "src-tauri", "binaries");
mkdirSync(dstDir, { recursive: true });

const src = join(repoRoot, "target", "release", srcName);
// Stage without the .exe extension so the single `resources` entry in
// tauri.conf.json (`binaries/ycode-notify`) resolves on every platform.
// ycode-notify is a no-op on Windows today (Unix-socket only); shipping
// the bytes keeps the bundle layout uniform until a Windows transport lands.
const dst = join(dstDir, "ycode-notify");
copyFileSync(src, dst);

console.log(`prep-notify-sidecar: ${src} → ${dst}`);
