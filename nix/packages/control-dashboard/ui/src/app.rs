//! The dashboard's one window, whatever runs it: dear-app natively, or winit
//! and wgpu in a browser.

use crate::net::{self, Health, Item, Layout, Msg, Net, Run, Said, View};
use chrono::{DateTime, Local, Utc};
use dear_imgui_rs::{Condition, DrawListMut, MouseButton, StyleColor, Ui, WindowFlags, WindowHoveredFlags};
use dear_imnodes::{ColorElement, EditorContext, ImNodesExt, LinkId, NodeEditor, NodeEditorSetup, NodeId, PinId, PinShape};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;
use web_time::Instant;

#[derive(Default)]
pub struct Dashboard {
    server: String,
    net: Option<Net>,
    view: View,
    /// Why the server can't be reached, while it can't.
    gone: Option<String>,
    details: Option<(String, Vec<Run>)>,
    /// Shared by every window through the server; `None` until it's here.
    layout: Option<Layout>,
    saved: Layout,
    last_save: Option<Instant>,
    /// Nodes imnodes has been told where to draw.
    positioned: HashSet<String>,
    /// imnodes can't zoom: fonts, style and positions are all scaled by this instead.
    zoom: Option<f32>,
    editor: Option<EditorContext>,
    selected: Option<String>,
    /// The graph's own selection, so picking from the lists isn't undone.
    picked: Option<String>,
    run: Option<String>,
    error: Option<String>,
}

const RED: [f32; 4] = [0.75, 0.2, 0.2, 1.0];
const AMBER: [f32; 4] = [0.75, 0.55, 0.1, 1.0];
const BLUE: [f32; 4] = [0.2, 0.4, 0.65, 1.0];
const RED_TEXT: [f32; 4] = [1.0, 0.55, 0.55, 1.0];
const DIM: [f32; 4] = [0.55, 0.55, 0.6, 1.0];

/// Colour only for what needs a look: healthy topics keep the default.
fn color(h: Health) -> Option<[f32; 4]> {
    match h {
        Health::Bad => Some(RED),
        Health::Waiting => Some(AMBER),
        Health::Running => Some(BLUE),
        Health::Fine | Health::Unseen => None,
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

/// What imnodes says the nodes' positions are, at zoom 1.
fn positions(ini: &str, keys: &[&str], zoom: f32) -> Layout {
    let at = placements(ini);
    keys.iter().filter_map(|k| at.get(&ids(k).0.raw()).map(|p| (k.to_string(), [p[0] / zoom, p[1] / zoom]))).collect()
}

/// A new node goes in the column of how far down a chain of reactions it is.
fn depth(links: &[net::Link], t: &str, n: usize) -> usize {
    links.iter().filter(|l| l.to == t && n < 8).map(|l| depth(links, &l.from, n + 1) + 1).max().unwrap_or(0)
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

fn node(ui: &Ui, ed: &NodeEditor, key: &str, title: &str, sub: &str, look: Look, zoom: f32) -> Geo {
    use ColorElement::*;
    let (id, input, output) = ids(key);
    let ghost = matches!(look, Look::Ghost);
    let colors: Vec<_> = match look {
        Look::Title(c) => c.into_iter().flat_map(|c| [TitleBar, TitleBarHovered, TitleBarSelected].map(|e| (e, c))).collect(),
        Look::Ghost => [NodeBackground, NodeBackgroundHovered, NodeBackgroundSelected, NodeOutline, TitleBar, TitleBarHovered, TitleBarSelected].map(|e| (e, [0.0; 4])).to_vec(),
    };
    let _colors: Vec<_> = colors.into_iter().map(|(e, c)| ed.push_color(e, c)).collect();
    let n = ed.node(id);
    let (mut min, mut max) = ([0.0; 2], [0.0; 2]);
    n.title_bar(|| {
        ui.text_colored(if ghost { DIM } else { [1.0; 4] }, title);
        (min, max) = (ui.item_rect_min(), ui.item_rect_max());
    });
    let row = {
        let _in = n.input_attr(input, PinShape::Circle);
        ui.text_disabled(sub);
        (ui.item_rect_min(), ui.item_rect_max())
    };
    ui.same_line();
    {
        let _out = n.output_attr(output, PinShape::Circle);
        ui.dummy([1.0, 1.0]);
        max[0] = max[0].max(ui.item_rect_max()[0]);
    }
    let pad = 8.0 * zoom;
    Geo { min: [min[0] - pad, min[1] - pad], max: [max[0].max(row.1[0]) + pad, row.1[1] + pad], y: (row.0[1] + row.1[1]) / 2.0 }
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
        (Link, [0.45, 0.45, 0.5, 1.0]),
        (LinkHovered, [0.6, 0.6, 0.65, 1.0]),
        (Pin, [0.45, 0.45, 0.5, 1.0]),
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

/// Machines or services: one line each, red when something's wrong.
fn listing(ui: &Ui, items: &[Item], prefix: &str, selected: &mut Option<String>) {
    for i in items {
        let _c = (i.status == Health::Bad).then(|| ui.push_style_color(StyleColor::Text, RED_TEXT));
        let name = i.topic.strip_prefix(prefix).unwrap_or(&i.topic);
        if ui.selectable_config(format!("{name}##{}", i.topic)).selected(selected.as_deref() == Some(&i.topic)).build() {
            *selected = Some(i.topic.clone());
        }
        ui.indent();
        ui.text_disabled(format!("{}{}", i.stats.as_ref().map_or(String::new(), |s| format!("{s}  ")), ago(i.last)));
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
        let net = Net::new(self.server.clone(), wake);
        net.layout();
        self.net = Some(net);
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
                Msg::Layout(l) => self.layout = Some(l),
                Msg::Sent(r) => self.error = r.err(),
            }
        }
        let editor = match &self.editor {
            Some(e) => e,
            None => self.editor.insert(nodes.create_editor_context()),
        };
        let view = &self.view;
        let topics: Vec<&str> = view.nodes.iter().map(|n| n.topic.as_str()).collect();
        let keys: Vec<&str> = topics.iter().copied().chain(view.ghosts.iter().map(|g| g.key.as_str())).collect();
        let before = self.selected.clone();
        let mut send = None;
        let mut open = None;

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
            let [w, _] = ui.content_region_avail();
            let (list, side) = (380.0, if self.selected.is_some() { 460.0 } else { 0.0 });
            ui.child_window("lists").size([list, 0.0]).build(ui, || {
                ui.text_disabled("Machines");
                listing(ui, &view.machines, "system/", &mut self.selected);
                ui.spacing();
                ui.text_disabled("Services");
                listing(ui, &view.services, "healthcheck/", &mut self.selected);
            });
            ui.same_line();
            ui.child_window("graph").size([w - list - side, 0.0]).flags(WindowFlags::NO_SCROLL_WITH_MOUSE).build(ui, || {
                let Some(layout) = &mut self.layout else { return };
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
                        layout.extend(positions(&bound.save_state_to_ini_string(), &keys, *zoom));
                        *zoom = z;
                        self.positioned.clear();
                    } else {
                        bound.reset_panning([pan[0] + wheel[0] * 20.0, pan[1] + wheel[1] * 20.0]);
                    }
                }
                let z = *zoom;
                // Columns leave room for a label between a node and the next.
                const COLUMN: f32 = 600.0;
                // Columns by how far down a chain of reactions a node is. A group
                // is a band: its nodes go from its top down, with each run's
                // ghosts beside it, and anything new starts below everything,
                // so bands don't overlap.
                let free = |layout: &Layout, x: f32, mut y: f32| {
                    while layout.values().any(|p| (p[0] - x).abs() < COLUMN / 2.0 && (p[1] - y).abs() < 90.0) {
                        y += 90.0;
                    }
                    [x, y]
                };
                for n in &view.nodes {
                    if !layout.contains_key(&n.topic) {
                        let x = 60.0 + depth(&view.links, &n.topic, 0) as f32 * COLUMN;
                        let top = view.nodes.iter().filter(|m| m.group.is_some() && m.group == n.group).filter_map(|m| layout.get(&m.topic)).map(|p| p[1]).reduce(f32::min);
                        let y = top.unwrap_or_else(|| layout.values().map(|p| p[1] + 150.0).fold(40.0, f32::max));
                        let p = free(layout, x, y);
                        layout.insert(n.topic.clone(), p);
                    }
                    for g in view.ghosts.iter().filter(|g| g.announcer == n.topic) {
                        if !layout.contains_key(&g.key) {
                            let p = free(layout, layout[&n.topic][0] + COLUMN, layout[&n.topic][1]);
                            layout.insert(g.key.clone(), p);
                        }
                    }
                }
                let _font = ui.push_font_with_size(None, ui.clone_style().font_size_base() * z);
                let setup = ui.imnodes(nodes).editor(Some(editor));
                quiet(&setup, z);
                for k in &keys {
                    if self.positioned.insert(k.to_string()) {
                        let p = layout[*k];
                        setup.set_node_pos_grid(ids(k).0, [p[0] * z, p[1] * z]);
                    }
                }
                let ed = setup.begin_nodes();
                let mut geo = HashMap::new();
                for n in &view.nodes {
                    geo.insert(n.topic.as_str(), node(ui, &ed, &n.topic, &n.topic, &ago(n.last), Look::Title(color(n.status)), z));
                }
                for g in &view.ghosts {
                    geo.insert(g.key.as_str(), node(ui, &ed, &g.key, &g.title, "expected", Look::Ghost, z));
                }
                for l in &view.links {
                    let _c = l.trigger.as_ref().map(|_| ed.push_color(ColorElement::Link, AMBER));
                    ed.link(LinkId::new(ids(&format!("{}|{}", l.from, l.to)).0.raw()), ids(&l.from).2, ids(&l.to).1);
                }
                let post = ed.end();

                let dl = ui.get_foreground_draw_list();
                let (lo, size) = (ui.window_pos(), ui.window_size());
                let hi = [lo[0] + size[0], lo[1] + size[1]];
                let _clip = dl.push_clip_rect(lo, hi, false);
                for g in &view.ghosts {
                    dashed(&dl, geo[g.key.as_str()].min, geo[g.key.as_str()].max);
                }
                // Groups: a faint frame around their nodes and the ghosts they announce.
                let mut groups: HashMap<&str, ([f32; 2], [f32; 2])> = HashMap::new();
                let group_of = |t: &str| view.nodes.iter().find(|n| n.topic == t).and_then(|n| n.group.as_deref());
                let members = view.nodes.iter().map(|n| (n.topic.as_str(), n.group.as_deref()))
                    .chain(view.ghosts.iter().map(|g| (g.key.as_str(), group_of(&g.announcer))));
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
                for l in &view.links {
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
                    [n] => topics.iter().find(|t| ids(t).0 == n).map(|t| t.to_string()),
                    _ => None,
                };
                if picked != self.picked {
                    self.selected = picked.clone();
                    self.picked = picked;
                }
                if self.last_save.is_none_or(|t| t.elapsed() > Duration::from_secs(2)) {
                    self.last_save = Some(Instant::now());
                    layout.extend(positions(&post.save_state_to_ini_string(), &keys, z));
                    if *layout != self.saved {
                        net.save_layout(layout);
                        self.saved = layout.clone();
                    }
                }
            });
            if let Some(t) = &self.selected {
                ui.same_line();
                ui.child_window("side").build(ui, || {
                    let Some((_, runs)) = self.details.as_ref().filter(|d| d.0 == *t) else { return };
                    if runs.is_empty() {
                        ui.text_disabled("No runs seen.");
                    }
                    let cur = runs.iter().find(|r| self.run.as_ref() == Some(&r.id)).or(runs.first());
                    for r in runs {
                        let label = format!("{}  {:>6}  {}##{}", local(r.start), fmt_duration(r.took), clip(&r.label, 36), r.id);
                        let _c = (!r.problems.is_empty()).then(|| ui.push_style_color(StyleColor::Text, RED_TEXT));
                        if ui.selectable_config(label).selected(cur.is_some_and(|c| c.id == r.id)).build() {
                            self.run = Some(r.id.clone());
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
                        Some(s) => open = open.take().or(said(ui, s, &r.id)),
                    }
                    // A failed subtask has no node of its own: what it said goes here, in full.
                    for s in &r.subtasks {
                        ui.separator();
                        ui.text_disabled(&s.topic);
                        match &s.said {
                            Some(d) => open = open.take().or(said(ui, d, &s.topic)),
                            None => red(ui, &s.problems.join("\n")),
                        }
                    }
                    for p in &r.triggers {
                        if ui.button(format!("{}##trigger{}", p.label, p.index)) {
                            send = Some(net::TriggerRef { run: r.id.clone(), index: p.index });
                        }
                    }
                    if let Some(l) = &r.log {
                        ui.separator();
                        ui.text_wrapped(l);
                    }
                });
            }
        });

        if self.selected != before {
            self.run = None;
            if let Some(t) = &self.selected {
                net.details(t);
            }
        }
        if let Some(t) = send {
            net.send(&t);
        }
        if let Some(p) = open {
            open_file(net, p);
        }
    }
}

/// A finished run's summary and result; returns a result file to open.
fn said(ui: &Ui, s: &Said, id: &str) -> Option<String> {
    if s.success { ui.text_wrapped(&s.summary) } else { red(ui, &s.summary) }
    match &s.result {
        Some(serde_json::Value::String(r)) => {
            let open = r.starts_with('/') && ui.small_button(format!("Open##{id}"));
            ui.text_wrapped(r);
            open.then(|| r.clone())
        }
        Some(v) => {
            ui.text_wrapped(json(v));
            None
        }
        None => None,
    }
}

fn json(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        v => serde_json::to_string_pretty(v).unwrap(),
    }
}

/// In a browser, the server's copy, in a new tab.
#[cfg(target_arch = "wasm32")]
fn open_file(net: &Net, path: String) {
    if let Some(w) = web_sys::window() {
        _ = w.open_with_url_and_target(&net.file_url(&path), "_blank");
    }
}

/// Opened here if this machine has it, else fetched from the server first.
#[cfg(not(target_arch = "wasm32"))]
fn open_file(net: &Net, path: String) {
    if std::path::Path::new(&path).exists() {
        _ = std::process::Command::new("open").arg(&path).spawn();
        return;
    }
    let name = path.rsplit('/').next().unwrap_or("result").to_owned();
    net.file(&path.clone(), move |r| match r.and_then(|b| {
        let f = std::env::temp_dir().join(&name);
        std::fs::write(&f, b).map(|_| f).map_err(|e| e.to_string())
    }) {
        Ok(f) => _ = std::process::Command::new("open").arg(f).spawn(),
        Err(e) => eprintln!("Couldn't fetch {path}: {e}"),
    });
}
