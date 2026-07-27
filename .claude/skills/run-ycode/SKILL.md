---
name: run-ycode
description: Build, launch, screenshot and drive the ycode Tauri desktop app on macOS. Use when asked to run, start, launch, open, screenshot, click through, smoke-test or manually verify the ycode app (as opposed to running its unit tests). Covers the cliclick/screencapture GUI driver, PTY-survival checks, and reading app state straight out of SQLite.
---

# Run ycode (macOS desktop)

ycode is a Tauri 2 desktop app: Rust backend (`src-tauri/` + `crates/*`),
React 19 frontend (`src/`), xterm.js terminals, SQLite for session state.

**Paths below are relative to the repo root.**

The repo's own WebDriver e2e suite (`e2e/`) **cannot run on macOS** —
`e2e/wdio.conf.js` throws on `process.platform === "darwin"` because Tauri has
no WKWebView WebDriver. So on a Mac the only way to drive the real app is the
macOS accessibility stack. `.claude/skills/run-ycode/driver.mjs` wraps that into
commands that actually work (see Gotchas for why each one exists).

## Prerequisites

```bash
brew install cliclick          # synthetic clicks/keys; no macOS equivalent built in
node --version                 # v20+ (repo uses Vite 6 / React 19)
```

**Grant your terminal both permissions or nothing below works:**
System Settings → Privacy & Security → **Screen Recording** *and* **Accessibility**
→ enable your terminal app → **restart the terminal**.

Without them you get, respectively:
- `screencapture` → `could not create image from display`
- `osascript`/click → `osascript is not allowed accessibility access (-1728)`

## Run (agent path)

```bash
# 1. Launch. Kills any stale instance first (macOS may route a launch to an
#    already-running app with the same bundle id), then runs `tauri dev`.
(bash scripts/dev-ycode.sh > /tmp/ycode-dev.log 2>&1 &)

# 2. Block until the window exists (first run compiles Rust — allow minutes).
node .claude/skills/run-ycode/driver.mjs wait-up 300

# 3. Screenshot, then LOOK at it.
node .claude/skills/run-ycode/driver.mjs shot /tmp/shot.png
```

Driver commands:

| Command | Purpose |
|---|---|
| `wait-up [secs]` | block until the window is up (use after launch **and after every rebuild**) |
| `shot <file>` | screenshot the display |
| `click <x> <y> [wait]` | click at **logical** points |
| `type <text> [wait]` | type via clipboard paste (IME-safe) |
| `key <name> [wait]` | `return`, `esc`, `tab`, `arrow-down`, … |
| `map <sx> <sy> [w] [h]` | screenshot px → logical points |
| `ptys` | list the app's child PTY processes |
| `pid` / `focus` | pid lookup / bring to front |

### Clicking from a screenshot

Screenshots are native pixels (3420×2224 on this Retina Mac); `cliclick` wants
logical points (1710×1112). Read a coordinate off the screenshot, convert, click:

```bash
D=.claude/skills/run-ycode/driver.mjs
node $D map 1963 80 2000 1301      # → 1678 68   (args: x y shotW shotH)
node $D click 1678 68 3            # opens Settings
```

`map`'s 3rd/4th args are the dimensions of the image **as you viewed it**
(the Read tool downscales to 2000px wide — pass 2000 1301, not 3420 2224).

### A worked flow: verify Settings doesn't kill terminal PTYs

This is the check that motivated the driver's `ptys` command — manual terminals
have no session row, so an unmount kills their PTY.

```bash
D=.claude/skills/run-ycode/driver.mjs
node $D click 970 179 2            # Terminal tab
node $D click 1400 400 1           # focus the terminal body
node $D type 'echo hello' 1
node $D key return 2
node $D ptys                       # → e.g. "46008 /bin/zsh"  ← note the pid
node $D click 1678 68 3            # open Settings
ps -p <pid> -o pid,command         # still there ⇒ workspace was hidden, not unmounted
```

### Read app state instead of guessing from pixels

Far more reliable than reading the UI. The DB lives outside the repo:

```bash
DB="$HOME/Library/Application Support/dev.ycode.ycode/ycode.db"
sqlite3 -header "$DB" "SELECT id,name FROM projects;"
sqlite3 -header "$DB" "SELECT id,session_id,sequence,kind FROM session_checkpoints;"
git worktree list                  # isolated agent worktrees
git diff --cached --name-only      # verify a Stage-hunk click really staged
```

## Run (human path)

```bash
bash scripts/dev-ycode.sh
```

Opens the window in the foreground; Ctrl-C to quit. Useless for an agent — there
is nothing to observe programmatically.

## Test

```bash
npm test                # vitest, ~3s
npm run typecheck       # tsc --noEmit
cargo test --workspace  # includes crates/ycode-ipc/tests/end_to_end.rs
npm run test:e2e        # ❌ throws on macOS — Linux/Windows only
```

## Gotchas

- **Every click steals focus from the app.** `cliclick` clicks activate whatever
  window is under the cursor — often *your terminal*, not ycode. The driver
  re-focuses ycode before every action; if you call `cliclick` directly, you must
  do the same or the next click lands in the wrong app.
- **`tauri dev` hot-rebuilds on any Rust edit and the window disappears for
  minutes.** Editing a `crates/**/*.rs` file mid-session (even just running
  `rustfmt`) restarts the app: the pid changes, all PTYs die, and the UI resets.
  Always `wait-up` again and re-read the pid. This bit twice while writing this
  skill.
- **Never hardcode coordinates across a restart.** The right pane restores to
  whatever tab was last active (Terminal/Files/Changes/Todos), so tab positions
  shift. Screenshot → `map` → click, every time.
- **A Chinese IME eats synthesised keystrokes.** `cliclick t:` feeds the IME, so
  `while true; do ...` arrives as `doechoYCODE...` plus a pinyin candidate bar.
  The driver's `type` pastes via `pbcopy` + ⌘V instead. Don't switch it back.
- **Native `<select>` menus ignore synthetic keys.** The workspace-target picker
  opens on click, but `cliclick kp:arrow-up/return` and `osascript key code` both
  fail to move the selection. Click the option's coordinates directly; expect to
  retry, and verify the result in the next screenshot rather than assuming.
- **`osascript ... to click at {x, y}` does not work** (error -25204). That's why
  the driver shells out to `cliclick` instead.
- **Agent-session PTYs survive; manual-terminal PTYs do not.** Agent terminals
  are owned by the backend `TerminalManager` (256 KB scrollback replayed on
  remount); `ManualTerminal` kills its PTY on React unmount. When testing
  terminal lifetime, use a *manual* terminal — an agent terminal proves nothing.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `could not create image from display` | Grant Screen Recording, restart terminal |
| `osascript is not allowed accessibility access (-1728)` | Grant Accessibility, restart terminal |
| `YCode is not running` from the driver | Usually a hot rebuild — `tail /tmp/ycode-dev.log`, then `wait-up 300` |
| Clicks land in the terminal app | You called `cliclick` directly; use the driver (it re-focuses) |
| Typed text becomes pinyin candidates | Use `driver.mjs type` (clipboard), not `cliclick t:` |
| Window never appears, log shows `Compiling` | First build only; wait it out (several minutes) |
| App launches but shows another project | Project tabs persist; click the right tab, verify by screenshot |
