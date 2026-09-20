use std::path::PathBuf;

use serde_json::json;
use ycode_introspect::usage;

fn main() {
    let mut args = std::env::args().skip(1);
    let workspace = PathBuf::from(args.next().expect("usage: usage_probe <workspace> <home>"));
    let home = PathBuf::from(args.next().expect("usage: usage_probe <workspace> <home>"));
    let result = usage::aggregate_workspace(&home, &workspace);
    let mut models: Vec<_> = result.by_model.iter().map(|item| item.model.clone()).collect();
    let mut days: Vec<_> = result.by_day.iter().map(|item| item.date.clone()).collect();
    models.sort();
    days.sort();
    println!(
        "{}",
        json!({
            "input": result.totals.input,
            "output": result.totals.output,
            "cache_creation": result.totals.cache_creation,
            "cache_read": result.totals.cache_read,
            "reasoning": result.totals.reasoning,
            "total": result.totals.total(),
            "sessions": result.sessions.len(),
            "models": models,
            "days": days,
            "cost_cents": (result.total_cost_usd * 100.0).round() as i64,
        })
    );
}
