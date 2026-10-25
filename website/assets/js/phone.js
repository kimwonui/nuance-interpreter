// 3D iPhone (CSS 3D, stacked layers for the rounded titanium edge) with NUA's hands-free screen inside.
// The screen mirrors ios/Interpreter/Views/OrbHomeView.swift (autoBody) and SplitConversation.swift:
// top half = the other person (rotated 180°), bottom half = you, orb in the middle, then
// History · Two-way/One-way (or Mute/Stop while running) · Settings.
// Everything here is an illustrative simulation: no microphone, no audio, no network.
(function () {
  const NUA = (window.NUA = window.NUA || {});
  const CANCEL = Symbol("cancel");

  const ICON = {
    clock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
    sliders: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/></svg>',
    micSlash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M9 9v3a3 3 0 0 0 5.1 2.1M15 10V6a3 3 0 0 0-5.7-1.3"/><path d="M19 11a7 7 0 0 1-1.2 3.9M5 11a7 7 0 0 0 11 5.7M12 18v3"/><path d="M3 3l18 18"/></svg>',
    mic: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="9" y="2.5" width="6" height="12" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/><path d="M12 17.5V21" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>',
    stop: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="5" y="5" width="14" height="14" rx="2.5"/></svg>',
    chevron: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>',
    swap: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4L3 8l4 4M3 8h14M17 12l4 4-4 4M21 16H7"/></svg>',
    check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/></svg>',
  };
  NUA.ICON = ICON;

  // Short illustrative lines (English/Korean only). Keyed by the language the line is spoken in.
  NUA.SAMPLES = {
    ko: [
      { ko: "혹시 이 근처에 조용한 카페 있어요?", en: "Is there a quiet café around here, by any chance?" },
      { ko: "와, 좋네요! 같이 가실래요?", en: "Oh, nice! Do you want to come with me?" },
      { ko: "천천히 말씀해 주셔서 고마워요.", en: "Thanks for speaking slowly for me." },
    ],
    en: [
      { en: "Yeah, there's a cozy one just around the corner.", ko: "네, 바로 모퉁이 돌면 아늑한 곳이 하나 있어요." },
      { en: "Sure, I'd love that!", ko: "좋아요, 저도 가고 싶어요!" },
      { en: "No worries — take your time.", ko: "괜찮아요, 천천히 하세요." },
    ],
  };

  const el = (tag, cls, html) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html !== undefined) n.innerHTML = html;
    return n;
  };

  /** Illustrative speech envelope (0…~0.1, the range the app's level taps produce). */
  function speechLevel(t, seed) {
    const syll = Math.pow(Math.max(0, Math.sin(t * 2 * Math.PI * 3.6 + seed)), 0.7);
    const phrase = 0.55 + 0.45 * Math.sin(t * 2 * Math.PI * 0.8 + seed * 2);
    const fade = Math.min(1, t / 0.25);
    return 0.01 + 0.09 * syll * phrase * fade;
  }

  // ---------------------------------------------------------------- device

  function buildDevice(opts) {
    const device = el("div", "device");
    const bodyEl = el("div", "device-body");
    device.appendChild(bodyEl);
    const n = opts.layers;
    for (let i = 0; i < n; i++) {
      const slab = el("div", "slab");
      const p = i / (n - 1); // 0 = back, 1 = front
      slab.style.setProperty("--p", p.toFixed(3));
      if (p > 0.25 && p < 0.75) slab.classList.add("with-buttons");
      bodyEl.appendChild(slab);
    }
    const back = el("div", "device-back", '<div class="camera"><i></i><i></i><i></i><b></b></div>');
    bodyEl.appendChild(back);
    const front = el("div", "device-front");
    const screen = el("div", "screen");
    screen.innerHTML =
      '<div class="statusbar"><span class="sb-time">9:41</span><span class="sb-icons">' +
      '<svg viewBox="0 0 18 12" fill="currentColor"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1"/></svg>' +
      '<svg viewBox="0 0 16 12" fill="currentColor"><path d="M8 2.2c2.4 0 4.6.9 6.2 2.5l1.3-1.3A10.6 10.6 0 0 0 8 .3 10.6 10.6 0 0 0 .5 3.4l1.3 1.3A8.8 8.8 0 0 1 8 2.2zm0 3.6c1.4 0 2.7.5 3.6 1.4l1.3-1.3A7 7 0 0 0 8 3.9a7 7 0 0 0-4.9 2l1.3 1.3c.9-.9 2.2-1.4 3.6-1.4zm0 3.5 2.1-2.1A3 3 0 0 0 8 6.5a3 3 0 0 0-2.1.7z"/></svg>' +
      '<span class="sb-battery"><i></i></span></span></div>' +
      '<div class="island"></div><div class="home-indicator"></div><div class="glare"></div>';
    front.appendChild(screen);
    bodyEl.appendChild(front);
    return { device, body: bodyEl, screen };
  }

  // ---------------------------------------------------------------- app screen

  class NuaApp {
    constructor(screenEl, opts) {
      this.interactive = !!opts.interactive;
      this.reduce = !!opts.reduce;
      this.s = { me: "ko", them: "en", direction: "two", auto: "off", speaker: null, listener: null, turn: null, holding: false, speakingLang: null };
      this.gen = 0;
      this.sampleIndex = { ko: 0, en: 0 };
      this.listeners = [];
      this.driver = new NUA.OrbDriver();
      this.halfT = { me: 0, them: 0 };
      this.talkStart = 0;
      this.speakStart = 0;
      this.seed = Math.random() * 10;
      this.build(screenEl);
      this.render();
    }

    on(fn) { this.listeners.push(fn); }
    emit(type, data) { this.listeners.forEach((fn) => fn(type, data, this)); }

    // ---- DOM

    build(screenEl) {
      const app = el("div", "app");
      app.innerHTML = `
        <section class="half half-them" data-side="them">
          <canvas class="half-bg"></canvas>
          <div class="half-content">
            <button class="chip" type="button" data-side="them"></button>
            <div class="half-title"></div>
            <div class="half-sub"></div>
          </div>
        </section>
        <div class="orb-block">
          <div class="orb-wrap">
            <canvas class="orb" width="260" height="260"></canvas>
            <span class="orb-mute" hidden>${ICON.micSlash}</span>
            <button class="orb-hit" type="button"></button>
          </div>
          <div class="status-title" aria-live="polite"></div>
          <div class="direction"></div>
        </div>
        <section class="half half-me" data-side="me">
          <canvas class="half-bg"></canvas>
          <div class="half-content">
            <button class="chip" type="button" data-side="me"></button>
            <div class="half-title"></div>
            <div class="half-sub"></div>
          </div>
        </section>
        <div class="bottom-row">
          <button class="circle" type="button" aria-label="History" tabindex="-1">${ICON.clock}</button>
          <div class="controls">
            <div class="idle-controls">
              <div class="segmented" role="radiogroup" aria-label="Direction">
                <button type="button" role="radio" data-dir="two">Two-way</button>
                <button type="button" role="radio" data-dir="one">One-way</button>
              </div>
              <div class="seg-hint"></div>
            </div>
            <div class="run-controls" hidden>
              <button class="pill-btn mute" type="button"><span class="ic"></span><span class="lbl">Mute</span></button>
              <button class="pill-btn stop" type="button">${ICON.stop}<span>Stop</span></button>
            </div>
          </div>
          <button class="circle" type="button" aria-label="Settings" tabindex="-1">${ICON.sliders}</button>
        </div>
        <div class="foot-note">Nothing is saved · Audio goes to OpenAI to interpret</div>
        <div class="pass" aria-hidden="true"></div>
        <div class="sheet-scrim" hidden></div>
        <div class="sheet" role="dialog" aria-modal="true" hidden>
          <div class="sheet-grabber"></div>
          <div class="sheet-bar"><button class="sheet-close" type="button">Close</button><div class="sheet-title"></div><span></span></div>
          <label class="sheet-search">${ICON.search}<input type="search" placeholder="Search name, native name, or code" autocomplete="off" spellcheck="false"></label>
          <div class="sheet-list"></div>
        </div>`;
      screenEl.appendChild(app);
      this.app = app;
      const q = (s) => app.querySelector(s);
      this.dom = {
        halves: { them: q(".half-them"), me: q(".half-me") },
        canvases: { them: q(".half-them canvas"), me: q(".half-me canvas") },
        orb: q("canvas.orb"),
        orbMute: q(".orb-mute"),
        orbHit: q(".orb-hit"),
        status: q(".status-title"),
        direction: q(".direction"),
        idle: q(".idle-controls"),
        run: q(".run-controls"),
        segs: app.querySelectorAll(".segmented button"),
        segHint: q(".seg-hint"),
        mute: q(".pill-btn.mute"),
        stop: q(".pill-btn.stop"),
        pass: q(".pass"),
        scrim: q(".sheet-scrim"),
        sheet: q(".sheet"),
        sheetTitle: q(".sheet-title"),
        search: q(".sheet input"),
        list: q(".sheet-list"),
      };
      this.ctx = {
        orb: this.dom.orb.getContext("2d"),
        them: this.dom.canvases.them.getContext("2d"),
        me: this.dom.canvases.me.getContext("2d"),
      };

      if (!this.interactive) {
        app.setAttribute("inert", "");
        return;
      }
      this.dom.orbHit.addEventListener("click", () => this.tapOrb());
      app.querySelectorAll(".chip").forEach((b) => b.addEventListener("click", () => this.openPicker(b.dataset.side)));
      this.dom.segs.forEach((b) => b.addEventListener("click", () => this.setDirection(b.dataset.dir)));
      this.dom.mute.addEventListener("click", () => this.toggleMute());
      this.dom.stop.addEventListener("click", () => this.stop());
      this.dom.direction.addEventListener("click", (e) => { if (e.target.closest(".swap")) this.swapLanguages(); });
      this.dom.scrim.addEventListener("click", () => this.closePicker());
      app.querySelector(".sheet-close").addEventListener("click", () => this.closePicker());
      this.dom.search.addEventListener("input", () => this.renderList());
      this.dom.sheet.addEventListener("keydown", (e) => { if (e.key === "Escape") this.closePicker(); });
    }

    // ---- derived state (ports of OrbHomeView.cue / orbMode / status and SideHalf.title / subtitle)

    lang(side) { return NUA.lang(side === "me" ? this.s.me : this.s.them); }
    get isOneWay() { return this.s.direction === "one"; }
    get running() { return this.s.auto !== "off"; }

    orbMode() {
      switch (this.s.auto) {
        case "connecting": case "interpreting": return "processing";
        case "waiting": case "hearing": return this.s.holding ? "holding" : "listening";
        case "speaking": return "speaking";
        case "muted": return "disabled";
        default: return "idle";
      }
    }

    statusTitle() {
      const s = this.s;
      switch (s.auto) {
        case "off": return "Tap to start";
        case "connecting": return "Connecting…";
        case "waiting": case "hearing": return s.holding ? "Waiting for you to finish" : "Listening";
        case "interpreting": return "Interpreting";
        case "speaking": return "Speaking " + NUA.lang(s.speakingLang).name;
        case "muted": return "Muted";
      }
      return "";
    }

    cue(side) {
      const s = this.s;
      switch (s.auto) {
        case "off": case "connecting": return "idle";
        case "muted": return "muted";
        case "speaking": return side === s.listener ? "listen" : "waitOther";
        default:
          if (s.speaker && (s.auto !== "waiting" || s.holding)) return side === s.speaker ? "talking" : "waitOther";
          if (s.turn) return side === s.turn ? "yourTurn" : "idle";
          return "idle";
      }
    }

    halfText(side) {
      const cue = this.cue(side);
      const lang = this.lang(side), other = this.lang(side === "me" ? "them" : "me");
      const oneWayListener = this.isOneWay && side === "them";
      const t = {
        idle: side === "me" ? `You speak ${lang.name}` : oneWayListener ? `They hear ${lang.name}` : `They speak ${lang.name}`,
        yourTurn: "Your turn", talking: `Speaking ${lang.name}…`, waitOther: "Wait for them to finish", listen: "Listen", muted: "Muted",
      }[cue];
      let sub;
      switch (cue) {
        case "idle":
          if (!this.running) sub = "Tap to change language";
          else sub = oneWayListener ? `One-way: only ${other.name} is interpreted` : "Speak when ready";
          break;
        case "yourTurn": sub = `Speak ${lang.name}`; break;
        case "talking": sub = "NUA will interpret when you pause"; break;
        case "waitOther": sub = `They are speaking ${other.name}`; break;
        case "listen": sub = `Translation in ${lang.name}`; break;
        case "muted": sub = "Mic off"; break;
      }
      return { title: t, sub };
    }

    // ---- render

    render() {
      const s = this.s, d = this.dom;
      ["them", "me"].forEach((side) => {
        const lang = this.lang(side);
        const half = d.halves[side];
        const { title, sub } = this.halfText(side);
        const chip = half.querySelector(".chip");
        chip.innerHTML = `<span class="chip-name">${lang.name}</span>` +
          (this.running ? "" : `<span class="chev">${ICON.chevron}</span>`);
        chip.disabled = this.running;
        chip.setAttribute("aria-label", `${side === "me" ? "Your" : "Their"} language: ${lang.name}. Search and change`);
        half.querySelector(".half-title").textContent = title;
        half.querySelector(".half-sub").textContent = sub;
        half.dataset.cue = this.cue(side);
      });
      const me = this.lang("me").name, them = this.lang("them").name;
      d.status.textContent = this.statusTitle();
      if (this.isOneWay) {
        d.direction.innerHTML = `<span>${me} → ${them}</span>` +
          (this.running ? "" : `<button class="swap" type="button" aria-label="Swap direction">${ICON.swap}</button>`);
      } else {
        d.direction.innerHTML = `<span>${me} ↔ ${them}</span>`;
      }
      d.idle.hidden = this.running;
      d.run.hidden = !this.running;
      d.segs.forEach((b) => {
        const on = b.dataset.dir === s.direction;
        b.classList.toggle("on", on);
        b.setAttribute("aria-checked", on ? "true" : "false");
      });
      d.segHint.textContent = this.isOneWay ? "Only your language is interpreted · Tap the orb to start" : "Both languages · Tap the orb to start";
      const muted = s.auto === "muted";
      d.mute.querySelector(".ic").innerHTML = muted ? ICON.mic : ICON.micSlash;
      d.mute.querySelector(".lbl").textContent = muted ? "Unmute" : "Mute";
      d.orbMute.hidden = !muted;
      d.orbHit.setAttribute("aria-label", this.running ? `${this.statusTitle()}` : "Start conversation");
      this.app.dataset.auto = s.auto;
      this.emit("state", s);
    }

    // ---- canvases

    sizeCanvases(dpr) {
      this.dpr = dpr;
      ["them", "me"].forEach((side) => {
        const c = this.dom.canvases[side];
        const w = c.clientWidth || 358, h = c.clientHeight || 200;
        c.width = Math.round(w * dpr);
        c.height = Math.round(h * dpr);
        c._w = w; c._h = h;
      });
      this.dom.orb.width = Math.round(260 * dpr);
      this.dom.orb.height = Math.round(260 * dpr);
    }

    frame(t) {
      const s = this.s, reduce = this.reduce;
      const input = s.auto === "hearing" ? speechLevel(t - this.talkStart, this.seed) : 0;
      const output = s.auto === "speaking" ? speechLevel(t - this.speakStart, this.seed + 3) : 0;
      const mode = this.orbMode();
      const f = this.driver.step(t, mode, s.auto === "speaking" ? NUA.lang(s.speakingLang) : null, input, output, reduce);
      const o = this.ctx.orb;
      o.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      NUA.drawOrb(o, 260, 190, f);

      ["them", "me"].forEach((side) => {
        const c = this.dom.canvases[side];
        if (!c._w) return;
        const g = this.ctx[side];
        const cue = this.cue(side);
        const paused = reduce || cue === "idle" || cue === "muted" || cue === "waitOther";
        if (!paused) this.halfT[side] = t;
        const ht = this.halfT[side];
        const level = cue === "talking" ? input : cue === "listen" ? output : 0;
        g.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
        drawHalf(g, c._w, c._h, this.lang(side), cue, level, ht, reduce);
      });
    }

    // ---- actions

    later(ms) {
      const g = this.gen;
      return new Promise((res, rej) => setTimeout(() => (g === this.gen ? res() : rej(CANCEL)), ms));
    }
    cancel() { this.gen++; }

    async tapOrb() {
      const s = this.s;
      if (s.auto === "off") return this.start();
      if (s.auto === "speaking") { // "Tap the orb to stop" NUA's voice; the conversation keeps going
        this.cancel();
        Object.assign(s, { auto: "waiting", speaker: null, holding: false, turn: s.listener, listener: null });
        this.render();
        this.emit("line-cut");
      }
    }

    async start() {
      if (this.running) return;
      this.closePicker();
      this.cancel();
      this.pressOrb();
      Object.assign(this.s, { auto: "connecting", speaker: null, listener: null, turn: null, holding: false });
      this.render();
      try {
        await this.later(900);
        this.s.auto = "waiting";
        this.render();
      } catch (e) { if (e !== CANCEL) throw e; }
    }

    stop() {
      this.cancel();
      Object.assign(this.s, { auto: "off", speaker: null, listener: null, turn: null, holding: false });
      this.render();
      this.emit("stopped");
    }

    toggleMute() {
      if (!this.running) return;
      this.cancel();
      const muted = this.s.auto === "muted";
      Object.assign(this.s, { auto: muted ? "waiting" : "muted", speaker: null, listener: null, holding: false });
      if (!muted) this.s.turn = null;
      this.render();
    }

    setDirection(dir) {
      if (this.running || this.s.direction === dir) return;
      this.s.direction = dir;
      this.render();
    }

    swapLanguages() {
      if (this.running) return;
      const s = this.s;
      [s.me, s.them] = [s.them, s.me];
      this.render();
    }

    setLanguage(code, side) {
      const s = this.s;
      const other = side === "me" ? "them" : "me";
      // Picking the other person's language swaps the two (LanguagePickerSheet footnote).
      if (s[other] === code) s[other] = s[side];
      s[side] = code;
      this.render();
    }

    /** True when the chosen pair has illustrative sample lines (English ↔ Korean). */
    hasSamples() {
      const pair = [this.s.me, this.s.them].sort().join("-");
      return pair === "en-ko";
    }

    canSay(side) {
      if (!this.running || this.s.auto === "connecting" || this.s.auto === "muted") return false;
      if (this.isOneWay && side === "them") return false; // one-way interprets only your language
      return true;
    }

    /** One illustrative turn: speak → (NUA holds its voice until the pause) → interpreting → NUA speaks. */
    async say(side) {
      if (!this.canSay(side)) return false;
      this.cancel();
      const s = this.s;
      const listener = side === "me" ? "them" : "me";
      const from = this.lang(side), to = this.lang(listener);
      let line = null;
      if (this.hasSamples()) {
        const list = NUA.SAMPLES[from.code];
        line = list[this.sampleIndex[from.code]++ % list.length];
      }
      const src = line ? line[from.code] : null, out = line ? line[to.code] : null;
      const talkMs = line ? Math.min(3400, Math.max(1900, 900 + src.length * 55)) : 2200;
      const speakMs = line ? Math.min(3600, Math.max(2000, 900 + out.length * 45)) : 2300;
      try {
        Object.assign(s, { auto: "hearing", speaker: side, listener: null, holding: false, turn: null });
        this.talkStart = performance.now() / 1000;
        this.render();
        this.emit("line", { phase: "talk", side, from, to, src, out });
        await this.later(talkMs * 0.62);
        s.holding = true; // GPT-Live started answering early: NUA waits for the speaker to finish
        this.render();
        await this.later(talkMs * 0.38);
        Object.assign(s, { auto: "interpreting", holding: false });
        this.render();
        this.flow(side);
        await this.later(650);
        Object.assign(s, { auto: "speaking", listener, speakingLang: to.code });
        this.speakStart = performance.now() / 1000;
        this.render();
        this.emit("line", { phase: "speak", side, from, to, src, out });
        await this.later(speakMs);
        Object.assign(s, { auto: "waiting", speaker: null, listener: null, turn: listener });
        this.render();
        this.emit("line", { phase: "done", side, from, to, src, out });
        return true;
      } catch (e) {
        if (e !== CANCEL) throw e;
        return false;
      }
    }

    /** Light passing from the speaker's half through the orb to the listener's half. */
    flow(fromSide) {
      if (this.reduce) return;
      const p = this.dom.pass;
      p.classList.remove("up", "down");
      void p.offsetWidth;
      p.classList.add(fromSide === "me" ? "up" : "down");
    }

    pressOrb() {
      const w = this.dom.orb.parentElement;
      w.classList.remove("pressed");
      void w.offsetWidth;
      w.classList.add("pressed");
    }

    // ---- language picker sheet

    openPicker(side) {
      if (this.running) return;
      this.pickerSide = side;
      this.lastFocus = document.activeElement;
      this.dom.sheetTitle.textContent = side === "me" ? "Your language" : "Their language";
      this.dom.sheet.setAttribute("aria-label", this.dom.sheetTitle.textContent);
      this.dom.search.value = "";
      this.renderList();
      this.dom.scrim.hidden = false;
      this.dom.sheet.hidden = false;
      requestAnimationFrame(() => { this.app.classList.add("sheet-open"); });
      setTimeout(() => this.dom.search.focus({ preventScroll: true }), 60);
      this.emit("picker", { open: true, side });
    }

    closePicker() {
      if (this.dom.sheet.hidden) return;
      this.app.classList.remove("sheet-open");
      setTimeout(() => { this.dom.sheet.hidden = true; this.dom.scrim.hidden = true; }, this.reduce ? 0 : 260);
      if (this.lastFocus && this.lastFocus.focus) this.lastFocus.focus({ preventScroll: true });
      this.emit("picker", { open: false });
    }

    renderList() {
      const side = this.pickerSide;
      const cur = side === "me" ? this.s.me : this.s.them;
      const other = side === "me" ? this.s.them : this.s.me;
      const q = this.dom.search.value;
      const results = NUA.LANGS.filter((l) => NUA.matchLang(l, q));
      const list = this.dom.list;
      list.innerHTML = "";
      if (!results.length) list.appendChild(el("p", "sheet-empty", "No matching language"));
      results.forEach((l) => {
        const b = el("button", "lang-row" + (l.code === cur ? " current" : ""));
        b.type = "button";
        b.innerHTML = `
          <span class="lr-main"><span class="lr-name">${l.name}<em>${l.code.toUpperCase()}</em></span>
          <span class="lr-native">${l.native}${l.liveOnly ? " · GPT-Live only" : ""}</span></span>
          ${l.code === other ? `<span class="lr-other">${side === "me" ? "Their language" : "Your language"}</span>` : ""}
          <span class="lr-check">${l.code === cur ? ICON.check : ""}</span>`;
        b.setAttribute("aria-label", `${l.name}, ${l.native}${l.liveOnly ? ", GPT-Live only" : ""}${l.code === cur ? ", selected" : ""}`);
        b.addEventListener("click", () => { this.setLanguage(l.code, side); this.closePicker(); });
        list.appendChild(b);
      });
      list.appendChild(el("p", "sheet-foot",
        "Search by name, native name, or code. Picking the other person's language swaps the two."));
    }
  }

  /** Port of FlagBackground: soft flag tint per half, breathing on your turn, following the level while talking,
   *  and a light band flowing away from the orb toward the listener while NUA speaks. */
  function drawHalf(g, w, h, lang, cue, level, t, reduce) {
    g.globalAlpha = 1;
    g.fillStyle = "#F5F5F7";
    g.fillRect(0, 0, w, h);
    let op;
    switch (cue) {
      case "yourTurn": op = reduce ? 0.16 : 0.12 + 0.06 * Math.sin((2 * Math.PI * t) / 3); break;
      case "talking": op = Math.min(0.32, 0.16 + level * 1.5); break;
      case "listen": op = 0.22; break;
      case "waitOther": op = 0.04; break;
      default: op = 0.06;
    }
    g.globalAlpha = op;
    NUA.paintFlag(g, lang.flag, 0, 0, w, h, reduce ? 0 : t * 1.2, reduce ? 0 : t * 0.4, cue === "listen" || cue === "talking" ? 3 : 0);
    g.globalAlpha = 1;
    if (cue === "listen" && !reduce) {
      const p = (t % 1.4) / 1.4;
      const y = h * p;
      const top = y - h * 0.18, bottom = y + h * 0.18;
      const grad = g.createLinearGradient(0, top, 0, bottom);
      grad.addColorStop(0, "rgba(255,255,255,0)");
      grad.addColorStop(0.5, "rgba(255,255,255,0.55)");
      grad.addColorStop(1, "rgba(255,255,255,0)");
      g.fillStyle = grad;
      g.fillRect(0, top, w, bottom - top);
    }
  }

  // ---------------------------------------------------------------- phone = device + app

  class Phone {
    constructor(host, opts) {
      this.opts = Object.assign({ interactive: false, layers: 16, reduce: false }, opts);
      const { device, body, screen } = buildDevice(this.opts);
      this.device = device;
      this.body = body;
      host.appendChild(device);
      this.app = new NuaApp(screen, this.opts);
      this.visible = false;
      this.dpr = Math.min(2, window.devicePixelRatio || 1) * (this.opts.lowPower ? 0.75 : 1);
      const resize = () => this.app.sizeCanvases(this.dpr);
      requestAnimationFrame(resize);
      if (window.ResizeObserver) new ResizeObserver(resize).observe(screen);
      if (window.IntersectionObserver) {
        new IntersectionObserver((entries) => { this.visible = entries[0].isIntersecting; }, { rootMargin: "120px" }).observe(host);
      } else this.visible = true;
      NUA.loop.add(this);
    }
    setPose(rx, ry, rz) {
      this.body.style.setProperty("--rx", rx.toFixed(2) + "deg");
      this.body.style.setProperty("--ry", ry.toFixed(2) + "deg");
      this.body.style.setProperty("--rz", (rz || 0).toFixed(2) + "deg");
      // Specular glare slides across the glass as the phone turns.
      this.body.style.setProperty("--gx", (50 + ry * 2.2).toFixed(1) + "%");
    }
  }

  /** One shared animation loop; only visible phones draw. */
  NUA.loop = {
    items: new Set(),
    fps: 60,
    last: 0,
    add(p) { this.items.add(p); if (!this.raf) this.raf = requestAnimationFrame((t) => this.tick(t)); },
    tick(ms) {
      this.raf = requestAnimationFrame((t) => this.tick(t));
      if (ms - this.last < 1000 / this.fps - 2) return;
      this.last = ms;
      const t = ms / 1000;
      this.items.forEach((p) => { if (p.visible && !document.hidden) p.app.frame(t); });
    },
  };

  NUA.Phone = Phone;
  NUA.CANCEL = CANCEL;
})();
