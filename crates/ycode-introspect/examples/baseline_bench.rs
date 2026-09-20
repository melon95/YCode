//! M0.2 旧版性能基线：introspect 层的扫描 / 解析 / 搜索耗时。
//!
//! 通过 UI 测历史搜索会把 IPC、序列化和 React 渲染混进来，复现性差。这里直接
//! 量原生版必须重写的那一层（scan_workspaces → read_all_events → 子串匹配），
//! 口径与 `Service::search_sessions` 一致：同样的 cwd 列表、同样的小写子串匹配。
//!
//! 用法：cargo run -p ycode-introspect --release --example baseline_bench -- <cwd> [query] [runs] [home]

use std::path::PathBuf;
use std::time::Instant;

use ycode_introspect::scanner;

fn main() {
    let mut args = std::env::args().skip(1);
    let cwd = PathBuf::from(args.next().expect("usage: baseline_bench <cwd> [query] [runs]"));
    let query = args.next().unwrap_or_else(|| "terminal".to_string());
    let runs: usize = args.next().and_then(|s| s.parse().ok()).unwrap_or(5);
    let home = args
        .next()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").expect("HOME")));
    let q = query.to_lowercase();

    println!("cwd   = {}", cwd.display());
    println!("query = {q:?}");
    println!("runs  = {runs}\n");

    // ── 扫描（发现会话文件） ──────────────────────────────────────────────
    let mut scan_ms = Vec::new();
    let mut sessions = Vec::new();
    for _ in 0..runs {
        let t = Instant::now();
        sessions = scanner::scan_workspace(&home, &cwd);
        scan_ms.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    let total_bytes: u64 = sessions
        .iter()
        .filter_map(|s| std::fs::metadata(&s.jsonl_path).ok())
        .map(|m| m.len())
        .sum();
    println!("scan_workspaces: {} 个会话, {:.1} MiB", sessions.len(), total_bytes as f64 / 1048576.0);
    report("  scan", &scan_ms);

    // ── 全量解析 ────────────────────────────────────────────────────────
    let mut parse_ms = Vec::new();
    let mut event_count = 0usize;
    for _ in 0..runs {
        let t = Instant::now();
        let mut n = 0usize;
        for s in &sessions {
            let sid = s.session_id.clone().unwrap_or_default();
            let _ = scanner::read_all_events(s.agent, &sid, &s.jsonl_path, |_ev| {
                n += 1;
            });
        }
        parse_ms.push(t.elapsed().as_secs_f64() * 1000.0);
        event_count = n;
    }
    println!("\nread_all_events: {event_count} 个事件");
    report("  parse", &parse_ms);

    // ── 搜索（扫描 + 解析 + 匹配，对应 search_sessions 的完整路径） ───────
    let mut search_ms = Vec::new();
    let mut hit_count = 0usize;
    for _ in 0..runs {
        let t = Instant::now();
        let mut hits = 0usize;
        for s in scanner::scan_workspace(&home, &cwd) {
            let sid = s.session_id.clone().unwrap_or_default();
            let _ = scanner::read_all_events(s.agent, &sid, &s.jsonl_path, |ev| {
                // 与 Service::search_sessions 同口径：匹配 preview() 而非原始 text。
                if ev.preview().to_lowercase().contains(&q) {
                    hits += 1;
                }
            });
        }
        search_ms.push(t.elapsed().as_secs_f64() * 1000.0);
        hit_count = hits;
    }
    println!("\nsearch (scan+parse+match): {hit_count} 个命中");
    report("  search", &search_ms);
}

fn report(label: &str, samples: &[f64]) {
    let mut sorted = samples.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mean = samples.iter().sum::<f64>() / samples.len() as f64;
    println!(
        "{label}: min {:.0} ms / median {:.0} ms / mean {:.0} ms / max {:.0} ms",
        sorted[0],
        sorted[sorted.len() / 2],
        mean,
        sorted[sorted.len() - 1],
    );
    let all: Vec<String> = samples.iter().map(|s| format!("{s:.0}")).collect();
    println!("{label}: 逐次 [{}]", all.join(", "));
}
