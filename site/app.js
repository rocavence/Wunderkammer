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
  let world = { w: 1, heights: [1] }, reach = { x: 0, y: 0 }, offset = { x: 0, y: 0 }, velocity = { x: -16, y: -9 };
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
    // Room around the screen for the tallest piece, plus what shows beyond the
    // screen once the wall shrinks into the window, so wrapping never shows a gap.
    const beyond = (1 / 0.5 - 1) / 2;
    reach = {
      x: column + gap + Math.ceil(vw * beyond),
      y: Math.ceil(column * Math.max(...items.map((it) => it.h / it.w))) + gap + Math.ceil(vh * beyond),
    };
    const columns = Math.ceil((vw + 2 * reach.x) / (column + gap)) + 1;
    const heights = new Array(columns).fill(0);
    const goal = vh + 2 * reach.y + 100;
    let i = 0;
    // Shortest column next, until every column reaches past the screen.
    while (Math.min(...heights) < goal) {
      const item = items[i++ % items.length];
      const c = heights.indexOf(Math.min(...heights));
      const h = Math.round(column * item.h / item.w);
      const el = document.createElement("div");
      el.className = "tile";
      el.style.width = column + "px";
      el.style.height = h + "px";
      el.appendChild(picture(item, { decoding: "async", draggable: false }));
      track.appendChild(el);
      tiles.push({ el, x: c * (column + gap), y: heights[c], w: column, h, col: c });
      heights[c] += h + gap;
    }
    // Each column wraps at its own height, so no column leaves a hole at the seam.
    world = { w: columns * (column + gap), heights };
  }

  function place() {
    for (const t of tiles) {
      const x = mod(t.x + offset.x + reach.x, world.w) - reach.x;
      const y = mod(t.y + offset.y + reach.y, world.heights[t.col]) - reach.y;
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
    // The first screen is for reading; the wall can be moved once it's the app's window.
    if (e.button !== 0 || !stage.classList.contains("framed")) return;
    drag = { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, t: performance.now(), moved: false, id: e.pointerId };
    velocity = { x: 0, y: 0 };
  });
  addEventListener("pointermove", (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y, now = performance.now();
    if (!drag.moved && Math.hypot(e.clientX - drag.sx, e.clientY - drag.sy) > 6) {
      drag.moved = true;
      try { wall.setPointerCapture(e.pointerId); } catch (err) { /* the pointer is already gone */ }
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
    drag = null;
    wall.classList.remove("dragging");
  });
  addEventListener("pointercancel", () => { drag = null; wall.classList.remove("dragging"); });
  wall.addEventListener("pointerenter", () => { hover = stage.classList.contains("framed"); });
  wall.addEventListener("pointerleave", () => { hover = false; });

  addEventListener("keydown", (e) => {
    if (e.key === "Escape" && menu.open) menu.open = false;
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

  // ── Piles: the same things, sorted four ways ─────────────────────
  const piles = document.querySelector(".piles");
  if (piles) {
    const names = JSON.parse(piles.dataset.names);
    const tiles = [...piles.querySelectorAll(".pt")];
    const buttons = [...document.querySelectorAll(".modes button")];
    const order = buttons.map((b) => b.dataset.mode);
    const labels = new Map();
    let mode = order[0], auto = true, timer = 0, seen = false;

    function label(key, count) {
      let tag = labels.get(mode + key);
      if (!tag) {
        tag = document.createElement("p");
        tag.className = "pile-label";
        tag.innerHTML = "<b></b><span></span>";
        tag.firstChild.textContent = names[key] || key;
        piles.appendChild(tag);
        labels.set(mode + key, tag);
      }
      tag.lastChild.textContent = count;
      return tag;
    }

    function arrange() {
      const narrow = piles.clientWidth < 640;
      const size = narrow ? 58 : 74, gap = narrow ? 5 : 7, between = narrow ? 20 : 40, head = 28;
      const groups = new Map();
      for (const t of tiles) {
        const key = t.dataset[mode];
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(t);
      }
      const sorted = [...groups.entries()].sort((a, b) => b[1].length - a[1].length);
      // Piles flow in rows, each row centred, never wider than the page.
      const width = piles.clientWidth, rows = [[]];
      let x = 0;
      for (const [key, list] of sorted) {
        const fits = Math.max(1, Math.floor((width + gap) / (size + gap)));
        const cols = Math.min(fits, list.length <= 3 ? list.length : Math.ceil(Math.sqrt(list.length * 1.4)));
        // A pile is at least as wide as its name.
        const w = Math.min(width, Math.max(cols * size + (cols - 1) * gap, label(key, list.length).offsetWidth));
        const h = Math.ceil(list.length / cols) * (size + gap) - gap;
        if (x > 0 && x + w > width) { rows.push([]); x = 0; }
        rows[rows.length - 1].push({ key, list, cols, w, h });
        x += w + between;
      }
      let y = 0;
      const live = new Set();
      rows.forEach((row) => {
        const rowWidth = row.reduce((sum, p) => sum + p.w, 0) + (row.length - 1) * between;
        let px = (width - rowWidth) / 2;
        const rowHeight = Math.max(...row.map((p) => p.h)) + head;
        for (const p of row) {
          p.list.forEach((t, i) => {
            const tx = px + (i % p.cols) * (size + gap), ty = y + head + Math.floor(i / p.cols) * (size + gap);
            t.style.width = t.style.height = size + "px";
            t.style.transitionDelay = still.matches ? "0s" : (Math.random() * 0.18).toFixed(2) + "s";
            t.style.transform = `translate(${tx}px, ${ty}px)`;
          });
          const tag = label(p.key, p.list.length);
          tag.style.transform = `translate(${px}px, ${y}px)`;
          live.add(tag);
          px += p.w + between;
        }
        y += rowHeight + between * 0.7;
      });
      for (const label of labels.values()) label.classList.toggle("on", live.has(label));
      piles.style.height = Math.ceil(y) + "px";
    }

    function show(next, byHand) {
      mode = next;
      buttons.forEach((b) => b.classList.toggle("on", b.dataset.mode === mode));
      arrange();
      if (byHand) { auto = false; clearTimeout(timer); timer = setTimeout(() => { auto = true; cycle(); }, 9000); }
    }
    function cycle() {
      clearTimeout(timer);
      if (!auto || !seen || still.matches) return;
      timer = setTimeout(() => { show(order[(order.indexOf(mode) + 1) % order.length]); cycle(); }, 3200);
    }
    buttons.forEach((b) => b.addEventListener("click", () => show(b.dataset.mode, true)));
    new IntersectionObserver(([e]) => { seen = e.isIntersecting; if (seen) cycle(); else clearTimeout(timer); }, { threshold: 0.35 }).observe(piles);
    arrange();
    requestAnimationFrame(() => piles.classList.add("ready"));
    addEventListener("resize", arrange);
  }

  // ── Step two: the card flies to wherever the arch is ─────────────
  const drop = document.querySelector(".drop-demo");
  if (drop) {
    const aim = () => {
      // From where the card rests (its layout box, not its moving picture) to the arch.
      const card = drop.querySelector(".db-card"), arch = drop.querySelector(".db-arch").getBoundingClientRect();
      const archX = arch.left - drop.getBoundingClientRect().left + arch.width / 2;
      drop.style.setProperty("--to-x", Math.round(archX - (card.offsetLeft + card.offsetWidth / 2)) + "px");
    };
    aim();
    addEventListener("resize", aim);
  }

  // ── Folders: each file flies from where it starts to the room, or to the folder ──
  const scenes = document.querySelectorAll(".fo-scene");
  const aimScenes = () => scenes.forEach((scene) => {
    const file = scene.querySelector(".fo-file");
    const target = scene.querySelector(scene.classList.contains("watch") ? ".fo-room" : ".fo-folder");
    const from = file.offsetLeft + file.offsetWidth / 2, to = target.offsetLeft + target.offsetWidth / 2;
    scene.style.setProperty("--fly", Math.round(to - from) + "px");
  });
  aimScenes();
  addEventListener("resize", aimScenes);

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
  fetch(`${wall.dataset.root}assets/wall.json?v=${wall.dataset.v}`).then((r) => r.json()).then((data) => {
    items = data;
    layout();
    morph();
    place();
    requestAnimationFrame(() => stage.classList.add("ready"));
    requestAnimationFrame(tick);
    finderStart();
  });
  // ── The glowing door ──────────────────────────────────────────────
  // Swings open as the story arrives, wider under the pointer; a click
  // throws it open and it settles back on a spring. Dust drifts in the light.
  const why = document.querySelector(".why");
  if (why) {
    const scene = why.querySelector(".why-scene");
    const world = why.querySelector(".door-world");
    const seam = why.querySelector(".door-seam");
    const dust = why.querySelector(".door-dust");
    const pen = dust.getContext("2d");
    let open = 0, speed = 0, boost = 0, rx = 0, ry = 0, tx = 0, ty = 0;
    let live = false, scale = 1, w = 0, h = 0, ratio = 1, px = -999, py = -999, mote = "255,196,140";
    const motes = [];

    const size = () => {
      ratio = Math.min(2, devicePixelRatio || 1);
      w = scene.clientWidth; h = scene.clientHeight;
      dust.width = w * ratio; dust.height = h * ratio;
      const css = getComputedStyle(scene);
      scale = parseFloat(css.getPropertyValue("--s")) || 1;
      mote = getComputedStyle(why).getPropertyValue("--mote").trim() || mote;
    };
    const arrived = () => {
      // Shut as the doorway comes into view, open by the time it's in the middle.
      const r = scene.getBoundingClientRect();
      return clamp((innerHeight - r.top - 60) / (innerHeight * 0.6));
    };
    const pose = () => {
      world.style.setProperty("--open", open.toFixed(4));
      world.style.transform = `scale(${scale}) rotateX(${rx.toFixed(3)}deg) rotateY(${ry.toFixed(3)}deg)`;
    };

    scene.addEventListener("pointermove", (e) => {
      const r = scene.getBoundingClientRect();
      tx = (e.clientX - r.left) / r.width - 0.5;
      ty = (e.clientY - r.top) / r.height - 0.5;
      px = e.clientX - r.left; py = e.clientY - r.top;
      boost = 0.16;
    });
    scene.addEventListener("pointerleave", () => { tx = ty = 0; boost = 0; px = py = -999; });
    scene.addEventListener("click", () => { speed += 0.09; });

    function drift(now) {
      pen.setTransform(ratio, 0, 0, ratio, 0, 0);
      pen.clearRect(0, 0, w, h);
      const d = seam.getBoundingClientRect(), s = scene.getBoundingClientRect();
      const left = d.left - s.left, top = d.top - s.top, mid = left + d.width / 2;
      const room = Math.round(90 * clamp(open));
      while (motes.length < room) {
        motes.push({
          x: left + Math.random() * d.width,
          y: top + d.height * (0.25 + Math.random() * 0.75),
          vx: (Math.random() - 0.5) * 0.2, vy: -(0.12 + Math.random() * 0.32),
          r: 0.5 + Math.random() * 1.7, age: 0, life: 220 + Math.random() * 320, seed: Math.random() * 1000,
        });
      }
      pen.globalCompositeOperation = "lighter";
      for (let i = motes.length - 1; i >= 0; i--) {
        const m = motes[i];
        m.age++;
        // Out through the doorway, wandering a little, shy of the pointer.
        m.vx += (m.x - mid) * 0.00004 + Math.sin((m.age + m.seed) / 37) * 0.004;
        const dx = m.x - px, dy = m.y - py, near = dx * dx + dy * dy;
        if (near < 3600) { m.vx += dx / near * 1.6; m.vy += dy / near * 1.6; }
        m.vx *= 0.985; m.vy *= 0.995;
        m.x += m.vx; m.y += m.vy;
        if (m.age > m.life || (motes.length > room && Math.random() < 0.02)) { motes.splice(i, 1); continue; }
        const a = Math.sin(Math.PI * m.age / m.life) * clamp(open) * (0.55 + 0.45 * Math.sin((now + m.seed * 40) / 260));
        pen.fillStyle = `rgba(${mote},${(a * 0.9).toFixed(3)})`;
        pen.beginPath();
        pen.arc(m.x, m.y, m.r, 0, Math.PI * 2);
        pen.fill();
      }
    }

    function swing(now) {
      if (!live) return;
      const want = clamp(ease(arrived()) * 0.68 + boost, 0, 1.06);
      speed += (want - open) * 0.05;
      speed *= 0.86;
      open += speed;
      rx = lerp(rx, -ty * 9 + Math.sin(now / 2700) * 1.4, 0.06);
      ry = lerp(ry, tx * 18 + Math.sin(now / 3600) * 2.4, 0.06);
      pose();
      drift(now);
      requestAnimationFrame(swing);
    }

    size();
    addEventListener("resize", size);
    if (still.matches) {
      open = 0.82;
      pose();
    } else {
      new IntersectionObserver(([e]) => {
        const was = live;
        live = e.isIntersecting;
        if (live && !was) requestAnimationFrame(swing);
      }).observe(scene);
    }
  }

  let resizing = 0;
  addEventListener("resize", () => {
    morph();
    clearTimeout(resizing);
    resizing = setTimeout(() => { if (items.length) layout(); }, 200);
  });
  addEventListener("scroll", morph, { passive: true });
})();
