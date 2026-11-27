// Public compatibility highlights are derived from aggregate reports, never individual sessions.
// Landing page: the supported games as a ranked, paginated list.
(function () {
  "use strict";
  const L = window.steamacList;
  const list = document.getElementById("supported-games-grid");
  const nav = document.getElementById("supported-games-pager");
  const empty = document.getElementById("supported-games-empty");
  const error = document.getElementById("supported-games-error");
  const all = document.getElementById("supported-games-all");
  const PER_PAGE = 6, MAX = 30;   // the full list lives on games.html
  const { text, tr } = L.translator({
    well: ["Runs well", "Funciona bien", "Работает хорошо", "运行良好"],
    playable: ["Playable", "Jugable", "Можно играть", "可游玩"],
    fps: ["median FPS", "FPS mediana", "медиана FPS", "FPS 中位数"],
    chips: ["Tested on", "Probado en", "Проверено на", "已测试芯片"],
    session: ["session", "sesión", "сеанс", "次会话"],
    sessions: ["sessions", "sesiones", "сеансов", "次会话"],
    prev: ["Previous page", "Página anterior", "Предыдущая страница", "上一页"],
    next: ["Next page", "Página siguiente", "Следующая страница", "下一页"],
  });
  const ruPlural = new Intl.PluralRules("ru");
  const ruSessions = { one: "сеанс", few: "сеанса", many: "сеансов", other: "сеанса" };
  let games = null, page = 1;

  function totals(game) {
    const r = game.ratings;
    const positive = r.well + r.issues, negative = r.unplayable + r.no_start;
    return { positive, negative, total: positive + negative };
  }
  function row(game, rank) {
    const ratings = totals(game);
    const well = ratings.total ? game.ratings.well > ratings.total / 2 : game.launch_rate >= 0.9;
    const li = document.createElement("li");
    const a = document.createElement("a");
    a.className = "game-row";
    a.href = window.steamacStats.gamesURL(game.appid);

    const rankEl = document.createElement("span");
    rankEl.className = "game-rank"; rankEl.textContent = rank;

    const name = document.createElement("span"), title = document.createElement("b"), meta = document.createElement("span");
    name.className = "game-name"; title.textContent = L.gameName(game); meta.className = "game-meta";
    const badge = document.createElement("span");
    badge.className = `supported-badge${well ? " supported-well" : ""}`; badge.append(tr(well ? "well" : "playable"));
    const chips = document.createElement("span");
    const short = game.chips.slice(0, 3).map((c) => c.replace(/^Apple /, "")).join(", ") || "—";
    chips.append(tr("chips"), ` ${short}${game.chips.length > 3 ? ` +${game.chips.length - 3}` : ""}`);
    chips.title = game.chips.join(", ");
    meta.append(badge, chips); name.append(title, meta);

    const fps = document.createElement("span"), value = document.createElement("strong"), unit = document.createElement("small");
    fps.className = "game-fps";
    value.textContent = L.number(game.fps_avg_median, 1); unit.append(tr("fps")); value.append(unit);
    const bar = document.createElement("span"), fill = document.createElement("span");
    bar.className = "fps-bar"; bar.setAttribute("aria-hidden", "true");
    fill.style.width = `${Math.min(100, ((game.fps_avg_median || 0) / 60) * 100)}%`;
    bar.append(fill); fps.append(value, bar);

    const sessions = document.createElement("span"), count = document.createElement("b");
    sessions.className = "game-sessions"; count.textContent = L.number(game.sessions);
    const unitLabel = tr(game.sessions === 1 ? "session" : "sessions");
    unitLabel.querySelector('[lang="ru"]').textContent = ruSessions[ruPlural.select(game.sessions)];
    sessions.append(count, unitLabel);

    a.append(rankEl, L.art(game), name, fps, sessions);
    li.append(a);
    return li;
  }
  function render(animate) {
    if (games === null) return;
    const supported = games.filter((g) => g.launch_rate > 0 && totals(g).positive >= totals(g).negative)
      .sort((a, b) => b.sessions - a.sessions || a.appid - b.appid).slice(0, MAX);
    const pages = Math.max(1, Math.ceil(supported.length / PER_PAGE));
    page = Math.min(Math.max(1, page), pages);
    const start = (page - 1) * PER_PAGE, shown = supported.slice(start, start + PER_PAGE);
    list.replaceChildren(...shown.map((g, i) => row(g, start + i + 1)));
    L.pager(nav, {
      page, pages, total: supported.length, from: start + 1, to: start + shown.length,
      labels: { prev: text("prev"), next: text("next") },
      onChange: (p) => { page = p; render(true); },
    });
    list.hidden = !supported.length; empty.hidden = Boolean(supported.length); error.hidden = true;
    if (animate) L.reveal([...list.querySelectorAll(".game-row")]);
  }
  window.addEventListener("langchange", () => render(false));
  (async () => {
    try {
      all.href = window.steamacStats.gamesURL();
      const response = await fetch(`${window.steamacStats.baseURL()}/v1/games`);
      if (!response.ok) throw new Error("Statistics unavailable");
      games = (await response.json()).games;
      render(false);
      // Animate the first page when it scrolls into view.
      const io = new IntersectionObserver(([e]) => { if (e.isIntersecting) { io.disconnect(); L.reveal([...list.querySelectorAll(".game-row")]); } }, { rootMargin: "0px 0px -10% 0px" });
      io.observe(list);
    } catch {
      list.hidden = true; nav.hidden = true; empty.hidden = true; error.hidden = false;
    }
  })();
})();
