// Draws the Corne's right-half dashboard (design 1, "stacked zones").
//
// The Mac app runs this in JavaScriptCore and streams the packed frame to the keyboard, so this
// file is the single definition of what the screen shows: change copy or layout here and the
// keyboard follows without a firmware flash. preview.html loads the same file.
//
// Screen: 68 x 160 px portrait, 1-bit, white on black. Drawing below uses ink = 1 (the light
// foreground); pack() turns that into panel pixels (1 = black).
//
// The Mac sends at most one frame a minute, because every refresh briefly takes the keyboard's
// radio away from typing. Nothing here may change by the second (no seconds, no blinking).
//
// The firmware draws only the "no data" screen itself (src/dashboard_display.c), because it
// has to appear when the Mac app is not running; renderStale() here is its reference.

(function (global) {
  'use strict';

  const W = 68, H = 160;
  // Bytes per packed row: 68 pixels rounded up to whole bytes.
  const STRIDE = 9;

  // 5x7 font: 7 rows per glyph, bit 4 is the leftmost of 5 columns.
  const FONT = {
    ' ': [0, 0, 0, 0, 0, 0, 0],
    A: [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11], B: [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
    C: [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E], D: [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C],
    E: [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F], F: [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
    G: [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F], H: [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
    I: [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E], J: [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
    K: [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11], L: [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
    M: [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11], N: [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11],
    O: [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E], P: [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
    Q: [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D], R: [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
    S: [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E], T: [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
    U: [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E], V: [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
    W: [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A], X: [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
    Y: [0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04], Z: [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
    '0': [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E], '1': [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
    '2': [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F], '3': [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
    '4': [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02], '5': [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
    '6': [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E], '7': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
    '8': [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E], '9': [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
    ':': [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00], '.': [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
    '/': [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x00], '-': [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
    '+': [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00], '?': [0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04],
    '!': [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04],
    '●': [0x00, 0x0E, 0x1F, 0x1F, 0x1F, 0x0E, 0x00], // settled (bell)
    '⊔': [0x00, 0x11, 0x11, 0x1B, 0x15, 0x11, 0x1F], // inbox: waiting on you
  };
  const UNKNOWN_GLYPH = [0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F];
  const norm = s => String(s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase();
  const glyph = ch => FONT[ch] || UNKNOWN_GLYPH;
  const trunc = (s, n) => [...norm(s)].slice(0, n).join('');

  // 1-bit drawing surface; v is 1 = ink, 0 = clear, 2 = invert.
  class FB {
    constructor() { this.p = new Uint8Array(W * H); }
    px(x, y, v = 1) {
      if (x < 0 || y < 0 || x >= W || y >= H) return;
      const i = y * W + x;
      this.p[i] = v === 2 ? this.p[i] ^ 1 : v;
    }
    fill(x, y, w, h, v = 1) { for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) this.px(x + i, y + j, v); }
    hline(x0, x1, y, v = 1, step = 1) { for (let x = x0; x <= x1; x += step) this.px(x, y, v); }
    vline(x, y0, y1, v = 1, step = 1) { for (let y = y0; y <= y1; y += step) this.px(x, y, v); }
    rect(x, y, w, h, v = 1) { this.hline(x, x + w - 1, y, v); this.hline(x, x + w - 1, y + h - 1, v); this.vline(x, y + 1, y + h - 2, v); this.vline(x + w - 1, y + 1, y + h - 2, v); }
    bmp(x, y, rows, v = 1, s = 1) { for (let j = 0; j < rows.length; j++) { const r = rows[j]; for (let i = 0; i < r.length; i++) if (r[i] === '#') this.fill(x + i * s, y + j * s, s, s, v); } }
    textW(str, o = {}) { const s = o.s || 1, gap = o.gap ?? s, n = [...norm(str)].length; return n ? n * (5 * s + gap) - gap : 0; }
    text(x, y, str, o = {}) {
      const s = o.s || 1, gap = o.gap ?? s, v = o.v ?? 1, chars = [...norm(str)];
      let cx = x;
      for (const ch of chars) {
        const g = glyph(ch);
        for (let r = 0; r < 7; r++) for (let c = 0; c < 5; c++) if ((g[r] >> (4 - c)) & 1) this.fill(cx + c * s, y + r * s, s, s, v);
        cx += 5 * s + gap;
      }
      return chars.length ? cx - gap - x : 0;
    }
    ctext(y, str, o = {}) { return this.text(Math.floor((W - this.textW(str, o)) / 2), y, str, o); }
    rtext(xr, y, str, o = {}) { return this.text(xr - this.textW(str, o) + 1, y, str, o); }
  }

  const CAL = ['.#...#.', '#######', '#.....#', '#.#.#.#', '#.....#', '#.#.#.#', '#######'];

  // Copy rules: every string on screen comes from these functions.
  const ME = 'Nico';
  const ALIASES = { 'Eng Weekly Priority Sync': 'Eng sync', 'Clear PR review queue': 'PR queue' };
  const FILLER = new Set(['+', '&', '/', '-', '|', ':', 'AND', 'WITH', 'THE', 'OF']);
  const LINE = 11, BESIDE_ICON = 9, LOOKAHEAD_DAYS = 3;

  // Meeting label: alias, then the other person's first name for a 1:1, then drop filler
  // words, whole words, 4-letter prefixes, and finally a hard cut.
  function shortTitle(raw, max = BESIDE_ICON) {
    if (raw == null) return { label: 'CALL', one: false };
    if (ALIASES[raw]) return { label: trunc(ALIASES[raw], max), one: false };
    if (/(^|\s)1:1(\s|$)/.test(raw)) {
      const names = raw.replace(/(^|\s)1:1(\s|$)/, ' ').split(/\/|<>|&|,/).map(s => s.replace(/[-–—]/g, ' ').trim()).filter(Boolean);
      const other = names.find(n => norm(n.split(/\s+/)[0]) !== norm(ME)) ?? names[0] ?? '1:1';
      return { label: trunc(norm(other).split(/\s+/)[0], max), one: true };
    }
    const words = norm(raw).split(/\s+/).filter(w => w && !FILLER.has(w));
    const full = words.join(' ');
    if (full.length <= max) return { label: full, one: false };
    const two = words.slice(0, 2).join(' ');
    if (words.length > 2 && two.length <= max) return { label: two, one: false };
    if (words.length >= 2) {
      const prefixes = words.slice(0, 2).map(w => w.slice(0, 4)).join(' ');
      if (prefixes.length <= max) return { label: prefixes, one: false };
    }
    return { label: full.slice(0, max).trim(), one: false };
  }
  const withOneOnOne = (st, max) => st.one && st.label.length + 4 <= max ? st.label + ' 1:1' : st.label;
  const hm = m => { const x = ((Math.floor(m) % 1440) + 1440) % 1440; return `${Math.floor(x / 60)}:${String(x % 60).padStart(2, '0')}`; };
  const span = (start, dur) => `${hm(start)}-${hm(start + dur)}`;
  const elapsedLbl = min => min < 60 ? `${min}M` : `${Math.floor(min / 60)}H${String(min % 60).padStart(2, '0')}M`;
  const countdownLbl = mins => mins < 60 ? `${mins}M` : mins < 600 ? `${Math.floor(mins / 60)}H${String(mins % 60).padStart(2, '0')}` : `${Math.floor(mins / 60)}H`;
  const ageLbl = min => min < 60 ? `${min}M` : min < 1440 ? `${Math.floor(min / 60)}H` : min < 10080 ? `${Math.floor(min / 1440)}D` : `${Math.floor(min / 10080)}W`;
  const cap99 = n => n > 99 ? '99+' : String(n);
  const thenLbl = m => m.day === 0 ? (m.then != null ? 'THEN ' + hm(m.then) : 'LAST TODAY') : m.day === 1 ? 'TOMORROW' : `IN ${m.day} DAYS`;

  // Breakdown beside the waiting total: spaced, unspaced, without the settled count, nothing.
  function waitBreakFit(fb, w, maxW) {
    const parts = [['?', w.ask], ['!', w.err], ['●', w.bell]].filter(([, c]) => c).map(([g, c]) => g + cap99(c));
    const hard = parts.filter(p => p[0] !== '●');
    for (const s of [parts.join(' '), parts.join(''), hard.join(' '), hard.join('')]) if (fb.textW(s) <= maxW) return s;
    return '';
  }

  // Text drawn inverted inside a box when it needs attention.
  function chip(fb, x, y, str, hot, s = 1) {
    const w = fb.textW(str, { s });
    if (hot) { fb.fill(x - 1, y - 1, w + 2, 7 * s + 2); fb.text(x, y, str, { s, v: 0 }); } else fb.text(x, y, str, { s });
    return w;
  }

  // Top strip: windows in tmux session "work" waiting on you, with a ? ! ● breakdown.
  function strip(fb, w) {
    const n = w.ask + w.err + w.bell, hot = w.ask + w.err > 0, total = '⊔' + cap99(n);
    chip(fb, hot ? 1 : 0, 1, total, hot);
    // The total's last column is tw - 1 (plain) or tw + 1 (chip box); keep a 2 px gap.
    const tw = fb.textW(total);
    const breakdown = waitBreakFit(fb, w, 65 - (hot ? tw + 1 : tw - 1));
    if (breakdown) fb.rtext(67, 1, breakdown);
  }

  function alertTitle(fb, label) {
    for (const s of [3, 2]) if (fb.textW(label, { s }) <= 62) { fb.ctext(s === 3 ? 30 : 34, label, { s, v: 0 }); return; }
    const parts = label.split(/ |(?<=-)/).filter(Boolean);
    if (parts.length === 2 && parts.every(p => fb.textW(p, { s: 2 }) <= 62)) {
      fb.ctext(25, parts[0], { s: 2, v: 0 });
      fb.ctext(42, parts[1], { s: 2, v: 0 });
      return;
    }
    fb.ctext(37, label, { v: 0 });
  }

  function meetingBand(fb, m) {
    if (m.mode === 'next') {
      const st = shortTitle(m.title, BESIDE_ICON);
      fb.bmp(0, 14, CAL);
      fb.text(10, 14, withOneOnOne(st, BESIDE_ICON));
      if (m.day > 0) fb.text(0, 33, m.dow, { s: 3, gap: 2 });
      else if (m.minsTo < 60) { const w = fb.text(0, 26, String(m.minsTo), { s: 5 }); fb.text(w + 2, 54, 'M'); }
      else fb.text(0, 33, countdownLbl(m.minsTo), { s: 3, gap: 2 });
      fb.text(0, 66, span(m.start, m.dur));
      fb.text(0, 76, thenLbl(m));
    } else if (m.mode === 'none') {
      fb.text(0, 14, 'NO MEETINGS');
      fb.text(0, 33, 'FREE', { s: 3, gap: 2 });
      fb.text(0, 66, `NEXT ${LOOKAHEAD_DAYS} DAYS`);
    } else if (m.mode === 'alert') {
      const st = shortTitle(m.title, BESIDE_ICON);
      fb.fill(0, 11, 68, 75);
      fb.rect(1, 12, 66, 73, 0);
      fb.ctext(15, st.one ? '1:1 WITH' : 'STARTING', { v: 0 });
      alertTitle(fb, st.label);
      fb.ctext(59, `IN ${m.minsTo}M`, { s: 2, v: 0 });
      fb.ctext(76, 'AT ' + hm(m.start), { v: 0 });
    } else { // onair: driven by the microphone; the calendar only supplies title and end time
      fb.fill(0, 11, 68, 75);
      fb.ctext(15, 'ON AIR', { s: 2, gap: 1, v: 0 });
      fb.ctext(34, elapsedLbl(m.elapsed), { s: 2, v: 0 });
      fb.ctext(53, withOneOnOne(shortTitle(m.title, LINE), LINE), { v: 0 });
      if (m.next != null && m.next <= 10) {
        const s = `NEXT IN ${m.next}M`, w = fb.textW(s), x = Math.floor((W - w) / 2);
        fb.fill(x - 1, 62, w + 2, 9, 0);
        fb.text(x, 63, s);
      } else if (m.title != null) {
        const over = m.elapsed - m.dur;
        fb.ctext(63, over > 0 ? `+${over}M OVER` : 'TO ' + hm(m.start + m.dur), { v: 0 });
      }
      if (m.title != null) {
        fb.rect(4, 75, 60, 5, 0);
        fb.fill(5, 76, Math.round(58 * Math.min(1, m.elapsed / m.dur)), 3, 0);
      }
    }
  }

  // Your own open PRs in TeracAI/platform: ready to merge, in review with someone, and those
  // still waiting for you to ask an individual reviewer. The actionable counts invert.
  function myPrRow(fb, y, label, n, hot) {
    fb.text(0, y, label);
    const count = cap99(n);
    chip(fb, 67 - fb.textW(count), y, count, hot);
  }

  function reviewBand(fb, r) {
    fb.text(0, 89, 'TO REVIEW');
    const n = r.count;
    if (n <= 9) fb.text(0, 98, String(n), { s: 4 });
    else if (n <= 99) fb.text(0, 104, String(n), { s: 3, gap: 1 });
    else { fb.text(0, 111, '99', { s: 2, gap: 1 }); fb.text(23, 111, '+'); }
    // Right-aligned so an inverted age (2D, 3W) keeps clear of a two-digit count.
    if (n === 0) { fb.rtext(67, 100, 'ALL'); fb.rtext(67, 110, 'CLEAR'); }
    else {
      const age = ageLbl(r.oldestMin);
      fb.rtext(67, 99, n === 1 ? 'AGE' : 'OLDEST');
      chip(fb, 67 - fb.textW(age, { s: 2 }), 111, age, r.oldestMin >= 1440, 2);
    }
    fb.hline(0, 67, 126, 1, 2);
    fb.text(0, 128, 'MY PRS');
    myPrRow(fb, 136, 'READY', r.mine.ready, r.mine.ready > 0);
    myPrRow(fb, 144, 'IN REVIEW', r.mine.inReview, false);
    myPrRow(fb, 152, 'NOT ASKED', r.mine.notAsked, r.mine.notAsked > 0);
  }

  // Shown by the firmware when the Mac app is silent: st.never before the first frame since
  // boot, otherwise st.mins since the last one.
  function renderStale(fb, st) {
    fb.text(0, 1, '⊔-');
    fb.hline(0, 67, 10);
    fb.bmp(0, 14, CAL);
    fb.text(10, 14, 'NO DATA');
    fb.text(0, 26, '--', { s: 5 });
    if (st.never) { fb.text(0, 66, 'WAITING FOR'); fb.text(0, 76, 'MAC APP'); }
    else { fb.text(0, 66, `LAST ${ageLbl(st.mins)} AGO`); fb.text(0, 76, 'CHECK MAC'); }
    fb.hline(0, 67, 86);
    fb.text(0, 89, 'TO REVIEW');
    fb.text(0, 98, '-', { s: 4 });
    fb.hline(0, 67, 126, 1, 2);
    fb.text(0, 128, 'MY PRS');
    for (const [y, label] of [[136, 'READY'], [144, 'IN REVIEW'], [152, 'NOT ASKED']]) {
      fb.text(0, y, label);
      fb.rtext(67, y, '-');
    }
  }

  function draw(state) {
    const fb = new FB();
    if (state.stale) renderStale(fb, state.stale);
    else {
      strip(fb, state.wait);
      fb.hline(0, 67, 10);
      meetingBand(fb, state.meet);
      fb.hline(0, 67, 86);
      reviewBand(fb, state.review);
    }
    return fb;
  }

  // Panel bytes: row-major, STRIDE bytes per row, most significant bit = leftmost pixel,
  // 1 = black. White on black, so ink is the clear (0) pixel.
  function pack(fb) {
    const out = new Uint8Array(STRIDE * H);
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        if (!fb.p[y * W + x]) out[y * STRIDE + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
    return out;
  }

  global.CorneDashboard = {
    W, H, STRIDE, FONT, CAL,
    draw,
    // state: object or JSON string. Returns a plain array so JavaScriptCore hands Swift an array
    // of numbers.
    render(state) {
      const s = typeof state === 'string' ? JSON.parse(state) : state;
      return Array.from(pack(draw(s)));
    },
  };
})(globalThis);
