import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const tmpRoot = path.join(__dirname, ".tmp");
const testHome = path.join(tmpRoot, "home");
const fixtureProject = path.join(tmpRoot, "fixture-project");

let tauriDriver;
let driverExiting = false;

ensureSupportedPlatform();

export const config = {
  host: "127.0.0.1",
  port: Number(process.env.TAURI_DRIVER_PORT ?? 4444),
  specs: ["./specs/**/*.e2e.js"],
  maxInstances: 1,
  capabilities: [
    {
      maxInstances: 1,
      "tauri:options": {
        application: resolveAppBinary(),
      },
    },
  ],
  reporters: ["spec"],
  framework: "mocha",
  mochaOpts: {
    ui: "bdd",
    timeout: 120000,
  },
  waitforTimeout: 30000,
  connectionRetryTimeout: 120000,
  connectionRetryCount: 1,

  onPrepare() {
    ensureSupportedPlatform();
    prepareIsolatedHome();
    prepareFixtureProject();

    if (process.env.E2E_SKIP_BUILD === "1") return;

    const result = spawnSync(
      "npm",
      ["run", "tauri", "build", "--", "--debug", "--no-bundle"],
      {
        cwd: repoRoot,
        stdio: "inherit",
        shell: true,
        env: e2eEnv(),
      },
    );
    if (result.status !== 0) {
      throw new Error(`Tauri debug build failed with status ${result.status}`);
    }
  },

  beforeSession() {
    const binary = resolveTauriDriverBinary();
    if (!fs.existsSync(binary)) {
      throw new Error(
        `tauri-driver not found at ${binary}. Install it with: cargo install tauri-driver --locked`,
      );
    }
    tauriDriver = spawn(binary, ["--port", String(config.port)], {
      stdio: [null, process.stdout, process.stderr],
      env: e2eEnv(),
    });
    tauriDriver.on("error", (error) => {
      console.error("tauri-driver failed to start:", error);
      process.exit(1);
    });
    tauriDriver.on("exit", (code) => {
      if (!driverExiting) {
        console.error("tauri-driver exited unexpectedly:", code);
        process.exit(1);
      }
    });
  },

  afterSession() {
    closeTauriDriver();
  },

  onComplete() {
    closeTauriDriver();
  },
};

function ensureSupportedPlatform() {
  if (process.platform === "darwin") {
    throw new Error(
      "Tauri desktop WebDriver does not support macOS. Run npm run test:e2e in a Linux VM/container or on Windows.",
    );
  }
  if (process.platform !== "linux" && process.platform !== "win32") {
    throw new Error(`Unsupported Tauri WebDriver platform: ${process.platform}`);
  }
}

function resolveAppBinary() {
  if (process.env.E2E_APP_BINARY) {
    return path.resolve(process.env.E2E_APP_BINARY);
  }
  const exe = process.platform === "win32" ? "YCode.exe" : "YCode";
  return path.join(repoRoot, "target", "debug", exe);
}

function resolveTauriDriverBinary() {
  if (process.env.TAURI_DRIVER_BINARY) {
    return path.resolve(process.env.TAURI_DRIVER_BINARY);
  }
  const exe = process.platform === "win32" ? "tauri-driver.exe" : "tauri-driver";
  return path.join(os.homedir(), ".cargo", "bin", exe);
}

function prepareIsolatedHome() {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
  fs.mkdirSync(testHome, { recursive: true });
}

function prepareFixtureProject() {
  fs.mkdirSync(path.join(fixtureProject, "docs"), { recursive: true });
  fs.writeFileSync(
    path.join(fixtureProject, "docs", "fixture.md"),
    [
      "# Fixture doc",
      "",
      "This file is edited by the real Tauri WebDriver e2e suite.",
      "",
    ].join("\n"),
  );
  process.env.E2E_FIXTURE_PROJECT_PATH = fixtureProject;
}

function e2eEnv() {
  return {
    ...process.env,
    XDG_CONFIG_HOME: path.join(testHome, "config"),
    XDG_DATA_HOME: path.join(testHome, "data"),
    XDG_CACHE_HOME: path.join(testHome, "cache"),
    RUST_LOG: process.env.RUST_LOG ?? "warn",
  };
}

function closeTauriDriver() {
  driverExiting = true;
  tauriDriver?.kill();
  tauriDriver = undefined;
}
