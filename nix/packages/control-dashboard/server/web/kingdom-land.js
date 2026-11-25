'use strict';

// The shape of the land, after the procedural generation literature, made
// first, and the towns set on it after:
//   - a continent of domain-warped noise about the towns (Quilez, "Domain
//     warping"), rising gently from its beaches;
//   - mountain ranges of ridged multifractal noise (Musgrave, "Texturing and
//     Modeling", ch. 16), only where a low-frequency mask puts a range;
//   - valleys worn by simulated raindrops (Beyer, "Implementation of a method
//     for hydraulic erosion", 2015);
//   - rain carried on a west wind, falling where the air must climb, so the
//     lee of a range is dry (orographic rain shadow, as in mapgen4);
//   - mesas, terraced, where it's hot and dry;
//   - thermal erosion: scree where slopes are steeper than they can stand
//     (Olsen, "Realtime procedural terrain generation", 2004);
//   - each town moved to the most level, dry ground near where it was meant;
//   - lakes where the land holds water: depressions filled by priority-flood
//     (Barnes, Lehman & Mulla, 2014);
//   - rivers where enough water gathers: D8 flow accumulation over the filled
//     land (O'Callaghan & Mark, 1984), with floodplains as wide as they are big;
//   - biomes from temperature and moisture (Whittaker's diagram), the
//     temperature falling northward, upward and on slopes facing north.
// Each biome is dressed in its own Kenney models and creatures.

const BIOMES = {
  beach: { ground: [.93, .85, .6], trees: ['nature/tree_palmShort', 'nature/tree_palm'], treeRate: .03, props: ['survival/rock-sand-a', 'survival/rock-sand-b', 'nature/rock_smallFlatA'], propRate: .08, pets: ['pets/animal-crab'] },
  meadow: { ground: [.45, .7, .27], trees: ['nature/tree_default', 'nature/tree_small', 'nature/tree_simple', 'nature/tree_oak'], treeRate: .08, props: ['nature/flower_redA', 'nature/flower_yellowB', 'nature/flower_purpleC', 'nature/grass', 'nature/grass_large', 'nature/flower_yellowA'], propRate: .4, pets: ['pets/animal-cow', 'pets/animal-pig', 'pets/animal-chick', 'pets/animal-bunny'] },
  forest: { ground: [.24, .52, .24], trees: ['nature/tree_oak', 'nature/tree_detailed', 'nature/tree_default', 'nature/tree_fat', 'nature/tree_tall'], treeRate: .75, props: ['nature/mushroom_red', 'nature/mushroom_tanGroup', 'nature/plant_bush', 'nature/log', 'nature/stump_old', 'nature/plant_bushLarge'], propRate: .18, pets: ['pets/animal-deer', 'pets/animal-fox', 'pets/animal-bunny', 'pets/animal-hog'] },
  autumn: { ground: [.66, .58, .27], trees: ['nature/tree_default_fall', 'nature/tree_oak_fall', 'nature/tree_detailed_fall', 'nature/tree_fat_fall', 'nature/tree_cone_fall', 'nature/tree_tall_fall'], treeRate: .55, props: ['graveyard/pumpkin', 'nature/mushroom_tanGroup', 'nature/log', 'nature/stump_round', 'nature/plant_bushSmall'], propRate: .15, pets: ['pets/animal-fox', 'pets/animal-hog', 'pets/animal-beaver'] },
  taiga: { ground: [.3, .46, .36], trees: ['nature/tree_pineDefaultA', 'nature/tree_pineRoundB', 'nature/tree_pineTallA_detailed', 'nature/tree_pineSmallC', 'nature/tree_pineTallB', 'nature/tree_pineRoundE'], treeRate: .7, props: ['nature/rock_smallA', 'nature/stump_round', 'nature/plant_bushSmall', 'nature/rock_smallC'], propRate: .1, pets: ['pets/animal-deer', 'pets/animal-bunny', 'pets/animal-fox'] },
  snow: { ground: [.92, .94, .98], trees: ['holiday/tree-snow-a', 'holiday/tree-snow-b', 'holiday/tree-snow-c'], treeRate: .3, props: ['holiday/snow-pile', 'holiday/rocks-small', 'holiday/snow-pile', 'holiday/snowman'], propRate: .07, pets: ['pets/animal-penguin', 'pets/animal-polar', 'holiday/reindeer'] },
  desert: { ground: [.93, .79, .5], trees: ['nature/cactus_tall', 'nature/cactus_short'], treeRate: .06, props: ['survival/rock-sand-a', 'survival/rock-sand-b', 'survival/rock-sand-c'], propRate: .06, pets: [] },
  savanna: { ground: [.79, .72, .38], trees: ['nature/tree_plateau', 'nature/tree_thin', 'nature/tree_plateau'], treeRate: .1, props: ['nature/grass_large', 'nature/rock_smallFlatA', 'nature/grass'], propRate: .2, pets: ['pets/animal-giraffe', 'pets/animal-elephant', 'pets/animal-lion'] },
  tropical: { ground: [.29, .66, .3], trees: ['nature/tree_palmTall', 'nature/tree_palmBend', 'nature/tree_palmDetailedTall', 'nature/tree_palmDetailedShort', 'nature/tree_plateau'], treeRate: .6, props: ['nature/plant_bushLarge', 'nature/grass_leafsLarge', 'nature/flower_yellowC', 'nature/plant_flatTall'], propRate: .25, pets: ['pets/animal-monkey', 'pets/animal-parrot', 'pets/animal-tiger'] },
  swamp: { ground: [.32, .4, .22], trees: ['nature/tree_thin_dark', 'nature/tree_simple_dark', 'nature/tree_fat_darkh', 'nature/tree_blocks_dark'], treeRate: .4, props: ['nature/mushroom_redGroup', 'nature/log', 'nature/stump_old', 'nature/plant_flatTall', 'nature/grass_leafs'], propRate: .3, pets: ['pets/animal-beaver', 'pets/animal-caterpillar'] },
  badlands: { ground: [.82, .47, .29], trees: ['nature/cactus_short'], treeRate: .03, props: ['nature/rock_tallE', 'survival/rock-sand-c', 'nature/rock_largeD'], propRate: .05, pets: [] },
  alpine: { ground: [.56, .54, .5], trees: ['nature/tree_pineSmallA', 'nature/tree_pineSmallB'], treeRate: .06, props: ['nature/rock_largeA', 'nature/rock_largeB', 'nature/rock_largeC', 'nature/stone_tallB', 'nature/rock_tallA'], propRate: .25, pets: [] },
};
const BIOME_NAMES = Object.keys(BIOMES);
const LAND_MODELS = [...new Set(Object.values(BIOMES).flatMap(b => [...b.trees, ...b.props, ...b.pets]))];

// A min-heap of [key, value] pairs.
function heap() {
  const h = [];
  return {
    get size() { return h.length; },
    push(e) { h.push(e); let i = h.length - 1; while (i) { const p = (i - 1) >> 1; if (h[p][0] <= e[0]) break; h[i] = h[p]; i = p; } h[i] = e; },
    pop() {
      const top = h[0], last = h.pop();
      if (h.length) { let i = 0; for (;;) { let c = 2 * i + 1; if (c >= h.length) break; if (c + 1 < h.length && h[c + 1][0] < h[c][0]) c++; if (h[c][0] >= last[0]) break; h[i] = h[c]; i = c; } h[i] = last; }
      return top;
    },
  };
}

// The land: heights, lakes, rivers and biomes on a grid of `res` per cell.
function makeLand({ WX, WZ, res, realms, pts, simplex, rand, nearest }) {
  const nx = Math.ceil(WX / res) + 1, nz = Math.ceil(WZ / res) + 1, N = nx * nz;
  const noise = (x, y) => simplex.noise2D(x, y);
  const fbm = (x, y, oct = 4) => { let a = 1, f = 1, s = 0, t = 0; for (let i = 0; i < oct; i++) { s += a * noise(x * f, y * f); t += a; a /= 2; f *= 2; } return s / t; };
  // Musgrave's ridged multifractal: sharp crests, each octave weighted by the last.
  const ridged = (x, y) => { let s = 0, a = 1, f = 1, w = 1; for (let i = 0; i < 3; i++) { let n = 1 - Math.abs(noise(x * f, y * f)); n *= n * w; w = clamp(n * 2); s += n * a; a *= .5; f *= 2.1; } return s / 1.4; };
  const X = k => (k % nx) * res, Z = k => Math.floor(k / nx) * res;

  const hAt = (A, x, z) => { const fx = clamp(x / res, 0, nx - 1.001), fz = clamp(z / res, 0, nz - 1.001), i = Math.floor(fx), j = Math.floor(fz), u = fx - i, v = fz - j, k = j * nx + i; return lerp(lerp(A[k], A[k + 1], u), lerp(A[k + nx], A[k + nx + 1], u), v); };
  const NB = [1, -1, nx, -nx, nx + 1, nx - 1, -nx + 1, -nx - 1];

  // Colder northward; upward too, later.
  const heat = (x, z) => .18 + z / WZ * .85 + fbm(x / 70 + 3, z / 70 - 9, 3) * .28;

  // The coast: the continent about the realms, domain-warped; above the sea
  // the land rises gently from its beaches.
  const shape = (x, z) => {
    const wx = x + fbm(x / 30 + 7, z / 30) * 10, wz = z + fbm(x / 30, z / 30 + 7) * 10;
    let isl = -1;
    for (const r of realms) { const ex = Math.abs(wx - r.cx) / (r.w / 2 + 9), ez = Math.abs(wz - r.cz) / (r.h / 2 + 9); isl = Math.max(isl, 1 - Math.cbrt(ex ** 3 + ez ** 3)); }
    return isl;
  };
  const coast = (x, z) => smooth(-.45, .3, shape(x, z)) + fbm(x / 45, z / 45) * .3 + fbm(x / 9, z / 9, 3) * .05 - .42;

  // The land: uplands, mountain ranges of ridged noise where a mask puts a
  // range, hills everywhere inland, and basins in the lowlands where lakes
  // may gather.
  const H = new Float32Array(N), townW = new Float32Array(N), mesa = new Uint8Array(N), rain = new Float32Array(N);
  for (let k = 0; k < N; k++) {
    const x = X(k), z = Z(k), base = coast(x, z) * 7;
    if (base <= 0) { H[k] = Math.max(base, -3); continue; }
    const inland = smooth(.3, 4, base), range = smooth(.05, .45, fbm(x / 70 + 11, z / 70 - 3, 2));
    const up = smooth(-.3, .5, fbm(x / 60 + 200, z / 60 - 100, 3)) * 4 * inland;
    const peaks = ridged(x / 34 + 40, z / 34 - 40) * 11 * range * inland;
    const hills = (fbm(x / 14, z / 14, 3) + 1) * 1.3 * inland;
    const h = base + up + peaks + hills;
    H[k] = Math.max(h - smooth(.3, .65, fbm(x / 26 + 90, z / 26 - 20, 3)) * 3 * (1 - range), Math.min(h, .7));
  }
  for (let pass = 0; pass < 2; pass++) { const B = H.slice(); for (let k = nx + 1; k < N - nx - 1; k++) H[k] = (B[k] * 4 + B[k - 1] + B[k + 1] + B[k - nx] + B[k + nx]) / 8; }

  // Valleys worn by raindrops running downhill, picking up soil where they
  // speed up and dropping it where they slow down (Beyer 2015).
  const at = (fx, fz) => { const i = Math.floor(fx), j = Math.floor(fz), u = fx - i, v = fz - j, k = j * nx + i; return [k, u, v, H[k], H[k + 1], H[k + nx], H[k + nx + 1]]; };
  for (let n = 0, drops = Math.floor(N * .6); n < drops; n++) {
    let x = 1 + rand() * (nx - 3), z = 1 + rand() * (nz - 3), dx = 0, dz = 0, speed = 1, water = 1, sediment = 0;
    if (H[Math.floor(z) * nx + Math.floor(x)] < .2) continue;
    for (let life = 0; life < 45; life++) {
      const [k, u, v, a, b, c, d] = at(x, z), h = lerp(lerp(a, b, u), lerp(c, d, u), v);
      const gx = (b - a) * (1 - v) + (d - c) * v, gz = (c - a) * (1 - u) + (d - b) * u;
      dx = dx * .1 - gx * .9; dz = dz * .1 - gz * .9;
      const l = Math.hypot(dx, dz);
      if (l < 1e-6) break;
      dx /= l; dz /= l; x += dx; z += dz;
      if (x < 1 || z < 1 || x >= nx - 2 || z >= nz - 2) break;
      const [, u2, v2, a2, b2, c2, d2] = at(x, z), dh = lerp(lerp(a2, b2, u2), lerp(c2, d2, u2), v2) - h;
      const capacity = Math.max(-dh * speed * water * 5, .01);
      const share = [(1 - u) * (1 - v), u * (1 - v), (1 - u) * v, u * v], cells = [k, k + 1, k + nx, k + nx + 1];
      if (sediment > capacity || dh > 0) {
        const drop = dh > 0 ? Math.min(dh, sediment) : (sediment - capacity) * .3;
        sediment -= drop;
        cells.forEach((q, i) => { H[q] += drop * share[i]; });
      } else {
        const take = Math.min((capacity - sediment) * .3, -dh);
        cells.forEach((q, i) => { H[q] -= take * share[i]; });
        sediment += take;
      }
      speed = Math.sqrt(Math.max(0, speed * speed - dh * 4)); water *= .985;
      if (H[Math.floor(z) * nx + Math.floor(x)] < 0) break;
    }
  }

  // Rain, carried on a west wind: the air dries as it crosses the land and
  // drops most of what it holds where it is made to climb, so the windward
  // slopes are wet and the lee of a range dry (orographic rain shadow).
  for (let j = 0; j < nz; j++) {
    let m = 1, prev = 0;
    for (let i = 0; i < nx; i++) {
      const k = j * nx + i, h = Math.max(0, H[k]);
      if (H[k] < 0) { m = Math.min(1, m + .03); rain[k] = m; prev = 0; continue; }
      const rise = Math.max(0, h - prev), r = m * Math.min(.5, .0011 + rise * .08);
      rain[k] = m * (1 + Math.min(1.2, rise * 6));
      m -= r; prev = h;
    }
  }
  for (let pass = 0; pass < 6; pass++) { const B = rain.slice(); for (let k = nx + 1; k < N - nx - 1; k++) rain[k] = (B[k] * 2 + B[k - 1] + B[k + 1] + B[k - nx] * 2 + B[k + nx] * 2) / 8; }
  for (let k = 0; k < N; k++) rain[k] = rain[k] * .75 + fbm(X(k) / 40 + 50, Z(k) / 40, 2) * .15;

  // Mesas where hot and dry: the land rises, then steps.
  for (let k = 0; k < N; k++) {
    const x = X(k), z = Z(k), m = smooth(.66, .8, heat(x, z)) * smooth(.34, .22, rain[k]);
    if (H[k] <= 0 || m <= .05) continue;
    const lift = H[k] + smooth(-.1, .3, fbm(x / 18 + 5, z / 18)) * 7 * m, step = 1.6, t = lift / step, f = t - Math.floor(t);
    H[k] = lerp(H[k], (Math.floor(t) + smooth(.82, .97, f)) * step, smooth(.05, .3, m));
    mesa[k] = m > .3 ? 1 : 0;
  }

  // Thermal erosion (Olsen 2004): wherever a slope is steeper than its
  // material stands, some of it slides down, so peaks are scree, not needles;
  // the mesas' rock stands as cliffs.
  for (let pass = 0; pass < 10; pass++) for (let k = nx + 1; k < N - nx - 1; k++) {
    if (H[k] <= 0) continue;
    const talus = (mesa[k] ? 4 : 1.1) * res;
    for (const o of NB.slice(0, 4)) { const d = H[k] - H[k + o]; if (d > talus) { const move = (d - talus) * .25; H[k] -= move; H[k + o] += move; } }
  }

  // Each town to the best ground near where it was meant to be: level, low
  // enough, dry, and clear of the others.
  const towns = d3.groups(pts, p => p.town ?? p.id).map(([, ps]) => ps).sort((a, b) => b.length - a.length);
  const lie = (p, dx, dz) => { const hs = [0, 1, 2, 3, 4, 5, 6, 7, 8].map(i => i ? hAt(H, p.x + dx + Math.cos(i * .785) * p.r * .8, p.z + dz + Math.sin(i * .785) * p.r * .8) : hAt(H, p.x + dx, p.z + dz)); return [d3.mean(hs), d3.max(hs) - d3.min(hs), d3.min(hs)]; };
  for (const ps of towns) {
    let best = [Infinity, 0, 0];
    for (let dz = -7; dz <= 7; dz++) for (let dx = -7; dx <= 7; dx++) {
      if (dx * dx + dz * dz > 49) continue;
      let score = Math.hypot(dx, dz) * .25;
      for (const p of ps) {
        const [mean, spread, low] = lie(p, dx, dz);
        score += spread * 2 + Math.max(0, mean - 8) + (low < .7 ? 60 : 0);
        for (const o of pts) if (o.town !== p.town && Math.hypot(o.x - p.x - dx, o.z - p.z - dz) < o.r + p.r + 1.5) score += 60;
      }
      if (score < best[0]) best = [score, dx, dz];
    }
    for (const p of ps) { p.x += best[1]; p.z += best[2]; }
  }

  // Then the towns, on whatever land they found: each building on a terrace
  // at the mean of the ground beneath it, cut into the slope or built up.
  const disc = (p, rad, f) => { for (let j = Math.max(0, Math.floor((p.z - rad) / res)); j <= Math.min(nz - 1, Math.ceil((p.z + rad) / res)); j++) for (let i = Math.max(0, Math.floor((p.x - rad) / res)); i <= Math.min(nx - 1, Math.ceil((p.x + rad) / res)); i++) { const e = Math.hypot(i * res - p.x, j * res - p.z); if (e <= rad) f(j * nx + i, e); } };
  for (const p of pts) { let s = 0, c = 0; disc(p, p.r * .8, k => { s += H[k]; c++; }); p.pad = Math.max(.9, s / c); }
  // A wall no higher than a man or two, earth banked beyond it.
  for (const p of pts) disc(p, p.r * .8 + 4, (k, e) => {
    const w = smooth(p.r * .8 + .6, p.r * .8 + .1, e), bank = smooth(p.r * .8 + 4, p.r * .8 + .6, e);
    H[k] = lerp(lerp(H[k], clamp(H[k], p.pad - 1.2, p.pad + 1.2), bank), p.pad, w);
    townW[k] = Math.max(townW[k], w);
  });
  for (let k = 0; k < N; k++) townW[k] = Math.max(townW[k], smooth(2.5, .6, nearest(X(k), Z(k))));

  // Lakes: fill every hollow up to where it would spill (priority-flood), the
  // sea and the map's edge draining; a hollow big enough, away from the towns,
  // stays a lake, the rest are filled.
  const F = new Float32Array(N), done = new Uint8Array(N), q = heap();
  for (let k = 0; k < N; k++) { const i = k % nx, j = Math.floor(k / nx); if (H[k] < 0 || i === 0 || j === 0 || i === nx - 1 || j === nz - 1) { F[k] = H[k]; done[k] = 1; q.push([F[k], k]); } }
  while (q.size) {
    const [f, k] = q.pop();
    for (const o of NB) {
      const m = k + o;
      if (m < 0 || m >= N || done[m] || Math.abs((m % nx) - (k % nx)) > 1) continue;
      done[m] = 1; F[m] = Math.max(H[m], f + 1e-4); q.push([F[m], m]);
    }
  }
  const lake = new Int32Array(N).fill(-1), lakes = [];
  for (let k = 0; k < N; k++) {
    if (lake[k] >= 0 || F[k] - H[k] < .08 || H[k] < 0) continue;
    const cells = [], stack = [k], id = lakes.length;
    lake[k] = id;
    while (stack.length) { const c = stack.pop(); cells.push(c); for (const o of NB.slice(0, 4)) { const m = c + o; if (m >= 0 && m < N && lake[m] < 0 && F[m] - H[m] >= .08 && H[m] >= 0 && Math.abs((m % nx) - (c % nx)) <= 1) { lake[m] = id; stack.push(m); } } }
    const level = Math.max(...cells.map(c => F[c])), townish = cells.some(c => townW[c] > .8);
    if (cells.length < 16 || townish) { for (const c of cells) { H[c] = F[c] - .02; lake[c] = -2; } continue; }
    lakes.push({ cells, level });
  }
  for (let k = 0; k < N; k++) if (lake[k] === -2) lake[k] = -1;

  // Rivers: where each cell's rain runs (D8, the steepest of eight), and how
  // much gathers; where enough has, a river, widening downstream.
  const to = new Int32Array(N).fill(-1), acc = new Float32Array(N).fill(1), order = Array.from({ length: N }, (_, k) => k).sort((a, b) => F[b] - F[a]);
  for (const k of order) {
    if (H[k] < 0) continue;
    let best = -1, low = F[k];
    for (const o of NB) { const m = k + o; if (m >= 0 && m < N && Math.abs((m % nx) - (k % nx)) <= 1 && F[m] < low) { low = F[m]; best = m; } }
    to[k] = best;
    if (best >= 0) acc[best] += acc[k];
  }
  const THRESH = 260, isRiver = k => acc[k] > THRESH && H[k] >= 0 && lake[k] < 0 && townW[k] < .6;
  const rivers = [], inRiver = new Uint8Array(N);
  const fed = new Uint8Array(N);
  for (let k = 0; k < N; k++) if (isRiver(k) && to[k] >= 0) fed[to[k]] = 1;
  for (let k = 0; k < N; k++) {
    if (!isRiver(k) || fed[k]) continue;
    const path = [];
    for (let c = k; c >= 0; c = to[c]) {
      path.push(c);
      if (inRiver[c] || H[c] < 0 || lake[c] >= 0 || townW[c] > .6 || path.length > 600) break;
      inRiver[c] = 1;
    }
    if (path.length < 8) continue;
    rivers.push({ cells: path, width: path.map(c => clamp(.3 + Math.sqrt(acc[c] / THRESH) * .22, .3, 1.3)) });
  }

  // Floodplains: the bigger a river, the wider the level land along it.
  for (const r of rivers) r.cells.forEach((c, i) => {
    const w = (r.width[i] - .4) * 4;
    if (w < .5) return;
    const lvl = H[c] + .3, rad = w + 2.5;
    disc({ x: X(c), z: Z(c) }, rad, (k, e) => { if (townW[k] < .3 && lake[k] < 0 && H[k] > lvl) H[k] = lerp(lvl, H[k], smooth(w, rad, e)); });
  });

  // Climate after the land: colder up high and on slopes facing north,
  // wetter where the rain falls and near water.
  const dist = new Float32Array(N).fill(1e9), bfs = [];
  for (let k = 0; k < N; k++) if (H[k] < 0 || lake[k] >= 0 || inRiver[k]) { dist[k] = 0; bfs.push(k); }
  for (let h = 0; h < bfs.length; h++) { const k = bfs[h]; for (const o of NB.slice(0, 4)) { const m = k + o; if (m >= 0 && m < N && dist[m] > dist[k] + 1) { dist[m] = dist[k] + 1; bfs.push(m); } } }
  const biome = new Uint8Array(N), temp = new Float32Array(N), moist = new Float32Array(N), B = name => BIOME_NAMES.indexOf(name);
  for (let k = 0; k < N; k++) {
    const x = X(k), z = Z(k), h = H[k], jitter = fbm(x / 6 + 17, z / 6 - 4, 2) * .05;
    const gx = (H[Math.min(N - 1, k + 1)] - H[Math.max(0, k - 1)]) / (2 * res), gz = (H[Math.min(N - 1, k + nx)] - H[Math.max(0, k - nx)]) / (2 * res), steep = Math.hypot(gx, gz) > 1.3;
    const t = temp[k] = heat(x, z) - Math.max(0, h) * .022 - clamp(gz, 0, 1) * .06 + jitter, m = moist[k] = rain[k] + Math.exp(-dist[k] * res / 9) * .3 + jitter;
    let b;
    if (h < .4 && dist[k] * res < 3 && lake[k] < 0) b = t < .2 ? 'snow' : 'beach';
    else if (t < .16) b = steep ? 'alpine' : 'snow';
    else if (h > 10 || (h > 7 && t < .4)) b = t < .22 && !steep ? 'snow' : 'alpine';
    else if (mesa[k]) b = 'badlands';
    else if (t < .33) b = 'taiga';
    else if (t > .7) b = m < .38 ? 'desert' : m < .62 ? 'savanna' : 'tropical';
    else if (m > .9 && h < 2.2) b = 'swamp';
    else if (m > .62) b = fbm(x / 40 - 70, z / 40 + 30, 2) > .15 ? 'autumn' : 'forest';
    else b = 'meadow';
    biome[k] = B(b);
  }
  const sample = (x, z) => { const fx = clamp(x / res, 0, nx - 1.001), fz = clamp(z / res, 0, nz - 1.001), i = Math.floor(fx), j = Math.floor(fz), u = fx - i, v = fz - j, k = j * nx + i; return lerp(lerp(H[k], H[k + 1], u), lerp(H[k + nx], H[k + nx + 1], u), v); };
  const cell = (x, z) => clamp(Math.round(z / res), 0, nz - 1) * nx + clamp(Math.round(x / res), 0, nx - 1);
  return { nx, nz, N, H, F, sample, cell, lake, lakes, rivers, biome, temp, moist, acc, townW, X, Z };
}
