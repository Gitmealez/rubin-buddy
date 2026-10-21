// Rick-Rubin-inspired 8-bit buddy: sprite data + rasterizer.
//
// Sprite grid is 24 x 32. Rows are built by concatenating repeated runs so
// column counts can't silently drift — buildRows() asserts every row width.
//
// Design notes: the read at this size comes almost entirely from silhouette,
// so the proportions are pushed. 4 rows of scalp against 16 rows of beard.
// Arms are one shade lighter than the torso ('n' vs 'b') so hands read as
// attached to something instead of floating. The beard tip is deliberately
// uneven — a clean triangle turns the shoulders into tuxedo lapels.
//
// Every gesture is a small one. He breathes, he nods, he strokes the beard, he
// pushes the shades up onto his head to look at you. Nothing bounces.

const W = 24;
const H = 32;

const PALETTE = {
  '.': null,                 // transparent
  k: [0x17, 0x12, 0x0f],     // outline
  s: [0xe8, 0xc0, 0x99],     // skin
  h: [0xf7, 0xdc, 0xbb],     // scalp highlight
  d: [0xc9, 0x99, 0x6e],     // skin shadow
  w: [0xf6, 0xf3, 0xec],     // beard light
  g: [0xd3, 0xcd, 0xc0],     // beard shadow
  b: [0x1f, 0x1c, 0x1c],     // black tee
  n: [0x33, 0x2f, 0x2c],     // sleeve / arm
  f: [0x56, 0x50, 0x4a],     // sunglasses frame
  l: [0x0e, 0x0c, 0x0b],     // lens
  r: [0xd9, 0x77, 0x57],     // Claude accent
  p: [0x2b, 0x27, 0x24],     // headphone band
  R: [0xa8, 0x55, 0x3c],     // Claude accent, shadow side — the headphone cups
  q: [0xe9, 0xe4, 0xda],     // glint on the lenses
  v: [0x75, 0x72, 0x6f],     // steam off the tea, pre-blended over his tee
  u: [0xd3, 0xcd, 0xc0, 0xa8], // dust kicked up by a landing — never rimmed
  // Rim light, added around the silhouette by withRim(). Translucent on
  // purpose: against a dark desktop it lifts him off the background, against a
  // light one it all but disappears. An opaque rim reads as a sticker outline.
  o: [0xf6, 0xf3, 0xec, 0x9c],
  // The same rim lit Claude-orange: the glow he gathers charging up a jump.
  O: [0xe8, 0x7a, 0x52, 0xd8],
  // Contact shadow, added under his feet by withShadow(). What makes him read
  // as standing ON a window's edge rather than hovering in front of it.
  z: [0x00, 0x00, 0x00, 0x48],
  Z: [0x00, 0x00, 0x00, 0x1e],
};

const _ = (n) => '.'.repeat(n);
const c = (ch, n) => ch.repeat(n);

// --- head -------------------------------------------------------------------
// Rows 4-8 all share a 12px interior at cols 6-17, which is what lets the
// shades slide up the face without any special-casing.

const SKULL = _(9) + c('k', 6) + _(9);
const FACE = [
  /* 2 */ _(7) + c('k', 2) + c('s', 6) + c('k', 2) + _(7),
  /* 3 */ _(6) + 'k' + c('s', 2) + c('h', 3) + c('s', 5) + 'k' + _(6),
  /* 4 */ _(5) + 'k' + c('s', 2) + c('h', 2) + c('s', 6) + c('d', 2) + 'k' + _(5),
  /* 5 */ _(5) + 'k' + c('s', 10) + c('d', 2) + 'k' + _(5),
  /* 6 */ _(5) + 'k' + c('s', 8) + c('d', 4) + 'k' + _(5),
];
const BROW = _(5) + 'k' + c('s', 9) + c('d', 3) + 'k' + _(5);
const CHEEK = _(5) + 'k' + c('s', 10) + c('d', 2) + 'k' + _(5);
const EYES = _(5) + 'k' + c('s', 2) + c('k', 2) + c('s', 4) + c('k', 2) + c('s', 2) + 'k' + _(5);
const SHADES = _(5) + 'k' + 'f' + c('l', 4) + 'ff' + c('l', 4) + 'f' + 'k' + _(5);
// Row 3 is only 10 wide, so the crown needs its own narrower band. Mixing the
// two is what makes the pushed-up shades read as tilted rather than flat.
const SHADES_NARROW = _(6) + 'k' + 'f' + c('l', 3) + 'ff' + c('l', 3) + 'f' + 'k' + _(6);
const BEARD_TOP = [
  /* 9  */ _(5) + 'k' + c('w', 2) + c('s', 8) + c('w', 2) + 'k' + _(5),
  /* 10 */ _(5) + 'k' + c('w', 3) + c('s', 2) + c('d', 2) + c('s', 2) + c('w', 3) + 'k' + _(5),
  /* 11 */ _(4) + 'k' + c('w', 6) + c('g', 2) + c('w', 6) + 'k' + _(4),
  /* 12 */ _(4) + 'k' + c('w', 5) + c('g', 4) + c('w', 5) + 'k' + _(4),
  /* 13 */ _(4) + 'k' + c('w', 14) + 'k' + _(4),
];

// `glassesY` is the top row of the two-row shades band; 7 is worn, 3 is pushed
// up onto the crown. `eyes`: 'none' (hidden behind the shades), 'open' (a 2x2
// block on row 7), 'closed' (the same block dropped to row 8 — lowered lids).
function headRows({ glassesY = 7, eyes = 'none' } = {}) {
  const rows = [
    _(W),                                 // 0 — padding
    SKULL,                                // 1
    ...FACE,                              // 2-6
    eyes === 'open' ? EYES : BROW,         // 7
    eyes === 'closed' ? EYES : CHEEK,      // 8
    ...BEARD_TOP,                         // 9-13
  ];
  if (glassesY !== null) {
    const bandFor = (y) => (y === 3 ? SHADES_NARROW : SHADES);
    rows[glassesY] = bandFor(glassesY);
    rows[glassesY + 1] = bandFor(glassesY + 1);
  }
  return rows;
}

// --- body -------------------------------------------------------------------
// Body rows share an 18px interior between the outlines at cols 2 and 21.
// Arms occupy the outer 2 columns of that interior.
const body = (interior) => _(2) + 'k' + interior + 'k' + _(2);

const BEARD_TIP = [
  /* 23 */ body(c('b', 7) + c('w', 4) + c('b', 7)),
  /* 24 */ body(c('b', 8) + c('g', 2) + c('b', 8)),
];

const LEGS = [
  /* 25 */ body(c('b', 18)),
  /* 26 */ _(4) + 'k' + c('b', 14) + 'k' + _(4),
  /* 27 */ _(5) + 'k' + c('b', 4) + 'k' + _(2) + 'k' + c('b', 4) + 'k' + _(5),
  /* 28 */ _(5) + 'k' + c('b', 4) + 'k' + _(2) + 'k' + c('b', 4) + 'k' + _(5),
  /* 29 */ _(5) + 'k' + c('s', 4) + 'k' + _(2) + 'k' + c('s', 4) + 'k' + _(5),
  /* 30 */ _(5) + c('k', 6) + _(2) + c('k', 6) + _(5),
  /* 31 */ _(W),
];

// Arms hanging, hands at the hips.
const BODY_ARMS_DOWN = [
  /* 14 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 15 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 16 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 17 */ body(c('n', 2) + 'b' + c('w', 12) + 'b' + c('n', 2)),
  /* 18 */ body(c('n', 2) + 'b' + c('w', 12) + 'b' + c('n', 2)),
  /* 19 */ body(c('n', 2) + c('b', 2) + c('w', 10) + c('b', 2) + c('n', 2)),
  /* 20 */ body(c('n', 2) + c('b', 3) + c('w', 8) + c('b', 3) + c('n', 2)),
  /* 21 */ body(c('s', 2) + c('b', 3) + c('w', 8) + c('b', 3) + c('s', 2)),
  /* 22 */ body(c('s', 2) + c('b', 4) + c('w', 6) + c('b', 4) + c('s', 2)),
  ...BEARD_TIP,
  ...LEGS,
];

// Both hands come up onto the beard — the "let it breathe" pose.
const BODY_HANDS_UP = [
  /* 14 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 15 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 16 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 17 */ body(c('n', 2) + 'b' + c('w', 12) + 'b' + c('n', 2)),
  /* 18 */ body(c('n', 2) + 'b' + c('w', 12) + 'b' + c('n', 2)),
  /* 19 */ body(c('n', 2) + c('s', 2) + c('w', 10) + c('s', 2) + c('n', 2)),
  /* 20 */ body(c('n', 2) + c('s', 2) + 'b' + c('w', 8) + 'b' + c('s', 2) + c('n', 2)),
  /* 21 */ body(c('n', 2) + c('b', 3) + c('w', 8) + c('b', 3) + c('n', 2)),
  /* 22 */ body(c('n', 2) + c('b', 4) + c('w', 6) + c('b', 4) + c('n', 2)),
  ...BEARD_TIP,
  ...LEGS,
];

const HEAD_BAND_END = 13; // last row that moves when he nods

function buildRows(head, bodyRows, label) {
  const rows = [...head, ...bodyRows];
  if (rows.length !== H) throw new Error(`${label}: ${rows.length} rows, expected ${H}`);
  rows.forEach((row, y) => {
    if (row.length !== W) throw new Error(`${label} row ${y}: width ${row.length}, expected ${W}`);
    for (const ch of row) {
      if (!(ch in PALETTE)) throw new Error(`${label} row ${y}: unknown palette char "${ch}"`);
    }
  });
  return rows;
}

// --- pose composition -------------------------------------------------------

const blank = () => Array.from({ length: H }, () => _(W));

// Shift a slice of rows sideways by dx, leaving the rest in place.
function shiftBandX(rows, from, to, dx) {
  return rows.map((row, y) => {
    if (y < from || y > to) return row;
    if (dx > 0) return _(dx) + row.slice(0, W - dx);
    return row.slice(-dx) + _(-dx);
  });
}

// Shift a slice of rows down by n, leaving the rest in place.
function shiftBand(rows, from, to, n) {
  const out = rows.slice();
  for (let y = to; y >= from; y--) {
    const src = y - n;
    out[y] = src >= from ? rows[src] : _(W);
  }
  return out;
}

// A breath: head and shoulders settle a pixel while the feet stay planted. The
// whole body used to drop, which was fine floating in a corner and wrong once
// he stands on a window's edge — every exhale sank his feet into the title bar.
const breathe = (rows, headEnd = HEAD_BAND_END) => shiftBand(rows, 0, headEnd, 1);

// Paint `over` on top of `under`, transparent pixels letting `under` show.
function overlay(under, over) {
  return under.map((row, y) =>
    row
      .split('')
      .map((ch, x) => (over[y][x] === '.' ? ch : over[y][x]))
      .join('')
  );
}

// Draw a small patch at (x, y). '.' in the patch leaves the sprite alone.
function stamp(rows, x, y, patch) {
  const out = rows.slice();
  patch.forEach((line, i) => {
    const ry = y + i;
    if (ry < 0 || ry >= H) return;
    let row = out[ry];
    for (let j = 0; j < line.length; j++) {
      const rx = x + j;
      if (line[j] === '.' || rx < 0 || rx >= W) continue;
      row = row.substring(0, rx) + line[j] + row.substring(rx + 1);
    }
    out[ry] = row;
  });
  return out;
}

// A little Claude-orange spark, for the thinking pose.
function sparkLayer(y0) {
  const rows = blank();
  const put = (y, x, ch) => {
    if (y < 0 || y >= H) return;
    rows[y] = rows[y].substring(0, x) + ch + rows[y].substring(x + 1);
  };
  put(y0, 20, 'r');
  put(y0 + 1, 19, 'r');
  put(y0 + 1, 21, 'r');
  put(y0 + 2, 20, 'r');
  return rows;
}

// --- poses ------------------------------------------------------------------

const SHADES_ON = headRows({ glassesY: 7, eyes: 'none' });

const standing = buildRows(SHADES_ON, BODY_ARMS_DOWN, 'standing');
const handsOnBeard = buildRows(SHADES_ON, BODY_HANDS_UP, 'handsOnBeard');

// Sitting cross-legged, hands on knees, beard pooling into the lap. The head
// is the standing head, dropped so he reads as grounded rather than shrunk;
// shades stay on — they always stay on. His base is row 30, the same as his
// feet standing, so sitting down on a window's edge doesn't leave him hovering.
const SIT_HEAD_END = 21; // last row of the seated head, for his breathing
const sitting = (() => {
  const wide = (interior) => _(1) + 'k' + interior + 'k' + _(1); // 20px interior
  const rows = [
    ...Array(9).fill(_(W)),                 // 0-8
    ...SHADES_ON.slice(1),                  // 9-21: skull through beard top
    /* 22 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
    /* 23 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
    /* 24 */ body('n' + c('b', 2) + c('w', 12) + c('b', 2) + 'n'),
    /* 25 */ wide(c('n', 2) + c('s', 2) + c('w', 12) + c('s', 2) + c('n', 2)),
    /* 26 */ wide(c('b', 3) + c('s', 2) + c('w', 10) + c('s', 2) + c('b', 3)),
    /* 27 */ wide(c('b', 6) + c('w', 3) + c('g', 2) + c('w', 3) + c('b', 6)),
    /* 28 */ wide(c('b', 20)),
    /* 29 */ wide(c('b', 6) + c('s', 3) + c('b', 2) + c('s', 3) + c('b', 6)),
    /* 30 */ _(2) + c('k', 20) + _(2),
    /* 31 */ _(W),
  ];
  if (rows.length !== H) throw new Error(`sitting: ${rows.length} rows`);
  rows.forEach((row, y) => {
    if (row.length !== W) throw new Error(`sitting row ${y}: width ${row.length}`);
  });
  return rows;
})();

const wearing = (glassesY, eyes) =>
  buildRows(headRows({ glassesY, eyes }), BODY_ARMS_DOWN, `shades@${glassesY}`);

// One hand working its way down the beard. A bare 2x2 skin block reads as a
// smudge on all that white, so the hand is outlined and the dark sleeve runs
// back to the shoulder at col 20 — the arm is what you actually see.
const strokePatch = (x) => {
  const sleeve = 21 - (x + 2);
  return ['kk' + _(sleeve), 'ss' + c('n', sleeve), 'ss' + c('n', sleeve), 'kk' + _(sleeve)];
};

// The idle right hand at the hip is painted out — that arm is up here now.
const strokeFrame = (x, y) =>
  stamp(stamp(standing, 19, 21, ['nn', 'nn']), x, y, strokePatch(x));

// --- small gestures ----------------------------------------------------------

// Head turns a pixel; the body stays put. That's all a glance is.
const HEAD_END = 13;
const glanceL = shiftBandX(standing, 1, HEAD_END, -1);
const glanceR = shiftBandX(standing, 1, HEAD_END, 1);

// One hand up to the temple, shades lifted a pixel, eyes shut against the
// light — everyone knows this gesture. Reuses the glasses-transition frame.
const adjustFrame = (() => {
  const lifted = wearing(6, 'closed');
  // hand at the temple; the hip hand it belongs to is painted out
  return stamp(stamp(lifted, 19, 21, ['nn', 'nn']), 16, 7, ['nss', '.ss']);
})();

// Arms straight up beside the head, hands open. The long hold IS the stretch.
const stretchUp = (() => {
  let rows = standing;
  // sleeves at his sides become torso while the arms are overhead
  for (const y of [14, 15, 16, 17, 18, 19, 20]) {
    rows = stamp(rows, 3, y, ['bb']);
    rows = stamp(rows, 19, y, ['bb']);
  }
  // left arm up (cols 2-3), right arm up (cols 20-21), hands on top
  for (const y of [8, 9, 10, 11, 12, 13]) {
    rows = stamp(rows, 2, y, ['nn']);
    rows = stamp(rows, 20, y, ['nn']);
  }
  rows = stamp(rows, 2, 7, ['ss']);
  rows = stamp(rows, 20, 7, ['ss']);
  // and the hands that hung at his hips go with the arms
  rows = stamp(rows, 3, 21, ['bb', 'bb']);
  rows = stamp(rows, 19, 21, ['bb', 'bb']);
  return rows;
})();
const stretchMid = (() => {
  let rows = stamp(stamp(standing, 3, 21, ['bb', 'bb']), 19, 21, ['bb', 'bb']);
  for (const y of [11, 12, 13]) {
    rows = stamp(rows, 2, y, ['nn']);
    rows = stamp(rows, 20, y, ['nn']);
  }
  rows = stamp(rows, 2, 10, ['ss']);
  rows = stamp(rows, 20, 10, ['ss']);
  return rows;
})();

// Tea. A small Claude-orange cup — raised, held at the beard, lowered.
const teaHold = stamp(standing, 18, 19, ['rr', 'rr']);
const teaRaise = (() => {
  let rows = stamp(standing, 19, 21, ['nn', 'nn']);  // hip hand painted out
  rows = stamp(rows, 17, 15, ['nn', 'ss']);          // hand mid-chest
  rows = stamp(rows, 17, 13, ['rr', 'rr']);          // cup above it
  return rows;
})();
const teaSip = (() => {
  let rows = stamp(standing, 19, 21, ['nn', 'nn']);
  rows = stamp(rows, 16, 12, ['nss']);               // hand at the beard
  rows = stamp(rows, 16, 10, ['.rr', '.rr']);        // cup at the mouth
  return rows;
})();
// A fresh cup steams: two wisps over his sleeve that trade places.
const teaSteaming = (phase) =>
  stamp(teaHold, 18, 17, phase ? ['.v', 'v.'] : ['v.', '.v']);

// Light catching the shades: a short diagonal streak slides across the lenses.
const glintAt = (x) => stamp(standing, x, 7, ['.q', 'q.']);

// --- hops ---------------------------------------------------------------------
// He travels between windows by jumping. Knees bend (the torso drops onto his
// feet), he leaves the ground arms-up with his feet tucked, and lands the same
// crouch he left from.

const crouchOf = (rows) => [_(W), _(W), ...rows.slice(0, 27), rows[29], rows[30], _(W)];
const crouch = crouchOf(standing);
const airborne = [...stretchUp.slice(0, 27), standing[29], standing[30], _(W), _(W), _(W)];

// The long jump between windows gets a wind-up. He sinks lower than a crouch
// — the torso right down onto his feet — while Claude-orange sparks climb the
// air around him, trembles a pixel each way, and the light catches his shades.
const deepCrouch = [_(W), _(W), _(W), ...standing.slice(0, 26), standing[29], standing[30], _(W)];
// Streaks rising either side, clear of his outline.
const SPARK_LEVELS = [
  [[0, 27], [23, 25]],
  [[0, 20], [23, 18]],
  [[0, 13], [23, 11]],
];
const charged = (rows, levels) =>
  levels.reduce((out, l) => SPARK_LEVELS[l].reduce((o, [x, y]) => stamp(o, x, y, ['r', 'r']), out), rows);
const tremble = (rows, dx) => shiftBandX(rows, 0, H - 1, dx);
const glintOn = (rows, x, dy) => stamp(rows, x, 7 + dy, ['.q', 'q.']);

// In the air he tucks into his seated pose and turns over. Pixel art only
// rotates cleanly by right angles, so it's the seated ball (a 24x24 square)
// turned a quarter at a time, held centred so the spin doesn't wobble.
const quarterTurn = (sq) => sq.map((_row, y) => sq.map((row) => row[y]).reverse().join(''));
const spun = (seated, turns) => {
  let sq = seated.slice(8, 32);
  for (let i = 0; i < turns; i++) sq = quarterTurn(sq);
  return [_(W), _(W), _(W), _(W), ...sq, _(W), _(W), _(W), _(W)];
};

// Landing: a hard crouch with the arms flung out for balance, dust thrown
// either side; the arms come in, the dust drifts out; the shades glint. Cool.
const impactOf = (base) => {
  let rows = base;
  for (let y = 17; y <= 25; y++) {     // the hanging arms go up and out
    rows = stamp(rows, 3, y, ['bb']);
    rows = stamp(rows, 19, y, ['bb']);
  }
  rows = stamp(rows, 0, 18, ['snn', 'snn']);
  rows = stamp(rows, 21, 18, ['nns', 'nns']);
  rows = stamp(rows, 1, 30, ['uuu']);
  rows = stamp(rows, 20, 30, ['uuu']);
  return stamp(stamp(rows, 2, 29, ['u']), 21, 29, ['u']);
};
const settlingOf = (base) =>
  stamp(stamp(stamp(stamp(base, 0, 29, ['uu']), 22, 29, ['uu']), 0, 30, ['u']), 23, 30, ['u']);

// The whole jump, dressed by `wear(rows, dy)` — bare, or with the headphones
// on, so the music doesn't stop for a jump.
function jumpOf(wear) {
  const low = wear(deepCrouch, 3);
  return {
    charge: [
      { rows: wear(crouch, 2), hold: 4 },
      { rows: charged(low, [0]), hold: 4, aura: true },
      { rows: tremble(charged(low, [0, 1]), 1), hold: 3 },
      { rows: tremble(charged(low, [1, 2]), -1), hold: 3, aura: true },
      { rows: charged(glintOn(low, 7, 3), [2]), hold: 2, aura: true },
      { rows: glintOn(low, 13, 3), hold: 60, aura: true },
    ],
    flip: [
      { rows: wear(airborne, 0), hold: 999 },
      ...[0, 1, 2, 3].map((turns) => ({ rows: spun(wear(sitting, 8), turns), hold: 999 })),
    ],
    land: [
      { rows: impactOf(wear(deepCrouch, 3)), hold: 5 },
      { rows: settlingOf(wear(crouch, 2)), hold: 4 },
      { rows: glintOn(wear(standing, 0), 9, 0), hold: 2 },
      { rows: glintOn(wear(standing, 0), 13, 0), hold: 2 },
    ],
  };
}
const BARE = jumpOf((rows) => rows);
const WIRED = jumpOf(withPhones);

// Left behind where he took off: a ring of sparks and a puff of dust. Its own
// little window, because by now he's already gone.
const PUFF = [
  [[[4, 29], ['.uuuu.', 'uuuuuu']], [[14, 29], ['.uuuu.', 'uuuuuu']], [[3, 26], ['r', 'r']], [[20, 26], ['r', 'r']], [[11, 27], ['rr']]],
  [[[1, 28], ['.uu.', 'uuuu', 'uuu.']], [[19, 28], ['.uu.', 'uuuu', '.uuu']], [[1, 23], ['r', 'r']], [[22, 23], ['r', 'r']], [[11, 24], ['rr']]],
  [[[0, 29], ['u.', 'uu']], [[22, 29], ['.u', 'uu']], [[0, 19], ['r']], [[23, 19], ['r']], [[11, 20], ['r']]],
].map((marks) => marks.reduce((rows, [[x, y], patch]) => stamp(rows, x, y, patch), blank()));

// --- music ------------------------------------------------------------------
// Studio headphones: a band hugging the dome, a cup over each ear.

// `dy` is how far down the head sits in the pose: 2 crouched, 8 seated.
function withPhones(rows, dy = 0) {
  let out = rows;
  out = stamp(out, 9, dy, [c('p', 6)]);
  out = stamp(out, 7, dy + 1, ['pp' + _(6) + 'pp']);
  out = stamp(out, 6, dy + 2, ['p' + _(10) + 'p']);
  out = stamp(out, 5, dy + 3, ['p' + _(12) + 'p']);
  out = stamp(out, 4, dy + 4, ['p' + _(14) + 'p', 'p' + _(14) + 'p']);
  // Claude-orange cups — the music is the one loud thing he wears.
  out = stamp(out, 3, dy + 6, ['.rr', 'Rrr', 'Rrr', '.rr']);   // left cup
  out = stamp(out, 18, dy + 6, ['rr.', 'rrR', 'rrR', 'rr.']);  // right cup
  return out;
}

// Both hands up at his ears, settling the headphones on (or lifting them off).
const handsAtEars = (() => {
  let rows = standing;
  for (let y = 14; y <= 22; y++) {
    rows = stamp(rows, 3, y, ['bb']);
    rows = stamp(rows, 19, y, ['bb']);
  }
  for (const y of [10, 11, 12, 13]) {
    rows = stamp(rows, 2, y, ['nn']);
    rows = stamp(rows, 20, y, ['nn']);
  }
  rows = stamp(rows, 2, 9, ['ss']);
  rows = stamp(rows, 20, 9, ['ss']);
  return rows;
})();

const NOTE = ['.rr', '.r.', 'rr.'];
const phonesOn = withPhones(standing);
// The head bobs down on the beat and tips to one side; the body keeps time.
const bob = (rows, dx) => shiftBandX(shiftBand(rows, 0, HEAD_BAND_END, 1), 0, HEAD_BAND_END, dx);

// --- animations -------------------------------------------------------------
// `next`      animation to settle into once a one-shot finishes; null loops.
// `shades`    where the shades are once this animation ends: 'up' or 'down'.
// `transition`/`from`  marks the two animations that move the shades between
//             those positions. The player inserts one automatically when a
//             requested animation's shade position doesn't match the current
//             one, so nothing ever hard-cuts from bare-eyed to shaded.

const ANIMATIONS = {
  // Waiting. The whole body settles a pixel, then rises.
  idle: {
    next: null,
    shades: 'down',
    frames: [
      { rows: standing, hold: 16 },
      { rows: breathe(standing), hold: 16 },
    ],
  },

  // Deep listening. Hands on the beard, spark drifting up.
  think: {
    next: null,
    shades: 'down',
    frames: [
      { rows: overlay(handsOnBeard, sparkLayer(4)), hold: 10 },
      { rows: overlay(breathe(handsOnBeard), sparkLayer(3)), hold: 10 },
      { rows: overlay(handsOnBeard, sparkLayer(2)), hold: 10 },
      { rows: overlay(breathe(handsOnBeard), sparkLayer(1)), hold: 10 },
    ],
  },

  // Working the material. One hand strokes down the beard, following its taper.
  stroke: {
    next: null,
    shades: 'down',
    frames: [
      { rows: strokeFrame(14, 11), hold: 9 },
      { rows: strokeFrame(14, 13), hold: 9 },
      { rows: strokeFrame(13, 16), hold: 9 },
      { rows: strokeFrame(13, 18), hold: 9 },
    ],
  },

  // That's the one. Head dips while the body stays put. Slow on purpose: at
  // the old tempo the whole gesture was 0.6s once and nobody ever saw it.
  nod: {
    next: 'idle',
    shades: 'down',
    frames: [
      { rows: standing, hold: 8 },
      { rows: shiftBand(standing, 0, HEAD_BAND_END, 1), hold: 8 },
      { rows: shiftBand(standing, 0, HEAD_BAND_END, 2), hold: 16 },
      { rows: shiftBand(standing, 0, HEAD_BAND_END, 1), hold: 8 },
    ],
  },

  // Shades slide up onto the crown. He wants to see you properly.
  glasses: {
    next: 'look',
    transition: true,
    from: 'down',
    shades: 'up',
    frames: [
      { rows: wearing(7, 'none'), hold: 3 },
      { rows: wearing(6, 'closed'), hold: 3 },
      { rows: wearing(5, 'open'), hold: 3 },
      { rows: wearing(3, 'open'), hold: 5 },
    ],
  },

  // And back down. Same beats in reverse — he's done looking at you.
  unglasses: {
    next: 'idle',
    transition: true,
    from: 'up',
    shades: 'down',
    frames: [
      { rows: wearing(3, 'open'), hold: 3 },
      { rows: wearing(5, 'open'), hold: 3 },
      { rows: wearing(6, 'closed'), hold: 3 },
      { rows: wearing(7, 'none'), hold: 4 },
    ],
  },

  // Settling down to sit. Quick — the sitting is the point, not the descent.
  sitdown: {
    next: 'meditate',
    shades: 'down',
    frames: [
      { rows: crouch, hold: 5 },
      { rows: sitting, hold: 5 },
    ],
  },

  // His own practice. Cross-legged, slower breath than idle — meditation
  // should read as deeper stillness, not a seated version of waiting.
  meditate: {
    next: null,
    shades: 'down',
    frames: [
      { rows: sitting, hold: 28 },
      { rows: breathe(sitting, SIT_HEAD_END), hold: 28 },
    ],
  },

  // And back up.
  standup: {
    next: 'idle',
    shades: 'down',
    frames: [
      { rows: sitting, hold: 4 },
      { rows: crouch, hold: 4 },
    ],
  },

  // A slow look around the room. Noticing.
  glance: {
    next: null,
    shades: 'down',
    frames: [
      { rows: standing, hold: 12 },
      { rows: glanceL, hold: 24 },
      { rows: standing, hold: 10 },
      { rows: glanceR, hold: 24 },
    ],
  },

  // Lifts the shades a pixel, eyes shut, settles them back. A micro-gesture.
  adjust: {
    next: 'idle',
    shades: 'down',
    frames: [
      { rows: standing, hold: 6 },
      { rows: adjustFrame, hold: 14 },
      { rows: standing, hold: 6 },
    ],
  },

  // Arms overhead, long hold. The stretch is the hold.
  stretch: {
    next: 'idle',
    shades: 'down',
    frames: [
      { rows: stretchMid, hold: 6 },
      { rows: stretchUp, hold: 42 },
      { rows: stretchMid, hold: 6 },
    ],
  },

  // Tea. Raised, sipped slowly, lowered. Very him.
  tea: {
    next: 'idle',
    shades: 'down',
    frames: [
      { rows: teaSteaming(0), hold: 7 },
      { rows: teaSteaming(1), hold: 7 },
      { rows: teaRaise, hold: 8 },
      { rows: teaSip, hold: 36 },
      { rows: teaRaise, hold: 8 },
      { rows: teaHold, hold: 8 },
    ],
  },

  // Shades up, eyes on you. Blinks now and then. This is "your turn".
  look: {
    next: null,
    shades: 'up',
    frames: [
      { rows: wearing(3, 'open'), hold: 40 },
      { rows: breathe(wearing(3, 'open')), hold: 40 },
      { rows: breathe(wearing(3, 'closed')), hold: 3 },
      { rows: wearing(3, 'open'), hold: 20 },
    ],
  },

  // Light catches the shades and slides across. Cool without trying.
  glint: {
    next: 'idle',
    shades: 'down',
    frames: [
      { rows: standing, hold: 8 },
      { rows: glintAt(7), hold: 2 },
      { rows: glintAt(9), hold: 2 },
      { rows: glintAt(13), hold: 2 },
      { rows: glintAt(15), hold: 2 },
      { rows: standing, hold: 10 },
    ],
  },

  // Music. Headphones on, head down on the beat — about 100 BPM, a note
  // rising off whichever side he's tipping away from.
  groove: {
    next: null,
    shades: 'down',
    frames: [
      { rows: stamp(phonesOn, 21, 3, NOTE), hold: 11 },
      { rows: stamp(bob(phonesOn, -1), 21, 1, NOTE), hold: 7 },
      { rows: stamp(phonesOn, 0, 3, NOTE), hold: 11 },
      { rows: stamp(bob(phonesOn, 1), 0, 1, NOTE), hold: 7 },
    ],
  },

  // `internal` animations are steps the app plays on its way somewhere else;
  // they stay out of the Pose menu.

  // Both hands settle the headphones on. The groove follows.
  phones: {
    next: 'groove',
    internal: true,
    shades: 'down',
    frames: [
      { rows: handsAtEars, hold: 5 },
      { rows: withPhones(handsAtEars), hold: 6 },
    ],
  },

  // And lifts them off when the music stops.
  unphones: {
    next: 'idle',
    internal: true,
    shades: 'down',
    frames: [
      { rows: withPhones(handsAtEars), hold: 6 },
      { rows: handsAtEars, hold: 5 },
    ],
  },

  // The jump to another window: charge, spin, land. The app moves his window
  // along the arc and picks the flip frame itself — launch first, then the
  // quarter turns — so the spin always lands upright; hence the long holds.
  charge: { next: null, internal: true, shades: 'down', frames: BARE.charge },
  flip: { next: null, internal: true, airborne: true, shades: 'down', frames: BARE.flip },
  // The same with the headphones on — the groove resumes on landing.
  'charge-phones': { next: null, internal: true, shades: 'down', frames: WIRED.charge },
  'flip-phones': { next: null, internal: true, airborne: true, shades: 'down', frames: WIRED.flip },
  'land-phones': { next: 'idle', internal: true, shades: 'down', frames: WIRED.land },
  puff: {
    next: null,
    internal: true,
    airborne: true,
    shades: 'down',
    frames: PUFF.map((rows) => ({ rows, hold: 3 })),
  },

  // A short hop — nudged along the same edge, or a window a step away — skips
  // the ceremony: crouch, up, down. The app moves his window while `fly` plays.
  leap: {
    next: 'fly',
    internal: true,
    shades: 'down',
    frames: [{ rows: crouch, hold: 4 }],
  },
  fly: {
    next: null,
    internal: true,
    airborne: true,
    shades: 'down',
    frames: [{ rows: airborne, hold: 30 }],
  },
  // The short hop's landing: just the crouch.
  touchdown: {
    next: 'idle',
    internal: true,
    shades: 'down',
    frames: [{ rows: crouch, hold: 5 }],
  },
  land: { next: 'idle', internal: true, shades: 'down', frames: BARE.land },
};

// --- menu bar icon ----------------------------------------------------------
// A 16x16 silhouette: dome, a clear band for the shades, beard tapering to a
// point. Rendered as a black-and-alpha mask and used as an AppKit template
// image, so macOS recolours it for light and dark menu bars.
const MENU_ICON = [
  '................',
  '......####......',
  '....########....',
  '...##########...',
  '...##########...',
  '...#........#...',
  '...##########...',
  '..############..',
  '..############..',
  '..############..',
  '...##########...',
  '...##########...',
  '....########....',
  '.....######.....',
  '......####......',
  '................',
];

function rasterizeMask(rows, scale) {
  const gridH = rows.length;
  const gridW = rows[0].length;
  rows.forEach((row, y) => {
    if (row.length !== gridW) throw new Error(`icon row ${y}: width ${row.length}`);
  });
  const w = gridW * scale;
  const h = gridH * scale;
  const buf = Buffer.alloc(w * h * 4, 0);
  for (let y = 0; y < gridH; y++) {
    for (let x = 0; x < gridW; x++) {
      if (rows[y][x] === '.') continue;
      for (let sy = 0; sy < scale; sy++) {
        for (let sx = 0; sx < scale; sx++) {
          const i = ((y * scale + sy) * w + (x * scale + sx)) * 4;
          buf[i + 3] = 255;  // black, fully opaque — template images use alpha
        }
      }
    }
  }
  return { width: w, height: h, data: buf };
}

// --- rim light --------------------------------------------------------------

const RIM_PAD = 1;
const OUT_W = W + RIM_PAD * 2;
const OUT_H = H + RIM_PAD * 2;

/// Pad by one pixel all round, then set every transparent pixel touching the
/// silhouette to the rim colour. 8-connected, so diagonal steps down the beard
/// taper and around the dome get covered too — 4-connected leaves gaps exactly
/// on the sloped edges that most need separating from the background.
///
/// The pad is what makes this safe: without it the rim (and the contact shadow
/// that later replaces it) under his feet would clip at the bottom row.
// Dust is air, not outline: a rim around it would turn a puff into a sticker.
const UNRIMMED = new Set(['u']);

function withRim(rows, rim = 'o') {
  const pad = '.'.repeat(RIM_PAD);
  const blankRow = '.'.repeat(OUT_W);
  const padded = [
    ...Array(RIM_PAD).fill(blankRow),
    ...rows.map((row) => pad + row + pad),
    ...Array(RIM_PAD).fill(blankRow),
  ];

  return padded.map((row, y) =>
    row
      .split('')
      .map((ch, x) => {
        if (ch !== '.') return ch;
        for (let dy = -1; dy <= 1; dy++) {
          for (let dx = -1; dx <= 1; dx++) {
            if (dx === 0 && dy === 0) continue;
            const n = padded[y + dy]?.[x + dx];
            if (n && n !== '.' && n !== 'o' && n !== 'O' && !UNRIMMED.has(n)) return rim;
          }
        }
        return ch;
      })
      .join('')
  );
}

// --- contact shadow ---------------------------------------------------------

/// A soft two-row shadow under whatever he's standing or sitting on: a darker
/// band one pixel wider than his base, a fainter one tucked under it. Laid over
/// the rim (it replaces the rim under his feet) and found from the raw rows, so
/// every grounded pose gets one at its own width. Airborne frames get none.
function withShadow(rimmed, raw) {
  let base = -1;
  for (let y = raw.length - 1; y >= 0 && base < 0; y--) {
    if (/[^.]/.test(raw[y])) base = y;
  }
  if (base < 0) return rimmed;
  const from = raw[base].search(/[^.]/);
  const to = raw[base].length - 1 - raw[base].split('').reverse().join('').search(/[^.]/);
  const out = rimmed.slice();
  const paint = (y, x0, x1, ch) => {
    if (y >= out.length) return;
    const row = out[y].split('');
    for (let x = Math.max(0, x0); x <= Math.min(row.length - 1, x1); x++) {
      if (row[x] === '.' || row[x] === 'o') row[x] = ch;
    }
    out[y] = row.join('');
  };
  // +RIM_PAD converts raw coordinates to padded ones.
  paint(base + 1 + RIM_PAD, from - 1 + RIM_PAD, to + 1 + RIM_PAD, 'z');
  paint(base + 2 + RIM_PAD, from + 1 + RIM_PAD, to - 1 + RIM_PAD, 'Z');
  return out;
}

// --- rasterizing ------------------------------------------------------------

function rasterize(rows, scale) {
  const gridH = rows.length;
  const gridW = rows[0].length;
  const w = gridW * scale;
  const h = gridH * scale;
  const buf = Buffer.alloc(w * h * 4, 0);
  for (let y = 0; y < gridH; y++) {
    for (let x = 0; x < gridW; x++) {
      const rgb = PALETTE[rows[y][x]];
      if (!rgb) continue;
      for (let sy = 0; sy < scale; sy++) {
        for (let sx = 0; sx < scale; sx++) {
          const i = ((y * scale + sy) * w + (x * scale + sx)) * 4;
          buf[i] = rgb[0];
          buf[i + 1] = rgb[1];
          buf[i + 2] = rgb[2];
          buf[i + 3] = rgb[3] ?? 255;
        }
      }
    }
  }
  return { width: w, height: h, data: buf };
}

module.exports = {
  W, H, OUT_W, OUT_H, PALETTE, ANIMATIONS, MENU_ICON, rasterize, rasterizeMask, withRim,
  withShadow,
};
