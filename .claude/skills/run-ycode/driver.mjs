#!/usr/bin/env node
// YCode macOS GUI driver.
//
// Why this exists: the repo's own e2e suite (e2e/wdio.conf.js) hard-fails on
// darwin — Tauri has no WKWebView WebDriver — so there is no built-in way to
// drive this app on a Mac. This wraps `cliclick` + `screencapture` into the
// handful of operations that actually work against a Tauri WKWebView window.
//
// Everything here was derived by driving the real app; see SKILL.md Gotchas.
//
// Usage:
//   node .claude/skills/run-ycode/driver.mjs <cmd> [args]
//
//   shot <file>            screenshot the whole display
//   click <x> <y> [wait]   click at LOGICAL points (see `map`)
//   type <text> [wait]     type via clipboard paste (IME-safe)
//   key <keyname> [wait]   cliclick key: return, esc, tab, arrow-down, ...
//   map <sx> <sy>          convert screenshot px -> logical points
//   focus                  bring YCode to the front
//   pid                    print YCode pid (exit 1 if not running)
//   ptys                   list YCode's child PTY processes (pid + command)
//   wait-up [secs]         block until the window is up
//
// Every mutating command re-focuses YCode first. Clicking steals focus from
// YCode to the *terminal running this script*, so without that the next click
// lands in the wrong app.

import { execFileSync, execSync } from "node:child_process";

const APP = "YCode";

function sh(cmd) {
  return execSync(cmd, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

function tryOsa(script) {
  try {
    return execFileSync("osascript", ["-e", script], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return null;
  }
}

function appPid() {
  try {
    return sh(`pgrep -x ${APP}`).trim().split("\n")[0] || null;
  } catch {
    return null;
  }
}

function requirePid() {
  const pid = appPid();
  if (!pid) {
    console.error(
      `${APP} is not running. Start it with: bash scripts/dev-ycode.sh`,
    );
    process.exit(1);
  }
  return pid;
}

function focus() {
  requirePid();
  tryOsa(
    `tell application "System Events" to tell process "${APP}" to set frontmost to true`,
  );
  sleepSync(600);
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/**
 * Screenshot pixels -> logical points.
 *
 * `screencapture` writes native-resolution pixels (2x on Retina) while
 * `cliclick` addresses the logical point grid, so coordinates read off a
 * screenshot must be scaled or every click misses. We derive the ratio from
 * the live display instead of hardcoding 2 — an external monitor is 1x.
 */
function displayBounds() {
  const raw = tryOsa(
    `tell application "Finder" to get bounds of window of desktop`,
  );
  if (!raw) return null;
  const [, , w, h] = raw.split(",").map((n) => parseInt(n.trim(), 10));
  return { w, h };
}

function mapCoords(sx, sy, shotW, shotH) {
  const b = displayBounds();
  if (!b) return { x: sx, y: sy };
  return {
    x: Math.round((sx * b.w) / shotW),
    y: Math.round((sy * b.h) / shotH),
  };
}

const [, , cmd, ...args] = process.argv;

switch (cmd) {
  case "pid": {
    const pid = appPid();
    if (!pid) {
      console.error("not running");
      process.exit(1);
    }
    console.log(pid);
    break;
  }

  case "wait-up": {
    const limit = Number(args[0] ?? 60);
    for (let i = 0; i < limit; i++) {
      if (appPid()) {
        console.log(`up (pid ${appPid()})`);
        process.exit(0);
      }
      sleepSync(1000);
    }
    console.error("timed out waiting for window");
    process.exit(1);
  }

  case "focus":
    focus();
    console.log("focused");
    break;

  case "shot": {
    const out = args[0];
    if (!out) {
      console.error("usage: shot <file>");
      process.exit(1);
    }
    focus();
    sleepSync(400);
    // -x = no shutter sound, -o = no window shadow.
    execFileSync("screencapture", ["-x", "-o", out]);
    console.log(out);
    break;
  }

  case "click": {
    const [x, y, wait] = args;
    if (x === undefined || y === undefined) {
      console.error("usage: click <x> <y> [waitSeconds]");
      process.exit(1);
    }
    focus();
    execFileSync("cliclick", [`c:${x},${y}`]);
    sleepSync(Number(wait ?? 2) * 1000);
    console.log(`clicked ${x},${y}`);
    break;
  }

  case "type": {
    const text = args[0];
    const wait = args[1];
    if (text === undefined) {
      console.error("usage: type <text> [waitSeconds]");
      process.exit(1);
    }
    focus();
    // Paste rather than synthesise keystrokes: with a Chinese IME active,
    // `cliclick t:` feeds the IME and the app receives pinyin candidates
    // instead of the literal text.
    execSync("pbcopy", { input: text });
    execFileSync("cliclick", ["kd:cmd", "t:v", "ku:cmd"]);
    sleepSync(Number(wait ?? 1) * 1000);
    console.log("typed via clipboard");
    break;
  }

  case "key": {
    const [name, wait] = args;
    if (!name) {
      console.error("usage: key <keyname> [waitSeconds]");
      process.exit(1);
    }
    focus();
    execFileSync("cliclick", [`kp:${name}`]);
    sleepSync(Number(wait ?? 1) * 1000);
    console.log(`key ${name}`);
    break;
  }

  case "map": {
    const [sx, sy, sw, sh_] = args;
    if (sx === undefined || sy === undefined) {
      console.error("usage: map <screenshotX> <screenshotY> [shotW] [shotH]");
      process.exit(1);
    }
    const { x, y } = mapCoords(
      Number(sx),
      Number(sy),
      Number(sw ?? 2000),
      Number(sh_ ?? 1301),
    );
    console.log(`${x} ${y}`);
    break;
  }

  case "ptys": {
    const pid = requirePid();
    let out = "";
    try {
      out = sh(`pgrep -P ${pid}`).trim();
    } catch {
      out = "";
    }
    if (!out) {
      console.log("(no child PTYs)");
      break;
    }
    for (const child of out.split("\n")) {
      try {
        console.log(sh(`ps -p ${child} -o pid=,command=`).trim());
      } catch {
        /* raced with exit */
      }
    }
    break;
  }

  default:
    console.error(
      "commands: shot click type key map focus pid ptys wait-up\n" +
        "see .claude/skills/run-ycode/SKILL.md",
    );
    process.exit(1);
}
