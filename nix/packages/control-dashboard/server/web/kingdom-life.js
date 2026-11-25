'use strict';

// Life about the land: wind in the leaves, rivers running and falling, fish
// leaping, gulls wheeling, carts on the roads, canoes on the lakes, folk
// strolling and sitting about their fires, snow in the north. Made once per world by `life`, moved every frame by `lifeStep`.

const LIFE_MODELS = ['pets/animal-fish', 'pets/animal-parrot', 'pets/animal-cow', 'town/cart', 'nature/canoe', 'nature/campfire_logs', 'nature/log', 'town/watermill', 'town/wall-block'];

// Wind: whatever grows sways, the more the higher up it, in gusts.
const wind = { value: 0 };
const SWAYS = /tree|plant|grass|flower|bush|crop|cactus|palm|pine|hedge|lily/;
const swayed = new Map();
function swaying(material) {
  if (swayed.has(material)) return swayed.get(material);
  const m = material.clone();
  swayed.set(material, m);
  m.onBeforeCompile = s => {
    s.uniforms.wind = wind;
    s.vertexShader = 'uniform float wind;\n' + s.vertexShader.replace('#include <begin_vertex>', `#include <begin_vertex>
      #ifdef USE_INSTANCING
        float ph = instanceMatrix[3].x * .37 + instanceMatrix[3].z * .23, hh = max(position.y, 0.), gust = .55 + .45 * sin(wind * .45 + ph * .15);
        transformed.x += sin(wind * 1.9 + ph) * .05 * hh * hh * gust;
        transformed.z += cos(wind * 1.4 + ph * 1.3) * .035 * hh * hh * gust;
      #endif`);
  };
  m.customProgramCacheKey = () => 'sway';
  return m;
}

// Streaks on running water, scrolled downstream.
const flowMap = (() => {
  const c = document.createElement('canvas'); c.width = 32; c.height = 128;
  const x = c.getContext('2d'), r = mulberry(11);
  x.fillStyle = '#d4e6ee'; x.fillRect(0, 0, 32, 128);
  x.fillStyle = '#ffffff';
  for (let i = 0; i < 26; i++) x.fillRect(Math.floor(r() * 30), Math.floor(r() * 128), 1 + Math.floor(r() * 2), 6 + Math.floor(r() * 14));
  const t = new THREE.CanvasTexture(c);
  t.wrapS = t.wrapT = THREE.RepeatWrapping; t.encoding = THREE.sRGBEncoding;
  return t;
})();

function puff(name, opacity = 0) { return new THREE.Sprite(new THREE.SpriteMaterial({ map: fxTexture(name), transparent: true, depthWrite: false, opacity })); }

// A white bird: Kenney's parrot, bleached into a gull.
let gullMat = null;
function gull() {
  const o = model('pets/animal-parrot', 0, 0, 0, 0, .2);
  o.traverse(m => { if (m.isMesh) { m.material = gullMat ??= Object.assign(m.material.clone(), { map: null, color: new THREE.Color(0xf4f4f0) }); m.castShadow = false; } });
  return o;
}

function life(Wd) {
  const { rand, land: L, group: g } = Wd, pick = xs => xs[Math.floor(rand() * xs.length)];
  const L2 = Wd.life = { falls: [], fish: [], flocks: [], carts: [], canoes: [], strollers: [], fires: [], mills: [], splashes: [] };

  // Waterfalls, wherever a river drops sharply: foam, and mist rising.
  for (const r of Wd.rivers) for (let i = 4; i < r.pts.length; i++) {
    const p = r.pts[i];
    if (r.pts[i - 4].y - p.y < .55 || L2.falls.some(f => f.at.distanceTo(p) < 4)) continue;
    const f = { at: p.clone(), puffs: [] };
    for (let k = 0; k < 7; k++) { const s = puff(k % 2 ? 'whitePuff05' : 'whitePuff10'); s.userData.phase = k / 7; f.puffs.push(s); g.add(s); }
    L2.falls.push(f);
  }

  // Watermills on the rivers near the towns.
  for (const r of Wd.rivers) for (let i = 6; i < r.pts.length - 6 && L2.mills.length < 4; i += 3) {
    const p = r.pts[i], d = Wd.nearest(p.x, p.z);
    if (d < 3 || d > 9 || r.width[i] > .8 || L2.mills.some(m => m.position.distanceTo(p) < 25)) continue;
    const a = r.pts[i - 1], b = r.pts[i + 1], dx = b.x - a.x, dz = b.z - a.z, l = Math.hypot(dx, dz), w = r.width[i] + .55;
    const nx = -dz / l, nz = dx / l, bank = Wd.sample(p.x + nx * (w + 1.2), p.z + nz * (w + 1.2));
    if (bank - p.y > 2) continue;
    const wheel = model('town/watermill', p.x + nx * w * .55, p.y - .1, p.z + nz * w * .55, Math.atan2(dx, dz), .8);
    const hut = house({ w: 1, d: 1, floors: 1, rand, chimney: true, timber: true });
    hut.position.set(p.x + nx * (w + .8), bank, p.z + nz * (w + .8)); hut.rotation.y = Math.atan2(nx, nz);
    g.add(wheel, hut);
    L2.mills.push(wheel);
  }

  // Fish, leaping from lakes and the sea.
  const waters = [...L.lakes.flatMap(l => l.cells.filter((_, i) => i % 3 === 0).map(k => new THREE.Vector3(L.X(k), l.level, L.Z(k))))];
  for (let n = 0; n < 400 && waters.length < 300; n++) { const x = rand() * Wd.WX, z = rand() * Wd.WZ, y = Wd.sample(x, z); if (y < -.4 && y > -2.5) waters.push(new THREE.Vector3(x, 0, z)); }
  L2.waters = waters;
  for (let i = 0; i < 5 && waters.length; i++) { const o = model('pets/animal-fish', 0, 0, 0, 0, .13); o.visible = false; g.add(o); L2.fish.push({ object: o, wait: rand() * 6, t: 0 }); }

  // Gulls, wheeling in flocks over the land and the coasts.
  for (let i = 0; i < 4; i++) {
    const flock = { x: rand() * Wd.WX, z: rand() * Wd.WZ, heading: rand() * 6.28, birds: [], seed: rand() * 100 };
    for (let k = 0; k < 5 + Math.floor(rand() * 5); k++) { const o = gull(); g.add(o); flock.birds.push({ object: o, r: 1.5 + rand() * 2.5, a: rand() * 6.28, h: rand() * 1.5, v: .5 + rand() * .3 }); }
    L2.flocks.push(flock);
  }

  // Carts on the main roads, drawn by a cow, a driver up front.
  for (const r of Wd.roads.filter(r => r.width > .5 && r.len > 14)) {
    if (L2.carts.length >= 6 || rand() < .4) continue;
    const cart = model('town/cart', 0, 0, 0, 0, .5), cow = model('pets/animal-cow', 0, 0, .8, 0, .2), who = person(pick(PEOPLE));
    who.play('sit'); who.object.scale.setScalar(.8); who.object.position.set(0, .2, .05);
    const o = group(cart, cow, who.object);
    g.add(o);
    L2.carts.push({ road: r, object: o, who, s: rand() * r.len, dir: 1, wait: 0 });
  }

  // Canoes on the lakes, rowed about.
  for (const lake of L.lakes) {
    if (lake.cells.length < 40) continue;
    const k = pick(lake.cells), who = person(pick(PEOPLE));
    who.play('sit'); who.object.scale.setScalar(.75); who.object.position.y = -.12;
    const o = group(model('nature/canoe', 0, 0, 0, 0, 1.3), who.object);
    o.position.set(L.X(k), lake.level + .02, L.Z(k));
    g.add(o);
    L2.canoes.push({ lake, object: o, who, to: null });
  }

  // In each town, a fire with folk sat about it, and folk strolling its lanes.
  for (const r of Wd.realms) {
    const at = (() => { for (let n = 0; n < 40; n++) { const p = pick(r.places), a = rand() * 6.28, d = p.r + 1.5 + rand() * 2, x = p.x + Math.cos(a) * d, z = p.z + Math.sin(a) * d, k = L.cell(x, z); if (Wd.nearest(x, z) > 1 && Wd.roadD[k] > 1.5 && Wd.riverD[k] > 1.5 && L.lake[k] < 0 && Wd.sample(x, z) > .4 && Math.abs(Wd.sample(x + 1, z) - Wd.sample(x - 1, z)) < .4) return new THREE.Vector3(x, Wd.sample(x, z), z); } return null; })();
    if (at) {
      const flames = [0, 1].map(i => { const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: fxTexture(i ? 'flame_03' : 'flame_01'), color: i ? 0xffb03a : 0xff6a1a, transparent: true, depthWrite: false })); s.scale.set(.5, .7, 1); s.position.set(at.x + (i - .5) * .1, at.y + .3, at.z); g.add(s); return s; });
      const smoke = [0, 1, 2, 3].map(i => { const s = puff('whitePuff00'); s.userData.phase = i / 4; g.add(s); return s; });
      const glow = glowSprite(0xffa040, 3.2); glow.position.set(at.x, at.y + .4, at.z); g.add(glow);
      g.add(model('nature/campfire_logs', at.x, at.y, at.z, rand() * 6, 1.1));
      const folk = [];
      const n = 2 + Math.floor(rand() * 2);
      for (let i = 0; i < n; i++) {
        const a = i / n * 6.28 + rand() * .4, x = at.x + Math.cos(a) * 1.05, z = at.z + Math.sin(a) * 1.05, who = person(pick(PEOPLE));
        who.play(rand() < .7 ? 'sit' : 'idle');
        who.object.position.set(x, Wd.sample(x, z), z); who.object.rotation.y = Math.atan2(at.x - x, at.z - z);
        g.add(who.object, model('nature/log', x - Math.cos(a) * .05, Wd.sample(x, z), z - Math.sin(a) * .05, -a, .55));
        folk.push(who);
      }
      L2.fires.push({ flames, smoke, glow, folk, at });
    }
    const lanes = Wd.roads.filter(w => w.pts && w.from.realm === r.n && w.to.realm === r.n);
    for (let i = 0; i < Math.min(3, lanes.length); i++) {
      const road = pick(lanes), who = person(pick(PEOPLE));
      g.add(who.object);
      L2.strollers.push({ road, ...who, s: rand() * road.len, dir: rand() < .5 ? 1 : -1, wait: rand() * 3, speed: .7 + rand() * .3 });
    }
  }

  // Snow falling over the snowy north.
  const snowy = [];
  for (let n = 0; n < 4000 && snowy.length < 1600; n++) { const x = rand() * Wd.WX, z = rand() * Wd.WZ; if (BIOME_NAMES[L.biome[L.cell(x, z)]] === 'snow') snowy.push(x, Wd.sample(x, z), z); }
  if (snowy.length) {
    L2.snowBase = Float32Array.from(snowy);
    L2.snow = new THREE.Points(new THREE.BufferGeometry().setAttribute('position', new THREE.Float32BufferAttribute(snowy, 3)), new THREE.PointsMaterial({ color: 0xffffff, map: softGlow, size: .35, transparent: true, depthWrite: false, opacity: .9 }));
    g.add(L2.snow);
  }
}

// Where a person or cart is along a road, and which way it faces.
function along(Wd, road, s, dir) {
  const u = clamp(s / road.len, 0, 1), p = road.curve.getPointAt(u), q = road.curve.getPointAt(clamp(u + .01 * dir, 0, 1));
  return [new THREE.Vector3(p.x, Wd.sample(p.x, p.z), p.z), Math.atan2(q.x - p.x, q.z - p.z) + (u >= 1 && dir > 0 || u <= 0 && dir < 0 ? Math.PI : 0)];
}

function splash(Wd, at) {
  const s = puff('whitePuff15', .8);
  s.position.copy(at); s.position.y += .1; s.scale.setScalar(.3);
  Wd.group.add(s);
  Wd.life.splashes.push({ object: s, t: 0 });
}

function lifeStep(Wd, t, dt) {
  const L2 = Wd.life;
  wind.value = t;
  flowMap.offset.y -= dt * .45;

  for (const f of L2.falls) f.puffs.forEach((s, i) => {
    const ph = (t * .5 + s.userData.phase) % 1;
    s.position.set(f.at.x + Math.sin(i * 2.1) * .5 * ph, f.at.y - .2 + ph * 1.4, f.at.z + Math.cos(i * 1.7) * .5 * ph);
    s.scale.setScalar(.4 + ph * 1.1); s.material.opacity = .7 * (1 - ph);
  });
  for (const m of L2.mills) m.rotateX(-dt * 1.2);

  for (const f of L2.fish) {
    if (!f.object.visible) {
      if ((f.wait -= dt) > 0) continue;
      const w = L2.waters[Math.floor(Wd.rand() * L2.waters.length)], a = Wd.rand() * 6.28;
      Object.assign(f, { from: w.clone(), dx: Math.cos(a), dz: Math.sin(a), t: 0 });
      f.object.visible = true; f.object.rotation.y = Math.atan2(-f.dz, f.dx);
      splash(Wd, w);
    }
    f.t += dt / 1.1;
    const u = f.t, h = 4 * u * (1 - u) * .9;
    f.object.position.set(f.from.x + f.dx * u * 1.4, f.from.y - .15 + h, f.from.z + f.dz * u * 1.4);
    f.object.rotation.z = (1 - 2 * u) * 1.1;
    if (u >= 1) { f.object.visible = false; f.wait = 1.5 + Wd.rand() * 5; splash(Wd, f.object.position); }
  }
  for (let i = L2.splashes.length - 1; i >= 0; i--) {
    const s = L2.splashes[i];
    s.t += dt / .7;
    s.object.scale.setScalar(.3 + s.t * .8); s.object.material.opacity = .8 * (1 - s.t);
    if (s.t >= 1) { Wd.group.remove(s.object); L2.splashes.splice(i, 1); }
  }

  for (const f of L2.flocks) {
    f.heading += Math.sin(t * .1 + f.seed) * dt * .25;
    const nx = f.x + Math.sin(f.heading) * dt * 2.2, nz = f.z + Math.cos(f.heading) * dt * 2.2;
    if (nx < 10 || nz < 10 || nx > Wd.WX - 10 || nz > Wd.WZ - 10) f.heading += dt * 1.5; else { f.x = nx; f.z = nz; }
    const base = Math.max(0, Wd.sample(f.x, f.z)) + 11;
    for (const b of f.birds) {
      b.a += dt * b.v;
      const x = f.x + Math.cos(b.a) * b.r, z = f.z + Math.sin(b.a) * b.r;
      b.object.position.set(x, base + b.h + Math.sin(t * 2 + b.r) * .25, z);
      b.object.rotation.set(0, -b.a + Math.PI, Math.sin(t * 14 + b.r * 9) * .35 - .35);
    }
  }

  for (const c of L2.carts) {
    c.who.mixer.update(dt);
    if (c.wait > 0) { c.wait -= dt; continue; }
    c.s += c.dir * dt * .9;
    if (c.s > c.road.len || c.s < 0) { c.dir *= -1; c.s = clamp(c.s, 0, c.road.len); c.wait = 4 + Wd.rand() * 6; }
    const [p, rot] = along(Wd, c.road, c.s, c.dir);
    c.object.position.copy(p); c.object.position.y += Math.abs(Math.sin(t * 7)) * .015; c.object.rotation.y = rot;
  }

  for (const c of L2.canoes) {
    c.who.mixer.update(dt);
    if (!c.to || c.object.position.distanceTo(c.to) < .6) { const k = c.lake.cells[Math.floor(Wd.rand() * c.lake.cells.length)]; c.to = new THREE.Vector3(Wd.land.X(k), c.lake.level + .02, Wd.land.Z(k)); }
    const dir = c.to.clone().sub(c.object.position), want = Math.atan2(dir.x, dir.z), turn = Math.atan2(Math.sin(want - c.object.rotation.y), Math.cos(want - c.object.rotation.y));
    c.object.rotation.y += clamp(turn, -dt * .6, dt * .6);
    c.object.position.x += Math.sin(c.object.rotation.y) * dt * .6; c.object.position.z += Math.cos(c.object.rotation.y) * dt * .6;
    c.object.position.y = c.lake.level + .02 + Math.sin(t * 1.5) * .02;
  }

  for (const f of L2.fires) {
    f.flames.forEach((s, i) => { s.scale.y = .7 * (1 + Math.sin(t * 13 + i * 2) * .2); s.material.opacity = .85 + Math.sin(t * 17 + i) * .15; });
    f.smoke.forEach((s, i) => { const ph = (t * .25 + s.userData.phase) % 1; s.position.set(f.at.x + Math.sin(ph * 4 + i) * .2 + ph * .4, f.at.y + .6 + ph * 2.4, f.at.z); s.scale.setScalar(.25 + ph * .9); s.material.opacity = .35 * (1 - ph) * smooth(0, .15, ph); });
    f.glow.material.opacity = .25 * (.9 + Math.sin(t * 9) * .1);
    for (const w of f.folk) w.mixer.update(dt);
  }

  for (const v of L2.strollers) {
    v.mixer.update(dt);
    if (v.wait > 0) { v.wait -= dt; v.play('idle'); continue; }
    v.s += v.dir * dt * v.speed;
    if (v.s > v.road.len - 1.5 || v.s < 1.5) { v.dir *= -1; v.s = clamp(v.s, 1.5, v.road.len - 1.5); v.wait = 2 + Wd.rand() * 6; continue; }
    const [p, rot] = along(Wd, v.road, v.s, v.dir);
    v.object.position.copy(p); v.object.rotation.y = rot;
    v.play('walk');
  }

  if (L2.snow) {
    const a = L2.snow.geometry.attributes.position, b = L2.snowBase;
    for (let i = 0; i < a.count; i++) {
      const fall = (t * .9 + i * .37) % 14;
      a.array[i * 3] = b[i * 3] + Math.sin(t * .7 + i) * .4; a.array[i * 3 + 1] = b[i * 3 + 1] + 14 - fall; a.array[i * 3 + 2] = b[i * 3 + 2] + Math.cos(t * .5 + i) * .4;
    }
    a.needsUpdate = true;
  }
}
