//! S6: the LoC budget for "adding a new CLI agent".
//!
//! The plan locks this at 500 LoC of NEW code (adapter implementation + its
//! Cargo.toml). The EchoAdapter crate is the canary: if it grows past 500 LoC,
//! the AgentAdapter trait is leaking too much downstream concern and the
//! abstraction needs revisiting.

use std::path::Path;

use anyhow::{bail, Context, Result};
use tracing::info;

const BUDGET: usize = 500;

/// Crate roots counted toward the budget. We measure the echo-adapter crate
/// because it's the worked example. ACP and PTY adapters are NOT counted —
/// they're upstream protocol implementations, not "new CLI" cost.
const ROOTS: &[&str] = &["crates/ycode-echo-adapter"];

pub fn run() -> Result<()> {
    let workspace = workspace_root()?;
    let mut total = 0usize;
    let mut breakdown = Vec::new();
    for root in ROOTS {
        let path = workspace.join(root);
        let n = count_lines(&path).with_context(|| format!("counting {}", path.display()))?;
        breakdown.push((path.display().to_string(), n));
        total += n;
    }
    for (p, n) in &breakdown {
        eprintln!("  {n:>4}  {p}");
    }
    eprintln!("  ----");
    eprintln!("  {total:>4}  total (budget {BUDGET})");

    if total > BUDGET {
        bail!(
            "S6 LoC gate FAILED: {total} > {BUDGET}. The AgentAdapter trait may be leaking downstream concern."
        );
    }
    info!("smoke loc-gate: PASS ({total}/{BUDGET})");
    Ok(())
}

/// Find the workspace root by walking up from the current dir until we find
/// a `Cargo.toml` containing `[workspace]`.
fn workspace_root() -> Result<std::path::PathBuf> {
    let mut here = std::env::current_dir()?;
    loop {
        let candidate = here.join("Cargo.toml");
        if candidate.exists() {
            let raw = std::fs::read_to_string(&candidate).unwrap_or_default();
            if raw.contains("[workspace]") {
                return Ok(here);
            }
        }
        if !here.pop() {
            bail!("could not find workspace root from cwd");
        }
    }
}

fn count_lines(crate_dir: &Path) -> Result<usize> {
    let mut total = 0;
    visit(crate_dir, &mut |p| {
        let ext = p.extension().and_then(|s| s.to_str()).unwrap_or("");
        if ext == "rs" || p.file_name().and_then(|s| s.to_str()) == Some("Cargo.toml") {
            let content = std::fs::read_to_string(p).unwrap_or_default();
            total += content.lines().count();
        }
    })?;
    Ok(total)
}

fn visit(dir: &Path, on_file: &mut impl FnMut(&Path)) -> Result<()> {
    if !dir.is_dir() {
        return Ok(());
    }
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        // Skip target/ and any .git/.
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if name == "target" || name.starts_with('.') {
            continue;
        }
        if path.is_dir() {
            visit(&path, on_file)?;
        } else {
            on_file(&path);
        }
    }
    Ok(())
}
