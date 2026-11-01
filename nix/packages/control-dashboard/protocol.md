# control-dashboard protocol

`server/` (Haskell) listens to every control-event and decides what is wrong.
Windows (`ui/`, and any other) only draw what it says. Everything is JSON;
times are ISO 8601 UTC, durations are seconds.

## `GET /` as a WebSocket: the view

On connecting, and again whenever it changes (at most every second), the
server sends the whole view. Clients send nothing on it.

```json
{
  "connected": true,
  "machines": [Item],
  "services": [Item],
  "nodes": [Item],
  "ghosts": [{"key": "a/b|trigger/c", "title": "x/y", "announcer": "a/b"}],
  "links": [{"from": "a/b", "to": "x/y", "label": "print the label", "trigger": {"run": "uuid", "index": 0}}]
}
```

- `connected`: whether the server reaches the broker.
- `machines` are the `system/<machine>` topics, `services` the `healthcheck/…`
  topics, `nodes` everything else worth a node in the graph.
- An `Item` is `{"topic", "status", "last", "stats", "problems", "group"}`:
  - `status` is `"bad"`, `"waiting"` (a trigger is the user's to send),
    `"running"`, `"fine"` or `"unseen"`. Only the first three deserve colour.
  - `last`: when its latest run started, or `null`.
  - `stats`: a machine's load, memory and disk, as text, or `null`.
  - `problems`: what's wrong, as sentences.
  - `group`: for nodes, the group to frame it in with its siblings (e.g.
    `"finances"` for `script/finances/…`), or `null`. A ghost is in its
    announcer's group.
- A ghost is a node for an event that hasn't happened yet: the reaction a
  pending trigger would cause, or a reaction a run's rules expect. Draw it
  faded. Its `key` is what links refer to.
- A link goes from one node (or ghost) key to another. `label` is the trigger
  that connects them, if any; `trigger`, when present, is a pending trigger to
  send (see below), and the link should look actionable.

## `GET /api/topic?topic=T`: a topic's last 20 runs, newest first

```json
[{
  "id": "uuid", "label": "Sync bank accounts", "start": "…", "end": "…" or null, "took": 1.5,
  "problems": ["…"],
  "said": {"summary": "…", "success": true, "result": any JSON} or null,
  "subtasks": [{"topic": "…", "problems": ["…"], "said": … or null}],
  "triggers": [{"index": 0, "label": "retry"}],
  "log": "the end of its log" or null
}]
```

`subtasks` only has the failed ones, in full, since they have no node of their
own. `log` is only there for runs with problems, when the server knows where
logs are.

## `POST /api/send`: send a pending trigger

Body `{"run": "uuid", "index": 0}`. `200` once sent; otherwise a status with
the reason as text.

## `GET /api/layout`, `PUT /api/layout`: node positions

`{"key": [x, y]}`, in grid units at zoom 1, shared by every window. Zoom is
each window's own.

## `GET /file?path=P`: a file a run gave as its result

Only paths that are some run's `said.result` are served.
