# control-dashboard protocol

`server/` (Haskell) listens to every control-event, decides what is wrong, and
serves the dashboard as JSON. `../control-mindustry/` draws it as a Mindustry
world, polling every 2 seconds; its buttons POST to the endpoints below.

## `GET /api/system`: everything

`{"summary", "triggers", "items"}`: the summary as in `/api/status`, the
triggers offered for sending (`{"topic", "content", "last"}`, `content`
saying what JSON the trigger takes, or null), and every machine, service
and event: its `topic`, `kind` (`"machine"`, `"service"` or `"event"`),
`status`, `problems`, `when` it last ran, its last 30 `runs`' statuses oldest
first, a machine's `gauges` (percentages), the `sends` waiting (`{"run",
"index", "label", "to"}`, as `/api/send` takes them), the reactions `awaited`,
the run to `dismiss` if there's something to dismiss, and for events the
`depth`, `parent` and `via` (a trigger's label) of the tree they're listed in.

## `GET /api/topic?topic=T`: a topic's last 20 runs

`{"topic", "log", "runs"}`, newest first, each with its `label`, `status`,
`when`, `took`, `problems`, `sends`, `summary`, `content`, `result` and the
`chain` of runs it is part of. `log` is the end of the script's log, if any.

## `GET /api/status`, and `/` as a WebSocket

`{"connected": true, "status": "bad", "bad": 2, "waiting": 1}`: whether the
server reaches the broker, the worst there is (`"bad"`, `"waiting"` or
`"fine"`), how many topics are bad and how many triggers wait to be sent. The
WebSocket sends it on connecting and again whenever it changes: the menu bar
dot (`dot/`) shows it.

## `POST /api/send`: send a trigger a run announced

Body `{"run": "uuid", "index": 0}`. `200` once sent; otherwise a status with
the reason as text, as for the other two.

## `POST /api/trigger`: send a trigger offered with `--trigger`

Body `{"topic": "trigger/…", "content": "[\"--dry-run\"]"}`: `content` is text
holding JSON, sent as the trigger's content. Empty or missing sends none; text
that isn't JSON is refused with `400`.

## `POST /api/dismiss`: want no more of a run

Body `{"run": "uuid"}`. Its problems and unsent triggers are forgotten; the
topic's next run is judged afresh.

## What the server announces

When a topic goes bad it sends `dashboard/problem/<topic>`, with content
`{"topic", "problems", "run"}` and its first problem as label; when it's no
longer bad, `dashboard/healthy/<topic>`. Anything may react to them.
