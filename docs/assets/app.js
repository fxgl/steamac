// Landing page behaviour: language, latest release link, layer map, settings tabs and the changelog.
// Everything here is progressive: without JavaScript the page shows all content in its static form.
(function () {
  "use strict";

  const root = document.documentElement;

  // ---------- Language ----------
  function setLang(lang) {
    root.dataset.lang = lang;
    root.lang = lang;
    try { localStorage.setItem("lang", lang); } catch (e) { /* private mode */ }
    window.dispatchEvent(new Event("langchange"));
  }
  document.querySelectorAll("[data-set-lang]").forEach((b) =>
    b.addEventListener("click", () => setLang(b.dataset.setLang)));

  // ---------- Latest release from the same-origin Sparkle feed ----------
  fetch("appcast.xml")
    .then((r) => (r.ok ? r.text() : ""))
    .then((xml) => {
      if (!xml) return;
      const release = new DOMParser().parseFromString(xml, "application/xml").querySelector("channel > item");
      const asset = release?.querySelector(":scope > enclosure")?.getAttribute("url");
      if (!asset) return;
      const version = release.querySelector("title")?.textContent;
      document.querySelectorAll("[data-dl]").forEach((a) => { a.href = asset; });
      document.querySelectorAll("[data-ver]").forEach((s) => { s.textContent = version || ""; });
    })
    .catch(() => {});

  // ---------- Nav: hairline once the page scrolls ----------
  const nav = document.querySelector(".nav");
  const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 8);
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // ---------- Layer map: highlight the layer being read ----------
  const mapLinks = [...document.querySelectorAll(".stack-map [data-layer]")];
  if (mapLinks.length && "IntersectionObserver" in window) {
    const visible = new Set();
    const update = () => {
      // The topmost visible article wins.
      const first = mapLinks.find((a) => visible.has(a.dataset.layer));
      if (!first) return;
      if (first.classList.contains("active")) return;
      mapLinks.forEach((a) => {
        a.classList.toggle("active", a === first);
        if (a === first) a.setAttribute("aria-current", "true"); else a.removeAttribute("aria-current");
      });
      document.querySelectorAll(".slab").forEach((s) => s.classList.toggle("active", s.dataset.layer === first.dataset.layer));
      window.dispatchEvent(new CustomEvent("layerchange", { detail: first.dataset.layer }));
    };
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => (e.isIntersecting ? visible.add(e.target.id) : visible.delete(e.target.id)));
      update();
    }, { rootMargin: "-35% 0px -55% 0px" });
    mapLinks.forEach((a) => { const el = document.getElementById(a.dataset.layer); if (el) io.observe(el); });
  }

  // ---------- Benchmark table: a bar under each figure, relative to the best in its row ----------
  document.querySelectorAll(".bench tbody tr").forEach((tr) => {
    const cells = [...tr.cells].slice(1);
    const values = cells.map((td) => parseFloat(td.textContent));
    const max = Math.max(...values.filter((v) => !Number.isNaN(v)));
    cells.forEach((td, i) => {
      if (Number.isNaN(values[i])) return;
      const bar = document.createElement("span");
      bar.className = `bar${values[i] === max ? " best" : ""}`;
      bar.style.width = `${(values[i] / max) * 100}%`;
      bar.setAttribute("aria-hidden", "true");
      td.append(bar);
    });
  });

  // ---------- Settings: an ARIA tab list switches the screenshot ----------
  const tabList = document.querySelector(".settings-tabs");
  if (tabList) {
    const tabs = [...tabList.querySelectorAll('[role="tab"]')];
    const panel = document.getElementById("settings-shot");
    const shots = [...panel.querySelectorAll("img[data-tab]")];
    const select = (tab, focus) => {
      tabs.forEach((t) => {
        const on = t === tab;
        t.setAttribute("aria-selected", String(on));
        t.tabIndex = on ? 0 : -1;
      });
      shots.forEach((img) => img.classList.toggle("show", img.dataset.tab === tab.dataset.tab));
      panel.setAttribute("aria-labelledby", tab.id);
      if (focus) tab.focus();
    };
    tabs.forEach((t) => t.addEventListener("click", () => select(t)));
    tabList.addEventListener("keydown", (e) => {
      const i = tabs.indexOf(document.activeElement);
      if (i < 0) return;
      const next = { ArrowDown: i + 1, ArrowRight: i + 1, ArrowUp: i - 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
      if (next === undefined) return;
      e.preventDefault();
      select(tabs[(next + tabs.length) % tabs.length], true);
    });
  }

  // ---------- Changelog: the newest three releases, the rest on request ----------
  const news = document.getElementById("news-list");
  const toggle = document.querySelector(".news-toggle");
  if (news && toggle && news.children.length > 3) {
    const more = toggle.innerHTML;
    const less = '<span lang="en">Show fewer changes</span><span lang="es">Ver menos cambios</span><span lang="ru">Свернуть</span><span lang="zh">收起</span>';
    news.classList.add("collapsed");
    toggle.hidden = false;
    toggle.addEventListener("click", () => {
      const open = !news.classList.toggle("collapsed");
      toggle.setAttribute("aria-expanded", String(open));
      toggle.innerHTML = open ? less : more;
      if (!open) document.getElementById("news").scrollIntoView({ block: "start" });
    });
  }
})();
