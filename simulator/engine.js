/*
 * Busy Bar engine — decides the colour of every LED for a given moment.
 *
 * Pure and deterministic: no DOM, no Date.now(), no Math.random(). Given the
 * same inputs it produces the same framebuffer, which is what lets the Swift
 * port be checked against this file line for line.
 *
 * Coordinates are LED cells. Colours are linear-ish RGB in 0..1 (the values
 * the firmware would send to the LEDs, divided by 255).
 */
(function (root) {
  'use strict';

  const COLS = 118;
  const ROWS = 16;

  /* ------------------------------------------------------------------ *
   * Palette — sampled from the BUSY Bar firmware's own animation frames *
   * ------------------------------------------------------------------ */
  const hex = (h) => [((h >> 16) & 255) / 255, ((h >> 8) & 255) / 255, (h & 255) / 255];

  const PALETTE = {
    call: {
      highlight: hex(0xFF808E),   // top row of the pill
      top:       hex(0xFF001D),   // rows 1-3
      bottom:    hex(0x6E0002),   // row 14
      rimBottom: hex(0x7C191B),   // row 15
      edge:      hex(0xD14C58),   // 1-LED rim on the left/right ends
      outline:   hex(0xE35A68),   // compact pill outline
      shadow:    hex(0x4A0006),   // text drop shadow on the lit pill
      darkTop:   hex(0x382E2E),   // dark pill / particle field
      darkBot:   hex(0x211C1C),
      spark:     hex(0xFD929A),   // brightest particle
      sparkDim:  hex(0xC7767C),
      flood:     hex(0xBC2525)    // the colour the shockwave floods to
    },
    free: {
      highlight: hex(0x8FFFC4),
      top:       hex(0x17EB79),
      bottom:    hex(0x03603F),
      rimBottom: hex(0x0D7B55),
      edge:      hex(0x5CD69A),
      outline:   hex(0x4FD08E),
      shadow:    hex(0x013A24),
      darkTop:   hex(0x30392F),
      darkBot:   hex(0x1C211D),
      spark:     hex(0x96F7C7),
      sparkDim:  hex(0x6AA889),
      flood:     hex(0x2A9E63)
    },
    white: [1, 1, 1],
    clockDim: hex(0x3A3A3A)
  };

  /* ------------------------------------------------------------------ *
   * Small maths helpers                                                *
   * ------------------------------------------------------------------ */
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  const lerp = (a, b, t) => a + (b - a) * t;
  const mix = (c1, c2, t) => [lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t)];
  const scale = (c, k) => [c[0] * k, c[1] * k, c[2] * k];
  const smooth = (e0, e1, x) => { const t = clamp((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t); };
  const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const easeOut = (t) => 1 - Math.pow(1 - t, 3);

  /* Deterministic hash → 0..1. Same integer in, same number out, in any language. */
  function hash(n) {
    let x = (n | 0) >>> 0;
    x = Math.imul(x ^ (x >>> 16), 0x45d9f3b) >>> 0;
    x = Math.imul(x ^ (x >>> 16), 0x45d9f3b) >>> 0;
    x = (x ^ (x >>> 16)) >>> 0;
    return x / 4294967295;
  }

  /* ------------------------------------------------------------------ *
   * Framebuffer                                                        *
   * ------------------------------------------------------------------ */
  function Frame() { this.px = new Float32Array(COLS * ROWS * 3); }
  Frame.prototype.get = function (x, y) {
    const i = (y * COLS + x) * 3; return [this.px[i], this.px[i + 1], this.px[i + 2]];
  };
  Frame.prototype.set = function (x, y, c) {
    if (x < 0 || y < 0 || x >= COLS || y >= ROWS) return;
    const i = (y * COLS + x) * 3; this.px[i] = c[0]; this.px[i + 1] = c[1]; this.px[i + 2] = c[2];
  };
  /* Alpha-blend c over the existing LED. */
  Frame.prototype.blend = function (x, y, c, a) {
    if (a <= 0 || x < 0 || y < 0 || x >= COLS || y >= ROWS) return;
    if (a > 1) a = 1;
    const i = (y * COLS + x) * 3, p = this.px;
    p[i] += (c[0] - p[i]) * a; p[i + 1] += (c[1] - p[i + 1]) * a; p[i + 2] += (c[2] - p[i + 2]) * a;
  };
  /* Add light — how the firmware's transition overlays combine with the screen. */
  Frame.prototype.add = function (x, y, c, k) {
    if (k <= 0 || x < 0 || y < 0 || x >= COLS || y >= ROWS) return;
    const i = (y * COLS + x) * 3, p = this.px;
    p[i] = Math.min(1, p[i] + c[0] * k); p[i + 1] = Math.min(1, p[i + 1] + c[1] * k); p[i + 2] = Math.min(1, p[i + 2] + c[2] * k);
  };
  Frame.prototype.multiply = function (x, y, k) {
    if (x < 0 || y < 0 || x >= COLS || y >= ROWS) return;
    const i = (y * COLS + x) * 3, p = this.px; p[i] *= k; p[i + 1] *= k; p[i + 2] *= k;
  };

  /* ------------------------------------------------------------------ *
   * Pills — the rounded, gradient-filled bars the whole UI is built on *
   * ------------------------------------------------------------------ */

  /* Signed distance from a cell centre to a rounded rectangle. Negative inside. */
  function roundRectSDF(px, py, x0, y0, w, h, r) {
    const cx = x0 + w / 2, cy = y0 + h / 2;
    const qx = Math.abs(px - cx) - (w / 2 - r);
    const qy = Math.abs(py - cy) - (h / 2 - r);
    const ox = Math.max(qx, 0), oy = Math.max(qy, 0);
    return Math.hypot(ox, oy) + Math.min(Math.max(qx, qy), 0) - r;
  }

  /*
   * A lit pill: highlight top row, bright band, linear fall to a deep base,
   * lighter bottom rim, and a pale 1-LED edge — exactly the BUSY pill's
   * vertical profile, stretched to any width.
   *
   * `fillTo` lets the collapse animation drain the colour: columns right of
   * it render as the dark pill instead.
   */
  function drawPill(f, x0, w, pal, opts) {
    const o = opts || {};
    const y0 = 0, h = ROWS, r = 2.6;
    const fillTo = o.fillTo === undefined ? x0 + w : o.fillTo;
    const sheen = o.sheen;           // { pos, width, strength } or undefined
    for (let y = 0; y < ROWS; y++) {
      for (let x = Math.floor(x0) - 1; x <= Math.ceil(x0 + w) + 1; x++) {
        const d = roundRectSDF(x + 0.5, y + 0.5, x0, y0, w, h, r);
        const cover = clamp(0.5 - d, 0, 1);
        if (cover <= 0) continue;

        const lit = x + 0.5 < fillTo;
        let c;
        if (lit) {
          if (y === 0) c = pal.highlight;
          else if (y <= 3) c = pal.top;
          else if (y === ROWS - 1) c = pal.rimBottom;
          else c = mix(pal.top, pal.bottom, (y - 3) / (ROWS - 2 - 3));
          // pale rim on the rounded ends
          const edge = clamp(1 - Math.abs(d + 0.9), 0, 1);
          if (edge > 0 && y > 0 && y < ROWS - 1) c = mix(c, pal.edge, edge * 0.85);
          if (sheen) {
            // a soft diagonal band of light drifting across the pill
            const u = (x + 0.5 - sheen.pos) + (y - ROWS / 2) * 0.55;
            const s = Math.exp(-(u * u) / (2 * sheen.width * sheen.width)) * sheen.strength;
            c = mix(c, pal.highlight, s);
          }
        } else {
          c = mix(pal.darkTop, pal.darkBot, clamp((y - 1) / 7, 0, 1));
          if (y === ROWS - 1) c = mix(pal.darkBot, [0.3, 0.29, 0.29], 0.35);
          const edge = clamp(1 - Math.abs(d + 0.9), 0, 1);
          if (edge > 0) c = mix(c, pal.outline, edge * (o.outline === undefined ? 0.8 : o.outline));
        }
        f.blend(x, y, c, cover);
      }
    }
  }

  /* ------------------------------------------------------------------ *
   * Text                                                               *
   * ------------------------------------------------------------------ */
  let FONTS = {};
  function setFonts(fonts) { FONTS = fonts; }

  function glyphOf(font, ch) {
    return font.glyphs[ch] || font.glyphs[ch.toUpperCase()] || font.glyphs['?'] || null;
  }

  function textWidth(fontName, str, tracking, space) {
    const font = FONTS[fontName]; if (!font) return 0;
    const tr = tracking || 0;
    let w = 0;
    for (let i = 0; i < str.length; i++) {
      const g = glyphOf(font, str[i]); if (!g) continue;
      w += (str[i] === ' ' && space !== undefined ? space : g.adv) + (i < str.length - 1 ? tr : 0);
    }
    return w;
  }

  /*
   * Draw a string with its baseline at `baseY`. Glyph pixels are either 1-bit
   * ('#') or intensity digits '0'..'9'. A hard drop shadow sits one LED down
   * and right, the way the firmware's white-on-red type is set.
   */
  function drawText(f, fontName, str, x, baseY, colour, opts) {
    const font = FONTS[fontName]; if (!font) return;
    const o = opts || {};
    const tr = o.tracking || 0;
    const passes = [];
    const sa = o.shadowAlpha === undefined ? 0.85 : o.shadowAlpha;
    if (o.shadow && o.shadowDepth === 2) passes.push({ dx: 2, dy: 2, c: o.shadow, a: sa * 0.8 });
    if (o.shadow) passes.push({ dx: 1, dy: 1, c: o.shadow, a: sa });
    passes.push({ dx: 0, dy: 0, c: colour, a: o.alpha === undefined ? 1 : o.alpha });
    for (const pass of passes) {
      let pen = Math.round(x);
      for (let i = 0; i < str.length; i++) {
        const g = glyphOf(font, str[i]); if (!g) continue;
        for (let r = 0; r < g.rows.length; r++) {
          const row = g.rows[r];
          for (let c = 0; c < row.length; c++) {
            const ch = row[c];
            let k = 0;
            if (ch === '#') k = 1;
            else if (ch >= '1' && ch <= '9') k = (ch.charCodeAt(0) - 48) / 9;
            if (k <= 0) continue;
            const gx = pen + g.ox + c + pass.dx;
            const gy = baseY - g.oy - g.h + 1 + r + pass.dy;   // oy: bottom of box above baseline
            if (o.clip && (gx < o.clip[0] || gx >= o.clip[1])) continue;
            f.blend(gx, gy, pass.c, k * pass.a);
          }
        }
        pen += (str[i] === ' ' && o.space !== undefined ? o.space : g.adv) + tr;
      }
    }
  }

  /* ------------------------------------------------------------------ *
   * Ambient effects                                                    *
   * ------------------------------------------------------------------ */

  /*
   * Drifting sparks over a dark field, after the firmware's particles_busy /
   * particles_rest loops. Each spark is seeded, so the field is identical on
   * every platform, and it's always moving — good for a panel that never
   * switches off.
   */
  function drawParticles(f, x0, x1, t, pal, density) {
    const n = Math.round((x1 - x0) * (density || 0.28));
    for (let i = 0; i < n; i++) {
      const seed = i * 7919 + 17;
      const px = x0 + hash(seed) * (x1 - x0);
      const speed = 0.6 + hash(seed + 1) * 1.4;          // LEDs per second, upward
      const life = 2.2 + hash(seed + 2) * 2.8;           // seconds
      const phase = hash(seed + 3) * life;
      const age = ((t + phase) % life) / life;           // 0..1
      const py = ROWS - 1 - age * speed * life + hash(seed + 4) * 4;
      const wobble = Math.sin((t + phase) * (1.3 + hash(seed + 5))) * 0.6;
      const x = Math.round(px + wobble), y = Math.round(py);
      if (x < x0 || x >= x1 || y < 1 || y > ROWS - 2) continue;
      const fade = Math.sin(age * Math.PI);                // in and out
      const twinkle = 0.65 + 0.35 * Math.sin((t + phase) * 9 + i);
      const c = hash(seed + 6) > 0.55 ? pal.spark : pal.sparkDim;
      f.blend(x, y, c, fade * twinkle);
    }
  }

  /*
   * The firmware's "select" transition, rebuilt procedurally so it fits any
   * width: a white ring bursts from just above top-centre with a dark leading
   * edge, the state colour floods in behind it, the panel flashes, then the
   * light decays. Additive — black contributes nothing.
   *
   * 66 frames at 60 fps in the original; `p` runs 0..1 across the same 1.1 s.
   */
  function drawShockwave(f, p, pal) {
    if (p <= 0 || p >= 1) return;
    const frame = p * 66;
    const cx = COLS / 2, cy = -3.5;
    const radius = Math.pow(frame / 11, 1.35) * 34;      // reaches the corners around frame 11
    const band = 3.2 + frame * 0.55;                      // ring thickens as it travels
    // colour floods in, peaks at frame 11, then decays the way the firmware's
    // frames do: roughly exponential, half-life about nine frames
    const flood = frame < 11 ? smooth(4, 11, frame) : Math.exp(-(frame - 11) / 13) * (1 - smooth(60, 66, frame));
    const ringLife = 1 - smooth(9, 16, frame);
    const aspect = 1.65;                                  // the ring reads as an oval on a wide panel
    for (let y = 0; y < ROWS; y++) {
      for (let x = 0; x < COLS; x++) {
        const dx = (x + 0.5 - cx) / aspect, dy = (y + 0.5 - cy);
        const d = Math.hypot(dx, dy);
        const u = (d - radius) / band;                    // 0 at the ring's crest
        // hot white crest, colour behind it, dark just ahead of it
        const crest = Math.exp(-u * u * 2.2) * ringLife;
        const inside = d < radius ? 1 : 0;
        const ahead = (u > 0.6 && u < 1.6) ? (1 - Math.abs(u - 1.1) * 2) * ringLife : 0;
        if (ahead > 0) f.multiply(x, y, 1 - ahead * 0.85);
        // until the flood peaks, the ring clears the old screen as it passes
        if (frame < 11 && u < -0.4) f.multiply(x, y, 0.12);
        f.add(x, y, mix(pal.flood, [1, 1, 1], 0.72), crest * 0.9);
        const edgeGlow = clamp((d - radius * 0.35) / (radius * 0.65 + 0.01), 0, 1);
        f.add(x, y, mix(pal.flood, pal.highlight, edgeGlow * 0.55), flood * (inside ? 1 : 0.9) * 0.62);
      }
    }
  }

  /* ------------------------------------------------------------------ *
   * Layout — 118 x 16                                                   *
   *                                                                     *
   *   col 0      margin                                                 *
   *   cols 1-71  status pill   (lit, the sign itself)                   *
   *   cols 72-73 gap                                                    *
   *   cols 74-116 clock pill   (dark field, sparks, time)               *
   *   col 117    margin                                                 *
   * ------------------------------------------------------------------ */
  const LAYOUT = {
    statusX: 1, statusW: 71,
    clockX: 74, clockW: 43,
    heroX: 1, heroW: COLS - 2,
    heroFont: 'busy_regular_14',   // 14-row capitals: the announcement
    statusFont: 'busy_bold_10',    // the face of the firmware's BUSY pill
    clockFont: 'busy_bold_10',
    heroBase: 14,                  // baseline rows (bottom row of capitals)
    statusBase: 12,
    clockBase: 12,
    secondsRow: 14
  };

  const WORDS = { call: 'ON A CALL', free: 'FREE' };

  /* busy_regular_14 is busy_regular_7 doubled, so everything about it is at
     twice the scale: a two-step shadow, and word spaces trimmed to match. */
  const HERO_SPACE = 6;
  function heroStyle(pal, alpha) {
    const a = alpha === undefined ? 1 : alpha;
    return { shadow: pal.shadow, shadowDepth: 2, space: HERO_SPACE, alpha: a, shadowAlpha: 0.9 * a };
  }
  function heroWidth(state) { return textWidth(LAYOUT.heroFont, WORDS[state], 0, HERO_SPACE); }

  /* ------------------------------------------------------------------ *
   * Timeline (seconds from the moment the state changes)                *
   * ------------------------------------------------------------------ */
  const T = {
    wave: 1.10,        // the shockwave, 66 frames at 60 fps
    swap: 0.18,        // frame 11: the flood peaks and hides the switch underneath
    hold: 3.4,         // the announcement stays up this long after the swap
    collapse: 0.68,    // 41 frames, like the firmware's label transition
    clockIn: 0.5
  };

  /*
   * The scene at a moment.
   *   now   — seconds, monotonic (drives ambient motion)
   *   state — 'call' | 'free';  prev — the state before it (or null)
   *   since — `now` at which `state` began
   *   clock — { h, m, s, ms } wall-clock time to show
   */
  function render(f, now, state, prev, since, clock) {
    f.px.fill(0);
    const pal = PALETTE[state];
    const e = now - since;
    const collapseStart = T.swap + T.hold;
    const collapseEnd = collapseStart + T.collapse;

    if (e < T.swap) {
      // the old screen, about to be wiped by the wave
      if (prev) drawSteady(f, now, prev, clock, 1);
    } else if (e < collapseStart) {
      drawHero(f, now, state, pal);
    } else if (e < collapseEnd) {
      const k = easeInOut((e - collapseStart) / T.collapse);
      const w = lerp(LAYOUT.heroW, LAYOUT.statusW, k);
      const edge = LAYOUT.heroX + w;
      // the clock pill is revealed behind the retreating edge
      if (edge < LAYOUT.clockX + LAYOUT.clockW) {
        drawClockPill(f, now, pal, clock, 0, { from: Math.max(LAYOUT.clockX, edge + 2) });
      }
      drawPill(f, LAYOUT.heroX, w, pal, { sheen: sheenAt(now) });
      // the announcement face gives way to the status face as the pill shrinks:
      // out before the big word can outgrow the pill, in once there's room
      const out = 1 - smooth(0.0, 0.28, k);
      const inn = smooth(0.3, 0.62, k);
      const clip = [LAYOUT.heroX + 1, Math.floor(edge) - 1];
      if (out > 0) {
        const hw = heroWidth(state);
        drawText(f, LAYOUT.heroFont, WORDS[state], LAYOUT.heroX + (Math.max(w, hw + 6) - hw) / 2 + 0.5,
          LAYOUT.heroBase, PALETTE.white, Object.assign(heroStyle(pal, out), { clip: clip }));
      }
      if (inn > 0) {
        const sw = textWidth(LAYOUT.statusFont, WORDS[state]);
        drawText(f, LAYOUT.statusFont, WORDS[state], LAYOUT.heroX + (w - sw) / 2 + 0.5,
          LAYOUT.statusBase, PALETTE.white, { shadow: pal.shadow, alpha: inn, shadowAlpha: 0.9 * inn, clip: clip });
      }
    } else {
      const clockAlpha = easeOut(clamp((e - collapseEnd) / T.clockIn, 0, 1));
      drawSteady(f, now, state, clock, clockAlpha);
    }

    if (e < T.wave) drawShockwave(f, e / T.wave, pal);
  }

  function sheenAt(now) {
    // a soft band of light crosses the pill every 8 s — the firmware's
    // indicator_busy loop does the same over 20 s
    const cycle = 8.0;
    return { pos: ((now % cycle) / cycle) * (COLS + 50) - 25, width: 6, strength: 0.18 };
  }

  function drawHero(f, now, state, pal) {
    drawPill(f, LAYOUT.heroX, LAYOUT.heroW, pal, { sheen: sheenAt(now) });
    const w = heroWidth(state);
    drawText(f, LAYOUT.heroFont, WORDS[state], LAYOUT.heroX + (LAYOUT.heroW - w) / 2 + 0.5,
      LAYOUT.heroBase, PALETTE.white, heroStyle(pal));
  }

  function drawSteady(f, now, state, clock, clockAlpha) {
    const pal = PALETTE[state];
    drawPill(f, LAYOUT.statusX, LAYOUT.statusW, pal, { sheen: sheenAt(now) });
    const w = textWidth(LAYOUT.statusFont, WORDS[state]);
    drawText(f, LAYOUT.statusFont, WORDS[state], LAYOUT.statusX + (LAYOUT.statusW - w) / 2 + 0.5,
      LAYOUT.statusBase, PALETTE.white, { shadow: pal.shadow });
    drawClockPill(f, now, pal, clock, clockAlpha);
  }

  /* Tabular digits: every digit takes the widest digit's advance, centred,
     so the clock doesn't shuffle sideways when a 1 comes round. */
  function drawClockText(f, fontName, str, x, base, colour, opts, colonAlpha) {
    const font = FONTS[fontName]; if (!font) return 0;
    let cell = 0;
    for (const d of '0123456789') { const g = glyphOf(font, d); if (g && g.adv > cell) cell = g.adv; }
    let pen = x;
    for (const ch of str) {
      const g = glyphOf(font, ch); if (!g) continue;
      if (ch >= '0' && ch <= '9') {
        const inset = cell - g.adv;             // narrow digits sit right, like a real LED clock
        drawText(f, fontName, ch, pen + inset, base, colour, opts);
        pen += cell;
      } else {
        const o = Object.assign({}, opts, { alpha: (opts.alpha === undefined ? 1 : opts.alpha) * colonAlpha,
          shadowAlpha: (opts.shadowAlpha === undefined ? 0.85 : opts.shadowAlpha) * colonAlpha });
        drawText(f, fontName, ch, pen, base, colour, o);
        pen += g.adv;
      }
    }
    return pen - x;
  }

  function clockTextWidth(fontName, str) {
    const font = FONTS[fontName]; if (!font) return 0;
    let cell = 0;
    for (const d of '0123456789') { const g = glyphOf(font, d); if (g && g.adv > cell) cell = g.adv; }
    let w = 0;
    for (const ch of str) { const g = glyphOf(font, ch); if (!g) continue; w += (ch >= '0' && ch <= '9') ? cell : g.adv; }
    return w;
  }

  function drawClockPill(f, now, pal, clock, alpha, opts) {
    const o = opts || {};
    const x0 = LAYOUT.clockX, x1 = LAYOUT.clockX + LAYOUT.clockW;
    const from = o.from === undefined ? x0 : o.from;
    if (from >= x1) return;
    // dark field with sparks, as behind the firmware's timer
    const tmp = new Frame();
    drawPill(tmp, x0, LAYOUT.clockW, pal, { fillTo: -1, outline: 0.55 });
    drawParticles(tmp, x0 + 1, x1 - 1, now, pal, 0.42);
    if (alpha > 0) {
      const pad = (n) => (n < 10 ? '0' : '') + n;
      const hhmm = pad(clock.h) + ':' + pad(clock.m);
      const w = clockTextWidth(LAYOUT.clockFont, hhmm);
      const colon = clock.ms < 500 ? 1 : 0.35;          // 1 Hz, like the v1 module
      drawClockText(tmp, LAYOUT.clockFont, hhmm, x0 + Math.round((LAYOUT.clockW - w) / 2), LAYOUT.clockBase,
        PALETTE.white, { shadow: [0, 0, 0], shadowAlpha: 0.75 * alpha, alpha: alpha }, colon);
      // seconds: a bar filling along the bottom, a nod to the v1 second ring
      const bx0 = x0 + 3, bx1 = x1 - 3;
      const span = bx1 - bx0;
      const filled = ((clock.s + clock.ms / 1000) / 60) * span;
      for (let x = bx0; x < bx1; x++) {
        const k = clamp(filled - (x - bx0), 0, 1);
        tmp.blend(x, LAYOUT.secondsRow, mix(pal.sparkDim, pal.spark, 0.5), (0.12 + 0.78 * k) * alpha);
      }
    }
    // copy the revealed part across
    for (let y = 0; y < ROWS; y++) for (let x = Math.max(0, Math.floor(from)); x < x1 + 1 && x < COLS; x++) {
      const c = tmp.get(x, y); if (c[0] + c[1] + c[2] > 0) f.set(x, y, c);
    }
  }

  root.BusyEngine = {
    clockTextWidth: clockTextWidth,
    COLS: COLS, ROWS: ROWS, PALETTE: PALETTE, LAYOUT: LAYOUT, WORDS: WORDS, T: T,
    Frame: Frame, render: render, setFonts: setFonts, textWidth: textWidth,
    drawPill: drawPill, drawText: drawText, drawParticles: drawParticles, drawShockwave: drawShockwave,
    hash: hash
  };
})(typeof window !== 'undefined' ? window : globalThis);
