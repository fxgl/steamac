// Statistics page: aggregated sessions and ratings from the public API, searchable and paginated,
// with a per-game drawer (#<appid>). Only aggregates are public; individual sessions never are.
(function () {
  "use strict";
  const root = document.documentElement;
  const L = window.steamacList;
  const $ = (id) => document.getElementById(id);
  const PER_PAGE = 20;
  const { text, tr: translated } = L.translator({
    game: ["Game", "Juego", "Игра", "游戏"], sessions: ["Sessions", "Sesiones", "Сеансы", "会话"], installs: ["Installs", "Instalaciones", "Установки", "安装数"],
    launch_rate: ["Launch rate", "Tasa de arranque", "Запуски", "启动率"], fps_avg_median: ["Median FPS", "FPS mediana", "Медиана FPS", "FPS 中位数"],
    chips: ["Tested on", "Probado en", "Проверено на", "已测试芯片"],
    play_hours: ["Play hours", "Horas de juego", "Часы игры", "游戏小时"], last_seen: ["Last seen", "Última vez", "Последний сеанс", "最近日期"],
    ratings: ["Player ratings", "Valoraciones", "Оценки игроков", "玩家评分"], well: ["Runs well", "Funciona bien", "Работает хорошо", "运行良好"],
    issues: ["Playable with issues", "Jugable con problemas", "Есть проблемы", "可玩但有问题"], unplayable: ["Unplayable", "Injugable", "Неиграбельно", "无法游玩"], no_start: ["Does not start", "No arranca", "Не запускается", "无法启动"],
    all: ["All", "Todos", "Все", "全部"], unrated: ["Not rated yet", "Sin valorar", "Нет оценок", "暂无评分"],
    chip: ["Chip", "Chip", "Чип", "芯片"], ram: ["RAM", "RAM", "ОЗУ", "内存"], driver: ["Driver", "Driver", "Драйвер", "驱动"],
    gfx: ["Graphics path", "Camino gráfico", "Графический путь", "图形路径"], env: ["Launch words", "Opciones de lanzamiento", "Параметры запуска", "启动参数"],
    no_recommendation: ["No profile has enough reports yet.", "Aún ningún perfil tiene informes suficientes.", "Пока недостаточно отчётов для рекомендации.", "暂无报告充足的推荐配置。"],
    players: ["Players", "Jugadores", "Игроки", "玩家"], unknown: ["Unknown", "Desconocido", "Неизвестно", "未知"],
    no_env: ["None", "Ninguna", "Нет", "无"], vulkan: ["Vulkan", "Vulkan", "Vulkan", "Vulkan"], dxmt: ["DXMT", "DXMT", "DXMT", "DXMT"],
    early: ["Early exit", "Salida temprana", "Ранний выход", "提前退出"], low1: ["1% low FPS", "1% low FPS", "1% low FPS", "1% 低帧率"],
    game_mem: ["Game MiB", "Juego MiB", "Игра МиБ", "游戏 MiB"], host_mem: ["VM process MiB", "Proceso VM MiB", "Процесс ВМ МиБ", "虚拟机进程 MiB"],
    loading: ["Loading statistics…", "Cargando estadísticas…", "Загрузка статистики…", "正在加载统计…"],
    empty: ["No sessions or ratings have been shared yet.", "Aún no se han compartido sesiones ni valoraciones.", "Сеансы и оценки пока не опубликованы.", "暂无分享的会话或评分。"],
    no_match: ["No games match your search.", "Ningún juego coincide con la búsqueda.", "По вашему запросу игр нет.", "没有匹配的游戏。"],
    filtered_empty: ["No reports match My Mac. Increase the limits or turn the filter off.", "Ningún informe encaja con Mi Mac. Sube los límites o desactiva el filtro.", "Нет отчётов для «Моего Mac». Увеличьте ограничения или выключите фильтр.", "没有符合「我的 Mac」的报告。请提高上限或关闭筛选。"],
    filtered_missing: ["No reports for this game match My Mac.", "No hay informes de este juego que encajen con Mi Mac.", "Для этой игры нет отчётов, подходящих «Моему Mac».", "此游戏没有符合「我的 Mac」的报告。"],
    filter_off: ["All reported Macs · filter off", "Todos los Mac · filtro desactivado", "Все Mac · фильтр выключен", "所有 Mac · 筛选已关闭"],
    no_limits: ["No hardware limits set", "Sin límites de hardware", "Ограничения не заданы", "未设置硬件上限"],
    gpu_limit: ["GPU cores", "núcleos GPU", "ядер GPU", "GPU 核心"],
    ram_limit: ["GB RAM", "GB RAM", "ГБ ОЗУ", "GB 内存"],
    pcores_limit: ["P-cores", "núcleos P", "P-ядер", "性能核心"],
    error: ["Could not load statistics. Please try again.", "No se pudieron cargar las estadísticas. Inténtalo de nuevo.", "Не удалось загрузить статистику. Попробуйте ещё раз.", "无法加载统计，请重试。"],
    missing: ["No reports for this game yet.", "Aún no hay informes de este juego.", "Для этой игры пока нет данных.", "该游戏暂无报告。"], retry: ["Retry", "Reintentar", "Повторить", "重试"],
    updated: ["Updated", "Actualizado", "Обновлено", "更新时间"], yes: ["Yes", "Sí", "Да", "是"], no: ["No", "No", "Нет", "否"],
    prev: ["Previous page", "Página anterior", "Предыдущая страница", "上一页"], next: ["Next page", "Página siguiente", "Следующая страница", "下一页"],
    shown: ["games", "juegos", "игр", "个游戏"],
  });
  const ratingKeys = ["well", "issues", "unplayable", "no_start"];
  const number = L.number, gameName = L.gameName;
  const percent = (value) => value === null || value === undefined ? "—" : `${number(value * 100, 1)}%`;
  const el = (tag, className, content) => {
    const e = document.createElement(tag);
    if (className) e.className = className;
    if (content instanceof Node) e.append(content); else if (content !== undefined) e.textContent = content;
    return e;
  };

  function ratingTotal(ratings = {}) { return ratingKeys.reduce((sum, key) => sum + (ratings[key] || 0), 0); }
  // The rating most players gave, or null when nobody rated the game.
  function verdict(ratings = {}) {
    const total = ratingTotal(ratings);
    if (!total) return null;
    return ratingKeys.reduce((best, key) => ((ratings[key] || 0) > (ratings[best] || 0) ? key : best), ratingKeys[0]);
  }
  function ratingBar(ratings = {}, compact) {
    const wrap = el("div", "rating"), bar = el("div", "rating-bar");
    const total = ratingTotal(ratings);
    const description = ratingKeys.map((key) => `${text(key)}: ${number(ratings[key] || 0)}`).join(" · ");
    bar.setAttribute("role", "img"); bar.setAttribute("aria-label", description); wrap.title = description;
    for (const key of ratingKeys) {
      const part = el("span", `rating-${key}`);
      part.style.width = `${total ? (ratings[key] || 0) * 100 / total : 0}%`;
      bar.append(part);
    }
    const label = el("span", "rating-count");
    const v = verdict(ratings);
    if (!v) label.append(translated("unrated"));
    else if (compact) { label.append(translated(v)); label.append(` · ${number(total)}`); }
    else label.textContent = `${number(total)} · ${ratingKeys.map((key) => number(ratings[key] || 0)).join(" / ")}`;
    if (v) label.dataset.verdict = v;
    wrap.append(bar, label);
    return wrap;
  }
  function chipList(chips) {
    const label = el("span", "", chips.slice(0, 4).map((chip) => chip.replace(/^Apple /, "")).join(", ") || "—");
    if (chips.length > 4) label.append(` +${chips.length - 4}`);
    label.title = chips.join(", ");
    return label;
  }
  function status(id, key, retry) {
    const element = $(id);
    element.replaceChildren(translated(key)); element.hidden = false;
    if (retry) { const button = el("button", "btn btn-ghost btn-sm stats-retry", translated("retry")); button.type = "button"; button.addEventListener("click", retry); element.append(button); }
  }

  let base, games = [], generated = "", detailData = null, detailRequest = 0, listRequest = 0;
  let page = 1, filter = "all";
  try { base = window.steamacStats.baseURL(); } catch { status("list-status", "error"); return; }

  // ---------- My Mac ----------
  const hardware = [
    { field: "gpu", param: "max_gpu_cores", max: 4096, label: "gpu_limit" },
    { field: "ram", param: "max_ram_gb", max: 4096, label: "ram_limit" },
    { field: "pcores", param: "max_pcores", max: 1024, label: "pcores_limit" },
  ];
  const myMac = { enabled: false, chip: "", gpu: "", ram: "", pcores: "" };
  function hardwareValue(value, max) {
    if (!["string", "number"].includes(typeof value) || value === "") return "";
    const n = Number(value);
    return Number.isInteger(n) && n >= 1 && n <= max ? String(n) : "";
  }
  function filterQuery() {
    const params = new URLSearchParams();
    if (myMac.enabled) for (const { field, param } of hardware) if (myMac[field]) params.set(param, myMac[field]);
    return params.toString();
  }
  function renderHardwareSummary() {
    $("my-mac-button").classList.toggle("on", myMac.enabled);
    if (!myMac.enabled) { $("my-mac-summary").textContent = text("filter_off"); return; }
    const parts = myMac.chip ? [myMac.chip] : [];
    for (const { field, label } of hardware) if (myMac[field]) parts.push(`≤ ${number(myMac[field])} ${text(label)}`);
    if (!filterQuery()) parts.push(text("no_limits"));
    $("my-mac-summary").textContent = parts.join(" · ");
  }
  function saveMyMac() { try { localStorage.setItem("myMac", JSON.stringify(myMac)); } catch { /* Private mode. */ } }
  function initMyMac() {
    let saved = null;
    try { saved = JSON.parse(localStorage.getItem("myMac")); } catch { /* Missing or unavailable storage. */ }
    const params = new URLSearchParams(location.search);
    const fromURL = ["chip", ...hardware.map(({ field }) => field)].some((key) => params.has(key));
    const source = fromURL ? Object.fromEntries(params) : saved;
    if (source && typeof source === "object") {
      myMac.enabled = fromURL || source.enabled === true;
      myMac.chip = typeof source.chip === "string" ? source.chip.slice(0, 64) : "";
      for (const { field, max } of hardware) myMac[field] = hardwareValue(source[field], max);
    }
    $("my-mac-enabled").checked = myMac.enabled;
    $("my-chip").value = myMac.chip;
    for (const { field } of hardware) $(`my-${field}`).value = myMac[field];
    saveMyMac(); renderHardwareSummary();
    $("my-mac").addEventListener("submit", (event) => event.preventDefault());
    $("my-mac").addEventListener("change", () => {
      if (!$("my-mac").reportValidity()) return;
      const previous = filterQuery(), wasEnabled = myMac.enabled;
      myMac.enabled = $("my-mac-enabled").checked;
      myMac.chip = $("my-chip").value.trim();
      for (const { field, max } of hardware) myMac[field] = hardwareValue($(`my-${field}`).value, max);
      saveMyMac(); renderHardwareSummary();
      if (filterQuery() !== previous || wasEnabled !== myMac.enabled) { load(); route(false); }
    });
    $("my-mac-button").addEventListener("click", () => {
      const form = $("my-mac"), open = form.hidden;
      form.hidden = !open;
      $("my-mac-button").setAttribute("aria-expanded", String(open));
      if (open && window.anime) window.anime.animate(form, { opacity: [0, 1], y: [-8, 0], duration: 350, ease: "out(3)" });
    });
  }

  async function fetchJSON(path) {
    const query = filterQuery();
    const response = await fetch(`${base}${path}${query ? `?${query}` : ""}`);
    if (!response.ok) { const error = new Error("API request failed"); error.status = response.status; throw error; }
    return response.json();
  }

  // ---------- Totals ----------
  function renderTotals() {
    const sums = { games: games.length, sessions: 0, installs: 0, play_hours: 0 };
    for (const g of games) { sums.sessions += g.sessions || 0; sums.installs += g.installs || 0; sums.play_hours += g.play_hours || 0; }
    document.querySelectorAll("[data-total]").forEach((dd) => {
      const target = Math.round(sums[dd.dataset.total]);
      if (window.anime && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
        const o = { v: 0 };
        window.anime.animate(o, { v: target, duration: 1400, ease: "out(4)", onUpdate: () => { dd.textContent = number(Math.round(o.v)); } });
      } else dd.textContent = number(target);
    });
  }
  function renderTotalLabels() {
    document.querySelectorAll("[data-label]").forEach((dt) => dt.replaceChildren(translated(dt.dataset.label)));
  }

  // ---------- List ----------
  function filtered() {
    const query = $("search").value.trim().toLocaleLowerCase(root.lang), sort = $("sort").value;
    const list = games.filter((game) =>
      `${gameName(game)} ${game.appid} ${game.chips.join(" ")}`.toLocaleLowerCase(root.lang).includes(query)
      && (filter === "all" || verdict(game.ratings) === filter));
    list.sort((a, b) => sort === "game" ? gameName(a).localeCompare(gameName(b), root.lang)
      : sort === "last_seen" ? (b.last_seen || "").localeCompare(a.last_seen || "")
      : sort === "ratings" ? ratingTotal(b.ratings) - ratingTotal(a.ratings) || a.appid - b.appid
      : (b[sort] ?? -1) - (a[sort] ?? -1) || a.appid - b.appid);
    return list;
  }
  function gameRow(game) {
    const li = document.createElement("li");
    const a = el("a", "game-row stats-row"); a.href = `#${game.appid}`;
    const name = el("span", "game-name"), meta = el("span", "game-meta");
    name.append(el("b", "", gameName(game)));
    meta.append(el("span", "game-appid", String(game.appid)), chipList(game.chips));
    name.append(meta);
    const fps = el("span", "game-fps"), value = el("strong", "", number(game.fps_avg_median, 1)), unit = el("small");
    unit.append(translated("fps_avg_median")); value.append(unit);
    const bar = el("span", "fps-bar"), fill = el("span");
    bar.setAttribute("aria-hidden", "true");
    fill.style.width = `${Math.min(100, ((game.fps_avg_median || 0) / 60) * 100)}%`;
    bar.append(fill); fps.append(value, bar);
    const launch = el("span", "game-launch"), launchValue = el("b", "", percent(game.launch_rate));
    launch.append(launchValue, translated("launch_rate"));
    const sessions = el("span", "game-sessions"), count = el("b", "", number(game.sessions));
    sessions.append(count, translated("sessions"));
    a.append(L.art(game), name, ratingBar(game.ratings, true), fps, launch, sessions);
    li.append(a);
    return li;
  }
  function renderList(animate) {
    if (!generated) return;
    const list = filtered();
    const pages = Math.max(1, Math.ceil(list.length / PER_PAGE));
    page = Math.min(Math.max(1, page), pages);
    const start = (page - 1) * PER_PAGE, shown = list.slice(start, start + PER_PAGE);
    $("games-list").replaceChildren(...shown.map(gameRow));
    $("games-list").hidden = !list.length;
    L.pager($("games-pager"), {
      page, pages, total: list.length, from: start + 1, to: start + shown.length,
      labels: { prev: text("prev"), next: text("next") },
      onChange: (p) => { page = p; renderList(true); $("toolbar").scrollIntoView({ block: "start" }); },
    });
    if (list.length) $("list-status").hidden = true;
    else status("list-status", games.length ? "no_match" : filterQuery() ? "filtered_empty" : "empty");
    $("updated").textContent = generated ? `${text("updated")}: ${new Date(generated).toLocaleString(root.lang)}` : "";
    renderFilters();
    if (animate) L.reveal([...$("games-list").querySelectorAll(".game-row")]);
  }
  function renderFilters() {
    const box = $("rating-filter");
    const counts = { all: games.length };
    for (const g of games) { const v = verdict(g.ratings); if (v) counts[v] = (counts[v] || 0) + 1; }
    box.replaceChildren(...["all", ...ratingKeys].map((key) => {
      const b = el("button", `chip${key === "all" ? "" : ` chip-${key}`}`);
      b.type = "button"; b.setAttribute("role", "radio"); b.setAttribute("aria-checked", String(filter === key));
      if (key !== "all") b.append(el("i", `rating-dot rating-${key}`));
      b.append(translated(key), el("span", "chip-count", number(counts[key] || 0)));
      b.addEventListener("click", () => { filter = key; page = 1; renderList(true); });
      return b;
    }));
  }
  function renderControls() {
    const selected = $("sort").value || "sessions";
    $("sort").replaceChildren();
    for (const key of ["sessions", "game", "installs", "launch_rate", "fps_avg_median", "ratings", "play_hours", "last_seen"]) {
      const option = document.createElement("option"); option.value = key; option.textContent = text(key); $("sort").append(option);
    }
    $("sort").value = selected;
    const label = document.querySelector(`.search .visually-hidden [lang="${root.dataset.lang}"]`);
    $("search").placeholder = label ? label.textContent : "";
    $("rating-legend").replaceChildren();
    renderTotalLabels();
  }

  // ---------- Detail drawer ----------
  let lastFocus = null;
  function openDrawer() {
    if (!$("detail").hidden) return;
    lastFocus = document.activeElement;
    $("detail").hidden = false; $("detail-backdrop").hidden = false;
    document.body.classList.add("drawer-open");
    if (window.anime && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
      window.anime.animate($("detail"), { x: ["100%", "0%"], duration: 500, ease: "out(4)" });
      window.anime.animate($("detail-backdrop"), { opacity: [0, 1], duration: 300 });
    }
    $("detail-close").focus({ preventScroll: true });
  }
  function closeDrawer() {
    $("detail").hidden = true; $("detail-backdrop").hidden = true;
    document.body.classList.remove("drawer-open");
    if (lastFocus && document.contains(lastFocus)) lastFocus.focus({ preventScroll: true });
  }
  function leaveDetail() {
    if (!location.hash) return closeDrawer();
    history.pushState("", document.title, location.pathname + location.search);
    route();
  }
  function renderDetail() {
    if (!detailData) return;
    const game = detailData;
    $("detail-title").textContent = gameName(game);
    const artBox = $("detail-art"); artBox.replaceChildren(L.art(game));
    const summary = $("detail-summary"); summary.replaceChildren();
    for (const [key, value] of [["sessions", number(game.sessions)], ["installs", number(game.installs)], ["launch_rate", percent(game.launch_rate)], ["play_hours", number(game.play_hours, 1)]]) {
      const tile = el("div", "tile"), strong = el("strong", "", value), label = el("span");
      label.append(translated(key)); tile.append(strong, label); summary.append(tile);
    }
    const ratings = $("detail-ratings"); ratings.replaceChildren();
    const rh = el("span", "detail-label"); rh.append(translated("ratings"));
    ratings.append(rh, ratingBar(game.ratings));
    const recommendation = $("recommended-profile"); recommendation.replaceChildren();
    const profile = game.recommended;
    if (!profile) { recommendation.classList.add("empty"); recommendation.append(translated("no_recommendation")); }
    else {
      recommendation.classList.remove("empty");
      const dl = document.createElement("dl");
      for (const [key, value] of [["driver", profile.driver], ["gfx", translated(profile.gfx)], ["env", profile.env || translated("no_env")], ["players", number(profile.installs)], ["sessions", number(profile.sessions)], ["launch_rate", percent(profile.launch_rate)], ["fps_avg_median", number(profile.fps_avg_median, 1)]]) {
        const row = el("div"), dt = el("dt"), dd = el("dd");
        dt.append(translated(key));
        if (value instanceof Node) dd.append(value); else dd.textContent = value;
        row.append(dt, dd); dl.append(row);
      }
      const rr = el("div"), rdt = el("dt"), rdd = el("dd");
      rdt.append(translated("ratings")); rdd.append(ratingBar(profile.ratings)); rr.append(rdt, rdd); dl.append(rr);
      recommendation.append(dl);
    }
    const head = document.createElement("tr");
    for (const key of ["chip", "ram", "driver", "gfx", "env", "WMTR", "sessions", "installs", "launch_rate", "early", "fps_avg_median", "low1", "game_mem", "host_mem", "play_hours", "ratings"]) {
      const th = el("th"); th.scope = "col"; th.append(translated(key)); head.append(th);
    }
    $("configs-table").querySelector("thead").replaceChildren(head);
    const configs = $("configs-table").querySelector("tbody"); configs.replaceChildren();
    for (const c of game.configs) {
      const tr = document.createElement("tr");
      for (const value of [c.chip, `${number(c.ram_gb)} GB`, c.driver, translated(c.gfx || "unknown"), c.env || translated("no_env"), translated(c.wmtr ? "yes" : "no"), number(c.sessions), number(c.installs), percent(c.launch_rate), percent(c.early_exit_rate), number(c.fps_avg_median, 1), number(c.fps_low1_median, 1), number(c.game_mib_median), number(c.host_mib_median), number(c.play_hours, 1), ratingBar(c.ratings)]) {
        const td = el("td"); if (value instanceof Node) td.append(value); else td.textContent = value; tr.append(td);
      }
      configs.append(tr);
    }
    $("detail-status").hidden = true; $("detail-content").hidden = false;
  }
  async function route() {
    const request = ++detailRequest, hash = location.hash.slice(1);
    detailData = null; $("detail-content").hidden = true;
    if (!hash) { closeDrawer(); return; }
    openDrawer();
    $("detail-art").replaceChildren();
    $("detail-title").textContent = /^\d+$/.test(hash) ? `Steam · ${hash}` : "Steam";
    if (!/^[1-9]\d*$/.test(hash) || Number(hash) > 4294967295) { status("detail-status", "missing"); return; }
    const known = games.find((g) => String(g.appid) === hash);
    if (known) { $("detail-title").textContent = gameName(known); $("detail-art").replaceChildren(L.art(known)); }
    status("detail-status", "loading");
    try {
      const data = await fetchJSON(`/v1/games/${hash}`);
      if (request !== detailRequest) return;
      detailData = data; renderDetail();
    } catch (error) {
      if (request === detailRequest) status("detail-status", error.status === 404 ? filterQuery() ? "filtered_missing" : "missing" : "error", route);
    }
  }

  async function load() {
    const request = ++listRequest;
    generated = ""; games = []; $("updated").textContent = "";
    status("list-status", "loading"); $("games-list").hidden = true; $("games-pager").hidden = true;
    try {
      const data = await fetchJSON("/v1/games");
      if (request !== listRequest) return;
      games = data.games; generated = data.generated;
      renderTotals(); renderList(true);
    } catch { if (request === listRequest) status("list-status", "error", load); }
  }

  // ---------- Wiring ----------
  document.querySelectorAll("[data-set-lang]").forEach((button) => button.addEventListener("click", () => {
    const lang = button.dataset.setLang; root.dataset.lang = lang; root.lang = lang;
    try { localStorage.setItem("lang", lang); } catch { /* Private mode. */ }
    window.dispatchEvent(new Event("langchange"));
  }));
  window.addEventListener("langchange", () => {
    renderControls(); renderHardwareSummary();
    if (generated) { renderList(false); document.querySelectorAll("[data-total]").forEach((dd) => { dd.textContent = number(Number(dd.textContent.replace(/\D/g, ""))); }); }
    renderDetail();
  });
  let searchTimer = 0;
  $("search").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(() => { page = 1; renderList(true); }, 120); });
  $("sort").addEventListener("change", () => { page = 1; renderList(true); });
  window.addEventListener("hashchange", () => route());
  $("detail-close").addEventListener("click", leaveDetail);
  $("detail-backdrop").addEventListener("click", leaveDetail);
  document.querySelector(".drawer-back").addEventListener("click", (e) => { e.preventDefault(); leaveDetail(); });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !$("detail").hidden) { e.preventDefault(); leaveDetail(); return; }
    if (e.key === "/" && !/^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName)) { e.preventDefault(); $("search").focus(); }
  });
  const nav = document.querySelector(".nav");
  const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 8);
  window.addEventListener("scroll", onScroll, { passive: true }); onScroll();

  // ---------- GitHub stars in the nav ----------
  fetch("https://api.github.com/repos/fxgl/steamac", { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : null))
    .then((repo) => {
      if (!repo || typeof repo.stargazers_count !== "number") return;
      const n = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 }).format(repo.stargazers_count);
      document.querySelectorAll("[data-stars]").forEach((el) => { el.textContent = n; });
    })
    .catch(() => {});

  initMyMac(); renderControls(); load(); route();
})();
