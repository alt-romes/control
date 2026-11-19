package control;

import arc.Core;
import arc.Events;
import arc.graphics.Color;
import arc.graphics.g2d.Draw;
import arc.graphics.g2d.Font;
import arc.graphics.g2d.Lines;
import arc.input.KeyCode;
import arc.math.Mathf;
import arc.math.geom.Vec2;
import arc.scene.ui.layout.Scl;
import arc.scene.ui.layout.Table;
import arc.struct.FloatSeq;
import arc.struct.IntIntMap;
import arc.struct.ObjectMap;
import arc.struct.ObjectSet;
import arc.struct.Seq;
import arc.util.Align;
import arc.util.Http;
import arc.util.Time;
import arc.util.Tmp;
import arc.util.serialization.Jval;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import mindustry.content.Blocks;
import mindustry.content.Fx;
import mindustry.content.Items;
import mindustry.content.StatusEffects;
import mindustry.content.UnitTypes;
import mindustry.game.EventType.ClientLoadEvent;
import mindustry.game.EventType.Trigger;
import mindustry.game.EventType.UnitDestroyEvent;
import mindustry.game.Rules;
import mindustry.game.Team;
import mindustry.gen.Building;
import mindustry.gen.Unit;
import mindustry.graphics.Layer;
import mindustry.graphics.Pal;
import mindustry.mod.Mod;
import mindustry.type.Item;
import mindustry.ui.Fonts;
import mindustry.ui.Styles;
import mindustry.ui.dialogs.BaseDialog;
import mindustry.world.Block;
import mindustry.world.Tile;

import static mindustry.Vars.*;

/**
 * The control-dashboard server's topics as a factory floor: one building per
 * topic, burning while it's bad, with an enemy by it whose death dismisses the
 * run. Each run that finishes ships its building's item to the core, or scrap
 * if it failed.
 */
public class Control extends Mod {
    static final String server = System.getProperty("control.url", "http://127.0.0.1:5001");
    static final int columnWidth = 32, rowHeight = 4, columnRows = 12, height = columnRows * rowHeight + 12, left = 8;
    /** The row of the main line, which runs left into the core. */
    static final int mainLine = 3;
    static final Color bad = Color.valueOf("ff5c5c"), running = Color.valueOf("6ba4ff");

    /** A line on the floor: a topic, a header, or something a topic waits on. */
    static class Row {
        String topic, text, sub = "", status = "fine", run, dismiss;
        Block block;
        Item item;
        boolean ghost;
        int depth, x, y, column;
        Row parent;
        Seq<String> runs = new Seq<>();
        Runnable tap;

        float cx() { return x * tilesize + block.offset; }
        float cy() { return y * tilesize + block.offset; }

        /** Whether a belt brings it from its parent: down the parent's trunk, then right. */
        boolean belted() { return parent != null && !ghost && parent.column == column; }

        /** From its parent's middle along the belt to its own. */
        FloatSeq path() {
            return FloatSeq.with(parent.cx(), parent.cy(), parent.x * tilesize, y * tilesize, cx(), cy());
        }

        /** Where it puts what its runs make: the start of its belt to the core, out of its left side. */
        Tile output() { return world.tile(x - 1, y + 1); }
    }

    /** An item along a reaction's belt, drawn: routers would send real ones anywhere. */
    record Flight(Item item, FloatSeq path, float start, Row to, Item made) {}

    /**
     * What an event makes: the next of what the run it reacted to made, so
     * chains pay off. Not a static field: items only exist once content loads.
     */
    static Item[] ladder() {
        return new Item[]{Items.copper, Items.lead, Items.graphite, Items.silicon, Items.titanium, Items.thorium, Items.plastanium, Items.phaseFabric, Items.surgeAlloy};
    }

    static Item better(Item i) {
        Item[] l = ladder();
        for (int n = 0; n < l.length - 1; n++) if (l[n] == i) return l[n + 1];
        return l[l.length - 1];
    }

    Seq<Row> rows = new Seq<>();
    Jval system;
    boolean reachable = true;
    Table hud = new Table(Styles.black6);
    /** Each topic's latest run and its status, as last seen. */
    ObjectMap<String, String[]> seen = new ObjectMap<>();
    Seq<Flight> flights = new Seq<>();
    /** The enemy standing for each bad run, by the run to dismiss. */
    ObjectMap<String, Unit> enemies = new ObjectMap<>();
    /** Runs whose enemy died, so it isn't back before the dismissal is. */
    ObjectSet<String> killed = new ObjectSet<>();
    /** The tiles we put buildings on: the rest are the player's. */
    ObjectSet<Tile> placed = new ObjectSet<>();
    /** Items waiting to go onto each topic's belt, as it has room. */
    ObjectMap<String, Seq<Item>> made = new ObjectMap<>();
    /** Each topic's row, as last laid out. */
    ObjectMap<String, Row> topics = new ObjectMap<>();
    /** How many items a run makes. */
    static final int perRun = 5;
    /** World units a flight goes per tick. */
    static final float speed = 2.5f;

    @Override
    public void init() {
        Events.on(ClientLoadEvent.class, e -> {
            Core.settings.put("backgroundpause", false);
            ui.hudGroup.fill(t -> t.top().add(hud).margin(8).padTop(8));
            ui.menufrag.addButton("Control", this::start);
            Executors.newSingleThreadScheduledExecutor(r -> { Thread t = new Thread(r, "control"); t.setDaemon(true); return t; })
                .scheduleWithFixedDelay(this::poll, 0, 2, TimeUnit.SECONDS);
            Core.app.post(this::start);
        });
        Events.run(Trigger.update, this::update);
        Events.run(Trigger.draw, this::draw);
        Events.on(UnitDestroyEvent.class, e -> {
            String run = enemies.findKey(e.unit, true);
            if (run == null) return;
            enemies.remove(run);
            killed.add(run);
            post("/api/dismiss", Jval.newObject().put("run", run), "Dismissed");
        });
    }

    void start() {
        int width = Math.max(120, left + (rows.isEmpty() ? 0 : rows.peek().column + 1) * columnWidth + 8);
        ui.loadAnd(() -> {
            logic.reset();
            world.loadGenerator(width, height, tiles -> {
                tiles.each((x, y) -> tiles.set(x, y, new Tile(x, y, Blocks.metalFloor, Blocks.air, Blocks.air)));
                tiles.getn(3, mainLine).setBlock(Blocks.coreShard, Team.sharded, 0);
            });
            Rules r = new Rules();
            r.waves = r.waveTimer = r.canGameOver = r.fire = r.fog = r.lighting = false;
            state.rules = r;
            logic.play();
            enemies.clear();
            flights.clear();
            made.clear();
            placed.clear();
            build();
        });
    }

    void poll() {
        Http.get(server + "/api/system").timeout(3000)
            .error(e -> Core.app.post(() -> { reachable = false; refreshHud(); }))
            .submit(res -> {
                String s = res.getResultAsString();
                Core.app.post(() -> { reachable = true; system = Jval.read(s); layout(); build(); play(); refreshHud(); });
            });
    }

    // * Laying out

    void layout() {
        Seq<Row> next = new Seq<>();
        ObjectMap<String, Row> byTopic = new ObjectMap<>();
        Seq<Jval> items = system.get("items").asArray();
        header(next, "Machines", items.contains(i -> i.getString("kind").equals("machine")));
        for (Jval i : items) if (i.getString("kind").equals("machine")) topic(next, byTopic, i, Blocks.memoryBank, Items.silicon, i.getString("topic").substring(7), 0);
        header(next, "Services", items.contains(i -> i.getString("kind").equals("service")));
        for (Jval i : items) if (i.getString("kind").equals("service")) topic(next, byTopic, i, Blocks.mechanicalDrill, Items.copper, i.getString("topic").substring(12), 0);
        Seq<Jval> triggers = system.get("triggers").asArray();
        header(next, "Triggers", !triggers.isEmpty());
        for (Jval t : triggers) {
            Row r = new Row();
            String topic = t.getString("topic");
            r.text = topic;
            r.sub = "sent " + (t.get("last").isNull() ? "never" : t.getString("last")) + ", click to send";
            r.block = Blocks.switchBlock;
            String takes = "Content, as JSON; empty for none" + (t.get("content").isNull() ? "" : "\n" + t.getString("content"));
            r.tap = () -> ui.showTextInput("Send " + topic, takes, 500, "", content ->
                post("/api/trigger", Jval.newObject().put("topic", topic).put("content", content), "Sent " + topic));
            next.add(r);
        }
        header(next, "Events", items.contains(i -> i.getString("kind").equals("event")));
        for (Jval i : items) if (i.getString("kind").equals("event")) {
            Row r = topic(next, byTopic, i, Blocks.graphitePress, ladder()[0], i.getString("topic"), i.getInt("depth", 0));
            r.parent = i.get("parent").isNull() ? null : byTopic.get(i.getString("parent"));
            if (r.parent != null) r.item = better(r.parent.item);
            if (!i.get("via").isNull()) r.sub = "after " + i.getString("via") + "; " + r.sub;
        }

        int column = 0, row = 0;
        for (int n = 0; n < next.size; n++) {
            Row r = next.get(n);
            int span = r.block == null ? 1 + subtree(next, n + 1) : r.depth == 0 ? subtree(next, n) : 1;
            if (row > 0 && row + span > columnRows) { column++; row = 0; }
            r.column = column;
            r.x = left + column * columnWidth + r.depth * 3;
            r.y = height - 6 - row * rowHeight;
            row++;
        }
        rows = next;
        topics = byTopic;
    }

    /** How many rows the topic at n takes with all that's under it. */
    static int subtree(Seq<Row> rs, int n) {
        int end = n + 1;
        while (end < rs.size && rs.get(end).depth > rs.get(n).depth) end++;
        return Math.min(end, rs.size) - n;
    }

    static void header(Seq<Row> rs, String title, boolean any) {
        if (!any) return;
        Row r = new Row();
        r.text = title.toUpperCase();
        r.status = "unseen";
        rs.add(r);
    }

    /** A topic, followed by the triggers it waits to have sent and the reactions it expects. */
    Row topic(Seq<Row> rs, ObjectMap<String, Row> byTopic, Jval i, Block block, Item item, String text, int depth) {
        Row r = new Row();
        String topic = i.getString("topic");
        Seq<Jval> problems = i.get("problems").asArray();
        r.topic = topic;
        r.text = text;
        r.status = i.getString("status");
        r.run = i.get("run").isNull() ? null : i.getString("run");
        r.dismiss = i.get("dismiss").isNull() ? null : i.getString("dismiss");
        r.block = block;
        r.item = item;
        r.depth = depth;
        r.sub = problems.isEmpty() ? i.getString("when") : problems.first().asString() + (problems.size > 1 ? " (and " + (problems.size - 1) + " more)" : "");
        Jval g = i.get("gauges");
        for (String k : new String[]{"load", "memory", "disk"}) if (g.has(k)) r.sub += "  " + k + " " + g.getInt(k, 0) + "%";
        for (Jval h : i.get("runs").asArray()) r.runs.add(h.asString());
        r.tap = () -> open(topic);
        rs.add(r);
        byTopic.put(topic, r);
        for (Jval s : i.get("sends").asArray()) {
            Row g2 = ghost(rs, r, s.getString("label") + " → " + s.getString("to"), "waiting");
            g2.sub = "waiting to be sent, click to send";
            g2.tap = () -> send(topic, s);
        }
        for (Jval f : i.get("awaited").asArray()) ghost(rs, r, f.asString(), "unseen").sub = "expected";
        return r;
    }

    static Row ghost(Seq<Row> rs, Row parent, String text, String status) {
        Row g = new Row();
        g.text = text;
        g.status = status;
        g.block = Blocks.graphitePress;
        g.ghost = true;
        g.parent = parent;
        g.depth = parent.depth + 1;
        rs.add(g);
        return g;
    }

    // * The world

    /**
     * Puts each topic's building where it goes, damaged while it's bad, and
     * the belts: between them, a trunk down from each parent with a router
     * where a child but the last branches off it, and from each to the core.
     */
    void build() {
        if (!state.isGame()) return;
        if (!rows.isEmpty() && left + (rows.peek().column + 1) * columnWidth > world.width()) { start(); return; }
        ObjectMap<Tile, Block> want = new ObjectMap<>();
        ObjectMap<Tile, Integer> rotation = new ObjectMap<>();
        ObjectMap<Row, Integer> lowest = new ObjectMap<>();
        for (Row r : rows) if (r.block != null && !r.ghost) want.put(world.tile(r.x, r.y), r.block);
        for (Row r : rows) if (r.belted()) {
            lowest.put(r.parent, Math.min(r.y, lowest.get(r.parent, r.y)));
            for (int y = r.parent.y - 1; y > r.y; y--) belt(want, rotation, r.parent.x, y, 3);
        }
        for (Row r : rows) if (r.belted()) {
            if (r.y > lowest.get(r.parent)) want.put(world.tile(r.parent.x, r.y), Blocks.router);
            else belt(want, rotation, r.parent.x, r.y, 0);
            for (int x = r.parent.x + 1; x < r.x; x++) belt(want, rotation, x, r.y, 0);
        }
        // Each topic's belt to the core: out of its left side to its column's
        // collector, crossing trunks at junctions, down to the main line.
        IntIntMap collectors = new IntIntMap();
        for (Row r : rows) if (r.item != null && !r.ghost) {
            int out = r.output().y, collector = left + r.column * columnWidth - 2;
            for (int x = r.output().x; x > collector; x--) {
                Tile t = world.tile(x, out);
                if (want.get(t) == Blocks.conveyor) want.put(t, Blocks.junction);
                else belt(want, rotation, x, out, 2);
            }
            collectors.put(collector, Math.max(out, collectors.get(collector, out)));
        }
        int far = 5;
        for (var c : collectors) {
            for (int y = c.value; y > mainLine; y--) belt(want, rotation, c.key, y, 3);
            far = Math.max(far, c.key);
        }
        for (int x = far; x >= 5; x--) belt(want, rotation, x, mainLine, 2);
        for (Tile t : placed.toSeq()) if (want.get(t) != t.block() || t.build != null && t.build.rotation != rotation.get(t, 0)) {
            t.remove();
            placed.remove(t);
        }
        for (var e : want) {
            Tile t = e.key;
            if (t.block() != e.value) {
                t.setBlock(e.value, state.rules.defaultTeam, rotation.get(t, 0));
                placed.add(t);
            }
        }
        for (Row r : rows) {
            Building b = r.block == null || r.ghost ? null : world.tile(r.x, r.y).build;
            if (b != null) b.health = b.maxHealth * (r.status.equals("bad") ? 0.3f : 1f);
        }
    }

    /** Where a flight is now, into out; whether it has arrived. */
    static boolean along(Flight f, Vec2 out) {
        FloatSeq p = f.path;
        float d = (Time.time - f.start) * speed;
        for (int i = 0; i + 3 < p.size; i += 2) {
            float len = Mathf.dst(p.get(i), p.get(i + 1), p.get(i + 2), p.get(i + 3));
            if (d < len) {
                out.set(p.get(i), p.get(i + 1)).lerp(p.get(i + 2), p.get(i + 3), d / len);
                return false;
            }
            d -= len;
        }
        out.set(p.get(p.size - 2), p.peek());
        return true;
    }

    static void belt(ObjectMap<Tile, Block> want, ObjectMap<Tile, Integer> rotation, int x, int y, int r) {
        Tile t = world.tile(x, y);
        want.put(t, Blocks.conveyor);
        rotation.put(t, r);
    }

    /**
     * Ships what each run that just finished made, from what it reacted to
     * and on its belt to the core, and keeps an enemy by each bad run.
     */
    void play() {
        if (!state.isGame()) return;
        ObjectMap<String, Row> bad = new ObjectMap<>();
        for (Row r : rows) {
            if (r.run != null) {
                String[] was = seen.put(r.topic, new String[]{r.run, r.status});
                if (was != null && !r.status.equals("running") && (!was[0].equals(r.run) || was[1].equals("running"))) {
                    Item item = r.status.equals("bad") ? Items.scrap : r.item;
                    if (r.belted()) flights.add(new Flight(r.parent.item, r.path(), Time.time, r, item));
                    else make(r.topic, item);
                }
            }
            if (r.dismiss != null && r.status.equals("bad") && !killed.contains(r.dismiss)) bad.put(r.dismiss, r);
        }
        for (String run : enemies.keys().toSeq()) if (!bad.containsKey(run) || enemies.get(run).dead()) enemies.remove(run).remove();
        for (var e : bad) if (!enemies.containsKey(e.key)) {
            // Flying, so no block can crush it: only shooting it dismisses the run.
            Unit u = UnitTypes.flare.spawn(Team.crux, e.value.cx() - 4, e.value.cy() + 12);
            u.apply(StatusEffects.unmoving, Float.POSITIVE_INFINITY);
            u.apply(StatusEffects.disarmed, Float.POSITIVE_INFINITY);
            enemies.put(e.key, u);
        }
    }

    void make(String topic, Item item) {
        Seq<Item> q = made.get(topic, Seq::new);
        for (int n = 0; n < perRun; n++) q.add(item);
    }

    void update() {
        if (!state.isGame()) return;
        flights.removeAll(f -> {
            if (!along(f, Tmp.v1)) return false;
            make(f.to.topic, f.made);
            return true;
        });
        for (var e : made) {
            Row r = topics.get(e.key);
            Building out = r == null ? null : r.output().build, from = r == null ? null : world.tile(r.x, r.y).build;
            if (out != null && from != null && !e.value.isEmpty() && out.acceptItem(from, e.value.first())) out.handleItem(from, e.value.remove(0));
        }
        for (Row r : rows) if (r.block != null && !r.ghost && r.status.equals("bad") && Mathf.chanceDelta(0.08)) {
            (Mathf.chance(0.5) ? Fx.fire : Fx.smoke).at(r.cx() + Mathf.range(6f), r.cy() + Mathf.range(6f));
        }
        if (Core.input.keyTap(KeyCode.mouseLeft) && !Core.scene.hasMouse()) {
            Vec2 m = Core.input.mouseWorld();
            if (enemies.values().toSeq().contains(u -> u.within(m, u.hitSize))) return;
            for (Row r : rows) {
                if (r.tap != null && m.x > r.cx() - 10 && m.x < r.cx() + (columnWidth - r.depth * 3 - 2) * tilesize && Math.abs(m.y - r.cy()) < 11) {
                    r.tap.run();
                    break;
                }
            }
        }
    }

    void draw() {
        if (!state.isGame()) return;
        for (Flight f : flights) {
            along(f, Tmp.v1);
            Draw.z(Layer.flyingUnit);
            Draw.rect(f.item.fullIcon, Tmp.v1.x, Tmp.v1.y, 6f, 6f);
        }
        Draw.reset();
        for (Row r : rows) {
            if (r.block == null) {
                Draw.z(Layer.playerName);
                text(r.text, r.x * tilesize - 4, r.y * tilesize + 4, Color.gray, 0.3f, columnWidth * tilesize);
                continue;
            }
            float x = r.cx(), y = r.cy(), right = x + r.block.size * tilesize / 2f + 4;
            float width = (left + (r.column + 1) * columnWidth - 1) * tilesize - right;
            Draw.z(Layer.blockUnder);
            Draw.color(Color.gray, 0.5f);
            Lines.stroke(1f);
            if (r.ghost && r.parent.column == r.column) {
                float px = r.parent.x * tilesize;
                Lines.dashLine(px, r.parent.cy() - 8, px, y, 6);
                Lines.dashLine(px, y, x - 8, y, 6);
            }
            if (r.ghost) {
                Draw.z(Layer.blockOver);
                Draw.color(color(r.status), 0.35f);
                Draw.rect(r.block.fullIcon, x, y);
            }
            if (r.status.equals("waiting")) {
                Draw.z(Layer.blockOver);
                Draw.color(Pal.accent);
                Lines.square(x, y, 10 + Mathf.absin(Time.time, 6f, 2f));
            }
            if (r.item != null && !r.ghost) {
                Draw.z(Layer.blockOver);
                Draw.color();
                Draw.rect(r.item.fullIcon, x + 5, y - 5, 5f, 5f);
            }
            Draw.z(Layer.playerName);
            text(r.text, right, y + 7, color(r.status), 0.26f, width);
            text(r.sub, right, y + 1, Color.lightGray, 0.2f, width);
            for (int n = 0; n < r.runs.size; n++) {
                String s = r.runs.get(n);
                Draw.color(s.equals("fine") ? Color.gray : color(s));
                float h = s.equals("bad") ? 4f : s.equals("running") ? 2.5f : 1f;
                Draw.rect(Core.atlas.white(), right + n * 2f + 0.5f, y - 7 + h / 2, 1.2f, h);
            }
            Draw.reset();
        }
    }

    /** Cut short with an ellipsis where it would be wider than width. */
    static void text(String s, float x, float y, Color c, float scale, float width) {
        Font f = Fonts.outline;
        boolean ints = f.usesIntegerPositions();
        f.setUseIntegerPositions(false);
        f.getData().setScale(scale / Scl.scl(1f));
        f.setColor(c);
        String e = escape(s);
        f.draw(e, x, y, 0, e.length(), width, Align.left, false, "…");
        f.getData().setScale(1f);
        f.setColor(Color.white);
        f.setUseIntegerPositions(ints);
    }

    static Color color(String status) {
        return switch (status) {
            case "bad" -> bad;
            case "waiting" -> Pal.accent;
            case "running" -> running;
            case "unseen" -> Color.gray;
            default -> Color.white;
        };
    }

    /** Text as it reads, not as colour markup. */
    static String escape(String s) {
        return s.replace("[", "[[");
    }

    // * What needs the user

    void refreshHud() {
        hud.clear();
        hud.defaults().left();
        if (!reachable) {
            hud.add("Can't reach the control-dashboard server at " + server + ".").color(bad);
            return;
        }
        if (!system.get("summary").getBool("connected", false)) hud.add("The server can't reach the broker.").color(bad).row();
        boolean any = false;
        for (Jval i : system.get("items").asArray()) {
            String topic = i.getString("topic");
            for (Jval p : i.get("problems").asArray()) {
                hud.button(escape(topic), Styles.cleart, () -> open(topic)).color(bad).left();
                hud.add(escape(p.asString())).color(bad).padLeft(8).row();
                any = true;
            }
            for (Jval s : i.get("sends").asArray()) {
                hud.button(escape(s.getString("label") + " from " + topic), Styles.cleart, () -> send(topic, s)).color(Pal.accent).left();
                hud.add("waiting to be sent").color(Pal.accent).padLeft(8).row();
                any = true;
            }
        }
        if (!any) hud.add("Nothing needs you.").color(Color.lightGray);
    }

    /** A topic's last runs, with what can be done about the latest. */
    void open(String topic) {
        Http.get(server + "/api/topic?topic=" + URLEncoder.encode(topic, StandardCharsets.UTF_8)).timeout(5000)
            .error(e -> Core.app.post(() -> ui.showErrorMessage("Couldn't get " + topic + ": " + e.getMessage())))
            .submit(res -> {
                Jval j = Jval.read(res.getResultAsString());
                Core.app.post(() -> show(topic, j));
            });
    }

    void show(String topic, Jval j) {
        BaseDialog d = new BaseDialog(escape(topic));
        Seq<Jval> runs = j.get("runs").asArray();
        d.cont.pane(p -> {
            p.defaults().left().width(900f);
            if (runs.isEmpty()) p.add("No runs.").color(Color.lightGray).row();
            boolean newest = true;
            for (Jval r : runs) {
                String took = r.get("took").isNull() ? "" : ", took " + r.getString("took");
                p.add(escape(r.getString("label")) + "  [lightgray]" + escape(r.getString("when") + took)).color(color(r.getString("status"))).padTop(newest ? 0 : 4).row();
                for (Jval pr : r.get("problems").asArray()) p.labelWrap(escape(pr.asString())).color(bad).padLeft(16).row();
                for (Jval s : r.get("sends").asArray())
                    p.button(escape("Send " + s.getString("label") + " → " + s.getString("to")), () -> { d.hide(); send(topic, s); }).padLeft(16).row();
                if (newest) {
                    for (Jval s : r.get("summary").asArray()) p.labelWrap(escape(s.asString())).padLeft(16).row();
                    said(p, "content", r.get("content"));
                    said(p, "result", r.get("result"));
                    if (!r.get("problems").asArray().isEmpty()) said(p, "log", j.get("log"));
                    for (Jval c : r.get("chain").asArray())
                        p.add(escape("  ".repeat(c.getInt("depth", 0)) + c.getString("topic") + "  ") + "[lightgray]" + escape(c.getString("when"))).color(color(c.getString("status"))).padLeft(16).row();
                }
                newest = false;
            }
        }).grow();
        Jval item = system == null ? null : system.get("items").asArray().find(i -> i.getString("topic").equals(topic));
        if (item != null && !item.get("dismiss").isNull()) d.buttons.button("Dismiss", () -> {
            d.hide();
            post("/api/dismiss", Jval.newObject().put("run", item.getString("dismiss")), "Dismissed " + topic);
        }).size(210f, 64f);
        d.addCloseButton();
        d.show();
    }

    static void said(Table p, String what, Jval v) {
        if (v == null || v.isNull()) return;
        p.add(what).color(Color.lightGray).padLeft(16).padTop(4).row();
        p.labelWrap(escape(v.asString())).padLeft(16).row();
    }

    void send(String topic, Jval s) {
        ui.showConfirm("Send", "Send “" + escape(s.getString("label")) + "” for " + escape(topic) + "?", () ->
            post("/api/send", Jval.newObject().put("run", s.getString("run")).put("index", s.getInt("index", 0)), "Sent " + s.getString("label")));
    }

    void post(String path, Jval body, String done) {
        Http.post(server + path, body.toString(Jval.Jformat.plain)).timeout(10000)
            .error(e -> Core.app.post(() -> ui.showErrorMessage(e instanceof Http.HttpStatusException h ? h.response.getResultAsString() : e.getMessage())))
            .submit(res -> Core.app.post(() -> { ui.showInfoToast(done, 3f); poll(); }));
    }
}
