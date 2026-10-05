// wunder.rocavence.com: the wall that drifts, and the small things that move.
(() => {
  "use strict";

  const root = document.documentElement;
  const still = matchMedia("(prefers-reduced-motion: reduce)");
  const lerp = (a, b, t) => a + (b - a) * t;
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const ease = (t) => 1 - Math.pow(1 - t, 3);
  const mod = (a, n) => ((a % n) + n) % n;
  let items = [];

  // ── Reveal on scroll ──────────────────────────────────────────────
  const reveal = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add("in");
      reveal.unobserve(e.target);
      if (e.target.classList.contains("stats")) countUp(e.target);
    }
  }, { rootMargin: "0px 0px -8% 0px" });
  document.querySelectorAll(".rise, .stats").forEach((el) => reveal.observe(el));

  function countUp(stats) {
    if (still.matches) return;
    for (const b of stats.querySelectorAll("b")) {
      const text = b.textContent, digits = text.replace(/\D/g, "");
      if (!digits || digits === "0") continue;
      const target = Number(digits), start = performance.now(), length = 1100;
      const step = (now) => {
        const t = clamp((now - start) / length), n = Math.round(target * ease(t));
        let i = 0;
        const shown = String(n).padStart(digits.length, " ");
        b.textContent = text.replace(/\d/g, () => shown[i++] ?? "").replace(/^[\s,.]+/, "");
        if (t < 1) requestAnimationFrame(step); else b.textContent = text;
      };
      requestAnimationFrame(step);
    }
  }

  // ── Theme ─────────────────────────────────────────────────────────
  const toggle = document.querySelector(".theme");
  const order = ["auto", "light", "dark"];
  const current = () => root.dataset.theme || "auto";
  const label = () => {
    const text = toggle.dataset[current()];
    toggle.setAttribute("aria-label", text);
    toggle.title = text;
  };
  label();
  toggle.addEventListener("click", () => {
    const next = order[(order.indexOf(current()) + 1) % order.length];
    if (next === "auto") delete root.dataset.theme; else root.dataset.theme = next;
    try { next === "auto" ? localStorage.removeItem("theme") : localStorage.setItem("theme", next); } catch (e) {}
    label();
  });

  // ── Language menu ─────────────────────────────────────────────────
  const menu = document.querySelector(".menu");
  document.querySelectorAll(".menu a[hreflang]").forEach((a) => a.addEventListener("click", () => {
    try { localStorage.setItem("lang", a.getAttribute("hreflang")); } catch (e) {}
  }));
  document.addEventListener("click", (e) => { if (menu.open && !menu.contains(e.target)) menu.open = false; });

  // ── The wall: Wunder's wander mode, drifting on its own ──────────
  const stage = document.querySelector(".stage");
  const pin = stage.querySelector(".stage-pin");
  const wall = stage.querySelector(".wall");
  const track = wall.querySelector(".wall-track");
  const tiles = [];
  let world = { w: 1, h: 1 }, offset = { x: 0, y: 0 }, velocity = { x: -16, y: -9 };
  let drag = null, hover = false, frame = { x: 0, y: 0, w: 1, h: 1 }, progress = 0, visible = true;

  function picture(item, props = {}) {
    const img = new Image();
    img.src = `${wall.dataset.root}assets/${item.src}`;
    img.alt = "";
    Object.assign(img, props);
    return img;
  }

  function layout() {
    track.textContent = "";
    tiles.length = 0;
    const vw = innerWidth, vh = innerHeight;
    const column = vw < 640 ? 150 : 236, gap = vw < 640 ? 10 : 14;
    const columns = Math.ceil((vw + 2 * column) / (column + gap)) + 1;
    const heights = new Array(columns).fill(0);
    const goal = vh + 2 * column + 200;
    let i = 0;
    // Shortest column next, until every column reaches past the screen.
    while (Math.min(...heights) < goal) {
      const item = items[i++ % items.length];
      const c = heights.indexOf(Math.min(...heights));
      const h = Math.round(column * item.h / item.w);
      const el = document.createElement("button");
      el.className = "tile";
      el.type = "button";
      el.tabIndex = -1;
      el.style.width = column + "px";
      el.style.height = h + "px";
      el.setAttribute("aria-label", item.title);
      el.appendChild(picture(item, { decoding: "async", draggable: false }));
      el.item = item;
      track.appendChild(el);
      tiles.push({ el, x: c * (column + gap), y: heights[c], w: column, h });
      heights[c] += h + gap;
    }
    world = { w: columns * (column + gap), h: Math.max(...heights) };
  }

  function place() {
    const pad = 260;
    for (const t of tiles) {
      const x = mod(t.x + offset.x + pad, world.w) - pad;
      const y = mod(t.y + offset.y + pad, world.h) - pad;
      t.el.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0)`;
    }
  }

  // Scrolling through the stage shrinks the wall into the app's own window.
  function morph() {
    const rect = stage.getBoundingClientRect(), vw = innerWidth, vh = innerHeight;
    progress = clamp(-rect.top / Math.max(rect.height - vh, 1));
    const e = still.matches ? 1 : ease(clamp((progress - 0.04) / 0.62));
    const w = Math.min(1120, vw * (vw < 640 ? 0.94 : 0.9)), h = vw < 640 ? Math.min(w * 1.15, vh * 0.64) : Math.min(w * 0.64, vh * 0.78);
    frame = { x: lerp(0, (vw - w) / 2, e), y: lerp(0, (vh - h) / 2 + 26, e), w: lerp(vw, w, e), h: lerp(vh, h, e) };
    pin.style.setProperty("--fx", frame.x + "px");
    pin.style.setProperty("--fy", frame.y + "px");
    pin.style.setProperty("--fw", frame.w + "px");
    pin.style.setProperty("--fh", frame.h + "px");
    pin.style.setProperty("--fr", lerp(0, 16, e) + "px");
    pin.style.setProperty("--scale", lerp(1, vw < 640 ? 0.52 : 0.56, e).toFixed(4));
    pin.style.setProperty("--copy", (1 - clamp(progress / 0.26)).toFixed(3));
    pin.style.setProperty("--chrome", clamp((progress - 0.36) / 0.3).toFixed(3));
    stage.classList.toggle("framed", e > 0.98);
  }

  let last = performance.now();
  function tick(now) {
    const dt = Math.min((now - last) / 1000, 0.05);
    last = now;
    if (visible) {
      if (!drag && !still.matches) {
        const slow = hover ? 0.25 : 1;
        offset.x += velocity.x * dt * slow;
        offset.y += velocity.y * dt * slow;
        // A fling settles back into the drift.
        velocity.x = lerp(velocity.x, -16, dt * 1.6);
        velocity.y = lerp(velocity.y, -9, dt * 1.6);
      }
      place();
    }
    requestAnimationFrame(tick);
  }

  new IntersectionObserver(([e]) => { visible = e.isIntersecting; }).observe(stage);

  wall.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    drag = { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, t: performance.now(), moved: false, id: e.pointerId };
    velocity = { x: 0, y: 0 };
  });
  addEventListener("pointermove", (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y, now = performance.now();
    if (!drag.moved && Math.hypot(e.clientX - drag.sx, e.clientY - drag.sy) > 6) {
      drag.moved = true;
      wall.setPointerCapture(e.pointerId);
      wall.classList.add("dragging");
    }
    if (!drag.moved) return;
    const scale = parseFloat(pin.style.getPropertyValue("--scale")) || 1;
    offset.x += dx / scale;
    offset.y += dy / scale;
    const dtime = Math.max(now - drag.t, 1) / 1000;
    velocity = { x: dx / scale / dtime, y: dy / scale / dtime };
    drag.x = e.clientX; drag.y = e.clientY; drag.t = now;
  });
  addEventListener("pointerup", (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const moved = drag.moved;
    drag = null;
    wall.classList.remove("dragging");
    if (!moved) {
      const tile = e.target instanceof Element && e.target.closest(".tile");
      if (tile) open(tile);
    }
  });
  addEventListener("pointercancel", () => { drag = null; wall.classList.remove("dragging"); });
  wall.addEventListener("pointerenter", () => { hover = true; });
  wall.addEventListener("pointerleave", () => { hover = false; });

  // ── Looking closer: the picture grows out of its tile ─────────────
  const preview = document.querySelector(".preview");
  let opened = null;

  function fit(item) {
    const maxW = innerWidth * 0.82, maxH = innerHeight * 0.72;
    const s = Math.min(maxW / item.w, maxH / item.h);
    const w = item.w * s, h = item.h * s;
    return { x: (innerWidth - w) / 2, y: (innerHeight - h) / 2 - 24, w, h };
  }

  function open(tile) {
    if (opened) return;
    const item = tile.item, from = tile.getBoundingClientRect(), to = fit(item);
    const img = preview.querySelector("img");
    img.src = tile.querySelector("img").src;
    img.alt = item.title;
    preview.querySelector(".p-title").textContent = item.title;
    preview.querySelector(".p-meta").textContent = [item.artist && item.artist.split(" (")[0], item.date].filter(Boolean).join(" · ");
    const link = preview.querySelector(".p-link");
    link.href = item.url || "https://www.clevelandart.org/open-access";
    preview.hidden = false;
    tile.style.visibility = "hidden";
    opened = { tile, item };
    Object.assign(img.style, { left: to.x + "px", top: to.y + "px", width: to.w + "px", height: to.h + "px" });
    const flip = `translate(${from.x - to.x}px, ${from.y - to.y}px) scale(${from.width / to.w}, ${from.height / to.h})`;
    img.animate([{ transform: flip, borderRadius: "10px" }, { transform: "none", borderRadius: "6px" }],
      { duration: still.matches ? 1 : 620, easing: "cubic-bezier(.2,.9,.22,1.06)" });
    preview.animate([{ opacity: 0 }, { opacity: 1 }], { duration: still.matches ? 1 : 280, fill: "forwards" });
    preview.querySelector(".p-close").focus({ preventScroll: true });
  }

  function close() {
    if (!opened) return;
    const { tile } = opened, img = preview.querySelector("img");
    const to = img.getBoundingClientRect(), back = tile.getBoundingClientRect();
    const flip = `translate(${back.x - to.x}px, ${back.y - to.y}px) scale(${back.width / to.width}, ${back.height / to.height})`;
    const run = img.animate([{ transform: "none" }, { transform: flip }], { duration: still.matches ? 1 : 420, easing: "cubic-bezier(.4,0,.2,1)", fill: "forwards" });
    preview.animate([{ opacity: 1 }, { opacity: 0 }], { duration: still.matches ? 1 : 380, fill: "forwards" });
    run.onfinish = () => {
      preview.hidden = true;
      tile.style.visibility = "";
      run.cancel();
      opened = null;
    };
  }
  preview.addEventListener("click", (e) => { if (!(e.target instanceof Element && e.target.closest(".p-link"))) close(); });
  addEventListener("keydown", (e) => {
    if (e.key === "Escape") { close(); if (menu.open) menu.open = false; }
  });

  // ── ⌘⇧C: what collecting feels like ──────────────────────────────
  const toast = document.querySelector(".toast");
  let toastTimer = 0;
  function collect() {
    if (!items.length) return;
    const item = items[Math.floor(Math.random() * items.length)];
    toast.querySelector("img").src = `${wall.dataset.root}assets/${item.src}`;
    toast.querySelector(".t-title").textContent = item.title;
    toast.classList.remove("show");
    void toast.offsetWidth;
    toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("show"), 1900);
  }
  document.querySelectorAll(".collect").forEach((b) => b.addEventListener("click", collect));
  addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "c") { e.preventDefault(); collect(); }
  });

  // ── Find it by describing it ─────────────────────────────────────
  const finder = document.querySelector(".finder");
  function finderStart() {
    const grid = finder.querySelector(".f-grid"), field = finder.querySelector(".f-query"), count = finder.querySelector(".f-count");
    const queries = JSON.parse(finder.dataset.queries), found = finder.dataset.found;
    grid.replaceChildren(...items.map((it) => picture(it, { loading: "lazy" })));
    const thumbs = [...grid.children];
    let q = 0, timer = 0, running = false;
    const show = (key) => {
      let n = 0;
      thumbs.forEach((img, i) => {
        const it = items[i];
        const hit = !key || (key.startsWith("color:") ? it.color === key.slice(6) : it.tags.includes(key));
        img.classList.toggle("dim", !hit);
        if (hit) n++;
      });
      count.textContent = key ? found.replace("{n}", n) : "";
    };
    const type = (text, done) => {
      let i = 0;
      const step = () => {
        field.textContent = text.slice(0, ++i);
        if (i < text.length) timer = setTimeout(step, 55 + Math.random() * 60); else done();
      };
      step();
    };
    const erase = (done) => {
      const step = () => {
        field.textContent = field.textContent.slice(0, -1);
        if (field.textContent) timer = setTimeout(step, 22); else done();
      };
      step();
    };
    const loop = () => {
      if (!running) return;
      const [text, key] = queries[q++ % queries.length];
      type(text, () => {
        show(key);
        timer = setTimeout(() => { show(null); erase(() => { timer = setTimeout(loop, 450); }); }, 2600);
      });
    };
    if (still.matches) { field.textContent = queries[0][0]; show(queries[0][1]); return; }
    new IntersectionObserver(([e]) => {
      if (e.isIntersecting && !running) { running = true; loop(); }
      if (!e.isIntersecting && running) { running = false; clearTimeout(timer); field.textContent = ""; show(null); }
    }, { threshold: 0.3 }).observe(finder);
  }

  // ── The three spaces, as you scroll ──────────────────────────────
  const view = document.querySelector(".story-view");
  if (view) {
    const steps = [...document.querySelectorAll(".story-step")];
    const watch = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        const i = steps.indexOf(e.target);
        view.dataset.active = i;
        steps.forEach((s, j) => s.classList.toggle("on", j === i));
      }
    }, { rootMargin: "-45% 0px -45% 0px" });
    steps.forEach((s) => watch.observe(s));
  }

  // ── A button that leans toward you ───────────────────────────────
  if (matchMedia("(hover: hover)").matches && !still.matches) {
    document.querySelectorAll(".cta").forEach((b) => {
      b.addEventListener("pointermove", (e) => {
        const r = b.getBoundingClientRect();
        b.style.translate = `${((e.clientX - r.left) / r.width - 0.5) * 10}px ${((e.clientY - r.top) / r.height - 0.5) * 8}px`;
      });
      b.addEventListener("pointerleave", () => { b.style.translate = ""; });
    });
  }

  // ── Start ────────────────────────────────────────────────────────
  fetch(`${wall.dataset.root}assets/wall.json`).then((r) => r.json()).then((data) => {
    items = data;
    layout();
    morph();
    place();
    requestAnimationFrame(() => stage.classList.add("ready"));
    requestAnimationFrame(tick);
    finderStart();
  });
  let resizing = 0;
  addEventListener("resize", () => {
    morph();
    clearTimeout(resizing);
    resizing = setTimeout(() => { if (items.length) layout(); }, 200);
  });
  addEventListener("scroll", morph, { passive: true });
})();
