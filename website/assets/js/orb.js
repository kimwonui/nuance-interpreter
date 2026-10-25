// Center orb, ported from ios/Interpreter/Views/OrbView.swift (drawing + OrbDriver easing).
// Modes: idle, listening, holding, processing, speaking (with output language), disabled.
// The site drives the levels with an illustrative speech envelope; it never touches a microphone.
(function () {
  const NUA = (window.NUA = window.NUA || {});
  const STOPS = ["#FF5A1E", "#F8324E", "#F0276A"];
  const ACCENT = [251, 60, 57];
  const rgba = (c, a) => `rgba(${c[0]},${c[1]},${c[2]},${Math.max(0, Math.min(1, a))})`;

  class OrbDriver {
    constructor() {
      this.last = null;
      this.cur = { scale: 1, amp: 0, glow: 0.22, bodyOpacity: 0.92, rings: 0, angular: 0, dots: 0, grey: 0, rippleAlpha: 0, hold: 0, flag: 0, flagLang: null };
      this.v = 0;
      this.rotation = 0; this.wobble = 0; this.holdAngle = 0; this.flagPhase = 0; this.flagAngle = -0.5;
      this.rippleStarts = []; this.lastRipple = 0;
    }

    step(t, mode, lang, input, output, reduce) {
      const dt = Math.min(0.05, Math.max(0, t - (this.last ?? t)));
      this.last = t;
      const speaking = mode === "speaking";
      // Level smoothing: rise 60 ms, fall 250 ms
      const raw = mode === "listening" ? input : speaking ? output : 0;
      const target = Math.min(1, Math.max(0, raw * 9));
      this.v += (target - this.v) * Math.min(1, dt / (target > this.v ? 0.06 : 0.25));
      const v = this.v;

      const g = { scale: 1, amp: 0, glow: 0.22, bodyOpacity: 0.92, rings: 0, angular: 0, dots: 0, grey: 0, rippleAlpha: 0, hold: 0, flag: 0 };
      switch (mode) {
        case "idle":
          g.scale = reduce ? 1 : 1.02 + 0.02 * Math.sin((2 * Math.PI * t) / 4);
          break;
        case "listening":
          g.scale = reduce ? 1 + 0.06 * v : 1.08 + 0.18 * v;
          g.amp = reduce ? 0 : 0.02 + 0.08 * v;
          g.glow = 0.5; g.bodyOpacity = 1;
          g.rings = reduce ? 0 : 0.1 + 0.3 * v;
          break;
        case "holding":
          g.glow = 0.3; g.bodyOpacity = 1; g.hold = 1;
          break;
        case "processing":
          g.scale = reduce ? 1.02 : 1.02 + 0.015 * Math.sin((2 * Math.PI * t) / 1.2);
          g.amp = reduce ? 0 : 0.025;
          g.glow = 0.32; g.bodyOpacity = 1; g.angular = 1; g.dots = reduce ? 0 : 1;
          break;
        case "speaking":
          g.scale = reduce ? 1 + 0.06 * v : 1.05 + 0.15 * v;
          g.amp = reduce ? 0 : lang ? 0.01 + 0.03 * v : 0.015 + 0.06 * v;
          g.glow = 0.45; g.bodyOpacity = 1; g.rippleAlpha = 1;
          g.flag = lang ? 1 : 0;
          if (lang) this.cur.flagLang = lang;
          break;
        case "disabled":
          g.scale = 0.96; g.glow = 0; g.bodyOpacity = 1; g.grey = 1;
          break;
      }
      const k = Math.min(1, dt / 0.25);
      for (const key of Object.keys(g)) this.cur[key] += (g[key] - this.cur[key]) * k;

      if (!reduce) {
        if (mode === "processing") this.rotation += (dt * 2 * Math.PI) / 2.4;
        if (mode !== "disabled" && mode !== "holding") this.wobble += dt * 1.6;
        if (mode === "holding") this.holdAngle += (dt * 2 * Math.PI) / 3;
        if (speaking && lang) {
          if (lang.flag.kind === "korea") this.flagAngle += (dt * 2 * Math.PI) / 6;
          else { this.flagPhase += (dt * 2 * Math.PI) / 1.2; this.flagAngle += (dt * 2 * Math.PI) / 8; }
        }
        if (speaking && v > 0.05 && t - this.lastRipple > 0.6) { this.rippleStarts.push(t); this.lastRipple = t; }
      }
      this.rippleStarts = this.rippleStarts.filter((s) => t - s <= 1.4);
      return Object.assign({}, this.cur, {
        rotation: this.rotation, wobblePhase: this.wobble, holdAngle: this.holdAngle,
        flagPhase: this.flagPhase, flagAngle: this.flagAngle,
        ripples: this.rippleStarts.map((s) => (t - s) / 1.4),
      });
    }
  }

  function blob(ctx, cx, cy, R, amp, w) {
    ctx.beginPath();
    const n = 120;
    for (let i = 0; i <= n; i++) {
      const th = (i / n) * 2 * Math.PI;
      const wob = 0.5 * Math.sin(3 * th + w) + 0.3 * Math.sin(5 * th - 1.3 * w + 1.7) + 0.2 * Math.sin(7 * th + 0.7 * w + 2.3);
      const r = R * (1 + amp * wob);
      const x = cx + r * Math.cos(th), y = cy + r * Math.sin(th);
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.closePath();
  }

  function linear(ctx, cx, cy, R) {
    const g = ctx.createLinearGradient(cx - R, cy - R, cx + R, cy + R);
    g.addColorStop(0, STOPS[0]); g.addColorStop(0.62, STOPS[1]); g.addColorStop(1, STOPS[2]);
    return g;
  }

  /** Draws one frame. `size` is the canvas box in CSS px, `diameter` the app's orb diameter (190 in the split screen). */
  function draw(ctx, size, diameter, f) {
    const c = { x: size / 2, y: size / 2 };
    const R = 95 * f.scale * (diameter / 320);
    const color = 1 - f.grey;
    ctx.clearRect(0, 0, size, size);

    // Glow: the app blurs a gradient disc; a radial gradient is the cheap, portable equivalent.
    if (f.glow * color > 0.01) {
      const gr = ctx.createRadialGradient(c.x, c.y + 12, R * 0.4, c.x, c.y + 12, R * 1.75);
      gr.addColorStop(0, `rgba(248,50,78,${0.75 * f.glow * color})`);
      gr.addColorStop(0.55, `rgba(248,50,78,${0.28 * f.glow * color})`);
      gr.addColorStop(1, "rgba(248,50,78,0)");
      ctx.fillStyle = gr;
      ctx.fillRect(0, 0, size, size);
    }
    // Listening rings (mic level)
    if (f.rings > 0.01) {
      ctx.lineWidth = 2;
      [[1.16, 0.22], [1.3, 0.1]].forEach(([k, op]) => {
        ctx.strokeStyle = rgba(ACCENT, op * f.rings * 2.2);
        ctx.beginPath(); ctx.arc(c.x, c.y, R * k, 0, Math.PI * 2); ctx.stroke();
      });
    }
    // Holding: dashed ring orbiting slowly (waiting for the pause)
    if (f.hold > 0.01) {
      ctx.save();
      ctx.strokeStyle = rgba(ACCENT, 0.45 * f.hold);
      ctx.lineWidth = 2.5; ctx.lineCap = "round"; ctx.setLineDash([6, 10]);
      ctx.beginPath(); ctx.arc(c.x, c.y, R * 1.2, f.holdAngle, f.holdAngle + Math.PI * 2); ctx.stroke();
      ctx.restore();
    }
    // Output ripples (playback level)
    ctx.lineWidth = 2;
    for (const p of f.ripples) {
      ctx.strokeStyle = rgba(ACCENT, 0.35 * (1 - p) * f.rippleAlpha);
      ctx.beginPath(); ctx.arc(c.x, c.y, R * (1 + 0.5 * p), 0, Math.PI * 2); ctx.stroke();
    }

    if (f.grey > 0.99) {
      blob(ctx, c.x, c.y, R, f.amp, f.wobblePhase);
      ctx.fillStyle = "#E7E7EC"; ctx.fill();
      return;
    }
    // Base gradient body
    const base = Math.max(0, 1 - f.flag);
    if (base > 0.01) {
      ctx.save();
      ctx.globalAlpha = f.bodyOpacity * base;
      blob(ctx, c.x, c.y, R, f.amp, f.wobblePhase);
      ctx.fillStyle = linear(ctx, c.x, c.y, R);
      ctx.fill();
      if (f.angular > 0.01 && ctx.createConicGradient) {
        const cg = ctx.createConicGradient(f.rotation, c.x, c.y);
        cg.addColorStop(0, STOPS[0]); cg.addColorStop(0.33, STOPS[1]); cg.addColorStop(0.66, STOPS[2]); cg.addColorStop(1, STOPS[0]);
        ctx.globalAlpha = f.bodyOpacity * base * f.angular;
        ctx.fillStyle = cg;
        ctx.fill();
      }
      ctx.restore();
    }
    // Disabled fades the colour out toward grey
    if (f.grey > 0.01) {
      ctx.save();
      ctx.globalAlpha = f.grey;
      blob(ctx, c.x, c.y, R, f.amp, f.wobblePhase);
      ctx.fillStyle = "#E7E7EC"; ctx.fill();
      ctx.restore();
    }
    // Output-language flag style (decorative cue; the status text names the language)
    if (f.flag > 0.01 && f.flagLang) {
      ctx.save();
      ctx.globalAlpha = f.flag;
      blob(ctx, c.x, c.y, R, f.amp, f.wobblePhase);
      ctx.clip();
      const b = R * 1.15;
      NUA.paintFlag(ctx, f.flagLang.flag, c.x - b, c.y - b, b * 2, b * 2, f.flagPhase, f.flagAngle, 4 * (diameter / 320));
      ctx.restore();
      if (f.flagLang.flag.kind === "korea") {
        ctx.save();
        ctx.globalAlpha = f.flag;
        blob(ctx, c.x, c.y, R, f.amp, f.wobblePhase);
        ctx.strokeStyle = "#E7E7EC"; ctx.lineWidth = 1.5; ctx.stroke();
        ctx.restore();
      }
    }
    // Highlight
    const hx = c.x - R * 0.2, hy = c.y - R * 0.3;
    const hl = ctx.createRadialGradient(hx, hy, 0, hx, hy, R * 0.85);
    hl.addColorStop(0, `rgba(255,255,255,${0.34 * color})`);
    hl.addColorStop(1, "rgba(255,255,255,0)");
    ctx.fillStyle = hl;
    ctx.beginPath(); ctx.arc(hx, hy, R * 0.85, 0, Math.PI * 2); ctx.fill();
    // Processing orbit dots
    if (f.dots > 0.01) {
      ctx.fillStyle = rgba(ACCENT, 0.6 * f.dots);
      for (let k = 0; k < 3; k++) {
        const a = f.rotation * (2.4 / 1.8) + k * 2.1;
        ctx.beginPath(); ctx.arc(c.x + R * 1.18 * Math.cos(a), c.y + R * 1.18 * Math.sin(a), 6, 0, Math.PI * 2); ctx.fill();
      }
    }
  }

  NUA.OrbDriver = OrbDriver;
  NUA.drawOrb = draw;
})();
