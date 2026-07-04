//! Server installer.
//!
//! Two installers today, dispatched on `InstallSpec`:
//!
//! - **GithubReleaseGzip** — hit `/repos/<repo>/releases/latest`, pick the
//!   asset matching the current platform, stream-download the `.gz`, gunzip
//!   into `<server_dir>/<binary_name>`, mark it executable.
//! - **Npm** — `npm install <packages>...` inside `<server_dir>` so the
//!   per-server `node_modules` is self-contained.
//!
//! Progress is reported through an `mpsc::Sender<InstallProgress>` so the IPC
//! layer can stream `LspInstallProgress` events to the webview.

use std::io::Read as _;
use std::path::Path;
use std::process::Stdio;

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;
use tracing::{info, warn};
use ts_rs::TS;

use crate::dirs::server_root;
use crate::manifest::{InstallSpec, ServerManifest};
use crate::LspError;

/// Coarse phase of an in-flight install, surfaced to the UI for progress.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "snake_case")]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub enum InstallStage {
    Resolving,
    Downloading,
    Extracting,
    RunningNpm,
    Finalizing,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export, export_to = "../../ycode-ipc/bindings/")]
pub struct InstallProgress {
    pub server_id: String,
    pub stage: InstallStage,
    /// 0–100. `None` means "indeterminate" (e.g. running `npm install`,
    /// where we don't get byte-level progress).
    pub percent: Option<u8>,
    /// Short human-readable status, e.g. "Downloading rust-analyzer 2024-08-01".
    pub message: String,
}

impl InstallProgress {
    fn new(server_id: &str, stage: InstallStage, percent: Option<u8>, message: &str) -> Self {
        Self {
            server_id: server_id.to_string(),
            stage,
            percent,
            message: message.to_string(),
        }
    }
}

/// Resulting record from a successful install. Caller persists this in the
/// `lsp_installations` SQLite table.
#[derive(Clone, Debug)]
pub struct InstallOutcome {
    pub server_id: String,
    pub version: String,
    pub binary_path: String,
}

/// Install `manifest`. Returns the install record on success. Progress
/// updates are dropped silently if the receiver is gone — install always
/// runs to completion.
pub async fn install(
    manifest: &ServerManifest,
    progress: mpsc::Sender<InstallProgress>,
) -> Result<InstallOutcome, LspError> {
    let root = server_root(&manifest.id)?;
    tokio::fs::create_dir_all(root.as_std_path()).await?;

    let _ = progress
        .send(InstallProgress::new(
            &manifest.id,
            InstallStage::Resolving,
            None,
            "Resolving install plan",
        ))
        .await;

    let outcome = match &manifest.install {
        InstallSpec::GithubReleaseGzip {
            repo,
            assets,
            binary_name,
        } => {
            install_github_gzip(
                &manifest.id,
                repo,
                assets,
                binary_name,
                root.as_std_path(),
                &progress,
            )
            .await?
        }
        InstallSpec::Npm { packages } => {
            install_npm(&manifest.id, packages, root.as_std_path(), &progress).await?
        }
        InstallSpec::GithubReleaseArchive { repo, assets } => {
            install_github_archive(&manifest.id, repo, assets, root.as_std_path(), &progress).await?
        }
        InstallSpec::ArchiveUrl { url } => {
            install_archive_url(&manifest.id, url, root.as_std_path(), &progress).await?
        }
        InstallSpec::GoInstall { package } => {
            install_go(&manifest.id, package, root.as_std_path(), &progress).await?
        }
    };

    let _ = progress
        .send(InstallProgress::new(
            &manifest.id,
            InstallStage::Finalizing,
            Some(100),
            "Installed",
        ))
        .await;

    info!(server_id = %manifest.id, version = %outcome.version, "lsp installed");
    Ok(outcome)
}

/// Wipe the install directory.
pub async fn uninstall(server_id: &str) -> Result<(), LspError> {
    let root = server_root(server_id)?;
    if root.as_std_path().exists() {
        tokio::fs::remove_dir_all(root.as_std_path()).await?;
    }
    Ok(())
}

// ── GitHub release installer ───────────────────────────────────────────────

async fn install_github_gzip(
    server_id: &str,
    repo: &str,
    assets: &crate::manifest::AssetPattern,
    binary_name: &str,
    root: &Path,
    progress: &mpsc::Sender<InstallProgress>,
) -> Result<InstallOutcome, LspError> {
    let asset_name = assets
        .for_current_platform()
        .ok_or_else(|| LspError::NoMatchingAsset(server_id.to_string()))?;

    let client = http_client()?;

    // `tag_name` + the matched asset's `browser_download_url`. Hitting the
    // latest endpoint avoids us having to track release SHAs ourselves.
    let release = fetch_latest_release(&client, repo).await?;
    let download_url = release
        .assets
        .iter()
        .find(|a| a.name == asset_name)
        .map(|a| a.browser_download_url.clone())
        .ok_or_else(|| LspError::NoMatchingAsset(server_id.to_string()))?;

    let _ = progress
        .send(InstallProgress::new(
            server_id,
            InstallStage::Downloading,
            Some(0),
            &format!("Downloading {} {}", server_id, release.tag_name),
        ))
        .await;

    // Stream the .gz into a temp file under the server dir so partial
    // downloads don't pollute the on-disk binary.
    let tmp_path = root.join(format!("{binary_name}.gz.part"));
    let total = stream_download(&client, &download_url, &tmp_path, server_id, progress).await?;

    let _ = progress
        .send(InstallProgress::new(
            server_id,
            InstallStage::Extracting,
            None,
            "Decompressing",
        ))
        .await;

    let binary_path = root.join(binary_name);
    decompress_gzip(&tmp_path, &binary_path).await?;
    tokio::fs::remove_file(&tmp_path).await.ok();

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = tokio::fs::metadata(&binary_path).await?.permissions();
        perms.set_mode(0o755);
        tokio::fs::set_permissions(&binary_path, perms).await?;
    }

    info!(
        server_id = %server_id,
        bytes = total,
        path = %binary_path.display(),
        "github release installed"
    );

    Ok(InstallOutcome {
        server_id: server_id.to_string(),
        version: release.tag_name,
        binary_path: binary_path.to_string_lossy().into_owned(),
    })
}

#[derive(Debug, Deserialize)]
struct GhRelease {
    tag_name: String,
    assets: Vec<GhAsset>,
}

#[derive(Debug, Deserialize)]
struct GhAsset {
    name: String,
    browser_download_url: String,
}

async fn fetch_latest_release(client: &reqwest::Client, repo: &str) -> Result<GhRelease, LspError> {
    let url = format!("https://api.github.com/repos/{repo}/releases/latest");
    let resp = client.get(&url).send().await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(LspError::GithubRelease(format!(
            "{url} → {status}: {body}"
        )));
    }
    let release: GhRelease = resp.json().await?;
    Ok(release)
}

async fn stream_download(
    client: &reqwest::Client,
    url: &str,
    dest: &Path,
    server_id: &str,
    progress: &mpsc::Sender<InstallProgress>,
) -> Result<u64, LspError> {
    let resp = client.get(url).send().await?;
    if !resp.status().is_success() {
        let status = resp.status();
        return Err(LspError::GithubRelease(format!(
            "download {url} → {status}"
        )));
    }
    let total = resp.content_length();
    let mut file = tokio::fs::File::create(dest).await?;
    let mut downloaded: u64 = 0;
    let mut last_pct: u8 = 0;
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        file.write_all(&chunk).await?;
        downloaded += chunk.len() as u64;
        if let Some(t) = total {
            if t > 0 {
                let pct = ((downloaded as f64 / t as f64) * 100.0).min(99.0) as u8;
                if pct > last_pct {
                    last_pct = pct;
                    let _ = progress
                        .send(InstallProgress::new(
                            server_id,
                            InstallStage::Downloading,
                            Some(pct),
                            &format!(
                                "Downloaded {} / {}",
                                format_mb(downloaded),
                                format_mb(t)
                            ),
                        ))
                        .await;
                }
            }
        }
    }
    file.flush().await?;
    Ok(downloaded)
}

async fn decompress_gzip(src: &Path, dest: &Path) -> Result<(), LspError> {
    let src = src.to_path_buf();
    let dest = dest.to_path_buf();
    tokio::task::spawn_blocking(move || -> Result<(), LspError> {
        let input = std::fs::File::open(&src)?;
        let mut decoder = flate2::read::GzDecoder::new(input);
        let mut output = std::fs::File::create(&dest)?;
        let mut buf = [0u8; 64 * 1024];
        loop {
            let n = decoder.read(&mut buf)?;
            if n == 0 {
                break;
            }
            std::io::Write::write_all(&mut output, &buf[..n])?;
        }
        Ok(())
    })
    .await
    .map_err(|e| LspError::GithubRelease(format!("decompress task: {e}")))?
}

// ── Archive installers (tar.gz / zip) ──────────────────────────────────────

/// Download a per-platform `.tar.gz`/`.zip` asset from the latest GitHub
/// release and extract it into the server dir (used for OmniSharp).
async fn install_github_archive(
    server_id: &str,
    repo: &str,
    assets: &crate::manifest::AssetPattern,
    root: &Path,
    progress: &mpsc::Sender<InstallProgress>,
) -> Result<InstallOutcome, LspError> {
    let asset_name = assets
        .for_current_platform()
        .ok_or_else(|| LspError::NoMatchingAsset(server_id.to_string()))?;

    let client = http_client()?;
    let release = fetch_latest_release(&client, repo).await?;
    let download_url = release
        .assets
        .iter()
        .find(|a| a.name == asset_name)
        .map(|a| a.browser_download_url.clone())
        .ok_or_else(|| LspError::NoMatchingAsset(server_id.to_string()))?;

    let _ = progress
        .send(InstallProgress::new(
            server_id,
            InstallStage::Downloading,
            Some(0),
            &format!("Downloading {} {}", server_id, release.tag_name),
        ))
        .await;

    let tmp_path = root.join(format!("{server_id}-archive.part"));
    stream_download(&client, &download_url, &tmp_path, server_id, progress).await?;
    extract_archive(&tmp_path, asset_name, root, server_id, progress).await?;
    tokio::fs::remove_file(&tmp_path).await.ok();

    Ok(InstallOutcome {
        server_id: server_id.to_string(),
        version: release.tag_name,
        binary_path: root.to_string_lossy().into_owned(),
    })
}

/// Download a `.tar.gz`/`.zip` from a fixed URL and extract it (used for the
/// Eclipse JDT LS tarball, which lives on eclipse.org, not GitHub).
async fn install_archive_url(
    server_id: &str,
    url: &str,
    root: &Path,
    progress: &mpsc::Sender<InstallProgress>,
) -> Result<InstallOutcome, LspError> {
    let client = http_client()?;

    let _ = progress
        .send(InstallProgress::new(
            server_id,
            InstallStage::Downloading,
            Some(0),
            &format!("Downloading {server_id}"),
        ))
        .await;

    let tmp_path = root.join(format!("{server_id}-archive.part"));
    stream_download(&client, url, &tmp_path, server_id, progress).await?;
    extract_archive(&tmp_path, url, root, server_id, progress).await?;
    tokio::fs::remove_file(&tmp_path).await.ok();

    Ok(InstallOutcome {
        server_id: server_id.to_string(),
        version: "latest".into(),
        binary_path: root.to_string_lossy().into_owned(),
    })
}

/// Extract `archive` into `dest`, choosing tar.gz vs zip from `name_hint`
/// (an asset filename or a download URL). Runs on a blocking thread since the
/// `tar`/`zip` crates are synchronous.
async fn extract_archive(
    archive: &Path,
    name_hint: &str,
    dest: &Path,
    server_id: &str,
    progress: &mpsc::Sender<InstallProgress>,
) -> Result<(), LspError> {
    let _ = progress
        .send(InstallProgress::new(
            server_id,
            InstallStage::Extracting,
            None,
            "Extracting archive",
        ))
        .await;

    let archive = archive.to_path_buf();
    let dest = dest.to_path_buf();
    let hint = name_hint.to_lowercase();
    tokio::task::spawn_blocking(move || -> Result<(), LspError> {
        if hint.ends_with(".zip") {
            extract_zip(&archive, &dest)
        } else if hint.ends_with(".tar.gz") || hint.ends_with(".tgz") {
            extract_tar_gz(&archive, &dest)
        } else {
            Err(LspError::Extract(format!("unknown archive format: {hint}")))
        }
    })
    .await
    .map_err(|e| LspError::Extract(format!("extract task: {e}")))?
}

fn extract_tar_gz(archive: &Path, dest: &Path) -> Result<(), LspError> {
    let file = std::fs::File::open(archive)?;
    let decoder = flate2::read::GzDecoder::new(file);
    let mut tar = tar::Archive::new(decoder);
    tar.set_preserve_permissions(true);
    tar.unpack(dest).map_err(|e| LspError::Extract(e.to_string()))?;
    Ok(())
}

fn extract_zip(archive: &Path, dest: &Path) -> Result<(), LspError> {
    let file = std::fs::File::open(archive)?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| LspError::Extract(e.to_string()))?;
    for i in 0..zip.len() {
        let mut entry = zip
            .by_index(i)
            .map_err(|e| LspError::Extract(e.to_string()))?;
        // Skip entries with absolute paths or `..` traversal.
        let Some(rel) = entry.enclosed_name() else {
            continue;
        };
        let out_path = dest.join(rel);
        if entry.is_dir() {
            std::fs::create_dir_all(&out_path)?;
            continue;
        }
        if let Some(parent) = out_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut out = std::fs::File::create(&out_path)?;
        std::io::copy(&mut entry, &mut out)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Some(mode) = entry.unix_mode() {
                std::fs::set_permissions(&out_path, std::fs::Permissions::from_mode(mode)).ok();
            }
        }
    }
    Ok(())
}

// ── Go toolchain installer ─────────────────────────────────────────────────

/// `go install <package>` with `GOBIN` pointed at the server dir, producing a
/// single binary there (used for gopls). Requires `go` on PATH.
async fn install_go(
    server_id: &str,
    package: &str,
    root: &Path,
    progress: &mpsc::Sender<InstallProgress>,
) -> Result<InstallOutcome, LspError> {
    if !command_on_path("go") {
        return Err(LspError::MissingTool("go".into()));
    }

    let _ = progress
        .send(InstallProgress::new(
            server_id,
            // No byte-level progress from a build; reuse the indeterminate
            // "running a package tool" stage.
            InstallStage::RunningNpm,
            None,
            &format!("Running go install {package}"),
        ))
        .await;

    let mut cmd = tokio::process::Command::new("go");
    cmd.arg("install")
        .arg(package)
        .env("GOBIN", root)
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let output = cmd
        .output()
        .await
        .map_err(|e| LspError::InstallCommand("go install".into(), e.to_string()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        warn!(server_id = %server_id, stderr = %stderr, "go install failed");
        return Err(LspError::InstallCommand("go install".into(), stderr));
    }

    // Binary name = last path segment of the package, minus any `@version`.
    let base = package
        .split('@')
        .next()
        .unwrap_or(package)
        .rsplit('/')
        .next()
        .unwrap_or("server");
    let binary_name = if cfg!(windows) {
        format!("{base}.exe")
    } else {
        base.to_string()
    };
    let binary_path = root.join(binary_name);

    Ok(InstallOutcome {
        server_id: server_id.to_string(),
        version: "latest".into(),
        binary_path: binary_path.to_string_lossy().into_owned(),
    })
}

fn http_client() -> Result<reqwest::Client, LspError> {
    let client = reqwest::Client::builder()
        // GitHub rejects requests without a UA.
        .user_agent(concat!("ycode-lsp/", env!("CARGO_PKG_VERSION")))
        // Cap a single request at 5 minutes — release binaries on a slow link
        // can still finish, but a stuck connection won't pin the install task
        // forever.
        .timeout(std::time::Duration::from_secs(300))
        .build()?;
    Ok(client)
}

// ── npm installer ──────────────────────────────────────────────────────────

async fn install_npm(
    server_id: &str,
    packages: &[String],
    root: &Path,
    progress: &mpsc::Sender<InstallProgress>,
) -> Result<InstallOutcome, LspError> {
    if !command_on_path("npm") {
        return Err(LspError::MissingTool("npm".into()));
    }

    let _ = progress
        .send(InstallProgress::new(
            server_id,
            InstallStage::RunningNpm,
            None,
            &format!("Running npm install {}", packages.join(" ")),
        ))
        .await;

    // Ensure a package.json exists so `npm install <pkg>` writes a
    // `node_modules` here without complaining about a missing `name` field.
    let pkg_json = root.join("package.json");
    if !pkg_json.exists() {
        let body = format!(
            "{{\n  \"name\": \"ycode-lsp-{server_id}\",\n  \"private\": true,\n  \"version\": \"0.0.0\"\n}}\n"
        );
        tokio::fs::write(&pkg_json, body).await?;
    }

    let mut cmd = tokio::process::Command::new("npm");
    cmd.arg("install")
        .arg("--no-audit")
        .arg("--no-fund")
        .arg("--loglevel=error");
    for p in packages {
        cmd.arg(p);
    }
    cmd.current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let output = cmd
        .output()
        .await
        .map_err(|e| LspError::InstallCommand("npm install".into(), e.to_string()))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        warn!(server_id = %server_id, stderr = %stderr, "npm install failed");
        return Err(LspError::InstallCommand("npm install".into(), stderr));
    }

    // Best-effort: parse the installed version of the *first* package so the
    // UI can show "vX.Y.Z" in the card. If parsing fails, we fall back to
    // "installed" — the binary on disk is the source of truth either way.
    let primary = packages.first().cloned().unwrap_or_default();
    let version = read_npm_version(root, &primary).await.unwrap_or_else(|| {
        warn!(server_id = %server_id, "could not read installed version");
        "installed".into()
    });

    let binary_path = root.to_string_lossy().into_owned();
    Ok(InstallOutcome {
        server_id: server_id.to_string(),
        version,
        binary_path,
    })
}

async fn read_npm_version(root: &Path, package: &str) -> Option<String> {
    let pkg_path = root.join("node_modules").join(package).join("package.json");
    let raw = tokio::fs::read_to_string(&pkg_path).await.ok()?;
    let value: serde_json::Value = serde_json::from_str(&raw).ok()?;
    value
        .get("version")?
        .as_str()
        .map(|s| format!("v{s}"))
}

/// Render a byte count as `X.Y MB` (binary, 1 MB = 1 048 576 B). Files under
/// a MiB still report two decimals — `0.05 MB` reads more cleanly than `51 KB`
/// when the next sample will jump to `0.10 MB` anyway.
fn format_mb(bytes: u64) -> String {
    let mb = bytes as f64 / 1_048_576.0;
    format!("{mb:.2} MB")
}

#[cfg(test)]
mod tests {
    use super::format_mb;

    #[test]
    fn format_mb_rounds_to_two_decimals() {
        assert_eq!(format_mb(0), "0.00 MB");
        assert_eq!(format_mb(1_048_576), "1.00 MB");
        assert_eq!(format_mb(14_506_043), "13.83 MB");
    }
}

fn command_on_path(cmd: &str) -> bool {
    let Some(paths) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&paths).any(|dir| {
        let candidate = dir.join(cmd);
        candidate.is_file()
            || (cfg!(windows) && dir.join(format!("{cmd}.cmd")).is_file())
            || (cfg!(windows) && dir.join(format!("{cmd}.exe")).is_file())
    })
}
