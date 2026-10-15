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
    // Do Not Disturb: indigo, the colour macOS gives Focus and Do Not
    // Disturb, on the same vertical profile as the firmware's pills
    dnd: {
      highlight: hex(0xB0A8FF),
      top:       hex(0x5B45FF),
      bottom:    hex(0x1D1370),
      rimBottom: hex(0x2C237E),
      edge:      hex(0x8A80E8),
      shadow:    hex(0x110A48),
      flood:     hex(0x4A3DC4)
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
    // the calendar's warnings and 'free, but booked': amber, between the
    // green and the red, on the same vertical profile
    amber: {
      highlight: hex(0xFFD38A),
      top:       hex(0xFFA21A),
      bottom:    hex(0x6B3B00),
      rimBottom: hex(0x7D4C12),
      edge:      hex(0xE0A653),
      shadow:    hex(0x482500),
      flood:     hex(0xC07A14)
    },
    // not here: away, at lunch, out of office
    grey: {
      highlight: hex(0xC4C8D2),
      top:       hex(0x7E8492),
      bottom:    hex(0x272A31),
      rimBottom: hex(0x3A3D45),
      edge:      hex(0x8E93A0),
      shadow:    hex(0x15161A),
      flood:     hex(0x5E636E)
    },
    white: [1, 1, 1]
  };
  /* Which palette each state is lit in. */
  const STATE_PALETTE = {
    call: 'call', meeting: 'call',
    free: 'free',
    dnd: 'dnd',
    callIn: 'amber', busyIn: 'amber', late: 'amber', freeTil: 'amber', callTbc: 'amber', busyTbc: 'amber',
    away: 'grey', lunch: 'grey', ooo: 'grey'
  };
  const palOf = (state) => PALETTE[STATE_PALETTE[state]];

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
  /* A frame of w x h LEDs — the wide bar's 118 x 16 unless told otherwise. */
  function Frame(w, h) {
    this.w = w || COLS; this.h = h || ROWS;
    this.px = new Float32Array(this.w * this.h * 3);
  }
  Frame.prototype.get = function (x, y) {
    const i = (y * this.w + x) * 3; return [this.px[i], this.px[i + 1], this.px[i + 2]];
  };
  Frame.prototype.set = function (x, y, c) {
    if (x < 0 || y < 0 || x >= this.w || y >= this.h) return;
    const i = (y * this.w + x) * 3; this.px[i] = c[0]; this.px[i + 1] = c[1]; this.px[i + 2] = c[2];
  };
  /* Alpha-blend c over the existing LED. */
  Frame.prototype.blend = function (x, y, c, a) {
    if (a <= 0 || x < 0 || y < 0 || x >= this.w || y >= this.h) return;
    if (a > 1) a = 1;
    const i = (y * this.w + x) * 3, p = this.px;
    p[i] += (c[0] - p[i]) * a; p[i + 1] += (c[1] - p[i + 1]) * a; p[i + 2] += (c[2] - p[i + 2]) * a;
  };
  /* Add light — how the firmware's transition overlays combine with the screen. */
  Frame.prototype.add = function (x, y, c, k) {
    if (k <= 0 || x < 0 || y < 0 || x >= this.w || y >= this.h) return;
    const i = (y * this.w + x) * 3, p = this.px;
    p[i] = Math.min(1, p[i] + c[0] * k); p[i + 1] = Math.min(1, p[i + 1] + c[1] * k); p[i + 2] = Math.min(1, p[i + 2] + c[2] * k);
  };
  Frame.prototype.multiply = function (x, y, k) {
    if (x < 0 || y < 0 || x >= this.w || y >= this.h) return;
    const i = (y * this.w + x) * 3, p = this.px; p[i] *= k; p[i + 1] *= k; p[i + 2] *= k;
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
    const y0 = 0, h = o.h || ROWS, r = 2.6;      // rows 0..h-1: 16, or taller in the stacked layout
    const sheen = o.sheen;           // { pos, width, strength } or undefined
    for (let y = 0; y < h; y++) {
      for (let x = Math.floor(x0) - 1; x <= Math.ceil(x0 + w) + 1; x++) {
        const d = roundRectSDF(x + 0.5, y + 0.5, x0, y0, w, h, r);
        const cover = clamp(0.5 - d, 0, 1);
        if (cover <= 0) continue;

        let c;
        if (y === 0) c = pal.highlight;
        else if (y <= 3) c = pal.top;
        else if (y === h - 1) c = pal.rimBottom;
        else c = mix(pal.top, pal.bottom, (y - 3) / (h - 2 - 3));
        // pale rim on the rounded ends
        const edge = clamp(1 - Math.abs(d + 0.9), 0, 1);
        if (edge > 0 && y > 0 && y < h - 1) c = mix(c, pal.edge, edge * 0.85);
        if (sheen) {
          // a soft diagonal band of light drifting across the pill
          const u = (x + 0.5 - sheen.pos) + (y - h / 2) * 0.55;
          const s = Math.exp(-(u * u) / (2 * sheen.width * sheen.width)) * sheen.strength;
          c = mix(c, pal.highlight, s);
        }
        if (o.dim) c = [c[0] * (1 - o.dim), c[1] * (1 - o.dim), c[2] * (1 - o.dim)];
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
            if (o.clipY && (gy < o.clipY[0] || gy >= o.clipY[1])) continue;
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
    const aspect = 1.65;                                  // the ring reads as an oval on a wide panel
    const cx = f.w / 2, cy = -3.5;
    // on a taller panel the ring travels further, so it still reaches the corners on cue
    const reach = Math.hypot(f.w / 2 / aspect, f.h - cy) / Math.hypot(COLS / 2 / aspect, ROWS - cy);
    const radius = Math.pow(frame / 11, 1.35) * 34 * reach;   // reaches the corners around frame 11
    const band = 3.2 + frame * 0.55;                      // ring thickens as it travels
    // colour floods in, peaks at frame 11, then decays the way the firmware's
    // frames do: roughly exponential, half-life about nine frames
    const flood = frame < 11 ? smooth(4, 11, frame) : Math.exp(-(frame - 11) / 13) * (1 - smooth(60, 66, frame));
    const ringLife = 1 - smooth(9, 16, frame);
    for (let y = 0; y < f.h; y++) {
      for (let x = 0; x < f.w; x++) {
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

  const WORDS = {
    call: 'ON A CALL', free: 'FREE', dnd: 'DND',
    meeting: 'MEETING',
    callIn: 'CALL IN', busyIn: 'BUSY IN',                        // + the countdown on the right
    late: 'LATE FOR',                                            // + CALL on the right
    freeTil: 'FREE TILL',                                        // + the slot's end on the right
    callTbc: 'CALL TBC', busyTbc: 'BUSY TBC',                    // tentative: countdown, then TILL
    away: 'AWAY', lunch: 'LUNCH', ooo: 'OUT OF'                  // + OFFICE on the right
  };
  /* The announcement. DO NOT DISTURB is too wide for the 14-row face, so it's
     set in the status face across the whole bar. */
  const HERO = {
    call: { word: 'ON A CALL', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    free: { word: 'FREE', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    dnd:  { word: 'DO NOT DISTURB', font: 'busy_bold_10', base: 12, depth: 1, space: undefined },
    meeting:   { word: 'MEETING', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    callIn:    { word: 'CALL SOON', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    busyIn:    { word: 'BUSY SOON', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    late:      { word: 'LATE FOR CALL', font: 'busy_bold_10', base: 12, depth: 1, space: undefined },
    freeTil:   { word: 'FREE TILL {t}', font: 'busy_bold_10', base: 12, depth: 1, space: undefined },
    callTbc:   { word: 'CALL TBC', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    busyTbc:   { word: 'BUSY TBC', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    away:      { word: 'AWAY', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    lunch:     { word: 'LUNCH', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    ooo:       { word: 'OUT OF OFFICE', font: 'busy_bold_10', base: 12, depth: 1, space: undefined }
  };
  const pad2 = (n) => (n < 10 ? '0' : '') + n;
  /* An announcement's words; {t} is the time the state is about (FREE TILL 11:00). */
  function heroWord(state, timer) {
    const w = HERO[state].word;
    if (w.indexOf('{t}') < 0) return w;
    return timer ? w.replace('{t}', pad2(timer.h) + ':' + pad2(timer.m)) : w.replace(' TILL {t}', '').replace('{t}', '');
  }
  const DAYS = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

  /* Pictograms, drawn in the firmware's style: white, hard shadow. The mic
     echoes the firmware's on_call theme; the tick is the "available" mark
     every meeting app uses; the moon is Do Not Disturb's, as on the Mac. Rows top to bottom; bottom row sits on the
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
    dnd: [
      '....#.......',
      '..###.......',
      '.###........',
      '.###........',
      '#####.......',
      '#####.......',
      '######......',
      '#######....#',
      '.##########.',
      '.##########.',
      '..########..',
      '....####....'
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
    ],
    // two people
    meeting: [
      '.###...###.',
      '#####.#####',
      '#####.#####',
      '.###...###.',
      '...........',
      '.###...###.',
      '#####.#####',
      '#####.#####',
      '#####.#####'
    ],
    // a bell: something's about to start
    soon: [
      '.....#.....',
      '...#####...',
      '..#######..',
      '..#######..',
      '..#######..',
      '..#######..',
      '.#########.',
      '###########',
      '...........',
      '....###....'
    ],
    // a warning sign
    late: [
      '.....#.....',
      '....###....',
      '...##.##...',
      '...##.##...',
      '..###.###..',
      '..###.###..',
      '.#########.',
      '.####.####.',
      '###########'
    ],
    // a pencil: pencilled in, not confirmed
    tbc: [
      '........#.',
      '.......###',
      '......###.',
      '.....###..',
      '....###...',
      '...###....',
      '..###.....',
      '.###......',
      '.##.......',
      '#.........'
    ],
    // a fork and a knife
    lunch: [
      '#.#.#..#',
      '#.#.#.##',
      '#.#.#.##',
      '#.#.#.##',
      '#####.##',
      '.###..##',
      '..#....#',
      '..#....#',
      '..#....#',
      '..#....#',
      '..#....#'
    ],
    // out of the door
    away: [
      '#####......',
      '#..........',
      '#.......#..',
      '#.......##.',
      '#..########',
      '#..########',
      '#.......##.',
      '#.......#..',
      '#..........',
      '#####......'
    ],
    // a plane seen from above, nose to the right, wings swept back
    ooo: [
      '....##......',
      '.....##.....',
      '......##....',
      '#......##...',
      '##.....###..',
      '############',
      '##.....###..',
      '#......##...',
      '......##....',
      '.....##.....',
      '....##......'
    ]
  };
  ICONS.callIn = ICONS.busyIn = ICONS.soon;
  ICONS.callTbc = ICONS.busyTbc = ICONS.tbc;
  ICONS.freeTil = ICONS.free;
  const ICON_LIFT = {
    call: -1, free: 1, dnd: -1, meeting: 0, callIn: 0, busyIn: 0, late: 0,
    freeTil: 1, callTbc: 0, busyTbc: 0, lunch: -1, away: 0, ooo: -1
  };   // rows above the baseline for the icon's bottom row

  /* busy_regular_14 is busy_regular_7 doubled, so everything about it is at
     twice the scale: a two-step shadow, and word spaces trimmed to match. */
  function heroStyle(state, pal, alpha) {
    const a = alpha === undefined ? 1 : alpha;
    const h = HERO[state];
    return { shadow: pal.shadow, shadowDepth: h.depth, space: h.space, alpha: a, shadowAlpha: 0.9 * a };
  }
  function heroWidth(state, timer) { return textWidth(HERO[state].font, heroWord(state, timer), 0, HERO[state].space); }

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
    for (let y = f.h - 1; y >= 0; y--) for (let x = 0; x < f.w; x++) {
      f.set(x, y, y - dy >= 0 ? f.get(x, y - dy) : [0, 0, 0]);
    }
  }

  /*
   * The scene at a moment.
   *   now   — seconds, monotonic (drives ambient motion)
   *   state — 'call' | 'free';  prev — the state before it (or null)
   *   since — `now` at which `state` began
   *   clock — { h, m, s, ms, dow, date } wall-clock time to show
   *   timer — Do Not Disturb's countdown, { left: seconds, h, m } (the end
   *           time), shown in place of the clock while the state is 'dnd'
   */
  function render(f, now, state, prev, since, clock, timer) {
    f.px.fill(0);
    const pal = palOf(state);
    const e = now - since;
    const collapseStart = T.swap + T.hold;
    const collapseEnd = collapseStart + T.collapse;

    if (e < T.swap) {
      // the old screen, pressed down as the wave hits it
      if (prev) {
        drawSteady(f, now, prev, clock, timer, 0);
        shiftDown(f, Math.round(T.press * easeIn(e / T.swap)));
      }
    } else if (e < collapseStart) {
      drawHero(f, now, state, pal, timer);
      // ...and the new one springs back up
      const r = (e - T.swap) / T.swap;
      if (r < 1) shiftDown(f, Math.round(T.press * (1 - easeOut(r))));
    } else if (e < collapseEnd) {
      const k = easeInOut((e - collapseStart) / T.collapse);
      const w = lerp(LAYOUT.heroW, LAYOUT.statusW, k);
      const edge = LAYOUT.heroX + w;
      drawPill(f, LAYOUT.heroX, w, pal, { sheen: sheenAt(now), dim: pulseAt(now, state) });
      // the announcement face gives way to icon + status face as the pill shrinks:
      // out before the big word can outgrow the pill, in once there's room
      const out = 1 - smooth(0.08, 0.34, k);
      const inn = smooth(0.14, 0.4, k);         // overlapping, so the pill is never empty
      const clip = [LAYOUT.heroX + 1, Math.floor(edge) - 1];
      if (out > 0) {
        const hw = heroWidth(state, timer);
        drawText(f, HERO[state].font, heroWord(state, timer), LAYOUT.heroX + (Math.max(w, hw + 6) - hw) / 2 + 0.5,
          HERO[state].base, PALETTE.white, Object.assign(heroStyle(state, pal, out), { clip: clip }));
      }
      if (inn > 0) drawStatusContent(f, state, pal, LAYOUT.heroX, w, inn, clip);
      // the time slides in from the right as the pill makes room, as the
      // firmware's timer label does
      const slide = Math.round(LAYOUT.slideIn * (1 - easeOut((e - collapseStart) / T.collapse)));
      drawRight(f, state, clock, timer, slide, Math.ceil(edge) + 2);
    } else {
      drawSteady(f, now, state, clock, timer, 0);
    }

    if (e < T.wave) drawShockwave(f, e / T.wave, pal);
  }

  function sheenAt(now, cols) {
    // a soft band of light crosses the pill every 8 s — the firmware's
    // indicator_busy loop does the same over 20 s
    const cycle = 8.0;
    return { pos: ((now % cycle) / cycle) * ((cols || COLS) + 50) - 25, width: 6, strength: 0.18 };
  }

  /* LATE FOR breathes: the pill dims by up to a third and back every 1.6 s,
     so it reads as urgent rather than as an opening. */
  function pulseAt(now, state) {
    if (state !== 'late') return 0;
    return 0.34 * (0.5 - 0.5 * Math.cos(2 * Math.PI * (now % 1.6) / 1.6));
  }

  function drawHero(f, now, state, pal, timer) {
    drawPill(f, LAYOUT.heroX, LAYOUT.heroW, pal, { sheen: sheenAt(now), dim: pulseAt(now, state) });
    const w = heroWidth(state, timer);
    drawText(f, HERO[state].font, heroWord(state, timer), LAYOUT.heroX + (LAYOUT.heroW - w) / 2 + 0.5,
      HERO[state].base, PALETTE.white, heroStyle(state, pal));
  }

  function drawSteady(f, now, state, clock, timer, slide) {
    const pal = palOf(state);
    drawPill(f, LAYOUT.statusX, LAYOUT.statusW, pal, { sheen: sheenAt(now), dim: pulseAt(now, state) });
    drawStatusContent(f, state, pal, LAYOUT.statusX, LAYOUT.statusW, 1);
    drawRight(f, state, clock, timer, slide, 0);
  }

  /*
   * What goes right of the pill (or under it, stacked): a top line in the
   * clock's face and a bottom line at half brightness. Usually the time and
   * the day; states that are about another moment show it instead.
   *   timer — { left, h, m }: seconds to go (or, for LATE, seconds since the
   *           start; for TBC, 0 once the meeting is on) and the time the
   *           state is about. Without it, the clock.
   */
  function rightText(state, clock, timer) {
    const day = DAYS[clock.dow] + ' ' + clock.date;
    const now = pad2(clock.h) + ':' + pad2(clock.m);
    const at = timer ? pad2(timer.h) + ':' + pad2(timer.m) : '';
    if (timer) {
      switch (state) {
        case 'dnd': { const c = countdownText(timer); return { top: c.mmss, bottom: c.until, blink: true }; }
        // on a call or in a meeting: how long till you're free, and when
        case 'call': case 'meeting': { const c = countdownText(timer); return { top: c.mmss, bottom: c.until, blink: true }; }
        case 'callIn': case 'busyIn':
          return { top: countdownText(timer).mmss, bottom: 'AT ' + at, blink: true };
        // tentative: a countdown to the start, then the end time once it's on
        case 'callTbc': case 'busyTbc':
          return timer.left > 0 ? { top: countdownText(timer).mmss, bottom: 'AT ' + at, blink: true }
                                : { top: now, bottom: 'TILL ' + at, blink: true };
        case 'late': return { top: 'CALL', bottom: '+' + elapsedText(timer.left), blink: false };
        case 'freeTil': return { top: at, bottom: day, blink: false };
      }
    }
    if (state === 'ooo') return { top: now, bottom: 'OFFICE', blink: true };
    return { top: now, bottom: day, blink: true };
  }

  /* Minutes and seconds since something started, rounded down: +00:00, +01:20. */
  function elapsedText(secs) {
    const s = Math.min(Math.max(Math.floor(secs + 1e-9), 0), 99 * 60 + 59);
    return pad2(Math.floor(s / 60)) + ':' + pad2(s % 60);
  }

  /* Right of the pill. `slide` pushes it right (entrance); nothing is drawn left of `minX`. */
  function drawRight(f, state, clock, timer, slide, minX) {
    const text = rightText(state, clock, timer);
    const tw = clockTextWidth(LAYOUT.timeFont, text.top);
    const bw = textWidth(LAYOUT.dateFont, text.bottom);
    const x0 = LAYOUT.clockX + slide;
    const clip = [Math.max(minX || 0, LAYOUT.clockX - 3), COLS];
    const colon = text.blink && clock.s % 2 === 1 ? 0.4 : 1;
    drawClockText(f, LAYOUT.timeFont, text.top, x0 + Math.round((LAYOUT.clockW - tw) / 2), LAYOUT.timeBase,
      PALETTE.white, { clip: clip }, colon);
    drawText(f, LAYOUT.dateFont, text.bottom, x0 + Math.round((LAYOUT.clockW - bw) / 2), LAYOUT.dateBase,
      PALETTE.white, { alpha: 0.5, clip: clip });
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
        // only the colon blinks: letters (the H in 1H05, CALL) stay lit
        const k = ch === ':' ? colonAlpha : 1;
        const o = Object.assign({}, opts, { alpha: (opts.alpha === undefined ? 1 : opts.alpha) * k });
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
   * A countdown in the clock's place and face — the firmware's timer
   * screen — with its end time beneath at half brightness (Do Not Disturb,
   * a call, a meeting), or the start time (CALL IN). Whole seconds, rounded
   * up, so it reads 30:00 as it starts and 00:01 last; 1H05 from an hour.
   */
  function countdownText(timer) {
    const pad = (n) => (n < 10 ? '0' : '') + n;
    const until = 'TILL ' + pad(timer.h) + ':' + pad(timer.m);
    const secs = Math.max(Math.ceil(timer.left - 1e-9), 0);
    // an hour or more reads as hours and minutes: 1H05
    if (secs >= 3600) return { mmss: Math.min(Math.floor(secs / 3600), 9) + 'H' + pad(Math.floor(secs % 3600 / 60)), until: until };
    return { mmss: pad(Math.floor(secs / 60)) + ':' + pad(secs % 60), until: until };
  }

  /* ------------------------------------------------------------------ *
   * Stacked layout — for small screens (960 x 540 and the like): an     *
   * 84 x 44 panel with the status pill across the top and the clock    *
   * large beneath it. Same states, colours, faces and timeline.         *
   *                                                                     *
   *   rows 0-15    status pill, cols 1-82 (icon + word, as the bar)    *
   *   rows 20-33   the time — or Do Not Disturb's countdown — 14 rows   *
   *   rows 36-42   the day — or the countdown's end time — half bright  *
   * ------------------------------------------------------------------ */
  const STACKED = {
    cols: 84, rows: 44,
    pillX: 1, pillW: 82, pillH: 16,
    bigFont: 'busy_regular_14', smallFont: 'busy_bold_7',
    bigBase: 33, smallBase: 42,
    slideIn: 24,                   // the clock rises from 24 rows down
    heroGap: 4                     // rows between the announcement's lines
  };
  /* The announcement fills the panel, a word or two per line. */
  /* A line is a string in the 14-row face, or { t, font, tracking } where
     a line won't fit the 82-LED pill in it. */
  const STACKED_HERO = {
    call: ['ON A', 'CALL'],
    free: ['FREE'],
    dnd: ['DO NOT', 'DISTURB'],
    meeting: [{ t: 'MEETING', tracking: -1 }],
    callIn: ['CALL', 'SOON'],
    busyIn: ['BUSY', 'SOON'],
    late: ['LATE', { t: 'FOR CALL', font: 'busy_bold_10' }],
    freeTil: ['FREE', { t: 'TILL {t}', font: 'busy_bold_10' }],
    callTbc: ['CALL', 'TBC'],
    busyTbc: ['BUSY', 'TBC'],
    away: ['AWAY'],
    lunch: ['LUNCH'],
    ooo: ['OUT OF', 'OFFICE']
  };
  const LINE_FONT = {
    busy_regular_14: { h: 14, depth: 2, space: 6 },
    busy_bold_10: { h: 10, depth: 1, space: undefined }
  };

  function renderStacked(f, now, state, prev, since, clock, timer) {
    f.px.fill(0);
    const S = STACKED, pal = palOf(state);
    const e = now - since;
    const collapseStart = T.swap + T.hold;
    const collapseEnd = collapseStart + T.collapse;

    if (e < T.swap) {
      if (prev) {
        drawStackedSteady(f, now, prev, clock, timer, 0);
        shiftDown(f, Math.round(T.press * easeIn(e / T.swap)));
      }
    } else if (e < collapseStart) {
      drawPill(f, S.pillX, S.pillW, pal, { sheen: sheenAt(now, f.w), h: f.h, dim: pulseAt(now, state) });
      drawStackedHero(f, state, pal, 1, null, timer);
      const r = (e - T.swap) / T.swap;
      if (r < 1) shiftDown(f, Math.round(T.press * (1 - easeOut(r))));
    } else if (e < collapseEnd) {
      // the pill draws up from the whole panel to the top band
      const k = easeInOut((e - collapseStart) / T.collapse);
      const h = Math.round(lerp(f.h, S.pillH, k));
      drawPill(f, S.pillX, S.pillW, pal, { sheen: sheenAt(now, f.w), h: h, dim: pulseAt(now, state) });
      const out = 1 - smooth(0.08, 0.34, k);
      const inn = smooth(0.14, 0.4, k);
      if (out > 0) drawStackedHero(f, state, pal, out, [1, h - 1], timer);
      if (inn > 0) drawStatusContent(f, state, pal, S.pillX, S.pillW, inn);
      // ...and the clock rises into the space it leaves
      const slide = Math.round(S.slideIn * (1 - easeOut((e - collapseStart) / T.collapse)));
      drawStackedClock(f, state, clock, timer, slide, h + 2);
    } else {
      drawStackedSteady(f, now, state, clock, timer, 0);
    }

    if (e < T.wave) drawShockwave(f, e / T.wave, pal);
  }

  function drawStackedSteady(f, now, state, clock, timer, slide) {
    const S = STACKED, pal = palOf(state);
    drawPill(f, S.pillX, S.pillW, pal, { sheen: sheenAt(now, f.w), h: S.pillH, dim: pulseAt(now, state) });
    drawStatusContent(f, state, pal, S.pillX, S.pillW, 1);
    drawStackedClock(f, state, clock, timer, slide, 0);
  }

  function drawStackedHero(f, state, pal, alpha, clipY, timer) {
    const S = STACKED;
    const at = timer ? pad2(timer.h) + ':' + pad2(timer.m) : '';
    const lines = STACKED_HERO[state]
      .map((l) => (typeof l === 'string' ? { t: l } : l))
      .map((l) => ({ t: l.t.replace('{t}', at), font: l.font || 'busy_regular_14', tracking: l.tracking || 0 }))
      .filter((l) => l.t.trim() !== '' && !/^TILL ?$/.test(l.t));
    let block = (lines.length - 1) * S.heroGap;
    for (const l of lines) block += LINE_FONT[l.font].h;
    let top = Math.round((f.h - block) / 2);
    for (const l of lines) {
      // set as the wide bar's announcement: the 14-row face with a two-step
      // shadow and trimmed spaces, the 10-row face with a one-step shadow
      const lf = LINE_FONT[l.font];
      const style = { shadow: pal.shadow, shadowDepth: lf.depth, space: lf.space, tracking: l.tracking,
        alpha: alpha, shadowAlpha: 0.9 * alpha, clipY: clipY };
      const w = textWidth(l.font, l.t, l.tracking, lf.space);
      drawText(f, l.font, l.t, S.pillX + (S.pillW - w) / 2 + 0.5, top + lf.h - 1, PALETTE.white, style);
      top += lf.h + S.heroGap;
    }
  }

  /* The time and the day — or Do Not Disturb's countdown and its end
     time — centred beneath the pill. `slide` pushes it down (entrance);
     nothing is drawn above row `minY`. */
  function drawStackedClock(f, state, clock, timer, slide, minY) {
    const S = STACKED;
    const text = rightText(state, clock, timer);
    const big = text.top, small = text.bottom;
    const clipY = [minY || 0, f.h];
    const colon = text.blink && clock.s % 2 === 1 ? 0.4 : 1;
    const bw = clockTextWidth(S.bigFont, big);
    const sw = textWidth(S.smallFont, small);
    drawClockText(f, S.bigFont, big, Math.round((f.w - bw) / 2), S.bigBase + slide, PALETTE.white,
      { clipY: clipY }, colon);
    drawText(f, S.smallFont, small, Math.round((f.w - sw) / 2), S.smallBase + slide, PALETTE.white,
      { alpha: 0.5, clipY: clipY });
  }

  root.BusyEngine = {
    STACKED: STACKED, renderStacked: renderStacked,
    clockTextWidth: clockTextWidth, drawClockText: drawClockText, ICONS: ICONS, statusContentWidth: statusContentWidth,
    COLS: COLS, ROWS: ROWS, PALETTE: PALETTE, LAYOUT: LAYOUT, WORDS: WORDS, T: T,
    STATES: Object.keys(STATE_PALETTE), palOf: palOf, heroWord: heroWord, rightText: rightText,
    Frame: Frame, render: render, setFonts: setFonts, textWidth: textWidth,
    drawPill: drawPill, drawText: drawText, drawShockwave: drawShockwave,
    hash: hash
  };
})(typeof window !== 'undefined' ? window : globalThis);
