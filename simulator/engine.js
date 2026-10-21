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
    // not here: away, at lunch, out of office, out on site
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
    call: 'call', callMuted: 'call', meeting: 'call',
    free: 'free',
    dnd: 'dnd',
    callIn: 'amber', busyIn: 'amber', late: 'amber', lateMtg: 'amber', freeTil: 'amber', callTbc: 'amber', busyTbc: 'amber',
    away: 'grey', lunch: 'grey', ooo: 'grey', onSite: 'grey', nearby: 'grey', backIn: 'grey'
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
    call: 'ON A CALL', callMuted: 'ON A CALL', free: 'FREE', dnd: 'DND',
    meeting: 'MEETING',
    callIn: 'CALL IN', busyIn: 'BUSY IN',                        // + the countdown on the right
    late: 'LATE FOR',                                            // + CALL on the right
    lateMtg: 'LATE FOR',                                         // + MTG on the right: a meeting in a room
    freeTil: 'FREE TILL',                                        // + the slot's end on the right
    callTbc: 'CALL TBC', busyTbc: 'BUSY TBC',                    // tentative: countdown, then TILL
    away: 'AWAY', lunch: 'LUNCH', ooo: 'OUT OF',                 // + OFFICE on the right
    onSite: 'OUT ON',                                            // + SITE on the right: with a client
    nearby: 'NEARBY',                                            // in the building, not at your desk (or your word: setNearbyWord)
    backIn: 'BACK IN'                                            // + the countdown on the right
  };
  /* The announcement. DO NOT DISTURB is too wide for the 14-row face, so it's
     set in the status face across the whole bar. */
  const HERO = {
    call: { word: 'ON A CALL', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    free: { word: 'FREE', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    dnd:  { word: 'DO NOT DISTURB', font: 'busy_bold_10', base: 12, depth: 1, space: undefined },
    callMuted: { word: 'ON A CALL', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    meeting:   { word: 'MEETING', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    callIn:    { word: 'CALL SOON', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    busyIn:    { word: 'BUSY SOON', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    late:      { word: 'LATE FOR CALL', font: 'busy_bold_10', base: 12, depth: 1, space: undefined },
    lateMtg:   { word: 'LATE FOR MTG', font: 'busy_bold_10', base: 12, depth: 1, space: undefined },
    freeTil:   { word: 'FREE TILL {t}', font: 'busy_bold_10', base: 12, depth: 1, space: undefined },
    callTbc:   { word: 'CALL TBC', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    busyTbc:   { word: 'BUSY TBC', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    away:      { word: 'AWAY', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    lunch:     { word: 'LUNCH', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    ooo:       { word: 'OUT OF OFFICE', font: 'busy_bold_10', base: 12, depth: 1, space: undefined },
    onSite:    { word: 'OUT ON SITE', font: 'busy_bold_10', base: 12, depth: 1, space: undefined },
    nearby: { word: 'NEARBY', font: 'busy_regular_14', base: 14, depth: 2, space: 6 },
    backIn:    { word: 'BACK IN', font: 'busy_regular_14', base: 14, depth: 2, space: 6 }
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
    // the mic, slashed, with the gap on one side as the Mac's mic.slash: muted
    callMuted: [
      '#..###...',
      '.#.####..',
      '.#.####..',
      '..#.###..',
      '..##.##..',
      '#.###.#.#',
      '#.###.#.#',
      '#..###..#',
      '.#....#..',
      '..######.',
      '....#..#.',
      '..#####.#'
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
    // someone walking: around the building
    nearby: [
      '....##...',
      '....##...',
      '.........',
      '...####..',
      '..#.##.#.',
      '.#..##..#',
      '....##...',
      '...#..#..',
      '...#...#.',
      '..#....#.',
      '.#......#'
    ],
    // into the door: back in a few minutes
    backIn: [
      '#####......',
      '#..........',
      '#...#......',
      '#..##......',
      '#.#########',
      '#.#########',
      '#..##......',
      '#...#......',
      '#..........',
      '#####......'
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
    ],
    // a map pin: somewhere else
    onSite: [
      '..#####..',
      '.#######.',
      '###...###',
      '##.....##',
      '###...###',
      '.#######.',
      '.#######.',
      '..#####..',
      '...###...',
      '...###...',
      '....#....'
    ]
  };
  ICONS.lateMtg = ICONS.late;
  ICONS.callIn = ICONS.busyIn = ICONS.soon;
  ICONS.callTbc = ICONS.busyTbc = ICONS.tbc;
  ICONS.freeTil = ICONS.free;
  const ICON_LIFT = {
    call: -1, callMuted: -1, free: 1, dnd: -1, meeting: 0, callIn: 0, busyIn: 0, late: 0, lateMtg: 0,
    freeTil: 1, callTbc: 0, busyTbc: 0, lunch: -1, away: 0, ooo: -1, onSite: -1, backIn: 0, nearby: 0
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

  /* Icon + word, centred as one unit in a pill of width w starting at x0;
     a state without an icon, the word alone. */
  const iconWidth = (state) => (ICONS[state] ? ICONS[state][0].length + LAYOUT.iconGap : 0);
  function statusContentWidth(state) {
    return iconWidth(state) + textWidth(LAYOUT.statusFont, WORDS[state]);
  }
  function drawStatusContent(f, now, state, pal, x0, w, alpha, clip) {
    const cw = statusContentWidth(state);
    const x = Math.round(x0 + (w - cw) / 2);
    if (ICONS[state]) {
      drawIcon(f, ICONS[state], x, LAYOUT.statusBase - ICON_LIFT[state], PALETTE.white, pal.shadow,
        alpha * iconAlphaAt(now, state), clip);
    }
    drawText(f, LAYOUT.statusFont, WORDS[state], x + iconWidth(state),
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
  const SETTLED = T.swap + T.hold + T.collapse;

  /*
   * Looking after the wall's screen. When nothing's going on — FREE, or
   * not here (quiet) — the same screen can stay up for hours, so:
   *   - after half an hour unchanged the LEDs ease down to about 60% of
   *     their light, over 20 s; any change brings them straight back
   *   - every 15 minutes the pill's icon and word scroll out to the left
   *     and back in from the right, as a sign does now and then
   * Calls, meetings and warnings always show at full brightness, still.
   */
  const REST = { after: 30 * 60, fade: 20, level: 0.83 };   // 0.83 before the LED gamma: about 60% of the light
  const SCROLL = { every: 15 * 60, duration: 2.4 };        // out to the left in half of it, in from the right in the other
  const QUIET = { free: true, away: true, lunch: true, ooo: true, onSite: true, nearby: true };
  const quiet = (state) => QUIET[state] === true;

  /* How bright the LEDs are, 0..1: 1 except in a quiet state that's been up
     half an hour. In hundredths, so a fade reuses its LEDs' drawings. */
  function restAt(now, state, since) {
    if (!quiet(state)) return 1;
    const k = smooth(REST.after, REST.after + REST.fade, now - since);
    return Math.round(lerp(1, REST.level, k) * 100) / 100;
  }

  /* How far the pill's icon and word are scrolled, in LEDs: 0 except for a
     moment every 15 minutes of a quiet state, once the announcement's done. */
  function scrollAt(now, state, since, pillW) {
    if (!quiet(state)) return 0;
    const s = now - since - SETTLED;
    if (s < SCROLL.every) return 0;
    const p = s % SCROLL.every, half = SCROLL.duration / 2;
    if (p >= SCROLL.duration) return 0;
    // far enough that the icon and word, shadow and all, are out of the pill
    const away = (statusContentWidth(state) + pillW) / 2 + 2;
    return p < half ? -Math.round(away * easeIn(p / half)) : Math.round(away * (1 - easeOut((p - half) / half)));
  }

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
      if (inn > 0) drawStatusContent(f, now, state, pal, LAYOUT.heroX, w, inn, clip);
      // the time slides in from the right as the pill makes room, as the
      // firmware's timer label does
      const slide = Math.round(LAYOUT.slideIn * (1 - easeOut((e - collapseStart) / T.collapse)));
      drawRight(f, state, clock, timer, slide, Math.ceil(edge) + 2);
    } else {
      drawSteady(f, now, state, clock, timer, 0, scrollAt(now, state, since, LAYOUT.statusW));
    }

    if (e < T.wave) drawShockwave(f, e / T.wave, pal);
  }

  function sheenAt(now, cols) {
    // a soft band of light crosses the pill every 8 s — the firmware's
    // indicator_busy loop does the same over 20 s
    const cycle = 8.0;
    return { pos: ((now % cycle) / cycle) * ((cols || COLS) + 50) - 25, width: 6, strength: 0.18 };
  }

  /* How far the pill is dimmed. LATE FOR (a call or a meeting) breathes: by up to a third and
     back every 1.6 s, so it reads as urgent rather than as an opening. ON A
     CALL with the mic muted glows at 45%: bright means quiet, dim means the
     room can talk. */
  function pulseAt(now, state) {
    if (state === 'callMuted') return 0.55;
    if (state !== 'late' && state !== 'lateMtg') return 0;
    return 0.34 * (0.5 - 0.5 * Math.cos(2 * Math.PI * (now % 1.6) / 1.6));
  }

  /* The muted mic flashes, slowly, so a glance tells the room it can talk:
     on 1.1 s, a 0.2 s fade, off 0.5 s, a 0.2 s fade back — every 2 s. The
     words stay put. */
  function iconAlphaAt(now, state) {
    if (state !== 'callMuted') return 1;
    const p = now % 2.0;
    if (p < 1.1) return 1;
    if (p < 1.3) return 1 - (p - 1.1) / 0.2;
    if (p < 1.8) return 0;
    return (p - 1.8) / 0.2;
  }

  function drawHero(f, now, state, pal, timer) {
    drawPill(f, LAYOUT.heroX, LAYOUT.heroW, pal, { sheen: sheenAt(now), dim: pulseAt(now, state) });
    const w = heroWidth(state, timer);
    drawText(f, HERO[state].font, heroWord(state, timer), LAYOUT.heroX + (LAYOUT.heroW - w) / 2 + 0.5,
      HERO[state].base, PALETTE.white, heroStyle(state, pal));
  }

  /* scroll: the icon and word moved this many LEDs (scrollAt), kept inside the pill. */
  function drawSteady(f, now, state, clock, timer, slide, scroll) {
    const pal = palOf(state);
    drawPill(f, LAYOUT.statusX, LAYOUT.statusW, pal, { sheen: sheenAt(now), dim: pulseAt(now, state) });
    const clip = scroll ? [LAYOUT.statusX + 1, LAYOUT.statusX + LAYOUT.statusW - 1] : undefined;
    drawStatusContent(f, now, state, pal, LAYOUT.statusX + (scroll || 0), LAYOUT.statusW, 1, clip);
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
        // on a call, in a meeting or at lunch (from the calendar): how long till you're free, or back, and when
        case 'call': case 'callMuted': case 'meeting': case 'lunch': { const c = countdownText(timer); return { top: c.mmss, bottom: c.until, blink: true }; }
        // a warning, or back in a few minutes: a countdown to it, and when
        case 'callIn': case 'busyIn': case 'backIn':
          return { top: countdownText(timer).mmss, bottom: 'AT ' + at, blink: true };
        // tentative: a countdown to the start, then the end time once it's on
        case 'callTbc': case 'busyTbc':
          return timer.left > 0 ? { top: countdownText(timer).mmss, bottom: 'AT ' + at, blink: true }
                                : { top: now, bottom: 'TILL ' + at, blink: true };
        case 'late': return { top: 'CALL', bottom: '+' + elapsedText(timer.left), blink: false };
        case 'lateMtg': return { top: 'MTG', bottom: '+' + elapsedText(timer.left), blink: false };
        case 'freeTil': return { top: at, bottom: day, blink: false };
      }
    }
    if (state === 'ooo') return { top: now, bottom: 'OFFICE', blink: true };
    if (state === 'onSite') return { top: now, bottom: 'SITE', blink: true };
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
    callMuted: ['ON A', 'CALL'],
    free: ['FREE'],
    dnd: ['DO NOT', 'DISTURB'],
    meeting: [{ t: 'MEETING', tracking: -1 }],
    callIn: ['CALL', 'SOON'],
    busyIn: ['BUSY', 'SOON'],
    late: ['LATE', { t: 'FOR CALL', font: 'busy_bold_10' }],
    lateMtg: ['LATE', { t: 'FOR MTG', font: 'busy_bold_10' }],
    freeTil: ['FREE', { t: 'TILL {t}', font: 'busy_bold_10' }],
    callTbc: ['CALL', 'TBC'],
    busyTbc: ['BUSY', 'TBC'],
    away: ['AWAY'],
    lunch: ['LUNCH'],
    ooo: ['OUT OF', 'OFFICE'],
    onSite: ['OUT ON', 'SITE'],
    nearby: ['NEARBY'],
    backIn: ['BACK', 'IN']
  };
  const LINE_FONT = {
    busy_regular_14: { h: 14, depth: 2, space: 6 },
    busy_bold_10: { h: 10, depth: 1, space: undefined }
  };

  /* ------------------------------------------------------------------ *
   * The Nearby key's word: NEARBY, or one of your own (W HOUSE) from    *
   * the app's settings. The sign says it wherever it would say NEARBY.  *
   * ------------------------------------------------------------------ */
  const NEARBY = 'NEARBY';
  /* Room for it, in LEDs: beside the walker in the pill, as ON A CALL
     has beside its mic, and beneath the walker on a Stream Deck key in
     the 5-row face (streamdeck/src/key.js). */
  const NEARBY_ROOM = { pill: 76, key: 34 };

  /* A word as the sign sets it: capitals, single spaces. */
  function signWord(word) {
    return String(word === undefined || word === null ? '' : word).trim().replace(/\s+/g, ' ').toUpperCase();
  }

  /* Why a word can't be the Nearby key's — 'characters', 'sign' or 'key',
     what it won't go on — or null if it can. */
  function nearbyProblem(word) {
    const w = signWord(word);
    if (!/^[\x20-\x7E]*$/.test(w)) return 'characters';      // the fonts have plain ASCII only
    if (iconWidth('nearby') + textWidth(LAYOUT.statusFont, w) > NEARBY_ROOM.pill) return 'sign';
    if (textWidth('busy_regular_5', w) > NEARBY_ROOM.key) return 'key';
    return null;
  }

  /* The word the sign says for `word`: NEARBY for none, or one that won't do. */
  function nearbyWordOf(word) {
    const w = signWord(word);
    return w !== '' && nearbyProblem(w) === null ? w : NEARBY;
  }

  /* Its announcement on the wide bar: the 14-row face where it fits, as
     BUSY SOON does, else the status face, as DO NOT DISTURB. */
  function nearbyHero(word) {
    return textWidth('busy_regular_14', word, 0, 6) <= LAYOUT.heroW - 6
      ? { word: word, font: 'busy_regular_14', base: 14, depth: 2, space: 6 }
      : { word: word, font: 'busy_bold_10', base: 12, depth: 1, space: undefined };
  }

  /* ...and stacked: one line in the 14-row face, set a step tighter if it
     needs it, as MEETING is; else two, broken at the space that leaves the
     longer line shortest; else one in the 10-row face. */
  function nearbyStackedHero(word) {
    const room = STACKED.pillW - 2;                  // DISTURB's width
    const wide = (t, tracking) => textWidth('busy_regular_14', t, tracking, 6);
    if (wide(word, 0) <= room) return [word];
    if (wide(word, -1) <= room) return [{ t: word, tracking: -1 }];
    let best = null, longest = Infinity;
    for (let i = word.indexOf(' '); i >= 0; i = word.indexOf(' ', i + 1)) {
      const a = word.slice(0, i), b = word.slice(i + 1);
      const l = Math.max(wide(a, 0), wide(b, 0));
      if (l <= room && l < longest) { best = [a, b]; longest = l; }
    }
    return best || [{ t: word, font: 'busy_bold_10' }];
  }

  /* Sets the word everywhere the bar says NEARBY. Call it after setFonts:
     the announcement is laid out by the word's width. */
  function setNearbyWord(word) {
    const w = nearbyWordOf(word);
    WORDS.nearby = w;
    HERO.nearby = nearbyHero(w);
    STACKED_HERO.nearby = nearbyStackedHero(w);
    return w;
  }

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
      if (inn > 0) drawStatusContent(f, now, state, pal, S.pillX, S.pillW, inn);
      // ...and the clock rises into the space it leaves
      const slide = Math.round(S.slideIn * (1 - easeOut((e - collapseStart) / T.collapse)));
      drawStackedClock(f, state, clock, timer, slide, h + 2);
    } else {
      drawStackedSteady(f, now, state, clock, timer, 0, scrollAt(now, state, since, S.pillW));
    }

    if (e < T.wave) drawShockwave(f, e / T.wave, pal);
  }

  function drawStackedSteady(f, now, state, clock, timer, slide, scroll) {
    const S = STACKED, pal = palOf(state);
    drawPill(f, S.pillX, S.pillW, pal, { sheen: sheenAt(now, f.w), h: S.pillH, dim: pulseAt(now, state) });
    const clip = scroll ? [S.pillX + 1, S.pillX + S.pillW - 1] : undefined;
    drawStatusContent(f, now, state, pal, S.pillX + (scroll || 0), S.pillW, 1, clip);
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

  /* ------------------------------------------------------------------ *
   * World clocks — local time and three more cities, while the sign    *
   * says FREE. Any mix of four layouts, each on its own timing:        *
   *   turns  — the split: the other cities in turn on the left, a      *
   *            narrower pill in the middle, local on the right         *
   *   rest   — after a while of FREE, the pill draws in to a chip and  *
   *            the four take the bar, till anything changes            *
   *   board  — now and then the bar rolls over to a four-column board *
   *   ticker — the other cities run through the pill                  *
   * world = { zones: [{ code, h, m, dow, date, dayDelta }] (local      *
   *           first), turns: { on, secs }, rest: { on, mins },         *
   *           board: { on, mins, secs }, ticker: { on, mins },         *
   *           rules: { restHolds, clash: 'wait' | 'skip',              *
   *                    tickerForScroll } }                             *
   * The app works out each city's time; this only draws it.            *
   *                                                                    *
   *   split  cols 1-31 the other cities · 35-82 the pill · 86-116 local *
   *   rest   cols 1-16 the chip · from col 19 two lines of two cities  *
   *   board  four columns of 29, each city above its time              *
   * ------------------------------------------------------------------ */
  const WORLD = {
    leftX: 1, leftW: 31, pillX: 35, pillW: 48, rightX: 86, rightW: 31,
    slideIn: 40,                       // the clocks slide in from either side as the pill draws in
    roll: 0.45,                        // the left clock rolls up to the next city
    chipW: 16, restIn: 0.8,            // resting: the pill draws in to a chip over this long
    gridX: 19, gridCell: 52, gridLabel: 14, gridGap: 3,
    boardCell: 29, boardRoll: 0.5, boardGap: 2,
    tickerSpeed: 24, tickerGap: 12     // LEDs a second; LEDs between the cities
  };
  const hhmm = (z) => pad2(z.h) + ':' + pad2(z.m);
  /* Tomorrow or yesterday there. */
  const dayMark = (z) => (z.dayDelta > 0 ? '+1' : z.dayDelta < 0 ? '-1' : '');
  const cityLine = (z) => z.code + (dayMark(z) ? ' ' + dayMark(z) : '');
  const colonOf = (clock) => (clock.s % 2 === 1 ? 0.4 : 1);
  /* The pill FREE sits in: today's, or the split's. */
  const worldPill = (world) => (world.turns.on ? { x: WORLD.pillX, w: WORLD.pillW } : { x: LAYOUT.statusX, w: LAYOUT.statusW });

  /* A clock beside the pill: the time in the clock's face, a line beneath at
     half brightness. dy moves it down (a roll), dx across (an entrance);
     nothing is drawn outside clip. */
  function drawSideClock(f, clock, top, bottom, x, w, dy, dx, alpha, clip) {
    const L = LAYOUT;
    const tw = clockTextWidth(L.timeFont, top), bw = textWidth(L.dateFont, bottom);
    drawClockText(f, L.timeFont, top, x + dx + Math.round((w - tw) / 2), L.timeBase + dy, PALETTE.white,
      { alpha: alpha, clip: clip }, colonOf(clock));
    drawText(f, L.dateFont, bottom, x + dx + Math.round((w - bw) / 2), L.dateBase + dy, PALETTE.white,
      { alpha: 0.5 * alpha, clip: clip });
  }

  /* The other cities on the left, one at a time, rolling up to the next
     every turns.secs seconds. slide pushes it left; nothing right of maxX. */
  function drawLeftTurns(f, clock, world, t, slide, maxX, alpha) {
    const others = world.zones.slice(1), n = others.length;
    if (n === 0) return;
    const dwell = world.turns.secs, tt = Math.max(t, 0);
    const i = Math.floor(tt / dwell) % n, p = tt % dwell;
    // the first city is there from the start; each after it rolls in
    const k = n < 2 || tt < dwell || p >= WORLD.roll ? 1 : easeInOut(p / WORLD.roll);
    const clip = [0, maxX];
    if (k < 1) {
      const z = others[(i - 1 + n) % n];
      drawSideClock(f, clock, hhmm(z), cityLine(z), WORLD.leftX, WORLD.leftW, -Math.round(k * (ROWS + 1)), -slide, alpha, clip);
    }
    const z = others[i];
    drawSideClock(f, clock, hhmm(z), cityLine(z), WORLD.leftX, WORLD.leftW, Math.round((1 - k) * (ROWS + 1)), -slide, alpha, clip);
  }

  /* Local time and the day, right of the split's pill. */
  function drawRightLocal(f, clock, world, slide, minX, alpha) {
    const z = world.zones[0];
    drawSideClock(f, clock, hhmm(z), DAYS[z.dow] + ' ' + z.date, WORLD.rightX, WORLD.rightW, 0, slide, alpha, [minX, COLS]);
  }

  /* FREE as the settings have it: today's layout, or the split. dx moves the
     tick and word (the scroll); empty leaves them out (the ticker's there). */
  function drawWorldBase(f, now, t, clock, world, dx, empty) {
    const pal = PALETTE.free, g = worldPill(world);
    f.px.fill(0);
    if (world.turns.on) {
      drawLeftTurns(f, clock, world, t, 0, WORLD.leftX + WORLD.leftW + 1, 1);
      drawRightLocal(f, clock, world, 0, 0, 1);
    } else {
      drawRight(f, 'free', clock, null, 0, 0);
    }
    drawPill(f, g.x, g.w, pal, { sheen: sheenAt(now) });
    if (!empty) drawStatusContent(f, now, 'free', pal, g.x + dx, g.w, 1, dx ? [g.x + 1, g.x + g.w - 1] : undefined);
  }

  /* The word's quarter-hour scroll in a pill w wide, s seconds after FREE settled: as scrollAt. */
  function worldScroll(s, w) {
    if (s < SCROLL.every) return 0;
    const p = s % SCROLL.every, half = SCROLL.duration / 2;
    if (p >= SCROLL.duration) return 0;
    const away = (statusContentWidth('free') + w) / 2 + 2;
    return p < half ? -Math.round(away * easeIn(p / half)) : Math.round(away * (1 - easeOut((p - half) / half)));
  }

  /* The ticker: how long the other cities are, and them running right to left
     through a pill at x0, w wide, t seconds in. */
  function tickerWidth(world) {
    const others = world.zones.slice(1);
    let w = 0;
    for (let i = 0; i < others.length; i++) {
      const z = others[i];
      w += textWidth('busy_bold_10', z.code + ' ') + clockTextWidth('busy_bold_10', hhmm(z));
      if (dayMark(z)) w += 2 + textWidth('busy_regular_5', dayMark(z));
      if (i < others.length - 1) w += WORLD.tickerGap;
    }
    return w;
  }
  function drawTickerText(f, world, x0, w, t) {
    const pal = PALETTE.free, clip = [x0 + 1, x0 + w - 1];
    let x = Math.round(x0 + w - t * WORLD.tickerSpeed);
    const others = world.zones.slice(1);
    for (let i = 0; i < others.length; i++) {
      const z = others[i], label = z.code + ' ', mark = dayMark(z);
      drawText(f, 'busy_bold_10', label, x, LAYOUT.statusBase, PALETTE.white,
        { shadow: pal.shadow, alpha: 0.7, shadowAlpha: 0.9 * 0.7, clip: clip });
      x += textWidth('busy_bold_10', label);
      x += drawClockText(f, 'busy_bold_10', hhmm(z), x, LAYOUT.statusBase, PALETTE.white,
        { shadow: pal.shadow, alpha: 1, shadowAlpha: 0.9, clip: clip }, 1);
      if (mark) {
        drawText(f, 'busy_regular_5', mark, x + 2, LAYOUT.statusBase - 5, PALETTE.white,
          { shadow: pal.shadow, alpha: 0.8, shadowAlpha: 0.9 * 0.8, clip: clip });
        x += 2 + textWidth('busy_regular_5', mark);
      }
      x += WORLD.tickerGap;
    }
  }
  /* Out goes the word, in run the cities, and back the word comes: how long, in a pill pillW wide. */
  const tickerSpan = (world, pillW) => SCROLL.duration + (pillW + tickerWidth(world)) / WORLD.tickerSpeed;
  /* t: seconds into the ticker; s: since FREE settled, for the left clock. */
  function drawWorldTicker(f, now, t, s, clock, world) {
    const g = worldPill(world), half = SCROLL.duration / 2;
    const run = (g.w + tickerWidth(world)) / WORLD.tickerSpeed;
    const away = (statusContentWidth('free') + g.w) / 2 + 2;
    if (t < half) { drawWorldBase(f, now, s, clock, world, -Math.round(away * easeIn(t / half)), false); return; }
    if (t >= half + run) {
      drawWorldBase(f, now, s, clock, world, Math.round(away * (1 - easeOut(Math.min((t - half - run) / half, 1)))), false);
      return;
    }
    drawWorldBase(f, now, s, clock, world, 0, true);
    drawTickerText(f, world, g.x, g.w, t - half);
  }

  /* The board: four columns, each city above its time, local in FREE's green. */
  function drawWorldBoard(f, clock, world) {
    f.px.fill(0);
    const cell = WORLD.boardCell, n = Math.min(world.zones.length, 4);
    const x0 = 1 + Math.round((4 - n) * cell / 2);      // fewer cities: the columns centred
    for (let i = 0; i < n; i++) {
      const z = world.zones[i], cx = x0 + i * cell, label = cityLine(z);
      const lw = textWidth('busy_regular_5', label);
      drawText(f, 'busy_regular_5', label, cx + Math.round((cell - lw) / 2), 5, i === 0 ? PALETTE.free.top : PALETTE.white,
        { alpha: i === 0 ? 1 : 0.55 });
      const tw = clockTextWidth('busy_regular_7', hhmm(z));
      drawClockText(f, 'busy_regular_7', hhmm(z), cx + Math.round((cell - tw) / 2) + 1, 14, PALETTE.white, {}, colonOf(clock));
    }
  }
  /* Frame a rolling up and out, b following from below, gap rows behind. */
  function rollFrames(f, a, b, off, gap) {
    for (let y = 0; y < f.h; y++) {
      const src = y + off;
      for (let x = 0; x < f.w; x++) {
        if (src < f.h) f.set(x, y, a.get(x, src));
        else if (src - f.h - gap >= 0) f.set(x, y, b.get(x, src - f.h - gap));
        else f.set(x, y, [0, 0, 0]);
      }
    }
  }
  const boardSpan = (world) => 2 * WORLD.boardRoll + world.board.secs;
  /* t seconds into the board: up it rolls over `under`, stays, and rolls away again. */
  function drawWorldBoardOn(f, t, world, face, under) {
    const R = WORLD.boardRoll, secs = world.board.secs, gap = WORLD.boardGap, span = f.h + gap;
    if (t >= R && t < R + secs) { face(f); return; }
    const a = new Frame(f.w, f.h), b = new Frame(f.w, f.h);
    if (t < R) {
      under(a); face(b);
      rollFrames(f, a, b, Math.round(easeInOut(t / R) * span), gap);
    } else {
      face(a); under(b);
      rollFrames(f, a, b, Math.round(easeInOut(Math.min((t - R - secs) / R, 1)) * span), gap);
    }
  }

  /* Resting's grid: two lines of two, each city then its time; nothing left of minX. */
  function drawWorldGrid(f, clock, world, x0, alpha, minX) {
    // two cities or fewer: one line, across the middle
    const bases = world.zones.length > 2 ? [6, 15] : [11], clip = [minX, COLS];
    for (let i = 0; i < world.zones.length && i < 4; i++) {
      const z = world.zones[i], cx = x0 + (i % 2) * WORLD.gridCell, base = bases[Math.floor(i / 2)];
      drawText(f, 'busy_regular_5', z.code, cx, base, i === 0 ? PALETTE.free.top : PALETTE.white,
        { alpha: (i === 0 ? 1 : 0.55) * alpha, clip: clip });
      drawClockText(f, 'busy_bold_7', hhmm(z), cx + WORLD.gridLabel + WORLD.gridGap, base, PALETTE.white,
        { alpha: alpha, clip: clip }, colonOf(clock));
    }
  }
  /* Resting, k of the way there: the pill slides left and draws in to the
     chip, what was beside it gives way, and the four slide in behind. */
  function drawWorldRest(f, now, t, clock, world, k) {
    const pal = PALETTE.free, L = LAYOUT, ek = easeInOut(k), split = world.turns.on;
    const fromX = split ? WORLD.pillX : L.statusX, fromW = split ? WORLD.pillW : L.statusW;
    f.px.fill(0);
    const outA = 1 - smooth(0, 0.35, k), go = Math.round(20 * smooth(0, 0.4, k));
    if (outA > 0) {
      const z = world.zones[0];
      drawSideClock(f, clock, hhmm(z), DAYS[z.dow] + ' ' + z.date, split ? WORLD.rightX : L.clockX, split ? WORLD.rightW : L.clockW,
        0, go, outA, [0, COLS]);
      if (split) drawLeftTurns(f, clock, world, t, go, WORLD.leftX + WORLD.leftW + 1, outA);
    }
    const x = lerp(fromX, L.statusX, ek), w = lerp(fromW, WORLD.chipW, ek);
    drawPill(f, x, w, pal, { sheen: sheenAt(now) });
    const ix = Math.round(lerp(Math.round(fromX + (fromW - statusContentWidth('free')) / 2),
      L.statusX + Math.round((WORLD.chipW - ICONS.free[0].length) / 2), ek));
    const clip = [Math.ceil(x) + 1, Math.floor(x + w) - 1];
    drawIcon(f, ICONS.free, ix, L.statusBase - ICON_LIFT.free, PALETTE.white, pal.shadow, 1, clip);
    const wordA = 1 - smooth(0, 0.35, k);
    if (wordA > 0) {
      drawText(f, L.statusFont, WORDS.free, ix + iconWidth('free'), L.statusBase, PALETTE.white,
        { shadow: pal.shadow, alpha: wordA, shadowAlpha: 0.9 * wordA, clip: clip });
    }
    const inA = smooth(0.4, 1, k);
    if (inA > 0) drawWorldGrid(f, clock, world, WORLD.gridX + Math.round(30 * (1 - easeOut(k))), inA, Math.round(x + w) + 2);
  }

  /* A call has just ended (e seconds into FREE): the announcement across the
     bar, then, with the split on, it draws in to the middle as both clocks
     slide back from the sides. */
  function drawWorldSettle(f, now, e, prev, clock, world) {
    const cs = T.swap + T.hold;
    if (!world.turns.on || e < cs) { render(f, now, 'free', prev, now - e, clock, null); return; }
    const pal = PALETTE.free, L = LAYOUT;
    f.px.fill(0);
    const p = Math.min((e - cs) / T.collapse, 1), k = easeInOut(p);
    const x = lerp(L.heroX, WORLD.pillX, k), w = lerp(L.heroW, WORLD.pillW, k);
    drawPill(f, x, w, pal, { sheen: sheenAt(now) });
    const clip = [Math.ceil(x) + 1, Math.floor(x + w) - 1];
    const fadeOut = 1 - smooth(0.08, 0.34, k), fadeIn = smooth(0.14, 0.4, k);
    if (fadeOut > 0) {
      const hw = heroWidth('free', null);
      drawText(f, HERO.free.font, heroWord('free', null), x + (Math.max(w, hw + 6) - hw) / 2 + 0.5, HERO.free.base,
        PALETTE.white, Object.assign(heroStyle('free', pal, fadeOut), { clip: clip }));
    }
    if (fadeIn > 0) drawStatusContent(f, now, 'free', pal, x, w, fadeIn, clip);
    const slide = Math.round(WORLD.slideIn * (1 - easeOut(p))), sideA = smooth(0.3, 0.75, p);
    if (sideA > 0) {
      drawRightLocal(f, clock, world, slide, Math.ceil(x + w) + 2, sideA);
      drawLeftTurns(f, clock, world, 0, slide, Math.floor(x) - 1, sideA);
    }
  }

  /*
   * When the board and the ticker show, up to s seconds after FREE settled,
   * and when it rests. The ticker needs the pill, so it never runs over the
   * chip; the board can, if the rules let it. One at a time: when two fall
   * together the second waits for the first (or is skipped), and nothing
   * starts that would run into the rest.
   */
  function worldSchedule(world, s, pillW) {
    const R = world.rules;
    const rest = world.rest.on ? world.rest.mins * 60 : Infinity;
    const raw = [], tickerFor = tickerSpan(world, pillW), boardFor = boardSpan(world);
    if (world.ticker.on && world.ticker.mins > 0) {
      for (let at = world.ticker.mins * 60; at <= s && at < rest; at += world.ticker.mins * 60) {
        raw.push({ kind: 'ticker', due: at, dur: tickerFor });
      }
    }
    if (world.board.on && world.board.mins > 0) {
      for (let at = world.board.mins * 60; at <= s && (!R.restHolds || at < rest); at += world.board.mins * 60) {
        raw.push({ kind: 'board', due: at, dur: boardFor });
      }
    }
    raw.sort((a, b) => a.due - b.due || (a.kind === 'ticker' ? -1 : 1));
    const events = [];
    let clear = 0;
    for (const e of raw) {
      if (R.clash === 'skip' && e.due < clear) continue;
      const at = Math.max(e.due, clear);
      const runsIntoRest = at < rest && at + e.dur > rest;
      if (runsIntoRest || (e.kind === 'ticker' && at >= rest)) continue;
      events.push({ kind: e.kind, at: at, dur: e.dur });
      clear = at + e.dur + 1;
    }
    return { events: events, rest: rest };
  }

  /* The bar s seconds after FREE settled (below 0: still settling, after prev), and what it's showing. */
  function worldAt(f, now, s, clock, world, prev) {
    if (s < 0) { drawWorldSettle(f, now, s + SETTLED, prev, clock, world); return 'settle'; }
    const sch = worldSchedule(world, s, worldPill(world).w);
    const resting = s >= sch.rest, restK = Math.min((s - sch.rest) / WORLD.restIn, 1);
    for (const e of sch.events) {
      if (s < e.at || s >= e.at + e.dur) continue;
      if (e.kind === 'board') {
        drawWorldBoardOn(f, s - e.at, world, (g) => drawWorldBoard(g, clock, world),
          resting ? (g) => drawWorldRest(g, now, s, clock, world, restK) : (g) => drawWorldBase(g, now, s, clock, world, 0, false));
      } else {
        drawWorldTicker(f, now, s - e.at, s, clock, world);
      }
      return e.kind;
    }
    if (resting) { drawWorldRest(f, now, s, clock, world, restK); return 'rest'; }
    const dx = world.ticker.on && world.rules.tickerForScroll ? 0 : worldScroll(s, worldPill(world).w);
    drawWorldBase(f, now, s, clock, world, dx, false);
    return dx ? 'scroll' : 'base';
  }

  /*
   * The scene with world clocks on: as render, but FREE as the settings have
   * it, and, as FREE gives way, its face pressed down as the wave hits it.
   * prevFor: how long FREE had been up when it ended.
   */
  function renderWorld(f, now, state, prev, since, clock, timer, world, prevFor) {
    const e = now - since;
    if (state === 'free') { f.px.fill(0); worldAt(f, now, e - SETTLED, clock, world, prev); return; }
    if (prev === 'free' && e < T.swap) {
      f.px.fill(0);
      worldAt(f, now, prevFor - SETTLED, clock, world, null);
      shiftDown(f, Math.round(T.press * easeIn(e / T.swap)));
      drawShockwave(f, e / T.wave, palOf(state));
      return;
    }
    render(f, now, state, prev, since, clock, timer);
  }

  /* ---- the same, stacked: the big clock stays local; the day line beneath takes each city in turn ---- */

  /* The day line: the day (i = 0) or a city and its time. */
  function drawStackedTurn(f, clock, world, i, dy) {
    const S = STACKED, z = world.zones[i], font = S.smallFont, base = S.smallBase + dy, clipY = [35, S.rows];
    if (i === 0) {
      const d = DAYS[z.dow] + ' ' + z.date, w = textWidth(font, d);
      drawText(f, font, d, Math.round((S.cols - w) / 2), base, PALETTE.white, { alpha: 0.5, clipY: clipY });
      return;
    }
    const mark = dayMark(z), lw = textWidth(font, z.code + ' '), tw = clockTextWidth(font, hhmm(z));
    const mw = mark ? 2 + textWidth('busy_regular_5', mark) : 0;
    const x = Math.round((S.cols - lw - tw - mw) / 2);
    drawText(f, font, z.code + ' ', x, base, PALETTE.white, { alpha: 0.5, clipY: clipY });
    drawClockText(f, font, hhmm(z), x + lw, base, PALETTE.white, { alpha: 0.8, clipY: clipY }, colonOf(clock));
    if (mark) drawText(f, 'busy_regular_5', mark, x + lw + tw + 2, base - 2, PALETTE.white, { alpha: 0.5, clipY: clipY });
  }
  function drawStackedWorldBase(f, now, t, clock, world, dx, empty) {
    const S = STACKED, pal = PALETTE.free;
    f.px.fill(0);
    drawPill(f, S.pillX, S.pillW, pal, { sheen: sheenAt(now, f.w), h: S.pillH });
    if (!empty) drawStatusContent(f, now, 'free', pal, S.pillX + dx, S.pillW, 1, dx ? [S.pillX + 1, S.pillX + S.pillW - 1] : undefined);
    if (!world.turns.on) { drawStackedClock(f, 'free', clock, null, 0, 0); return; }
    const big = pad2(clock.h) + ':' + pad2(clock.m), bw = clockTextWidth(S.bigFont, big);
    drawClockText(f, S.bigFont, big, Math.round((f.w - bw) / 2), S.bigBase, PALETTE.white, {}, colonOf(clock));
    const n = world.zones.length;
    if (n === 0) return;
    const dwell = world.turns.secs, tt = Math.max(t, 0);
    const i = Math.floor(tt / dwell) % n, p = tt % dwell;
    const k = n < 2 || tt < dwell || p >= WORLD.roll ? 1 : easeInOut(p / WORLD.roll);
    if (k < 1) drawStackedTurn(f, clock, world, (i - 1 + n) % n, -Math.round(k * 10));
    drawStackedTurn(f, clock, world, i, Math.round((1 - k) * 10));
  }
  function drawStackedWorldTicker(f, now, t, s, clock, world) {
    const S = STACKED, half = SCROLL.duration / 2;
    const run = (S.pillW + tickerWidth(world)) / WORLD.tickerSpeed;
    const away = (statusContentWidth('free') + S.pillW) / 2 + 2;
    if (t < half) { drawStackedWorldBase(f, now, s, clock, world, -Math.round(away * easeIn(t / half)), false); return; }
    if (t >= half + run) {
      drawStackedWorldBase(f, now, s, clock, world, Math.round(away * (1 - easeOut(Math.min((t - half - run) / half, 1)))), false);
      return;
    }
    drawStackedWorldBase(f, now, s, clock, world, 0, true);
    drawTickerText(f, world, S.pillX, S.pillW, t - half);
  }
  /* The board, stacked: four rows, a departures board. */
  function drawStackedWorldBoard(f, clock, world) {
    f.px.fill(0);
    const font = 'busy_bold_7', bases = [9, 20, 31, 42], n = Math.min(world.zones.length, 4);
    const dy = Math.round((4 - n) * 11 / 2);           // fewer cities: the rows centred
    for (let i = 0; i < n; i++) {
      const z = world.zones[i], base = bases[i] + dy, mark = dayMark(z);
      drawText(f, font, z.code, 8, base, i === 0 ? PALETTE.free.top : PALETTE.white, { alpha: i === 0 ? 1 : 0.55 });
      if (mark) drawText(f, 'busy_regular_5', mark, 33, base, PALETTE.white, { alpha: 0.5 });
      const tw = clockTextWidth(font, hhmm(z));
      drawClockText(f, font, hhmm(z), STACKED.cols - 7 - tw, base, PALETTE.white, {}, colonOf(clock));
    }
  }
  /* Resting, stacked: the chip and the local time share the top band, the
     other three beneath with their day; the big clock rises from behind the pill. */
  function drawStackedWorldRest(f, now, clock, world, k) {
    const S = STACKED, pal = PALETTE.free, L = LAYOUT, ek = easeInOut(k), z = world.zones[0];
    f.px.fill(0);
    const big = hhmm(z), bw = clockTextWidth(S.bigFont, big);
    const bx = Math.round(lerp((S.cols - bw) / 2, 18 + (66 - bw) / 2, ek)), bb = Math.round(lerp(S.bigBase, 14, ek));
    drawClockText(f, S.bigFont, big, bx, bb, PALETTE.white, {}, colonOf(clock));
    const dayA = 1 - smooth(0, 0.3, k);
    if (dayA > 0) {
      const d = DAYS[z.dow] + ' ' + z.date, dw = textWidth(S.smallFont, d);
      drawText(f, S.smallFont, d, Math.round((S.cols - dw) / 2), S.smallBase, PALETTE.white, { alpha: 0.5 * dayA });
    }
    const inA = smooth(0.35, 1, k), dy = Math.round(18 * (1 - easeOut(k))), clipY = [18, S.rows];
    if (inA > 0) {
      const off = (4 - Math.min(world.zones.length, 4)) * 14;   // fewer cities: the columns centred
      for (let j = 1; j < world.zones.length && j < 4; j++) {
        const zz = world.zones[j], cx = off + (j - 1) * 28, cell = 28;
        const lw = textWidth('busy_regular_5', zz.code);
        drawText(f, 'busy_regular_5', zz.code, cx + Math.round((cell - lw) / 2), 26 + dy, PALETTE.white, { alpha: 0.55 * inA, clipY: clipY });
        const tw = clockTextWidth('busy_regular_7', hhmm(zz));
        drawClockText(f, 'busy_regular_7', hhmm(zz), cx + Math.round((cell - tw) / 2) + 1, 35 + dy, PALETTE.white,
          { alpha: inA, clipY: clipY }, colonOf(clock));
        const d = DAYS[zz.dow], dw = textWidth('busy_regular_5', d);
        drawText(f, 'busy_regular_5', d, cx + Math.round((cell - dw) / 2), 42 + dy, PALETTE.white,
          { alpha: (zz.dayDelta ? 0.9 : 0.4) * inA, clipY: clipY });
      }
    }
    const w = lerp(S.pillW, WORLD.chipW, ek);
    drawPill(f, S.pillX, w, pal, { sheen: sheenAt(now, f.w), h: S.pillH });
    const ix = Math.round(lerp(Math.round(S.pillX + (S.pillW - statusContentWidth('free')) / 2),
      S.pillX + Math.round((WORLD.chipW - ICONS.free[0].length) / 2), ek));
    drawIcon(f, ICONS.free, ix, L.statusBase - ICON_LIFT.free, PALETTE.white, pal.shadow, 1);
    const wordA = 1 - smooth(0, 0.35, k);
    if (wordA > 0) {
      drawText(f, L.statusFont, WORDS.free, ix + iconWidth('free'), L.statusBase, PALETTE.white,
        { shadow: pal.shadow, alpha: wordA, shadowAlpha: 0.9 * wordA, clip: [S.pillX + 1, Math.floor(S.pillX + w) - 1] });
    }
  }
  function worldAtStacked(f, now, s, clock, world, prev) {
    const S = STACKED;
    if (s < 0) { renderStacked(f, now, 'free', prev, now - (s + SETTLED), clock, null); return 'settle'; }
    const sch = worldSchedule(world, s, S.pillW);
    const resting = s >= sch.rest, restK = Math.min((s - sch.rest) / WORLD.restIn, 1);
    for (const e of sch.events) {
      if (s < e.at || s >= e.at + e.dur) continue;
      if (e.kind === 'board') {
        drawWorldBoardOn(f, s - e.at, world, (g) => drawStackedWorldBoard(g, clock, world),
          resting ? (g) => drawStackedWorldRest(g, now, clock, world, restK) : (g) => drawStackedWorldBase(g, now, s, clock, world, 0, false));
      } else {
        drawStackedWorldTicker(f, now, s - e.at, s, clock, world);
      }
      return e.kind;
    }
    if (resting) { drawStackedWorldRest(f, now, clock, world, restK); return 'rest'; }
    const dx = world.ticker.on && world.rules.tickerForScroll ? 0 : worldScroll(s, S.pillW);
    drawStackedWorldBase(f, now, s, clock, world, dx, false);
    return dx ? 'scroll' : 'base';
  }
  function renderStackedWorld(f, now, state, prev, since, clock, timer, world, prevFor) {
    const e = now - since;
    if (state === 'free') { f.px.fill(0); worldAtStacked(f, now, e - SETTLED, clock, world, prev); return; }
    if (prev === 'free' && e < T.swap) {
      f.px.fill(0);
      worldAtStacked(f, now, prevFor - SETTLED, clock, world, null);
      shiftDown(f, Math.round(T.press * easeIn(e / T.swap)));
      drawShockwave(f, e / T.wave, palOf(state));
      return;
    }
    renderStacked(f, now, state, prev, since, clock, timer);
  }

  root.BusyEngine = {
    STACKED: STACKED, renderStacked: renderStacked,
    clockTextWidth: clockTextWidth, drawClockText: drawClockText, ICONS: ICONS, statusContentWidth: statusContentWidth,
    COLS: COLS, ROWS: ROWS, PALETTE: PALETTE, LAYOUT: LAYOUT, WORDS: WORDS, T: T,
    STATES: Object.keys(STATE_PALETTE), palOf: palOf, heroWord: heroWord, rightText: rightText,
    Frame: Frame, render: render, setFonts: setFonts, textWidth: textWidth,
    drawPill: drawPill, drawText: drawText, drawShockwave: drawShockwave, sheenAt: sheenAt,
    hash: hash,
    REST: REST, SCROLL: SCROLL, SETTLED: SETTLED, quiet: quiet, restAt: restAt, scrollAt: scrollAt,
    NEARBY: NEARBY, signWord: signWord, nearbyProblem: nearbyProblem, nearbyWordOf: nearbyWordOf, setNearbyWord: setNearbyWord,
    WORLD: WORLD, renderWorld: renderWorld, renderStackedWorld: renderStackedWorld, worldAt: worldAt, worldAtStacked: worldAtStacked,
    worldSchedule: worldSchedule
  };
})(typeof window !== 'undefined' ? window : globalThis);
