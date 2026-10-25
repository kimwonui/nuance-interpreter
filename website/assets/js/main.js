// Page controller: three phones (hero, table story, interactive demo), scroll/pointer poses,
// the demo panel, the languages grid and the "hear the meaning" waveform illustration.
(function () {
  const NUA = window.NUA;
  const params = new URLSearchParams(location.search);
  const reduce = params.has("reduced") || matchMedia("(prefers-reduced-motion: reduce)").matches;
  const coarse = matchMedia("(pointer: coarse)").matches;
  const lowPower = params.has("lite") ||
    (navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 4) ||
    (navigator.deviceMemory && navigator.deviceMemory <= 4) ||
    (coarse && Math.min(screen.width, screen.height) < 500);
  const narrow = () => innerWidth <= 900;
  document.documentElement.classList.toggle("reduced-motion", reduce);
  document.documentElement.classList.toggle("low-power", !!lowPower);
  if (lowPower) NUA.loop.fps = 30;

  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, k) => a + (b - a) * k;
  const ease = (x) => x * x * (3 - 2 * x);
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));

  const phoneOpts = { reduce, lowPower, layers: lowPower ? 8 : 16 };

  /** Fit the 412×866 device into its stage. */
  function fit(phone, host, hFactor, wFactor) {
    const run = () => {
      const s = Math.min((host.clientHeight * hFactor) / 866, (host.clientWidth * wFactor) / 412);
      phone.device.style.setProperty("--scale", clamp(s, 0.3, 1.1).toFixed(3));
    };
    run();
    addEventListener("resize", run);
  }

  /** Smoothly approaches target poses each frame. */
  const poses = [];
  function posed(phone, initial) {
    const p = { phone, cur: Object.assign({}, initial), target: Object.assign({}, initial) };
    phone.setPose(initial.rx, initial.ry, initial.rz);
    poses.push(p);
    return p;
  }
  function poseTick() {
    poses.forEach((p) => {
      let moved = false;
      ["rx", "ry", "rz"].forEach((k) => {
        const d = p.target[k] - p.cur[k];
        if (Math.abs(d) > 0.01) { p.cur[k] += d * (reduce ? 1 : 0.09); moved = true; }
      });
      if (moved) p.phone.setPose(p.cur.rx, p.cur.ry, p.cur.rz);
    });
    requestAnimationFrame(poseTick);
  }

  let pointer = { x: 0, y: 0 };
  if (!reduce && !coarse) {
    addEventListener("pointermove", (e) => {
      pointer.x = (e.clientX / innerWidth) * 2 - 1;
      pointer.y = (e.clientY / innerHeight) * 2 - 1;
    }, { passive: true });
  }

  /** A sequence that loops the illustrative conversation on a non-interactive phone. */
  async function autoplay(app, isActive) {
    for (;;) {
      if (!isActive()) { await wait(600); continue; }
      await wait(1300);
      await app.start();
      await wait(1300);
      await app.say("me");
      await wait(800);
      await app.say("them");
      await wait(1500);
      app.stop();
      await wait(900);
    }
  }

  /** Reduced motion: one still, readable frame instead of a moving sequence. */
  function stillFrame(app) {
    Object.assign(app.s, { auto: "speaking", speaker: "me", listener: "them", speakingLang: app.s.them, holding: false });
    app.render();
  }

  // ---------------------------------------------------------------- Hero
  const heroHost = $("#hero-phone");
  const hero = new NUA.Phone(heroHost, phoneOpts);
  fit(hero, heroHost.parentElement, 0.8, 0.72);
  const heroPose = posed(hero, { rx: 6, ry: -20, rz: 2 });
  const cards = { them: $(".fc-top"), me: $(".fc-bottom") };
  function showCard(side, label, text, nua) {
    const c = cards[side];
    if (!text) return c.classList.remove("show");
    c.querySelector(".fc-label").textContent = label;
    c.querySelector(".fc-text").textContent = text;
    c.querySelector(".fc-text").lang = label.includes("Korean") ? "ko" : "en";
    c.classList.toggle("nua", !!nua);
    c.classList.add("show");
  }
  function hideCards() { cards.them.classList.remove("show"); cards.me.classList.remove("show"); }
  hero.app.on((type, d) => {
    if (type === "line" && d.phase === "talk") {
      hideCards();
      showCard(d.side, `${d.side === "me" ? "You" : "Them"} · ${d.from.name}`, d.src);
    } else if (type === "line" && d.phase === "speak") {
      showCard(d.side === "me" ? "them" : "me", `NUA · ${d.to.name}`, d.out, true);
    } else if (type === "stopped") hideCards();
  });
  if (reduce) {
    stillFrame(hero.app);
    const line = NUA.SAMPLES.ko[0];
    showCard("me", "You · Korean", line.ko);
    showCard("them", "NUA · English", line.en, true);
  } else {
    autoplay(hero.app, () => hero.visible);
  }

  // ---------------------------------------------------------------- One phone, two voices (scroll story)
  const how = $("#how");
  const howStage = $(".how-stage");
  const tableHost = $("#table-phone");
  const table = new NUA.Phone(tableHost, phoneOpts);
  fit(table, tableHost.parentElement, 0.94, 0.66);
  const tablePose = posed(table, { rx: 50, ry: 0, rz: 0 });
  const steps = $$(".how-steps li");
  let step = -1, storyRun = 0;

  async function storyTalk(run) {
    while (run === storyRun) {
      if (!(await table.app.say("me")) || run !== storyRun) return;
      await wait(700);
      if (run !== storyRun || !(await table.app.say("them"))) return;
      await wait(900);
    }
  }
  function setStep(i) {
    if (i === step) return;
    step = i;
    steps.forEach((li, k) => { li.classList.toggle("active", k === i); li.classList.toggle("seen", k < i); });
    howStage.classList.toggle("seats", i >= 1);
    const run = ++storyRun;
    if (i < 2) table.app.stop();
    else if (i === 2) {
      if (table.app.s.auto === "off") table.app.start();
      else { // back from step 4: end the current turn, keep listening
        table.app.cancel();
        Object.assign(table.app.s, { auto: "waiting", speaker: null, listener: null, holding: false, turn: null });
        table.app.render();
      }
    }
    else if (i === 3) {
      (async () => {
        if (table.app.s.auto === "off") { await table.app.start(); await wait(900); }
        storyTalk(run);
      })();
    }
  }

  function storyFrame() {
    if (narrow() || reduce) return;
    const r = how.getBoundingClientRect();
    const total = how.offsetHeight - innerHeight;
    const p = clamp(-r.top / Math.max(1, total), 0, 1);
    const lay = ease(clamp(p / 0.28, 0, 1));
    tablePose.target.rx = lerp(10, 56, lay);
    tablePose.target.ry = lerp(-16, 0, lay) + pointer.x * 3;
    tablePose.target.rz = lerp(-6, 0, lay);
    setStep(p < 0.2 ? 0 : p < 0.42 ? 1 : p < 0.64 ? 2 : 3);
  }
  if (reduce) {
    Object.assign(tablePose.target, { rx: 50, ry: 0, rz: 0 });
    stillFrame(table.app);
    steps.forEach((li) => li.classList.add("active"));
    howStage.classList.add("seats");
  } else {
    let narrowLoop = false;
    const onLayout = () => {
      if (narrow()) {
        Object.assign(tablePose.target, { rx: 48, ry: 0, rz: 0 });
        steps.forEach((li) => { li.classList.remove("seen"); li.classList.add("active"); });
        if (!narrowLoop) { narrowLoop = true; storyRun++; autoplay(table.app, () => table.visible && narrow()); }
      } else {
        step = -1;
        storyFrame();
      }
    };
    onLayout();
    addEventListener("resize", onLayout);
    addEventListener("scroll", storyFrame, { passive: true });
  }

  // ---------------------------------------------------------------- Interactive demo
  const demoHost = $("#demo-phone");
  const demo = new NUA.Phone(demoHost, Object.assign({}, phoneOpts, { interactive: true }));
  fit(demo, demoHost.parentElement, 0.92, 0.9);
  const demoPose = posed(demo, { rx: 3, ry: -8, rz: 0 });
  const app = demo.app;
  const sayButtons = { me: $('[data-say="me"]'), them: $('[data-say="them"]'), exchange: $('[data-say="exchange"]') };
  const talkHint = $(".talk-hint");
  const transcript = $(".transcript");
  const stateItems = $$(".state-list li");
  const dsItems = { start: $('[data-ds="start"]'), lang: $('[data-ds="lang"]'), talk: $('[data-ds="talk"]'), stop: $('[data-ds="stop"]') };
  let changedLang = false, lastPair = "ko-en";

  function stateKey(s) {
    if (s.auto === "waiting" || s.auto === "hearing") return s.holding ? "holding" : "listening";
    if (s.auto === "off") return "off";
    return s.auto;
  }

  app.on((type, d) => {
    const s = app.s;
    if (type === "state") {
      const me = app.lang("me"), them = app.lang("them");
      const pair = s.me + "-" + s.them;
      if (pair !== lastPair) { changedLang = true; lastPair = pair; }
      const key = stateKey(s);
      stateItems.forEach((li) => li.classList.toggle("active", li.dataset.state === key));
      $(".sc-dir").textContent = `${app.isOneWay ? "One-way" : "Two-way"} · ${me.name} ${app.isOneWay ? "→" : "↔"} ${them.name}`;
      sayButtons.me.textContent = `You talk · ${me.name}`;
      sayButtons.them.textContent = `They talk · ${them.name}`;
      sayButtons.me.disabled = !app.canSay("me");
      sayButtons.them.disabled = !app.canSay("them");
      sayButtons.exchange.disabled = !app.canSay("me");
      let hint;
      if (s.auto === "off") hint = "Start the conversation first: tap the orb on the phone.";
      else if (s.auto === "connecting") hint = "Connecting…";
      else if (s.auto === "muted") hint = "Muted. Tap Unmute on the phone to continue.";
      else if (!app.hasSamples()) hint = `No sample lines for ${me.name} ↔ ${them.name}; the states still play.`;
      else if (app.isOneWay) hint = "One-way interprets only your language, so “They talk” is off.";
      else hint = s.auto === "waiting" ? "Pick who talks next. Tapping again mid-turn starts a new turn." : "NUA is handling this turn.";
      talkHint.textContent = hint;
      const running = s.auto !== "off";
      dsItems.start.classList.toggle("active", !running);
      dsItems.start.classList.toggle("done", running);
      dsItems.lang.classList.toggle("done", changedLang);
      dsItems.talk.classList.toggle("active", running && s.auto !== "muted");
      dsItems.stop.classList.toggle("active", s.auto === "muted");
    } else if (type === "line") {
      if (d.phase === "talk") addLine(d.side === "me" ? "You" : "Them", d.from, d.src || `(No sample line in ${d.from.name}.)`);
      if (d.phase === "speak") addLine("NUA", d.to, d.out || `(Speaks ${d.to.name}.)`, true);
    }
  });
  app.render();

  function addLine(who, lang, text, nua) {
    const empty = $(".t-empty", transcript);
    if (empty) empty.remove();
    const li = document.createElement("li");
    if (nua) li.className = "nua";
    li.innerHTML = `<span class="t-who"></span><span class="t-text"></span>`;
    li.querySelector(".t-who").textContent = `${who} · ${lang.name}`;
    const t = li.querySelector(".t-text");
    t.textContent = text;
    t.lang = lang.code;
    if (lang.code === "ar") t.dir = "rtl";
    transcript.appendChild(li);
    while (transcript.children.length > 8) transcript.firstElementChild.remove();
    transcript.scrollTop = transcript.scrollHeight;
  }

  let exchangeRun = 0;
  sayButtons.me.addEventListener("click", () => { exchangeRun++; app.say("me"); });
  sayButtons.them.addEventListener("click", () => { exchangeRun++; app.say("them"); });
  sayButtons.exchange.addEventListener("click", async () => {
    const run = ++exchangeRun;
    const order = app.isOneWay ? ["me", "me"] : ["me", "them", "me"];
    for (const side of order) {
      if (run !== exchangeRun || !(await app.say(side))) return;
      await wait(650);
    }
  });

  const demoStage = $(".demo-stage");
  let demoHover = false;
  if (!reduce && !coarse) {
    demoStage.addEventListener("pointerenter", () => (demoHover = true));
    demoStage.addEventListener("pointerleave", () => (demoHover = false));
  }

  // ---------------------------------------------------------------- Pose targets from pointer + scroll
  function heroFrame() {
    if (reduce) return;
    const h = $(".hero").offsetHeight;
    const p = clamp(scrollY / h, 0, 1);
    heroPose.target.rx = 6 - pointer.y * 7 + p * 14;
    heroPose.target.ry = -20 + pointer.x * 14 - p * 16;
    heroPose.target.rz = 2 - p * 3;
    heroHost.style.transform = `translateY(${(p * 70).toFixed(1)}px)`;
    if (demoHover) {
      const r = demoStage.getBoundingClientRect();
      const lx = clamp(((pointer.x + 1) / 2 * innerWidth - r.left) / r.width * 2 - 1, -1, 1);
      demoPose.target.ry = -8 + lx * 6;
    } else demoPose.target.ry = -8;
    if (narrow()) { demoPose.target.ry = 0; demoPose.target.rx = 0; }
    requestAnimationFrame(heroFrame);
  }
  heroFrame();
  poseTick();

  // ---------------------------------------------------------------- Languages grid
  const grid = $("#lang-grid");
  NUA.LANGS.forEach((l) => {
    const li = document.createElement("li");
    li.className = "lang-card";
    li.innerHTML = `
      <div class="lc-top"><canvas class="lc-flag" width="60" height="42" aria-hidden="true"></canvas></div>
      <div class="lc-name">${l.name}<em>${l.code.toUpperCase()}</em></div>
      <div class="lc-native" lang="${l.code}">${l.native}</div>
`;
    const c = li.querySelector("canvas").getContext("2d");
    NUA.paintFlag(c, l.flag, 0, 0, 60, 42, 0, 0, 0);
    grid.appendChild(li);
  });

  // ---------------------------------------------------------------- Waveform illustration
  const waves = $$(".vc-wave");
  // One shared contour (three phrases with pauses); the reply keeps the same shape at a slightly different length.
  const contour = (x) => {
    const phrases = [[0.02, 0.3, 0.9], [0.36, 0.62, 0.6], [0.68, 0.97, 1]];
    for (const [a, b, h] of phrases) if (x >= a && x <= b) { const u = (x - a) / (b - a); return h * Math.sin(Math.PI * Math.pow(u, 0.8)); }
    return 0;
  };
  const rand = (i) => { const v = Math.sin(i * 12.9898) * 43758.5453; return v - Math.floor(v); };
  let waveHead = reduce ? 1 : 0, waveVisible = false;
  function drawWaves() {
    waves.forEach((cv) => {
      const w = cv.clientWidth, h = cv.clientHeight, dpr = Math.min(2, devicePixelRatio || 1);
      if (cv.width !== Math.round(w * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
      const g = cv.getContext("2d");
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, w, h);
      const out = cv.dataset.wave === "output";
      const bars = Math.max(30, Math.floor(w / 6));
      const grad = g.createLinearGradient(0, 0, w, h);
      grad.addColorStop(0, "#FF5A1E"); grad.addColorStop(0.62, "#F8324E"); grad.addColorStop(1, "#F0276A");
      for (let i = 0; i < bars; i++) {
        const x = i / bars;
        const src = out ? Math.min(1, x * 1.04 - 0.02) : x;
        const amp = contour(src) * (0.45 + 0.55 * rand(i + (out ? 97 : 0)));
        const bh = Math.max(2, amp * (h - 6));
        const played = x <= waveHead;
        g.globalAlpha = played ? 1 : 0.28;
        g.fillStyle = out ? grad : "#9C9CA5";
        const bx = i * (w / bars);
        g.beginPath();
        if (g.roundRect) g.roundRect(bx, (h - bh) / 2, Math.max(2, w / bars - 2.5), bh, 2);
        else g.rect(bx, (h - bh) / 2, Math.max(2, w / bars - 2.5), bh);
        g.fill();
      }
      g.globalAlpha = 1;
    });
  }
  if (window.IntersectionObserver) {
    new IntersectionObserver((e) => { waveVisible = e[0].isIntersecting; }, { threshold: 0.3 }).observe($(".voice-compare"));
  } else waveVisible = true;
  let lastWave = 0;
  function waveTick(ms) {
    if (!reduce && waveVisible) {
      waveHead = ((ms / 1000) % 5) / 4.2;
      if (ms - lastWave > 50) { drawWaves(); lastWave = ms; }
    }
    requestAnimationFrame(waveTick);
  }
  drawWaves();
  addEventListener("resize", drawWaves);
  requestAnimationFrame(waveTick);

  // ---------------------------------------------------------------- Closing orb (idle breathing, as on launch)
  const closing = $("#closing-orb");
  if (closing) {
    const dpr = Math.min(2, devicePixelRatio || 1);
    closing.width = 300 * dpr; closing.height = 300 * dpr;
    const g = closing.getContext("2d");
    const driver = new NUA.OrbDriver();
    let vis = false;
    if (window.IntersectionObserver) new IntersectionObserver((e) => (vis = e[0].isIntersecting)).observe(closing);
    const tick = (ms) => {
      if (vis || reduce) {
        g.setTransform(dpr, 0, 0, dpr, 0, 0);
        NUA.drawOrb(g, 300, 250, driver.step(ms / 1000, "idle", null, 0, 0, reduce));
      }
      if (!reduce) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    if (reduce) setTimeout(() => requestAnimationFrame(tick), 300);
  }

  // ---------------------------------------------------------------- Nav highlight
  const links = $$(".nav-links a");
  if (window.IntersectionObserver) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) links.forEach((a) => a.classList.toggle("on", a.getAttribute("href") === "#" + e.target.id));
      });
    }, { rootMargin: "-45% 0px -50% 0px" });
    ["how", "meaning", "demo", "languages", "faq"].forEach((id) => io.observe(document.getElementById(id)));
  }
})();
