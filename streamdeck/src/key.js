/*
 * The Status key's picture: what the bar says, drawn by the bar's own
 * engine and fonts (simulator/engine.js, fonts.js) on a 36 x 36 LED panel,
 * and lit the way the app lights the wall (Sources/Bar/LEDRaster.swift).
 *
 * The lit pill holds the status in a word or two, cut to fit; beneath it,
 * white on black, what the right of the bar shows — the countdown, or the
 * time with its colon blinking. The Mute and Leave keys are drawn the same
 * way: an icon in the pill, LIVE, MUTED or LEAVE beneath.
 */
import '../../simulator/fonts.js';
import '../../simulator/engine.js';
import { png } from './png.js';

const E = globalThis.BusyEngine;
E.setFonts(globalThis.BUSY_FONTS);

export const N = 36;            // LEDs across and down
export const SIZE = 144;        // px: Stream Deck shows it at 72 to 144
const P = SIZE / N;             // px per LED
const PILL_H = 22;              // rows of lit pill
const DETAIL_BASE = 32;         // baseline of the line under it
const WHITE = E.PALETTE.white;

/* The bar's words, cut to fit the pill in the 7-row face. */
const WORDS = {
  call: ['ON A', 'CALL'], callMuted: ['ON A', 'CALL'], meeting: ['IN A', 'MTG'], free: ['FREE'], dnd: ['DND'],
  callIn: ['CALL', 'IN'], busyIn: ['BUSY', 'IN'], late: ['LATE'], freeTil: ['FREE', 'TILL'],
  callTbc: ['CALL', 'TBC'], busyTbc: ['BUSY', 'TBC'], away: ['AWAY'], lunch: ['LUNCH'], ooo: ['OOO']
};
export const STATES = Object.keys(WORDS);

const pad2 = (n) => (n < 10 ? '0' : '') + n;

/* The engine's clock reading, in this Mac's time zone. */
export function clockOf(date) {
  return { h: date.getHours(), m: date.getMinutes(), s: date.getSeconds(), ms: date.getMilliseconds(),
    dow: date.getDay(), date: date.getDate() };
}

/* The engine's timer from the app's moment, as BarMoment.timer(at:) makes it. */
export function timerOf(moment, now) {
  if (!moment) return null;
  const at = new Date(moment.at);
  const left = moment.kind === 'countdown' ? (moment.at - now) / 1000
    : moment.kind === 'countUp' ? (now - moment.at) / 1000 : 0;
  return { left: left, h: at.getHours(), m: at.getMinutes() };
}

/* What the key says: the pill's lines, and the line beneath them — the
   bar's right-hand top line, except where the pill can't carry the rest. */
export function keyText(state, clock, timer) {
  const right = E.rightText(state, clock, timer);
  if (state === 'late' && timer) return { lines: WORDS.late, detail: right.bottom, blink: false };        // +01:20
  if ((state === 'callTbc' || state === 'busyTbc') && timer && timer.left <= 0) {
    return { lines: ['TBC', 'TILL'], detail: pad2(timer.h) + ':' + pad2(timer.m), blink: false };   // on now: till when
  }
  return { lines: WORDS[state], detail: right.top, blink: right.blink };
}

/* Lines centred in the pill: the 7-row bold face, or the regular one where a line won't fit. */
function drawLines(f, lines, pal, alpha) {
  const font = lines.every((l) => E.textWidth('busy_bold_7', l) <= N - 2) ? 'busy_bold_7' : 'busy_regular_7';
  const gap = 3;
  let base = Math.round((PILL_H - (lines.length * 7 + (lines.length - 1) * gap)) / 2) + 6;
  for (const line of lines) {
    E.drawText(f, font, line, Math.round((N - E.textWidth(font, line)) / 2), base, WHITE,
      { shadow: pal.shadow, alpha: alpha, shadowAlpha: 0.9 * alpha });
    base += 7 + gap;
  }
}

/*
 * The key as LEDs at `date`. `view` is the app's status
 * ({ state, moment, dnd }), or null when the app isn't answering.
 */
export function drawKey(view, date) {
  const f = new E.Frame(N, N);
  if (!view || !WORDS[view.state]) {
    // the app isn't answering (or says something this key doesn't know): a dark pill
    drawLines(f, view ? ['?'] : ['APP', 'OFF'], E.palOf('away'), 0.5);
    return f;
  }
  const clock = clockOf(date);
  const text = keyText(view.state, clock, timerOf(view.moment, date.getTime()));
  const pal = E.palOf(view.state);
  // LATE breathes on the bar; at one picture a second, it blinks. Muted on a call, it glows, as the bar does.
  const dim = view.state === 'callMuted' ? 0.55 : view.state === 'late' && clock.s % 2 === 1 ? 0.34 : 0;
  E.drawPill(f, 0, N, pal, { h: PILL_H, dim: dim });
  drawLines(f, text.lines, pal, 1);
  const font = ['busy_bold_7', 'busy_regular_7'].find((fn) => E.clockTextWidth(fn, text.detail) <= N - 2) || 'busy_regular_5';
  E.drawClockText(f, font, text.detail, Math.round((N - E.clockTextWidth(font, text.detail)) / 2), DETAIL_BASE, WHITE, {},
    text.blink && clock.s % 2 === 1 ? 0.4 : 1);
  return f;
}

/* The Mute and Leave keys: an icon in the lit pill, a word beneath it.
   The bar's own mic, drawn bigger for a key a finger's width across; the
   slashed one cut on one side as the bar's is; the handset laid down, as
   every meeting app draws "leave". */
export const KEY_ICONS = {
  mic: [
    '.....###.....',
    '....#####....',
    '...#######...',
    '...#######...',
    '...#######...',
    '...#######...',
    '...#######...',
    '#..#######..#',
    '#..#######..#',
    '#...#####...#',
    '.#...###...#.',
    '..#.......#..',
    '...#######...',
    '......#......',
    '......#......',
    '....#####....'
  ],
  micMuted: [
    '#....###.....',
    '.#..#####....',
    '..#.######...',
    '..#.######...',
    '...#.#####...',
    '...##.####...',
    '...###.###...',
    '#..####.##..#',
    '#..####.##..#',
    '#...####....#',
    '.#...####..#.',
    '..#......#...',
    '...######.#..',
    '......#....#.',
    '......#.....#',
    '....#####....'
  ],
  handset: [
    '....#######....',
    '..###########..',
    '.#############.',
    '###.........###',
    '###.........###',
    '.##.........##.'
  ]
};

/* What the Mute key shows, from the app's status: 'off' when it isn't
   answering, 'idle' outside a meeting, else 'live', 'muted' or 'unknown'. */
export function muteFace(view) {
  if (!view) return 'off';
  if (!view.meeting) return 'idle';
  return view.meeting.muted === true ? 'muted' : view.meeting.muted === false ? 'live' : 'unknown';
}

/* What the Leave key shows: 'active' while there's a meeting to leave. */
export function leaveFace(view) {
  if (!view) return 'off';
  return view.meeting && view.meeting.canLeave ? 'active' : 'idle';
}

const FACES = {
  'mute:live': { state: 'free', icon: 'mic', word: 'LIVE' },
  'mute:muted': { state: 'call', icon: 'micMuted', word: 'MUTED' },
  'mute:unknown': { state: 'away', icon: 'mic', word: 'MIC ?' },
  'mute:idle': { state: 'away', icon: 'mic', word: '', dim: 0.62 },
  'leave:active': { state: 'call', icon: 'handset', word: 'LEAVE' },
  'leave:idle': { state: 'away', icon: 'handset', word: '', dim: 0.62 }
};
export const MEETING_FACES = Object.keys(FACES);

/* An icon's rows centred across the key, white with the pill's hard shadow,
   as the bar draws its icons. */
function drawIcon(f, rows, top, shadow, alpha) {
  const x0 = Math.round((N - rows[0].length) / 2);
  for (const pass of [{ d: 1, c: shadow, a: 0.9 * alpha }, { d: 0, c: WHITE, a: alpha }]) {
    rows.forEach((row, r) => {
      for (let c = 0; c < row.length; c++) if (row[c] === '#') f.blend(x0 + c + pass.d, top + r + pass.d, pass.c, pass.a);
    });
  }
}

/* A Mute or Leave key as LEDs; `hold` says HOLD under the pill. */
export function drawMeetingKey(kind, face, hold) {
  const f = new E.Frame(N, N);
  const spec = FACES[kind + ':' + face];
  if (!spec) {
    drawLines(f, ['APP', 'OFF'], E.palOf('away'), 0.5);
    return f;
  }
  const pal = E.palOf(spec.state);
  E.drawPill(f, 0, N, pal, { h: PILL_H, dim: spec.dim || 0 });
  const rows = KEY_ICONS[spec.icon];
  drawIcon(f, rows, Math.round((PILL_H - rows.length) / 2), pal.shadow, spec.dim ? 0.45 : 1);
  const word = hold ? 'HOLD' : spec.word;
  if (word) {
    // one face for every word, so LIVE and MUTED match: MUTED is too wide for the bold one
    E.drawText(f, 'busy_regular_7', word, Math.round((N - E.textWidth('busy_regular_7', word)) / 2), DETAIL_BASE, WHITE, {});
  }
  return f;
}

/* Just a lit pill with words in it, in a state's colours: the key's
   picture before the plugin has drawn one (tools/icons.js). */
export function drawLabel(lines, state) {
  const f = new E.Frame(N, N);
  E.drawPill(f, 0, N, E.palOf(state), { h: PILL_H });
  drawLines(f, lines, E.palOf(state), 1);
  return f;
}

/* LEDRaster's look: rounded dots at 85% of the pitch, flat to 30% of the
   cell then shading to 85% by 70%; gamma 1.25; a barely-lit floor; and a
   faint glass, lighter at the top and shaded toward the bottom. */
const LOOK = { ledFill: 0.85, ledRadius: 0.353, unlit: [0.018, 0.018, 0.02], gamma: 1.25, glassTop: 0.05, glassBottom: 0.12 };

const MASK = (() => {
  const m = new Float32Array(P * P), led = P * LOOK.ledFill, r = led * LOOK.ledRadius, half = led / 2;
  for (let y = 0; y < P; y++) for (let x = 0; x < P; x++) {
    const px = x + 0.5 - P / 2, py = y + 0.5 - P / 2;
    const qx = Math.abs(px) - (half - r), qy = Math.abs(py) - (half - r);
    const d = Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
    const cover = Math.min(Math.max(0.5 - d, 0), 1);
    const dist = Math.hypot(px, py) / P;
    m[y * P + x] = cover * (dist <= 0.3 ? 1 : Math.max(0.85, 1 - 0.15 * (dist - 0.3) / 0.4));
  }
  return m;
})();

const GLASS = Array.from({ length: SIZE }, (_, y) => {
  const t = (y + 0.5) / SIZE;
  if (t <= 0.38) { const a = LOOK.glassTop * (1 - t / 0.38); return { keep: 1 - a, add: a }; }
  return { keep: 1 - LOOK.glassBottom * (t - 0.38) / 0.62, add: 0 };
});

/* The frame as 144 x 144 RGB pixels. */
export function paint(frame) {
  const rgb = Buffer.alloc(SIZE * SIZE * 3);
  const lit = new Float32Array(N * N * 3);
  for (let i = 0; i < N * N * 3; i++) {
    const u = LOOK.unlit[i % 3];
    lit[i] = u + Math.pow(Math.max(frame.px[i], 0), LOOK.gamma) * (1 - u);
  }
  for (let y = 0; y < SIZE; y++) {
    const g = GLASS[y], row = Math.floor(y / P) * N;
    for (let x = 0; x < SIZE; x++) {
      const led = (row + Math.floor(x / P)) * 3, m = MASK[(y % P) * P + (x % P)], o = (y * SIZE + x) * 3;
      for (let k = 0; k < 3; k++) rgb[o + k] = Math.round(255 * Math.min(1, lit[led + k] * m * g.keep + g.add));
    }
  }
  return rgb;
}

const dataURL = (frame) => 'data:image/png;base64,' + png(SIZE, SIZE, paint(frame)).toString('base64');

/* The key's picture as Stream Deck takes it. */
export function keyImage(view, date) {
  return dataURL(drawKey(view, date));
}

/* A Mute or Leave key's picture; the same face gives the same picture. */
const meetingImages = new Map();
export function meetingKeyImage(kind, face, hold) {
  const key = kind + ':' + face + (hold ? ':hold' : '');
  if (!meetingImages.has(key)) meetingImages.set(key, dataURL(drawMeetingKey(kind, face, hold)));
  return meetingImages.get(key);
}
