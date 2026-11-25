'use strict';

// The kingdom's land and life: generated from the system, kept fresh by
// app.js through worldFor, settle, arrived, burned, flyTo and legendHtml.

const RES = .5, U = 10, MARGIN = 26;
let W = null, hovering = null;
const folk = [], effects = [];

// * Ways over a grid

const DIRS8 = [[1, 0], [0, 1], [-1, 0], [0, -1]];
function astar(cost, gw, gh, from, to) {
  const n = gw * gh, g = new Float64Array(n).fill(Infinity), came = new Int32Array(n).fill(-1), way = new Int8Array(n).fill(-1), shut = new Uint8Array(n);
  const tx = to % gw, tz = Math.floor(to / gw);
  const hu = k => (Math.abs(k % gw - tx) + Math.abs(Math.floor(k / gw) - tz)) * .9;
  const heap = [[hu(from), from]];
  const push = e => { heap.push(e); let i = heap.length - 1; while (i) { const p = (i - 1) >> 1; if (heap[p][0] <= e[0]) break; heap[i] = heap[p]; i = p; } heap[i] = e; };
  const pop = () => {
    const top = heap[0], last = heap.pop();
    if (heap.length) {
      let i = 0;
      for (;;) {
        let c = 2 * i + 1;
        if (c >= heap.length) break;
        if (c + 1 < heap.length && heap[c + 1][0] < heap[c][0]) c++;
        if (heap[c][0] >= last[0]) break;
        heap[i] = heap[c]; i = c;
      }
      heap[i] = last;
    }
    return top;
  };
  g[from] = 0;
  while (heap.length) {
    const [, k] = pop();
    if (k === to) break;
    if (shut[k]) continue;
    shut[k] = 1;
    const x = k % gw, z = Math.floor(k / gw);
    DIRS8.forEach(([dx, dz], d) => {
      const u = x + dx, v = z + dz;
      if (u < 0 || v < 0 || u >= gw || v >= gh) return;
      const m = v * gw + u, ng = g[k] + cost(m, k, way[k] >= 0 && way[k] !== d);
      if (ng < g[m]) { g[m] = ng; came[m] = k; way[m] = d; push([ng + hu(m), m]); }
    });
  }
  const path = [];
  for (let k = to; k >= 0; k = came[k]) { path.push(k); if (k === from) break; }
  return path.reverse();
}

function chaikin(pts, times = 2) {
  for (let t = 0; t < times; t++) {
    const out = [pts[0]];
    for (let i = 0; i < pts.length - 1; i++) {
      const [a, b] = [pts[i], pts[i + 1]];
      out.push([lerp(a[0], b[0], .25), lerp(a[1], b[1], .25)], [lerp(a[0], b[0], .75), lerp(a[1], b[1], .75)]);
    }
    out.push(pts.at(-1));
    pts = out;
  }
  return pts;
}
// Even steps along a line, `step` apart.
function resample(pts, step) {
  const out = [pts[0]];
  let carry = 0;
  for (let i = 1; i < pts.length; i++) {
    const [a, b] = [pts[i - 1], pts[i]], l = Math.hypot(b[0] - a[0], b[1] - a[1]);
    for (let s = step - carry; s <= l; s += step) out.push([lerp(a[0], b[0], s / l), lerp(a[1], b[1], s / l)]);
    carry = (carry + l) % step;
  }
  if (Math.hypot(out.at(-1)[0] - pts.at(-1)[0], out.at(-1)[1] - pts.at(-1)[1]) > .01) out.push(pts.at(-1));
  return out;
}

// Bridson's Poisson-disc sampling: points no closer than r.
function poisson(w, h, r, rand, ok) {
  const cell = r / Math.SQRT2, gw = Math.ceil(w / cell), gh = Math.ceil(h / cell), grid = new Int32Array(gw * gh).fill(-1), pts = [], active = [];
  const add = p => { pts.push(p); active.push(p); grid[Math.floor(p[1] / cell) * gw + Math.floor(p[0] / cell)] = pts.length - 1; };
  add([rand() * w, rand() * h]);
  while (active.length) {
    const i = Math.floor(rand() * active.length), [px, py] = active[i];
    let found = false;
    for (let k = 0; k < 16 && !found; k++) {
      const a = rand() * 2 * Math.PI, d = r * (1 + rand()), x = px + Math.cos(a) * d, y = py + Math.sin(a) * d;
      if (x < 0 || y < 0 || x >= w || y >= h) continue;
      const gx = Math.floor(x / cell), gy = Math.floor(y / cell);
      let near = false;
      for (let v = Math.max(0, gy - 2); v <= Math.min(gh - 1, gy + 2) && !near; v++)
        for (let u = Math.max(0, gx - 2); u <= Math.min(gw - 1, gx + 2) && !near; u++) {
          const q = grid[v * gw + u];
          near = q >= 0 && Math.hypot(pts[q][0] - x, pts[q][1] - y) < r;
        }
      if (!near) { add([x, y]); found = true; }
    }
    if (!found) active.splice(i, 1);
  }
  return pts.filter(ok);
}

// * The land

const SCATTER = ['nature/rock_largeA', 'nature/rock_largeB', 'nature/rock_largeC', 'nature/rock_smallA', 'nature/rock_smallC', 'nature/rock_tallA', 'nature/rock_tallE', 'nature/stone_tallB',
  'nature/flower_redA', 'nature/flower_yellowB', 'nature/flower_purpleC', 'nature/grass', 'nature/grass_large', 'nature/plant_bush', 'nature/plant_bushLarge', 'nature/mushroom_red', 'nature/mushroom_tanGroup',
  'nature/lily_large', 'nature/lily_small', 'nature/cliff_block_rock', 'nature/log', 'nature/stump_old', 'nature/crop_melon', 'nature/crop_pumpkin', 'castle/bridge-straight', 'nature/fence_simple', 'nature/bridge_wood',
  'town/wall-block', 'town/lantern', 'town/stall-red', 'town/stall-green', 'town/fountain-round', 'nature/campfire_stones', 'nature/log_stack', 'survival/signpost',
  'graveyard/pumpkin-carved', 'graveyard/lightpost-single', 'boats/boat-sail-a', 'boats/boat-fishing-small', 'boats/boat-row-small', 'pets/animal-parrot'];
const PEOPLE = ['character-male-a', 'character-male-b', 'character-male-c', 'character-male-d', 'character-female-a', 'character-female-b', 'character-female-c', 'character-female-d'].map(n => 'people/' + n);

async function generate(sys) {
  await Promise.all([ready([...PIECES, ...SCATTER, ...PEOPLE, ...LAND_MODELS, ...LIFE_MODELS]), document.fonts.load('20px Bold')]);
  const rand = mulberry(hashOf(sys.nodes.map(n => n.id).sort().join()));
  const simplex = new SimplexNoise(rand);
  const fbm = (x, y, oct = 4) => { let a = 1, f = 1, s = 0, t = 0; for (let i = 0; i < oct; i++) { s += a * simplex.noise2D(x * f, y * f); t += a; a /= 2; f *= 2; } return s / t; };
  const pick = xs => xs[Math.floor(rand() * xs.length)];

  // Where everything goes: each project a realm, flowing west to east; in it,
  // each event with subtasks a small town, its town hall in the middle and a
  // building for each subtask about it, and each other event a building alone.
  const up = new Map(sys.edges.filter(e => e.kind === 'part').map(e => [e.target, e.source]));
  const rootOf = id => { for (let n = 0; up.has(id) && n < 20; n++) id = up.get(id); return id; };
  const towns = new Map();
  for (const n of sys.nodes) { const t = rootOf(n.id); if (!towns.has(t)) towns.set(t, []); if (t !== n.id) towns.get(t).push(n.id); }
  const groups = new Map();
  for (const t of towns.keys()) { const n = nodes.get(t), r = (n && project(n)) ?? 'crown'; if (!groups.has(r)) groups.set(r, []); groups.get(r).push(t); }
  const realmOf = new Map([...groups].flatMap(([r, ts]) => ts.map(t => [t, r])));
  // A town's buildings, about its hall: [id, x, z, r] from its middle.
  const plan = t => {
    const subs = towns.get(t), hall = nodes.get(t)?.kind === 'you' || subs.length ? 3 : 2.1;
    if (!subs.length) return [[t, 0, 0, hall]];
    const R = Math.max(hall + 3.4, subs.length * 4.9 / (2 * Math.PI));
    return [[t, 0, 0, hall], ...subs.map((id, i) => { const a = (i + .5) / subs.length * 2 * Math.PI; return [id, Math.sin(a) * R, Math.cos(a) * R, 2.1]; })];
  };
  const extent = t => Math.max(...plan(t).map(([, x, z, r]) => Math.max(Math.abs(x), Math.abs(z)) + r)) * 2;
  const laid = await new ELK().layout({
    id: 'root',
    layoutOptions: { 'elk.algorithm': 'rectpacking', 'elk.aspectRatio': '1.5', 'elk.spacing.nodeNode': String(15 * U) },
    children: [...groups].map(([r, ts]) => ({
      id: 'realm:' + r,
      layoutOptions: { 'elk.algorithm': 'layered', 'elk.direction': 'RIGHT', 'elk.spacing.nodeNode': String(1.6 * U), 'elk.layered.spacing.nodeNodeBetweenLayers': String(3 * U), 'elk.padding': `[top=${3 * U},left=${3 * U},bottom=${3 * U},right=${3 * U}]` },
      children: ts.map(t => ({ id: t, width: extent(t) * U, height: extent(t) * U })),
      edges: sys.edges.flatMap((e, i) => { const a = rootOf(e.source), b = rootOf(e.target); return a !== b && realmOf.get(a) === r && realmOf.get(b) === r ? [{ id: 'e' + i, sources: [a], targets: [b] }] : []; }),
    })),
  });
  const WX = laid.width / U + 2 * MARGIN, WZ = laid.height / U + 2 * MARGIN;
  const realms = laid.children.map((c, n) => {
    const x0 = MARGIN + c.x / U, z0 = MARGIN + c.y / U, w = c.width / U, h = c.height / U, name = c.id.slice(6);
    return { name, n, x0, z0, w, h, cx: x0 + w / 2, cz: z0 + h / 2, biome: null, colour: ['#c0392b', '#2f6fd1', '#2f9e6e', '#d68a1c', '#8e44ad', '#1aa3b8'][hashOf(name) % 6],
      places: c.children.flatMap(t => plan(t.id).map(([id, dx, dz, r]) => ({ id, x: x0 + (t.x + t.width / 2) / U + dx, z: z0 + (t.y + t.height / 2) / U + dz, r, realm: n, seed: rand(), town: t.id,
        hall: id === t.id && towns.get(id).length > 0, rot: id === t.id ? 0 : Math.atan2(-dx, -dz) }))) };
  });
  const places = new Map(realms.flatMap(r => r.places.map(p => [p.id, p])));
  const pts = [...places.values()];
  const nearest = (x, z) => { let d = Infinity; for (const p of pts) d = Math.min(d, Math.hypot(p.x - x, p.z - z) - p.r); return d; };

  // The land: shaped, worn, watered and given its climates (kingdom-land.js);
  // each town takes the biome it stands in.
  const land = makeLand({ WX, WZ, res: RES, realms, pts, simplex, rand, nearest });
  const { nx, nz, N: NV, H, sample } = land;
  for (const p of pts) p.y = sample(p.x, p.z);
  for (const p of pts) {
    if (p.id !== p.town) continue;
    const to = sys.edges.flatMap(e => [e.source === p.id && e.target, e.target === p.id && e.source]).map(id => id && places.get(rootOf(id))).filter(q => q && q !== p);
    const fx = to.reduce((s, q) => s + q.x - p.x, 0), fz = to.reduce((s, q) => s + q.z - p.z, 0);
    p.rot = Math.hypot(fx, fz) > 1 ? Math.atan2(fx, fz) : rand() * 6.28;
  }
  for (const r of realms) r.biome = BIOME_NAMES[land.biome[land.cell(r.cx, r.cz)]];

  // Roads: each the cheapest way between two places over a grid of the
  // land, up and down as little as may be, around the other places, wandering
  // where the ground's cost does; then smoothed, and swaying a little.
  const gw = Math.ceil(WX), gh = Math.ceil(WZ), G = gw * gh, gat = (x, z) => clamp(Math.round(z), 0, gh - 1) * gw + clamp(Math.round(x), 0, gw - 1);
  const gH = Float32Array.from({ length: G }, (_, k) => sample(k % gw, Math.floor(k / gw)));
  const rough = Float32Array.from({ length: G }, (_, k) => (fbm((k % gw) / 6 + 31, Math.floor(k / gw) / 6 - 17, 3) + 1) * .8);
  const blocked = new Int16Array(G).fill(-1), used = new Float32Array(G);
  pts.forEach((p, n) => { for (let dz = -Math.ceil(p.r); dz <= Math.ceil(p.r); dz++) for (let dx = -Math.ceil(p.r); dx <= Math.ceil(p.r); dx++) if (Math.hypot(dx, dz) < p.r * .55) blocked[gat(p.x + dx, p.z + dz)] = n; });
  const order = { reaction: 0, part: 1, trigger: 2, awaited: 3 };
  const roads = [];
  for (const e of [...sys.edges].sort((a, b) => order[a.kind] - order[b.kind] || b.count - a.count)) {
    const a = places.get(e.source), b = places.get(e.target);
    if (!a || !b || a === b) continue;
    if (e.kind === 'trigger') { roads.push({ edge: e, from: a, to: b }); continue; }
    const from = gat(a.x, a.z), to = gat(b.x, b.z), main = e.kind === 'reaction';
    const cost = (k, prev, turning) => {
      if (blocked[k] >= 0 && blocked[k] !== blocked[to] && blocked[k] !== blocked[from]) return 1e4;
      const climb = Math.abs(gH[k] - gH[prev]), wet = gH[k] < .15 || land.lake[land.cell(k % gw, Math.floor(k / gw))] >= 0;
      return 1 + climb * 4 + Math.max(0, climb - .3) ** 2 * 60 + rough[k] + (wet ? 14 : 0) + (turning ? .6 : 0) - (used[k] ? .45 : 0) + (main ? 0 : .3);
    };
    const cells = astar(cost, gw, gh, from, to);
    if (cells[0] !== from) continue;
    for (const k of cells) used[k] = 1;
    // Corners cut, a sway from side to side, corners cut again.
    let line = chaikin(cells.map(k => [k % gw, Math.floor(k / gw)]), 2);
    line[0] = [a.x, a.z]; line[line.length - 1] = [b.x, b.z];
    line = resample(line, .5);
    const seed = roads.length * 7.3;
    line = line.map(([x, z], i) => {
      if (i === 0 || i === line.length - 1) return [x, z];
      const [px, pz] = line[i - 1], [qx, qz] = line[i + 1], l = Math.hypot(qx - px, qz - pz) || 1, s = i * .5, L = line.length * .5;
      const n = simplex.noise2D(s / 7, seed) * .9 * smooth(0, 3, s) * smooth(0, 3, L - s);
      return [x - (qz - pz) / l * n, z + (qx - px) / l * n];
    });
    line = resample(chaikin(line, 2), .35);
    // The road's own level: the land's, smoothed, never in the water.
    let ys = line.map(([x, z]) => Math.max(sample(x, z), .22));
    for (let pass = 0; pass < 4; pass++) ys = ys.map((y, i) => (ys[Math.max(0, i - 3)] + ys[Math.max(0, i - 1)] + y + ys[Math.min(ys.length - 1, i + 1)] + ys[Math.min(ys.length - 1, i + 3)]) / 5);
    ys[0] = a.y; ys[ys.length - 1] = b.y;
    const v3 = line.map(([x, z], i) => new THREE.Vector3(x, ys[i], z));
    roads.push({ edge: e, from: a, to: b, pts: v3, curve: new THREE.CatmullRomCurve3(v3), width: main ? .75 : e.kind === 'part' ? .42 : 0 });
  }
  for (const r of roads) r.len = r.curve?.getLength();

  // The rivers the water found, smoothed, their surface never rising
  // downstream.
  const rivers = land.rivers.map(r => {
    const line = resample(chaikin(r.cells.map(c => [land.X(c), land.Z(c)]), 3), .4), n = line.length;
    let ys = line.map(([x, z]) => sample(x, z));
    for (let i = 1; i < n; i++) ys[i] = Math.min(ys[i], ys[i - 1]);
    return { pts: line.map(([x, z], i) => new THREE.Vector3(x, ys[i], z)), width: line.map((_, i) => r.width[Math.min(r.width.length - 1, Math.floor(i / n * r.width.length))]) };
  });

  // Carve the roads and rivers into the land: a road its own level, a river
  // a channel below its banks; and note what lies where, for colours.
  const roadD = new Float32Array(NV).fill(9), roadKind = new Uint8Array(NV), riverD = new Float32Array(NV).fill(9);
  const stamp = (v3, radius, apply) => {
    for (const p of v3) {
      const i0 = Math.max(0, Math.floor((p.x - radius) / RES)), i1 = Math.min(nx - 1, Math.ceil((p.x + radius) / RES)), j0 = Math.max(0, Math.floor((p.z - radius) / RES)), j1 = Math.min(nz - 1, Math.ceil((p.z + radius) / RES));
      for (let j = j0; j <= j1; j++) for (let i = i0; i <= i1; i++) { const d = Math.hypot(i * RES - p.x, j * RES - p.z); if (d < radius) apply(j * nx + i, d, p); }
    }
  };
  const target = new Float32Array(NV).fill(NaN), weight = new Float32Array(NV);
  for (const r of roads) if (r.width) stamp(r.pts, 2, (k, d, p) => {
    const w = smooth(2, r.width + .3, d);
    if (w > weight[k]) { weight[k] = w; target[k] = p.y; }
    if (d < roadD[k]) { roadD[k] = d; roadKind[k] = r.width > .5 ? 1 : 2; }
  });
  for (let k = 0; k < NV; k++) if (weight[k]) H[k] = lerp(H[k], target[k], weight[k]);
  for (const r of rivers) stamp(r.pts, 1.6, (k, d, p) => {
    riverD[k] = Math.min(riverD[k], d);
    if (roadD[k] < 1.2) return;
    H[k] = Math.min(H[k], lerp(p.y - .55, H[k], smooth(.45, 1.6, d)));
  });

  // Bridges where a road meets a river.
  const bridges = [];
  for (const r of roads) if (r.width > .5) for (let i = 2; i < r.pts.length - 2; i += 1) {
    const p = r.pts[i];
    if (rivers.some(v => v.pts.some(q => Math.hypot(q.x - p.x, q.z - p.z) < .7)) && !bridges.some(b => b.position.distanceTo(p) < 2.5)) {
      const d = r.pts[i + 1].clone().sub(r.pts[i - 1]);
      bridges.push(model('nature/bridge_wood', p.x, p.y - .32, p.z, Math.atan2(d.x, d.z), 1.7));
    }
  }

  const world = { land, WX, WZ, nx, nz, H, sample, realms, places, pts, roads, rivers, rand, roadD, riverD, roadKind, group: new THREE.Group(), villagers: [], pets: [], boats: [], clouds: [], nearest };
  build(world, { fbm, pick, bridges });
  return world;
}

// * Building the world

function build(Wd, { fbm, pick, bridges }) {
  const { nx, nz, H, rand, group: g } = Wd;

  // The land, a low-poly sheet, each face its own colour: its biome's, lighter
  // or darker by its moisture, banded where the badlands are terraced; earth
  // on the roads, cobbles about the buildings, rock on the steeps.
  const pos = [], col = [], c = new THREE.Color(), L = Wd.land;
  const colourOf = (x, z, y, slope, k) => {
    const b = BIOME_NAMES[L.biome[k]], wet = clamp(L.moist[k] - .3);
    let rgb;
    if (y < -.05) rgb = mix([.85, .78, .55], [.45, .62, .66], smooth(-.05, -1.5, y));
    else if (L.lake[k] >= 0) rgb = [.55, .5, .36];
    else if (Wd.roadKind[k] === 1 && Wd.roadD[k] < .62) rgb = b === 'snow' ? [.8, .78, .74] : [.73, .58, .38];
    else if (Wd.roadKind[k] === 2 && Wd.roadD[k] < .36) rgb = [.68, .6, .42];
    else if (Wd.riverD[k] < .75) rgb = [.5, .44, .32];
    else if (Wd.nearest(x, z) < .2) rgb = b === 'snow' ? [.84, .85, .88] : b === 'desert' || b === 'badlands' ? [.86, .72, .52] : [.66, .64, .58];
    else if (b === 'badlands') rgb = slope > 1.2 ? [[.78, .42, .26], [.9, .64, .42], [.66, .34, .22], [.84, .52, .32]][Math.floor(Math.max(0, y) / .4) % 4] : [.88, .6, .38];
    else if (slope > 1.1) rgb = mix(BIOMES[b].ground, (b === "snow" || b === "taiga" || b === "alpine" ? [[.52, .54, .58], [.6, .61, .64], [.46, .48, .52], [.56, .57, .6]] : [[.6, .55, .48], [.68, .63, .55], [.53, .48, .42], [.64, .58, .5]])[Math.floor(Math.max(0, y) / .45 + fbm(x / 9, z / 9) * 1.5) & 3], smooth(1.1, 2, slope));
    else rgb = BIOMES[b].ground.map(v => v * (b === 'snow' || b === 'beach' || b === 'desert' ? 1 : 1.08 - wet * .18));
    if (Wd.roadKind[k] === 1 && Wd.roadD[k] < .78 && Wd.roadD[k] >= .62) rgb = mix(rgb, [.73, .58, .38], .5);
    const j = 1 + (rand() - .5) * .07;
    return rgb.map(v => v * j);
  };
  // Faceted irregularly, as if cut by hand: the grid's points jittered, then
  // joined by Delaunay; each face coloured at its middle.
  const vx = [], vz = [];
  for (let j = 0; j < nz; j++) for (let i = 0; i < nx; i++) {
    const edge = i === 0 || j === 0 || i === nx - 1 || j === nz - 1, k = j * nx + i, flat = L.townW[k] > .3 || Wd.roadD[k] < 1.2;
    const jit = edge || flat ? 0 : RES * .32;
    vx.push(i * RES + (rand() - .5) * 2 * jit); vz.push(j * RES + (rand() - .5) * 2 * jit);
  }
  const tris = d3.Delaunay.from(vx.map((x, i) => [x, vz[i]])).triangles, vy = vx.map((x, i) => Wd.sample(x, vz[i]));
  for (let t = 0; t < tris.length; t += 3) {
    const v = [tris[t], tris[t + 1], tris[t + 2]].map(i => [vx[i], vy[i], vz[i]]), cx = (v[0][0] + v[1][0] + v[2][0]) / 3, cz = (v[0][2] + v[1][2] + v[2][2]) / 3, cy = (v[0][1] + v[1][1] + v[2][1]) / 3;
    const slope = Math.max(...v.map(a => a[1])) - Math.min(...v.map(a => a[1]));
    c.setRGB(...colourOf(cx, cz, cy, slope / RES, L.cell(cx, cz)));
    for (const a of v) { pos.push(...a); col.push(c.r, c.g, c.b); }
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  geo.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
  geo.computeVertexNormals();
  const land = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ vertexColors: true, flatShading: true, roughness: .95 }));
  land.receiveShadow = true; land.castShadow = true;
  g.add(land);
  Wd.ground = land;

  // The sea, rolling; the rivers, running.
  const seaGeo = new THREE.PlaneGeometry(Wd.WX + 600, Wd.WZ + 600, 160, 160);
  seaGeo.rotateX(-Q); seaGeo.translate(Wd.WX / 2, 0, Wd.WZ / 2);
  const seaMat = new THREE.MeshStandardMaterial({ color: 0x3d9bd4, transparent: true, opacity: .78, roughness: .25, metalness: .1, flatShading: true });
  seaMat.onBeforeCompile = sh => {
    sh.uniforms.wind = wind;
    sh.vertexShader = 'uniform float wind;\n' + sh.vertexShader.replace('#include <begin_vertex>', '#include <begin_vertex>\ntransformed.y += sin(position.x * .35 + wind * 1.1) * .07 + cos(position.z * .3 + wind * .8) * .07;');
  };
  Wd.sea = new THREE.Mesh(seaGeo, seaMat);
  Wd.sea.receiveShadow = true;
  g.add(Wd.sea);
  const waterMat = new THREE.MeshStandardMaterial({ color: 0x6cbde8, map: flowMap, transparent: true, opacity: .88, roughness: .2, flatShading: true, side: THREE.DoubleSide });
  for (const r of Wd.rivers) {
    const p = [], uv = [], idx = [];
    let run = 0;
    r.pts.forEach((q, i) => {
      const a = r.pts[Math.max(0, i - 1)], b = r.pts[Math.min(r.pts.length - 1, i + 1)], dx = b.x - a.x, dz = b.z - a.z, l = Math.hypot(dx, dz) || 1, w = r.width[i];
      p.push(q.x - dz / l * w, q.y - .28, q.z + dx / l * w, q.x + dz / l * w, q.y - .28, q.z - dx / l * w);
      if (i) run += q.distanceTo(r.pts[i - 1]);
      uv.push(0, run / 3, 1, run / 3);
      if (i) idx.push(2 * i - 2, 2 * i - 1, 2 * i, 2 * i - 1, 2 * i + 1, 2 * i);
    });
    const rg = new THREE.BufferGeometry();
    rg.setAttribute("position", new THREE.Float32BufferAttribute(p, 3)); rg.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2)); rg.setIndex(idx); rg.computeVertexNormals();
    g.add(new THREE.Mesh(rg, waterMat));
  }
  bridges.forEach(b => g.add(b));

  // What grows and lies about, set where there's room for it.
  const free = (x, z, room) => {
    const k = clamp(Math.round(z / RES), 0, nz - 1) * nx + clamp(Math.round(x / RES), 0, nx - 1);
    return Wd.roadD[k] > room + .5 && Wd.riverD[k] > room + .6 && Wd.nearest(x, z) > room + 1.4 && H[k] > .3;
  };
  const slopeAt = (x, z) => Math.abs(Wd.sample(x + .5, z) - Wd.sample(x - .5, z)) + Math.abs(Wd.sample(x, z + .5) - Wd.sample(x, z - .5));
  const placed = new Map(), put = (name, x, z, s = 1, rot = rand() * 6.28, y = Wd.sample(x, z)) => {
    if (!placed.has(name)) placed.set(name, []);
    placed.get(name).push(new THREE.Matrix4().compose(new THREE.Vector3(x, y, z), new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), rot), new THREE.Vector3(s, s, s)));
  };
  // Each biome its own trees, thick or thin by the noise of its woods, and its
  // own things lying about.
  const SCALE = [['holiday/tree', .62], ['holiday/snowman', .45], ['holiday/rocks', .7], ['holiday/snow-pile', 1.1], ['nature/cactus', 1.7], ['survival/rock-sand', 2.2], ['nature/tree_plateau', 1.1]];
  const scaleOf = name => (SCALE.find(([p]) => name.startsWith(p))?.[1] ?? 1);
  for (const [x, z] of poisson(Wd.WX, Wd.WZ, 1.1, rand, () => true)) {
    const k = L.cell(x, z), b = BIOMES[BIOME_NAMES[L.biome[k]]], y = Wd.sample(x, z), sl = slopeAt(x, z), woods = smooth(-.35, .35, fbm(x / 20 + 9, z / 20 - 9)) * (1 - L.townW[k] * .8);
    if (!free(x, z, .3) || L.lake[k] >= 0) continue;
    if (sl < 1.6 && rand() < b.treeRate * (.35 + woods * 1.3)) { const t = pick(b.trees); put(t, x, z, scaleOf(t) * (.8 + rand() * .5)); }
    else if (rand() < b.propRate * (sl > 1.2 ? .4 : 1)) { const t = pick(b.props); put(t, x, z, scaleOf(t) * (.8 + rand() * .6)); }
    else if (sl > 1.2 && sl < 2.4 && rand() < .2) { const s = .7 + rand() * .6; put(pick(['nature/rock_largeA', 'nature/rock_largeB', 'nature/rock_tallE', 'nature/stone_tallB']), x, z, s, rand() * 6.28, y - .2 * s); }
  }
  // Crags: where the land stands steeper than it could slide, the Nature
  // Kit's tall rocks set into the face.
  for (const [x, z] of poisson(Wd.WX, Wd.WZ, 1.6, rand, ([x, z]) => slopeAt(x, z) > 2 && free(x, z, .3) && L.townW[L.cell(x, z)] < .2)) {
    const s = .8 + rand() * .6;
    put(pick(['nature/rock_tallA', 'nature/rock_tallC', 'nature/rock_tallE', 'nature/stone_tallB', 'nature/rock_largeB']), x, z, s, rand() * 6.28, Wd.sample(x, z) - .35 * s);
  }
  // Buttes in the badlands and the desert: Nature Kit cliff blocks, stacked.
  for (const [x, z] of poisson(Wd.WX, Wd.WZ, 7, rand, ([x, z]) => { const b = BIOME_NAMES[L.biome[L.cell(x, z)]]; return (b === 'badlands' || b === 'desert') && free(x, z, 1.6) && slopeAt(x, z) < 1; })) {
    const y = Wd.sample(x, z), s = 1.3 + rand() * .6, n = 1 + Math.floor(rand() * 3), rot = Math.floor(rand() * 4) * Q;
    for (let i = 0; i < n; i++) put('nature/cliff_block_rock', x, z, s * (1 - i * .18), rot + i, y - .1 + s * (i - i * (i - 1) * .09) * (1 - .09 * i));
  }
  // Lakes, their water level, lily pads near the shores of the warmer ones.
  const lakeMat = new THREE.MeshStandardMaterial({ color: 0x4fa6cf, transparent: true, opacity: .85, roughness: .2, flatShading: true });
  for (const lake of L.lakes) {
    const geo = new THREE.BufferGeometry(), p = [];
    for (const k of lake.cells) { const x = L.X(k), z = L.Z(k), r = RES * .75; p.push(x - r, lake.level, z - r, x - r, lake.level, z + r, x + r, lake.level, z + r, x - r, lake.level, z - r, x + r, lake.level, z + r, x + r, lake.level, z - r); }
    geo.setAttribute('position', new THREE.Float32BufferAttribute(p, 3)); geo.computeVertexNormals();
    const m = new THREE.Mesh(geo, lakeMat); m.receiveShadow = true; g.add(m);
    for (const k of lake.cells) if (rand() < .05 && L.temp[k] > .35 && L.lake[k + 2] < 0 !== (L.lake[k - 2] < 0)) put(rand() < .5 ? 'nature/lily_large' : 'nature/lily_small', L.X(k), L.Z(k), 2.4, rand() * 6.28, lake.level + .01);
  }

  // The places, their yards, and their lamps.
  for (const p of Wd.pts) {
    const n = nodes.get(p.id), r = Wd.realms[p.realm], kind = n?.status === 'unseen' ? 'ghost' : p.hall && n?.kind !== 'you' ? 'hall' : n?.kind ?? 'script';
    const b = (BUILDINGS[kind] ?? BUILDINGS.script)({ rand, colour: r.colour });
    b.position.set(p.x, p.y, p.z); b.rotation.y = p.rot;
    b.updateMatrixWorld(true);
    p.object = b; p.kind = kind; p.height = b.userData.height;
    g.add(b);
    const yard = (name, dx, dz, s = 1, rot) => { const at = b.localToWorld(new THREE.Vector3(dx, 0, dz)); put(name, at.x, at.z, s, rot == null ? rand() * 6.28 : rot + p.rot); };
    if (kind === 'script') for (let i = 0; i < 6; i++) yard(rand() < .5 ? 'nature/crop_pumpkin' : 'nature/crop_melon', -2.2 + (i % 3) * .5, 1.2 + Math.floor(i / 3) * .5, .7);
    if (kind === 'server') { yard(rand() < .5 ? 'town/stall-red' : 'town/stall-green', 1.9, 1.1, .8, -.3); yard('town/lantern', -1.6, 1.2, .55, 0); }
    if (kind === 'healthcheck') { yard('nature/campfire_stones', 1.2, 1.1, 1.4); yard('nature/log_stack', -1.3, .4, 1.2); }
    if (kind === 'ghost') { yard('graveyard/pumpkin-carved', .9, 1.1, 1); yard('graveyard/lightpost-single', -1.2, 1, .9, 0); }
    if (kind === 'you') yard('town/fountain-round', 0, 3.6, .9, 0);
    // A hidden box for the pointer.
    const hit = new THREE.Mesh(new THREE.BoxGeometry(p.r * 1.4, p.height, p.r * 1.4), new THREE.MeshBasicMaterial({ visible: false }));
    hit.position.set(p.x, p.y + p.height / 2, p.z);
    hit.userData.place = p;
    g.add(hit);
    p.hit = hit;
  }
  // Each terrace held by a stone wall wherever the slope falls away below it,
  // or rises above it; but not across the roads.
  for (const p of Wd.pts) {
    const R = p.r * .8 + .25, s = .55, n = Math.ceil(2 * Math.PI * R / s);
    for (let i = 0; i < n; i++) {
      const a = i / n * 2 * Math.PI, x = p.x + Math.cos(a) * R, z = p.z + Math.sin(a) * R, k = L.cell(x, z);
      if (Wd.roadD[k] < 1.1) continue;
      const out = Wd.sample(p.x + Math.cos(a) * (R + .8), p.z + Math.sin(a) * (R + .8)), drop = p.y - out;
      if (Math.abs(drop) < .3) continue;
      const lo = Math.min(p.y, out) - .15, hi = Math.max(p.y, out);
      for (let y = hi - s; y > lo - s; y -= s) put('town/wall-block', x, z, s, Q - a, y);
    }
  }
  // Lanterns along the roads, signposts where they leave each town.
  for (const r of Wd.roads) if (r.width > .5) {
    for (let s = 3; s < r.len - 3; s += 7) {
      const p = r.curve.getPointAt(s / r.len), t = r.curve.getTangentAt(s / r.len), side = (Math.floor(s / 7) % 2 ? 1 : -1) * (r.width + .45);
      const x = p.x - t.z * side, z = p.z + t.x * side;
      if (Wd.nearest(x, z) > 1.2) put('town/lantern', x, z, .55, 0);
    }
    const p = r.curve.getPointAt(Math.min(1, 3.2 / r.len)), t = r.curve.getTangentAt(Math.min(1, 3.2 / r.len));
    put('survival/signpost', p.x + t.z * 1.2, p.z - t.x * 1.2, 2, Math.atan2(t.x, t.z));
  }
  for (const [name, ms] of placed) instanced(g, name, ms);

  // Folk and creatures, boats and clouds.
  for (const r of Wd.realms) for (let i = 0; i < 2 + Math.floor(rand() * 3); i++) {
    const kinds = BIOMES[r.biome]?.pets.length ? BIOMES[r.biome].pets : BIOMES.meadow.pets;
    const home = pick(r.places), pet = { home, kind: pick(kinds), object: null, at: null, to: null, wait: rand() * 4 };
    pet.object = model(pet.kind, 0, 0, 0, 0, pet.kind.startsWith('holiday') ? .45 : .22 + rand() * .08);
    pet.at = spotNear(Wd, home, 2.4, 4);
    if (!pet.at) continue;
    pet.object.position.copy(pet.at);
    g.add(pet.object);
    Wd.pets.push(pet);
  }
  // Wild creatures, each in its own biome, far from the towns, in herds.
  for (const [x, z] of poisson(Wd.WX, Wd.WZ, 9, rand, ([x, z]) => Wd.nearest(x, z) > 8 && Wd.sample(x, z) > .4 && Wd.land.lake[Wd.land.cell(x, z)] < 0)) {
    const kinds = BIOMES[BIOME_NAMES[Wd.land.biome[Wd.land.cell(x, z)]]].pets;
    if (!kinds.length || rand() < .5) continue;
    const kind = pick(kinds);
    for (let i = 0, n = 1 + Math.floor(rand() * 4); i < n; i++) {
      const home = { x: x + (rand() - .5) * 3, z: z + (rand() - .5) * 3 }, pet = { home, kind, object: model(kind, home.x, Wd.sample(home.x, home.z), home.z, rand() * 6, (kind.startsWith("holiday") ? .45 : .24) * (.8 + rand() * .3)), to: null, wait: rand() * 4 };
      g.add(pet.object);
      Wd.pets.push(pet);
    }
  }
  for (const kind of ['boats/boat-sail-a', 'boats/boat-fishing-small', 'boats/boat-row-small', 'boats/boat-sail-a', 'boats/boat-fishing-small']) {
    const at = seaSpot(Wd);
    if (!at) continue;
    const o = model(kind, at.x, 0, at.z, rand() * 6, kind.includes('sail') ? .42 : .32);
    g.add(o);
    Wd.boats.push({ object: o, to: null, speed: .6 + rand() * .6 });
  }
  for (let i = 0; i < 7; i++) {
    const cloud = new THREE.Group(), m = new THREE.MeshStandardMaterial({ color: 0xffffff, transparent: true, opacity: .55, depthWrite: false, emissive: 0xffffff, emissiveIntensity: .35 });
    for (let k = 0; k < 4 + Math.floor(rand() * 4); k++) {
      const puff = new THREE.Mesh(new THREE.IcosahedronGeometry(1.2 + rand() * 1.4, 2), m);
      puff.position.set((rand() - .5) * 6, rand() * 1.2, (rand() - .5) * 3);

      cloud.add(puff);
    }
    cloud.position.set(rand() * Wd.WX, 36 + rand() * 8, rand() * Wd.WZ); cloud.scale.setScalar(1.6);
    g.add(cloud);
    Wd.clouds.push(cloud);
  }

  // The parrots' ways: arcs from what announced a trigger to what reacted.
  for (const r of Wd.roads.filter(r => r.edge.kind === 'trigger')) {
    const a = new THREE.Vector3(r.from.x, r.from.y + r.from.height + .4, r.from.z), b = new THREE.Vector3(r.to.x, r.to.y + r.to.height + .4, r.to.z);
    const mid = a.clone().lerp(b, .5).add(new THREE.Vector3(0, 3 + a.distanceTo(b) * .2, 0));
    r.curve = new THREE.QuadraticBezierCurve3(a, mid, b);
    r.len = r.curve.getLength();
    r.mesh = new THREE.Mesh(new THREE.TubeGeometry(r.curve, 80, .05, 6), new THREE.MeshBasicMaterial({ color: 0x9b6fd6, transparent: true, opacity: .5 }));
    g.add(r.mesh);
  }
  // The trails, a line of stepping stones; the awaited ones, fainter.
  const stones = { part: [], awaited: [] };
  for (const r of Wd.roads) if (r.edge.kind === 'part' || r.edge.kind === 'awaited') for (let s = 1.2; s < r.len - 1.2; s += .55) {
    const p = r.curve.getPointAt(s / r.len);
    stones[r.edge.kind].push(new THREE.Matrix4().compose(new THREE.Vector3(p.x, Wd.sample(p.x, p.z) + .02, p.z), new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), s), new THREE.Vector3(1, 1, 1)));
  }
  for (const [kind, ms] of Object.entries(stones)) if (ms.length) {
    const m = new THREE.InstancedMesh(new THREE.CylinderGeometry(.09, .1, .04, 6), new THREE.MeshStandardMaterial({ color: kind === 'part' ? 0x8a8072 : 0xa69e90, transparent: kind === 'awaited', opacity: .55, flatShading: true }), ms.length);
    ms.forEach((x, i) => m.setMatrixAt(i, x));
    m.receiveShadow = true;
    g.add(m);
  }

  // What changes: rings, fires, signs, smoke.
  Wd.ring = new THREE.RingGeometry(1.5, 1.75, 40); Wd.ring.rotateX(-Q);
  Wd.cursor = new THREE.Mesh(Wd.ring, new THREE.MeshBasicMaterial({ color: 0xffcf4a, transparent: true, opacity: .9, depthWrite: false }));
  Wd.cursor.visible = false;
  g.add(Wd.cursor);
  for (const p of Wd.pts) {
    p.fire = fireAt(); p.fire.position.copy(p.object.localToWorld(new THREE.Vector3(0, p.height * .62, .75))); p.fire.visible = false;
    p.chimney = ud(p).smoke ? smokeAt() : null;
    if (p.chimney) { p.chimney.position.copy(p.object.localToWorld(ud(p).smoke.clone())); g.add(p.chimney); }
    p.glow = new THREE.Mesh(Wd.ring, new THREE.MeshBasicMaterial({ color: 0xffd36a, transparent: true, opacity: .6, depthWrite: false }));
    p.glow.position.set(p.x, p.y + .06, p.z); p.glow.visible = false;
    g.add(p.fire, p.glow);
  }
  Wd.highlight = new THREE.Group();
  g.add(Wd.highlight);
  life(Wd);
  const L2 = Wd.life;
  batch(Wd, [...Wd.pets, ...Wd.boats, ...Wd.villagers, ...L2.fish, ...L2.carts, ...L2.canoes, ...L2.strollers].map(o => o.object)
    .concat(Wd.clouds, L2.mills, L2.flocks.flatMap(f => f.birds.map(b => b.object)), L2.fires.flatMap(f => f.folk.map(w => w.object)), Wd.pts.flatMap(p => [p.object.userData.sails, p.object.userData.ghost]).filter(Boolean)));
}

function realmNear(Wd, x, z) {
  let best = Wd.realms[0], bd = Infinity;
  for (const r of Wd.realms) { const d = Math.hypot(Math.max(Math.abs(x - r.cx) - r.w / 2, 0), Math.max(Math.abs(z - r.cz) - r.h / 2, 0)); if (d < bd) { bd = d; best = r; } }
  return [best, bd];
}
const mix = (a, b, t) => a.map((v, i) => lerp(v, b[i], t));

// A model's every mesh, repeated by instancing.
const TINTS = { 'nature/cliff_block_rock': 0xffb486 };
function instanced(g, name, matrices) {
  const root = gltfs.get(name).scene;
  root.updateMatrixWorld(true);
  root.traverse(o => {
    if (!o.isMesh) return;
    let material = TINTS[name] ? Object.assign(o.material.clone(), { color: new THREE.Color(TINTS[name]) }) : o.material;
    if (SWAYS.test(name)) material = swaying(material);
    const im = new THREE.InstancedMesh(o.geometry, material, matrices.length);
    matrices.forEach((m, i) => im.setMatrixAt(i, m.clone().multiply(o.matrixWorld)));
    im.castShadow = im.receiveShadow = true;
    g.add(im);
  });
}

// Every opaque mesh drawn more than once, drawn at once, the meshes
// themselves moved to a layer no camera sees: what stands still merged into
// one geometry for each material; what moves under `moving` an InstancedMesh
// for each geometry and material, copied over every frame.
const HIDDEN = 31;
function batch(Wd, moving) {
  Wd.group.updateMatrixWorld(true);
  const roots = new Set(moving), still = new Map(), moved = new Map();
  const moves = o => { for (let a = o; a; a = a.parent) if (roots.has(a)) return true; return false; };
  const shown = o => { for (let a = o; a; a = a.parent) if (!a.visible) return false; return true; };
  const into = (m, key, o) => { if (!m.has(key)) m.set(key, []); m.get(key).push(o); };
  Wd.group.traverse(o => {
    if (!o.isMesh || o.isInstancedMesh || o.isSkinnedMesh || o.material.transparent || !o.material.visible || o.userData.place) return;
    if (moves(o)) into(moved, o.geometry.uuid + o.material.uuid, o);
    else if (shown(o)) into(still, o.material.uuid, o);
  });
  const add = (mesh, meshes) => { meshes.forEach(o => o.layers.set(HIDDEN)); Object.assign(mesh, { castShadow: meshes.some(o => o.castShadow), receiveShadow: true, frustumCulled: false }); Wd.group.add(mesh); };
  for (const meshes of still.values()) {
    const geo = meshes.length > 1 && merged(meshes);
    if (geo) add(new THREE.Mesh(geo, meshes[0].material), meshes);
  }
  Wd.batches = [];
  for (const meshes of moved.values()) {
    if (meshes.length < 2) continue;
    const im = new THREE.InstancedMesh(meshes[0].geometry, meshes[0].material, meshes.length);
    add(im, meshes);
    copy(im, meshes);
    Wd.batches.push({ im, meshes });
  }
}
// Meshes as one geometry, each moved where it stands; null unless they all
// have the same attributes (tangents left, there being no normal maps).
function merged(meshes) {
  const names = ['position', 'normal', 'uv'].filter(n => meshes[0].geometry.attributes[n]);
  if (!meshes.every(o => names.every(n => o.geometry.attributes[n]) && !o.geometry.attributes.color && !o.material.normalMap)) return null;
  const total = d3.sum(meshes, o => o.geometry.attributes.position.count), out = Object.fromEntries(names.map(n => [n, new Float32Array(total * (n === 'uv' ? 2 : 3))]));
  const index = [], v = new THREE.Vector3(), nm = new THREE.Matrix3();
  let base = 0;
  for (const o of meshes) {
    const g = o.geometry, a = g.attributes, c = a.position.count;
    nm.getNormalMatrix(o.matrixWorld);
    for (let i = 0; i < c; i++) {
      v.fromBufferAttribute(a.position, i).applyMatrix4(o.matrixWorld).toArray(out.position, (base + i) * 3);
      if (a.normal) v.fromBufferAttribute(a.normal, i).applyMatrix3(nm).normalize().toArray(out.normal, (base + i) * 3);
      if (a.uv) { out.uv[(base + i) * 2] = a.uv.getX(i); out.uv[(base + i) * 2 + 1] = a.uv.getY(i); }
    }
    if (g.index) for (let i = 0; i < g.index.count; i++) index.push(base + g.index.getX(i));
    else for (let i = 0; i < c; i++) index.push(base + i);
    base += c;
  }
  const geo = new THREE.BufferGeometry();
  for (const n of names) geo.setAttribute(n, new THREE.BufferAttribute(out[n], n === 'uv' ? 2 : 3));
  geo.setIndex(index);
  return geo;
}
const ZERO = new THREE.Matrix4().makeScale(0, 0, 0);
function copy(im, meshes) {
  meshes.forEach((o, i) => { let shown = true; for (let a = o; a && shown; a = a.parent) shown = a.visible; im.setMatrixAt(i, shown ? o.matrixWorld : ZERO); });
  im.instanceMatrix.needsUpdate = true;
}
const batchStep = Wd => Wd.batches.forEach(b => copy(b.im, b.meshes));

// Somewhere on open ground near a place, or a short walk from `from`.
function spotNear(Wd, p, r0, r1, from) {
  for (let n = 0; n < 20; n++) {
    const a = Wd.rand() * 2 * Math.PI, r = r0 + Wd.rand() * (r1 - r0), x = (from?.x ?? p.x) + Math.cos(a) * (from ? 1.5 : r), z = (from?.z ?? p.z) + Math.sin(a) * (from ? 1.5 : r);
    if (Math.hypot(x - p.x, z - p.z) > r1 || Wd.nearest(x, z) < .4 || Wd.sample(x, z) < .3) continue;
    return new THREE.Vector3(x, Wd.sample(x, z), z);
  }
  return null;
}
function seaSpot(Wd) {
  for (let n = 0; n < 60; n++) {
    const x = Wd.rand() * Wd.WX, z = Wd.rand() * Wd.WZ;
    if (Wd.sample(x, z) < -1.2) return new THREE.Vector3(x, 0, z);
  }
  return null;
}

// * Effects

const fxTextures = new Map();
const fxTexture = name => { if (!fxTextures.has(name)) { const t = new THREE.TextureLoader().load(`kingdom/fx/${name}.png`); t.encoding = THREE.sRGBEncoding; fxTextures.set(name, t); } return fxTextures.get(name); };
const softGlow = (() => {
  const c = document.createElement('canvas'); c.width = c.height = 64;
  const x = c.getContext('2d'), g = x.createRadialGradient(32, 32, 0, 32, 32, 32);
  g.addColorStop(0, 'rgba(255,255,255,1)'); g.addColorStop(.25, 'rgba(255,255,255,.55)'); g.addColorStop(1, 'rgba(255,255,255,0)');
  x.fillStyle = g; x.fillRect(0, 0, 64, 64);
  return new THREE.CanvasTexture(c);
})();
function glowSprite(color, size) {
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: softGlow, color, blending: THREE.AdditiveBlending, transparent: true, opacity: 0, depthWrite: false }));
  s.scale.setScalar(size);
  return s;
}
const ud = p => p.object.userData;

// Puffs of white smoke rising from a chimney.
function smokeAt() {
  const f = new THREE.Group();
  for (let i = 0; i < 6; i++) {
    const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: fxTexture(i % 2 ? "whitePuff05" : "whitePuff00"), transparent: true, depthWrite: false, opacity: 0 }));
    s.userData.puff = i / 6;
    f.add(s);
  }
  return f;
}
function fireAt() {
  const f = new THREE.Group();
  for (let i = 0; i < 4; i++) {
    const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: fxTexture(['flame_01', 'flame_03', 'flame_05', 'flame_01'][i]), color: [0xff6a1a, 0xff9a2e, 0xffd24a, 0xff4a12][i], transparent: true, depthWrite: false }));
    s.position.set((i - 1.5) * .32, .7, 0); s.scale.set(1.5, 2.1, 1);
    f.add(s);
  }
  for (let i = 0; i < 5; i++) {
    const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: fxTexture(['blackSmoke00', 'blackSmoke05', 'blackSmoke10', 'blackSmoke15', 'blackSmoke05'][i]), transparent: true, depthWrite: false }));
    s.userData.puff = i / 5;
    f.add(s);
  }
  return f;
}
const signTexture = (() => {
  const c = document.createElement('canvas'); c.width = c.height = 128;
  const x = c.getContext('2d'), im = new Image();
  im.onload = () => { x.drawImage(im, 0, 0, 128, 128); x.font = '84px Bold, sans-serif'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.lineWidth = 10; x.strokeStyle = '#6b3e2e'; x.strokeText('!', 64, 70); x.fillStyle = '#ffd166'; x.fillText('!', 64, 70); t.needsUpdate = true; };
  im.src = 'kingdom/ui/round_brown.png';
  const t = new THREE.CanvasTexture(c); t.encoding = THREE.sRGBEncoding;
  return t;
})();

// * The living

// Kenney's Mini Characters, each with its own skeleton and its own mixer.
function person(name, tint) {
  const gltf = gltfs.get(name), o = THREE.SkeletonUtils.clone(gltf.scene), mixer = new THREE.AnimationMixer(o);
  o.scale.setScalar(1.1);
  if (tint) o.traverse(m => { if (m.isMesh) { m.material = m.material.clone(); m.material.transparent = true; m.material.opacity = .45; m.material.color.setRGB(.85, .92, 1); m.castShadow = false; } });
  const actions = Object.fromEntries(gltf.animations.map(a => [a.name, mixer.clipAction(a)]));
  let now = null;
  const play = pose => { if (now === pose) return; const a = actions[pose] ?? actions.idle; a.reset().fadeIn(.2).play(); actions[now]?.fadeOut(.2); now = pose; };
  play('idle');
  return { object: o, mixer, play };
}

// The more often a place runs, the more folk live there.
function settle(runs) {
  if (!W) return;
  const count = new Map();
  for (const r of runs) count.set(r.node, (count.get(r.node) ?? 0) + 1);
  for (const p of W.pts) {
    const want = Math.min(3, Math.round(Math.log2(1 + (count.get(p.id) ?? 0) / 2))) + (p.kind === 'you' ? 1 : 0);
    const have = W.villagers.filter(v => v.home === p);
    for (let n = have.length; n < want; n++) {
      const at = spotNear(W, p, 1.4, 3.2);
      if (!at) continue;
      const v = { home: p, ...person(PEOPLE[Math.floor(W.rand() * PEOPLE.length)]), at, to: null, wait: W.rand() * 3 };
      v.object.position.copy(at);
      W.group.add(v.object);
      W.villagers.push(v);
    }
    for (const v of have.slice(want)) { W.group.remove(v.object); W.villagers.splice(W.villagers.indexOf(v), 1); }
  }
}

function roadFor(kind, source, target, label) {
  return W?.roads.find(r => r.edge.kind === kind && r.edge.source === source && r.edge.target === target && (label == null || r.edge.label === label));
}

// Someone sets out along a way: a parrot for a trigger, else a walker.
function goes(road, bright) {
  if (!road?.curve) return;
  const kind = road.edge.kind;
  if (kind === 'trigger') {
    const o = model('pets/animal-parrot', 0, 0, 0, 0, .28);
    W.group.add(o);
    return folk.push({ road, s: 0, object: o, bright, speed: 7, bird: true });
  }
  const p = person(bright ? PEOPLE[kind === 'part' ? 2 : 0] : PEOPLE[Math.floor(W.rand() * PEOPLE.length)], !bright);
  p.play(kind === 'part' ? 'walk' : bright ? 'sprint' : 'walk');
  W.group.add(p.object);
  folk.push({ road, s: 0, ...p, bright, speed: bright ? (kind === 'part' ? 1.6 : 3.4) : 1.4 });
}

// A run began: who set out, and from where.
function arrived(r, byId) {
  if (!W) return;
  const p = r.parent && byId.get(r.parent);
  if (p) return goes(roadFor('part', p.node, r.node), true);
  for (const i of r.reactTo) {
    const c = byId.get(i);
    if (!c) continue;
    if (c.node.startsWith('trigger/')) {
      const from = c.reactTo.map(j => byId.get(j)?.node).find(Boolean) ?? '@you';
      return goes(roadFor('trigger', from, r.node, c.node.slice(8)), true);
    }
    return goes(roadFor('reaction', c.node, r.node), true);
  }
  const at = W.places.get(r.node);
  if (at) pulse(at, 0xffcf4a);
}

// A run went wrong.
function burned(r) {
  const at = W?.places.get(r.node);
  if (at) { pulse(at, 0xff5a4a, true); play('error_004'); }
}

function pulse(p, color, big) {
  const m = new THREE.Mesh(W.ring, new THREE.MeshBasicMaterial({ color, transparent: true, depthWrite: false }));
  m.position.set(p.x, p.y + .08, p.z);
  W.group.add(m);
  effects.push({ object: m, t0: performance.now(), for: big ? 2400 : 1500, grow: big ? 3 : 2 });
}

// Echoes: the roads are walked as often as they were used.
setInterval(() => {
  if (!W || document.hidden || folk.filter(f => !f.bright).length > 18) return;
  const used = W.roads.filter(r => r.edge.count > 0 && r.curve);
  let pick = W.rand() * d3.sum(used, r => Math.sqrt(r.edge.count));
  for (const road of used) if ((pick -= Math.sqrt(road.edge.count)) <= 0) return goes(road, false);
}, 2000);

// * Sound: the interface's clicks, and music if wanted

const sound = name => { const a = new Audio(`kingdom/sounds/${name}.ogg`); a.volume = .3; return a; };
function play(name) { sound(name).play().catch(() => {}); }
addEventListener('click', e => {
  if (e.target === canvas) return;
  if (e.target.closest('button')) play('click_002');
  else if (e.target.closest('summary')) play('bookFlip1');
  else if (e.target.closest('[data-select]')) play('select_001');
}, true);
let music = null;
const musicOn = () => { try { return localStorage.getItem('kingdom.music') === 'on'; } catch { return false; } };
function tune() {
  const want = musicOn() ? 'day' : null;
  if (music?.dataset.name === want) return;
  music?.pause();
  music = want ? Object.assign(new Audio(`kingdom/music/${want}.ogg`), { loop: true, volume: .25 }) : null;
  if (music) { music.dataset.name = want; music.play().catch(() => {}); }
  document.getElementById('music')?.classList.toggle('on', !!want);
}

// * Drawing a frame

let last = 0, lit = '';
function frame(ms) {
  requestAnimationFrame(frame);
  if (!W || document.hidden) return;
  const t = ms / 1000, dt = Math.min(.05, t - last);
  last = t;
  document.body.classList.remove('stale');
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * renderer.getPixelRatio()) || canvas.height !== Math.round(h * renderer.getPixelRatio())) {
    renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix();
  }
  lifeStep(W, t, dt);
  // The sun's shadows follow where one looks.
  const at = controls.target;
  sun.position.set(at.x - 30, at.y + 55, at.z + 22); sun.target.position.copy(at);
  const span = clamp(camera.position.distanceTo(at) * .9, 25, 110);
  Object.assign(sun.shadow.camera, { left: -span, right: span, top: span, bottom: -span, near: 1, far: 200 });
  sun.shadow.camera.updateProjectionMatrix();

  // How each place is.
  for (const p of W.pts) {
    const n = nodes.get(p.id), status = n?.status, ud = p.object.userData;
    p.fire.visible = status === 'bad';
    p.glow.visible = status === 'running';
    if (p.glow.visible) { p.glow.material.opacity = .45 + Math.sin(t * 4) * .25; p.glow.scale.setScalar(1 + Math.sin(t * 2) * .05); }
    if (ud.sails) ud.sails.rotateX(dt * (status === 'running' ? 5 : .7));
    if (ud.ghost) { ud.ghost.position.y = .3 + Math.sin(t * 1.6 + p.seed * 9) * .15; ud.ghost.rotation.y = Math.sin(t * .5) * .6; }
    if (p.fire.visible) p.fire.children.forEach((s, i) => {
      if (s.userData.puff == null) { s.scale.y = 2.1 * (1 + Math.sin(t * 13 + i * 2) * .18); s.material.opacity = .9 + Math.sin(t * 17 + i) * .1; return; }
      const ph = (t * .28 + s.userData.puff) % 1;
      s.position.set(Math.sin(ph * 5 + i) * .3 + ph * .8, 1 + ph * 4.5, 0); s.scale.setScalar(.8 + ph * 3); s.material.opacity = .65 * (1 - ph);
    });
    if (status === 'waiting') {
      p.sign ??= Object.assign(new THREE.Sprite(new THREE.SpriteMaterial({ map: signTexture, depthTest: false })), { renderOrder: 5 });
      if (!p.sign.parent) W.group.add(p.sign);
      p.sign.scale.setScalar(1.1);
      p.sign.position.set(p.x, p.y + p.height + .9 + Math.sin(t * 3) * .15, p.z);
    } else if (p.sign?.parent) W.group.remove(p.sign);
    if (p.chimney) p.chimney.children.forEach((s, i) => {
      const ph = (t * (status === "running" ? .45 : .18) + s.userData.puff) % 1;
      s.position.set(Math.sin(ph * 4 + i) * .15 + ph * .5, ph * 2.4, 0); s.scale.setScalar(.25 + ph * .9); s.material.opacity = (status === "running" ? .75 : .3) * (1 - ph) * smooth(0, .15, ph);
    });
  }
  const sel = W.places.get(selected);
  W.cursor.visible = !!sel;
  if (sel) { W.cursor.position.set(sel.x, sel.y + .07, sel.z); W.cursor.rotation.y = t * .4; W.cursor.scale.setScalar(sel.r / 1.8 + Math.sin(t * 3) * .03); }

  // Roads that matter now, and the parrots' ways.
  const key = selected + '|' + (hovering?.road?.edge.source ?? '') + (hovering?.road?.edge.target ?? '');
  if (key !== lit) {
    lit = key;
    W.highlight.clear();
    for (const r of W.roads) {
      const e = r.edge, mine = (selected && (e.source === selected || e.target === selected || (e.kind === 'trigger' && selected === 'trigger/' + e.label))) || r === hovering?.road;
      if (!mine || !r.curve || e.kind === 'trigger') continue;
      const lifted = new THREE.CatmullRomCurve3(r.pts.map(p => new THREE.Vector3(p.x, W.sample(p.x, p.z) + .08, p.z)));
      W.highlight.add(new THREE.Mesh(new THREE.TubeGeometry(lifted, Math.max(20, r.pts.length), .16, 6), new THREE.MeshBasicMaterial({ color: 0xffcf4a, transparent: true, opacity: .55, depthWrite: false })));
    }
  }
  for (const r of W.roads) if (r.mesh) {
    const e = r.edge, mine = selected && (e.source === selected || e.target === selected || selected === 'trigger/' + e.label);
    r.mesh.material.color.set(e.pending ? 0xffa62a : mine || r === hovering?.road ? 0xffcf4a : 0x9b6fd6);
    r.mesh.material.opacity = e.pending ? .6 + Math.sin(t * 4) * .3 : mine ? .9 : .45;
  }

  // Folk at home: they wander about, and act out how their place is.
  for (const v of W.villagers) {
    const status = nodes.get(v.home.id)?.status;
    v.mixer.update(dt);
    if (v.to) {
      const dir = v.to.clone().sub(v.object.position); dir.y = 0;
      const step = 1.1 * dt;
      if (dir.length() <= step) { v.to = null; v.wait = 2 + W.rand() * 5; }
      else { v.object.position.add(dir.setLength(step)); v.object.position.y = W.sample(v.object.position.x, v.object.position.z); v.object.rotation.y = Math.atan2(dir.x, dir.z); }
      v.play('walk');
    } else {
      v.play(status === 'waiting' ? 'emote-yes' : status === 'running' ? 'interact-right' : status === 'bad' ? 'emote-no' : 'idle');
      if ((v.wait -= dt) <= 0) v.to = spotNear(W, v.home, 1.4, 3.2, v.object.position);
    }
  }
  for (const pet of W.pets) {
    if (!pet.to) { if ((pet.wait -= dt) <= 0) { pet.to = spotNear(W, pet.home, 2, 4.5, pet.object.position); pet.wait = 2 + W.rand() * 6; } continue; }
    const dir = pet.to.clone().sub(pet.object.position); dir.y = 0;
    const step = .7 * dt;
    if (dir.length() <= step) { pet.to = null; continue; }
    pet.object.position.add(dir.setLength(step));
    pet.object.position.y = W.sample(pet.object.position.x, pet.object.position.z) + Math.abs(Math.sin(t * 9)) * .06;
    pet.object.rotation.y = Math.atan2(dir.x, dir.z);
  }
  // On the roads.
  for (let i = folk.length - 1; i >= 0; i--) {
    const f = folk[i];
    f.s += f.speed * dt;
    f.mixer?.update(dt);
    if (f.s >= f.road.len) {
      W.group.remove(f.object);
      folk.splice(i, 1);
      if (f.bright) pulse(f.road.to, 0xffcf4a);
      continue;
    }
    const u = f.s / f.road.len, p = f.road.curve.getPointAt(u), ahead = f.road.curve.getPointAt(Math.min(1, u + .01));
    f.object.position.copy(p);
    if (f.bird) { f.object.position.y += Math.sin(t * 9) * .08; f.object.rotation.z = Math.sin(t * 18) * .25; }
    else f.object.position.y = W.sample(p.x, p.z);
    f.object.rotation.y = Math.atan2(ahead.x - p.x, ahead.z - p.z);
  }
  // On the sea, and in the sky.
  for (const b of W.boats) {
    if (!b.to || b.object.position.distanceTo(b.to) < 1) b.to = seaSpot(W);
    if (!b.to) continue;
    const dir = b.to.clone().sub(b.object.position); dir.y = 0;
    const want = Math.atan2(dir.x, dir.z), turn = Math.atan2(Math.sin(want - b.object.rotation.y), Math.cos(want - b.object.rotation.y));
    b.object.rotation.y += clamp(turn, -dt * .4, dt * .4);
    b.object.position.x += Math.sin(b.object.rotation.y) * b.speed * dt; b.object.position.z += Math.cos(b.object.rotation.y) * b.speed * dt;
    b.object.position.y = Math.sin(t * 1.3 + b.speed * 9) * .06;
    b.object.rotation.z = Math.sin(t * 1.1 + b.speed * 5) * .05;
  }
  for (const c of W.clouds) { c.position.x += dt * .8; if (c.position.x > W.WX + 60) c.position.x = -60; }
  const now = performance.now();
  for (let i = effects.length - 1; i >= 0; i--) {
    const e = effects[i], a = (now - e.t0) / e.for;
    if (a >= 1) { W.group.remove(e.object); effects.splice(i, 1); continue; }
    e.object.scale.setScalar(1 + a * e.grow); e.object.material.opacity = 1 - a;
  }

  controls.update();
  batchStep(W);
  renderer.render(scene, camera);
  labels();
  tune();
}
if (!BENCH && !new URLSearchParams(location.search).has('roofs')) requestAnimationFrame(frame);

// * Names over the land, in the interface's own hand

const labelLayer = document.getElementById('labels');
function labels() {
  const v = new THREE.Vector3(), cw = canvas.clientWidth, ch = canvas.clientHeight, dist = camera.position.distanceTo(controls.target);
  for (const p of W.pts) {
    const n = nodes.get(p.id);
    if (!n) continue;
    if (!p.label) {
      p.label = document.createElement('div');
      p.label.className = 'place-label';
      p.label.dataset.select = p.id;
      labelLayer.append(p.label);
    }
    const status = n.status, html = `<span class="name">${esc(nameOf(p.id))}</span>${(n.ticks ?? []).length ? `<span class="ticks">${n.ticks.slice(-12).map(s => `<i class="${s}"></i>`).join('')}</span>` : ''}`;
    if (p.label.dataset.html !== html) { p.label.innerHTML = html; p.label.dataset.html = html; }
    p.label.className = `place-label ${status}${p.id === selected ? ' selected' : ''}`;
    v.set(p.x, p.y, p.z + p.r * .55).project(camera);
    const near = camera.position.distanceTo(new THREE.Vector3(p.x, p.y, p.z)), show = v.z < 1 && (near < 70 || status === 'bad' || status === 'waiting' || p.id === selected);
    p.label.style.display = show ? '' : 'none';
    if (show) {
      const s = clamp(28 / near, .55, 1.15);
      p.label.style.transform = `translate(${(v.x + 1) / 2 * cw}px, ${(1 - v.y) / 2 * ch}px) translate(-50%, 0) scale(${s})`;
      p.label.style.zIndex = Math.round(1000 - near);
    }
  }
  for (const r of W.realms) {
    if (!r.label) {
      r.label = document.createElement('div');
      r.label.className = 'realm-label';
      r.label.textContent = r.name;
      r.label.style.setProperty('--realm', r.colour);
      labelLayer.append(r.label);
    }
    v.set(r.cx, Math.max(...r.places.map(p => p.y + p.height)) + 2.5, r.z0 - .5).project(camera);
    const show = v.z < 1 && dist > 25;
    r.label.style.display = show ? '' : 'none';
    if (show) r.label.style.transform = `translate(${(v.x + 1) / 2 * cw}px, ${(1 - v.y) / 2 * ch}px) translate(-50%, -50%) scale(${clamp(90 / dist, .5, 1.1)})`;
  }
}

document.getElementById('music')?.addEventListener('click', () => { try { localStorage.setItem('kingdom.music', musicOn() ? 'off' : 'on'); } catch {} tune(); });

// * Looking around

function fit() {
  const cx = W.WX / 2, cz = W.WZ / 2, d = Math.max(W.WX - 2 * MARGIN + 30, (W.WZ - 2 * MARGIN + 30) * camera.aspect * .9) * 1.12;
  controls.target.set(cx, 0, cz);
  camera.position.set(cx, d * .85, cz + d * .72);
}
function glide(to, distance) {
  const from = [controls.target.clone(), camera.position.clone()], offset = camera.position.clone().sub(controls.target);
  if (distance) offset.setLength(distance);
  const t0 = performance.now();
  (function step() {
    const a = d3.easeCubicInOut(Math.min(1, (performance.now() - t0) / 1100));
    controls.target.lerpVectors(from[0], to, a);
    camera.position.lerpVectors(from[1], to.clone().add(offset), a);
    if (a < 1) requestAnimationFrame(step);
  })();
}
function flyTo(id) {
  const p = W?.places.get(id);
  if (p) glide(new THREE.Vector3(p.x, p.y, p.z), Math.min(camera.position.distanceTo(controls.target), 24));
}

const ray = new THREE.Raycaster();
function hit(ev) {
  if (!W) return null;
  const r = canvas.getBoundingClientRect();
  ray.setFromCamera({ x: (ev.clientX - r.left) / r.width * 2 - 1, y: -(ev.clientY - r.top) / r.height * 2 + 1 }, camera);
  const box = ray.intersectObjects(W.pts.map(p => p.hit))[0];
  if (box) return { place: box.object.userData.place };
  const ground = ray.intersectObject(W.ground)[0];
  if (!ground) return null;
  let best = null, bd = 1.1;
  for (const road of W.roads) if (road.pts) for (const q of road.pts) { const d = Math.hypot(q.x - ground.point.x, q.z - ground.point.z); if (d < bd) { bd = d; best = road; } }
  return best ? { road: best } : null;
}
const tip = document.getElementById('tip');
let downAt = null;
canvas.addEventListener('pointerdown', ev => { downAt = [ev.clientX, ev.clientY]; });
canvas.addEventListener('pointermove', ev => {
  if (ev.buttons) return;
  hovering = hit(ev);
  canvas.classList.toggle('pointing', !!hovering);
  if (!hovering) return tip.hidden = true;
  const n = hovering.place && nodes.get(hovering.place.id), e = hovering.road?.edge;
  tip.innerHTML = n
    ? `<b>${esc(topicOf(n))}</b><br>${esc(caption(n))}${n.problems?.length ? `<br><span class="bad">${esc(n.problems[0])}</span>` : ''}`
    : `<b>${esc({ reaction: 'A road', part: 'A trail of stepping stones', awaited: 'A faint trail' }[e.kind])}</b><br>${esc(laneName(e.source))} → ${esc(laneName(e.target))}<br>${esc(e.kind === 'awaited' ? 'expected, never walked' : e.kind === 'part' ? 'part of its runs' : 'reacted to')}${e.count ? ` · walked ${e.count} times` : ''}`;
  tip.hidden = false;
  tip.style.left = Math.min(ev.clientX + 18, innerWidth - 320) + 'px';
  tip.style.top = ev.clientY + 18 + 'px';
});
canvas.addEventListener('pointerleave', () => { hovering = null; tip.hidden = true; });
canvas.addEventListener('click', ev => {
  if (downAt && Math.hypot(ev.clientX - downAt[0], ev.clientY - downAt[1]) > 4) return;
  const h = hit(ev);
  if (h) play('select_001');
  select(h?.place ? h.place.id : h?.road ? h.road.edge.target : '');
});

// * The legend's pictures, of the buildings themselves

let legendCache = null, snapRenderer = null;
function snapshot(object, { w = 76, h = 64, d = 9, y = 1.4 } = {}) {
  snapRenderer ??= new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
  snapRenderer.outputEncoding = THREE.sRGBEncoding;
  snapRenderer.setPixelRatio(2); snapRenderer.setSize(w, h, false);
  const cam = new THREE.PerspectiveCamera(30, w / h, .1, 100);
  cam.position.set(d * .55, y + d * .5, d * .75); cam.lookAt(0, y, 0);
  const s = new THREE.Scene();
  s.add(new THREE.HemisphereLight(0xdfeaff, 0x6f7a52, .55));
  const l = new THREE.DirectionalLight(0xfff1dc, .8); l.position.set(-3, 6, 4); s.add(l, object);
  snapRenderer.render(s, cam);
  return `<img src="${snapRenderer.domElement.toDataURL()}" width="${w}" height="${h}" alt="">`;
}
function legendPictures() {
  if (legendCache || !gltfs.get('town/wall')?.scene || !gltfs.get('pets/animal-parrot')?.scene) return legendCache ?? {};
  const rand = mulberry(5), b = kind => snapshot(BUILDINGS[kind]({ rand, colour: '#c0392b' }), { d: kind === 'you' ? 13 : kind === 'dashboard' ? 11 : 9, y: kind === 'ghost' ? .7 : 1.4 });
  const tube = color => { const c = new THREE.QuadraticBezierCurve3(new THREE.Vector3(-2, 0, 0), new THREE.Vector3(0, 2, 0), new THREE.Vector3(2, 0, 0)); return new THREE.Mesh(new THREE.TubeGeometry(c, 24, .08, 6), new THREE.MeshBasicMaterial({ color })); };
  return legendCache = {
    hall: b('hall'), server: b('server'), script: b('script'), healthcheck: b('healthcheck'), system: b('system'), dashboard: b('dashboard'), you: b('you'), ghost: b('ghost'),
    parrot: snapshot(group(tube(0x9b6fd6), model('pets/animal-parrot', 0, 2, 0, -.6, .5)), { d: 7, y: 1 }),
    pending: snapshot(tube(0xffa62a), { d: 7, y: 1 }),
    folk: snapshot(group(model('people/character-male-a', -.6, 0, 0, .4, 1.1), model('people/character-female-b', .6, 0, .2, -.3, 1.1)), { d: 4, y: .5 }),
  };
}
function legendHtml() {
  const p = legendPictures(), row = (pic, text) => `${pic ?? '<span></span>'}<span>${text}</span>`;
  return `<h2>How to read the kingdom</h2>
    <p class="dim">Each project is a realm, each topic a building in it; an event with subtasks is a small town, its town hall the event and a building for each subtask about it. Click anything for its runs; drag to move, right-drag to turn, scroll to zoom.</p>
    <div class="legend">
    ${row(p.hall, 'a town hall: an event with subtasks, its belfry over the town of them')}
    ${row(p.server, 'a town house: a server, answering requests; its chimney smokes while it runs')}
    ${row(p.script, 'a windmill among its fields: a script; its sails race while it runs')}
    ${row(p.healthcheck, 'a watchtower: a service’s health')}
    ${row(p.system, 'a mine in the rock: a machine')}
    ${row(p.dashboard, 'the seer’s tower: the dashboard’s own announcements')}
    ${row(p.you, 'your castle: triggers you can send')}
    ${row(p.ghost, 'a haunted grave: expected, but it hasn’t happened')}
    ${row(null, 'On fire, its folk shaking their heads: something is wrong. A golden ring, its folk at work: running now. A “!” over it, its folk waving: a trigger waits for you.')}
    ${row(null, 'A road between towns: what ran because the other finished, lanterns along it, bridges over rivers. Stepping stones: a subtask within its parent’s runs. Faint stones: a reaction a run expects that hasn’t come.')}
    ${row(p.parrot, 'a parrot’s way: a trigger, carried from what announced it to what reacted')}
    ${row(p.pending, 'an orange way: a trigger that waits for you')}
    ${row(p.folk, 'Folk running in colour are runs happening now; pale ones walk each road as often as it was used. The more often a place runs, the more folk live there.')}
    </div><p class="dim">The marks under each name are its last runs, oldest first.</p>`;
}

// * Making and remaking

let shapeOfWorld = '';
async function worldFor(sys) {
  const s = sys.nodes.map(n => n.id + ':' + n.kind + ':' + (n.status === 'unseen')).sort().join() + '|' + sys.edges.map(e => [e.kind, e.source, e.target, e.label].join(':')).sort().join();
  if (s === shapeOfWorld) {
    for (const road of W?.roads ?? []) road.edge = sys.edges.find(e => e.kind === road.edge.kind && e.source === road.edge.source && e.target === road.edge.target && e.label === road.edge.label) ?? road.edge;
    return false;
  }
  shapeOfWorld = s;
  const old = W, made = await generate(sys);
  if (old) { scene.remove(old.group); old.pts.forEach(p => p.label?.remove()); old.realms.forEach(r => r.label?.remove()); }
  scene.add(made.group);
  W = made;
  folk.length = 0;
  if (!old) fit();
  return true;
}
