//! One-shot helper invoked by agent CLI hooks (Claude Code `Stop`, Codex
//! `notify`). Connects to a Unix domain socket owned by the running ycode
//! app and writes one JSON line, then exits 0.
//!
//! The helper deliberately does as little as possible:
//! - No network IO. Local socket only.
//! - Hard 200 ms connect + write timeout so a stuck or dead ycode never
//!   stalls the CLI calling us.
//! - Always exits 0, even on failure. Hooks failing must not block the
//!   CLI's normal turn — silent best-effort matches the user expectation.
//!
//! ## Wire protocol
//!
//! One newline-terminated JSON object per connection, fields:
//!
//! ```json
//! {
//!   "terminal_id": "session-xyz",     // YCODE_TERMINAL_ID env, may be ""
//!   "source": "claude" | "codex",     // argv[2] (defaults to "unknown")
//!   "event": "stop" | "notification" | "turn_complete", // argv[1]
//!   "stdin": "...raw stdin contents..." // present when invoked with piped JSON (Claude hooks)
//! }
//! ```
//!
//! ## Invocation
//!
//! ```text
//! ycode-notify <event> [<source>] [--next ARGV_JSON] [<extra...>]
//! ```
//!
//! `--next ARGV_JSON` opts into **chain mode**: after firing the UDS event we
//! `exec` the program in the decoded argv (Vec<String>), appending any extra
//! positional arguments we received. This lets us slot in front of an
//! existing user-set Codex `notify` wrapper (e.g. SkyComputerUseClient) so
//! both YCode *and* their pre-existing tool keep working.
//!
//! Reads `YCODE_NOTIFY_SOCK` for the socket path; falls back to the
//! platform default (`$TMPDIR/ycode-notify-<uid>.sock` on Unix).

use std::io::{Read, Write};
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_millis(200);

fn main() {
    // Best-effort: any error short-circuits to a silent exit 0.
    let _ = run();
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let (event, source, next_argv, passthrough) = parse_argv(std::env::args().skip(1));

    let terminal_id = std::env::var("YCODE_TERMINAL_ID").unwrap_or_default();

    // Read stdin if anything was piped in. Claude hooks pipe a JSON event blob
    // we forward verbatim so the host can extract session_id / cwd / etc.
    // Codex `notify` passes data via argv, not stdin — so an empty stdin is
    // fine.
    let stdin_str = read_stdin_lossy();

    // `extra` carries any trailing positional args we received — for Codex
    // that's the JSON payload it appends after our notify argv (containing
    // `last-assistant-message` etc.). Forwarded verbatim so the host can
    // build a richer notification body.
    let payload = serde_json::json!({
        "terminal_id": terminal_id,
        "source": source,
        "event": event,
        "stdin": stdin_str,
        "extra": passthrough,
    });

    let _ = send(&payload.to_string());

    // Chain mode: replace ourselves with the wrapped notify program so the
    // user's pre-existing tool still runs. We `exec` (not spawn) so the parent
    // CLI sees a single process lifecycle. UDS send errors above are swallowed
    // so a dead ycode never blocks the chain.
    if let Some(chain) = next_argv {
        exec_chain(&chain, &passthrough);
    }
    Ok(())
}

/// Walk argv once, peeling off `--next ARGV_JSON` wherever it appears. The
/// first two non-flag tokens are `event` and `source`; anything after that is
/// treated as passthrough for the chained command (this is where Codex's
/// trailing JSON payload lands).
fn parse_argv<I: IntoIterator<Item = String>>(
    iter: I,
) -> (String, String, Option<Vec<String>>, Vec<String>) {
    let mut event = "stop".to_string();
    let mut source = "unknown".to_string();
    let mut next_argv: Option<Vec<String>> = None;
    let mut passthrough: Vec<String> = Vec::new();
    let mut positional = 0u8;

    let mut iter = iter.into_iter();
    while let Some(a) = iter.next() {
        if a == "--next" {
            if let Some(json) = iter.next() {
                if let Ok(v) = serde_json::from_str::<Vec<String>>(&json) {
                    if !v.is_empty() {
                        next_argv = Some(v);
                    }
                }
            }
            continue;
        }
        match positional {
            0 => event = a,
            1 => source = a,
            _ => passthrough.push(a),
        }
        positional = positional.saturating_add(1);
    }
    (event, source, next_argv, passthrough)
}

#[cfg(unix)]
fn exec_chain(next: &[String], passthrough: &[String]) {
    use std::os::unix::process::CommandExt;
    let Some((head, rest)) = next.split_first() else {
        return;
    };
    let mut cmd = std::process::Command::new(head);
    cmd.args(rest);
    cmd.args(passthrough);
    // exec replaces our process image; on failure we just fall through and
    // exit 0 normally — losing the chain is preferable to surfacing an error
    // back to the CLI.
    let _ = cmd.exec();
}

#[cfg(not(unix))]
fn exec_chain(_next: &[String], _passthrough: &[String]) {
    // Windows v1 doesn't ship the helper, so chain mode is unreachable here.
}

fn read_stdin_lossy() -> String {
    // Reading stdin when it's connected to a TTY would hang waiting for the
    // user. Only drain when something is actually piped — detect by trying
    // a non-blocking metadata check. The simplest portable signal: stdin
    // is not a tty.
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let fd = std::io::stdin().as_raw_fd();
        // SAFETY: `isatty` is a pure FFI call returning an int; safe to call
        // on any valid fd. We're not modifying any state.
        let is_tty = unsafe { libc_isatty(fd) } != 0;
        if is_tty {
            return String::new();
        }
    }

    let mut buf = Vec::with_capacity(1024);
    let _ = std::io::stdin().read_to_end(&mut buf);
    // Cap to 64 KiB — agent hook payloads are tiny; anything larger is
    // pathological and would just bloat the socket message.
    if buf.len() > 64 * 1024 {
        buf.truncate(64 * 1024);
    }
    String::from_utf8_lossy(&buf).into_owned()
}

#[cfg(unix)]
extern "C" {
    #[link_name = "isatty"]
    fn libc_isatty(fd: std::os::raw::c_int) -> std::os::raw::c_int;
}

#[cfg(unix)]
fn send(line: &str) -> Result<(), Box<dyn std::error::Error>> {
    use std::os::unix::net::UnixStream;

    let sock_path = std::env::var("YCODE_NOTIFY_SOCK")
        .ok()
        .unwrap_or_else(default_sock_path);
    if sock_path.is_empty() {
        return Ok(());
    }

    let mut stream = UnixStream::connect(&sock_path)?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    stream.write_all(line.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    Ok(())
}

#[cfg(not(unix))]
fn send(_line: &str) -> Result<(), Box<dyn std::error::Error>> {
    // v1 ships Unix-only. Windows named-pipe support can land here later.
    Ok(())
}

#[cfg(unix)]
fn default_sock_path() -> String {
    let tmp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into());
    // SAFETY: `getuid` is a pure FFI call returning the current uid; no
    // arguments, no mutation.
    let uid = unsafe { libc_getuid() };
    format!("{}/ycode-notify-{}.sock", tmp.trim_end_matches('/'), uid)
}

#[cfg(not(unix))]
fn default_sock_path() -> String {
    String::new()
}

#[cfg(unix)]
extern "C" {
    #[link_name = "getuid"]
    fn libc_getuid() -> u32;
}

#[cfg(test)]
mod tests {
    use super::parse_argv;

    fn argv(slice: &[&str]) -> Vec<String> {
        slice.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn plain_event_and_source() {
        let (e, s, n, p) = parse_argv(argv(&["turn_complete", "codex"]));
        assert_eq!(e, "turn_complete");
        assert_eq!(s, "codex");
        assert!(n.is_none());
        assert!(p.is_empty());
    }

    #[test]
    fn next_decodes_argv_json() {
        let chain = r#"["sky","turn-ended","--previous-notify","[\"x\"]"]"#;
        let (e, s, n, p) = parse_argv(argv(&[
            "turn_complete",
            "codex",
            "--next",
            chain,
            "{\"foo\":1}",
        ]));
        assert_eq!(e, "turn_complete");
        assert_eq!(s, "codex");
        let n = n.unwrap();
        assert_eq!(n, vec!["sky", "turn-ended", "--previous-notify", "[\"x\"]"]);
        // Trailing payload (codex's JSON arg) is passthrough.
        assert_eq!(p, vec!["{\"foo\":1}".to_string()]);
    }

    #[test]
    fn next_with_invalid_json_is_ignored() {
        let (_, _, n, _) = parse_argv(argv(&["e", "s", "--next", "{not json}"]));
        assert!(n.is_none());
    }

    #[test]
    fn next_with_empty_array_is_ignored() {
        let (_, _, n, _) = parse_argv(argv(&["e", "s", "--next", "[]"]));
        assert!(n.is_none());
    }

    #[test]
    fn empty_argv_uses_defaults() {
        let (e, s, n, p) = parse_argv(argv(&[]));
        assert_eq!(e, "stop");
        assert_eq!(s, "unknown");
        assert!(n.is_none());
        assert!(p.is_empty());
    }
}
