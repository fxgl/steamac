// Hero: the real launcher recording drawn live as a matrix of square pixels on a canvas.
// A lens under the pointer shows the actual video. Without JavaScript the plain <video> shows.
(function () {
  "use strict";
  const fig = document.querySelector(".matrix");
  if (!fig) return;
  const video = fig.querySelector("video");
  const canvas = fig.querySelector("canvas");
  const ctx = canvas.getContext("2d");
  const small = document.createElement("canvas");
  const sctx = small.getContext("2d", { willReadFrequently: true });
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const modeBox = fig.querySelector(".matrix-mode");
  const screen = fig.querySelector(".matrix-screen");

  let w = 0, h = 0, dpr = 1, cell = 8, cols = 0, rows = 0;
  let mode = "pixels", onScreen = !("IntersectionObserver" in window), raf = 0, last = 0, started = 0;
  let lens = null, lensR = 0, lensTarget = 0;
  let peak = 0.35;   // running brightness peak for contrast stretch: the recording is mostly dark

  fig.classList.add("matrix-on");
  modeBox.hidden = false;

  function resize() {
    const r = screen.getBoundingClientRect();
    dpr = Math.min(2, window.devicePixelRatio || 1);
    w = Math.max(1, Math.round(r.width * dpr)); h = Math.max(1, Math.round(r.height * dpr));
    canvas.width = w; canvas.height = h;
    cell = Math.max(4, Math.round(r.width / 120)) * dpr;
    cols = Math.ceil(w / cell); rows = Math.ceil(h / cell);
    small.width = cols; small.height = rows;
  }

  function source() {
    if (video.readyState >= 2) return video;
    if (!fig.__poster) { fig.__poster = new Image(); fig.__poster.onload = () => kick(); fig.__poster.src = video.poster; }
    const poster = fig.__poster;
    return poster.complete && poster.naturalWidth ? poster : null;
  }

  function frame(now) {
    const src = source();
    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, w, h);
    // Faint grid so the matrix reads even on black frames.
    ctx.fillStyle = "rgba(255,255,255,.06)";
    const dot = Math.max(1, Math.round(dpr));
    for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) ctx.fillRect(x * cell + cell / 2 - dot / 2, y * cell + cell / 2 - dot / 2, dot, dot);
    if (!src) return;

    sctx.drawImage(src, 0, 0, cols, rows);
    const data = sctx.getImageData(0, 0, cols, rows).data;
    let max = 0;
    for (let i = 0; i < data.length; i += 4) {
      const l = (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]) / 255;
      if (l > max) max = l;
    }
    peak += (Math.max(0.2, max) - peak) * 0.08;

    // Entrance: rows appear top to bottom behind a bright scanline.
    const reveal = reduced ? 1 : Math.min(1, (now - started) / 1400);
    const limit = Math.floor(rows * reveal);
    ctx.fillStyle = "#fff";
    for (let y = 0; y < limit; y++) {
      for (let x = 0; x < cols; x++) {
        const i = (y * cols + x) * 4;
        let l = (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]) / 255 / peak;
        if (l < 0.08) continue;
        l = Math.min(1, l);
        const s = Math.max(dpr, Math.round(cell * 0.86 * Math.sqrt(l)));
        ctx.globalAlpha = 0.25 + 0.75 * l;
        ctx.fillRect(x * cell + (cell - s) / 2, y * cell + (cell - s) / 2, s, s);
      }
    }
    ctx.globalAlpha = 1;
    if (reveal < 1) {
      ctx.fillStyle = "rgba(255,255,255,.85)";
      ctx.fillRect(0, limit * cell, w, Math.max(1, dpr));
    }

    // Lens: the real picture under the pointer, growing in and out.
    lensR += (lensTarget - lensR) * 0.18;
    if (lens && lensR > 1) {
      ctx.save();
      ctx.beginPath(); ctx.arc(lens.x, lens.y, lensR, 0, Math.PI * 2); ctx.clip();
      ctx.drawImage(src, 0, 0, w, h);
      ctx.restore();
      ctx.strokeStyle = "rgba(255,255,255,.9)"; ctx.lineWidth = dpr;
      ctx.beginPath(); ctx.arc(lens.x, lens.y, lensR, 0, Math.PI * 2); ctx.stroke();
    }
  }

  function loop(now) {
    raf = 0;
    if (!onScreen || document.hidden || mode !== "pixels") return;
    if (!last || now - last >= 33) { last = now; frame(now); }   // ~30 fps is plenty for the recording
    if (!reduced || lensR > 0.5 || Math.abs(lensTarget - lensR) > 0.5) raf = requestAnimationFrame(loop);
  }
  const kick = () => {
    if (!raf && onScreen && !document.hidden && mode === "pixels") raf = requestAnimationFrame(loop);
  };
  function updatePlayback() {
    if (onScreen && !document.hidden) {
      if (!reduced) video.play().catch(() => {});
      kick();
    } else {
      video.pause();
      if (raf) { cancelAnimationFrame(raf); raf = 0; }
    }
  }

  function setMode(next) {
    mode = next;
    fig.dataset.mode = next;
    modeBox.querySelectorAll("button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.mode === next)));
    if (next === "pixels") { resize(); kick(); }
  }
  modeBox.querySelectorAll("button").forEach((b) => b.addEventListener("click", () => setMode(b.dataset.mode)));

  screen.addEventListener("pointermove", (e) => {
    const r = screen.getBoundingClientRect();
    lens = { x: (e.clientX - r.left) * dpr, y: (e.clientY - r.top) * dpr };
    lensTarget = Math.min(w, h) * 0.24;
    kick();
  });
  screen.addEventListener("pointerleave", () => { lensTarget = 0; kick(); });

  if (reduced) { video.removeAttribute("autoplay"); video.controls = true; }
  video.addEventListener("loadeddata", kick);
  video.addEventListener("seeked", kick);
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(([e]) => {
      onScreen = e.isIntersecting;
      updatePlayback();
    }, { threshold: 0.05 }).observe(fig);
  }
  document.addEventListener("visibilitychange", updatePlayback);
  new ResizeObserver(() => { resize(); kick(); }).observe(screen);

  started = performance.now();
  setMode("pixels");
  if (reduced) video.pause();
  updatePlayback();
})();
