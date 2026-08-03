//! `ycode` — the shell command, mirroring VS Code's `code`.
//!
//! ```text
//! ycode                 # open the current directory
//! ycode .               # same
//! ycode ~/src/myrepo    # open that folder as a project
//! ycode src/main.rs     # open the enclosing repo, focus that file
//! ycode --help | --version
//! ```
//!
//! ## How it talks to the app
//!
//! The running app owns a Unix domain socket (`$TMPDIR/ycode-cli.sock`, path
//! overridable via `YCODE_CLI_SOCK`) served by `ycode_ipc::cli_listener`. We
//! send one newline-terminated JSON request and read one JSON response:
//!
//! ```json
//! {"action":"open","path":"/abs/dir","file":"/abs/dir/src/main.rs"}
//! ```
//!
//! Both are absolute. `path` is the directory we think should be opened — a
//! *hint*: the app maps it to whichever registered project already covers it,
//! which may be an ancestor. `file` is therefore absolute too, so the app can
//! re-base it against the root it actually chose; sending it relative to our
//! guess would silently address a different file with the same suffix. Absent
//! when a directory was requested.
//!
//! ## Cold start
//!
//! When no app is listening we launch it (macOS `open -a`, Linux the bundled
//! binary / `.desktop` entry), then retry the connect for a few seconds — the
//! listener only binds once the backend has initialised. This keeps `ycode .`
//! working from a fresh login the same way `code .` does.
//!
//! Unlike `ycode-notify` this binary is user-facing, so failures print a real
//! message to stderr and exit non-zero.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Per-connect timeout. The app answers immediately (a DB insert at worst);
/// anything slower means it's wedged and we should say so rather than hang.
/// Unix only — a Windows pipe handle has no equivalent setter short of raw
/// Win32, and its connect already fails fast when nothing is serving.
#[cfg(unix)]
const IO_TIMEOUT: Duration = Duration::from_secs(5);

/// How long to keep retrying the connect after we launched the app. A cold
/// macOS launch (bundle load + SQLite migrations) is typically 1–3s.
const LAUNCH_WAIT: Duration = Duration::from_secs(30);

const HELP: &str = "\
ycode — open a folder in YCode

USAGE:
    ycode [PATH]

ARGS:
    PATH    Directory to open as a project, or a file to open inside its
            enclosing project. Defaults to the current directory.

OPTIONS:
    -h, --help       Print this help
    -V, --version    Print the CLI version

The app is launched automatically when it isn't already running.
";

fn main() {
    if let Err(e) = run() {
        eprintln!("ycode: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match parse_args(&args)? {
        Command::Help => {
            print!("{HELP}");
            Ok(())
        }
        Command::Version => {
            println!("ycode {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Command::Open(target) => open(target),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Command {
    Help,
    Version,
    /// Raw path as typed by the user (possibly relative, possibly absent).
    Open(Option<String>),
}

/// Parse argv. Unknown flags are an error rather than being treated as paths —
/// a typo'd `--wait` silently opening a folder named `--wait` would be worse
/// than a clear message. A literal `--` ends flag parsing so paths that really
/// do start with a dash stay reachable.
fn parse_args(args: &[String]) -> Result<Command, String> {
    let mut path: Option<String> = None;
    let mut no_more_flags = false;

    for arg in args {
        if !no_more_flags {
            match arg.as_str() {
                "-h" | "--help" => return Ok(Command::Help),
                "-V" | "--version" => return Ok(Command::Version),
                "--" => {
                    no_more_flags = true;
                    continue;
                }
                // A bare "-" is conventionally stdin; we have no use for it.
                a if a.starts_with('-') && a != "-" => {
                    return Err(format!("unknown option `{a}` (try `ycode --help`)"));
                }
                _ => {}
            }
        }
        if path.is_some() {
            return Err("expected at most one path (try `ycode --help`)".into());
        }
        path = Some(arg.clone());
    }

    Ok(Command::Open(path))
}

/// What the app is asked to open: an absolute directory, plus the file to
/// focus inside it when the user pointed at a file.
#[derive(Debug, PartialEq, Eq)]
struct Target {
    dir: PathBuf,
    /// Absolute path of the file to focus. `None` for a directory arg. Kept
    /// absolute because `dir` is only a hint — see the note in `open()`.
    file: Option<PathBuf>,
}

fn open(raw: Option<String>) -> Result<(), String> {
    let cwd = std::env::current_dir().map_err(|e| format!("cannot read current directory: {e}"))?;
    let target = resolve_target(raw.as_deref(), &cwd)?;

    let mut request = serde_json::json!({
        "action": "open",
        "path": path_to_string(&target.dir)?,
    });
    if let Some(file) = &target.file {
        // Absolute, deliberately. `dir` is only a *hint* — the app resolves it
        // to whichever registered project already covers the path, which can
        // be an ancestor of what we picked (we stop at the nearest `.git`, it
        // prefers the deepest known project). A path relative to our `dir`
        // re-based against a different root silently addresses a different
        // file that happens to share the suffix. The app re-derives the
        // relative path once it knows the real root.
        request["file"] = serde_json::Value::String(path_to_string(file)?);
    }
    let line = request.to_string();

    let sock = socket_path();
    match send(&sock, &line) {
        Ok(()) => Ok(()),
        // The app is up but had no free connection slot. Retrying alone is
        // enough — launching would spawn a redundant process (or, thanks to
        // single-instance, just refocus and confuse the user).
        #[cfg(windows)]
        Err(SendError::Busy) => wait_and_send(&sock, &line),
        Err(SendError::NotRunning) => {
            launch_app()?;
            wait_and_send(&sock, &line)
        }
        Err(SendError::Other(e)) => Err(e),
    }
}

/// Turn the user's argument into an absolute directory (+ optional file).
///
/// Rules, matching `code`:
/// - no argument → current directory
/// - directory → that directory
/// - file → its parent directory, with the file focused. We walk up to the
///   enclosing git root when there is one, so `ycode src/deep/mod.rs` opens
///   the repo rather than a leaf folder with no context.
/// - missing path → error (we never create directories)
fn resolve_target(raw: Option<&str>, cwd: &Path) -> Result<Target, String> {
    let raw = raw.unwrap_or(".");
    let expanded = expand_tilde(raw);
    let joined = if expanded.is_absolute() {
        expanded
    } else {
        cwd.join(expanded)
    };

    let canonical = joined
        .canonicalize()
        .map_err(|e| format!("cannot open `{raw}`: {e}"))?;

    if canonical.is_dir() {
        return Ok(Target {
            dir: canonical,
            file: None,
        });
    }

    let parent = canonical
        .parent()
        .ok_or_else(|| format!("cannot determine the folder containing `{raw}`"))?
        .to_path_buf();
    let root = git_root(&parent).unwrap_or(parent);
    Ok(Target {
        dir: root,
        file: Some(canonical),
    })
}

/// Expand a leading `~` / `~/…` against `$HOME`. Shells already do this for
/// unquoted arguments, but `ycode "~/src"` (quoted, or invoked from a script)
/// reaches us verbatim.
fn expand_tilde(raw: &str) -> PathBuf {
    let Some(home) = std::env::var_os("HOME") else {
        return PathBuf::from(raw);
    };
    match raw {
        "~" => PathBuf::from(home),
        r if r.starts_with("~/") => PathBuf::from(home).join(&r[2..]),
        r => PathBuf::from(r),
    }
}

/// Nearest ancestor (inclusive) containing a `.git` entry. `.git` is a file,
/// not a directory, inside a linked worktree — so test for existence, not
/// for `is_dir`.
fn git_root(start: &Path) -> Option<PathBuf> {
    let mut cur = Some(start);
    while let Some(dir) = cur {
        if dir.join(".git").exists() {
            return Some(dir.to_path_buf());
        }
        cur = dir.parent();
    }
    None
}

fn path_to_string(p: &Path) -> Result<String, String> {
    p.to_str()
        .map(str::to_string)
        .ok_or_else(|| format!("path is not valid UTF-8: {}", p.display()))
}

/// Endpoint to talk to. Mirrors `ycode_ipc::cli_listener::default_socket_path`
/// — keep the two in sync.
fn socket_path() -> String {
    if let Ok(explicit) = std::env::var("YCODE_CLI_SOCK") {
        if !explicit.is_empty() {
            return explicit;
        }
    }
    default_endpoint()
}

/// Unix: a socket file under `$TMPDIR`.
#[cfg(unix)]
fn default_endpoint() -> String {
    let tmp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into());
    format!("{}/ycode-cli.sock", tmp.trim_end_matches('/'))
}

/// Windows: a named pipe. Per-user, because the pipe namespace is
/// machine-global and two logged-in users would otherwise collide.
#[cfg(windows)]
fn default_endpoint() -> String {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "default".into());
    let user: String = user
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect();
    format!(r"\\.\pipe\ycode-cli-{user}")
}

enum SendError {
    /// Nothing is listening — the app isn't running (or hasn't bound yet).
    NotRunning,
    /// The endpoint exists but has no free instance right now (Windows
    /// `ERROR_PIPE_BUSY`). Distinct from `NotRunning` because the cure is to
    /// retry, not to launch a second app.
    #[cfg(windows)]
    Busy,
    Other(String),
}

#[cfg(unix)]
fn send(sock: &str, line: &str) -> Result<(), SendError> {
    use std::os::unix::net::UnixStream;

    let mut stream = UnixStream::connect(sock).map_err(|e| match e.kind() {
        // ENOENT: no socket file. ECONNREFUSED: stale file left by a crashed
        // app. Both mean "launch it".
        std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused => {
            SendError::NotRunning
        }
        _ => SendError::Other(format!("cannot reach YCode at {sock}: {e}")),
    })?;
    stream
        .set_write_timeout(Some(IO_TIMEOUT))
        .and_then(|()| stream.set_read_timeout(Some(IO_TIMEOUT)))
        .map_err(|e| SendError::Other(format!("socket setup failed: {e}")))?;

    stream
        .write_all(line.as_bytes())
        .and_then(|()| stream.write_all(b"\n"))
        .and_then(|()| stream.flush())
        .map_err(|e| SendError::Other(format!("sending request failed: {e}")))?;

    let mut reply = String::new();
    BufReader::new(&stream)
        .read_line(&mut reply)
        .map_err(|e| SendError::Other(format!("reading response failed: {e}")))?;
    parse_reply(&reply).map_err(SendError::Other)
}

/// `ERROR_PIPE_BUSY`. The pipe exists but every instance is currently serving
/// someone else — transient, and the documented signal to wait and retry.
///
/// Matched on the raw code because `std` has no `ErrorKind` for it: its
/// `decode_error_kind` table maps 231 to `Uncategorized`, and the only source
/// of `WouldBlock` on Windows is `WSAEWOULDBLOCK`, which a `CreateFileW` on a
/// pipe cannot produce.
#[cfg(windows)]
const ERROR_PIPE_BUSY: i32 = 231;

/// Windows: a named pipe is just a file handle, so opening it read+write is the
/// whole client.
///
/// Busy is expected, not exceptional: the server keeps a single listening
/// instance and re-arms only *after* a client connects, so two concurrent
/// `ycode` invocations reliably put the second one in that window. Reporting it
/// as `NotRunning` routes it into the retry loop, which is what the Win32
/// `WaitNamedPipe` idiom does.
#[cfg(windows)]
fn send(sock: &str, line: &str) -> Result<(), SendError> {
    use std::fs::OpenOptions;

    let mut pipe = OpenOptions::new()
        .read(true)
        .write(true)
        .open(sock)
        .map_err(|e| {
            if e.raw_os_error() == Some(ERROR_PIPE_BUSY) {
                SendError::Busy
            } else if e.kind() == std::io::ErrorKind::NotFound {
                SendError::NotRunning
            } else {
                SendError::Other(format!("cannot reach YCode at {sock}: {e}"))
            }
        })?;

    pipe.write_all(line.as_bytes())
        .and_then(|()| pipe.write_all(b"\n"))
        .and_then(|()| pipe.flush())
        .map_err(|e| SendError::Other(format!("sending request failed: {e}")))?;

    let mut reply = String::new();
    BufReader::new(&pipe)
        .read_line(&mut reply)
        .map_err(|e| SendError::Other(format!("reading response failed: {e}")))?;
    parse_reply(&reply).map_err(SendError::Other)
}

#[cfg(not(any(unix, windows)))]
fn send(_sock: &str, _line: &str) -> Result<(), SendError> {
    Err(SendError::Other(
        "the ycode command is not supported on this platform".into(),
    ))
}

/// Interpret the app's `{"ok":true}` / `{"ok":false,"error":"…"}` reply.
/// An empty reply means the app closed the connection without answering,
/// which we surface rather than silently claiming success.
fn parse_reply(reply: &str) -> Result<(), String> {
    let trimmed = reply.trim();
    if trimmed.is_empty() {
        return Err("YCode closed the connection without responding".into());
    }
    let value: serde_json::Value =
        serde_json::from_str(trimmed).map_err(|e| format!("unreadable response: {e}"))?;
    if value.get("ok").and_then(|v| v.as_bool()) == Some(true) {
        return Ok(());
    }
    let msg = value
        .get("error")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown error");
    Err(msg.to_string())
}

/// Retry the send until the app is listening and has a free slot.
///
/// `Other` is terminal: it means we reached the app and it said no (bad path,
/// shutting down), so retrying would just repeat the same answer. `NotRunning`
/// and `Busy` are both "not yet" and keep the loop going until the deadline.
fn wait_and_send(sock: &str, line: &str) -> Result<(), String> {
    let deadline = Instant::now() + LAUNCH_WAIT;
    // Short waits: a busy instance frees up in microseconds, and a cold start
    // is dominated by the app's own boot, not by our polling interval.
    let step = Duration::from_millis(50);
    loop {
        let stalled = match send(sock, line) {
            Ok(()) => return Ok(()),
            Err(SendError::Other(e)) => return Err(e),
            Err(SendError::NotRunning) => "YCode did not start listening in time — is it stuck on a dialog?",
            #[cfg(windows)]
            Err(SendError::Busy) => "YCode is running but never freed a connection slot",
        };
        if Instant::now() >= deadline {
            return Err(stalled.into());
        }
        std::thread::sleep(step);
    }
}

/// Start the desktop app without waiting for it to exit. We deliberately do
/// *not* pass the path here: the app resolves it over the socket once it's up,
/// which keeps a single code path for warm and cold starts.
#[cfg(target_os = "macos")]
fn launch_app() -> Result<(), String> {
    // `open -g -b <bundle-id>` launches without stealing focus; the app raises
    // and focuses its own window when it handles our request, so the window
    // that appears is the one the user asked for.
    let status = std::process::Command::new("open")
        .args(["-g", "-b", "dev.ycode.app"])
        .status()
        .map_err(|e| format!("could not run `open`: {e}"))?;
    if status.success() {
        return Ok(());
    }
    // Bundle id unknown to Launch Services (app never opened, or installed
    // somewhere LS hasn't indexed). Fall back to the conventional location.
    let status = std::process::Command::new("open")
        .args(["-g", "-a", "/Applications/YCode.app"])
        .status()
        .map_err(|e| format!("could not run `open`: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err("YCode is not running and could not be launched — is it installed in /Applications?"
            .into())
    }
}

#[cfg(target_os = "linux")]
fn launch_app() -> Result<(), String> {
    use std::process::Stdio;

    // Candidates, in order: the app binary next to us (AppImage / portable
    // layout), then the packaged name on PATH. Never `ycode` — that's the
    // symlink pointing back at *this* binary, and spawning it would fork
    // forever.
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(dir) = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
    {
        candidates.push(dir.join("YCode"));
    }
    candidates.push(PathBuf::from("YCode"));
    candidates.push(PathBuf::from("ycode-app"));

    let mut last_err = String::new();
    for program in &candidates {
        match std::process::Command::new(program)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(_) => return Ok(()),
            Err(e) => last_err = format!("{}: {e}", program.display()),
        }
    }
    Err(format!(
        "YCode is not running and could not be launched ({last_err})"
    ))
}

/// Windows: the installer puts `YCode.exe` in a per-user location and our
/// shim sits in a directory on PATH, so we can't assume they're adjacent.
/// Try, in order: next to us (portable layout), the recorded install path,
/// then the conventional per-user install dir.
#[cfg(windows)]
fn launch_app() -> Result<(), String> {
    use std::process::Stdio;

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(dir) = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
    {
        candidates.push(dir.join("YCode.exe"));
    }
    // Written by the installer so we don't have to guess (see
    // `ycode_config::cli_installer`).
    if let Ok(recorded) = std::env::var("YCODE_APP_EXE") {
        if !recorded.is_empty() {
            candidates.push(PathBuf::from(recorded));
        }
    }
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        candidates.push(PathBuf::from(local).join(r"Programs\YCode\YCode.exe"));
    }
    if let Ok(pf) = std::env::var("ProgramFiles") {
        candidates.push(PathBuf::from(pf).join(r"YCode\YCode.exe"));
    }

    let mut last_err = String::new();
    for program in &candidates {
        match std::process::Command::new(program)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(_) => return Ok(()),
            Err(e) => last_err = format!("{}: {e}", program.display()),
        }
    }
    Err(format!(
        "YCode is not running and could not be launched ({last_err})"
    ))
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn launch_app() -> Result<(), String> {
    Err("YCode is not running; please start it manually".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_flags_and_paths() {
        let s = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(parse_args(&s(&["--help"])).unwrap(), Command::Help);
        assert_eq!(parse_args(&s(&["-h"])).unwrap(), Command::Help);
        assert_eq!(parse_args(&s(&["--version"])).unwrap(), Command::Version);
        assert_eq!(parse_args(&[]).unwrap(), Command::Open(None));
        assert_eq!(
            parse_args(&s(&["."])).unwrap(),
            Command::Open(Some(".".into()))
        );
        // `--` lets a dash-leading directory name through.
        assert_eq!(
            parse_args(&s(&["--", "-weird"])).unwrap(),
            Command::Open(Some("-weird".into()))
        );
        assert!(parse_args(&s(&["--nope"])).is_err());
        assert!(parse_args(&s(&["a", "b"])).is_err());
    }

    #[test]
    fn resolves_directory_argument() {
        let tmp = std::env::temp_dir().canonicalize().unwrap();
        let target = resolve_target(Some("."), &tmp).unwrap();
        assert_eq!(target.dir, tmp);
        assert_eq!(target.file, None);
    }

    #[test]
    fn resolves_file_to_git_root_with_relative_file() {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir(root.join(".git")).unwrap();
        std::fs::create_dir_all(root.join("src/deep")).unwrap();
        std::fs::write(root.join("src/deep/mod.rs"), "").unwrap();

        let target = resolve_target(Some("src/deep/mod.rs"), &root).unwrap();
        assert_eq!(target.dir, root);
        assert_eq!(target.file, Some(root.join("src/deep/mod.rs")));
    }

    /// Inside a linked worktree `.git` is a *file* pointing at the real git
    /// dir, not a directory — which is why `git_root` tests for existence
    /// rather than `is_dir`. ycode creates worktrees for isolated sessions, so
    /// this is a path users actually hit.
    #[test]
    fn resolves_file_inside_a_linked_worktree() {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::write(root.join(".git"), "gitdir: /elsewhere/.git/worktrees/wt").unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join("src/lib.rs"), "").unwrap();

        let target = resolve_target(Some("src/lib.rs"), &root).unwrap();
        assert_eq!(target.dir, root);
        assert_eq!(target.file, Some(root.join("src/lib.rs")));
    }

    #[test]
    fn resolves_file_without_git_root_to_its_parent() {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join("plain")).unwrap();
        std::fs::write(root.join("plain/notes.txt"), "").unwrap();

        let target = resolve_target(Some("plain/notes.txt"), &root).unwrap();
        assert_eq!(target.dir, root.join("plain"));
        assert_eq!(target.file, Some(root.join("plain/notes.txt")));
    }

    #[test]
    fn missing_path_is_an_error() {
        let tmp = std::env::temp_dir();
        assert!(resolve_target(Some("definitely/not/here"), &tmp).is_err());
    }

    #[test]
    fn expands_tilde() {
        let home = std::env::var("HOME").unwrap();
        assert_eq!(expand_tilde("~"), PathBuf::from(&home));
        assert_eq!(expand_tilde("~/src"), PathBuf::from(&home).join("src"));
        assert_eq!(expand_tilde("/abs"), PathBuf::from("/abs"));
        // Only a leading `~/` is special — `~foo` (other users' homes) is not
        // something we resolve, so it stays verbatim.
        assert_eq!(expand_tilde("~foo"), PathBuf::from("~foo"));
    }

    #[test]
    fn reads_replies() {
        assert!(parse_reply(r#"{"ok":true}"#).is_ok());
        assert_eq!(
            parse_reply(r#"{"ok":false,"error":"boom"}"#).unwrap_err(),
            "boom"
        );
        assert!(parse_reply("").is_err());
        assert!(parse_reply("not json").is_err());
    }
}
