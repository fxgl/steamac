// Motion layer for the landing page, built on anime.js (assets/vendor). Purely decorative:
// the page is complete without it, and nothing runs when the visitor prefers reduced motion.
(function () {
  "use strict";

  const root = document.documentElement;
  const A = window.anime;
  if (!A || !root.classList.contains("motion")) { root.classList.remove("motion"); return; }
  const { animate, stagger, splitText, utils } = A;

  const api = {};
  window.steamacMotion = api;

  // Run `fn` once, the first time `el` comes into view.
  function onceVisible(el, fn, margin = "0px 0px -12% 0px") {
    if (!el) return;
    const io = new IntersectionObserver((entries) => {
      if (!entries[0].isIntersecting) return;
      io.disconnect();
      fn(el);
    }, { rootMargin: margin });
    io.observe(el);
  }
  // Repeatedly report visibility (for loops that should only run on screen).
  function whileVisible(el, on, off) {
    if (!el) return;
    new IntersectionObserver(([e]) => (e.isIntersecting ? on() : off()), { threshold: 0.2 }).observe(el);
  }

  // ---------- Hero: copy rises in, headline by character, then the window tilts up flat ----------
  const heroCopy = document.querySelector(".hero-copy");
  const heroShot = document.querySelector(".matrix");
  if (heroCopy) {
    const h1 = heroCopy.querySelector("h1");
    const current = h1.querySelector(`[lang="${root.dataset.lang}"]`) || h1;
    const parts = [...heroCopy.children].filter((el) => el !== h1);
    utils.set(h1, { opacity: 1 });
    let chars = [];
    try { chars = splitText(current, { chars: true }).chars; } catch (e) { chars = []; }
    if (chars.length) {
      utils.set(chars, { opacity: 0 });
      animate(chars, {
        opacity: [0, 1],
        y: ["0.45em", "0em"],
        rotate: [6, 0],
        duration: 900,
        delay: stagger(28, { start: 120 }),
        ease: "out(4)",
      });
    } else {
      animate(h1, { opacity: [0, 1], y: [24, 0], duration: 800, ease: "out(4)" });
    }
    animate(parts, {
      opacity: [0, 1],
      y: [18, 0],
      duration: 800,
      delay: (el, i) => (i === 0 ? 0 : 450 + i * 90),
      ease: "out(3)",
    });
  }
  if (heroShot) animate(heroShot, { opacity: [0, 1], y: [24, 0], duration: 1000, delay: 300, ease: "out(4)" });

  // ---------- Scroll reveals ----------
  document.querySelectorAll("[data-reveal]").forEach((el) =>
    onceVisible(el, () => animate(el, { opacity: [0, 1], y: [28, 0], duration: 900, ease: "out(4)" })));
  document.querySelectorAll("[data-reveal-group]").forEach((group) =>
    onceVisible(group, () => animate([...group.children], {
      opacity: [0, 1], y: [28, 0], duration: 800, delay: stagger(80), ease: "out(4)",
    })));

  // ---------- Isometric stack: drop in, then the layer being read lifts out ----------
  const iso = document.querySelector(".iso");
  if (iso) {
    const slabs = [...iso.querySelectorAll(".slab")];
    const base = (s) => Number(s.style.getPropertyValue("--i")) * 24;
    slabs.forEach((s) => utils.set(s, { translateZ: base(s) + 260, opacity: 0 }));
    let ready = false, pending = null;
    onceVisible(iso, () => {
      animate(slabs, {
        translateZ: (s) => base(s),
        opacity: 1,
        duration: 1100,
        delay: stagger(90),
        ease: "out(4)",
        onComplete: () => { ready = true; if (pending) lift(pending); },
      });
    }, "0px");
    function lift(id) {
      if (!ready) { pending = id; return; }
      const active = slabs.findIndex((s) => s.dataset.layer === id);
      iso.classList.toggle("focused", active >= 0);
      slabs.forEach((s, i) => {
        // Open a gap above the active slab so it reads as pulled out of the stack.
        const extra = active < 0 ? 0 : i === active ? 34 : i > active ? 70 : 0;
        animate(s, { translateZ: base(s) + extra, duration: 700, ease: "outElastic(1, .8)" });
      });
    }
    window.addEventListener("layerchange", (e) => lift(e.detail));
    slabs.forEach((s) => {
      s.style.cursor = "pointer";
      s.addEventListener("click", () => document.getElementById(s.dataset.layer)?.scrollIntoView({ behavior: "smooth", block: "start" }));
    });
  }

  // ---------- Pipeline: a signal walks from DirectX to Metal while the diagram is on screen ----------
  const pipeline = document.querySelector(".pipeline");
  if (pipeline) {
    const steps = [...pipeline.querySelectorAll("[data-step]")].sort((a, b) => a.dataset.step - b.dataset.step);
    const bridge = pipeline.querySelector(".pipe-bridge");
    const packet = pipeline.querySelector(".packet");
    let running = false, timer = 0, i = 0;
    const vertical = () => getComputedStyle(pipeline).gridTemplateColumns.split(" ").length < 3;
    function tick() {
      steps.forEach((s) => s.classList.remove("lit"));
      const step = steps[i];
      step.classList.add("lit");
      if (step === bridge && packet) {
        const v = vertical();
        utils.set(packet, { x: 0, y: 0, opacity: 1, left: v ? "50%" : 0, top: v ? 0 : "50%" });
        animate(packet, v
          ? { y: bridge.offsetHeight, duration: 520, ease: "inOut(2)", onComplete: () => utils.set(packet, { opacity: 0 }) }
          : { x: bridge.offsetWidth, duration: 520, ease: "inOut(2)", onComplete: () => utils.set(packet, { opacity: 0 }) });
      }
      i = (i + 1) % steps.length;
      timer = setTimeout(tick, i === 0 ? 1400 : 520);
    }
    whileVisible(pipeline, () => { if (!running) { running = true; tick(); } }, () => {
      running = false; clearTimeout(timer); steps.forEach((s) => s.classList.remove("lit"));
    });
  }

  // ---------- Numbers count up when they appear ----------
  document.querySelectorAll("[data-count]").forEach((el) => {
    const target = Number(el.dataset.count), digits = Number(el.dataset.decimals || 0);
    el.textContent = (0).toFixed(digits);
    onceVisible(el, () => {
      const o = { v: 0 };
      animate(o, {
        v: target, duration: 1600, ease: "out(4)",
        onUpdate: () => { el.textContent = o.v.toFixed(digits); },
      });
    });
  });

  // ---------- Benchmark bars grow ----------
  const bench = document.querySelector(".bench");
  if (bench) {
    const bars = [...bench.querySelectorAll(".bar")];
    utils.set(bars, { scaleX: 0 });
    onceVisible(bench, () => animate(bars, { scaleX: 1, duration: 1000, delay: stagger(60), ease: "out(4)" }));
  }

  // ---------- Hooks for the list scripts ----------
  api.rows = (rows) => {
    animate(rows, { opacity: [0, 1], x: [-12, 0], duration: 500, delay: stagger(40), ease: "out(3)" });
    rows.forEach((row) => {
      const bar = row.querySelector(".fps-bar span");
      if (bar) animate(bar, { scaleX: [0, 1], duration: 900, delay: 150, ease: "out(4)" });
    });
  };
})();
