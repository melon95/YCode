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

// Build for the same target Tauri is bundling for, not the host default.
// `tauri build --target x86_64-apple-darwin` on an Apple Silicon runner (what
// the release matrix does) would otherwise get an arm64 helper stapled into an
// x86_64 .app — the app itself runs fine, so the mismatch only surfaces when
// the user invokes the binary and the shell answers "bad CPU type". Tauri
// exports the triple to `beforeBuildCommand`; when it's absent (a plain
// `node scripts/prep-notify-sidecar.mjs`) we fall back to the host build.
const triple = process.env.TAURI_ENV_TARGET_TRIPLE;
const targetArgs = triple ? ` --target ${triple}` : "";
// Derive the exe suffix from the *target*, not the host — they differ whenever
// we cross-compile.
const isWindows = triple
  ? triple.includes("windows")
  : process.platform === "win32";
const ext = isWindows ? ".exe" : "";
// cargo nests per-target output one level deeper.
const outDir = triple
  ? join(repoRoot, "target", triple, "release")
  : join(repoRoot, "target", "release");

// Helper binaries staged under src-tauri/binaries/, matched by the
// `resources` entries in tauri.conf.json.
//
// `keepExt` controls whether the staged copy keeps the platform's exe suffix.
// ycode-notify/ycode-mcp are spawned by the app, which passes an explicit
// path, so a suffix-less name works everywhere and keeps one resources entry
// per binary. ycode-cli is different: on Windows it's invoked through the
// `ycode.cmd` shim, and Windows will not execute a file without a recognised
// extension — so it has to ship as `ycode-cli.exe` there, which is also what
// `resolve_cli_bin` looks for.
const crates = [
  { name: "ycode-notify", keepExt: false },
  { name: "ycode-mcp", keepExt: false },
  { name: "ycode-cli", keepExt: true },
];

const dstDir = join(repoRoot, "src-tauri", "binaries");
mkdirSync(dstDir, { recursive: true });

for (const { name, keepExt } of crates) {
  execSync(`cargo build --release${targetArgs} -p ${name}`, {
    cwd: repoRoot,
    stdio: "inherit",
  });
  const src = join(outDir, `${name}${ext}`);
  const dst = join(dstDir, keepExt ? `${name}${ext}` : name);
  copyFileSync(src, dst);
  console.log(`prep-notify-sidecar: ${src} → ${dst}`);
}
