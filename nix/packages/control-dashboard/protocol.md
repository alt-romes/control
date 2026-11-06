# control-dashboard protocol

`server/` (Haskell) listens to every control-event and decides what is wrong.
Windows (`ui/`, and any other) only draw what it says. Everything is JSON;
times are ISO 8601 UTC, durations are seconds.

A plain `GET` of any other path serves the server's `--web` directory: the
dashboard built for browsers, at `/`.

## `GET /` as a WebSocket: the view

On connecting, and again whenever it changes (at most every second), the
server sends the whole view. Clients send nothing on it.

```json
{
  "connected": true,
  "status": "bad",
  "now": [{"key": "system/m4", "status": "bad", "problems": ["Disk 98% full."], "triggers": [{"run": "uuid", "index": 0, "label": "retry"}]}],
  "machines": [Item],
  "services": [Item],
  "nodes": [Item],
  "ghosts": [{"key": "a/b|trigger/c", "title": "x/y", "announcer": "a/b"}],
  "links": [{"from": "a/b", "to": "x/y", "label": "print the label", "trigger": {"run": "uuid", "index": 0}}],
  "said": [{"key": "a/b#content", "under": "a/b", "title": "content", "value": any JSON}],
  "places": {"a/b": [0, 0], "a/b#content": [0, 1], "x/y": [1, 0]}
}
```

- `connected`: whether the server reaches the broker.
- `status`: the worst of `now`: `"bad"`, `"waiting"` or `"fine"`. All a menu
  bar needs.
- `now` is what needs the user, worst first: topics that are bad, then those
  waiting for a trigger to be sent (`triggers`, see below).
- `machines` are the `system/<machine>` topics, `services` the `healthcheck/…`
  topics, `nodes` everything else worth a node in the graph.
- An `Item` is `{"topic", "status", "last", "stats", "problems", "group", "recent"}`:
  - `status` is `"bad"`, `"waiting"` (a trigger is the user's to send),
    `"running"`, `"fine"` or `"unseen"`. Only the first three deserve colour.
  - `last`: when its latest run started, or `null`.
  - `stats`: a machine's load, memory and disk, as text, or `null`.
  - `problems`: what's wrong, as sentences.
  - `group`: for nodes, the group to frame it in with its siblings (e.g.
    `"finances"` for `script/finances/…`), or `null`. A ghost is in its
    announcer's group, and what a node said in the node's.
  - `recent`: its last 30 runs, oldest first, each `{"status", "took"}`, the
    status being `"bad"` (failed or overran), `"running"` or `"fine"`.
- A ghost is a node for an event that hasn't happened yet: the reaction a
  pending trigger would cause, or a reaction a run's rules expect. Draw it
  faded. Its `key` is what links refer to.
- A link goes from one node (or ghost) key to another. `label` is the trigger
  that connects them, if any; `trigger`, when present, is a pending trigger to
  send (see below), and the link should look actionable.
- `said` is what a node's latest run started with (`content`) and finished
  with (`result`), each a node of its own under it.
- `places` puts every graph node, ghost and `said` node in a column and a row:
  a column per step down a chain of links, and rows from the top. A row is as
  tall as its tallest node, so where it is on screen is the window's to say.

## What the server announces

When a topic goes bad it sends `dashboard/problem/<topic>`, with content
`{"topic", "problems", "run"}` and its first problem as label; when it's no
longer bad, `dashboard/healthy/<topic>`. Anything may react to them.

## `GET /api/topic?topic=T`: a topic's last 20 runs, newest first

```json
[{
  "id": "uuid", "label": "Sync bank accounts", "content": any JSON or null, "start": "…", "end": "…" or null, "took": 1.5,
  "problems": ["…"],
  "said": {"summary": "…", "success": true, "result": any JSON} or null,
  "subtasks": [{"topic": "…", "problems": ["…"], "said": … or null}],
  "triggers": [{"index": 0, "label": "retry"}],
  "log": "the end of its log" or null,
  "trace": [{"id", "topic", "label", "start", "end", "depth": 0, "status": "bad"}],
  "diagnosis": "what Claude made of it" or null, "diagnosable": true
}]
```

`subtasks` only has the failed ones, in full, since they have no node of their
own. `log` is only there for runs with problems, when the server knows where
logs are.

`trace` is the chain the run is part of, from the run that began it, each run
followed by its subtasks and reactions, `depth` deep; empty when it's alone.
`diagnosable` says Claude can be asked about it (see below).

## `POST /api/send`: send a pending trigger

Body `{"run": "uuid", "index": 0}`. `200` once sent; otherwise a status with
the reason as text.

## Claude

With `--claude`, the server hands the `claude` CLI what it knows, with no
tools and in a sandbox, and answers `200` with its reply as text once it has
one (it takes a while). One question is asked at a time.

- `POST /api/diagnose`, body `{"run": "uuid"}`: what went wrong with a run
  that has problems. Replies are kept, and are the run's `diagnosis`.
- `POST /api/ask`, body `{"question": "…"}`: anything about every topic's
  problems and last runs.

## `GET /file?path=P`: a file a run gave as its result

Only paths that are some run's `said.result`, or images (`.png`, `.jpg`)
named in some run's content, are served.
