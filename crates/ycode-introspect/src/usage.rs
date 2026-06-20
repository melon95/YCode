//! Token usage + cost aggregation across CLI agent jsonl sessions.
//!
//! The agents are the source of truth for what they spent: every Claude
//! assistant message carries a `message.usage` block, and every Codex
//! `token_count` event carries a running `total_token_usage`. This module
//! reuses the same on-disk files the history viewer reads ([`crate::scanner`])
//! and rolls them up into per-session / per-model / per-day totals plus an
//! estimated USD cost.
//!
//! Two source shapes, normalised here:
//! * **Claude** — one `usage` block *per assistant message*, i.e. incremental.
//!   The same `message.id` is written to several lines (a thinking line, a
//!   text line, a tool_use line…) each repeating the *same* usage, so we
//!   dedupe by `message.id` and keep the largest copy (best-wins, mirrors
//!   ccusage). Modern Claude (2.x) no longer emits `requestId`, so the id is
//!   the only reliable dedupe key.
//! * **Codex** — `token_count` events report *cumulative* session totals, so
//!   we take the last one rather than summing. The model comes from the
//!   `turn_context` line (`payload.model`).
//!
//! Pricing is an offline estimate (see [`price`]). It covers the current
//! Claude / GPT / Gemini families; unknown models still count tokens but
//! contribute `0` cost so we never invent a number we can't back.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::Path;

use serde_json::Value;

use crate::scanner;

/// Raw token counters, normalised so `input` excludes anything counted in the
/// cache buckets (matches Claude's native split; for Codex we subtract the
/// cached portion out of the reported input). `reasoning` is a *subset* of
/// `output` (Codex reasoning tokens) kept only for display — it is NOT added
/// into [`TokenCounts::total`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TokenCounts {
    pub input: u64,
    pub output: u64,
    pub cache_creation: u64,
    pub cache_read: u64,
    pub reasoning: u64,
}

impl TokenCounts {
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_creation + self.cache_read
    }

    fn add(&mut self, o: &TokenCounts) {
        self.input += o.input;
        self.output += o.output;
        self.cache_creation += o.cache_creation;
        self.cache_read += o.cache_read;
        self.reasoning += o.reasoning;
    }
}

/// Per-million-token USD rates for one model. `0.0` everywhere means "unknown
/// model" — tokens are still counted, cost stays 0.
#[derive(Clone, Copy, Debug, Default)]
pub struct ModelPrice {
    pub input: f64,
    pub output: f64,
    pub cache_creation: f64,
    pub cache_read: f64,
}

impl ModelPrice {
    fn cost(&self, t: &TokenCounts) -> f64 {
        (t.input as f64 * self.input
            + t.output as f64 * self.output
            + t.cache_creation as f64 * self.cache_creation
            + t.cache_read as f64 * self.cache_read)
            / 1_000_000.0
    }
}

/// Offline price estimate for `model`, matched by family keyword. Rates are
/// public list prices (USD / 1M tokens) as of 2026-06 and are deliberately
/// coarse — this is a "where did my tokens go" estimate, not billing.
pub fn price(model: &str) -> ModelPrice {
    let m = model.to_ascii_lowercase();
    // Claude family.
    if m.contains("opus") {
        return ModelPrice { input: 15.0, output: 75.0, cache_creation: 18.75, cache_read: 1.5 };
    }
    if m.contains("sonnet") {
        return ModelPrice { input: 3.0, output: 15.0, cache_creation: 3.75, cache_read: 0.3 };
    }
    if m.contains("haiku") {
        return ModelPrice { input: 1.0, output: 5.0, cache_creation: 1.25, cache_read: 0.1 };
    }
    // OpenAI / Codex family (gpt-5*, o-series, codex). No separate cache-write
    // price; cached input is read-priced.
    if m.contains("gpt") || m.contains("codex") || m.starts_with("o1") || m.starts_with("o3")
        || m.starts_with("o4")
    {
        return ModelPrice { input: 1.25, output: 10.0, cache_creation: 1.25, cache_read: 0.125 };
    }
    // Gemini family (2.x pro-ish estimate).
    if m.contains("gemini") {
        return ModelPrice { input: 1.25, output: 10.0, cache_creation: 1.25, cache_read: 0.31 };
    }
    ModelPrice::default()
}

/// One assistant turn's spend, already costed. The unit of aggregation.
#[derive(Clone, Debug)]
pub struct UsageRecord {
    pub agent: &'static str,
    pub session_id: Option<String>,
    pub title: Option<String>,
    pub jsonl_path: String,
    pub model: Option<String>,
    pub tokens: TokenCounts,
    pub cost_usd: f64,
    pub ts_ms: i64,
}

/// Rolled-up usage for one session (one jsonl file).
#[derive(Clone, Debug)]
pub struct SessionUsage {
    pub agent: String,
    pub session_id: Option<String>,
    pub title: Option<String>,
    pub jsonl_path: String,
    /// Model that accounts for the most tokens in this session.
    pub model: Option<String>,
    pub tokens: TokenCounts,
    pub cost_usd: f64,
    pub first_ts_ms: i64,
    pub last_ts_ms: i64,
    /// Number of costed assistant turns (Claude) or `1` (Codex cumulative).
    pub message_count: u64,
}

/// Usage grouped by model across the whole workspace.
#[derive(Clone, Debug)]
pub struct ModelUsage {
    pub model: String,
    pub tokens: TokenCounts,
    pub cost_usd: f64,
}

/// Usage grouped by calendar day (UTC, `YYYY-MM-DD`).
#[derive(Clone, Debug)]
pub struct DayUsage {
    pub date: String,
    pub tokens: TokenCounts,
    pub cost_usd: f64,
}

/// Usage rolled up for one registered project. Populated only by
/// [`aggregate_all_projects`]; the single-project view leaves `by_project`
/// empty.
#[derive(Clone, Debug)]
pub struct ProjectUsage {
    pub project_id: String,
    pub name: String,
    pub tokens: TokenCounts,
    pub cost_usd: f64,
    /// Distinct session jsonl files that contributed any tokens.
    pub session_count: u64,
}

/// Everything the usage screen needs for one workspace.
#[derive(Clone, Debug, Default)]
pub struct WorkspaceUsage {
    pub totals: TokenCounts,
    pub total_cost_usd: f64,
    pub sessions: Vec<SessionUsage>,
    pub by_model: Vec<ModelUsage>,
    pub by_day: Vec<DayUsage>,
    /// Per-project breakdown. Empty for the single-project view.
    pub by_project: Vec<ProjectUsage>,
}

/// Scan every claude + codex session for `cwd`, cost each one, and aggregate.
pub fn aggregate_workspace(home: &Path, cwd: &Path) -> WorkspaceUsage {
    let mut records = Vec::new();
    for s in scanner::scan_workspace(home, cwd) {
        collect_records(&s, &mut records);
    }
    aggregate(records)
}

fn collect_records(s: &crate::DiscoveredSession, out: &mut Vec<UsageRecord>) {
    let path_str = s.jsonl_path.to_string_lossy().into_owned();
    // Stream line-by-line: codex rollouts can be 20MB+ (see service.rs), so we
    // never hold the whole file in memory at once.
    let file = match std::fs::File::open(&s.jsonl_path) {
        Ok(f) => f,
        Err(_) => return,
    };
    let lines = BufReader::new(file).lines().map_while(Result::ok);
    match s.agent {
        "claude" => collect_claude(s, &path_str, lines, out),
        "codex" => collect_codex(s, &path_str, lines, out),
        _ => {}
    }
}

/// Claude: dedupe assistant `message.usage` by `message.id`, keeping the
/// largest copy (streaming writes the same id several times with growing
/// counts).
fn collect_claude(
    s: &crate::DiscoveredSession,
    path_str: &str,
    lines: impl Iterator<Item = String>,
    out: &mut Vec<UsageRecord>,
) {
    // message.id -> (counts, model, ts). Best-wins by total tokens.
    let mut best: HashMap<String, (TokenCounts, Option<String>, i64)> = HashMap::new();
    // Turns with no id still count — keep them under a synthetic unique key.
    let mut anon = 0u64;

    for line in lines {
        let line = line.trim();
        if line.is_empty() || !line.contains("\"usage\"") {
            continue;
        }
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if v.get("type").and_then(|t| t.as_str()) != Some("assistant") {
            continue;
        }
        let usage = match v.pointer("/message/usage") {
            Some(u) => u,
            None => continue,
        };
        let counts = TokenCounts {
            input: u64_at(usage, "input_tokens"),
            output: u64_at(usage, "output_tokens"),
            cache_creation: u64_at(usage, "cache_creation_input_tokens"),
            cache_read: u64_at(usage, "cache_read_input_tokens"),
            reasoning: 0,
        };
        if counts.total() == 0 {
            continue;
        }
        let model = v
            .pointer("/message/model")
            .and_then(|m| m.as_str())
            .map(|s| s.to_string());
        let ts = parse_rfc3339_ms(v.get("timestamp").and_then(|t| t.as_str()));
        let id = v
            .pointer("/message/id")
            .and_then(|i| i.as_str())
            .map(|s| s.to_string());

        match id {
            Some(id) => {
                let entry = best.entry(id).or_insert((TokenCounts::default(), None, ts));
                if counts.total() >= entry.0.total() {
                    entry.0 = counts;
                    entry.1 = model;
                    entry.2 = ts;
                }
            }
            None => {
                anon += 1;
                best.insert(format!("__anon_{anon}"), (counts, model, ts));
            }
        }
    }

    for (_id, (counts, model, ts)) in best {
        let cost = price(model.as_deref().unwrap_or("")).cost(&counts);
        out.push(UsageRecord {
            agent: "claude",
            session_id: s.session_id.clone(),
            title: s.title.clone(),
            jsonl_path: path_str.to_string(),
            model,
            tokens: counts,
            cost_usd: cost,
            ts_ms: ts,
        });
    }
}

/// Codex: `token_count` events are cumulative, so take the last one. Split the
/// reported input into cached (read-priced) and uncached. Model comes from the
/// last `turn_context` line.
fn collect_codex(
    s: &crate::DiscoveredSession,
    path_str: &str,
    lines: impl Iterator<Item = String>,
    out: &mut Vec<UsageRecord>,
) {
    let mut last_total: Option<(TokenCounts, i64)> = None;
    let mut model: Option<String> = None;

    for line in lines {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let ty = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
        if ty == "turn_context" {
            if let Some(m) = v.pointer("/payload/model").and_then(|m| m.as_str()) {
                model = Some(m.to_string());
            }
            continue;
        }
        if ty != "event_msg" {
            continue;
        }
        if v.pointer("/payload/type").and_then(|t| t.as_str()) != Some("token_count") {
            continue;
        }
        let info = match v.pointer("/payload/info/total_token_usage") {
            Some(i) => i,
            None => continue,
        };
        let input_total = u64_at(info, "input_tokens");
        let cached = u64_at(info, "cached_input_tokens");
        let counts = TokenCounts {
            input: input_total.saturating_sub(cached),
            output: u64_at(info, "output_tokens"),
            cache_creation: 0,
            cache_read: cached,
            reasoning: u64_at(info, "reasoning_output_tokens"),
        };
        // Codex writes the timestamp at the top level OR inside payload,
        // depending on version (see codex::parse_ts). Try both so day-bucketed
        // usage isn't silently dropped into the "unknown" bucket.
        let ts = parse_rfc3339_ms(
            v.get("timestamp")
                .and_then(|t| t.as_str())
                .or_else(|| v.pointer("/payload/timestamp").and_then(|t| t.as_str())),
        );
        last_total = Some((counts, ts));
    }

    if let Some((counts, ts)) = last_total {
        if counts.total() == 0 {
            return;
        }
        // Don't invent a model when `turn_context` is missing — pricing an
        // unknown model would fabricate a cost (module contract: unknown
        // models count tokens but contribute $0).
        let cost = price(model.as_deref().unwrap_or("")).cost(&counts);
        out.push(UsageRecord {
            agent: "codex",
            session_id: s.session_id.clone(),
            title: s.title.clone(),
            jsonl_path: path_str.to_string(),
            model,
            tokens: counts,
            cost_usd: cost,
            ts_ms: ts,
        });
    }
}

/// Fold a flat record stream into the session / model / day rollups.
pub fn aggregate(records: Vec<UsageRecord>) -> WorkspaceUsage {
    let mut totals = TokenCounts::default();
    let mut total_cost = 0.0;

    // session key = jsonl_path (one file == one session).
    let mut sessions: HashMap<String, SessionUsage> = HashMap::new();
    let mut session_model_tokens: HashMap<String, HashMap<String, u64>> = HashMap::new();
    let mut by_model: HashMap<String, ModelUsage> = HashMap::new();
    let mut by_day: HashMap<String, DayUsage> = HashMap::new();

    for r in &records {
        totals.add(&r.tokens);
        total_cost += r.cost_usd;

        // Session rollup.
        let se = sessions.entry(r.jsonl_path.clone()).or_insert_with(|| SessionUsage {
            agent: r.agent.to_string(),
            session_id: r.session_id.clone(),
            title: r.title.clone(),
            jsonl_path: r.jsonl_path.clone(),
            model: None,
            tokens: TokenCounts::default(),
            cost_usd: 0.0,
            first_ts_ms: r.ts_ms,
            last_ts_ms: r.ts_ms,
            message_count: 0,
        });
        se.tokens.add(&r.tokens);
        se.cost_usd += r.cost_usd;
        se.message_count += 1;
        if r.ts_ms > 0 {
            if se.first_ts_ms == 0 || r.ts_ms < se.first_ts_ms {
                se.first_ts_ms = r.ts_ms;
            }
            if r.ts_ms > se.last_ts_ms {
                se.last_ts_ms = r.ts_ms;
            }
        }
        if let Some(m) = &r.model {
            *session_model_tokens
                .entry(r.jsonl_path.clone())
                .or_default()
                .entry(m.clone())
                .or_insert(0) += r.tokens.total();
        }

        // Model rollup.
        if let Some(m) = &r.model {
            let me = by_model.entry(m.clone()).or_insert_with(|| ModelUsage {
                model: m.clone(),
                tokens: TokenCounts::default(),
                cost_usd: 0.0,
            });
            me.tokens.add(&r.tokens);
            me.cost_usd += r.cost_usd;
        }

        // Day rollup (UTC).
        let date = date_utc(r.ts_ms);
        let de = by_day.entry(date.clone()).or_insert_with(|| DayUsage {
            date,
            tokens: TokenCounts::default(),
            cost_usd: 0.0,
        });
        de.tokens.add(&r.tokens);
        de.cost_usd += r.cost_usd;
    }

    // Pick each session's dominant model.
    for (path, models) in session_model_tokens {
        if let Some((model, _)) = models.into_iter().max_by_key(|(_, t)| *t) {
            if let Some(se) = sessions.get_mut(&path) {
                se.model = Some(model);
            }
        }
    }

    let mut sessions: Vec<SessionUsage> = sessions.into_values().collect();
    sessions.sort_by(|a, b| b.last_ts_ms.cmp(&a.last_ts_ms));
    let mut by_model: Vec<ModelUsage> = by_model.into_values().collect();
    by_model.sort_by(|a, b| b.cost_usd.partial_cmp(&a.cost_usd).unwrap_or(std::cmp::Ordering::Equal));
    let mut by_day: Vec<DayUsage> = by_day.into_values().collect();
    by_day.sort_by(|a, b| a.date.cmp(&b.date));

    WorkspaceUsage {
        totals,
        total_cost_usd: total_cost,
        sessions,
        by_model,
        by_day,
        by_project: Vec::new(),
    }
}

/// Scan every project's cwd, cost each session, and aggregate into ONE global
/// rollup with a per-project breakdown. `projects` is `(project_id, name,
/// cwd)`. The global `totals` / `by_model` / `by_day` / `sessions` span all
/// projects; `by_project` carries the per-project split, sorted by cost.
pub fn aggregate_all_projects(
    home: &Path,
    projects: &[(String, String, std::path::PathBuf)],
) -> WorkspaceUsage {
    let mut all_records = Vec::new();
    let mut by_project = Vec::new();

    for (project_id, name, cwd) in projects {
        let mut records = Vec::new();
        for s in scanner::scan_workspace(home, cwd) {
            collect_records(&s, &mut records);
        }

        // Per-project rollup (totals + distinct sessions) before folding the
        // records into the global stream.
        let mut tokens = TokenCounts::default();
        let mut cost_usd = 0.0;
        let mut paths = std::collections::HashSet::new();
        for r in &records {
            tokens.add(&r.tokens);
            cost_usd += r.cost_usd;
            paths.insert(r.jsonl_path.clone());
        }
        if tokens.total() > 0 {
            by_project.push(ProjectUsage {
                project_id: project_id.clone(),
                name: name.clone(),
                tokens,
                cost_usd,
                session_count: paths.len() as u64,
            });
        }
        all_records.append(&mut records);
    }

    by_project.sort_by(|a, b| {
        b.cost_usd
            .partial_cmp(&a.cost_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.tokens.total().cmp(&a.tokens.total()))
    });

    let mut agg = aggregate(all_records);
    agg.by_project = by_project;
    agg
}

fn u64_at(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(|n| n.as_u64()).unwrap_or(0)
}

fn parse_rfc3339_ms(s: Option<&str>) -> i64 {
    let Some(s) = s else { return 0 };
    match time::OffsetDateTime::parse(s, &time::format_description::well_known::Rfc3339) {
        Ok(t) => t.unix_timestamp() * 1000 + (t.millisecond() as i64),
        Err(_) => 0,
    }
}

/// `YYYY-MM-DD` (UTC) for a unix-millis timestamp. `"unknown"` when the source
/// line carried no parseable timestamp (ts == 0).
fn date_utc(ts_ms: i64) -> String {
    if ts_ms <= 0 {
        return "unknown".to_string();
    }
    let secs = ts_ms / 1000;
    match time::OffsetDateTime::from_unix_timestamp(secs) {
        Ok(t) => format!(
            "{:04}-{:02}-{:02}",
            t.year(),
            t.month() as u8,
            t.day()
        ),
        Err(_) => "unknown".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_dedupes_by_message_id_keeping_largest() {
        let s = crate::DiscoveredSession {
            agent: "claude",
            jsonl_path: "/tmp/x.jsonl".into(),
            session_id: Some("sess".into()),
            cwd: None,
            title: Some("t".into()),
        };
        // Same message.id on three lines (thinking/text/tool), usage repeated.
        // Must count ONCE.
        let lines: Vec<String> = vec![
            r#"{"type":"assistant","timestamp":"2026-06-18T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#.into(),
            r#"{"type":"assistant","timestamp":"2026-06-18T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#.into(),
            r#"{"type":"assistant","timestamp":"2026-06-18T10:01:00Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#.into(),
        ];
        let mut out = Vec::new();
        collect_claude(&s, "/tmp/x.jsonl", lines.into_iter(), &mut out);
        let agg = aggregate(out);
        // m1 (150) counted once + m2 (15) = input 110, output 55.
        assert_eq!(agg.totals.input, 110);
        assert_eq!(agg.totals.output, 55);
        assert_eq!(agg.sessions.len(), 1);
        assert_eq!(agg.sessions[0].message_count, 2);
        // opus: 110/1e6*15 + 55/1e6*75
        let expect = 110.0 / 1e6 * 15.0 + 55.0 / 1e6 * 75.0;
        assert!((agg.total_cost_usd - expect).abs() < 1e-9);
    }

    #[test]
    fn codex_takes_last_cumulative_total() {
        let s = crate::DiscoveredSession {
            agent: "codex",
            jsonl_path: "/tmp/c.jsonl".into(),
            session_id: Some("c".into()),
            cwd: None,
            title: None,
        };
        let lines: Vec<String> = vec![
            r#"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#.into(),
            r#"{"type":"event_msg","timestamp":"2026-06-18T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"reasoning_output_tokens":40}}}}"#.into(),
            r#"{"type":"event_msg","timestamp":"2026-06-18T10:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":1500,"output_tokens":300,"reasoning_output_tokens":90}}}}"#.into(),
        ];
        let mut out = Vec::new();
        collect_codex(&s, "/tmp/c.jsonl", lines.into_iter(), &mut out);
        assert_eq!(out.len(), 1);
        let r = &out[0];
        // last cumulative: input 2000-1500=500 uncached, cache_read 1500, output 300.
        assert_eq!(r.tokens.input, 500);
        assert_eq!(r.tokens.cache_read, 1500);
        assert_eq!(r.tokens.output, 300);
        assert_eq!(r.tokens.reasoning, 90);
        assert_eq!(r.model.as_deref(), Some("gpt-5.5"));
    }

    #[test]
    fn codex_reads_timestamp_from_payload_when_top_level_absent() {
        let s = crate::DiscoveredSession {
            agent: "codex",
            jsonl_path: "/tmp/c.jsonl".into(),
            session_id: Some("c".into()),
            cwd: None,
            title: None,
        };
        // No top-level `timestamp` — it lives under payload (version variance).
        let lines: Vec<String> = vec![
            r#"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#.into(),
            r#"{"type":"event_msg","payload":{"timestamp":"2026-06-18T10:00:00Z","type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10}}}}"#.into(),
        ];
        let mut out = Vec::new();
        collect_codex(&s, "/tmp/c.jsonl", lines.into_iter(), &mut out);
        assert_eq!(out.len(), 1);
        // ts must be parsed (non-zero) so it doesn't fall into the "unknown" day.
        assert!(out[0].ts_ms > 0);
        assert_eq!(date_utc(out[0].ts_ms), "2026-06-18");
    }

    #[test]
    fn codex_without_turn_context_has_no_model_and_zero_cost() {
        let s = crate::DiscoveredSession {
            agent: "codex",
            jsonl_path: "/tmp/c.jsonl".into(),
            session_id: Some("c".into()),
            cwd: None,
            title: None,
        };
        // No turn_context line -> unknown model -> must not fabricate a cost.
        let lines: Vec<String> = vec![
            r#"{"type":"event_msg","timestamp":"2026-06-18T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500}}}}"#.into(),
        ];
        let mut out = Vec::new();
        collect_codex(&s, "/tmp/c.jsonl", lines.into_iter(), &mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].model, None);
        assert_eq!(out[0].cost_usd, 0.0);
        assert_eq!(out[0].tokens.total(), 1500);
    }

    #[test]
    fn unknown_model_counts_tokens_zero_cost() {
        let p = price("some-future-model");
        assert_eq!(p.cost(&TokenCounts { input: 1000, output: 1000, ..Default::default() }), 0.0);
    }

    #[test]
    fn date_utc_formats() {
        // 2026-06-18T10:00:00Z
        let ts = 1781776800_000i64;
        assert_eq!(date_utc(ts), "2026-06-18");
        assert_eq!(date_utc(0), "unknown");
    }
}
