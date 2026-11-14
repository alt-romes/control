# control-dashboard protocol

`server/` (Haskell) listens to every control-event, decides what is wrong, and
serves the dashboard as a page.

## `GET /`: the overview; `GET /?topic=T`: a topic's last 20 runs

What needs the user, the triggers to send, and every machine, service and
event with its last 30 runs. The page fetches itself again every 5 seconds
and whenever the WebSocket below says things changed; its buttons POST to the
endpoints below.

## `GET /api/status`, and `GET /` as a WebSocket

`{"connected": true, "status": "bad", "bad": 2, "waiting": 1}`: whether the
server reaches the broker, the worst there is (`"bad"`, `"waiting"` or
`"fine"`), how many topics are bad and how many triggers wait to be sent. The
WebSocket sends it on connecting and again whenever it changes: the menu bar
dot (`dot/`) shows it.

## `POST /api/send`: send a trigger a run announced

Body `{"run": "uuid", "index": 0}`. `200` once sent; otherwise a status with
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
