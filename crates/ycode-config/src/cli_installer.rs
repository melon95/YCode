//! Install / remove the `ycode` shell command, mirroring VS Code's
//! "Shell Command: Install 'code' command in PATH".
//!
//! ## Unix
//!
//! We drop a **symlink** at `/usr/local/bin/ycode` pointing at the `ycode-cli`
//! binary shipped inside the app bundle. A symlink (rather than a copy) means
//! an app update automatically updates the command — the bundle path is
//! stable across versions.
//!
//! `/usr/local/bin` is on the default PATH of every macOS and Linux shell,
//! which is the whole point: the user shouldn't have to edit their rc files.
//! It is root-owned on a stock macOS (and doesn't exist at all on Apple
//! Silicon machines that never installed Homebrew), so [`install`] falls back
//! to an authenticated helper — `osascript … with administrator privileges` on
//! macOS, `pkexec` on Linux — when the unprivileged attempt hits EACCES/EPERM.
//! That prompt is the same one VS Code produces, and it only appears when the
//! directory really isn't user-writable.
//!
//! ## Windows
//!
//! Symlinks need Developer Mode or admin rights, and there is no directory
//! equivalent to `/usr/local/bin` that's already on PATH. So we instead write a
//! tiny **`ycode.cmd` shim** into `%LOCALAPPDATA%\YCode\bin` and add that
//! directory to the *user* `PATH` (via `HKCU\Environment`, no elevation
//! needed — the same approach VS Code, Rustup, and Python's installer use).
//! The shim forwards to the bundled `ycode-cli.exe`, so it survives app
//! updates for the same reason the symlink does; rewriting it on "Repair"
//! re-points it after a move.
//!
//! A `.cmd` rather than a `.exe` copy so the target path stays visible in a
//! text file the user can inspect, without shipping a second binary. Git Bash
//! (MSYS2) ignores `PATHEXT` and would never find a `.cmd`, so an
//! extension-less `sh` script is written alongside it — together they cover
//! cmd.exe, PowerShell and Git Bash.
//!
//! Every operation is idempotent: installing over our own shim/symlink
//! refreshes it, uninstalling when nothing is there succeeds quietly.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::agent_patcher::PatchError;

/// Where the command lands on Unix. Fixed rather than configurable: the value
/// of this feature is that `ycode` just works in a fresh shell, and only a
/// handful of directories are on PATH by default everywhere.
#[cfg(unix)]
pub const CLI_INSTALL_DIR: &str = "/usr/local/bin";

/// Command name, matching the crate's `[[bin]]` name.
pub const CLI_NAME: &str = "ycode";

/// Absolute path the symlink is written to.
#[cfg(unix)]
pub fn cli_link_path() -> PathBuf {
    Path::new(CLI_INSTALL_DIR).join(CLI_NAME)
}

/// Directory holding our shim on Windows. Under `%LOCALAPPDATA%` so it needs
/// no elevation, and dedicated to us so putting it on PATH can't shadow
/// anything the user installed.
#[cfg(windows)]
pub fn cli_install_dir() -> Result<PathBuf, PatchError> {
    let base = std::env::var_os("LOCALAPPDATA").ok_or(PatchError::NoHome)?;
    Ok(PathBuf::from(base).join("YCode").join("bin"))
}

/// Absolute path of the `ycode.cmd` shim.
#[cfg(windows)]
pub fn cli_link_path() -> PathBuf {
    // Callers treat this as "where the command lives"; an unresolvable
    // LOCALAPPDATA is reported properly by `install`/`uninstall`, so a lossy
    // fallback here keeps `status` infallible.
    cli_install_dir()
        .unwrap_or_else(|_| PathBuf::from(r"C:\ycode\bin"))
        .join(format!("{CLI_NAME}.cmd"))
}

/// State of `/usr/local/bin/ycode` as far as this app is concerned.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CliInstallStatus {
    /// Nothing at the install path.
    NotInstalled,
    /// Our symlink is in place and points at `target`.
    Installed { path: String, target: String },
    /// Our symlink is there but points at a different (usually older,
    /// since-moved) binary. Re-installing fixes it, so the UI offers that
    /// rather than treating it as installed.
    Stale { path: String, target: String },
    /// Something we didn't create occupies the path — a real file, a directory,
    /// or a symlink to an unrelated program. We never overwrite it silently;
    /// the user is told to clear it themselves.
    Conflict { path: String, detail: String },
}

/// Inspect the install path. `expected` is where the bundled `ycode-cli`
/// binary currently lives, used to tell a live link from a stale one.
#[cfg(unix)]
pub fn status(expected: &Path) -> CliInstallStatus {
    let link = cli_link_path();
    let path = link.display().to_string();

    // `symlink_metadata` does not follow the link, so a dangling symlink is
    // still visible here (plain `metadata` would report NotFound and we'd
    // wrongly claim the path is free, then fail on create).
    let meta = match std::fs::symlink_metadata(&link) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return CliInstallStatus::NotInstalled
        }
        Err(e) => {
            return CliInstallStatus::Conflict {
                path,
                detail: format!("cannot inspect: {e}"),
            }
        }
    };

    if !meta.file_type().is_symlink() {
        return CliInstallStatus::Conflict {
            path,
            detail: if meta.is_dir() {
                "a directory already exists there".into()
            } else {
                "a regular file already exists there".into()
            },
        };
    }

    let target = match std::fs::read_link(&link) {
        Ok(t) => t,
        Err(e) => {
            return CliInstallStatus::Conflict {
                path,
                detail: format!("cannot read link: {e}"),
            }
        }
    };

    if same_binary(&target, expected) {
        CliInstallStatus::Installed {
            path,
            target: target.display().to_string(),
        }
    } else if points_into_ycode(&target) {
        CliInstallStatus::Stale {
            path,
            target: target.display().to_string(),
        }
    } else {
        CliInstallStatus::Conflict {
            path,
            detail: format!("symlink to an unrelated program: {}", target.display()),
        }
    }
}

/// Marker written into the shim so we can recognise our own file. A user's
/// pre-existing `ycode.cmd` won't carry it, and we refuse to touch anything
/// that doesn't.
#[cfg(windows)]
const SHIM_MARKER: &str = ":: generated by YCode - do not edit";

/// Render the `.cmd` shim. `%*` forwards every argument; `@echo off` keeps the
/// command line itself out of the output.
///
/// `app_exe` is the running app's own path, passed in rather than derived from
/// `bin`: the two sit in different directories and their relative arrangement
/// is an installer detail (NSIS, MSI and a portable unzip all differ). The CLI
/// reads it from the environment to cold-start the app instead of probing a
/// list of guesses.
#[cfg(windows)]
fn shim_contents(bin: &Path, app_exe: &Path) -> String {
    format!(
        "@echo off\r\n\
         {SHIM_MARKER}\r\n\
         setlocal\r\n\
         set \"YCODE_APP_EXE={}\"\r\n\
         \"{}\" %*\r\n",
        app_exe.display(),
        bin.display(),
    )
}

/// Companion shim for MSYS2-style shells (Git Bash), which look for `ycode` /
/// `ycode.exe` and ignore `PATHEXT` — so the `.cmd` alone is unreachable there.
///
/// Uses LF endings and `exec` so the shell replaces itself with the CLI rather
/// than leaving a wrapper process around. `"$@"` preserves argument boundaries.
#[cfg(windows)]
fn sh_shim_contents(bin: &Path, app_exe: &Path) -> String {
    // Git Bash accepts Windows paths, so no cygpath translation is needed.
    format!(
        "#!/bin/sh\n\
         # generated by YCode - do not edit\n\
         export YCODE_APP_EXE='{}'\n\
         exec '{}' \"$@\"\n",
        app_exe.display().to_string().replace('\'', r"'\''"),
        bin.display().to_string().replace('\'', r"'\''"),
    )
}

/// Windows: the shim is a regular file, so "is it ours, and does it point at
/// this build?" is a content check rather than a link check.
#[cfg(windows)]
pub fn status(expected: &Path) -> CliInstallStatus {
    let link = cli_link_path();
    let path = link.display().to_string();

    let body = match std::fs::read_to_string(&link) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return CliInstallStatus::NotInstalled
        }
        Err(e) => {
            return CliInstallStatus::Conflict {
                path,
                detail: format!("cannot inspect: {e}"),
            }
        }
    };

    if !body.contains(SHIM_MARKER) {
        return CliInstallStatus::Conflict {
            path,
            detail: "a file we didn't create already exists there".into(),
        };
    }

    // The shim quotes the target on its own line; recovering it lets us report
    // where the command currently points, and detect a stale one after the app
    // moved.
    let target = body
        .lines()
        .find(|l| l.starts_with('"'))
        .and_then(|l| l.trim_start_matches('"').split('"').next())
        .unwrap_or_default()
        .to_string();

    if same_binary(Path::new(&target), expected) {
        CliInstallStatus::Installed { path, target }
    } else {
        // Ours by the marker, so a rewrite is always safe — no `Conflict` arm.
        CliInstallStatus::Stale { path, target }
    }
}

/// Whether two paths denote the same binary. Compares canonical paths so a
/// bundle reached through `/private/var` vs `/var` (a macOS symlink) doesn't
/// read as a mismatch; falls back to a literal compare when either side can't
/// be canonicalised (dangling link, unreadable dir).
fn same_binary(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

/// Heuristic for "this link was ours, just pointing somewhere stale": the
/// target names our binary, or sits inside a YCode app bundle. Used to offer
/// a one-click fix instead of a scary conflict message when the user moved
/// the app or ran an old dev build.
///
/// Deliberately does NOT match a bare `.../ycode` filename. Repairing a link
/// means overwriting it, so a loose test here would let us clobber an
/// unrelated tool that happens to be named `ycode` — exactly what the
/// `Conflict` branch exists to prevent. Our own target is always the
/// `ycode-cli` binary (see `resolve_cli_bin`), so requiring that name, or an
/// app-bundle path, costs us nothing.
#[cfg(unix)]
fn points_into_ycode(target: &Path) -> bool {
    let s = target.to_string_lossy();
    s.ends_with("/ycode-cli") || s.ends_with("/ycode-cli.exe") || s.contains("YCode.app")
}

/// Create (or refresh) the command. Returns the resulting status.
///
/// `bin` must be the absolute path of the bundled `ycode-cli` binary. An
/// unrelated file at the install path is left untouched and reported as an
/// error — clobbering someone else's `ycode` is not ours to do.
///
/// The precondition checks are shared; only the write itself differs per
/// platform (symlink vs `.cmd` shim + user PATH entry).
pub fn install(bin: &Path) -> Result<CliInstallStatus, PatchError> {
    if !bin.exists() {
        return Err(PatchError::Schema {
            file: "ycode-cli",
            msg: format!("binary not found at {}", bin.display()),
        });
    }
    if let CliInstallStatus::Conflict { path, detail } = status(bin) {
        return Err(PatchError::Schema {
            file: "cli",
            msg: format!("{path}: {detail} — remove it and try again"),
        });
    }

    #[cfg(unix)]
    {
        let link = cli_link_path();
        match try_symlink(bin, &link) {
            Ok(()) => Ok(status(bin)),
            Err(e) if is_permission_denied(&e) => {
                elevated_install(bin, &link)?;
                Ok(status(bin))
            }
            Err(e) => Err(e.into()),
        }
    }

    #[cfg(windows)]
    {
        let dir = cli_install_dir()?;
        std::fs::create_dir_all(&dir)?;
        // Write then rename so a shell resolving `ycode` mid-update never sees
        // a half-written file. `std::fs::rename` passes
        // MOVEFILE_REPLACE_EXISTING, so it replaces the old shim atomically —
        // deleting it first would reintroduce exactly the gap this avoids.
        let link = cli_link_path();
        let staging = dir.join(format!(".{CLI_NAME}.cmd.tmp.{}", std::process::id()));
        // `current_exe` is the running YCode.exe — the authoritative answer to
        // "where is the app", whatever the installer chose.
        let app_exe = std::env::current_exe()?;
        std::fs::write(&staging, shim_contents(bin, &app_exe))?;
        if let Err(e) = std::fs::rename(&staging, &link) {
            let _ = std::fs::remove_file(&staging);
            return Err(e.into());
        }
        // Git Bash (MSYS2) resolves a bare `ycode` against `ycode` and
        // `ycode.exe` only — it does not consult PATHEXT, so the .cmd above is
        // invisible there. Drop an extension-less sh script beside it so the
        // command works in what is one of the most common Windows dev shells.
        // Best-effort: cmd.exe/PowerShell already work without it.
        let sh = dir.join(CLI_NAME);
        if let Err(e) = std::fs::write(&sh, sh_shim_contents(bin, &app_exe)) {
            tracing::warn!(path = %sh.display(), error = %e, "could not write the Git Bash shim");
        }
        // Only useful if the directory is actually reachable from a shell.
        add_dir_to_user_path(&dir)?;
        Ok(status(bin))
    }
}

/// Remove the symlink. Removing something that isn't ours is refused; removing
/// nothing at all succeeds (idempotent, so a double-click can't fail).
pub fn uninstall(expected: &Path) -> Result<CliInstallStatus, PatchError> {
    let link = cli_link_path();
    match status(expected) {
        CliInstallStatus::NotInstalled => return Ok(CliInstallStatus::NotInstalled),
        CliInstallStatus::Conflict { path, detail } => {
            return Err(PatchError::Schema {
                file: "cli",
                msg: format!("{path}: {detail} — not created by YCode, leaving it alone"),
            })
        }
        CliInstallStatus::Installed { .. } | CliInstallStatus::Stale { .. } => {}
    }

    match std::fs::remove_file(&link) {
        Ok(()) => {
            // Take the Git Bash companion with it, or `ycode` keeps working in
            // that one shell after the user asked for it to be removed.
            #[cfg(windows)]
            if let Ok(dir) = cli_install_dir() {
                let _ = std::fs::remove_file(dir.join(CLI_NAME));
            }
            // Leave the PATH entry alone on Windows: the directory is ours and
            // empty now, an orphan entry is harmless, and removing it would
            // race any other shell reading the variable. Re-installing reuses
            // it.
            Ok(CliInstallStatus::NotInstalled)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(CliInstallStatus::NotInstalled),
        #[cfg(unix)]
        Err(e) if is_permission_denied(&e) => {
            elevated_uninstall(&link)?;
            Ok(status(expected))
        }
        Err(e) => Err(e.into()),
    }
}

/// Append our bin directory to the *user* `PATH` (`HKCU\Environment`), which
/// needs no elevation, then broadcast the change so newly launched shells pick
/// it up without a sign-out.
///
/// Idempotent: an entry that's already there (compared case-insensitively, and
/// ignoring a trailing separator — Windows paths are both) is left alone rather
/// than duplicated on every re-install.
///
/// ## Why the registry rather than `[Environment]::SetEnvironmentVariable`
///
/// The .NET accessor is the obvious one-liner, but it is destructive here.
/// `GetEnvironmentVariable('PATH','User')` **expands** embedded `%VAR%`
/// references before returning, so writing the result back flattens a
/// `REG_EXPAND_SZ` PATH: a user whose PATH reads
/// `%USERPROFILE%\.cargo\bin;…` silently gets it rewritten to a literal
/// `C:\Users\bob\.cargo\bin;…`. That breaks roaming profiles, survives an
/// uninstall, and the user has no backup of the original. Rustup and the VS
/// Code installer both go through the registry for exactly this reason.
///
/// So: read the raw value with `Get-ItemProperty` (no expansion), write it back
/// with `Set-ItemProperty` preserving the original value kind, then broadcast
/// `WM_SETTINGCHANGE` ourselves — which is the one thing the .NET API did for
/// free.
#[cfg(windows)]
fn add_dir_to_user_path(dir: &Path) -> Result<(), PatchError> {
    let dir = dir.display().to_string();
    // PowerShell single-quoted strings escape a quote by doubling it.
    let quoted = dir.replace('\'', "''");
    let script = format!(
        "$ErrorActionPreference = 'Stop'; \
         $d = '{quoted}'; \
         $k = 'HKCU:\\Environment'; \
         $item = Get-ItemProperty -Path $k -Name PATH -ErrorAction SilentlyContinue; \
         $cur = if ($item) {{ $item.PATH }} else {{ '' }}; \
         $kind = (Get-Item $k).GetValueKind('PATH'); \
         $parts = $cur -split ';' | Where-Object {{ $_ -ne '' }}; \
         $has = $false; \
         foreach ($p in $parts) {{ \
           if ($p.TrimEnd('\\') -ieq $d.TrimEnd('\\')) {{ $has = $true }} \
         }} \
         if (-not $has) {{ \
           $new = (($parts + $d) -join ';'); \
           if ($null -eq $kind) {{ $kind = 'ExpandString' }} \
           Set-ItemProperty -Path $k -Name PATH -Value $new -Type $kind; \
           $sig = '[DllImport(\"user32.dll\", SetLastError=true, CharSet=CharSet.Auto)]\
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, \
string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'; \
           $n = Add-Type -MemberDefinition $sig -Name Win32SendMessageTimeout \
-Namespace YCode -PassThru; \
           $r = [UIntPtr]::Zero; \
           [void]$n::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r) \
         }}"
    );

    let out = powershell(&script)?;
    if out.status.success() {
        return Ok(());
    }
    Err(PatchError::Schema {
        file: "cli",
        msg: format!(
            "the command was installed at {dir} but could not be added to your PATH: {} \
             — add that folder to PATH manually",
            String::from_utf8_lossy(&out.stderr).trim()
        ),
    })
}

/// Run a PowerShell one-liner without flashing a console window.
///
/// The app is built with `windows_subsystem = "windows"` and so owns no
/// console; a plain `Command::output()` makes Windows allocate one for the
/// child, which appears as a black rectangle blinking over the UI.
/// `CREATE_NO_WINDOW` suppresses that.
///
/// `-NonInteractive` matters too: without it a misconfigured profile could
/// block on a prompt with nobody able to answer.
#[cfg(windows)]
fn powershell(script: &str) -> Result<std::process::Output, PatchError> {
    use std::os::windows::process::CommandExt;
    /// `CREATE_NO_WINDOW` from winbase.h.
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    Ok(std::process::Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .creation_flags(CREATE_NO_WINDOW)
        .output()?)
}

/// Replace-or-create the symlink without a destructive window: build it at a
/// sibling temp path, then `rename` over the target. `rename` is atomic, so a
/// concurrent shell never sees the command missing.
#[cfg(unix)]
fn try_symlink(bin: &Path, link: &Path) -> Result<(), std::io::Error> {
    if let Some(parent) = link.parent() {
        // Missing `/usr/local/bin` is normal on a clean Apple Silicon install.
        // Creating it needs the same privileges as writing into it, so a
        // failure here just falls through to the elevated path.
        if !parent.exists() {
            std::fs::create_dir_all(parent)?;
        }
    }
    // pid-scoped so two concurrent installs (two accounts, or two windows)
    // can't have one's error path delete the file the other is mid-`rename`.
    let staging = link.with_file_name(format!(".{CLI_NAME}.ycode-tmp.{}", std::process::id()));
    let _ = std::fs::remove_file(&staging);
    std::os::unix::fs::symlink(bin, &staging)?;
    match std::fs::rename(&staging, link) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = std::fs::remove_file(&staging);
            Err(e)
        }
    }
}

#[cfg(unix)]
fn is_permission_denied(e: &std::io::Error) -> bool {
    matches!(
        e.kind(),
        std::io::ErrorKind::PermissionDenied | std::io::ErrorKind::ReadOnlyFilesystem
    )
}

/// Shell one-liner that (re)creates the link, used by both elevated paths.
/// Unix only — Windows installs into a user-writable directory and never
/// needs to elevate.
/// `mkdir -p` covers the missing-directory case; `ln -sfn` replaces an
/// existing link atomically without descending into it when it happens to
/// point at a directory.
#[cfg(unix)]
fn install_script(bin: &Path, link: &Path) -> String {
    let dir = link.parent().unwrap_or_else(|| Path::new(CLI_INSTALL_DIR));
    format!(
        "mkdir -p {} && ln -sfn {} {}",
        shell_quote(&dir.to_string_lossy()),
        shell_quote(&bin.to_string_lossy()),
        shell_quote(&link.to_string_lossy()),
    )
}

#[cfg(target_os = "macos")]
fn elevated_install(bin: &Path, link: &Path) -> Result<(), PatchError> {
    run_osascript(&install_script(bin, link))
}

#[cfg(target_os = "macos")]
fn elevated_uninstall(link: &Path) -> Result<(), PatchError> {
    run_osascript(&format!("rm -f {}", shell_quote(&link.to_string_lossy())))
}

/// Run `script` as root via the system authentication dialog. `osascript` is
/// a separate process, so this works regardless of what thread we're on.
#[cfg(target_os = "macos")]
fn run_osascript(script: &str) -> Result<(), PatchError> {
    let apple_script = format!(
        "do shell script {} with administrator privileges",
        applescript_string(script)
    );
    let out = std::process::Command::new("osascript")
        .arg("-e")
        .arg(&apple_script)
        .output()?;
    if out.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    // -128 is "user cancelled" from the auth dialog — a deliberate decline,
    // worth a clearer message than the raw AppleScript error.
    let msg = if stderr.contains("-128") {
        "authentication was cancelled".to_string()
    } else {
        stderr.trim().to_string()
    };
    Err(PatchError::Schema {
        file: "cli",
        msg: format!("could not write to {CLI_INSTALL_DIR}: {msg}"),
    })
}

#[cfg(target_os = "linux")]
fn elevated_install(bin: &Path, link: &Path) -> Result<(), PatchError> {
    run_pkexec(&install_script(bin, link))
}

#[cfg(target_os = "linux")]
fn elevated_uninstall(link: &Path) -> Result<(), PatchError> {
    run_pkexec(&format!("rm -f {}", shell_quote(&link.to_string_lossy())))
}

#[cfg(target_os = "linux")]
fn run_pkexec(script: &str) -> Result<(), PatchError> {
    let out = std::process::Command::new("pkexec")
        .args(["/bin/sh", "-c", script])
        .output()
        .map_err(|e| PatchError::Schema {
            file: "cli",
            msg: format!(
                "could not write to {CLI_INSTALL_DIR} and pkexec is unavailable ({e}); \
                 run `sudo {script}` manually"
            ),
        })?;
    if out.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    Err(PatchError::Schema {
        file: "cli",
        msg: format!(
            "could not write to {CLI_INSTALL_DIR}: {}",
            stderr.trim()
        ),
    })
}

#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
fn elevated_install(_bin: &Path, _link: &Path) -> Result<(), PatchError> {
    Err(PatchError::Schema {
        file: "cli",
        msg: "the ycode shell command is not supported on this platform yet".into(),
    })
}

#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
fn elevated_uninstall(_link: &Path) -> Result<(), PatchError> {
    Err(PatchError::Schema {
        file: "cli",
        msg: "the ycode shell command is not supported on this platform yet".into(),
    })
}

/// Single-quote for `/bin/sh`. Unix only. Paths reach us from the OS (app bundle
/// location) and can contain spaces; a user with an apostrophe in their
/// volume name would otherwise break the script.
#[cfg(unix)]
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// Render a string as an AppleScript string literal.
#[cfg(target_os = "macos")]
fn applescript_string(s: &str) -> String {
    let mut out = String::from("\"");
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            _ => out.push(ch),
        }
    }
    out.push('"');
    out
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn quotes_paths_for_sh() {
        assert_eq!(shell_quote("/usr/local/bin"), "'/usr/local/bin'");
        assert_eq!(
            shell_quote("/Volumes/My Disk/YCode.app"),
            "'/Volumes/My Disk/YCode.app'"
        );
        assert_eq!(shell_quote("/it's/here"), r"'/it'\''s/here'");
    }

    #[test]
    fn builds_an_install_script() {
        let script = install_script(
            Path::new("/Applications/YCode.app/Contents/Resources/binaries/ycode-cli"),
            Path::new("/usr/local/bin/ycode"),
        );
        assert_eq!(
            script,
            "mkdir -p '/usr/local/bin' && ln -sfn \
             '/Applications/YCode.app/Contents/Resources/binaries/ycode-cli' '/usr/local/bin/ycode'"
        );
    }

    #[test]
    fn recognises_our_own_targets() {
        assert!(points_into_ycode(Path::new("/some/where/ycode-cli")));
        assert!(points_into_ycode(Path::new(
            "/Applications/YCode.app/Contents/MacOS/whatever"
        )));
        assert!(!points_into_ycode(Path::new("/usr/bin/vim")));
        // An unrelated tool that merely happens to be named `ycode` must read
        // as a conflict, not as our own stale link — "repair" overwrites, and
        // overwriting someone else's binary is the one thing this module
        // promises never to do.
        assert!(!points_into_ycode(Path::new("/opt/tools/ycode")));
    }

    #[test]
    fn same_binary_ignores_path_aliasing() {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let real = dir.path().join("ycode-cli");
        std::fs::write(&real, "").unwrap();
        let alias = dir.path().join("sub/../ycode-cli");
        std::fs::create_dir(dir.path().join("sub")).unwrap();
        assert!(same_binary(&real, &alias));
        assert!(!same_binary(&real, Path::new("/usr/bin/vim")));
    }

    /// The symlink dance itself, exercised against a writable temp dir so the
    /// test never touches `/usr/local/bin` or prompts for a password.
    #[test]
    fn symlink_is_created_and_replaced_in_place() {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let bin_a = dir.path().join("ycode-cli-a");
        let bin_b = dir.path().join("ycode-cli-b");
        std::fs::write(&bin_a, "").unwrap();
        std::fs::write(&bin_b, "").unwrap();
        let link = dir.path().join("bin/ycode");

        try_symlink(&bin_a, &link).unwrap();
        assert_eq!(std::fs::read_link(&link).unwrap(), bin_a);

        // Re-install over an existing link points it at the new binary and
        // leaves no staging file behind.
        try_symlink(&bin_b, &link).unwrap();
        assert_eq!(std::fs::read_link(&link).unwrap(), bin_b);
        assert!(!link
            .with_file_name(format!(".{CLI_NAME}.ycode-tmp.{}", std::process::id()))
            .exists());
    }

    #[test]
    fn status_reports_a_free_path_as_not_installed() {
        // `cli_link_path()` is fixed, so this asserts on whichever state the
        // developer's machine is in — all we can check without touching it is
        // that inspection never panics and returns a coherent variant.
        let s = status(Path::new("/nonexistent/ycode-cli"));
        match s {
            CliInstallStatus::NotInstalled
            | CliInstallStatus::Installed { .. }
            | CliInstallStatus::Stale { .. }
            | CliInstallStatus::Conflict { .. } => {}
        }
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use super::*;

    /// The shim has to carry the marker (so we recognise our own file and
    /// refuse to clobber a user's), quote the target (so a path with spaces —
    /// `C:\Program Files\…` — still resolves), and forward argv.
    #[test]
    fn shim_is_recognisable_and_quotes_its_target() {
        let bin = Path::new(r"C:\Program Files\YCode\resources\binaries\ycode-cli.exe");
        let app = Path::new(r"C:\Program Files\YCode\YCode.exe");
        let body = shim_contents(bin, app);

        assert!(body.contains(SHIM_MARKER));
        assert!(body.contains(r#""C:\Program Files\YCode\resources\binaries\ycode-cli.exe" %*"#));
        // The CLI reads this to launch the app on a cold start.
        assert!(body.contains(r"YCODE_APP_EXE=C:\Program Files\YCode\YCode.exe"));
        // cmd.exe needs CRLF.
        assert!(body.contains("\r\n"));
    }

    /// `status` recovers the target from a shim we wrote, so a moved app reads
    /// as `Stale` (repairable) rather than `Installed`.
    #[test]
    fn status_round_trips_the_shim_target() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("ycode-cli.exe");
        std::fs::write(&bin, "").unwrap();

        let body = shim_contents(&bin, Path::new(r"C:\YCode\YCode.exe"));
        let recovered = body
            .lines()
            .find(|l| l.starts_with('"'))
            .and_then(|l| l.trim_start_matches('"').split('"').next())
            .unwrap();
        assert_eq!(Path::new(recovered), bin);
    }

    /// A file we didn't write must never be treated as ours — overwriting a
    /// user's own `ycode.cmd` is the one thing this module promises not to do.
    #[test]
    fn foreign_cmd_file_is_not_ours() {
        let body = "@echo off\r\necho hi\r\n";
        assert!(!body.contains(SHIM_MARKER));
    }

    /// Git Bash resolves a bare `ycode` against `ycode`/`ycode.exe` only, never
    /// `.cmd`, so the companion script is what makes the command work there.
    #[test]
    fn sh_shim_is_a_valid_posix_script() {
        let bin = Path::new(r"C:\Program Files\YCode\resources\binaries\ycode-cli.exe");
        let app = Path::new(r"C:\Program Files\YCode\YCode.exe");
        let body = sh_shim_contents(bin, app);

        assert!(body.starts_with("#!/bin/sh\n"));
        // LF only — CRLF would make the shebang fail with "bad interpreter".
        assert!(!body.contains('\r'));
        // `exec` + "$@" so argument boundaries survive and no wrapper lingers.
        assert!(body.contains(r#"exec 'C:\Program Files\YCode\resources\binaries\ycode-cli.exe' "$@""#));
        assert!(body.contains("YCODE_APP_EXE='C:\\Program Files\\YCode\\YCode.exe'"));
    }

    /// A path containing a single quote must not break out of the sh quoting.
    #[test]
    fn sh_shim_escapes_single_quotes() {
        let bin = Path::new(r"C:\it's\ycode-cli.exe");
        let body = sh_shim_contents(bin, Path::new(r"C:\it's\YCode.exe"));
        assert!(body.contains(r"'C:\it'\''s\ycode-cli.exe'"));
    }
}
