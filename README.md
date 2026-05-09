# ycode

A desktop tool that orchestrates multiple CLI coding agents (Claude Code, Gemini CLI, Codex, any ACP-compatible agent) in parallel — each session runs in its own git worktree on a local subprocess.

> **Strategic stance.** The moat is the `AgentAdapter` abstraction, not the UI.
> Sculptor (the closest competitor) is essentially a Claude-Code-specific
> container manager; the explicit goal here is that adding a new CLI is a
> matter of registering an ACP profile or writing a < 500 LoC heuristic
> profile, not building a new vertical. See
> [`/Users/melon/.claude/plans/sleepy-roaming-graham.md`](/Users/melon/.claude/plans/sleepy-roaming-graham.md)
> for the full plan.

## Status

| Layer | State |
|---|---|
| `AgentAdapter` trait + `AgentEvent` superset enum + `Capabilities` flags | done |
| State machine + permission broker + orchestrator | done |
| `SessionManager` (multi-session, restart, archive) | done |
| Adapters: `echo` (in-process), `acp` (hand-rolled JSON-RPC), `pty` (codex profile) | done |
| Persistence (sqlx + SQLite, WAL mode) | done |
| Worktree manager (`gix` discovery + shell-out for `git worktree add/remove`) | done |
| Tauri shell + typed IPC surface (`ycode-ipc::Service`) | done |
| Frontend (React 19 + TypeScript + Vite 6 + Zustand, ts-rs bindings consumed via `@bindings/*`) | done |
| Smoke scenarios | echo / echo-permission / echo-cancel / echo-parallel (S4) / echo-restart (S5) / loc-gate (S6) — all green; live `acp-claude` / `acp-gemini` / `pty-codex` gated on external binaries + API keys |

The plan named "Svelte 5 + Vite"; we landed on React 19 + Vite for the same reasons (typed via ts-rs, mechanical port). State lives in a single Zustand store keyed by session id.

## Build & run

Requirements: Rust 1.80+, `git` on PATH, an ACP-capable CLI for end-to-end use (e.g. `npm i -g @zed-industries/claude-code-acp`).

```bash
# Install frontend deps once.
npm install

# Production: build the React app, then run the desktop binary.
npm run build && cargo run -p ycode-tauri

# Dev with HMR: in two terminals,
#   1) npm run dev               # Vite at http://localhost:1420
#   2) cargo run -p ycode-tauri  # webview loads devUrl in debug builds
# Or, with the Tauri CLI installed (`cargo install tauri-cli --version '^2'`):
#   cargo tauri dev              # auto-runs `npm run dev` per tauri.conf.json

# Run any unit / loopback test.
cargo test --workspace

# Type-check the frontend without building.
npm run typecheck
```

The desktop binary is `~51 MB` debug. `bundle.active = false` in
`tauri.conf.json` keeps Tauri from demanding signed icon bundles during
development; release packaging is a separate concern.

## Configuration

User config lives at the platform-default `ycode/config.toml`
(`~/.config/ycode/config.toml` on Linux, `~/Library/Application
Support/dev.ycode.ycode/` on macOS). When the file is missing, defaults
ship with Claude Code and Gemini CLI registered as ACP agents.

```toml
[[agents]]
id = "claude-code"
kind = "acp"
command = "claude-code-acp"
env = { ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY" }

[[agents]]
id = "gemini-cli"
kind = "acp"
command = "gemini"
args = ["--experimental-acp"]

[[agents]]
id = "codex"
kind = "pty"
command = "codex"
heuristic_profile = "codex"
```

`$VAR` references inside `env` are expanded from the host environment at load
time. Missing variables stay as the literal `$VAR` so the adapter can fail
loudly on spawn rather than silently launching unauthenticated.

## Adding a new agent

The S6 cost gate (`cargo run -p ycode-cli -- smoke loc-gate`) enforces that an
end-to-end adapter for a new CLI fits in < 500 LoC. The cheapest path, in
order:

1. **CLI already speaks ACP.** Add a `[[agents]]` stanza with `kind = "acp"`
   and the spawn `command`. Zero Rust changes.
2. **CLI has a stable text interface.** Write a heuristic profile in
   `crates/ycode-pty-adapter/src/heuristics/<name>.rs`, register it in
   `heuristics::make`, and reference it from `config.toml`. Each profile has a
   soft 200 LoC budget — exceeding it is a signal you should be upstreaming
   ACP support, not chasing terminal strings.
3. **CLI is genuinely unique.** Implement `AgentAdapter` in a new crate and
   register a factory in `state::register_factories`. Use this only when the
   first two routes don't fit.

## Smoke tests

```bash
# Cheap (no external binaries):
cargo run -p ycode-cli -- smoke echo
cargo run -p ycode-cli -- smoke echo-permission
cargo run -p ycode-cli -- smoke echo-cancel
cargo run -p ycode-cli -- smoke echo-parallel    # S4
cargo run -p ycode-cli -- smoke echo-restart     # S5
cargo run -p ycode-cli -- smoke loc-gate         # S6 cost gate

# Live (require external binaries + API keys):
cargo run -p ycode-cli -- smoke acp-claude --repo <path>     # S1
cargo run -p ycode-cli -- smoke acp-gemini --repo <path>     # S2 (cancel mid-turn)
cargo run -p ycode-cli -- smoke pty-codex  --repo <path>     # S3
```

Every scenario emits NDJSON of `AgentEvent`s on stdout and structured
tracing on stderr — pipe stdout through `jq` for a readable transcript.

## Workspace layout

```
ycode/
├── Cargo.toml                # workspace root
├── package.json              # frontend deps (React, Vite, Zustand, @tauri-apps/api)
├── vite.config.ts            # alias @bindings/* → crates/ycode-ipc/bindings/
├── index.html                # Vite entry
├── src/                      # React + TS frontend
│   ├── main.tsx
│   ├── App.tsx
│   ├── lib/                  # ipc.ts (Tauri command wrappers), store.ts (Zustand), types.ts
│   └── components/           # TopBar / Sidebar / SessionRow / LogPane / EventCard / Composer / StatusBar / PermissionDialog
├── src-tauri/                # Tauri shell — commands.rs is glue, state.rs wires Service
└── crates/
    ├── ycode-adapter/        # AgentAdapter trait, AgentEvent, Capabilities, SessionState
    ├── ycode-acp-adapter/    # ACP over hand-rolled JSON-RPC; loopback test in tests/loopback.rs
    ├── ycode-pty-adapter/    # PTY + vt100 + heuristic profiles (codex.rs is the example)
    ├── ycode-echo-adapter/   # in-process toy adapter; smoke target for the S6 LoC gate
    ├── ycode-core/           # state machine, permission broker, orchestrator, SessionManager
    ├── ycode-worktree/       # gix discovery + git worktree shell-out
    ├── ycode-persist/        # sqlx + SQLite + migrations (sessions, events, permissions)
    ├── ycode-config/         # TOML config + $VAR expansion
    ├── ycode-ipc/            # typed Service facade + DTOs (ts-rs bindings)
    └── ycode-cli/            # headless smoke runner (S1–S6 entry points)
```

## License

MIT OR Apache-2.0
