//! The dashboard's one window.

use crate::net::{self, Attention, Done, Health, Item, Msg, Net, Run, Span, Tick, View};
use chrono::{DateTime, Local, Utc};
use dear_imgui_rs::{Condition, DrawListMut, MouseButton, StyleColor, Ui, WindowFlags, WindowHoveredFlags};
use dear_imnodes::{ColorElement, EditorContext, ImNodesExt, LinkId, NodeEditor, NodeEditorSetup, NodeId, PinId, PinShape};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Default)]
pub struct Dashboard {
    server: String,
    net: Option<Net>,
    view: View,
    /// Why the server can't be reached, while it can't.
    gone: Option<String>,
    details: Option<(String, Vec<Run>)>,
    canvas: Canvas,
    selected: Option<String>,
    run: Option<String>,
    error: Option<String>,
    tab: usize,
}

const RED: [f32; 4] = [0.75, 0.2, 0.2, 1.0];
const AMBER: [f32; 4] = [0.75, 0.55, 0.1, 1.0];
const BLUE: [f32; 4] = [0.2, 0.4, 0.65, 1.0];
const GREY: [f32; 4] = [0.45, 0.45, 0.5, 1.0];
const RED_TEXT: [f32; 4] = [1.0, 0.55, 0.55, 1.0];
const AMBER_TEXT: [f32; 4] = [1.0, 0.75, 0.35, 1.0];
const DIM: [f32; 4] = [0.55, 0.55, 0.6, 1.0];

const TABS: [&str; 4] = ["Now", "Events", "Machines", "Healthchecks"];

/// Colour only for what needs a look: healthy topics keep the default.
fn color(h: Health) -> Option<[f32; 4]> {
    match h {
        Health::Bad => Some(RED),
        Health::Waiting => Some(AMBER),
        Health::Running => Some(BLUE),
        Health::Fine | Health::Unseen => None,
    }
}

fn text_color(h: Health) -> Option<[f32; 4]> {
    match h {
        Health::Bad => Some(RED_TEXT),
        Health::Waiting => Some(AMBER_TEXT),
        _ => None,
    }
}

/// Node, input pin, and output pin ids: stable, so imnodes' own state agrees across frames.
fn ids(key: &str) -> (NodeId, PinId, PinId) {
    let h = key.bytes().fold(0x811c9dc5u32, |h, b| (h ^ b as u32).wrapping_mul(0x01000193)) as i32 & 0x3fff_fffe;
    (NodeId::new(h), PinId::new(h), PinId::new(h | 1))
}

/// Node positions from imnodes' saved state, by node id.
fn placements(ini: &str) -> HashMap<i32, [f32; 2]> {
    let mut node = None;
    let mut out = HashMap::new();
    for l in ini.lines() {
        if let Some(n) = l.strip_prefix("[node.").and_then(|l| l.strip_suffix(']')) {
            node = n.parse().ok();
        } else if let (Some(n), Some((x, y))) = (node, l.strip_prefix("origin=").and_then(|o| o.split_once(',')))
            && let (Ok(x), Ok(y)) = (x.parse(), y.parse())
        {
            out.insert(n, [x, y]);
        }
    }
    out
}

fn fmt_duration(secs: f64) -> String {
    let ms = (secs * 1000.0).max(0.0) as i64;
    let s = ms / 1000;
    let unit = |n: i64, u: &str| if n == 0 { String::new() } else { format!(" {n}{u}") };
    match s {
        _ if ms < 1000 => format!("{ms}ms"),
        0..10 => format!("{:.1}s", ms as f64 / 1000.0),
        10..60 => format!("{s}s"),
        60..3600 => format!("{}m{}", s / 60, unit(s % 60, "s")),
        3600..86400 => format!("{}h{}", s / 3600, unit(s % 3600 / 60, "m")),
        _ => format!("{}d{}", s / 86400, unit(s % 86400 / 3600, "h")),
    }
}

fn ago(t: Option<DateTime<Utc>>) -> String {
    t.map_or("never seen".into(), |t| format!("{} ago", fmt_duration((Utc::now() - t).as_seconds_f64())))
}

fn local(t: DateTime<Utc>) -> String {
    t.with_timezone(&Local).format("%a %d %b %H:%M").to_string()
}

fn clip(s: &str, n: usize) -> String {
    let s = s.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    if s.chars().count() > n { s.chars().take(n).collect::<String>() + "…" } else { s.to_owned() }
}

/// What a machine or healthcheck says beside its name: its stats, and when it last ran.
fn sub(i: &Item) -> String {
    format!("{}{}", i.stats.as_ref().map_or(String::new(), |s| format!("{s}  ")), ago(i.last))
}

/// Where a node was drawn this frame, in screen space: imnodes doesn't say.
struct Geo {
    min: [f32; 2],
    max: [f32; 2],
    /// The pins' height.
    y: f32,
}

/// A ghost is see-through: its dashed outline is drawn later, from its `Geo`.
enum Look {
    Title(Option<[f32; 4]>),
    Ghost,
}

fn node(ui: &Ui, ed: &NodeEditor, s: &Shown, look: Look, zoom: f32) -> Geo {
    use ColorElement::*;
    let (id, input, output) = ids(s.key);
    let ghost = matches!(look, Look::Ghost);
    let colors: Vec<_> = match look {
        Look::Title(c) => c.into_iter().flat_map(|c| [TitleBar, TitleBarHovered, TitleBarSelected].map(|e| (e, c))).collect(),
        Look::Ghost => [NodeBackground, NodeBackgroundHovered, NodeBackgroundSelected, NodeOutline, TitleBar, TitleBarHovered, TitleBarSelected].map(|e| (e, [0.0; 4])).to_vec(),
    };
    let _colors: Vec<_> = colors.into_iter().map(|(e, c)| ed.push_color(e, c)).collect();
    let n = ed.node(id);
    let (mut min, mut max) = ([0.0; 2], [0.0; 2]);
    n.title_bar(|| {
        ui.text_colored(if ghost { DIM } else { [1.0; 4] }, s.title);
        (min, max) = (ui.item_rect_min(), ui.item_rect_max());
    });
    let row = {
        let _in = n.input_attr(input, PinShape::Circle);
        ui.text_disabled(&s.sub);
        (ui.item_rect_min(), ui.item_rect_max())
    };
    ui.same_line();
    {
        let _out = n.output_attr(output, PinShape::Circle);
        ui.dummy([1.0, 1.0]);
        max[0] = max[0].max(ui.item_rect_max()[0]);
    }
    let mut bottom = row.1;
    let mut below = |ui: &Ui| bottom = [bottom[0].max(ui.item_rect_max()[0]), ui.item_rect_max()[1]];
    if !s.recent.is_empty() {
        strip(ui, s.recent, zoom);
        below(ui);
    }
    for p in s.problems {
        ui.text_colored(RED_TEXT, clip(p, 60));
        below(ui);
    }
    for l in &s.body {
        ui.text(l);
        below(ui);
    }
    let pad = 8.0 * zoom;
    Geo { min: [min[0] - pad, min[1] - pad], max: [max[0].max(bottom[0]) + pad, bottom[1] + pad], y: (row.0[1] + row.1[1]) / 2.0 }
}

/// A topic's last runs, oldest first: red for those that went wrong, as tall as they took.
fn strip(ui: &Ui, recent: &[Tick], zoom: f32) {
    let (w, gap, h) = (3.0 * zoom, 1.5 * zoom, 12.0 * zoom);
    let longest = recent.iter().map(|t| t.took).fold(1e-3, f64::max);
    let p = ui.cursor_screen_pos();
    let dl = ui.get_window_draw_list();
    for (i, t) in recent.iter().enumerate() {
        let x = p[0] + i as f32 * (w + gap);
        let top = p[1] + h - (h * (t.took / longest) as f32).max(2.0 * zoom);
        dl.add_rect([x, top], [x + w, p[1] + h], color(t.status).unwrap_or(GREY)).filled(true).build();
    }
    ui.dummy([recent.len() as f32 * (w + gap), h]);
}

/// Grey unless something needs a look, and sized to the zoom.
fn quiet(setup: &NodeEditorSetup, zoom: f32) {
    use ColorElement::*;
    setup.set_grid_spacing(24.0 * zoom);
    setup.set_node_padding([8.0 * zoom; 2]);
    setup.set_node_corner_rounding(4.0 * zoom);
    setup.set_pin_circle_radius(4.0 * zoom);
    setup.set_pin_hover_radius(10.0 * zoom);
    setup.set_link_thickness((3.0 * zoom).max(1.0));
    for (e, c) in [
        (TitleBar, [0.25, 0.25, 0.27, 1.0]),
        (TitleBarHovered, [0.3, 0.3, 0.33, 1.0]),
        (TitleBarSelected, [0.35, 0.35, 0.38, 1.0]),
        (Link, GREY),
        (LinkHovered, [0.6, 0.6, 0.65, 1.0]),
        (Pin, GREY),
        (PinHovered, [0.6, 0.6, 0.65, 1.0]),
        (GridLine, [1.0, 1.0, 1.0, 0.03]),
        (GridLinePrimary, [1.0, 1.0, 1.0, 0.05]),
    ] {
        setup.set_color(e, c);
    }
}

fn dashed(dl: &DrawListMut, a: [f32; 2], b: [f32; 2]) {
    let seg = |p: [f32; 2], q: [f32; 2]| {
        let len = ((q[0] - p[0]).hypot(q[1] - p[1]) / 8.0).ceil() as usize;
        for i in (0..len).step_by(2) {
            let at = |k: usize| { let f = (k as f32 / len as f32).min(1.0); [p[0] + (q[0] - p[0]) * f, p[1] + (q[1] - p[1]) * f] };
            dl.add_line(at(i), at(i + 1), DIM).build();
        }
    };
    seg(a, [b[0], a[1]]);
    seg([b[0], a[1]], b);
    seg(b, [a[0], b[1]]);
    seg([a[0], b[1]], a);
}

/// A run's content or result, as the lines a node shows below its problems.
fn body(v: &Value) -> Vec<String> {
    let lines: Vec<String> = match v {
        Value::Object(m) => m.iter().filter(|(_, v)| !matches!(v, Value::Null) && v.as_str() != Some("")).map(|(k, v)| clip(&format!("{k}: {}", v.as_str().map_or_else(|| v.to_string(), str::to_owned)), 60)).collect(),
        v => json(v).lines().map(|l| clip(l, 60)).collect(),
    };
    lines.into_iter().take(8).collect()
}

/// A node on the graph: an event's topic, or what its last run said.
struct Shown<'a> {
    key: &'a str,
    title: &'a str,
    sub: String,
    color: Option<[f32; 4]>,
    problems: &'a [String],
    group: Option<&'a str>,
    recent: &'a [Tick],
    body: Vec<String>,
    /// The node this one hangs under.
    under: Option<&'a str>,
}

impl<'a> Shown<'a> {
    fn item(i: &'a Item) -> Self {
        Shown { key: &i.topic, title: &i.topic, sub: ago(i.last), color: color(i.status), problems: &i.problems, group: i.group.as_deref(), recent: &i.recent, body: vec![], under: None }
    }

    fn said(s: &'a net::Said, group: Option<&'a str>) -> Self {
        Shown { key: &s.key, title: &s.title, sub: String::new(), color: None, problems: &[], group, recent: &[], body: body(&s.value), under: Some(&s.under) }
    }
}

/// The graph of events.
#[derive(Default)]
struct Canvas {
    editor: Option<EditorContext>,
    /// imnodes can't zoom: fonts, style and positions are all scaled by this instead.
    zoom: Option<f32>,
    /// How big each node was last drawn, at zoom 1: a column is as wide as
    /// its widest, and a row as tall as its tallest.
    sizes: HashMap<String, [f32; 2]>,
    /// Nodes moved by hand, at zoom 1, until the window closes.
    moved: HashMap<String, [f32; 2]>,
    /// The node being dragged, while it is.
    dragging: Option<String>,
    /// What imnodes has selected, so picking elsewhere isn't undone.
    picked: Option<String>,
}

impl Canvas {
    /// Draws the graph where the server placed it; returns a trigger clicked.
    #[allow(clippy::too_many_arguments)]
    fn draw(&mut self, ui: &Ui, nodes: &dear_imnodes::Context, net: &Net, shown: &[Shown], ghosts: &[net::Ghost], links: &[net::Link], places: &HashMap<String, (usize, usize)>, selected: &mut Option<String>) -> Option<net::TriggerRef> {
        let editor = self.editor.get_or_insert_with(|| nodes.create_editor_context());
        let zoom = self.zoom.get_or_insert(1.0);
        let io = ui.io();
        let (wheel, origin) = ([io.mouse_wheel_h(), io.mouse_wheel()], ui.cursor_screen_pos());
        if wheel != [0.0; 2] && ui.is_window_hovered_with_flags(WindowHoveredFlags::CHILD_WINDOWS) {
            let bound = nodes.bind_editor(editor);
            let pan = bound.get_panning();
            if io.key_super() || io.key_ctrl() {
                let z = (*zoom * 1.1f32.powf(wheel[1])).clamp(0.25, 2.0);
                let r = z / *zoom;
                let m = io.mouse_pos();
                let m = [m[0] - origin[0], m[1] - origin[1]];
                bound.reset_panning([m[0] - (m[0] - pan[0]) * r, m[1] - (m[1] - pan[1]) * r]);
                *zoom = z;
            } else {
                bound.reset_panning([pan[0] + wheel[0] * 20.0, pan[1] + wheel[1] * 20.0]);
            }
        }
        let z = *zoom;
        // A column is as wide as its widest node, a row as tall as its
        // tallest, and columns leave room for a label between them.
        let size = |k: &str, i: usize| self.sizes.get(k).map_or([300.0, 80.0][i], |s| s[i]);
        let mut wide = vec![0.0f32; places.values().map(|p| p.0 + 1).max().unwrap_or(0)];
        let mut tall = vec![0.0f32; places.values().map(|p| p.1 + 1).max().unwrap_or(0)];
        for (k, (c, r)) in places {
            wide[*c] = wide[*c].max(size(k, 0));
            tall[*r] = tall[*r].max(size(k, 1));
        }
        let starts = |v: &[f32], first: f32, gap: f32| v.iter().scan(first, |x, w| Some(std::mem::replace(x, *x + w + if *w > 0.0 { gap } else { 0.0 }))).collect::<Vec<_>>();
        let (left, top) = (starts(&wide, 60.0, 160.0), starts(&tall, 40.0, 40.0));
        let at = |k: &str| self.moved.get(k).copied().unwrap_or_else(|| places.get(k).map_or([0.0; 2], |(c, r)| [left[*c], top[*r]]));
        let _font = ui.push_font_with_size(None, ui.clone_style().font_size_base() * z);
        let setup = ui.imnodes(nodes).editor(Some(editor));
        quiet(&setup, z);
        let keys: Vec<&str> = shown.iter().map(|n| n.key).chain(ghosts.iter().map(|g| g.key.as_str())).collect();
        for k in keys.iter().filter(|k| self.dragging.as_deref() != Some(k)) {
            let p = at(k);
            setup.set_node_pos_grid(ids(k).0, [p[0] * z, p[1] * z]);
        }
        let ed = setup.begin_nodes();
        let mut geo = HashMap::new();
        for n in shown {
            geo.insert(n.key, node(ui, &ed, n, Look::Title(n.color), z));
        }
        for g in ghosts {
            let s = Shown { key: &g.key, title: &g.title, sub: "expected".into(), color: None, problems: &[], group: None, recent: &[], body: vec![], under: None };
            geo.insert(g.key.as_str(), node(ui, &ed, &s, Look::Ghost, z));
        }
        let hung = shown.iter().filter_map(|s| s.under.map(|u| (u, s.key)));
        for (from, to) in links.iter().map(|l| (l.from.as_str(), l.to.as_str())).chain(hung) {
            let trigger = links.iter().any(|l| l.from == from && l.to == to && l.trigger.is_some());
            let _c = trigger.then(|| ed.push_color(ColorElement::Link, AMBER));
            ed.link(LinkId::new(ids(&format!("{from}|{to}")).0.raw()), ids(from).2, ids(to).1);
        }
        let post = ed.end();
        // A node dragged stays where it's dropped: imnodes only says where in its saved state.
        if ui.is_mouse_clicked(MouseButton::Left) && ui.is_window_hovered_with_flags(WindowHoveredFlags::CHILD_WINDOWS) {
            self.dragging = post.hovered_node().and_then(|n| keys.iter().find(|k| ids(k).0 == n)).map(|k| k.to_string());
        }
        if let Some(k) = self.dragging.take_if(|_| !ui.is_mouse_down(MouseButton::Left))
            && let Some(p) = placements(&post.save_state_to_ini_string()).get(&ids(&k).0.raw())
        {
            let (p, was) = ([p[0] / z, p[1] / z], at(&k));
            if (p[0] - was[0]).abs() + (p[1] - was[1]).abs() > 1.0 {
                self.moved.insert(k, p);
            }
        }
        // Nodes are placed by how big they were last drawn: if that changed, draw again.
        let sizes: HashMap<String, [f32; 2]> = geo.iter().map(|(k, g)| (k.to_string(), [(g.max[0] - g.min[0]) / z, (g.max[1] - g.min[1]) / z])).collect();
        if sizes.iter().any(|(k, s)| self.sizes.get(k).is_none_or(|t| (s[0] - t[0]).abs() + (s[1] - t[1]).abs() > 1.0)) {
            net.wake();
        }
        self.sizes = sizes;

        let dl = ui.get_foreground_draw_list();
        let (lo, size) = (ui.window_pos(), ui.window_size());
        let hi = [lo[0] + size[0], lo[1] + size[1]];
        let _clip = dl.push_clip_rect(lo, hi, false);
        for g in ghosts {
            dashed(&dl, geo[g.key.as_str()].min, geo[g.key.as_str()].max);
        }
        // Groups: a faint frame around their nodes and the ghosts they announce.
        let mut groups: HashMap<&str, ([f32; 2], [f32; 2])> = HashMap::new();
        let group_of = |t: &str| shown.iter().find(|n| n.key == t).and_then(|n| n.group);
        let members = shown.iter().map(|n| (n.key, n.group)).chain(ghosts.iter().map(|g| (g.key.as_str(), group_of(&g.announcer))));
        for (k, g) in members {
            if let (Some(g), Some(r)) = (g, geo.get(k)) {
                let b = groups.entry(g).or_insert((r.min, r.max));
                *b = ([b.0[0].min(r.min[0]), b.0[1].min(r.min[1])], [b.1[0].max(r.max[0]), b.1[1].max(r.max[1])]);
            }
        }
        let pad = 12.0 * z;
        for (g, (a, b)) in &groups {
            let h = ui.calc_text_size(g)[1];
            dl.add_rect([a[0] - pad, a[1] - pad - h - 4.0], [b[0] + pad, b[1] + pad], [0.5, 0.5, 0.55, 0.35]).rounding(6.0 * z).build();
            dl.add_text([a[0] - pad + 6.0, a[1] - pad - h - 2.0], DIM, g);
        }
        let m = ui.io().mouse_pos();
        let inside = |a: [f32; 2], b: [f32; 2]| m[0] >= a[0] && m[0] <= b[0] && m[1] >= a[1] && m[1] <= b[1];
        let mut send = None;
        for l in links {
            let (Some(label), Some(a), Some(b)) = (&l.label, geo.get(l.from.as_str()), geo.get(l.to.as_str())) else { continue };
            let [w, h] = ui.calc_text_size(label);
            let mid = [(a.max[0] + b.min[0]) / 2.0, (a.y + b.y) / 2.0];
            let (p, q) = ([mid[0] - w / 2.0 - 4.0, mid[1] - h / 2.0 - 2.0], [mid[0] + w / 2.0 + 4.0, mid[1] + h / 2.0 + 2.0]);
            let hover = l.trigger.is_some() && inside(lo, hi) && inside(p, q);
            dl.add_rect(p, q, if hover { [0.3, 0.25, 0.1, 1.0] } else { [0.12, 0.12, 0.14, 1.0] }).filled(true).rounding(3.0).build();
            dl.add_text([p[0] + 4.0, p[1] + 2.0], if l.trigger.is_some() { AMBER } else { DIM }, label);
            if hover && ui.is_mouse_clicked(MouseButton::Left) {
                send = l.trigger.clone();
            }
        }

        let picked = match post.selected_nodes()[..] {
            [n] => shown.iter().find(|s| s.under.is_none() && ids(s.key).0 == n).map(|s| s.key.to_owned()),
            _ => None,
        };
        if picked != self.picked {
            *selected = picked.clone();
            self.picked = picked;
        }
        send
    }
}

/// What was asked for this frame, done once it's drawn.
#[derive(Default)]
struct Wants {
    send: Option<net::TriggerRef>,
    /// A topic to show, and which of its runs.
    show: Option<(String, String)>,
}

/// A topic's runs, and the chosen one in full.
fn runs(ui: &Ui, runs: &[Run], run: &mut Option<String>, w: &mut Wants) {
    if runs.is_empty() {
        ui.text_disabled("No runs seen.");
    }
    let cur = runs.iter().find(|r| run.as_ref() == Some(&r.id)).or(runs.first());
    for r in runs {
        let label = format!("{}  {:>6}  {}##{}", local(r.start), fmt_duration(r.took), clip(&r.label, 36), r.id);
        let _c = (!r.problems.is_empty()).then(|| ui.push_style_color(StyleColor::Text, RED_TEXT));
        if ui.selectable_config(label).selected(cur.is_some_and(|c| c.id == r.id)).build() {
            *run = Some(r.id.clone());
        }
    }
    let Some(r) = cur else { return };
    ui.separator();
    ui.text_wrapped(&r.label);
    if let Some(c) = &r.content {
        ui.text_wrapped(json(c));
    }
    for p in &r.problems {
        red(ui, p);
    }
    match &r.said {
        None => ui.text_disabled(format!("Running for {}", fmt_duration(r.took))),
        Some(s) => said(ui, s),
    }
    if !r.trace.is_empty() {
        ui.separator();
        w.show = w.show.take().or(waterfall(ui, &r.trace, &r.id));
    }
    // A failed subtask has no node of its own: what it said goes here, in full.
    for s in &r.subtasks {
        ui.separator();
        ui.text_disabled(&s.topic);
        match &s.said {
            Some(d) => said(ui, d),
            None => red(ui, &s.problems.join("\n")),
        }
    }
    for p in &r.triggers {
        if ui.button(format!("{}##trigger{}", p.label, p.index)) {
            w.send = Some(net::TriggerRef { run: r.id.clone(), index: p.index });
        }
    }
    if let Some(l) = &r.log {
        ui.separator();
        ui.text_wrapped(l);
    }
}

/// The chain of runs a run is part of, on one time axis; returns a run clicked.
fn waterfall(ui: &Ui, trace: &[Span], current: &str) -> Option<(String, String)> {
    let now = Utc::now();
    let t0 = trace.iter().map(|s| s.start).min()?;
    let t1 = trace.iter().map(|s| s.end.unwrap_or(now)).max()?;
    let total = (t1 - t0).as_seconds_f32().max(1e-3);
    let [w, _] = ui.content_region_avail();
    let (names, h) = ((w * 0.4).min(180.0), ui.text_line_height());
    let dl = ui.get_window_draw_list();
    let mut picked = None;
    for s in trace {
        let p = ui.cursor_screen_pos();
        if ui.invisible_button(format!("##span{}", s.id), [w, h]) && s.id != current {
            picked = Some((s.topic.clone(), s.id.clone()));
        }
        let name = format!("{}{}", "  ".repeat(s.depth), s.topic.rsplit('/').next().unwrap_or(&s.topic));
        dl.add_text(p, if s.id == current { [1.0; 4] } else { DIM }, clip(&name, 24));
        let x = |t: DateTime<Utc>| p[0] + names + (w - names) * (t - t0).as_seconds_f32() / total;
        let (a, b) = (x(s.start), x(s.end.unwrap_or(now)).max(x(s.start) + 2.0));
        let c = color(s.status).unwrap_or(if s.id == current { [0.75, 0.75, 0.8, 1.0] } else { GREY });
        dl.add_rect([a, p[1] + 2.0], [b, p[1] + h - 2.0], c).filled(true).rounding(2.0).build();
        if ui.is_item_hovered() {
            let took = (s.end.unwrap_or(now) - s.start).as_seconds_f64();
            ui.tooltip_text(format!("{}\n{}\n{} from {}", s.topic, s.label, fmt_duration(took), local(s.start)));
        }
    }
    picked
}

/// A topic to pick, coloured if it needs a look.
fn row(ui: &Ui, title: &str, key: &str, status: Health, selected: &mut Option<String>) {
    let _c = text_color(status).map(|c| ui.push_style_color(StyleColor::Text, c));
    if ui.selectable_config(format!("{title}##{key}")).selected(selected.as_deref() == Some(key)).build() {
        *selected = Some(key.to_owned());
    }
}

/// Everything that needs you, worst first.
fn now_page(ui: &Ui, items: &[Attention], selected: &mut Option<String>, w: &mut Wants) {
    if items.is_empty() {
        ui.text_disabled("Nothing needs you.");
    }
    for a in items {
        row(ui, &a.key, &a.key, a.status, selected);
        ui.indent();
        for p in &a.problems {
            ui.text_disabled(p);
        }
        for (k, t) in a.triggers.iter().enumerate() {
            if k > 0 {
                ui.same_line();
            }
            if ui.small_button(format!("{}##{}{}", t.label, t.run, t.index)) {
                w.send = Some(net::TriggerRef { run: t.run.clone(), index: t.index });
            }
        }
        ui.unindent();
    }
}

/// Machines or healthchecks: each with its stats, last runs and problems.
fn list_page(ui: &Ui, items: &[Item], prefix: &str, selected: &mut Option<String>) {
    for i in items {
        row(ui, i.topic.strip_prefix(prefix).unwrap_or(&i.topic), &i.topic, i.status, selected);
        ui.same_line();
        ui.text_disabled(sub(i));
        ui.indent();
        strip(ui, &i.recent, 1.0);
        for p in &i.problems {
            red(ui, p);
        }
        ui.unindent();
    }
}

/// Errors wrap: they're the part worth reading in full.
fn red(ui: &Ui, s: &str) {
    let _c = ui.push_style_color(StyleColor::Text, RED_TEXT);
    ui.text_wrapped(s);
}

impl Dashboard {
    pub fn new(server: String) -> Self {
        Dashboard { server, ..Default::default() }
    }

    /// `wake` asks for a frame, when something arrives.
    pub fn connect(&mut self, wake: Arc<dyn Fn() + Send + Sync>) {
        self.net = Some(Net::new(self.server.clone(), wake));
    }

    pub fn frame(&mut self, ui: &Ui, nodes: &dear_imnodes::Context) {
        let Some(net) = &mut self.net else { return };
        for m in net.poll() {
            match m {
                Msg::View(v) => {
                    self.view = v;
                    self.gone = None;
                    if let Some(t) = &self.selected {
                        net.details(t);
                    }
                }
                Msg::Gone(e) => self.gone = Some(e),
                Msg::Details(t, d) => self.details = Some((t, d)),
                Msg::Sent(r) => self.error = r.err(),
            }
        }
        let view = &self.view;
        let before = self.selected.clone();
        let mut w = Wants::default();

        let flags = WindowFlags::NO_DECORATION | WindowFlags::NO_MOVE | WindowFlags::NO_SAVED_SETTINGS | WindowFlags::NO_BRING_TO_FRONT_ON_FOCUS;
        ui.window("control").position([0.0, 0.0], Condition::Always).size(ui.io().display_size(), Condition::Always).flags(flags).build(|| {
            if let Some(e) = &self.gone {
                red(ui, &format!("Can't reach the server at {}: {e}", self.server));
            } else if !view.connected {
                red(ui, "The server can't reach the broker.");
            }
            if let Some(e) = &self.error {
                red(ui, e);
            }
            let Some(_bar) = ui.tab_bar("tabs") else { return };
            let group = |t: &str| view.nodes.iter().find(|n| n.topic == t).and_then(|n| n.group.as_deref());
            let shown: Vec<Shown> = view.nodes.iter().map(Shown::item).chain(view.said.iter().map(|s| Shown::said(s, group(&s.under)))).collect();
            for (i, name) in TABS.iter().enumerate() {
                let items: &[Item] = match i {
                    1 => &view.nodes,
                    2 => &view.machines,
                    3 => &view.services,
                    _ => &[],
                };
                // A tab is red when anything on it is broken.
                let broken = if i == 0 { view.now.iter().any(|a| a.status == Health::Bad) } else { items.iter().any(|n| n.status == Health::Bad) };
                let colors: Vec<_> = if broken {
                    [StyleColor::Tab, StyleColor::TabHovered, StyleColor::TabSelected, StyleColor::TabDimmed, StyleColor::TabDimmedSelected].map(|c| ui.push_style_color(c, RED)).into()
                } else {
                    vec![]
                };
                let label = if i == 0 && !view.now.is_empty() { format!("{name}  {}###{i}", view.now.len()) } else { format!("{name}###{i}") };
                let item = ui.tab_item(label);
                colors.into_iter().rev().for_each(drop);
                let Some(_item) = item else { continue };
                if self.tab != i {
                    self.selected = None;
                }
                self.tab = i;
                let [width, _] = ui.content_region_avail();
                let side = if self.selected.is_some() { 460.0 } else { 0.0 };
                ui.child_window("page").size([width - side, 0.0]).flags(if i == 1 { WindowFlags::NO_SCROLL_WITH_MOUSE } else { WindowFlags::empty() }).build(ui, || match i {
                    0 => now_page(ui, &view.now, &mut self.selected, &mut w),
                    1 => w.send = self.canvas.draw(ui, nodes, net, &shown, &view.ghosts, &view.links, &view.places, &mut self.selected).or(w.send.take()),
                    2 => list_page(ui, items, "system/", &mut self.selected),
                    _ => list_page(ui, items, "healthcheck/", &mut self.selected),
                });
                if let Some(t) = &self.selected {
                    ui.same_line();
                    ui.child_window("side").build(ui, || {
                        if let Some((_, r)) = self.details.as_ref().filter(|d| d.0 == *t) {
                            ui.text_disabled(t);
                            runs(ui, r, &mut self.run, &mut w);
                        }
                    });
                }
            }
        });

        if self.selected != before {
            self.run = None;
            if let Some(t) = &self.selected {
                net.details(t);
            }
        }
        if let Some((t, run)) = w.show {
            if self.selected.as_ref() != Some(&t) {
                net.details(&t);
            }
            self.selected = Some(t);
            self.run = Some(run);
        }
        if let Some(t) = w.send {
            net.send(&t);
        }
    }
}

/// A finished run's summary and result.
fn said(ui: &Ui, s: &Done) {
    if s.success { ui.text_wrapped(&s.summary) } else { red(ui, &s.summary) }
    if let Some(v) = &s.result {
        ui.text_wrapped(json(v));
    }
}

fn json(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        v => serde_json::to_string_pretty(v).unwrap(),
    }
}
