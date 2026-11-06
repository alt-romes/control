//! Talking to control-dashboard-server: its view live over a WebSocket,
//! everything else over HTTP. See ../../protocol.md.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Duration;
use web_time::Instant;

#[derive(Deserialize, Default)]
pub struct View {
    pub connected: bool,
    pub since: Option<DateTime<Utc>>,
    pub now: Vec<Attention>,
    pub machines: Vec<Item>,
    pub services: Vec<Item>,
    pub nodes: Vec<Item>,
    pub ghosts: Vec<Ghost>,
    pub links: Vec<Link>,
    pub todos: Vec<Todo>,
    pub notes: Vec<Note>,
}

#[derive(Deserialize)]
pub struct Item {
    pub topic: String,
    pub status: Health,
    pub last: Option<DateTime<Utc>>,
    pub stats: Option<String>,
    pub problems: Vec<String>,
    pub group: Option<String>,
    pub recent: Vec<Tick>,
    pub content: Option<Value>,
    pub result: Option<Value>,
}

#[derive(Deserialize)]
pub struct Tick {
    pub status: String,
    pub took: f64,
}

#[derive(Deserialize, Clone, Copy, PartialEq, Default)]
#[serde(rename_all = "lowercase")]
pub enum Health {
    Bad,
    Waiting,
    Running,
    #[default]
    Fine,
    Unseen,
}

#[derive(Deserialize)]
pub struct Ghost {
    pub key: String,
    pub title: String,
    pub announcer: String,
}

#[derive(Deserialize)]
pub struct Link {
    pub from: String,
    pub to: String,
    pub label: Option<String>,
    pub trigger: Option<TriggerRef>,
}

#[derive(Deserialize, Serialize, Clone)]
pub struct TriggerRef {
    pub run: String,
    pub index: usize,
}

#[derive(Deserialize)]
pub struct Todo {
    pub key: String,
    pub title: String,
    pub project: String,
    pub due: String,
    pub when: String,
    pub problems: Vec<String>,
}

#[derive(Deserialize)]
pub struct Attention {
    pub key: String,
    pub title: String,
    pub project: Option<String>,
    pub status: Health,
    pub problems: Vec<String>,
    pub triggers: Vec<Announced>,
}

#[derive(Deserialize)]
pub struct Announced {
    pub run: String,
    pub index: usize,
    pub label: String,
}

#[derive(Deserialize, Serialize, Clone, PartialEq)]
pub struct Note {
    pub file: String,
    pub line: usize,
    pub indent: usize,
    pub text: String,
}

#[derive(Deserialize)]
pub struct Run {
    pub id: String,
    pub label: String,
    pub content: Option<Value>,
    pub start: DateTime<Utc>,
    pub took: f64,
    pub problems: Vec<String>,
    pub said: Option<Said>,
    pub subtasks: Vec<Subtask>,
    pub triggers: Vec<Pending>,
    pub log: Option<String>,
    pub trace: Vec<Span>,
    pub diagnosis: Option<String>,
    pub diagnosable: bool,
}

/// A run in the chain the shown one is part of.
#[derive(Deserialize)]
pub struct Span {
    pub id: String,
    pub topic: String,
    pub label: String,
    pub start: DateTime<Utc>,
    pub end: Option<DateTime<Utc>>,
    pub depth: usize,
    pub status: String,
}

#[derive(Deserialize)]
pub struct Said {
    pub summary: String,
    pub success: bool,
    pub result: Option<Value>,
}

#[derive(Deserialize)]
pub struct Subtask {
    pub topic: String,
    pub problems: Vec<String>,
    pub said: Option<Said>,
}

#[derive(Deserialize)]
pub struct Pending {
    pub index: usize,
    pub label: String,
}

/// Node positions by key, in grid space at zoom 1.
pub type Layout = HashMap<String, [f32; 2]>;

pub enum Msg {
    View(View),
    /// The view as it was at a time.
    Past(DateTime<Utc>, Result<View, String>),
    Gone(String),
    Details(String, Vec<Run>),
    Layout(Layout),
    Sent(Result<(), String>),
    Diagnosed(String, Result<(), String>),
    Image(String, Result<Vec<u8>, String>),
}

pub struct Net {
    server: String,
    ws: Option<(ewebsock::WsSender, ewebsock::WsReceiver)>,
    retry: Instant,
    tx: Sender<Msg>,
    rx: Receiver<Msg>,
    wake: Arc<dyn Fn() + Send + Sync>,
}

impl Net {
    pub fn new(server: String, wake: Arc<dyn Fn() + Send + Sync>) -> Self {
        let (tx, rx) = channel();
        Net { server, ws: None, retry: Instant::now(), tx, rx, wake }
    }

    /// What arrived since the last frame; reconnects every few seconds while down.
    pub fn poll(&mut self) -> Vec<Msg> {
        if self.ws.is_none() && Instant::now() >= self.retry {
            self.retry = Instant::now() + Duration::from_secs(3);
            let wake = self.wake.clone();
            let url = self.server.replacen("http", "ws", 1) + "/";
            match ewebsock::connect_with_wakeup(url, Default::default(), move || wake()) {
                Ok(ws) => self.ws = Some(ws),
                Err(e) => _ = self.tx.send(Msg::Gone(e)),
            }
        }
        let mut out: Vec<Msg> = self.rx.try_iter().collect();
        while let Some(ev) = self.ws.as_ref().and_then(|(_, rx)| rx.try_recv()) {
            match ev {
                ewebsock::WsEvent::Message(ewebsock::WsMessage::Text(t)) => match serde_json::from_str(&t) {
                    Ok(v) => out.push(Msg::View(v)),
                    Err(e) => out.push(Msg::Gone(format!("The server sent what this window can't read: {e}"))),
                },
                ewebsock::WsEvent::Error(e) => {
                    out.push(Msg::Gone(e));
                    self.ws = None;
                }
                ewebsock::WsEvent::Closed => {
                    out.push(Msg::Gone("The server closed the connection.".into()));
                    self.ws = None;
                }
                _ => {}
            }
        }
        out
    }

    /// A topic's runs, now or as they were at a time.
    pub fn details(&self, topic: &str, at: Option<DateTime<Utc>>) {
        let topic = topic.to_owned();
        self.fetch(ehttp::Request::get(format!("{}/api/topic?topic={}{}", self.server, encode(&topic), when(at))), move |r| {
            r.and_then(|b| serde_json::from_slice(&b).map_err(|e| e.to_string())).ok().map(|d| Msg::Details(topic, d))
        });
    }

    pub fn past(&self, at: DateTime<Utc>) {
        self.fetch(ehttp::Request::get(format!("{}/api/view?{}", self.server, &when(Some(at))[1..])), move |r| {
            Some(Msg::Past(at, r.and_then(|b| serde_json::from_slice(&b).map_err(|e| e.to_string()))))
        });
    }

    pub fn note(&self, n: &Note) {
        let req = ehttp::Request::post(format!("{}/api/note", self.server), serde_json::to_vec(n).unwrap());
        self.fetch(req, |r| Some(Msg::Sent(r.map(|_| ()))));
    }

    /// Asks Claude about a run: it takes a while.
    pub fn diagnose(&self, run: &str) {
        let mut req = ehttp::Request::post(format!("{}/api/diagnose", self.server), serde_json::to_vec(&serde_json::json!({"run": run})).unwrap());
        req.timeout = Some(Duration::from_secs(330));
        let run = run.to_owned();
        self.fetch(req, |r| Some(Msg::Diagnosed(run, r.map(|_| ()))));
    }

    /// An image in a run's content or result.
    pub fn image(&self, path: &str) {
        let path = path.to_owned();
        self.fetch(ehttp::Request::get(self.file_url(&path)), |r| Some(Msg::Image(path, r)));
    }

    pub fn layout(&self) {
        self.fetch(ehttp::Request::get(format!("{}/api/layout", self.server)), |r| {
            Some(Msg::Layout(r.ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()))
        });
    }

    pub fn save_layout(&self, l: &Layout) {
        let req = ehttp::Request::put(format!("{}/api/layout", self.server), serde_json::to_vec(l).unwrap());
        self.fetch(req, |r| r.err().map(|e| Msg::Sent(Err(format!("Couldn't save the layout: {e}")))));
    }

    pub fn send(&self, t: &TriggerRef) {
        let req = ehttp::Request::post(format!("{}/api/send", self.server), serde_json::to_vec(t).unwrap());
        self.fetch(req, |r| Some(Msg::Sent(r.map(|_| ()))));
    }

    pub fn todo(&self, body: &Value) {
        let req = ehttp::Request::post(format!("{}/api/todo", self.server), serde_json::to_vec(body).unwrap());
        self.fetch(req, |r| Some(Msg::Sent(r.map(|_| ()))));
    }

    pub fn file_url(&self, path: &str) -> String {
        format!("{}/file?path={}", self.server, encode(path))
    }

    /// A file a run gave as its result, from the server, to open.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn file(&self, path: &str, then: impl FnOnce(Result<Vec<u8>, String>) + Send + 'static) {
        ehttp::fetch(ehttp::Request::get(self.file_url(path)), move |r| {
            then(r.map_err(|e| e.to_string()).and_then(|r| if r.ok { Ok(r.bytes) } else { Err(r.text().unwrap_or("").to_owned()) }))
        });
    }

    fn fetch(&self, req: ehttp::Request, msg: impl FnOnce(Result<Vec<u8>, String>) -> Option<Msg> + Send + 'static) {
        let (tx, wake) = (self.tx.clone(), self.wake.clone());
        ehttp::fetch(req, move |r| {
            let body = r.and_then(|r| if r.ok { Ok(r.bytes) } else { Err(format!("{} {}", r.status, r.text().unwrap_or(""))) });
            if let Some(m) = msg(body) {
                _ = tx.send(m);
                wake();
            }
        });
    }
}

fn when(at: Option<DateTime<Utc>>) -> String {
    at.map_or(String::new(), |t| format!("&at={}", encode(&t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))))
}

fn encode(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"/-_.".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}
