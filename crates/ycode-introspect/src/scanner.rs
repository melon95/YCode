//! Cross-agent workspace scanner. Given a project cwd, return every session
//! both backends know about.

use std::path::{Path, PathBuf};

use crate::{claude, codex, DiscoveredSession, IntrospectError};

/// Discover claude + codex sessions for `cwd`. Errors from one backend are
/// logged and the other backend's results are still returned. Per plan
/// §6.3 (`workspace.scan_known`).
pub fn scan_workspace(home: &Path, cwd: &Path) -> Vec<DiscoveredSession> {
    let mut out = Vec::new();
    match claude::scan_workspace(home, cwd) {
        Ok(mut found) => out.append(&mut found),
        Err(IntrospectError::Io(e)) => tracing::warn!(error = %e, "claude scan failed"),
        Err(e) => tracing::warn!(error = %e, "claude scan failed"),
    }
    match codex::scan_workspace(home, cwd) {
        Ok(mut found) => out.append(&mut found),
        Err(IntrospectError::Io(e)) => tracing::warn!(error = %e, "codex scan failed"),
        Err(e) => tracing::warn!(error = %e, "codex scan failed"),
    }
    out
}

/// Stream every line of `path`, parse + normalise to UnifiedEvent, dispatch
/// to `cb`. Stops on first IO error. Per plan §6.2.5 / §8.20.
pub fn read_all_events<F>(
    agent: &str,
    session_id: &str,
    path: &Path,
    mut cb: F,
) -> Result<u64, IntrospectError>
where
    F: FnMut(crate::unified::UnifiedEvent),
{
    use std::io::{BufRead, BufReader};
    let f = std::fs::File::open(path).map_err(|e| IntrospectError::Io(e.to_string()))?;
    let reader = BufReader::new(f);
    let mut seq: u64 = 0;
    for line in reader.lines() {
        let line = line.map_err(|e| IntrospectError::Io(e.to_string()))?;
        if line.trim().is_empty() {
            continue;
        }
        match agent {
            "claude" => match claude::parse_line(&line) {
                Ok(raw) => cb(claude::normalize(raw, seq, session_id)),
                Err(e) => tracing::warn!(error = %e, seq, "claude parse failed"),
            },
            "codex" => match codex::parse_line(&line) {
                Ok(raw) => {
                    if let Some(ev) = codex::normalize(raw, seq, session_id) {
                        cb(ev);
                    }
                }
                Err(e) => tracing::warn!(error = %e, seq, "codex parse failed"),
            },
            _ => tracing::warn!(agent, "read_all_events: unknown agent"),
        }
        seq += 1;
    }
    Ok(seq)
}

/// Convenience for the IPC layer: collect every event up to `max_events`.
pub fn read_all_events_vec(
    agent: &str,
    session_id: &str,
    path: &Path,
    max_events: usize,
) -> Result<Vec<crate::unified::UnifiedEvent>, IntrospectError> {
    let mut out = Vec::new();
    read_all_events(agent, session_id, path, |ev| {
        if out.len() < max_events {
            out.push(ev);
        }
    })?;
    Ok(out)
}

/// Stand-alone helper for callers that just want a list of session jsonl
/// paths for a given workspace without per-agent dispatch.
pub fn all_jsonl_paths(home: &Path, cwd: &Path) -> Vec<PathBuf> {
    scan_workspace(home, cwd)
        .into_iter()
        .map(|s| s.jsonl_path)
        .collect()
}
