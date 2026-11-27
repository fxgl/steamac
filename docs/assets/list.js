// Shared pieces for game lists on the landing and statistics pages: translated labels,
// Steam capsule art, one row per game and a pager. Exposed as window.steamacList.
(function () {
  "use strict";
  const root = document.documentElement;
  const LANGS = ["en", "es", "ru", "zh"];

  // words: { key: [en, es, ru, zh] }
  function translator(words) {
    const text = (key) => words[key]?.[Math.max(0, LANGS.indexOf(root.dataset.lang))] || key;
    const tr = (key) => {
      const fragment = document.createDocumentFragment();
      LANGS.forEach((lang, i) => {
        const span = document.createElement("span");
        span.lang = lang;
        span.textContent = words[key]?.[i] ?? words[key]?.[0] ?? key;
        fragment.append(span);
      });
      return fragment;
    };
    return { text, tr };
  }

  const number = (value, digits = 0) => value === null || value === undefined ? "—"
    : Number(value).toLocaleString(root.lang, { maximumFractionDigits: digits });
  const gameName = (game) => game.game || `App ${game.appid}`;

  // Steam's public header art; falls back to the game's initials when the image is missing.
  function art(game) {
    const box = document.createElement("span");
    box.className = "game-art";
    const initials = gameName(game).replace(/[^\p{L}\p{N} ]/gu, "").split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]).join("").toUpperCase();
    box.textContent = initials;
    if (game.appid) {
      // In the DOM from the start so lazy loading works; the initials stay underneath until it loads.
      const img = document.createElement("img");
      img.alt = ""; img.loading = "lazy"; img.decoding = "async";
      img.referrerPolicy = "no-referrer";
      img.width = 460; img.height = 215;
      img.onload = () => img.classList.add("loaded");
      img.onerror = () => img.remove();
      img.src = `https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/${game.appid}/header.jpg`;
      box.append(img);
    }
    return box;
  }

  // Page buttons with ellipses: 1 … 4 5 6 … 12
  function pager(nav, { page, pages, total, from, to, labels, onChange }) {
    nav.replaceChildren();
    nav.hidden = pages <= 1;
    if (pages <= 1) return;
    const info = document.createElement("span");
    info.className = "pager-info";
    info.textContent = `${number(from)}–${number(to)} / ${number(total)}`;
    const list = document.createElement("div");
    list.className = "pager-pages";
    const button = (label, target, opts = {}) => {
      const b = document.createElement("button");
      b.type = "button";
      if (label instanceof Node) b.append(label); else b.textContent = label;
      if (opts.aria) b.setAttribute("aria-label", opts.aria);
      if (target === page && !opts.nav) b.setAttribute("aria-current", "page");
      b.disabled = target < 1 || target > pages || (opts.nav && target === page);
      b.addEventListener("click", () => onChange(target));
      return b;
    };
    list.append(button("‹", page - 1, { nav: true, aria: labels.prev }));
    const shown = new Set([1, pages, page - 1, page, page + 1].filter((p) => p >= 1 && p <= pages));
    let last = 0;
    [...shown].sort((a, b) => a - b).forEach((p) => {
      if (p - last > 1) { const gap = document.createElement("span"); gap.className = "pager-info"; gap.textContent = "…"; gap.style.alignSelf = "center"; list.append(gap); }
      list.append(button(String(p), p));
      last = p;
    });
    list.append(button("›", page + 1, { nav: true, aria: labels.next }));
    nav.append(info, list);
  }

  // Animates freshly rendered rows when the motion layer is present.
  function reveal(rows) {
    if (window.steamacMotion?.rows) window.steamacMotion.rows(rows);
  }

  window.steamacList = Object.freeze({ LANGS, translator, number, gameName, art, pager, reveal });
})();
