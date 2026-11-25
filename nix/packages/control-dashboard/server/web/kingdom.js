'use strict';

// The system as a living kingdom, built from Kenney's 3D kits: a land of
// hills, rivers, woods and coasts; each project a town, each topic a building
// composed of Fantasy Town, Castle, Graveyard, Nature and Survival pieces; and
// what reacts to what a road, the cheapest way over the land by A*, through
// ground whose cost wanders with noise. Runs are Mini Characters walking the
// roads, triggers parrots flying between towns.

const canvas = document.getElementById('world');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
renderer.setPixelRatio(Math.min(2, devicePixelRatio || 1));
renderer.outputEncoding = THREE.sRGBEncoding;


renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(32, 1, .3, 900);
const controls = new THREE.MapControls(camera, canvas);
Object.assign(controls, { enableDamping: true, dampingFactor: .1, screenSpacePanning: false, minDistance: 6, maxDistance: 260, maxPolarAngle: 1.2, minPolarAngle: .25, zoomSpeed: 1.2 });

const hemi = new THREE.HemisphereLight(0xdfeaff, 0x6f7a52, .5);
const sun = new THREE.DirectionalLight(0xfff1dc, .75);
sun.castShadow = true;
sun.shadow.mapSize.set(4096, 4096);
sun.shadow.bias = -.0005;
sun.shadow.normalBias = .03;
scene.add(hemi, sun, sun.target);
scene.fog = new THREE.Fog(0xcfe3f0, 160, 520);

const BENCH = new URLSearchParams(location.search).has('bench');

function mulberry(a) {
  return () => {
    a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
function hashOf(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619); return h >>> 0; }
const lerp = (a, b, t) => a + (b - a) * t;
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const smooth = (a, b, v) => { const t = clamp((v - a) / (b - a)); return t * t * (3 - 2 * t); };
const Q = Math.PI / 2;

// * The sky: a gradient dome

const sky = new THREE.Mesh(new THREE.SphereGeometry(600, 32, 16), new THREE.ShaderMaterial({
  side: THREE.BackSide, depthWrite: false, fog: false,
  uniforms: { top: { value: new THREE.Color(0x5d9ad6) }, bottom: { value: new THREE.Color(0xd8ecf5) } },
  vertexShader: 'varying vec3 p; void main() { p = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.); }',
  fragmentShader: 'uniform vec3 top; uniform vec3 bottom; varying vec3 p; void main() { float h = clamp(normalize(p).y * 1.6 + .15, 0., 1.); gl_FragColor = vec4(mix(bottom, top, h), 1.); }',
}));
scene.add(sky);

// * The kits

const loader = new THREE.GLTFLoader(), gltfs = new Map(), materials = new Map();
// The Nature Kit's cyan leaves and stone, made the greens and greys of the other kits.
const RECOLOUR = { leafsGreen: 0x1d6a10, leafsDark: 0x0a3a12, grass: 0x2a7a14, stone: 0x656e71, stoneDark: 0x41494b };
const KITS = { town: 'kingdom/town', castle: 'kingdom/castle', nature: 'kingdom/nature', graveyard: 'kingdom/graveyard', pets: 'kingdom/pets', survival: 'kingdom/survival', boats: 'kingdom/boats', holiday: 'kingdom/holiday', people: 'kingdom/characters' };
function load(name) {
  if (!gltfs.has(name)) {
    const [kit, model] = name.split('/');
    gltfs.set(name, loader.loadAsync(`${KITS[kit]}/${model}.glb`).then(g => {
      // One material for each of a kit's, its colormap shared.
      g.scene.traverse(o => {
        if (!o.isMesh) return;
        o.castShadow = o.receiveShadow = true;
        const m = o.material;
        m.metalness = 0;
        if (kit === 'nature' && RECOLOUR[m.name]) m.color.set(RECOLOUR[m.name]);
        if (m.map) m.map.anisotropy = 4;
        const key = [kit, m.name, m.color.getHexString(), m.map?.name, m.transparent].join('|');
        if (!materials.has(key)) materials.set(key, m);
        o.material = materials.get(key);
      });
      gltfs.set(name, g);
      return g;
    }));
  }
  return gltfs.get(name);
}
const ready = names => Promise.all(names.map(load));
// A model, placed: its kit and name, where, turned which way, how big.
function model(name, x = 0, y = 0, z = 0, rot = 0, s = 1) {
  const g = gltfs.get(name);
  if (!g?.scene) throw new Error('not loaded: ' + name);
  const o = g.scene.clone(true);
  o.position.set(x, y, z); o.rotation.y = rot; o.scale.setScalar(s);
  return o;
}
function group(...xs) { const g = new THREE.Group(); xs.flat().forEach(x => x && g.add(x)); return g; }

// * Buildings, composed

// A house: w by d cells, of some floors, stone below and timber above, its
// door on the south (+z) side, and a gable roof along x.
function house({ w = 2, d = 1, floors = 2, timber = true, rand, door = 0, chimney = true, banner }) {
  const g = new THREE.Group();
  // Walls stand on a cell's +x edge; turned to face each side.
  const side = (name, i, j, f, dir) => g.add(model('town/' + name, i, f, j, [0, Q, 2 * Q, -Q][dir]));
  for (let f = 0; f < floors; f++) {
    const kind = f === 0 ? 'wall' : timber ? 'wall-wood' : 'wall', pick = () => rand() < .5 ? `${kind}-window-shutters` : rand() < .5 ? `${kind}-window-glass` : `${kind}-window-small`;
    for (let i = 0; i < w; i++) {
      const front = f === 0 && i === door ? `${kind}-door` : pick();
      side(front, i, d - 1, f, 3);
      side(f ? pick() : kind, i, 0, f, 1);
    }
    for (let j = 0; j < d; j++) { side(pick(), w - 1, j, f, 0); side(pick(), 0, j, f, 2); }
  }
  // A gable over each cell, like a row of town houses.
  for (let i = 0; i < w; i++) for (let j = 0; j < d; j++) g.add(model('town/roof-gable', i, floors, j));
  if (chimney) g.add(model('town/chimney', w - 1, floors - .1, 0));
  if (banner) g.add(model(`town/banner-${banner}`, 0, 0, d - 1, -Q));
  g.position.set(-(w - 1) / 2, 0, -(d - 1) / 2);
  const outer = group(g);
  outer.userData = { height: floors + .7, smoke: new THREE.Vector3(w / 2 - .2, floors + 1.2, -(d - 1) / 2) };
  return outer;
}

// A town hall: a wide hall of stone, a belfry over its door, its banner.
function hall({ rand }) {
  const g = group(house({ w: 3, d: 2, floors: 2, timber: false, rand, door: 1, chimney: false, banner: 'green' }),
    model('castle/tower-square-mid-windows', 0, 1.95, .5, 0, .8), model('castle/tower-square-top-roof-high', 0, 2.75, .5, 0, .8), model('castle/flag', 0, 3.7, .5, 0, .8));
  g.userData = { height: 4.4 };
  return g;
}

// A windmill: a stone tower with sails that turn.
function windmill({ rand }) {
  const g = new THREE.Group();
  for (let f = 0; f < 3; f++) for (let r = 0; r < 4; r++) g.add(model('town/' + (f === 0 && r === 3 ? 'wall-door' : f ? (rand() < .4 ? 'wall-window-small' : 'wall') : 'wall'), 0, f, 0, r * Q));
  g.add(model('town/roof-high-point', 0, 3, 0));
  const sails = model('town/windmill', 0, 2.55, .62, Q);
  g.add(sails);
  g.userData = { height: 4, sails };
  return g;
}

// A watchtower: a hexagonal stone tower, a pennant on top.
function watchtower({ colour }) {
  const g = group(model('castle/tower-hexagon-base'), model('castle/tower-hexagon-mid', 0, 1.31), model('castle/tower-hexagon-mid', 0, 1.77), model('castle/tower-hexagon-roof', 0, 2.23), model('castle/flag-pennant', 0, 3.02, 0));
  g.userData = { height: 3.9, flag: colour };
  return g;
}

// A mine: a cave in the rock, a cart, tools and a lantern.
function mine({ rand }) {
  // A hill of rock, a timbered mouth into it, rails out to a cart.
  const g = group(
    model('nature/rock_tallA', 0, 0, -.5, 0, 2.2), model('nature/rock_tallA', -1, 0, -.2, 2.5, 1.5), model('nature/rock_tallA', 1, 0, -.3, 3.6, 1.6),
    model('nature/rock_largeD', -1.3, 0, .6, rand() * 6, 1.1), model('nature/rock_tallC', 1.3, 0, .5, rand() * 6, 1.3),
    model('town/pillar-wood', -.4, 0, .45, 0, 1.1), model('town/pillar-wood', .4, 0, .45, 0, 1.1), model('town/planks', 0, 1.05, .45, 0, .9),
    model('nature/path_wood', 0, 0, .95, Q), model('nature/path_wood', 0, 0, 1.9, Q),
    model('town/cart', .1, 0, 1.6, Q, .7), model('survival/tool-pickaxe', -.8, 0, 1.2, .8, 1.6), model('survival/workbench-anvil', 1, 0, 1.2, .4, 1.6),
    model('town/lantern', .55, 0, .7, 0, .55),
  );
  const mouth = new THREE.Mesh(new THREE.PlaneGeometry(.8, 1), new THREE.MeshBasicMaterial({ color: 0x1b1410 }));
  mouth.position.set(0, .5, .42);
  g.add(mouth);
  g.userData = { height: 1.9, smoke: new THREE.Vector3(-.2, 1.8, -.4) };
  return g;
}

// The seer's tower: tall, square, roofed high, a long banner down its side.
function seer({ colour }) {
  const g = group(model('castle/tower-square-base'), model('castle/tower-square-mid-windows', 0, 1.01), model('castle/tower-square-mid-windows', 0, 2.02),
    model('castle/tower-square-top-roof-high', 0, 3.03), model('castle/flag-banner-long', .51, .9, 0), model('nature/statue_ring', 1.1, 0, .8, .3));
  g.userData = { height: 4.6, flag: colour };
  return g;
}

// A castle: walls about a keep, towers at its corners, a gate to the south.
function castle({ colour }) {
  const g = new THREE.Group();
  for (const [x, z] of [[-1.5, -1.5], [1.5, -1.5], [-1.5, 1.5], [1.5, 1.5]]) g.add(model('castle/tower-square-base', x, 0, z), model('castle/tower-square-top-roof-high', x, 1.01, z), model('castle/flag', x, 2.3, z));
  for (const t of [-.5, .5]) {
    g.add(model('castle/wall', t, 0, -1.5), model('castle/wall', -1.5, 0, t, Q), model('castle/wall', 1.5, 0, t, Q));
  }
  g.add(model('castle/wall-doorway', 0, 0, 1.5), model('castle/wall', -.8, 0, 1.5, 0, .6), model('castle/wall', .8, 0, 1.5, 0, .6));
  g.add(model('castle/tower-square-base', 0, 0, -.3, 0, 1.2), model('castle/tower-square-mid-windows', 0, 1.2, -.3, 0, 1.2), model('castle/tower-square-top-roof-high', 0, 2.42, -.3, 0, 1.2), model('castle/flag-banner-long', .62, 1.2, -.3, 0, 1));
  g.userData = { height: 4.4, flag: colour };
  return g;
}

// A grave: what was expected and never came, haunted.
function grave({ rand }) {
  const ghost = model('graveyard/character-ghost', .3, .3, .2, -.4, .9);
  const g = group(model('graveyard/gravestone-cross', -.3, 0, -.2, rand() - .5), model('graveyard/gravestone-round', .45, 0, -.4, rand() - .5),
    model('graveyard/iron-fence', 0, 0, .9), model('graveyard/candle-multiple', -.5, 0, .5), model('graveyard/pine-crooked', -.9, 0, -.8, rand() * 6, .8), ghost);
  g.scale.setScalar(1.35);
  g.userData = { height: 1.9, ghost };
  return g;
}

const BUILDINGS = {
  server: o => house({ ...o, w: 2, d: 1, floors: 2, banner: 'red' }),
  hall: o => hall(o),
  script: o => windmill(o),
  healthcheck: o => watchtower(o),
  system: o => mine(o),
  dashboard: o => seer(o),
  you: o => castle(o),
  ghost: o => grave(o),
};
const PIECES = [
  ...['wall', 'wall-door', 'wall-window-shutters', 'wall-window-glass', 'wall-window-small', 'wall-wood', 'wall-wood-door', 'wall-wood-window-shutters', 'wall-wood-window-glass', 'wall-wood-window-small',
    'roof-gable', 'roof', 'roof-left', 'roof-right', 'wall-slope', 'wall-wood-slope', 'roof-high-point', 'chimney', 'windmill', 'banner-red', 'banner-green', 'cart', 'lantern', 'stall-red', 'stall-green', 'fence', 'watermill', 'pillar-wood', 'planks'].map(n => 'town/' + n),
  ...['tower-hexagon-base', 'tower-hexagon-mid', 'tower-hexagon-roof', 'flag-pennant', 'tower-square-base', 'tower-square-mid-windows', 'tower-square-top-roof-high', 'flag-banner-long', 'flag', 'wall', 'wall-doorway'].map(n => 'castle/' + n),
  ...['rock_tallA', 'rock_tallC', 'rock_largeD', 'path_wood', 'statue_ring'].map(n => 'nature/' + n),
  ...['tool-pickaxe', 'workbench-anvil'].map(n => 'survival/' + n),
  ...['character-ghost', 'gravestone-cross', 'gravestone-round', 'iron-fence', 'candle-multiple', 'pine-crooked'].map(n => 'graveyard/' + n),
];

// * The bench: every building in a row, to see them as they are.

async function bench() {
  await ready(PIECES);
  const rand = mulberry(3);
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(60, 30), new THREE.MeshStandardMaterial({ color: 0x7fb069 }));
  ground.rotation.x = -Q; ground.receiveShadow = true; document.getElementById('inspector').hidden = true; document.querySelector('main').style.gridTemplateColumns = '1fr';
  scene.add(ground);
  Object.entries(BUILDINGS).forEach(([kind, make], n) => { const b = make({ rand, colour: '#d9534f' }); b.position.x = (n - 3) * 5.5; scene.add(b); });
  sun.position.set(-20, 40, 25); sun.target.position.set(0, 0, 0);
  Object.assign(sun.shadow.camera, { left: -40, right: 40, top: 40, bottom: -40, near: 1, far: 120 });
  sun.shadow.camera.updateProjectionMatrix();
  camera.position.set(-1, 12, 26); controls.target.set(-1, 1.5, 0);
  (function loop() {
    requestAnimationFrame(loop);
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (canvas.width !== Math.round(w * renderer.getPixelRatio())) { renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix(); }
    document.body.classList.remove('stale'); controls.update(); renderer.render(scene, camera);
  })();
}
if (BENCH) bench();

// The roof pieces side by side, two of each along x, to see how they join.
if (new URLSearchParams(location.search).has('roofs')) (async () => {
  const names = ['wall', 'roof', 'roof-gable', 'roof-gable-end', 'roof-gable-top', 'roof-left', 'roof-right', 'roof-point', 'roof-high-gable', 'roof-corner'];
  await ready(names.map(n => 'town/' + n));
  const roof = (x, ends) => { for (let i = 0; i < 3; i++) for (const [j, r] of [[0, -Q], [1, Q]]) { const end = ends ? (i === 0 ? 'roof-left' : i === 2 ? 'roof-right' : null) : null; scene.add(model('town/' + (end ?? 'roof'), x + i, 0, j, r)); } };
  const roofs = (x, a) => { for (let i = 0; i < 3; i++) for (const [j, r] of [[0, a], [1, -a]]) { scene.add(model('town/wall', x + i, 0, j, r), model('town/' + (i === 0 ? 'roof-left' : i === 2 ? 'roof-right' : 'roof'), x + i, 1, j, r)); } };
  roofs(-6, Q); roofs(2, -Q);
  sun.position.set(-20, 40, 25);
  camera.position.set(-1, 7, 9); controls.target.set(0, 0, 0);
  (function loop() { requestAnimationFrame(loop); const w = canvas.clientWidth, h = canvas.clientHeight; renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix(); document.body.classList.remove('stale'); controls.update(); renderer.render(scene, camera); })();
})();
