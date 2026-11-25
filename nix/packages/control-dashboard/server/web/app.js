'use strict';

const $ = s => document.querySelector(s);
const ink = n => getComputedStyle(document.documentElement).getPropertyValue('--' + n).trim();
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const ms = t => new Date(t).getTime();

let sys = null, nodes = new Map(), parentOf = {}, runs = [];
let selected = decodeURIComponent(location.hash.slice(1)), detail = null;
const opened = new Map();

// * Words

function fmt(s) {
  s = Math.max(0, s);
  const u = (n, x) => n ? ' ' + n + x : '';
  if (s < 1) return Math.round(s * 1000) + 'ms';
  if (s < 10) return s.toFixed(1) + 's';
  if (s < 60) return Math.floor(s) + 's';
  if (s < 3600) return Math.floor(s / 60) + 'm' + u(Math.floor(s % 60), 's');
  if (s < 86400) return Math.floor(s / 3600) + 'h' + u(Math.floor(s % 3600 / 60), 'm');
  return Math.floor(s / 86400) + 'd' + u(Math.floor(s % 86400 / 3600), 'h');
}
const now = () => ms(sys.now);
const when = r => r.end ? fmt((now() - ms(r.start)) / 1000) + ' ago' : 'running for ' + fmt((now() - ms(r.start)) / 1000);
const took = r => r.end ? 'took ' + fmt((ms(r.end) - ms(r.start)) / 1000) : '';

const topicOf = n => n.kind === 'ghost' ? n.topic : n.id;

// What a node belongs to: its machine, project or the dashboard.
function project(n) {
  if (n.kind === 'you') return null;
  const [k, p] = topicOf(n).split('/');
  return k === 'system' ? 'machines' : k === 'dashboard' ? 'dashboard' : p ?? null;
}

// A node's name within its project, or within the run it is part of.
function nameOf(id) {
  const n = nodes.get(id);
  if (!n) return id;
  if (n.kind === 'you') return 'you';
  const t = topicOf(n), p = parentOf[id];
  if (p && t.startsWith(p + '/')) return t.slice(p.length + 1);
  const s = t.split('/');
  return s.slice(2).join('/') || s[1] || t;
}

function laneName(id) {
  const g = project(nodes.get(id)), n = nameOf(id);
  return g && g !== n ? g + ' · ' + n : n;
}

function caption(n) {
  if (n.kind === 'ghost') return n.topic.startsWith('trigger/') ? 'nothing has reacted yet' : 'expected, not seen';
  if (n.kind === 'you') return 'triggers you can send';
  const head = { bad: 'problem', waiting: 'waiting for you' }[n.status] ?? n.kind;
  const g = n.gauges ?? {};
  if (Object.keys(g).length) return [n.status === 'bad' ? 'problem' : null, ...['load', 'memory', 'disk'].filter(k => k in g).map(k => `${k} ${g[k]}%`)].filter(Boolean).join(' · ');
  return head + ' · ' + (n.latest ? when(n.latest) : n.required ? 'required, never seen' : 'never seen');
}

const statusText = { bad: 'Something is wrong.', waiting: 'Waiting for you to send a trigger.', running: 'Running.', fine: 'Fine.', unseen: 'Never seen.' };

// * The inspector

// A button that does what it says only when clicked twice, the second time
// within a few seconds: what it sends can't be taken back.
const post = (to, body, label, arm) =>
  `<button data-post="${to}" data-body="${esc(JSON.stringify(body))}"${arm ? ` data-arm="${esc(arm)}"` : ''}>${label}</button>`;
const sendButton = q => post('/api/send', { run: q.run, index: q.index }, 'Send', 'Sure? Send');
const dismissButton = run => post('/api/dismiss', { run }, 'Dismiss');
const link = (id, name = id) => `<a data-select="${esc(id)}" title="${esc(id)}">${esc(name)}</a>`;
const near = id => link(id, nodes.has(id) ? laneName(id) : id);
const list = (xs, cls = '') => xs.length ? `<ul class="${cls}">${xs.map(x => `<li>${esc(x)}</li>`).join('')}</ul>` : '';
const ago = t => fmt((now() - ms(t)) / 1000) + ' ago';

function dataHtml(v) {
  if (v == null) return '';
  if (Array.isArray(v) && v.every(x => typeof x !== 'object')) return `<pre>${esc(v.join(' '))}</pre>`;
  if (typeof v === 'object' && !Array.isArray(v)) return `<dl class="facts">${Object.entries(v).map(([k, x]) => `<dt>${esc(k)}</dt><dd>${esc(pretty(x))}</dd>`).join('')}</dl>`;
  return `<pre>${esc(pretty(v))}</pre>`;
}

const outcomeHtml = o => o.reactions.length
  ? [...new Map(o.reactions.map(r => [r.node + r.health, r])).values()].map(r => `${near(r.node)} <span class="${r.health}">${{ bad: 'went wrong', running: 'is running', fine: 'went fine' }[r.health] ?? r.health}</span>`).join(', ')
  : '<span class="dim">nothing has reacted yet</span>';

// Something a run asks of you, with what it would send.
function requestHtml(q) {
  const said = q.summary && q.summary !== q.label ? `<p>${esc(q.summary)}</p>` : '';
  if (q.sent) return `<div class="request sent"><p><b>${esc(q.label)}</b></p>
    <p class="dim">for ${near(q.from)}, sent ${ago(q.sent.at)}: ${outcomeHtml(q.sent)}</p></div>`;
  return `<div class="request"><p><b>${esc(q.label)}</b></p>
    <p class="dim">${near(q.from)} asked ${q.asked ? ago(q.asked) : ''}</p>${said}
    ${q.data != null ? `<p class="dim">It sends ${esc(q.topic)} with</p>${dataHtml(q.data)}` : `<p class="dim">It sends ${esc(q.topic)}</p>`}
    <p>${sendButton(q)} ${dismissButton(q.run)}</p></div>`;
}

const actionHtml = a => `<form class="action" data-post="/api/trigger" data-body="${esc(JSON.stringify({ topic: a.topic }))}">
  <p><b>${esc(a.topic.replace(/^trigger\//, ''))}</b> <span class="dim">${a.last ? `sent ${ago(a.last.at)}: ${outcomeHtml(a.last)}` : 'never sent'}</span></p>
  <p><input name="content" placeholder="message, if any"> <button data-arm="Sure? Send">Send</button></p></form>`;

function boardHtml() {
  const waiting = sys.requests.filter(q => !q.sent), sent = sys.requests.filter(q => q.sent);
  let h = `<h2><button class="fold" data-fold title="Fold">${boardOpen ? '–' : '+'}</button>Requests <span class="count ${waiting.length ? 'waiting' : 'dim'}">${waiting.length || 'none'} waiting</span></h2>`;
  if (!boardOpen) return h;
  h += waiting.length ? waiting.map(requestHtml).join('') : '<p class="dim">Nothing waits for you.</p>';
  if (sent.length) h += '<h3>Sent today</h3>' + sent.map(requestHtml).join('');
  if (sys.actions.length) h += '<h3>Start whenever</h3>' + sys.actions.map(actionHtml).join('');
  return h;
}

let boardOpen = true;
try { boardOpen = localStorage.getItem('kingdom.board') !== 'closed'; } catch {}

// Not while you're in the middle of something on it.
const busy = el => !!el.querySelector('.armed, button:disabled') || [...el.querySelectorAll('input')].some(i => i.value || i === document.activeElement)
  || !!getSelection().toString() && el.contains(getSelection().anchorNode);

function renderBoard() {
  const b = $('#board');
  if (busy(b)) return;
  const top = b.scrollTop;
  b.innerHTML = boardHtml();
  b.classList.toggle('open', boardOpen);
  b.scrollTop = top;
}

function overviewHtml() {
  const bad = sys.nodes.filter(n => n.own && n.status === 'bad');
  let h = '<h2>Something wrong</h2>';
  if (!bad.length) h += '<p class="dim">Nothing.</p>';
  for (const n of bad) h += `<p>${link(n.id)}</p>${list(n.problems, 'bad')}${n.latest ? `<p>${dismissButton(n.latest.id)}</p>` : ''}`;
  return h + legendHtml();
}

function connections(id) {
  const rows = [];
  const add = (title, xs) => xs.length && rows.push(`<dt>${title}</dt><dd>${xs.join(', ')}</dd>`);
  const out = k => sys.edges.filter(e => e.source === id && e.kind === k), inn = k => sys.edges.filter(e => e.target === id && e.kind === k);
  const via = (e, end) => `${near(e[end])} <span class="dim">by ${esc(e.label)}</span>`;
  add('Part of', inn('part').map(e => near(e.source)));
  add('Subtasks', out('part').map(e => near(e.target)));
  add('Reacts to', inn('reaction').map(e => near(e.source)));
  add('Reacted to by', out('reaction').map(e => near(e.target)));
  add('Triggered by', inn('trigger').map(e => via(e, 'source')));
  add('Triggers', out('trigger').map(e => via(e, 'target')));
  add('Expects', out('awaited').map(e => near(e.target)));
  add('Expected by', inn('awaited').map(e => near(e.source)));
  return rows.join('');
}

function rulesHtml(r) {
  if (!r) return '';
  return [
    r.timeout != null && `<dt>Limit</dt><dd>${fmt(r.timeout)}</dd>`,
    r.expected != null && `<dt>Expected</dt><dd>every ${fmt(r.expected)}</dd>`,
    r.reactions?.length && `<dt>Expects reactions</dt><dd>${r.reactions.map(esc).join(', ')}</dd>`,
    r.subtasks?.length && `<dt>Expects subtasks</dt><dd>${[...new Set(r.subtasks)].map(esc).join(', ')}</dd>`,
  ].filter(Boolean).join('');
}

const pretty = v => typeof v === 'string' ? v : JSON.stringify(v, null, 2);

function chainHtml(chain) {
  if (!chain.length) return '';
  const t0 = Math.min(...chain.map(c => ms(c.start))), t1 = Math.max(...chain.map(c => c.end ? ms(c.end) : now())), span = Math.max(1, t1 - t0);
  return '<p class="dim">The chain of runs it is part of:</p><table class="chain">' + chain.map(c => {
    const a = (ms(c.start) - t0) / span * 100, b = ((c.end ? ms(c.end) : now()) - t0) / span * 100;
    return `<tr><td style="padding-left:${c.depth}em"><a data-select="${esc(c.node)}" title="${esc(c.topic)}">${esc(c.topic.split('/').slice(-2).join('/'))}</a></td>
      <td class="bar"><div class="span ${c.health}" style="margin-left:${Math.min(a, 99)}%;width:${Math.max(.5, b - a)}%"></div></td>
      <td class="dim">${c.end ? took(c) : 'running'}</td></tr>`;
  }).join('') + '</table>';
}

function runHtml(r, i) {
  const open = opened.get(r.id) ?? i === 0;
  return `<details data-run="${r.id}"${open ? ' open' : ''}><summary><span class="dot ${r.health}"></span>
    <span class="label">${esc(r.label || r.topic)}</span><span class="when">${when(r)}</span></summary>
    ${r.topic !== detail.topic ? `<p class="dim">${esc(r.topic)}</p>` : ''}
    ${r.dismissed ? '<p class="dim">Dismissed.</p>' : list(r.problems, 'bad')}
    ${sys.requests.filter(q => q.run === r.id && q.sent).map(requestHtml).join('')}
    ${!r.dismissed && r.problems.length && !r.sends.length ? `<p>${dismissButton(r.id)}</p>` : ''}
    ${r.end ? `<p class="dim">${r.success ? 'Succeeded' : 'Failed'}, ${took(r)}.</p>` : ''}
    ${r.summary ? `<pre>${esc(r.summary)}</pre>` : ''}
    ${r.content != null ? `<p class="dim">Content</p><pre>${esc(pretty(r.content))}</pre>` : ''}
    ${r.result != null ? `<p class="dim">Result</p><pre>${esc(pretty(r.result))}</pre>` : ''}
    ${chainHtml(r.chain)}
    ${i === 0 && detail.log && r.health === 'bad' ? `<p class="dim">The end of its log</p><pre>${esc(detail.log)}</pre>` : ''}
  </details>`;
}

function nodeHtml() {
  const n = nodes.get(selected);
  let h = `<h1>${esc(n?.kind === 'you' ? 'You' : n ? topicOf(n) : selected)}</h1>`;
  if (n?.kind === 'you') return h + '<p>Triggers you can send whenever; each starts whatever reacts to it.</p>' + sys.actions.map(actionHtml).join('');
  if (n?.kind === 'ghost') {
    h += n.topic.startsWith('trigger/')
      ? '<p class="dim">This trigger has been announced, but nothing has reacted to it yet.</p>'
      : '<p class="dim">A run expects a reaction on this, but none has come.</p>';
    return h + `<dl class="facts">${connections(selected)}</dl>`;
  }
  if (n) {
    h += `<p class="${n.status}">${statusText[n.status] ?? ''}</p>${list(n.problems, 'bad')}`;
    h += sys.requests.filter(q => !q.sent && q.from === n.id).map(requestHtml).join('');
    if (n.problems.length && !n.sends.length && n.latest) h += `<p>${dismissButton(n.latest.id)}</p>`;
    h += `<dl class="facts"><dt>Kind</dt><dd>${esc(n.kind)}</dd>${rulesHtml(n.rules)}${n.required ? '<dt>Required</dt><dd>yes</dd>' : ''}${connections(selected)}</dl>`;
  }
  if (detail?.gauges?.length) h += '<h2>Load, memory and disk use</h2><div id="gauges"></div>';
  if (!detail || detail.topic !== selected) return h + '<p class="dim">Loading…</p>';
  h += `<h2>Last runs</h2>`;
  return h + (detail.runs.length ? detail.runs.map(runHtml).join('') : '<p class="dim">No runs.</p>');
}

let shownFor = null;
function renderInspector() {
  const ins = $('#inspector');
  if (busy(ins)) return;
  ins.querySelectorAll('details[data-run]').forEach(d => opened.set(d.dataset.run, d.open));
  const top = ins.scrollTop;
  ins.innerHTML = selected ? nodeHtml() : overviewHtml();
  ins.scrollTop = shownFor === selected ? top : 0;
  shownFor = selected;
  if ($('#gauges')) drawGauges();
}

let gaugeChart = null;
function drawGauges() {
  gaugeChart?.dispose();
  const g = gaugeChart = echarts.init($('#gauges'));
  const series = [['load', 's1'], ['memory', 's2'], ['disk', 's3']].map(([k, s]) => ({
    name: k, type: 'line', showSymbol: false, lineStyle: { width: 2 }, color: ink(s),
    data: detail.gauges.filter(x => k in x.gauges).map(x => [ms(x.at), x.gauges[k]]).reverse(),
  }));
  g.setOption({
    animation: false, textStyle: { fontFamily: 'Georgia, serif' },
    grid: { left: 40, right: 12, top: 34, bottom: 22 },
    legend: { top: 0, left: 0, textStyle: { color: ink('dim') }, itemWidth: 14, itemHeight: 2 },
    tooltip: { trigger: 'axis', valueFormatter: v => v + '%', backgroundColor: ink('node'), borderColor: ink('line'), textStyle: { color: ink('fg') } },
    xAxis: { type: 'time', splitNumber: 4, axisLabel: { color: ink('dim'), hideOverlap: true }, axisLine: { lineStyle: { color: ink('line') } } },
    yAxis: { type: 'value', min: 0, max: 100, interval: 50, axisLabel: { color: ink('dim'), formatter: '{value}%' }, splitLine: { lineStyle: { color: ink('line') } } },
    series,
  });
}

// * Keeping fresh

function header() {
  const s = sys.summary, parts = [];
  if (!s.connected) parts.push('<span class="bad">The server can’t reach the broker.</span>');
  if (s.bad) parts.push(`<a class="bad" data-select="">${s.bad} ${s.bad === 1 ? 'problem' : 'problems'}</a>`);
  if (s.waiting) parts.push(`<a class="waiting" data-unfold>${s.waiting} ${s.waiting === 1 ? 'request waits' : 'requests wait'} for you</a>`);
  if (s.connected && !s.bad && !s.waiting) parts.push('<span class="dim">All fine.</span>');
  $('#state').innerHTML = parts.join(' · ');
  document.title = (s.bad ? '!' + s.bad + ' ' : '') + (s.waiting ? '?' + s.waiting + ' ' : '') + 'Control';
  const dot = s.status === 'bad' ? ink('bad') : s.status === 'waiting' ? ink('waiting-line') : '#888';
  document.querySelector('link[rel=icon]').href = `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" fill="${dot}"/></svg>`)}`;
}

async function refresh() {
  try {
    const r = await fetch('/api/system');
    if (!r.ok) throw r;
    sys = await r.json();
    nodes = new Map(sys.nodes.map(n => [n.id, n]));
    parentOf = Object.fromEntries(sys.edges.filter(e => e.kind === 'part').map(e => [e.target, e.source]));
    document.body.classList.remove('stale');
    header();
    if (await worldFor(sys)) settle(runs);
    renderBoard();
    renderInspector();
  } catch (e) {
    console.error(e);
    document.body.classList.add('stale');
    document.title = '✕ Control';
  }
}

async function refreshRuns() {
  const r = await fetch('/api/runs?hours=6');
  if (!r.ok) return;
  const before = new Map(runs.map(r => [r.id, r]));
  runs = await r.json();
  // What began since, or in the last minute and a half on first sight.
  const byId = new Map(runs.map(r => [r.id, r])), recent = now() - 90e3;
  for (const r of runs) {
    const was = before.get(r.id);
    if (before.size ? !was : ms(r.start) > recent) arrived(r, byId);
    else if (was && !was.end && r.end && r.health === 'bad') burned(r);
  }
  settle(runs);
}

async function loadDetail() {
  const want = selected;
  if (!want || want.startsWith('?') || want === '@you') { detail = null; return renderInspector(); }
  const r = await fetch('/api/topic?topic=' + encodeURIComponent(want));
  if (r.ok && want === selected) { detail = await r.json(); renderInspector(); }
}

function select(id, fly) {
  if (id !== selected) { opened.clear(); detail = null; }
  selected = id;
  history.replaceState(null, '', id ? '#' + encodeURIComponent(id) : location.pathname);
  if (fly) flyTo(id);
  renderInspector();
  loadDetail();
}

addEventListener('click', async e => {
  const s = e.target.closest('[data-select]');
  if (s) { e.preventDefault(); return select(s.dataset.select, true); }
  const f = e.target.closest('[data-fold], [data-unfold]');
  if (f) {
    boardOpen = 'unfold' in f.dataset || !boardOpen;
    try { localStorage.setItem('kingdom.board', boardOpen ? 'open' : 'closed'); } catch {}
    return renderBoard();
  }
  const b = e.target.closest('button[data-post]');
  if (b && armed(b)) act(b, b.dataset.post, JSON.parse(b.dataset.body));
});

addEventListener('submit', e => {
  e.preventDefault();
  const f = e.target, body = JSON.parse(f.dataset.body), c = f.elements.content, b = f.querySelector('button');
  if (c?.value) body.content = c.value;
  if (armed(b)) act(b, f.dataset.post, body, () => { if (c) c.value = ''; });
});

// Whether a button may go ahead: one asking to be sure goes ahead on its
// second click, until it gives up waiting for it.
function armed(b) {
  if (!b.dataset.arm || b.classList.contains('armed')) return true;
  b.dataset.was = b.textContent;
  b.classList.add('armed');
  b.textContent = b.dataset.arm;
  setTimeout(() => { if (b.classList.contains('armed')) { b.classList.remove('armed'); b.textContent = b.dataset.was; } }, 4000);
  return false;
}

async function act(b, to, body, done) {
  const label = b.dataset.was ?? b.textContent;
  b.classList.remove('armed');
  b.disabled = true;
  b.textContent = '…';
  const r = await fetch(to, { method: 'POST', body: JSON.stringify(body) }).catch(() => null);
  if (!r?.ok) say(r ? await r.text() : 'The server can’t be reached.');
  else done?.();
  b.disabled = false;
  b.textContent = label;
  await refresh();
  loadDetail();
  refreshRuns();
}

function say(text) {
  const t = $('#toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(say.timer);
  say.timer = setTimeout(() => { t.hidden = true; }, 8000);
}


let soon = null;
(function live() {
  const s = new WebSocket(location.origin.replace(/^http/, 'ws'));
  s.onmessage = () => {
    refresh();
    clearTimeout(soon);
    soon = setTimeout(() => { refreshRuns(); loadDetail(); }, 1500);
  };
  s.onclose = () => setTimeout(live, 5000);
})();
setInterval(refresh, 5000);
setInterval(() => { refreshRuns(); loadDetail(); }, 30000);
refresh().then(refreshRuns).then(loadDetail);
