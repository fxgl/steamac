import { env } from "cloudflare:workers";
import { applyD1Migrations, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import worker, { validate } from "../src/index.js";

export function sample(overrides = {}) {
  return {
    v: 1, sid: crypto.randomUUID(), install: crypto.randomUUID(), launcher: "1.9.2", appid: 1091500, game: "Cyberpunk 2077",
    mac: { model: "Mac15,9", chip: "Apple M3 Max", pcores: 12, cores: 16, gpu_cores: 40, ram_gb: 64, macos: "26.1" },
    vm: { cpus: 10, mem_mib: 24576, driver: "kosmickrisp", wmtr: false, hz: 60, steamos: "20251001.1" },
    launched: true, end: "exit", run_s: 1832, play_s: 1700, first_window_s: 12, proton: "10.0-104", res: "1920x1080",
    fps: { avg: 54.3, p50: 59.9, low1: 31.2, hitches_per_min: 1.2 },
    mem: { game_mib: 5400, guest_mib: 9800, host_mib: 14200 }, ...overrides,
  };
}
let host = 0;
async function request(path, body, options = {}) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(new Request(`https://case${host}.example${path}`, {
    method: body === undefined ? "GET" : "POST",
    ...(body === undefined ? {} : { body: typeof body === "string" ? body : JSON.stringify(body), headers: { "Content-Type": "application/json" } }),
    ...options,
  }), options.bindings || { ...env, POST_LIMITER: { limit: async () => ({ success: true }) } }, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}
let migrated;
beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS.slice(0, 1));
  // Exercise 0002 against real v1 data, including the quota and name triggers.
  for (const rating of [false, true]) {
    const row = validate({ ...sample(), rating: "well" }, rating);
    delete row.gfx; delete row.env;
    await env.DB.prepare(`INSERT INTO ${rating ? "ratings" : "sessions"} (${Object.keys(row).join(",")}) VALUES (${Object.keys(row).map(() => "?").join(",")})`).bind(...Object.values(row)).run();
  }
  const quota = await env.DB.prepare("SELECT sum(requests) AS n FROM daily_usage").first("n");
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS.slice(1));
  migrated = {
    session: await env.DB.prepare("SELECT v, gfx, env FROM sessions").first(),
    rating: await env.DB.prepare("SELECT v, gfx, env FROM ratings").first(),
    quotaBefore: quota, quotaAfter: await env.DB.prepare("SELECT sum(requests) AS n FROM daily_usage").first("n"),
    game: await env.DB.prepare("SELECT game FROM game_names").first("game"),
  };
});
beforeEach(async () => {
  host++;
  // Delete ratings before resetting the quota because clearing is itself a write.
  await env.DB.prepare("DELETE FROM daily_usage").run();
  await env.DB.prepare("DELETE FROM ratings").run();
  await env.DB.prepare("DELETE FROM sessions").run();
  await env.DB.prepare("DELETE FROM daily_usage").run();
  await env.DB.prepare("DELETE FROM game_names").run();
});

describe("non-Steam shortcuts", () => {
  it("keeps rows stored with a shortcut app id out of every answer", async () => {
    expect((await request("/v1/sessions", sample())).status).toBe(201);
    await env.DB.prepare("UPDATE sessions SET appid = 3103058971").run();
    expect((await (await request("/v1/games")).json()).games).toEqual([]);
    expect((await request("/v1/games/3103058971")).status).toBe(404);
  });
});

describe("schema validation", () => {
  it("accepts schema v1 and ignores unknown fields", () => {
    const row = validate(sample({ extra: { ignored: true } }));
    expect(row.appid).toBe(1091500);
    expect(row).not.toHaveProperty("extra");
  });
  it.each([
    ["schema", (b) => { b.v = 3; }], ["UUID", (b) => { b.sid = "bad"; }],
    ["appid zero", (b) => { b.appid = 0; }], ["non-Steam shortcut appid", (b) => { b.appid = 3103058971; }],
    ["boolean type", (b) => { b.launched = 1; }], ["driver", (b) => { b.vm.driver = "other"; }],
    ["end", (b) => { b.end = "crash"; }], ["duration", (b) => { b.run_s = 604801; }],
    ["play duration", (b) => { b.play_s = b.run_s + 1; }], ["FPS", (b) => { b.fps.avg = 1001; }],
    ["negative memory", (b) => { b.mem.host_mib = -1; }], ["control text", (b) => { b.game = "bad\nname"; }],
    ["long name", (b) => { b.game = "x".repeat(129); }], ["null optional", (b) => { b.proton = null; }],
    ["resolution", (b) => { b.res = "0x1080"; }], ["fractional cores", (b) => { b.mac.cores = 1.5; }],
  ])("rejects invalid %s", async (_name, mutate) => {
    const body = sample(); mutate(body);
    expect((await request("/v1/sessions", body)).status).toBe(400);
  });
  it("allows missing measurements and rejects malformed JSON and large bodies", async () => {
    const body = sample(); delete body.fps; delete body.mem; delete body.first_window_s;
    expect((await request("/v1/sessions", body)).status).toBe(201);
    expect((await request("/v1/sessions", "{")).status).toBe(400);
    expect((await request("/v1/sessions", " ".repeat(8193))).status).toBe(413);
    expect((await request("/v1/ratings", " ".repeat(4097))).status).toBe(413);
  });
});
it("stores a session exactly once, normalizing UUID case", async () => {
  const body = sample();
  expect((await request("/v1/sessions", body)).status).toBe(201);
  body.sid = body.sid.toUpperCase();
  expect((await request("/v1/sessions", body)).status).toBe(200);
  expect(await env.DB.prepare("SELECT count(*) AS n FROM sessions").first("n")).toBe(1);
  expect(await env.DB.prepare("SELECT requests FROM daily_usage").first("requests")).toBe(1);
});
it("enforces the IP limiter", async () => {
  const bindings = { ...env, POST_LIMITER: { limit: async () => ({ success: false }) } };
  expect((await request("/v1/sessions", sample(), { bindings })).status).toBe(429);
});
it("enforces a shared atomic SQL daily quota for sessions and ratings", async () => {
  const body = sample();
  await env.DB.prepare("INSERT INTO daily_usage VALUES (?, date('now'), 199)").bind(body.install).run();
  const rating = { ...body, rating: "well" };
  expect((await request("/v1/ratings", rating)).status).toBe(200);
  expect((await request("/v1/sessions", body)).status).toBe(429);
  expect((await request("/v1/ratings", { ...rating, rating: "issues" })).status).toBe(429);
  expect((await request("/v1/ratings", { ...rating, rating: "none" })).status).toBe(429);
  expect(await env.DB.prepare("SELECT rating FROM ratings").first("rating")).toBe("well");
  expect(await env.DB.prepare("SELECT count(*) AS n FROM sessions").first("n")).toBe(0);
});
it("upserts ratings per installation/game, clears them and validates reduced VM fields", async () => {
  const rating = { ...sample(), rating: "well", vm: { driver: "moltenvk", wmtr: true } };
  expect((await request("/v1/ratings", rating)).status).toBe(200);
  expect((await request("/v1/ratings", { ...rating, rating: "issues" })).status).toBe(200);
  expect(await env.DB.prepare("SELECT count(*) AS n FROM ratings").first("n")).toBe(1);
  expect(await env.DB.prepare("SELECT requests FROM daily_usage").first("requests")).toBe(2);
  expect((await request("/v1/ratings", { ...rating, rating: null })).status).toBe(400);
  expect((await request("/v1/ratings", { ...rating, rating: "bad" })).status).toBe(400);
  expect((await request("/v1/ratings", { ...rating, rating: "none" })).status).toBe(200);
  expect(await env.DB.prepare("SELECT count(*) AS n FROM ratings").first("n")).toBe(0);
});
it("computes exact medians, launch and early-exit rates and config ratings without exposing individual sessions", async () => {
  const install = crypto.randomUUID();
  for (const [index, fps] of [20, 40, 60, 80].entries()) {
    const b = sample({ install: index < 2 ? install : crypto.randomUUID(), launched: index !== 3, run_s: index === 0 ? 30 : 100, play_s: index === 0 ? 20 : 90, first_window_s: 1, fps: { avg: fps, p50: fps, low1: fps / 2, hitches_per_min: 0 } });
    expect((await request("/v1/sessions", b)).status).toBe(201);
  }
  const missing = sample({ run_s: 100, play_s: 10 }); delete missing.fps;
  expect((await request("/v1/sessions", missing)).status).toBe(201);
  expect((await request("/v1/ratings", { ...sample({ install }), rating: "well" })).status).toBe(200);
  expect((await request("/v1/ratings", { ...sample(), rating: "no_start", mac: { ...sample().mac, chip: "Apple M4" } })).status).toBe(200);
  const listResponse = await request("/v1/games"), list = await listResponse.json();
  expect(listResponse.headers.get("Cache-Control")).toContain("300");
  expect(list.games[0]).toMatchObject({ sessions: 5, installs: 4, launch_rate: 0.8, fps_avg_median: 50, ratings: { well: 1, issues: 0, unplayable: 0, no_start: 1 } });
  const response = await request("/v1/games/1091500"), game = await response.json();
  expect(game.configs.find((c) => c.chip === "Apple M3 Max")).toMatchObject({ early_exit_rate: 0.25, fps_avg_median: 50, fps_low1_median: 25, ratings: { well: 1 } });
  expect(game.configs.find((c) => c.chip === "Apple M4")).toMatchObject({ sessions: 0, ratings: { no_start: 1 } });
  expect(game).not.toHaveProperty("recent");
  for (const field of ["sid", "install", "launcher", "mac", "vm", "run_s", "play_s", "first_window_s", "proton", "res", "fps", "mem"]) {
    expect(game).not.toHaveProperty(field);
  }
  expect(game.play_hours).toBeCloseTo(300 / 3600);
  expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
});
it("supports rating-only games and JSON routing errors", async () => {
  expect((await request("/v1/ratings", { ...sample(), rating: "well" })).status).toBe(200);
  expect((await (await request("/v1/games")).json()).games[0]).toMatchObject({ sessions: 0, ratings: { well: 1 } });
  expect((await request("/v1/games/1234")).status).toBe(404);
  expect((await request("/unknown")).status).toBe(404);
  expect((await request("/v1/games", {}, { method: "POST" })).status).toBe(405);
  const options = await request("/v1/sessions", undefined, { method: "OPTIONS" });
  expect(options.status).toBe(200); expect(options.headers.get("Access-Control-Allow-Headers")).toBe("Content-Type");
});

it("accepts omitted optional metadata on sessions and ratings", async () => {
  const body = sample();
  delete body.game; delete body.mac.pcores; delete body.mac.gpu_cores; delete body.vm.steamos;
  expect((await request("/v1/sessions", body)).status).toBe(201);
  expect(await env.DB.prepare("SELECT game, mac_pcores, mac_gpu_cores, vm_steamos FROM sessions").first()).toEqual({
    game: null, mac_pcores: null, mac_gpu_cores: null, vm_steamos: null,
  });
  const rating = { ...body, rating: "issues", vm: { driver: body.vm.driver, wmtr: body.vm.wmtr } };
  expect((await request("/v1/ratings", rating)).status).toBe(200);
  const game = await (await request(`/v1/games/${body.appid}`)).json();
  expect(game).toMatchObject({ game: null, sessions: 1, ratings: { issues: 1 } });
  expect(game.configs[0]).toMatchObject({ game: null, sessions: 1, ratings: { issues: 1 } });
  expect(game).not.toHaveProperty("recent");
  const list = await (await request("/v1/games")).json();
  expect(list.games[0]).toMatchObject({ game: null, sessions: 1 });
});
it("retains the latest known app name across unnamed sessions, rating replacement and clearing", async () => {
  const body = sample({ game: "First name" });
  expect((await request("/v1/sessions", body)).status).toBe(201);
  const unnamed = sample(); delete unnamed.game;
  expect((await request("/v1/sessions", unnamed)).status).toBe(201);
  expect(await env.DB.prepare("SELECT game FROM game_names WHERE appid = ?").bind(body.appid).first("game")).toBe("First name");
  const rating = { ...sample(), game: "Latest name", rating: "well" };
  expect((await request("/v1/ratings", rating)).status).toBe(200);
  delete rating.game;
  expect((await request("/v1/ratings", { ...rating, rating: "issues" })).status).toBe(200);
  expect((await request("/v1/ratings", { ...rating, rating: "none" })).status).toBe(200);
  const list = await (await request("/v1/games")).json();
  expect(list.games[0].game).toBe("Latest name");
  const game = await (await request(`/v1/games/${body.appid}`)).json();
  expect(game.game).toBe("Latest name");
  expect(game.configs[0].game).toBe("Latest name");
});
it.each(["game", "pcores", "gpu_cores", "steamos"])("rejects explicit null for optional %s", async (key) => {
  const body = sample();
  if (key === "game") body.game = null;
  else if (key === "steamos") body.vm.steamos = null;
  else body.mac[key] = null;
  expect((await request("/v1/sessions", body)).status).toBe(400);
  expect((await request("/v1/ratings", { ...body, rating: "well" })).status).toBe(400);
});

it("lists distinct chips from sessions and ratings by session count then chip name", async () => {
  for (const chip of ["Apple M3 Pro", "Apple M3 Pro", "Apple M1 Max", "Apple M2 Max"]) {
    const body = sample();
    body.mac.chip = chip;
    expect((await request("/v1/sessions", body)).status).toBe(201);
  }
  for (const chip of ["Apple M3 Pro", "Apple M4 Pro", "Apple M1"]) {
    const body = { ...sample(), rating: "well" };
    body.mac.chip = chip;
    expect((await request("/v1/ratings", body)).status).toBe(200);
  }
  const ratingOnly = { ...sample({ appid: 620, game: "Portal 2" }), rating: "well" };
  ratingOnly.mac.chip = "Apple M5";
  expect((await request("/v1/ratings", ratingOnly)).status).toBe(200);
  const list = await (await request("/v1/games")).json();
  const expected = ["Apple M3 Pro", "Apple M1 Max", "Apple M2 Max", "Apple M1", "Apple M4 Pro"];
  expect(list.games.find((game) => game.appid === 1091500).chips).toEqual(expected);
  expect(list.games.find((game) => game.appid === 620).chips).toEqual(["Apple M5"]);
  const detail = await (await request("/v1/games/1091500")).json();
  expect(detail.chips).toEqual(expected);
  expect(detail).not.toHaveProperty("recent");
});
async function seedHardwareReports() {
  for (const [chip, gpu, ram, pcores, fps, rating] of [
    ["Apple M1", 16, 16, 4, 20, "well"],
    ["Apple M3", 32, 64, 8, 60, "issues"],
    ["Apple M4", null, 32, null, 100, "no_start"],
  ]) {
    const body = sample();
    Object.assign(body.mac, { chip, ram_gb: ram });
    if (gpu === null) delete body.mac.gpu_cores; else body.mac.gpu_cores = gpu;
    if (pcores === null) delete body.mac.pcores; else body.mac.pcores = pcores;
    body.fps.avg = fps;
    expect((await request("/v1/sessions", body)).status).toBe(201);
    expect((await request("/v1/ratings", { ...body, rating })).status).toBe(200);
  }
}
it.each([
  ["max_gpu_cores=16", ["Apple M1"], 20, { well: 1, issues: 0, no_start: 0 }],
  ["max_ram_gb=32", ["Apple M1", "Apple M4"], 60, { well: 1, issues: 0, no_start: 1 }],
  ["max_pcores=8", ["Apple M1", "Apple M3"], 40, { well: 1, issues: 1, no_start: 0 }],
  ["max_gpu_cores=32&max_ram_gb=32&max_pcores=8", ["Apple M1"], 20, { well: 1, issues: 0, no_start: 0 }],
])("filters every aggregate with %s, excluding unknown values only for active dimensions", async (query, chips, fps, ratings) => {
  await seedHardwareReports();
  const list = await (await request(`/v1/games?${query}`)).json();
  expect(list.games).toHaveLength(1);
  expect(list.games[0]).toMatchObject({ sessions: chips.length, installs: chips.length, fps_avg_median: fps, chips, ratings });
  expect(list.games[0].play_hours).toBeCloseTo(chips.length * 1700 / 3600);
  const game = await (await request(`/v1/games/1091500?${query}`)).json();
  expect(game).toMatchObject({ sessions: chips.length, chips, fps_avg_median: fps, ratings });
  expect(game.configs.map((config) => config.chip)).toEqual(chips);
  for (const config of game.configs) expect(config).toMatchObject({ sessions: 1, installs: 1, launch_rate: 1 });
  expect(game).not.toHaveProperty("recent");
});
it("filters rating-only games and returns an empty list / 404 when no reports remain", async () => {
  const rating = { ...sample({ appid: 620, game: "Portal 2" }), rating: "well" };
  Object.assign(rating.mac, { gpu_cores: 16, ram_gb: 16, pcores: 4 });
  expect((await request("/v1/ratings", rating)).status).toBe(200);
  const included = await (await request("/v1/games?max_gpu_cores=16&max_ram_gb=16&max_pcores=4")).json();
  expect(included.games[0]).toMatchObject({ sessions: 0, chips: ["Apple M3 Max"], ratings: { well: 1 } });
  const excluded = await (await request("/v1/games?max_gpu_cores=15")).json();
  expect(excluded.games).toEqual([]);
  expect((await request("/v1/games/620?max_gpu_cores=15")).status).toBe(404);
});
it.each(["max_gpu_cores", "max_ram_gb", "max_pcores"].flatMap((key) =>
  ["", "0", "-1", "1.5", "1e2", "NaN", " 2", "999999999999999999999", key === "max_pcores" ? "1025" : "4097"].map((value) => [key, value])
))("rejects invalid %s=%s for list and detail", async (key, value) => {
  const query = new URLSearchParams({ [key]: value });
  expect((await request(`/v1/games?${query}`)).status).toBe(400);
  expect((await request(`/v1/games/1091500?${query}`)).status).toBe(400);
});
it.each(["max_gpu_cores", "max_ram_gb", "max_pcores"])("rejects repeated %s values", async (key) => {
  expect((await request(`/v1/games?${key}=1&${key}=2`)).status).toBe(400);
});
it("accepts hardware filter upper bounds", async () => {
  expect((await request("/v1/games?max_gpu_cores=4096&max_ram_gb=4096&max_pcores=1024")).status).toBe(200);
});
it("separates hardware caches and normalizes parameter order and leading zeroes", async () => {
  await seedHardwareReports();
  const unfiltered = await (await request("/v1/games")).json();
  expect(unfiltered.games[0].sessions).toBe(3);
  const filtered = await (await request("/v1/games?max_gpu_cores=016&max_ram_gb=016")).json();
  expect(filtered.games[0].sessions).toBe(1);
  const body = sample();
  Object.assign(body.mac, { gpu_cores: 16, ram_gb: 16, pcores: 4 });
  expect((await request("/v1/sessions", body)).status).toBe(201);
  const normalized = await (await request("/v1/games?max_ram_gb=16&max_gpu_cores=16")).json();
  expect(normalized.games[0].sessions).toBe(1);
  const distinct = await (await request("/v1/games?max_gpu_cores=32&max_ram_gb=16")).json();
  expect(distinct.games[0].sessions).toBe(2);
  const detail = await (await request("/v1/games/1091500?max_gpu_cores=16")).json();
  expect(detail.sessions).toBe(2);
  const detailUnfiltered = await (await request("/v1/games/1091500")).json();
  expect(detailUnfiltered.sessions).toBe(4);
});
it("recomputes a cached answer once it is older than five minutes", async () => {
  expect((await request("/v1/sessions", sample())).status).toBe(201);
  expect((await (await request("/v1/games")).json()).games[0].sessions).toBe(1);
  expect((await request("/v1/sessions", sample())).status).toBe(201);
  expect((await (await request("/v1/games")).json()).games[0].sessions).toBe(1);
  await env.DB.prepare("UPDATE responses SET created = created - 300000").run();
  expect((await (await request("/v1/games")).json()).games[0].sessions).toBe(2);
});

describe("per-game profile statistics", () => {
  it("preserves v1 data, names and quotas while applying 0002", () => {
    expect(migrated).toEqual({
      session: { v: 1, gfx: null, env: null }, rating: { v: 1, gfx: null, env: null },
      quotaBefore: 2, quotaAfter: 2, game: "Cyberpunk 2077",
    });
  });
  it("accepts v2 for both reports and canonicalizes safe assignments", async () => {
    const body = sample({ v: 2, gfx: "dxmt", env: "WINE_A=old DXVK_A=1 WINE_A=new VK_= MTL_0=.,:;+-" });
    for (const rating of [false, true]) {
      expect((await request(rating ? "/v1/ratings" : "/v1/sessions", { ...body, rating: "well" })).status).toBe(rating ? 200 : 201);
      expect(await env.DB.prepare(`SELECT v, gfx, env FROM ${rating ? "ratings" : "sessions"}`).first()).toEqual({
        v: 2, gfx: "dxmt", env: "DXVK_A=1 MTL_0=.,:;+- VK_= WINE_A=new",
      });
    }
    const names = ["VKD3D", "DXVK", "PROTON", "WINE", "MESA", "RADV", "VK", "DXMT", "MTL", "STEAMAC"];
    expect(validate(sample({ v: 2, env: names.map((name) => `${name}_A=1`).join(" ") })).env.split(" ")).toHaveLength(names.length);
    expect(validate(sample({ v: 2, env: "" }))).toMatchObject({ gfx: null, env: null });
    expect(validate(sample({ v: 2, env: `WINE_A=${"x".repeat(249)}` })).env).toHaveLength(256);
  });
  it.each([
    ["gfx", null], ["gfx", "default"], ["gfx", "DXMT"], ["gfx", 1],
    ["env", null], ["env", 1], ["env", " WINE_A=1"], ["env", "WINE_A=1 "], ["env", "WINE_A=1  DXVK_A=2"],
    ["env", "WINE_A=1\tDXVK_A=2"], ["env", "WINE_A=1\n"], ["env", "HOME=x"], ["env", "WINE=1"],
    ["env", "WINE_lower=1"], ["env", "WINE_A"], ["env", "WINE_A=a=b"], ["env", "WINE_A=$HOME"],
    ["env", "WINE_A='x'"], ["env", "WINE_A=/tmp/x"], ["env", "WINE_A=hello world"], ["env", "WINE_A=你好"],
    ["env", `WINE_A=${"x".repeat(250)}`],
  ])("rejects v2 %s=%j for sessions and ratings", async (key, value) => {
    const body = sample({ v: 2, [key]: value });
    expect((await request("/v1/sessions", body)).status).toBe(400);
    expect((await request("/v1/ratings", { ...body, rating: "well" })).status).toBe(400);
  });
  it("keeps v1 profiles null and maps only legacy non-wmtr reports to Vulkan", async () => {
    for (const wmtr of [false, true]) {
      const body = sample({ gfx: "dxmt", env: "HOME=ignored" }); body.vm.wmtr = wmtr;
      expect((await request("/v1/sessions", body)).status).toBe(201);
      expect((await request("/v1/ratings", { ...body, rating: "well" })).status).toBe(200);
    }
    expect((await env.DB.prepare("SELECT gfx, env FROM sessions").all()).results).toEqual([{ gfx: null, env: null }, { gfx: null, env: null }]);
    const game = await (await request("/v1/games/1091500")).json();
    expect(game.configs).toHaveLength(2);
    expect(game.configs.find((c) => !c.wmtr)).toMatchObject({ gfx: "vulkan", env: null, sessions: 1, ratings: { well: 1 } });
    expect(game.configs.find((c) => c.wmtr)).toMatchObject({ gfx: null, env: null, sessions: 1, ratings: { well: 1 } });
    expect(game.recommended).toBeNull();
  });
  it("groups by chip, RAM, driver, effective gfx and canonical env, not wmtr", async () => {
    for (const [gfx, envWords, wmtr, chip, ram, driver] of [
      ["vulkan", "WINE_A=1 DXVK_A=2", false, "Apple M3 Max", 64, "kosmickrisp"],
      ["vulkan", "DXVK_A=2 WINE_A=1", true, "Apple M3 Max", 64, "kosmickrisp"],
      ["dxmt", "WINE_A=1 DXVK_A=2", true, "Apple M3 Max", 64, "kosmickrisp"],
      ["vulkan", "WINE_A=2", false, "Apple M3 Max", 64, "kosmickrisp"],
      ["vulkan", "WINE_A=2", false, "Apple M1", 64, "kosmickrisp"],
      ["vulkan", "WINE_A=2", false, "Apple M3 Max", 32, "kosmickrisp"],
      ["vulkan", "WINE_A=2", false, "Apple M3 Max", 64, "moltenvk"],
    ]) {
      const body = sample({ v: 2, gfx, env: envWords }); Object.assign(body.mac, { chip, ram_gb: ram }); Object.assign(body.vm, { driver, wmtr });
      expect((await request("/v1/sessions", body)).status).toBe(201);
      expect((await request("/v1/ratings", { ...body, rating: "well" })).status).toBe(200);
    }
    const game = await (await request("/v1/games/1091500")).json();
    expect(game.configs).toHaveLength(6);
    expect(game.configs.find((c) => c.sessions === 2)).toMatchObject({ gfx: "vulkan", env: "DXVK_A=2 WINE_A=1", wmtr: true, ratings: { well: 2 } });
  });
  async function reports({ gfx = "vulkan", driver = "kosmickrisp", envWords = "", ratings = ["well", "well"], session = true, launched = true, early = false, ram = 64, chips = ["Apple M1", "Apple M3 Max"], installs } = {}) {
    for (const [index, rating] of ratings.entries()) {
      const body = sample({ v: 2, gfx, env: envWords, launched, ...(installs ? { install: installs[index] } : {}) });
      body.vm.driver = driver; Object.assign(body.mac, { chip: chips[index % chips.length], ram_gb: ram });
      if (early) Object.assign(body, { run_s: 30, play_s: 20, first_window_s: 1 });
      body.fps.avg = 20 + index * 20;
      if (session) expect((await request("/v1/sessions", body)).status).toBe(201);
      if (rating) expect((await request("/v1/ratings", { ...body, rating })).status).toBe(200);
    }
  }
  it("ranks weighted ratings across chips and returns exactly the recommendation fields", async () => {
    await reports({ gfx: "dxmt", ratings: ["well", "no_start"] });
    await reports({ gfx: "vulkan", envWords: "WINE_A=1", ratings: ["well", "issues"] });
    const game = await (await request("/v1/games/1091500")).json();
    expect(game.recommended).toEqual({
      driver: "kosmickrisp", gfx: "vulkan", env: "WINE_A=1", installs: 2, sessions: 2,
      ratings: { well: 1, issues: 1, unplayable: 0, no_start: 0 }, fps_avg_median: 30, launch_rate: 1,
    });
  });
  it("requires two distinct installs across sessions or ratings, not two reports", async () => {
    const install = crypto.randomUUID();
    await reports({ installs: [install, install], ratings: ["well", "well"] });
    const first = await (await request("/v1/games/1091500")).json();
    expect(first.recommended).toBeNull();
    await reports({ session: false, ratings: ["issues"] });
    host++;
    const second = await (await request("/v1/games/1091500")).json();
    expect(second.recommended).toMatchObject({ installs: 2, sessions: 2, ratings: { well: 1, issues: 1 } });
  });
  it("allows rating-only and session-only recommendations", async () => {
    await reports({ session: false });
    let game = await (await request("/v1/games/1091500")).json();
    expect(game.recommended).toMatchObject({ installs: 2, sessions: 0, launch_rate: null, fps_avg_median: null });
    await reports({ gfx: "dxmt", ratings: [null, null] });
    await env.DB.prepare("DELETE FROM ratings").run(); host++;
    game = await (await request("/v1/games/1091500")).json();
    expect(game.recommended).toMatchObject({ gfx: "dxmt", installs: 2, sessions: 2, ratings: { well: 0, issues: 0, unplayable: 0, no_start: 0 } });
  });
  it("breaks score ties by launch success before early exits", async () => {
    await reports({ gfx: "dxmt", launched: false });
    await reports({ gfx: "vulkan", early: true });
    expect((await (await request("/v1/games/1091500")).json()).recommended.gfx).toBe("vulkan");
  });
  it("breaks equal scores and launch rates by fewer early exits", async () => {
    await reports({ gfx: "dxmt", early: true });
    await reports({ gfx: "vulkan" });
    expect((await (await request("/v1/games/1091500")).json()).recommended.gfx).toBe("vulkan");
  });
  it("puts missing rates last and breaks complete ties deterministically", async () => {
    await reports({ gfx: "dxmt", session: false });
    await reports({ gfx: "vulkan" });
    expect((await (await request("/v1/games/1091500")).json()).recommended.gfx).toBe("vulkan");
    await reports({ gfx: "dxmt" }); host++;
    expect((await (await request("/v1/games/1091500")).json()).recommended.gfx).toBe("dxmt");
  });
  it("never recommends unknown graphics even with a better score", async () => {
    for (let i = 0; i < 2; i++) {
      const body = sample(); body.vm.wmtr = true;
      expect((await request("/v1/ratings", { ...body, rating: "well" })).status).toBe(200);
    }
    expect((await (await request("/v1/games/1091500")).json()).recommended).toBeNull();
    await reports({ ratings: ["issues", "issues"] }); host++;
    expect((await (await request("/v1/games/1091500")).json()).recommended.gfx).toBe("vulkan");
  });
  it("applies the same My Mac scope to recommendation scores and install thresholds", async () => {
    await reports({ gfx: "dxmt", ram: 64 });
    await reports({ gfx: "vulkan", ram: 16, ratings: ["issues", "issues"] });
    expect((await (await request("/v1/games/1091500")).json()).recommended.gfx).toBe("dxmt");
    expect((await (await request("/v1/games/1091500?max_ram_gb=16")).json()).recommended.gfx).toBe("vulkan");
    await env.DB.prepare("UPDATE sessions SET mac_ram_gb = 64 WHERE gfx = 'vulkan' AND mac_chip = 'Apple M1'").run();
    await env.DB.prepare("UPDATE ratings SET mac_ram_gb = 64 WHERE gfx = 'vulkan' AND mac_chip = 'Apple M1'").run(); host++;
    expect((await (await request("/v1/games/1091500?max_ram_gb=16")).json()).recommended).toBeNull();
  });
});
