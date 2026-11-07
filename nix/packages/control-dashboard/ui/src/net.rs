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
    pub now: Vec<Attention>,
    pub machines: Vec<Item>,
    pub services: Vec<Item>,
    pub nodes: Vec<Item>,
    pub ghosts: Vec<Ghost>,
    pub links: Vec<Link>,
    pub said: Vec<Said>,
    /// Each graph node's column and row.
    pub places: HashMap<String, (usize, usize)>,
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
}

#[derive(Deserialize)]
pub struct Tick {
    pub status: Health,
    pub took: f64,
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

/// What a node's latest run started or finished with, as a node under it.
#[derive(Deserialize)]
pub struct Said {
    pub key: String,
    pub under: String,
    pub title: String,
    pub value: Value,
}

#[derive(Deserialize, Serialize, Clone)]
pub struct TriggerRef {
    pub run: String,
    pub index: usize,
}

#[derive(Deserialize)]
pub struct Attention {
    pub key: String,
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

#[derive(Deserialize)]
pub struct Run {
    pub id: String,
    pub label: String,
    pub content: Option<Value>,
    pub start: DateTime<Utc>,
    pub took: f64,
    pub problems: Vec<String>,
    pub said: Option<Done>,
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
    pub status: Health,
}

#[derive(Deserialize)]
pub struct Done {
    pub summary: String,
    pub success: bool,
    pub result: Option<Value>,
}

#[derive(Deserialize)]
pub struct Subtask {
    pub topic: String,
    pub problems: Vec<String>,
    pub said: Option<Done>,
}

#[derive(Deserialize)]
pub struct Pending {
    pub index: usize,
    pub label: String,
}

pub enum Msg {
    View(View),
    Gone(String),
    Details(String, Vec<Run>),
    Sent(Result<(), String>),
    Diagnosed(String, Result<(), String>),
    Answer(Result<String, String>),
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

    /// Asks for another frame.
    pub fn wake(&self) {
        (self.wake)()
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

    pub fn send(&self, t: &TriggerRef) {
        let req = ehttp::Request::post(format!("{}/api/send", self.server), serde_json::to_vec(t).unwrap());
        self.fetch(req, |r| Some(Msg::Sent(r.map(|_| ()))));
    }

    /// Asks Claude about a run: it takes a while.
    pub fn diagnose(&self, run: &str) {
        let run = run.to_owned();
        self.fetch(slow(self.post("diagnose", serde_json::json!({"run": run}))), |r| Some(Msg::Diagnosed(run, r.map(|_| ()))));
    }

    /// Asks Claude about the history: it takes a while too.
    pub fn ask(&self, question: &str) {
        self.fetch(slow(self.post("ask", serde_json::json!({"question": question}))), |r| {
            Some(Msg::Answer(r.map(|b| String::from_utf8_lossy(&b).into_owned())))
        });
    }

    /// Forgets topics: their runs are dropped, until they run again.
    pub fn forget(&self, topics: &[String]) {
        self.fetch(self.post("forget", serde_json::json!({"topics": topics})), |r| Some(Msg::Sent(r.map(|_| ()))));
    }

    /// An image in a run's content or result.
    pub fn image(&self, path: &str) {
        let path = path.to_owned();
        self.fetch(ehttp::Request::get(self.file_url(&path)), |r| Some(Msg::Image(path, r)));
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

    fn post(&self, path: &str, body: Value) -> ehttp::Request {
        ehttp::Request::post(format!("{}/api/{path}", self.server), serde_json::to_vec(&body).unwrap())
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

/// Claude can take minutes.
fn slow(mut req: ehttp::Request) -> ehttp::Request {
    req.timeout = Some(Duration::from_secs(330));
    req
}

fn encode(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"/-_.".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}
