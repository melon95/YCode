# Tauri WebDriver e2e

This suite drives the real Tauri desktop app through `tauri-driver` and
WebdriverIO. It is not a Vite/browser-only test.

## Platform support

Tauri desktop WebDriver currently supports Linux and Windows. It does not run
on macOS because there is no WKWebView WebDriver tool for Tauri to use.

For local development on a Mac, run this inside a Linux VM or Linux container
with GUI/WebKit support. In CI, prefer a Linux runner with Xvfb.

## Linux setup

Install the native WebKit driver and `tauri-driver`:

```bash
sudo apt-get install -y webkit2gtk-driver xvfb
cargo install tauri-driver --locked
```

Run the suite:

```bash
xvfb-run -a npm run test:e2e
```

The test config builds the debug Tauri app with:

```bash
npm run tauri build -- --debug --no-bundle
```

To reuse an existing binary:

```bash
E2E_SKIP_BUILD=1 E2E_APP_BINARY=/absolute/path/to/YCode npm run test:e2e
```

The suite sets `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_CACHE_HOME` under
`e2e/.tmp/home` so the app does not touch the user's normal YCode config or
database on Linux.
