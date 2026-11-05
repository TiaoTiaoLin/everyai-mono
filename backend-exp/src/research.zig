//! Research mode. The user's model leads (instructions in `modes.zig`): it
//! scopes the question, sends researchers with the `research` tool, and
//! writes the report. Each researcher is a small tool loop of its own
//! (web_search, web_fetch) on a model from the roster, run in parallel on its
//! own memory. They share the turn's source ledger behind a lock, so every
//! citation number is the same for the lead, the researchers and the app.
//!
//! The harness holds the lead to the steps: no report before anything was
//! gathered, research only in Research mode, rounds and spend capped by the
//! depth the user picked, citations checked against the ledger, and one nudge
//! when it stops without writing the report.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const billing = @import("billing.zig");
const chat = @import("chat.zig");
const openrouter = @import("openrouter.zig");
const safe_fetch = @import("net/safe_fetch.zig");
const tools = @import("tools.zig");

/// How far the user wants the research to go (the composer's depth picker).
pub const Depth = enum {
    quick,
    standard,
    deep,

    pub fn caps(self: Depth) Caps {
        return switch (self) {
            .quick => .{ .per_round = 2, .rounds = 1, .budget_usd = 0.15, .tier = 1, .steps = 4 },
            .standard => .{ .per_round = 4, .rounds = 2, .budget_usd = 0.60, .tier = 2, .steps = 6 },
            .deep => .{ .per_round = 6, .rounds = 3, .budget_usd = 2.50, .tier = 3, .steps = 8 },
        };
    }
};

pub const Caps = struct {
    /// Researchers per `research` call.
    per_round: usize,
    /// `research` calls per turn.
    rounds: usize,
    /// What the researchers may spend in a turn, upstream USD.
    budget_usd: f64,
    /// The highest roster tier allowed.
    tier: u8,
    /// Upstream calls per researcher.
    steps: usize,
};

pub const Member = struct { id: []const u8, tier: u8, strengths: []const u8 };

/// The models researchers run on. Tier 1 is open to every depth, 2 from
/// Standard, 3 only in Deep.
pub const roster = [_]Member{
    .{ .id = "google/gemini-3.5-flash-lite", .tier = 1, .strengths = "fast and cheap: quick facts, broad scans, many short pages" },
    .{ .id = "openai/gpt-5.4-mini", .tier = 2, .strengths = "numbers, prices, specifications and side-by-side comparisons" },
    .{ .id = "anthropic/claude-haiku-5.5", .tier = 2, .strengths = "careful reading of long or technical pages, papers and documentation" },
    .{ .id = "anthropic/claude-sonnet-5.5", .tier = 3, .strengths = "hard, contested or subtle questions that need judgment about sources" },
};

/// The roster as the lead reads it, after the Research block: constant, so cached.
pub const roster_block = blk: {
    var s: []const u8 = "<researchers>\nModels for the research tool and what each does best. Quick research may use tier 1, Standard tiers 1-2, Deep all three; the tool says what is left.\n";
    for (roster) |m| s = s ++ std.fmt.comptimePrint("- {s} (tier {d}): {s}\n", .{ m.id, m.tier, m.strengths });
    break :blk s ++ "</researchers>";
};

/// What a researcher is told. Our words; its report goes to the lead, not the user.
const researcher_prompt =
    \\You are a researcher on a team. The lead researcher gave you one question. Find the answer on the web and report back to the lead.
    \\- Search with web_search (2-4 specific queries), then read the 2-4 best pages with web_fetch. Prefer primary sources (official sites, papers, filings, datasets) and recent ones, and note each source's date.
    \\- Report only what the pages say. Every claim and number carries its source number, e.g. [4]. Use only numbers the tools gave you.
    \\- The lead reads your report, not the user, so skip any introduction. Write three parts: Findings (bullets, most important first, with the numbers, dates and names), Gaps and disagreements (what sources dispute, or what you could not find), and Best sources (the 2-3 most useful numbers and why).
    \\- Stay under 400 words. Stop searching once you can answer well.
    \\
++ safe_fetch.untrusted_rule;

/// One turn's research: what the lead did so far.
pub const State = struct {
    depth: Depth = .standard,
    rounds: usize = 0,
    spent_usd: f64 = 0,
    /// Researchers have reported this turn: the report may be written.
    gathered: bool = false,
    /// The report artifact exists (created this turn).
    reported: bool = false,
    /// The lead stopped once without writing the report and was told to.
    nudged: bool = false,
};

const Task = struct { question: []const u8, model: []const u8, focus: []const u8 };

/// The `research` tool: checks the call against the depth's caps and the
/// roster, runs the researchers in parallel, and returns their briefs.
/// `aux` is where the researchers' calls go (`App.aux`).
pub fn run(app: *App, req: *anole.Request, who: auth.Identity, session: ?[]const u8, call_id: []const u8, args: std.json.Value, sink: chat.Sink, state: *State, aux: App.Route) ![]const u8 {
    const arena = req.arena;
    const caps = state.depth.caps();
    if (state.rounds >= caps.rounds)
        return std.fmt.allocPrint(arena, "Not run: {s} research allows {d} round(s) of researchers and they are used. Write the report now with what the briefs found, and say what is still open.", .{ @tagName(state.depth), caps.rounds });
    if (state.spent_usd >= caps.budget_usd)
        return std.fmt.allocPrint(arena, "Not run: this research has spent its budget (${d:.2}). Write the report now with what the briefs found.", .{caps.budget_usd});

    const list = if (args == .object) (if (args.object.get("questions")) |q| (if (q == .array) q.array.items else &.{}) else &.{}) else &.{};
    if (list.len == 0) return "Error: give at least one question.";
    if (list.len > caps.per_round)
        return std.fmt.allocPrint(arena, "Not run: {s} research sends at most {d} researchers per round and you asked for {d}. Merge or drop questions and call research again.", .{ @tagName(state.depth), caps.per_round, list.len });
    var tasks = try arena.alloc(Task, list.len);
    for (list, 0..) |q, i| {
        const question = std.mem.trim(u8, openrouter.jsonString(q, "question") orelse "", " \t\r\n");
        if (question.len == 0) return std.fmt.allocPrint(arena, "Error: question {d} is empty.", .{i + 1});
        const model = openrouter.jsonString(q, "model") orelse roster[0].id;
        const member = for (roster) |m| {
            if (std.mem.eql(u8, m.id, model)) break m;
        } else return std.fmt.allocPrint(arena, "Error: \"{s}\" is not on the researcher roster. Use one of: {s}.", .{ model, try allowed(arena, caps.tier) });
        if (member.tier > caps.tier)
            return std.fmt.allocPrint(arena, "Not run: {s} is tier {d}, and {s} research allows up to tier {d}. Use one of: {s}.", .{ model, member.tier, @tagName(state.depth), caps.tier, try allowed(arena, caps.tier) });
        tasks[i] = .{ .question = question, .model = model, .focus = openrouter.jsonString(q, "focus") orelse "" };
    }
    // Researchers need credit even when the lead's model is free.
    billing.preflight(app, req, who.user_id, aux.byok) catch |err| switch (err) {
        error.PaymentRequired => return "Error: the user is out of credits, so researchers can't run. Answer from what you know and say so.",
        else => return err,
    };
    state.rounds += 1;

    var shared: Shared = .{ .sink = sink, .io = req.io };
    const briefs = try arena.alloc(Brief, tasks.len);
    const jobs = try arena.alloc(Job, tasks.len);
    var group: std.Io.Group = .init;
    // Tasks started before an error below must not outlive this frame.
    defer group.cancel(req.io);
    for (tasks, briefs, jobs, 0..) |t, *b, *j, i| {
        b.* = .{};
        j.* = .{
            .app = app,
            .req = req,
            .who = who,
            .session = session,
            .task = t,
            .steps = caps.steps,
            .status_id = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ call_id, i + 1 }),
            .shared = &shared,
            .out = b,
            .aux = aux,
        };
        try shared.status(j.status_id, "running", t);
        group.concurrent(req.io, Job.run, .{j}) catch group.async(req.io, Job.run, .{j});
    }
    group.await(req.io) catch {};

    var out: std.Io.Writer.Allocating = .init(arena);
    var spent: f64 = 0;
    for (briefs) |b| spent += b.cost_usd;
    state.spent_usd += spent;
    var any = false;
    for (tasks, briefs, 0..) |t, b, i| {
        try out.writer.print("<brief n=\"{d}\" model=\"{s}\">\nQuestion: {s}\n", .{ i + 1, t.model, t.question });
        if (b.failed) {
            try out.writer.print("The researcher failed: {s}\n</brief>\n", .{b.text});
            continue;
        }
        any = true;
        try out.writer.print("{s}\n</brief>\n", .{try safe_fetch.wrapUntrusted(arena, "researcher", b.text)});
    }
    if (any) state.gathered = true;
    const left = caps.rounds - state.rounds;
    try out.writer.print("\nRound {d} of {d} ({s} depth); researchers spent ${d:.3} of ${d:.2}. ", .{ state.rounds, caps.rounds, @tagName(state.depth), state.spent_usd, caps.budget_usd });
    if (left > 0 and state.spent_usd < caps.budget_usd)
        try out.writer.print("{d} round(s) left: call research again only for real gaps or conflicts; otherwise write the report now.", .{left})
    else
        try out.writer.writeAll("No rounds left: write the report now.");
    return out.written();
}

fn allowed(arena: std.mem.Allocator, tier: u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var first = true;
    for (roster) |m| if (m.tier <= tier) {
        if (!first) try out.writer.writeAll(", ");
        first = false;
        try out.writer.writeAll(m.id);
    };
    return out.written();
}

const Brief = struct {
    /// The report, or why it failed; in the turn's arena.
    text: []const u8 = "",
    failed: bool = false,
    cost_usd: f64 = 0,
};

/// What the researchers share with the turn: its event stream and source
/// ledger (one at a time) and its arena (only under the lock).
const Shared = struct {
    sink: chat.Sink,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    fn status(self: *Shared, id: []const u8, state: []const u8, t: Task) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const detail = try std.fmt.allocPrint(self.sink.arena, "{s} · {s}", .{ t.question, shortModel(t.model) });
        try self.sink.send("tool_status", .{ .id = id, .name = "researcher", .status = state, .detail = detail });
    }

    /// The text kept in the turn's arena, outliving the researcher's memory.
    fn keep(self: *Shared, text: []const u8) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.sink.arena.dupe(u8, text);
    }
};

/// "claude-haiku-5.5" from "anthropic/claude-haiku-5.5".
fn shortModel(id: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, id, '/')) |i| id[i + 1 ..] else id;
}

/// The turn's sink as web_search and web_fetch use it, safe to share between
/// researchers: every use takes the lock, and sources are copied into the
/// turn's arena before the ledger keeps them.
const LockedSink = struct {
    shared: *Shared,

    pub fn send(self: LockedSink, name: []const u8, value: anytype) !void {
        self.shared.mutex.lockUncancelable(self.shared.io);
        defer self.shared.mutex.unlock(self.shared.io);
        try self.shared.sink.send(name, value);
    }

    pub fn onDelta(self: LockedSink, d: openrouter.Delta) !void {
        self.shared.mutex.lockUncancelable(self.shared.io);
        defer self.shared.mutex.unlock(self.shared.io);
        switch (d) {
            .sources => |list| {
                const kept = try self.shared.sink.arena.alloc(openrouter.Source, list.len);
                for (list, kept) |s, *k| k.* = try dupeSource(self.shared.sink.arena, s);
                try self.shared.sink.onDelta(.{ .sources = kept });
            },
            else => try self.shared.sink.onDelta(d),
        }
    }

    pub fn cite(self: LockedSink, source: openrouter.Source) !usize {
        self.shared.mutex.lockUncancelable(self.shared.io);
        defer self.shared.mutex.unlock(self.shared.io);
        return self.shared.sink.cite(try dupeSource(self.shared.sink.arena, source));
    }

    pub fn number(self: LockedSink, source: openrouter.Source) !usize {
        self.shared.mutex.lockUncancelable(self.shared.io);
        defer self.shared.mutex.unlock(self.shared.io);
        return self.shared.sink.number(try dupeSource(self.shared.sink.arena, source));
    }
};

fn dupeSource(arena: std.mem.Allocator, s: openrouter.Source) !openrouter.Source {
    return .{
        .url = try arena.dupe(u8, s.url),
        .title = try arena.dupe(u8, s.title),
        .snippet = if (s.snippet) |sn| try arena.dupe(u8, sn) else null,
    };
}

/// One researcher: a tool loop with its own arena, passed as an
/// `anole.db.Ctx` (the request's arena is the handler's alone). Tasks stay
/// on the request's executor (pinned scheduling), so the turn's sink and
/// arena are touched only between waits; the lock keeps that explicit.
const Job = struct {
    app: *App,
    req: *anole.Request,
    who: auth.Identity,
    session: ?[]const u8,
    task: Task,
    steps: usize,
    status_id: []const u8,
    shared: *Shared,
    out: *Brief,
    aux: App.Route,

    fn run(self: *Job) void {
        var memory: std.heap.ArenaAllocator = .init(self.app.gpa);
        defer memory.deinit();
        const text = self.loop(memory.allocator()) catch |err| blk: {
            self.out.failed = true;
            break :blk @errorName(err);
        };
        self.out.text = self.shared.keep(text) catch "out of memory";
        if (self.out.text.len == 0) {
            self.out.failed = true;
            self.out.text = "it returned nothing";
        }
        self.shared.status(self.status_id, if (self.out.failed) "failed" else "done", self.task) catch {};
    }

    fn loop(self: *Job, a: std.mem.Allocator) ![]const u8 {
        var cx: anole.db.Ctx = .{ .io = self.req.io, .arena = a };
        const sink: LockedSink = .{ .shared = self.shared };
        const web_tools = try webTools(a);

        var messages: std.ArrayList([]const u8) = .empty;
        try messages.append(a, try std.json.Stringify.valueAlloc(a, .{ .role = "system", .content = researcher_prompt }, .{}));
        const ask = if (self.task.focus.len > 0)
            try std.fmt.allocPrint(a, "Question: {s}\nWhat to look for: {s}", .{ self.task.question, self.task.focus })
        else
            try std.fmt.allocPrint(a, "Question: {s}", .{self.task.question});
        try messages.append(a, try std.json.Stringify.valueAlloc(a, .{ .role = "user", .content = ask }, .{}));

        var step: usize = 0;
        while (true) : (step += 1) {
            if (self.shared.sink.ev.draining()) return error.ServerDraining;
            const last = step + 1 >= self.steps;
            const body = try std.mem.concat(a, u8, &.{
                "{\"model\":",                                          try std.json.Stringify.valueAlloc(a, self.task.model, .{}),
                ",\"usage\":{\"include\":true},\"max_tokens\":1800,\"tools\":", web_tools,
                if (last) ",\"tool_choice\":\"none\"" else "",           ",\"messages\":[",
                try std.mem.join(a, ",", messages.items),               "]}",
            });
            const reply = try self.call(&cx, a, body);
            const message = reply.message;
            const content = openrouter.jsonString(message, "content") orelse "";
            const calls = if (message == .object) (if (message.object.get("tool_calls")) |c| (if (c == .array) c.array.items else &.{}) else &.{}) else &.{};
            if (calls.len == 0 or last) {
                if (content.len > 0 or last) return content;
                return error.EmptyReply;
            }
            try messages.append(a, try std.json.Stringify.valueAlloc(a, .{ .role = "assistant", .content = content, .tool_calls = message.object.get("tool_calls").? }, .{}));
            for (calls) |c| {
                const id = openrouter.jsonString(c, "id") orelse "";
                const f = if (c == .object) c.object.get("function") orelse std.json.Value{ .null = {} } else std.json.Value{ .null = {} };
                const name = openrouter.jsonString(f, "name") orelse "";
                const raw_args = openrouter.jsonString(f, "arguments") orelse "{}";
                const args = std.json.parseFromSliceLeaky(std.json.Value, a, if (raw_args.len == 0) "{}" else raw_args, .{}) catch null;
                const output = if (args == null)
                    "Error: the arguments were not valid JSON."
                else if (std.mem.eql(u8, name, "web_search"))
                    chat.webSearch(self.app, &cx, self.who, self.session, args.?, sink, self.aux) catch |err| try std.fmt.allocPrint(a, "Error: {t}", .{err})
                else if (std.mem.eql(u8, name, "web_fetch"))
                    chat.webFetch(self.app, &cx, args.?, sink) catch |err| try std.fmt.allocPrint(a, "Error: {t}", .{err})
                else
                    "Error: researchers have web_search and web_fetch only.";
                try messages.append(a, try std.json.Stringify.valueAlloc(a, .{ .role = "tool", .tool_call_id = id, .content = output }, .{}));
            }
        }
    }

    /// One upstream call, metered under the chat; its message.
    fn call(self: *Job, cx: *anole.db.Ctx, a: std.mem.Allocator, body: []const u8) !struct { message: std.json.Value } {
        const s = try self.aux.up.post(cx.*, "/chat/completions", body, &.{});
        defer s.close();
        const raw = try s.reader.allocRemaining(a, .limited(4 * 1024 * 1024));
        if (s.status >= 300) {
            self.req.log().warn("researcher failed", .{ .model = self.task.model, .upstream = openrouter.errorMessage(a, raw) });
            return error.UpstreamFailed;
        }
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return error.BadReply;
        if (v != .object) return error.BadReply;
        if (v.object.get("usage")) |u| if (u == .object) {
            const usage = openrouter.parseUsage(u.object);
            self.out.cost_usd += usage.cost_usd;
            const c = try billing.charge(self.app, cx, self.who.user_id, .{ .kind = "research", .model = self.task.model, .prompt_tokens = usage.prompt_tokens, .completion_tokens = usage.completion_tokens, .cached_tokens = usage.cached_tokens, .cost_usd = usage.cost_usd, .session = self.session, .byok = self.aux.byok });
            const sink: LockedSink = .{ .shared = self.shared };
            try sink.send("usage", .{ .kind = "research", .model = self.task.model, .prompt_tokens = usage.prompt_tokens, .completion_tokens = usage.completion_tokens, .cached_tokens = usage.cached_tokens, .cache_write_tokens = usage.cache_write_tokens, .charged_micros = c.charged_micros, .byok_cost_micros = billing.ownKeyCost(c, self.aux.byok) });
        };
        const choices = v.object.get("choices") orelse return error.BadReply;
        if (choices != .array or choices.array.items.len == 0) return error.BadReply;
        return .{ .message = choices.array.items[0].object.get("message") orelse return error.BadReply };
    }
};

/// web_search and web_fetch out of the chat's tool list, as JSON.
fn webTools(a: std.mem.Allocator) ![]const u8 {
    const all = try std.json.parseFromSliceLeaky(std.json.Value, a, tools.definitions, .{});
    var kept: std.json.Array = .init(a);
    for (all.array.items) |t| {
        const name = openrouter.jsonString(t.object.get("function").?, "name") orelse continue;
        if (std.mem.eql(u8, name, "web_search") or std.mem.eql(u8, name, "web_fetch")) try kept.append(t);
    }
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .array = kept }, .{});
}

/// The citation numbers in `content` the ledger doesn't have (it holds
/// `known` sources); null when every one is known. "[3]", "[3][5]", "[3, 5]".
pub fn citationProblems(arena: std.mem.Allocator, content: []const u8, known: usize) !?[]const u8 {
    var bad: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, i, '[')) |open| {
        i = open + 1;
        const close = std.mem.indexOfScalarPos(u8, content, i, ']') orelse break;
        const inside = content[i..close];
        // A link's text "[2024 report](…)" is not a citation.
        if (close + 1 < content.len and content[close + 1] == '(') continue;
        var it = std.mem.tokenizeAny(u8, inside, ", ");
        var all_numbers = inside.len > 0;
        var nums: std.ArrayList(usize) = .empty;
        while (it.next()) |tok| {
            const n = std.fmt.parseInt(usize, tok, 10) catch {
                all_numbers = false;
                break;
            };
            try nums.append(arena, n);
        }
        if (!all_numbers) continue;
        for (nums.items) |n| if (n == 0 or n > known) {
            for (bad.items) |b| {
                if (b == n) break;
            } else try bad.append(arena, n);
        };
    }
    if (bad.items.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    for (bad.items, 0..) |n, k| try out.writer.print("{s}[{d}]", .{ if (k == 0) "" else ", ", n });
    return try std.fmt.allocPrint(arena, "Note: the report cites {s}, but this turn's sources only go up to [{d}]. Fix those citations with edit_artifact: cite only numbers from the briefs, or drop the claim.", .{ out.written(), known });
}

/// Said once when the lead stops after gathering without writing the report.
pub const report_nudge = "You gathered research but haven't written the report. Write it now as one markdown artifact with create_artifact (summary, cited sections, charts for compared numbers, what is uncertain, Sources), then the 3-5 line brief.";

/// Why `create_artifact` waits: nothing was gathered yet this turn.
pub const report_too_early = "Not yet: in Research mode the report comes after the researchers report. Call research with the sub-questions first (ask_user before that only if the scope is genuinely open), then write the report from the briefs.";

test "roster block names every model and tier" {
    for (roster) |m| try std.testing.expect(std.mem.indexOf(u8, roster_block, m.id) != null);
    try std.testing.expect(std.mem.indexOf(u8, roster_block, "(tier 3)") != null);
}

test "caps grow with depth" {
    try std.testing.expect(Depth.quick.caps().per_round < Depth.deep.caps().per_round);
    try std.testing.expectEqual(@as(u8, 1), Depth.quick.caps().tier);
}

test "citation problems: unknown numbers, not links or years" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try citationProblems(a, "Fine [1][2] and [2, 3]. See [the 2024 report](https://x.dev).", 3) == null);
    const p = (try citationProblems(a, "Bad [4] and [0], again [4]; ok [1]. [note] stays.", 3)).?;
    try std.testing.expect(std.mem.indexOf(u8, p, "[4], [0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "up to [3]") != null);
}
