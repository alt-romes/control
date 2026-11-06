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
  "since": "2026-11-02T00:09:22Z",
  "now": [Attention],
  "machines": [Item],
  "services": [Item],
  "nodes": [Item],
  "ghosts": [{"key": "a/b|trigger/c", "title": "x/y", "announcer": "a/b"}],
  "links": [{"from": "a/b", "to": "x/y", "label": "print the label", "trigger": {"run": "uuid", "index": 0}}],
  "todos": [Todo],
  "notes": [{"file": "satisago/README.md", "line": 41, "indent": 4, "text": "Do this"}]
}
```

- `connected`: whether the server reaches the broker.
- `status`: the worst of `now`, `"bad"`, `"waiting"` or `"fine"`: all a menu
  bar needs.
- `since`: when the history begins, as far as a window can rewind.
- `now` is what needs the user, worst first: `{"key", "title", "project",
  "status", "problems", "triggers"}`, a topic or a todo (`project` is a
  todo's). Bad topics, late todos, topics waiting for a trigger (`triggers`,
  each `{"run", "index", "label"}`, to send), then today's todos.
- `machines` are the `system/<machine>` topics, `services` the `healthcheck/…`
  topics, `nodes` everything else worth a node in the graph.
- An `Item` is `{"topic", "status", "last", "stats", "problems", "group",
  "recent", "content", "result"}`:
  - `status` is `"bad"`, `"waiting"` (a trigger is the user's to send),
    `"running"`, `"fine"` or `"unseen"`. Only the first three deserve colour.
  - `last`: when its latest run started, or `null`.
  - `stats`: a machine's load, memory and disk, as text, or `null`.
  - `problems`: what's wrong, as sentences.
  - `group`: for nodes, the group to frame it in with its siblings (e.g.
    `"finances"` for `script/finances/…`), or `null`. A ghost is in its
    announcer's group.
  - `recent`: its last 30 runs, oldest first, each `{"status", "took"}`, the
    status being `"bad"` (failed or overran), `"running"` or `"fine"`.
  - `content`, `result`: what its latest run started with and finished with.
- A ghost is a node for an event that hasn't happened yet: the reaction a
  pending trigger would cause, or a reaction a run's rules expect. Draw it
  faded. Its `key` is what links refer to.
- A link goes from one node (or ghost) key to another. `label` is the trigger
  that connects them, if any; `trigger`, when present, is a pending trigger to
  send (see below), and the link should look actionable.

## Todos

A todo is an event on `todo/<project>`, anything may send: the project is just
the path, and its label is what to do. Its content may give `{"due": day}`, else
it's due the day it's sent. Later events on its topic that react to it change
it: `{"due": day}` reschedules it, `{"done": true}` closes it, and a label
renames it.

A `Todo` in the view is an open one: `{"key": "todo/<id>", "title", "project",
"due", "when", "problems"}`, sorted by project then due date. `when` is
`"today"` (due today or earlier), `"week"` (by Sunday) or `"year"` (later);
`problems` say it's late.

A note is an unticked `- [ ] ` checkbox in the server's `--notes` directories:
its `file` is named from the directory, `line` counts from 0.

## `POST /api/note`: tick a note

Body: the note, as the view has it. `200` once its file says `- [x]`, `409` if
that line has changed since.

## `POST /api/todo`: send a todo event

Body `{"verb": "capture", "label", "when", "about"}`, `{"verb": "when", "item":
"id", "when"}` or `{"verb": "done", "item": "id"}`, `when` being `"today"`,
`"week"` or `"year"` (the end of it, as its due date). A capture's project is
the label's `project/path: ` prefix, else the topic it's `about`, else
`general`. `200` once sent.

## `GET /api/topic?topic=T[&at=TIME]`: a topic's last 20 runs, newest first

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

With `at`, an ISO 8601 time, everything is as the server knew it then.

## `GET /api/view?at=TIME`: the view as it was

The view, as the WebSocket would have sent it at that time: the history up to
then, replayed.

## `POST /api/diagnose`: ask Claude about a run

Body `{"run": "uuid"}`, for a run with problems the server still remembers.
The server hands the `claude` CLI everything it knows about the run, with no
tools and in a sandbox, and answers `200` with its reply as text, once it
has one (it takes a while). Replies are kept, and are the run's `diagnosis`.

## `POST /api/send`: send a pending trigger

Body `{"run": "uuid", "index": 0}`. `200` once sent; otherwise a status with
the reason as text.

## `GET /api/layout`, `PUT /api/layout`: node positions

`{"key": [x, y]}`, in grid units at zoom 1, shared by every window. Zoom is
each window's own.

## `GET /file?path=P`: a file a run gave as its result

Only paths that are some run's `said.result`, or images (`.png`, `.jpg`)
named in some run's content, are served.
