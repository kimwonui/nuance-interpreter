// Languages and decorative flag styles, mirrored from ios/Interpreter/App/Models.swift.
// Flags are a visual cue for the language only (not a nationality), exactly as in the app.
(function () {
  const NUA = (window.NUA = window.NUA || {});

  const stripes = (vertical, bands, emblem) => ({ kind: "stripes", vertical, bands, emblem });

  NUA.LANGS = [
    { code: "en", name: "English", native: "English", flag: { kind: "usa" } },
    { code: "ko", name: "Korean", native: "한국어", flag: { kind: "korea" } },
    { code: "ja", name: "Japanese", native: "日本語", flag: stripes(false, [[0xffffff, 1]], { kind: "disc", hex: 0xbc002d, ratio: 0.3 }) },
    { code: "zh", name: "Chinese", native: "中文", flag: stripes(false, [[0xde2910, 1]], { kind: "star", hex: 0xffde00 }) },
    { code: "es", name: "Spanish", native: "Español", flag: stripes(false, [[0xaa151b, 1], [0xf1bf00, 2], [0xaa151b, 1]]) },
    { code: "fr", name: "French", native: "Français", flag: stripes(true, [[0x002395, 1], [0xffffff, 1], [0xed2939, 1]]) },
    { code: "de", name: "German", native: "Deutsch", flag: stripes(false, [[0x000000, 1], [0xdd0000, 1], [0xffce00, 1]]) },
    { code: "it", name: "Italian", native: "Italiano", flag: stripes(true, [[0x009246, 1], [0xffffff, 1], [0xce2b37, 1]]) },
    { code: "pt", name: "Portuguese", native: "Português", flag: stripes(true, [[0x006600, 2], [0xff0000, 3]]) },
    { code: "ru", name: "Russian", native: "Русский", flag: stripes(false, [[0xffffff, 1], [0x0039a6, 1], [0xd52b1e, 1]]) },
    { code: "hi", name: "Hindi", native: "हिन्दी", flag: stripes(false, [[0xff9933, 1], [0xffffff, 1], [0x138808, 1]], { kind: "ring", hex: 0x000080, ratio: 0.16 }) },
    { code: "id", name: "Indonesian", native: "Bahasa Indonesia", flag: stripes(false, [[0xff0000, 1], [0xffffff, 1]]) },
    { code: "vi", name: "Vietnamese", native: "Tiếng Việt", flag: stripes(false, [[0xda251d, 1]], { kind: "star", hex: 0xffff00 }) },
    // Spoken across many countries: a plain pan-Arab green with a white disc, not one country's flag.
    { code: "ar", name: "Arabic", native: "العربية", liveOnly: true, flag: stripes(false, [[0x007a3d, 1]], { kind: "disc", hex: 0xffffff, ratio: 0.18 }) },
  ];

  NUA.lang = (code) => NUA.LANGS.find((l) => l.code === code);

  /** Search by English name, native name, or code (case- and accent-insensitive), like Lang.matches. */
  NUA.matchLang = (lang, query) => {
    const fold = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
    const q = fold(query.trim());
    if (!q) return true;
    return fold(lang.name).includes(q) || fold(lang.native).includes(q) || lang.code.includes(q);
  };

  const hex = (h) => "#" + h.toString(16).padStart(6, "0");

  /** Port of FlagPainter.paint: `phase` drives the waving motion, `angle` the turning motion. */
  NUA.paintFlag = function (ctx, art, x, y, w, h, phase, angle, wave) {
    if (wave === undefined) wave = 4;
    if (art.kind === "usa") return usa(ctx, x, y, w, h, phase, wave);
    if (art.kind === "korea") return korea(ctx, x, y, w, h, angle);
    return stripesPaint(ctx, art, x, y, w, h, phase, angle, wave);
  };

  function usa(ctx, x, y, w, h0, phase, wave) {
    const h = h0 / 7;
    for (let i = 0; i < 7; i++) {
      const dy = wave * Math.sin(phase + i * 0.7);
      ctx.fillStyle = i % 2 === 0 ? "#B22234" : "#FFFFFF";
      ctx.fillRect(x, y + i * h + dy, w, h + 1);
    }
    const cx = x, cy = y + wave * Math.sin(phase), cw = w * 0.45, ch = h * 4;
    ctx.fillStyle = "#3C3B6E";
    ctx.fillRect(cx, cy, cw, ch);
    const dot = Math.max(3, w * 0.018);
    ctx.fillStyle = "#FFFFFF";
    for (let row = 0; row < 3; row++) {
      for (let col = 0; col < 4; col++) {
        ctx.beginPath();
        ctx.arc(cx + cw * (0.18 + 0.21 * col), cy + ch * (0.25 + 0.25 * row), dot, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }

  function korea(ctx, x, y, w, h, angle) {
    ctx.fillStyle = "#FFFFFF";
    ctx.fillRect(x, y, w, h);
    const c = { x: x + w / 2, y: y + h / 2 };
    const s = Math.min(w, h);
    const r = s * 0.22;
    ctx.save();
    ctx.translate(c.x, c.y);
    ctx.rotate(angle);
    ctx.fillStyle = "#0047A0";
    ctx.beginPath(); ctx.arc(0, 0, r, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = "#CD2E3A";
    ctx.beginPath(); ctx.arc(0, 0, r, Math.PI, Math.PI * 2, false); ctx.closePath(); ctx.fill();
    ctx.beginPath(); ctx.arc(-r / 2, 0, r / 2, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = "#0047A0";
    ctx.beginPath(); ctx.arc(r / 2, 0, r / 2, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
    const bar = s * 0.1;
    ctx.fillStyle = "#1F1F1F";
    for (let k = 0; k < 4; k++) {
      ctx.save();
      ctx.translate(c.x, c.y);
      ctx.rotate(((45 + k * 90) * Math.PI) / 180);
      for (let j = 0; j < 3; j++) roundRect(ctx, r * 1.45 + j * bar * 0.32, -bar / 2, bar * 0.18, bar, 1);
      ctx.restore();
    }
  }

  function stripesPaint(ctx, art, x, y, w, h, phase, angle, wave) {
    const total = art.bands.reduce((a, b) => a + b[1], 0);
    let offset = 0;
    art.bands.forEach((band, i) => {
      const share = band[1] / total;
      const shift = wave * Math.sin(phase + i * 0.9);
      ctx.fillStyle = hex(band[0]);
      if (art.vertical) ctx.fillRect(x + w * offset + shift, y, w * share + 1, h);
      else ctx.fillRect(x, y + h * offset + shift, w, h * share + 1);
      offset += share;
    });
    const e = art.emblem;
    if (!e) return;
    const c = { x: x + w / 2, y: y + h / 2 };
    const s = Math.min(w, h);
    ctx.fillStyle = hex(e.hex);
    ctx.strokeStyle = hex(e.hex);
    if (e.kind === "disc") {
      ctx.beginPath(); ctx.arc(c.x, c.y, s * e.ratio, 0, Math.PI * 2); ctx.fill();
    } else if (e.kind === "star") {
      starPath(ctx, c.x, c.y, s * 0.2, angle * 0.2); ctx.fill();
    } else if (e.kind === "ring") {
      const r = s * e.ratio;
      ctx.lineWidth = Math.max(1.5, r * 0.15);
      ctx.beginPath(); ctx.arc(c.x, c.y, r, 0, Math.PI * 2); ctx.stroke();
      ctx.save();
      ctx.translate(c.x, c.y);
      ctx.rotate(angle * 0.3);
      ctx.lineWidth = Math.max(0.8, r * 0.05);
      ctx.beginPath();
      for (let k = 0; k < 12; k++) {
        const a = (k * Math.PI) / 6;
        ctx.moveTo(0, 0);
        ctx.lineTo(r * Math.cos(a), r * Math.sin(a));
      }
      ctx.stroke();
      ctx.restore();
    }
  }

  function starPath(ctx, cx, cy, R, rotation) {
    ctx.beginPath();
    for (let i = 0; i < 10; i++) {
      const r = i % 2 === 0 ? R : R * 0.4;
      const a = -Math.PI / 2 + (i * Math.PI) / 5 + rotation;
      const px = cx + r * Math.cos(a), py = cy + r * Math.sin(a);
      if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
    }
    ctx.closePath();
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
    ctx.fill();
  }
})();
