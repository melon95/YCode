// Cloudflare Worker that doubles as ycode's update endpoint AND an anonymous
// active-user counter.
//
//   GET /releases/latest.json   Records one ping (instance + day) from the
//                               request headers, then proxies the real
//                               latest.json from GitHub so the Tauri updater
//                               keeps working exactly as before.
//   GET /stats?token=...        DAU / MAU / install totals + version & OS
//                               breakdown. Token-gated.
//   GET /  (or /health)         Liveness check.
//
// The only thing ever stored is a random per-install UUID (sent by the app
// in `x-ycode-instance`) plus the app version / OS / arch. No IP addresses,
// no file paths, nothing identifying.

export interface Env {
  DB: D1Database;
  UPSTREAM_LATEST_JSON: string;
  /// Optional shared secret guarding /stats. Set via `wrangler secret put`.
  STATS_TOKEN?: string;
}

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);

    if (req.method === "GET" && url.pathname === "/releases/latest.json") {
      return handleUpdate(req, env, ctx);
    }
    if (req.method === "GET" && url.pathname === "/stats") {
      return handleStats(url, req, env);
    }
    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }
    return new Response("not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;

/// Records the active-user ping (best-effort, off the response's critical
/// path) and proxies GitHub's real update manifest back to the updater.
async function handleUpdate(
  req: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const instance = req.headers.get("x-ycode-instance");
  if (instance) {
    const version = req.headers.get("x-ycode-version");
    const os = req.headers.get("x-ycode-os");
    const arch = req.headers.get("x-ycode-arch");
    const day = new Date().toISOString().slice(0, 10); // UTC YYYY-MM-DD
    const now = Date.now();
    // waitUntil so a slow/failed D1 write never delays the update response.
    ctx.waitUntil(
      env.DB.prepare(
        `INSERT INTO pings (instance, day, version, os, arch, last_seen)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(instance, day) DO UPDATE SET
           version   = excluded.version,
           os        = excluded.os,
           arch      = excluded.arch,
           last_seen = excluded.last_seen`,
      )
        .bind(
          instance.slice(0, 64),
          day,
          clamp(version),
          clamp(os),
          clamp(arch),
          now,
        )
        .run()
        .catch((err) => console.error("ping write failed", err)),
    );
  }

  // Proxy the genuine manifest. Cache briefly so a burst of launches doesn't
  // hammer GitHub; the updater is fine with a few minutes of staleness.
  const upstream = await fetch(env.UPSTREAM_LATEST_JSON, {
    cf: { cacheTtl: 300, cacheEverything: true },
  });
  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      "content-type": "application/json",
      "cache-control": "public, max-age=300",
    },
  });
}

/// Aggregated, anonymous usage numbers. Distinct-instance counts over rolling
/// windows give DAU/MAU; raw row counts would over-count multi-launch days.
async function handleStats(
  url: URL,
  req: Request,
  env: Env,
): Promise<Response> {
  // Fail closed: without a configured token the stats endpoint stays private
  // rather than silently leaking aggregate numbers.
  if (!env.STATS_TOKEN) {
    return new Response("stats disabled: STATS_TOKEN not configured", {
      status: 503,
    });
  }
  // Accept the token via `Authorization: Bearer …` (keeps it out of URLs and
  // access logs) or, for convenience, a `?token=` query param.
  const bearer = req.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "");
  const provided = bearer || url.searchParams.get("token");
  if (provided !== env.STATS_TOKEN) {
    return new Response("unauthorized", { status: 401 });
  }

  const today = new Date().toISOString().slice(0, 10);
  const [dau, mau, total, byVersion, byOs] = await Promise.all([
    env.DB.prepare(
      `SELECT COUNT(DISTINCT instance) AS n FROM pings WHERE day = ?1`,
    )
      .bind(today)
      .first<{ n: number }>(),
    env.DB.prepare(
      `SELECT COUNT(DISTINCT instance) AS n FROM pings
       WHERE day >= date('now', '-30 day')`,
    ).first<{ n: number }>(),
    env.DB.prepare(
      `SELECT COUNT(DISTINCT instance) AS n FROM pings`,
    ).first<{ n: number }>(),
    env.DB.prepare(
      `SELECT version, COUNT(DISTINCT instance) AS n FROM pings
       WHERE day >= date('now', '-30 day')
       GROUP BY version ORDER BY n DESC`,
    ).all(),
    env.DB.prepare(
      `SELECT os, COUNT(DISTINCT instance) AS n FROM pings
       WHERE day >= date('now', '-30 day')
       GROUP BY os ORDER BY n DESC`,
    ).all(),
  ]);

  return Response.json({
    dau: dau?.n ?? 0,
    mau: mau?.n ?? 0,
    total_installs: total?.n ?? 0,
    by_version: byVersion.results,
    by_os: byOs.results,
    generated_at: new Date().toISOString(),
  });
}

/// Defensive bound on free-form header values before they hit the DB.
function clamp(value: string | null): string | null {
  return value ? value.slice(0, 64) : null;
}
