# control-dashboard protocol

`server/` (Haskell) listens to every control-event, decides what is wrong, and
serves the page in `server/web/` (given with `--web`): the system as a whole
kingdom in three.js from Kenney's Fantasy Town, Castle, Nature, Graveyard, Survival,
Watercraft, Cube Pets and Mini Characters kits, with its music and sounds.

## `GET /api/system`: the system as a net

`{"summary", "now", "actions", "requests", "nodes", "edges"}`. `actions` are the
triggers offered with `--trigger`, each with when it was last sent and how what
reacted to it went. `requests` are what runs asked you to send, waiting ones
first: every unsent trigger of a run not dismissed, however old, and those sent
in the last day with what came of them; each with its label, topic, data, the
node that asked and that run's summary. A node is a topic (the dashboard's
announcements about every topic are one node per kind), with its health, its
problems, the triggers it waits to send, its latest run and rules, and its last
30 runs' health. An edge is `"part"` (a subtask in its parent's runs),
`"reaction"`, `"trigger"` (from what announced it, or `@you`, to what reacted
to it, labelled with the trigger) or `"awaited"` (a reaction a run expects);
a trigger nothing reacted to yet and an awaited reaction no topic matches lead
to a ghost node, `?<topic>`.

## `GET /api/runs?hours=H`: the runs of the last H hours

Each with its node, health, the run it was part of and the runs it reacted to.

## `GET /api/topic?topic=T`: a node's last 20 runs in full

Each with its problems, content, result and the chain of runs it is part of;
the end of the log if there is one; a machine's gauges over every run
remembered.

The page fetches these again whenever the WebSocket below says things
changed, and its buttons POST to the endpoints below.

## `GET /api/status`, and `GET /` as a WebSocket

`{"connected": true, "status": "bad", "bad": 2, "waiting": 1}`: whether the
server reaches the broker, the worst there is (`"bad"`, `"waiting"` or
`"fine"`), how many topics are bad and how many triggers wait to be sent. The
WebSocket sends it on connecting and again whenever it changes: the menu bar
dot (`dot/`) shows it.

## `POST /api/send`: send a trigger a run announced

Body `{"run": "uuid", "index": 0}`, a request still waiting. `200` once sent; otherwise a status with
the reason as text, as for the other two.

## `POST /api/trigger`: send a trigger offered with `--trigger`

Body `{"topic": "trigger/…", "content": "…"}`, the content optional.

## `POST /api/dismiss`: want no more of a run

Body `{"run": "uuid"}`. Its problems and unsent triggers are forgotten; the
topic's next run is judged afresh.

## What the server announces

When a topic goes bad it sends `dashboard/problem/<topic>`, with content
`{"topic", "problems", "run"}` and its first problem as label; when it's no
longer bad, `dashboard/healthy/<topic>`. Anything may react to them.
