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
    pub machines: Vec<Item>,
    pub services: Vec<Item>,
    pub nodes: Vec<Item>,
    pub ghosts: Vec<Ghost>,
    pub links: Vec<Link>,
}

#[derive(Deserialize)]
pub struct Item {
    pub topic: String,
    pub status: Health,
    pub last: Option<DateTime<Utc>>,
    pub stats: Option<String>,
    pub problems: Vec<String>,
    pub group: Option<String>,
}

#[derive(Deserialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Health {
    Bad,
    Waiting,
    Running,
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
    Gone(String),
    Details(String, Vec<Run>),
    Layout(Layout),
    Sent(Result<(), String>),
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

    pub fn details(&self, topic: &str) {
        let topic = topic.to_owned();
        self.fetch(ehttp::Request::get(format!("{}/api/topic?topic={}", self.server, encode(&topic))), move |r| {
            r.and_then(|b| serde_json::from_slice(&b).map_err(|e| e.to_string())).ok().map(|d| Msg::Details(topic, d))
        });
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

fn encode(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"/-_.".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}
