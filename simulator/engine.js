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
      shadow:    hex(0x4A0006),   // text drop shadow on the lit pill
      flood:     hex(0xBC2525)    // the colour the shockwave floods to
    },
    free: {
      highlight: hex(0x8FFFC4),
      top:       hex(0x17EB79),
      bottom:    hex(0x03603F),
      rimBottom: hex(0x0D7B55),
      edge:      hex(0x5CD69A),
      shadow:    hex(0x013A24),
      flood:     hex(0x2A9E63)
    },
    white: [1, 1, 1]
  };

  /* ------------------------------------------------------------------ *
   * Small maths helpers                                                *
   * ------------------------------------------------------------------ */
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  const lerp = (a, b, t) => a + (b - a) * t;
  const mix = (c1, c2, t) => [lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t)];
  const smooth = (e0, e1, x) => { const t = clamp((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t); };
  const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const easeOut = (t) => 1 - Math.pow(1 - t, 3);
  const easeIn = (t) => t * t * t;

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
   */
  function drawPill(f, x0, w, pal, opts) {
    const o = opts || {};
    const y0 = 0, h = ROWS, r = 2.6;
    const sheen = o.sheen;           // { pos, width, strength } or undefined
    for (let y = 0; y < ROWS; y++) {
      for (let x = Math.floor(x0) - 1; x <= Math.ceil(x0 + w) + 1; x++) {
        const d = roundRectSDF(x + 0.5, y + 0.5, x0, y0, w, h, r);
        const cover = clamp(0.5 - d, 0, 1);
        if (cover <= 0) continue;

        let c;
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
   * Layout — 118 x 16, after the firmware's timer screen: a lit pill on  *
   * the left, the time in white on black to its right, a dim word below. *
   *                                                                     *
   *   col 0        margin                                               *
   *   cols 1-80    status pill  (icon + word, lit)                      *
   *   cols 81-83   gap                                                  *
   *   cols 84-116  clock        (time rows 1-7, date rows 10-14)        *
   *   col 117      margin                                               *
   * ------------------------------------------------------------------ */
  const LAYOUT = {
    statusX: 1, statusW: 80,
    clockX: 84, clockW: 33,
    heroX: 1, heroW: COLS - 2,
    heroFont: 'busy_regular_14',   // 14-row capitals: the announcement
    statusFont: 'busy_bold_10',    // the face of the firmware's BUSY pill
    timeFont: 'busy_bold_7',       // the firmware's clock app face
    dateFont: 'busy_regular_5',
    heroBase: 14,                  // baseline rows (bottom row of capitals)
    statusBase: 12,
    timeBase: 7,                   // rows 1-7, as the firmware's timer label
    dateBase: 14,                  // rows 10-14
    iconGap: 4,
    slideIn: 40                    // the time slides in from 40 LEDs right
  };

  const WORDS = { call: 'ON A CALL', free: 'FREE' };
  const DAYS = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

  /* Pictograms, drawn in the firmware's style: white, hard shadow. The mic
     echoes the firmware's on_call theme; the tick is the "available" mark
     every meeting app uses. Rows top to bottom; bottom row sits on the
     status baseline. */
  const ICONS = {
    call: [
      '...###...',
      '..#####..',
      '..#####..',
      '..#####..',
      '..#####..',
      '#.#####.#',
      '#.#####.#',
      '#..###..#',
      '.#.....#.',
      '..#####..',
      '....#....',
      '..#####..'
    ],
    free: [
      '........##',
      '.......###',
      '......###.',
      '.....###..',
      '##..###...',
      '######....',
      '.####.....',
      '..##......'
    ]
  };
  const ICON_LIFT = { call: -1, free: 1 };   // rows above the baseline for the icon's bottom row

  /* busy_regular_14 is busy_regular_7 doubled, so everything about it is at
     twice the scale: a two-step shadow, and word spaces trimmed to match. */
  const HERO_SPACE = 6;
  function heroStyle(pal, alpha) {
    const a = alpha === undefined ? 1 : alpha;
    return { shadow: pal.shadow, shadowDepth: 2, space: HERO_SPACE, alpha: a, shadowAlpha: 0.9 * a };
  }
  function heroWidth(state) { return textWidth(LAYOUT.heroFont, WORDS[state], 0, HERO_SPACE); }

  function drawIcon(f, rows, x, bottomY, colour, shadow, alpha, clip) {
    const h = rows.length;
    const passes = [{ d: 1, c: shadow, a: 0.9 * alpha }, { d: 0, c: colour, a: alpha }];
    for (const pass of passes) {
      for (let r = 0; r < h; r++) for (let c = 0; c < rows[r].length; c++) {
        if (rows[r][c] !== '#') continue;
        const gx = x + c + pass.d, gy = bottomY - h + 1 + r + pass.d;
        if (clip && (gx < clip[0] || gx >= clip[1])) continue;
        f.blend(gx, gy, pass.c, pass.a);
      }
    }
  }

  /* Icon + word, centred as one unit in a pill of width w starting at x0. */
  function statusContentWidth(state) {
    return ICONS[state][0].length + LAYOUT.iconGap + textWidth(LAYOUT.statusFont, WORDS[state]);
  }
  function drawStatusContent(f, state, pal, x0, w, alpha, clip) {
    const cw = statusContentWidth(state);
    const x = Math.round(x0 + (w - cw) / 2);
    drawIcon(f, ICONS[state], x, LAYOUT.statusBase - ICON_LIFT[state], PALETTE.white, pal.shadow, alpha, clip);
    drawText(f, LAYOUT.statusFont, WORDS[state], x + ICONS[state][0].length + LAYOUT.iconGap,
      LAYOUT.statusBase, PALETTE.white, { shadow: pal.shadow, alpha: alpha, shadowAlpha: 0.9 * alpha, clip: clip });
  }

  /* ------------------------------------------------------------------ *
   * Timeline (seconds from the moment the state changes)                *
   * ------------------------------------------------------------------ */
  const T = {
    wave: 1.10,        // the shockwave: 66 frames at 60 fps
    swap: 0.10,        // the firmware cuts to the new screen at 100 ms
    press: 3,          // ...having pressed the old one down 3 rows, then springs the new one up
    hold: 3.4,         // the announcement stays up this long after the cut
    collapse: 0.667    // 41 frames, as indicator_busy_transition
  };

  /* Move everything down by dy rows (the firmware's press effect). */
  function shiftDown(f, dy) {
    if (dy <= 0) return;
    for (let y = ROWS - 1; y >= 0; y--) for (let x = 0; x < COLS; x++) {
      f.set(x, y, y - dy >= 0 ? f.get(x, y - dy) : [0, 0, 0]);
    }
  }

  /*
   * The scene at a moment.
   *   now   — seconds, monotonic (drives ambient motion)
   *   state — 'call' | 'free';  prev — the state before it (or null)
   *   since — `now` at which `state` began
   *   clock — { h, m, s, ms, dow, date } wall-clock time to show
   */
  function render(f, now, state, prev, since, clock) {
    f.px.fill(0);
    const pal = PALETTE[state];
    const e = now - since;
    const collapseStart = T.swap + T.hold;
    const collapseEnd = collapseStart + T.collapse;

    if (e < T.swap) {
      // the old screen, pressed down as the wave hits it
      if (prev) {
        drawSteady(f, now, prev, clock, 0);
        shiftDown(f, Math.round(T.press * easeIn(e / T.swap)));
      }
    } else if (e < collapseStart) {
      drawHero(f, now, state, pal);
      // ...and the new one springs back up
      const r = (e - T.swap) / T.swap;
      if (r < 1) shiftDown(f, Math.round(T.press * (1 - easeOut(r))));
    } else if (e < collapseEnd) {
      const k = easeInOut((e - collapseStart) / T.collapse);
      const w = lerp(LAYOUT.heroW, LAYOUT.statusW, k);
      const edge = LAYOUT.heroX + w;
      drawPill(f, LAYOUT.heroX, w, pal, { sheen: sheenAt(now) });
      // the announcement face gives way to icon + status face as the pill shrinks:
      // out before the big word can outgrow the pill, in once there's room
      const out = 1 - smooth(0.08, 0.34, k);
      const inn = smooth(0.14, 0.4, k);         // overlapping, so the pill is never empty
      const clip = [LAYOUT.heroX + 1, Math.floor(edge) - 1];
      if (out > 0) {
        const hw = heroWidth(state);
        drawText(f, LAYOUT.heroFont, WORDS[state], LAYOUT.heroX + (Math.max(w, hw + 6) - hw) / 2 + 0.5,
          LAYOUT.heroBase, PALETTE.white, Object.assign(heroStyle(pal, out), { clip: clip }));
      }
      if (inn > 0) drawStatusContent(f, state, pal, LAYOUT.heroX, w, inn, clip);
      // the time slides in from the right as the pill makes room, as the
      // firmware's timer label does
      const slide = Math.round(LAYOUT.slideIn * (1 - easeOut((e - collapseStart) / T.collapse)));
      drawClock(f, clock, slide, Math.ceil(edge) + 2);
    } else {
      drawSteady(f, now, state, clock, 0);
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

  function drawSteady(f, now, state, clock, slide) {
    const pal = PALETTE[state];
    drawPill(f, LAYOUT.statusX, LAYOUT.statusW, pal, { sheen: sheenAt(now) });
    drawStatusContent(f, state, pal, LAYOUT.statusX, LAYOUT.statusW, 1);
    drawClock(f, clock, slide, 0);
  }

  /* Tabular digits: every digit takes the widest digit's advance, so the
     clock doesn't shuffle sideways as the minutes turn. */
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
        const o = Object.assign({}, opts, { alpha: (opts.alpha === undefined ? 1 : opts.alpha) * colonAlpha });
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

  /*
   * The time, white on black, with the day beneath at half brightness —
   * the firmware's clock app. Colons drop to 40% on odd seconds.
   * `slide` pushes it right (entrance); nothing is drawn left of `minX`.
   */
  function drawClock(f, clock, slide, minX) {
    const pad = (n) => (n < 10 ? '0' : '') + n;
    const hhmm = pad(clock.h) + ':' + pad(clock.m);
    const day = DAYS[clock.dow] + ' ' + clock.date;
    const tw = clockTextWidth(LAYOUT.timeFont, hhmm);
    const dw = textWidth(LAYOUT.dateFont, day);
    const x0 = LAYOUT.clockX + slide;
    const clip = [Math.max(minX || 0, LAYOUT.clockX - 3), COLS];
    const colon = clock.s % 2 === 1 ? 0.4 : 1;
    drawClockText(f, LAYOUT.timeFont, hhmm, x0 + Math.round((LAYOUT.clockW - tw) / 2), LAYOUT.timeBase,
      PALETTE.white, { clip: clip }, colon);
    drawText(f, LAYOUT.dateFont, day, x0 + Math.round((LAYOUT.clockW - dw) / 2), LAYOUT.dateBase,
      PALETTE.white, { alpha: 0.5, clip: clip });
  }

  root.BusyEngine = {
    clockTextWidth: clockTextWidth, ICONS: ICONS, statusContentWidth: statusContentWidth,
    COLS: COLS, ROWS: ROWS, PALETTE: PALETTE, LAYOUT: LAYOUT, WORDS: WORDS, T: T,
    Frame: Frame, render: render, setFonts: setFonts, textWidth: textWidth,
    drawPill: drawPill, drawText: drawText, drawShockwave: drawShockwave,
    hash: hash
  };
})(typeof window !== 'undefined' ? window : globalThis);
