// Page controller: two phones (table story, interactive demo), scroll/pointer poses, the demo panel,
// the languages grid and the "same meaning, different feel" comparison. The hero film is in film.js.
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

  // ---------------------------------------------------------------- One phone, two voices (scroll story)
  const how = $("#how");
  const howStage = $(".how-stage");
  const tableHost = $("#table-phone");
  const table = new NUA.Phone(tableHost, phoneOpts);
  fit(table, tableHost.parentElement, 0.94, 0.66);
  const tablePose = posed(table, { rx: 50, ry: 0, rz: 0 });
  const steps = $$(".how-steps li");
  const howNext = $(".how-next");
  let step = -1, storyRun = 0;

  // Speech bubbles beside the two people: what was said, then what NUA says to the other person.
  const cards = { them: $(".fc-them"), me: $(".fc-you") };
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
  table.app.on((type, d) => {
    if (type === "line" && d.phase === "talk") {
      hideCards();
      showCard(d.side, `${d.side === "me" ? "You" : "Them"} · ${d.from.name}`, d.src);
    } else if (type === "line" && d.phase === "speak") {
      showCard(d.side === "me" ? "them" : "me", `NUA · ${d.to.name}`, d.out, true);
    } else if (type === "stopped") hideCards();
  });

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
    howNext.classList.toggle("ready", i === 3);
    const run = ++storyRun;
    if (i < 3) hideCards();
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
    howNext.classList.add("ready");
    const line = NUA.SAMPLES.ko[0];
    showCard("me", "You · Korean", line.ko);
    showCard("them", "NUA · English", line.en, true);
  } else {
    let narrowLoop = false;
    const onLayout = () => {
      if (narrow()) {
        Object.assign(tablePose.target, { rx: 48, ry: 0, rz: 0 });
        steps.forEach((li) => { li.classList.remove("seen"); li.classList.add("active"); });
        howNext.classList.add("ready");
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
  function poseFrame() {
    if (reduce) return;
    if (demoHover) {
      const r = demoStage.getBoundingClientRect();
      const lx = clamp(((pointer.x + 1) / 2 * innerWidth - r.left) / r.width * 2 - 1, -1, 1);
      demoPose.target.ry = -8 + lx * 6;
    } else demoPose.target.ry = -8;
    if (narrow()) { demoPose.target.ry = 0; demoPose.target.rx = 0; }
    requestAnimationFrame(poseFrame);
  }
  poseFrame();
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

  // ---------------------------------------------------------------- Same meaning, different feel (example text, no audio)
  const TONES = {
    formal: {
      ko: "제안해 주신 내용에 전적으로 동의합니다. 그대로 진행하시지요.",
      sounds: "Sounds polite, even, unhurried",
      nua: "I fully agree with your proposal. Please, proceed.",
      keeps: "Keeps it polite",
      // [start, end, height, spread]: phrases with pauses; spread = how much the loudness jumps around
      shape: [[0.02, 0.45, 0.52, 0.18], [0.52, 0.97, 0.48, 0.18]],
    },
    casual: {
      ko: "그 계획 완전 내 스타일이야, 걍 밀고 가자!",
      sounds: "Sounds excited, quick, loud",
      nua: "Yo, that plan's my style. Let's roll with it!",
      keeps: "Keeps it casual",
      shape: [[0.02, 0.2, 0.95, 0.6], [0.25, 0.52, 0.75, 0.6], [0.57, 0.97, 1, 0.55]],
    },
  };
  const PLAIN = "I agree with the plan. Let's go ahead.";
  const FLAT = [[0.03, 0.47, 0.42, 0.06], [0.53, 0.96, 0.42, 0.06]];
  const tc = $(".tone-compare");
  const toneButtons = $$(".tc-pick [data-tone]");
  const tcWaves = $$(".tc-wave", tc);
  const field = (k) => $(`[data-field="${k}"]`, tc);
  let tone = "formal", tcHead = reduce ? 1 : 0, tcVisible = false, mix = 1;

  const rand = (i) => { const v = Math.sin(i * 12.9898) * 43758.5453; return v - Math.floor(v); };
  function level(shape, x, i, seed) {
    for (const [a, b, h, spread] of shape) {
      if (x < a || x > b) continue;
      const u = (x - a) / (b - a);
      const env = Math.sin(Math.PI * Math.pow(u, 0.85));
      return h * env * (1 - spread + spread * rand(i * 1.7 + seed));
    }
    return 0;
  }
  function drawTone() {
    const t = TONES[tone];
    tcWaves.forEach((cv) => {
      const w = cv.clientWidth, h = cv.clientHeight, dpr = Math.min(2, devicePixelRatio || 1);
      if (!w) return;
      if (cv.width !== Math.round(w * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
      const g = cv.getContext("2d");
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, w, h);
      const kind = cv.dataset.wave;
      const shape = kind === "plain" ? FLAT : t.shape;
      const bars = Math.max(28, Math.floor(w / 6));
      let fill = "#9C9CA5";
      if (kind === "nua") {
        fill = g.createLinearGradient(0, 0, w, 0);
        fill.addColorStop(0, "#FF5A1E"); fill.addColorStop(0.62, "#F8324E"); fill.addColorStop(1, "#F0276A");
      } else if (kind === "source") fill = "#26262B";
      g.fillStyle = fill;
      for (let i = 0; i < bars; i++) {
        const x = i / bars;
        const amp = level(shape, x, i, kind === "nua" ? 0 : kind === "source" ? 0 : 31) * (kind === "plain" ? 1 : mix);
        const bh = Math.max(2, amp * (h - 4));
        g.globalAlpha = x <= tcHead ? 1 : 0.22;
        const bx = i * (w / bars), bw = Math.max(2, w / bars - 2.5);
        g.beginPath();
        if (g.roundRect) g.roundRect(bx, (h - bh) / 2, bw, bh, 2); else g.rect(bx, (h - bh) / 2, bw, bh);
        g.fill();
      }
      g.globalAlpha = 1;
    });
  }
  function setTone(next, focus) {
    tone = next;
    const t = TONES[tone];
    toneButtons.forEach((b) => {
      const on = b.dataset.tone === tone;
      b.setAttribute("aria-checked", on);
      b.tabIndex = on ? 0 : -1;
      if (on && focus) b.focus();
    });
    tc.dataset.current = tone;
    field("ko").textContent = t.ko;
    field("sounds").textContent = t.sounds;
    field("plain").textContent = PLAIN;
    field("nua").textContent = t.nua;
    field("keeps").textContent = t.keeps;
    tcHead = reduce ? 1 : 0;
    tcStart = 0;
    mix = reduce ? 1 : 0.2;
    drawTone();
  }
  toneButtons.forEach((b, k) => {
    b.addEventListener("click", () => setTone(b.dataset.tone));
    b.addEventListener("keydown", (e) => {
      const d = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0;
      if (!d) return;
      e.preventDefault();
      setTone(toneButtons[(k + d + toneButtons.length) % toneButtons.length].dataset.tone, true);
    });
  });
  if (window.IntersectionObserver) {
    new IntersectionObserver((e) => { tcVisible = e[0].isIntersecting; }, { threshold: 0.25 }).observe($(".tc-card"));
  } else tcVisible = true;
  let lastTc = 0, tcStart = 0;
  function tcTick(ms) {
    if (!reduce && tcVisible) {
      if (!tcStart || tcHead >= 1.25) tcStart = ms; // sweep, rest a moment, sweep again
      tcHead = (ms - tcStart) / 3200;
      mix = Math.min(1, mix + 0.06);
      if (ms - lastTc > 50) { drawTone(); lastTc = ms; }
    }
    requestAnimationFrame(tcTick);
  }
  setTone("formal");
  addEventListener("resize", drawTone);
  requestAnimationFrame(tcTick);

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
    ["meaning", "how", "demo", "languages", "faq"].forEach((id) => io.observe(document.getElementById(id)));
  }
})();
