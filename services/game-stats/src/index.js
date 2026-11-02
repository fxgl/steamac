const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN = /^[\x21-\x7e]+$/;
const VERSION = /^[A-Za-z0-9][A-Za-z0-9._+()-]*$/;
const RATING_KEYS = ["well", "issues", "unplayable", "no_start"];
/** Steam app ids; non-Steam shortcuts added to a library get ids with the top bit set, meaningful
 *  only on the Mac that made them. */
const STEAM_APPID_MAX = 2147483647;
class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
function json(value, status = 200, headers = {}) {
  return Response.json(value, { status, headers: { ...CORS, ...headers } });
}
/** Each public answer is recomputed at most once per key per TTL (see migrations/0003_responses.sql). */
const CACHE_TTL_S = 300;
function cachedJSON(body) {
  return new Response(body, { headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": `public, max-age=${CACHE_TTL_S}` } });
}
function invalid(name) { throw new HttpError(400, `Invalid ${name}`); }
function object(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) invalid(name);
  return value;
}
function string(value, name, max, pattern) {
  if (typeof value !== "string" || !value.length || [...value].length > max || !pattern.test(value)) invalid(name);
  return value;
}
function number(value, name, min, max, integer = false) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) invalid(name);
  return value;
}
function boolean(value, name) {
  if (typeof value !== "boolean") invalid(name);
  return Number(value);
}
function choice(value, name, values) {
  if (!values.includes(value)) invalid(name);
  return value;
}
/** Match the launcher's safe assignment subset, not shell syntax. Last assignment wins, as in env. */
function profileEnv(value) {
  if (typeof value !== "string" || value.length > 256) invalid("env");
  if (value === "") return null;
  const assignments = new Map();
  for (const word of value.split(" ")) {
    const match = /^((?:VKD3D|DXVK|PROTON|WINE|MESA|RADV|VK|DXMT|MTL|STEAMAC)_[A-Z0-9_]*)=([A-Za-z0-9_.,:;+-]*)$/.exec(word);
    if (!match || match[0] !== word) invalid("env");
    assignments.set(match[1], word);
  }
  return [...assignments].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([, word]) => word).join(" ");
}
/** Flatten only known schema fields; unknown keys never reach D1. */
export function validate(value, rating = false) {
  const b = object(value, "body"), mac = object(b.mac, "mac"), vm = object(b.vm, "vm");
  const row = {
    v: number(b.v, "v", 1, 2, true),
    install: string(b.install, "install", 36, UUID).toLowerCase(),
    launcher: string(b.launcher, "launcher", 64, VERSION),
    appid: number(b.appid, "appid", 1, STEAM_APPID_MAX, true),
    mac_model: string(mac.model, "mac.model", 64, /^[A-Za-z0-9,._-]+$/),
    mac_chip: string(mac.chip, "mac.chip", 64, /^[A-Za-z0-9 +()._-]+$/),
    mac_cores: number(mac.cores, "mac.cores", 1, 1024, true),
    mac_ram_gb: number(mac.ram_gb, "mac.ram_gb", 1, 4096, true),
    mac_macos: string(mac.macos, "mac.macos", 64, VERSION),
    vm_driver: choice(vm.driver, "vm.driver", ["moltenvk", "kosmickrisp"]),
    vm_wmtr: boolean(vm.wmtr, "vm.wmtr"),
  };
  row.gfx = row.v === 2 && "gfx" in b ? choice(b.gfx, "gfx", ["vulkan", "dxmt"]) : null;
  row.env = row.v === 2 && "env" in b ? profileEnv(b.env) : null;
  if ("game" in b) row.game = string(b.game, "game", 128, /^[^\p{Cc}\p{Cs}\p{Cf}]+$/u);
  if ("pcores" in mac) {
    row.mac_pcores = number(mac.pcores, "mac.pcores", 0, 1024, true);
    if (row.mac_pcores > row.mac_cores) invalid("mac.pcores");
  }
  if ("gpu_cores" in mac) row.mac_gpu_cores = number(mac.gpu_cores, "mac.gpu_cores", 1, 4096, true);
  const vmFields = {
    cpus: () => number(vm.cpus, "vm.cpus", 1, 1024, true),
    mem_mib: () => number(vm.mem_mib, "vm.mem_mib", 1, 4194304, true),
    hz: () => number(vm.hz, "vm.hz", 1, 1000),
  };
  for (const [key, parse] of Object.entries(vmFields)) {
    if (!rating || key in vm) row[`vm_${key}`] = parse();
  }
  if ("steamos" in vm) row.vm_steamos = string(vm.steamos, "vm.steamos", 64, VERSION);
  if (rating) {
    row.rating = choice(b.rating, "rating", [...RATING_KEYS, "none"]);
    return row;
  }
  Object.assign(row, {
    sid: string(b.sid, "sid", 36, UUID).toLowerCase(),
    launched: boolean(b.launched, "launched"),
    end: choice(b.end, "end", ["exit", "shutdown", "session", "replaced"]),
    run_s: number(b.run_s, "run_s", 0, 604800),
    play_s: number(b.play_s, "play_s", 0, 604800),
  });
  if (row.play_s > row.run_s) invalid("play_s");
  if ("first_window_s" in b) row.first_window_s = number(b.first_window_s, "first_window_s", 0, row.run_s);
  if ("proton" in b) row.proton = string(b.proton, "proton", 64, TOKEN);
  if ("res" in b) {
    row.res = string(b.res, "res", 11, /^\d{1,5}x\d{1,5}$/);
    if (!row.res.split("x").every((n) => Number(n) >= 1 && Number(n) <= 32768)) invalid("res");
  }
  if ("fps" in b) {
    const fps = object(b.fps, "fps");
    for (const key of ["avg", "p50", "low1", "hitches_per_min"]) {
      row[`fps_${key}`] = number(fps[key], `fps.${key}`, 0, key === "hitches_per_min" ? 60000 : 1000);
    }
  }
  if ("mem" in b) {
    const mem = object(b.mem, "mem");
    for (const key of ["game_mib", "guest_mib", "host_mib"]) {
      if (key in mem) row[`mem_${key}`] = number(mem[key], `mem.${key}`, 0, 4194304);
    }
  }
  return row;
}
async function bodyJSON(request, max) {
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get("Content-Type") || "")) invalid("Content-Type");
  if (Number(request.headers.get("Content-Length")) > max) throw new HttpError(413, "Body too large");
  const reader = request.body?.getReader();
  if (!reader) invalid("body");
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) { await reader.cancel(); throw new HttpError(413, "Body too large"); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { invalid("JSON"); }
}
async function post(request, env, rating) {
  const row = validate(await bodyJSON(request, rating ? 4096 : 8192), rating);
  if (!rating && await env.DB.prepare("SELECT 1 FROM sessions WHERE sid = ?").bind(row.sid).first()) {
    return json({ status: "duplicate" });
  }
  // The address is used only as a transient limiter key, never persisted or logged.
  if (!(await env.POST_LIMITER.limit({ key: request.headers.get("CF-Connecting-IP") || "local" })).success) {
    throw new HttpError(429, "IP rate limit");
  }
  try {
    if (rating && row.rating === "none") {
      await env.DB.prepare("DELETE FROM ratings WHERE install = ? AND appid = ?").bind(row.install, row.appid).run();
      return json({ status: "cleared" });
    }
    const columns = Object.keys(row);
    const sql = `${rating ? "INSERT OR REPLACE" : "INSERT"} INTO ${rating ? "ratings" : "sessions"}
      (${columns.join(",")}) VALUES (${columns.map(() => "?").join(",")})${rating ? "" : " ON CONFLICT(sid) DO NOTHING"}`;
    const result = await env.DB.prepare(sql).bind(...Object.values(row)).run();
    return json({ status: rating ? "stored" : result.meta.changes ? "stored" : "duplicate" }, rating ? 200 : result.meta.changes ? 201 : 200);
  } catch (error) {
    if (String(error).includes("daily rate limit")) throw new HttpError(429, "Installation daily rate limit");
    throw error;
  }
}
const MEDIANS = { fps_avg: "fps_avg_median", fps_low1: "fps_low1_median", mem_game_mib: "game_mib_median", mem_host_mib: "host_mib_median" };
const HARDWARE_FILTERS = {
  max_gpu_cores: { column: "mac_gpu_cores", max: 4096 },
  max_ram_gb: { column: "mac_ram_gb", max: 4096 },
  max_pcores: { column: "mac_pcores", max: 1024 },
};
function hardwareFilters(params) {
  const filters = {};
  for (const [key, { max }] of Object.entries(HARDWARE_FILTERS)) {
    const values = params.getAll(key);
    if (!values.length) continue;
    if (values.length !== 1 || !/^\d+$/.test(values[0])) invalid(key);
    filters[key] = number(Number(values[0]), key, 1, max, true);
  }
  return filters;
}
/** One bound predicate is shared by every session/rating aggregate; NULL never satisfies <=. Rows of
 *  non-Steam shortcuts stored before they were refused stay out of every aggregate. */
function reportScope(appid, filters) {
  const clauses = ["appid <= ?"], bindings = [STEAM_APPID_MAX];
  if (appid !== undefined) { clauses.push("appid = ?"); bindings.push(appid); }
  for (const [key, value] of Object.entries(filters)) {
    clauses.push(`${HARDWARE_FILTERS[key].column} <= ?`);
    bindings.push(value);
  }
  return { where: `WHERE ${clauses.join(" AND ")}`, bindings };
}
// Legacy wmtr advertised a context, not a game's graphics path: only wmtr=0 proves Vulkan.
const EFFECTIVE_GFX = "coalesce(gfx, CASE WHEN vm_wmtr = 0 THEN 'vulkan' END)";
const CONFIG_GROUP = "appid, mac_chip, mac_ram_gb, vm_driver, effective_gfx, env";
function normalizedReports(table, scope) {
  return `SELECT *, ${EFFECTIVE_GFX} AS effective_gfx FROM ${table} ${scope.where}`;
}
function emptyRatings() { return { well: 0, issues: 0, unplayable: 0, no_start: 0 }; }
function byText(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
/** Mean of the middle one or two values, as the window-ranked SQL medians compute it. */
function median(values) {
  if (!values.length) return null;
  values.sort((a, b) => a - b);
  const mid = values.length >> 1;
  return values.length % 2 ? values[mid] : (values[mid - 1] + values[mid]) / 2;
}
/** Per-game totals read each scoped report row exactly once. D1 bills rows read, and window ranks
 *  over the whole history cost about seven reads per session on every list recomputation. A game's
 *  last_seen is its latest session, or its latest rating when it has no sessions. */
async function gameSummaries(db, scope, appid) {
  const [sessions, ratings, names] = (await db.batch([
    db.prepare(`SELECT appid, install, launched, play_s, received, fps_avg, mac_chip FROM sessions ${scope.where}`).bind(...scope.bindings),
    db.prepare(`SELECT appid, rating, received, mac_chip FROM ratings ${scope.where}`).bind(...scope.bindings),
    appid === undefined ? db.prepare("SELECT appid, game FROM game_names") : db.prepare("SELECT appid, game FROM game_names WHERE appid = ?").bind(appid),
  ])).map((result) => result.results);
  const games = new Map();
  function game(appid) {
    if (!games.has(appid)) {
      games.set(appid, { sessions: 0, installs: new Set(), launched: 0, play_s: 0, played: null, rated: null, fps: [], chips: new Map(), ratings: emptyRatings() });
    }
    return games.get(appid);
  }
  for (const s of sessions) {
    const g = game(s.appid);
    g.sessions++; g.installs.add(s.install); g.launched += s.launched; g.play_s += s.play_s;
    if (g.played === null || s.received > g.played) g.played = s.received;
    if (s.fps_avg !== null) g.fps.push(s.fps_avg);
    g.chips.set(s.mac_chip, (g.chips.get(s.mac_chip) || 0) + 1);
  }
  for (const r of ratings) {
    const g = game(r.appid);
    g.ratings[r.rating]++;
    if (g.rated === null || r.received > g.rated) g.rated = r.received;
    if (!g.chips.has(r.mac_chip)) g.chips.set(r.mac_chip, 0);
  }
  const name = new Map(names.map((row) => [row.appid, row.game]));
  return [...games].map(([appid, g]) => ({
    appid, game: name.get(appid) ?? null, sessions: g.sessions, installs: g.installs.size,
    launch_rate: g.sessions ? g.launched / g.sessions : null, play_hours: g.play_s / 3600,
    last_seen: g.sessions ? g.played : g.rated, fps_avg_median: median(g.fps), ratings: g.ratings,
    // Rating-only chips count zero sessions, so they follow every chip with sessions.
    chips: [...g.chips].sort(([a, n], [b, m]) => m - n || byText(a, b)).map(([chip]) => chip),
  })).sort((a, b) => b.sessions - a.sessions || a.appid - b.appid);
}
/** Window ranks produce exact medians, ignoring missing measurements, without transferring raw
 *  history; only the detail page asks, so only one game's reports are ranked. */
async function configSummaries(db, scope) {
  const metrics = Object.entries(MEDIANS);
  const ranks = metrics.map(([key]) => `row_number() OVER (PARTITION BY ${CONFIG_GROUP} ORDER BY ${key} IS NULL, ${key}) AS ${key}_rank,
    count(${key}) OVER (PARTITION BY ${CONFIG_GROUP}) AS ${key}_count`).join(",");
  const medians = metrics.map(([key, name]) => `avg(CASE WHEN ${key}_rank IN ((${key}_count + 1) / 2, (${key}_count + 2) / 2) THEN ${key} END) AS ${name}`).join(",");
  const rows = await db.prepare(`WITH reports AS (
    ${normalizedReports("sessions", scope)}
  ), ranked AS (
    SELECT *, ${ranks} FROM reports
  ) SELECT appid, (SELECT game FROM game_names WHERE game_names.appid = ranked.appid) AS game,
    count(*) AS sessions, count(DISTINCT install) AS installs, avg(launched) AS launch_rate,
    sum(play_s) / 3600.0 AS play_hours, max(received) AS last_seen, ${medians},
    mac_chip AS chip, mac_ram_gb AS ram_gb, vm_driver AS driver, max(vm_wmtr) AS wmtr, effective_gfx AS gfx, env,
    1.0 * sum(CASE WHEN launched = 1 AND end = 'exit' AND run_s < 60 THEN 1 ELSE 0 END) / nullif(sum(launched), 0) AS early_exit_rate
    FROM ranked GROUP BY ${CONFIG_GROUP} ORDER BY sessions DESC, appid`).bind(...scope.bindings).all();
  return rows.results;
}
function configKey(row) { return JSON.stringify([row.chip, row.ram_gb, row.driver, row.gfx, row.env]); }
async function configRatings(db, scope) {
  return (await db.prepare(`WITH reports AS (
    SELECT appid, game, rating, received, mac_chip, mac_ram_gb, vm_driver, vm_wmtr, ${EFFECTIVE_GFX} AS effective_gfx, env
    FROM ratings ${scope.where}
  ) SELECT appid, (SELECT game FROM game_names WHERE game_names.appid = ranked.appid) AS game,
    ${RATING_KEYS.map((key) => `sum(rating = '${key}') AS ${key}`).join(",")}, max(received) AS last_seen,
    mac_chip AS chip, mac_ram_gb AS ram_gb, vm_driver AS driver, max(vm_wmtr) AS wmtr, effective_gfx AS gfx, env
    FROM reports AS ranked
    GROUP BY ${CONFIG_GROUP}`).bind(...scope.bindings).all()).results;
}
function mergeConfigs(sessions, ratings) {
  const rows = new Map(sessions.map((row) => [configKey(row), { ...row, ratings: emptyRatings() }]));
  for (const r of ratings) {
    let row = rows.get(configKey(r));
    if (!row) {
      row = { appid: r.appid, game: r.game, sessions: 0, installs: 0, launch_rate: null, play_hours: 0, fps_avg_median: null, last_seen: r.last_seen, ratings: emptyRatings(),
        chip: r.chip, ram_gb: r.ram_gb, driver: r.driver, wmtr: r.wmtr, gfx: r.gfx, env: r.env, early_exit_rate: null, fps_low1_median: null, game_mib_median: null, host_mib_median: null };
      rows.set(configKey(r), row);
    }
    for (const name of RATING_KEYS) row.ratings[name] = r[name];
    row.wmtr = Number(row.wmtr) || Number(r.wmtr);
  }
  return [...rows.values()].map((row) => ({ ...row, wmtr: Boolean(row.wmtr) }));
}
/** Rank profiles across chips in the same hardware scope. Score = (well + 0.5 * issues) / ratings;
 *  no ratings score zero. Require two distinct installs across either source. Ties prefer launch
 *  success, then fewer early exits (missing rates last), then stable profile-key order.
 *  Unknown legacy graphics paths cannot be applied safely, so they never qualify. */
async function recommended(db, scope) {
  const group = "vm_driver, effective_gfx, env";
  const row = await db.prepare(`WITH session_reports AS (
    ${normalizedReports("sessions", scope)}
  ), rating_reports AS (
    ${normalizedReports("ratings", scope)}
  ), installs AS (
    SELECT vm_driver, effective_gfx, env, install FROM session_reports
    UNION
    SELECT vm_driver, effective_gfx, env, install FROM rating_reports
  ), profiles AS (
    SELECT ${group}, count(*) AS installs FROM installs
    WHERE effective_gfx IS NOT NULL GROUP BY ${group} HAVING count(*) >= 2
  ), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY ${group} ORDER BY fps_avg IS NULL, fps_avg) AS fps_rank,
      count(fps_avg) OVER (PARTITION BY ${group}) AS fps_count FROM session_reports
  ), profile_sessions AS (
    SELECT ${group}, count(*) AS sessions, avg(launched) AS launch_rate,
      1.0 * sum(CASE WHEN launched = 1 AND end = 'exit' AND run_s < 60 THEN 1 ELSE 0 END) / nullif(sum(launched), 0) AS early_exit_rate,
      avg(CASE WHEN fps_rank IN ((fps_count + 1) / 2, (fps_count + 2) / 2) THEN fps_avg END) AS fps_avg_median
    FROM ranked GROUP BY ${group}
  ), profile_ratings AS (
    SELECT ${group}, count(*) AS ratings,
      ${RATING_KEYS.map((key) => `sum(rating = '${key}') AS ${key}`).join(",")}
    FROM rating_reports GROUP BY ${group}
  )
  SELECT p.vm_driver AS driver, p.effective_gfx AS gfx, p.env, p.installs,
    coalesce(s.sessions, 0) AS sessions, s.fps_avg_median, s.launch_rate,
    ${RATING_KEYS.map((key) => `coalesce(r.${key}, 0) AS ${key}`).join(",")}
  FROM profiles p
  LEFT JOIN profile_sessions s ON s.vm_driver = p.vm_driver AND s.effective_gfx = p.effective_gfx AND s.env IS p.env
  LEFT JOIN profile_ratings r ON r.vm_driver = p.vm_driver AND r.effective_gfx = p.effective_gfx AND r.env IS p.env
  ORDER BY coalesce((r.well + 0.5 * r.issues) / r.ratings, 0) DESC,
    s.launch_rate IS NULL, s.launch_rate DESC, s.early_exit_rate IS NULL, s.early_exit_rate ASC,
    p.vm_driver, p.effective_gfx, p.env
  LIMIT 1`).bind(...scope.bindings, ...scope.bindings).first();
  if (!row) return null;
  const ratings = Object.fromEntries(RATING_KEYS.map((key) => [key, row[key]]));
  for (const key of RATING_KEYS) delete row[key];
  return { ...row, ratings };
}
async function get(env, appid, filters) {
  const scope = reportScope(appid, filters);
  const games = await gameSummaries(env.DB, scope, appid);
  if (appid === undefined) return { generated: new Date().toISOString(), games };
  if (!games.length) throw new HttpError(404, "Game not found");
  const configs = mergeConfigs(await configSummaries(env.DB, scope), await configRatings(env.DB, scope));
  return { generated: new Date().toISOString(), ...games[0], configs, recommended: await recommended(env.DB, scope) };
}
export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url), path = url.pathname;
      const detail = /^\/v1\/games\/([1-9]\d*)$/.exec(path);
      const isGet = path === "/v1/games" || (detail && Number(detail[1]) <= STEAM_APPID_MAX);
      const isPost = path === "/v1/sessions" || path === "/v1/ratings";
      if (!isGet && !isPost) throw new HttpError(404, "Not found");
      if (request.method === "OPTIONS") return json({ status: "ok" });
      if (isPost && request.method === "POST") return await post(request, env, path === "/v1/ratings");
      if (!isGet || request.method !== "GET") return json({ error: "Method not allowed" }, 405, { Allow: isGet ? "GET, OPTIONS" : "POST, OPTIONS" });
      // Version every public aggregate shape so a deploy never serves a cached answer of the previous shape.
      const filters = hardwareFilters(url.searchParams);
      const key = `${url.origin}${path}?${new URLSearchParams({ aggregates: "4", ...filters })}`;
      const now = Date.now(), expired = now - CACHE_TTL_S * 1000;
      const hit = await env.DB.prepare("SELECT body FROM responses WHERE key = ? AND created > ?").bind(key, expired).first("body");
      if (hit !== null) return cachedJSON(hit);
      const body = JSON.stringify(await get(env, detail ? Number(detail[1]) : undefined, filters));
      ctx.waitUntil(env.DB.batch([
        env.DB.prepare("INSERT OR REPLACE INTO responses (key, body, created) VALUES (?, ?, ?)").bind(key, body, now),
        env.DB.prepare("DELETE FROM responses WHERE created <= ?").bind(expired),
      ]));
      return cachedJSON(body);
    } catch (error) {
      return json({ error: error instanceof HttpError ? error.message : "Internal server error" }, error instanceof HttpError ? error.status : 500);
    }
  },
};
