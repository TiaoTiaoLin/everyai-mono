//! OpenAI-compatible `POST /v1/chat/completions` for OpenHands and other
//! agent harnesses: authenticated by a gateway key (`sk-eai-...`), forwarded
//! to OpenRouter, metered per user/key/session (`X-EveryAI-Session`).
//! Anthropic/Gemini requests get prompt-cache breakpoints when the caller
//! sent none: system prompt, tools, and the latest message.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const billing = @import("billing.zig");
const chat = @import("chat.zig");
const models = @import("models.zig");
const openrouter = @import("openrouter.zig");
const sse = anole.sse;
const truncation = @import("truncation.zig");
const safe_fetch = @import("net/safe_fetch.zig");
const web = @import("web.zig");

fn completions(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth.identity(req);
    // Passed through to the upstream with a few fields changed, so the
    // object as sent, not a typed copy.
    var root: std.json.Value = .{ .object = (req.jsonObject() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return res.fail(.bad_request, "body must be JSON"),
    }) orelse return res.fail(.bad_request, "body must be a JSON object") };
    const o = &root.object;

    // LiteLLM-style prefixes ("openai/anthropic/claude-...") are stripped to the OpenRouter id.
    var model = openrouter.jsonStr(o.get("model")) orelse return res.fail(.bad_request, "model is required");
    for ([_][]const u8{ "openai/", "openrouter/", "litellm_proxy/" }) |p| {
        if (std.mem.startsWith(u8, model, p) and std.mem.indexOfScalar(u8, model[p.len..], '/') != null) model = model[p.len..];
    }
    try o.put(req.arena, "model", .{ .string = model });

    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    const facts = app.catalog.facts(req.io, model);
    // The newest user message carries what is being attached now; earlier
    // attachments (from before a model switch) become text notes instead.
    if (o.get("messages")) |msgs| if (msgs == .array) {
        const items = msgs.array.items;
        var newest: ?usize = null;
        for (items, 0..) |m, i| if (m == .object) if (openrouter.jsonStr(m.object.get("role"))) |r| if (std.mem.eql(u8, r, "user")) {
            newest = i;
        };
        for (items, 0..) |*m, i| {
            if (m.* != .object) continue;
            const content = m.object.getPtr("content") orelse continue;
            if (newest != null and i == newest.?) {
                if (models.unsupportedPart(facts.inputs, content.*)) |what| {
                    res.status = .bad_request;
                    return res.json(.{ .@"error" = .{ .message = try models.unsupportedMessage(req.arena, model, what), .type = "invalid_request_error", .code = "unsupported_modality" } });
                }
            } else content.* = try models.dropUnsupported(req.arena, facts.inputs, content.*);
        }
    };
    // The user's own key (byok.zig) pays for the call instead.
    const route = try app.routeFor(req, model, true);
    if (app.keyless(route.byok, model, true)) {
        res.status = .unauthorized;
        return res.json(.{ .@"error" = .{ .message = openrouter.no_key_message, .type = "authentication_error", .code = "no_api_key" } });
    }
    billing.preflight(app, req, who.user_id, facts.free or route.byok) catch {
        res.status = .payment_required;
        return res.json(.{ .@"error" = .{ .message = "Out of EveryAI credits", .type = "insufficient_quota", .code = "out_of_credits" } });
    };

    // Metering needs the usage block.
    try o.put(req.arena, "usage", try jsonObject(req.arena, &.{.{ "include", .{ .bool = true } }}));
    if (chat.wantsBreakpoints(model)) try addBreakpoints(req.arena, o, app.cfg.gateway_cache_ttl);
    try applyEffort(req.arena, o, req.headers.get("X-EveryAI-Effort"));
    const streaming = if (o.get("stream")) |s| s == .bool and s.bool else false;
    // A whole non-streamed completion (an agent writing a file) can take
    // minutes; a stream's deadline ends once its head is out.
    if (!streaming) req.setTimeout(.fromSeconds(600));
    const body = try std.json.Stringify.valueAlloc(req.arena, root, .{});
    const session = req.headers.get("X-EveryAI-Session");

    const up = try route.up.post(openrouter.ctxOf(req), "/chat/completions", body, &.{});
    var call: Call = .{ .app = app, .req = req, .who = who, .session = session, .model = model, .route = route, .o = o, .max_output = facts.max_output };

    if (up.status >= 300) {
        defer up.close();
        const reply = try up.reader.allocRemaining(req.arena, .limited(64 * 1024 * 1024));
        res.status = @fromBackingInt(@intCast(up.status));
        // Harnesses back off by it (overloaded, rate-limited).
        if (up.retry_after) |v| try res.header("Retry-After", v);
        res.content_type = .json;
        res.body = reply;
        return;
    }
    if (!streaming) {
        res.status = .ok;
        res.content_type = .json;
        res.body = try call.whole(up);
        return;
    }
    var buf: [16 * 1024]u8 = undefined;
    try res.header("Content-Type", "text/event-stream");
    try res.header("Cache-Control", "no-cache");
    var out = try res.stream(&buf);
    try call.streamed(up, &out.interface);
    try out.end();
}

/// One gateway request and its recovery from cut-off replies (see
/// truncation.zig): a cut-off tool call is asked for again once with a bigger
/// output cap, cut-off text is continued with a nudge, and a call still cut
/// off is made unparseable so the harness reports it instead of running it.
const Call = struct {
    app: *App,
    req: *anole.Request,
    who: auth.Identity,
    session: ?[]const u8,
    model: []const u8,
    route: App.Route,
    /// The request body; the output cap is raised in place.
    o: *std.json.ObjectMap,
    max_output: i64,
    boosted: bool = false,
    continuations: u8 = 0,
    /// Text of the replies continued so far.
    text: std.ArrayList(u8) = .empty,

    const Next = enum { done, boost, continue_text };

    /// What to do after a reply that finished with `finish` (`used` output tokens).
    fn next(self: *Call, finish: []const u8, has_tools: bool, text: []const u8, used: i64) !Next {
        if (!truncation.isLength(finish)) return .done;
        // Another attempt runs the plugins again (a web search is billed per
        // run), and their callers cap the output on purpose.
        if (self.o.get("plugins") != null) return .done;
        const arena = self.req.arena;
        if (has_tools) {
            if (self.boosted) return .done;
            const cap = truncation.boostedCap(capOf(self.o.*, used), self.max_output) orelse return .done;
            self.boosted = true;
            try self.o.put(arena, "max_tokens", .{ .integer = cap });
            if (self.o.get("max_completion_tokens") != null) try self.o.put(arena, "max_completion_tokens", .{ .integer = cap });
            return .boost;
        }
        if (text.len == 0 or self.continuations >= truncation.max_continuations) return .done;
        self.continuations += 1;
        return .continue_text;
    }

    /// The body for the next attempt: the request, plus the text so far and
    /// a nudge when continuing.
    fn body(self: *Call) ![]const u8 {
        const arena = self.req.arena;
        if (self.text.items.len == 0) return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = self.o.* }, .{});
        var o = try self.o.clone(arena);
        var msgs: std.json.Array = .init(arena);
        if (o.get("messages")) |m| if (m == .array) try msgs.appendSlice(m.array.items);
        try msgs.append(try jsonObject(arena, &.{ .{ "role", .{ .string = "assistant" } }, .{ "content", .{ .string = self.text.items } } }));
        try msgs.append(try jsonObject(arena, &.{ .{ "role", .{ .string = "user" } }, .{ "content", .{ .string = truncation.continue_nudge } } }));
        try o.put(arena, "messages", .{ .array = msgs });
        return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = o }, .{});
    }

    /// The next attempt, or null when it failed (the caller keeps the last
    /// reply). `text` is the reply being continued.
    fn retry(self: *Call, step: Next, text: []const u8) !?openrouter.Stream {
        const kept = self.text.items.len;
        if (step == .continue_text) try self.text.appendSlice(self.req.arena, text);
        const up = self.route.up.post(openrouter.ctxOf(self.req), "/chat/completions", try self.body(), &.{}) catch |err| {
            self.req.log().warn("gateway retry failed", .{ .err = @errorName(err) });
            self.text.shrinkRetainingCapacity(kept);
            return null;
        };
        if (up.status < 300) return up;
        self.req.log().warn("gateway retry failed", .{ .status = up.status });
        up.close();
        self.text.shrinkRetainingCapacity(kept);
        return null;
    }

    fn meter(self: *Call, u: openrouter.Usage) !void {
        try meterUsage(self.app, self.req, self.who, self.session, self.model, self.route, u);
    }

    /// Non-streamed: the final reply's JSON.
    fn whole(self: *Call, first: openrouter.Stream) ![]const u8 {
        const arena = self.req.arena;
        var up = first;
        while (true) {
            const reply = blk: {
                defer up.close();
                break :blk try up.reader.allocRemaining(arena, .limited(64 * 1024 * 1024));
            };
            var v = std.json.parseFromSliceLeaky(std.json.Value, arena, reply, .{}) catch return reply;
            if (v != .object) return reply;
            var used: i64 = 0;
            if (v.object.get("usage")) |u| if (u == .object) {
                const usage = openrouter.parseUsage(u.object);
                used = usage.completion_tokens;
                try self.meter(usage);
            };
            const choice = firstChoice(v) orelse return reply;
            const msg = choice.getPtr("message") orelse return reply;
            if (msg.* != .object) return reply;
            const finish = openrouter.jsonStr(choice.get("finish_reason")) orelse "";
            const calls = if (msg.object.get("tool_calls")) |t| (if (t == .array) t.array.items else &.{}) else &.{};
            const text = openrouter.jsonStr(msg.object.get("content")) orelse "";

            const step = try self.next(finish, calls.len > 0, text, used);
            if (step != .done) if (try self.retry(step, text)) |again| {
                up = again;
                continue;
            };
            // Final: the text before it, and a cut-off call made unparseable.
            if (self.text.items.len > 0) try msg.object.put(arena, "content", .{ .string = try std.mem.concat(arena, u8, &.{ self.text.items, text }) });
            if (truncation.isLength(finish) and calls.len > 0) try markCut(arena, @constCast(&calls[calls.len - 1]));
            if (self.text.items.len == 0 and !(truncation.isLength(finish) and calls.len > 0)) return reply;
            return std.json.Stringify.valueAlloc(arena, v, .{});
        }
    }

    /// Streamed: text goes through as it arrives; tool calls, the finish
    /// chunk and usage are held until the reply is known not to need a retry.
    fn streamed(self: *Call, first: openrouter.Stream, out: *std.Io.Writer) !void {
        const arena = self.req.arena;
        var up = first;
        var forward_text = true;
        while (true) {
            var held: Held = .{};
            const current = up;
            defer current.close();
            try held.read(arena, self.req.io, up.reader, out, forward_text, keepalive_every);
            if (held.usage) |u| try self.meter(u);

            const step = try self.next(held.finish, held.tools, held.text.items, if (held.usage) |u| u.completion_tokens else 0);
            if (step != .done) if (try self.retry(step, held.text.items)) |again| {
                // Text held in finish chunks still goes to the client.
                if (forward_text) for (held.chunks.items) |c| if (c.text.len > 0) try writeData(out, try held.textChunk(arena, c.text));
                up = again;
                // A retried call repeats text the client already has.
                forward_text = step == .continue_text;
                continue;
            };
            for (held.chunks.items, 0..) |c, i| {
                if (held.finish_at == i and truncation.isLength(held.finish) and held.tools)
                    try writeData(out, try held.markChunk(arena));
                try writeData(out, c.raw);
            }
            try writeData(out, "[DONE]");
            return;
        }
    }
};

/// How long a stream may go without sending anything while chunks are held
/// back (a long tool call): idle clients and proxies time out well before
/// a big file is generated.
const keepalive_every: std.Io.Duration = .fromSeconds(15);

/// One streamed attempt's held-back chunks.
const Held = struct {
    chunks: std.ArrayList(struct { raw: []const u8, text: []const u8 }) = .empty,
    finish_at: ?usize = null,
    finish: []const u8 = "",
    tools: bool = false,
    last_tool: i64 = 0,
    text: std.ArrayList(u8) = .empty,
    usage: ?openrouter.Usage = null,
    id: []const u8 = "",
    model: []const u8 = "",
    /// What each held tool call has streamed so far, for progress notes.
    progress: std.ArrayList(ToolProgress) = .empty,

    /// Reads one attempt, forwarding text when `forward_text` and holding
    /// the rest. While holding, an SSE comment goes out every `beat_every`.
    fn read(self: *Held, arena: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader, out: *std.Io.Writer, forward_text: bool, beat_every: std.Io.Duration) !void {
        const Ts = std.Io.Clock.Timestamp;
        var last_sent = Ts.now(io, .awake);
        var last_progress = last_sent;
        var parser = sse.Parser.init(arena, reader, .{});
        defer parser.deinit();
        var scratch: std.heap.ArenaAllocator = .init(arena);
        defer scratch.deinit();
        while (try parser.next()) |ev| {
            if (std.mem.eql(u8, ev.data, "[DONE]")) break;
            _ = scratch.reset(.retain_capacity);
            const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), ev.data, .{}) catch {
                try writeData(out, ev.data);
                continue;
            };
            if (v != .object or v.object.get("error") != null) {
                try writeData(out, ev.data);
                continue;
            }
            if (self.id.len == 0) if (openrouter.jsonStr(v.object.get("id"))) |id| {
                self.id = try arena.dupe(u8, id);
            };
            if (self.model.len == 0) if (openrouter.jsonStr(v.object.get("model"))) |m| {
                self.model = try arena.dupe(u8, m);
            };
            var hold = false;
            if (v.object.get("usage")) |u| if (u == .object) {
                var usage = openrouter.parseUsage(u.object);
                usage.served_model = try arena.dupe(u8, usage.served_model);
                self.usage = usage;
                hold = true;
            };
            var text: []const u8 = "";
            if (firstChoice(v)) |choice| {
                if (openrouter.jsonStr(choice.get("finish_reason"))) |f| {
                    self.finish = try arena.dupe(u8, f);
                    self.finish_at = self.chunks.items.len;
                    hold = true;
                }
                if (choice.get("delta")) |d| if (d == .object) {
                    text = openrouter.jsonStr(d.object.get("content")) orelse "";
                    if (d.object.get("tool_calls")) |tc| if (tc == .array and tc.array.items.len > 0) {
                        self.tools = true;
                        hold = true;
                        for (tc.array.items) |c| if (c == .object) {
                            self.last_tool = @max(self.last_tool, openrouter.jsonInt(c.object.get("index")));
                            try self.track(arena, c.object);
                        };
                    };
                };
            } else hold = true;
            try self.text.appendSlice(arena, text);
            if (hold) {
                try self.chunks.append(arena, .{ .raw = try arena.dupe(u8, ev.data), .text = try arena.dupe(u8, text) });
                const now = Ts.now(io, .awake);
                // While a tool call is held, a progress note a few times a second (an SSE
                // comment: clients that don't know it ignore it) shows what is being written.
                if (self.progress.items.len > 0 and now.compare(.gte, last_progress.addDuration(.{ .raw = progress_every, .clock = .awake }))) {
                    try out.writeAll(": progress ");
                    try out.writeAll(try self.progressJson(arena));
                    try out.writeAll("\n\n");
                    try out.flush();
                    last_progress = now;
                    last_sent = now;
                } else if (now.compare(.gte, last_sent.addDuration(.{ .raw = beat_every, .clock = .awake }))) {
                    try out.writeAll(": keepalive\n\n");
                    try out.flush();
                    last_sent = now;
                }
            } else if (forward_text) {
                try writeData(out, ev.data);
                last_sent = Ts.now(io, .awake);
            }
        }
    }

    fn track(self: *Held, arena: std.mem.Allocator, call: std.json.ObjectMap) !void {
        const index: usize = @intCast(@max(0, openrouter.jsonInt(call.get("index"))));
        while (self.progress.items.len <= index) try self.progress.append(arena, .{});
        const p = &self.progress.items[index];
        const f = call.get("function") orelse return;
        if (f != .object) return;
        if (openrouter.jsonStr(f.object.get("name"))) |n| try p.name.appendSlice(arena, n);
        const args = openrouter.jsonStr(f.object.get("arguments")) orelse return;
        p.chars += args.len;
        // The arguments are JSON text, so a newline in a file's content is the two characters \n.
        p.lines += std.mem.count(u8, args, "\\n");
        if (p.head.items.len < 2048) try p.head.appendSlice(arena, args[0..@min(args.len, 2048 - p.head.items.len)]);
    }

    fn progressJson(self: *const Held, arena: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(struct { index: usize, name: []const u8, chars: usize, lines: usize, path: []const u8 }) = .empty;
        for (self.progress.items, 0..) |p, i| {
            if (p.name.items.len == 0 and p.chars == 0) continue;
            try list.append(arena, .{ .index = i, .name = p.name.items, .chars = p.chars, .lines = p.lines, .path = pathIn(p.head.items) });
        }
        return std.json.Stringify.valueAlloc(arena, list.items, .{});
    }

    fn textChunk(self: *const Held, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        return chunkJson(arena, self.id, self.model, .{ .content = text });
    }

    /// Appends `cut_marker` to the last tool call's arguments.
    fn markChunk(self: *const Held, arena: std.mem.Allocator) ![]const u8 {
        return chunkJson(arena, self.id, self.model, .{ .tool_calls = .{.{ .index = self.last_tool, .function = .{ .arguments = truncation.cut_marker } }} });
    }
};

const progress_every: std.Io.Duration = .fromMilliseconds(400);

const ToolProgress = struct {
    name: std.ArrayList(u8) = .empty,
    chars: usize = 0,
    lines: usize = 0,
    /// The start of the arguments, where the file path is.
    head: std.ArrayList(u8) = .empty,
};

/// The file a tool call's (partial) arguments name, or "".
fn pathIn(head: []const u8) []const u8 {
    for ([_][]const u8{ "\"file_path\"", "\"path\"" }) |key| {
        const at = std.mem.indexOf(u8, head, key) orelse continue;
        var i = at + key.len;
        while (i < head.len and (head[i] == ' ' or head[i] == ':')) i += 1;
        if (i >= head.len or head[i] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, head, i + 1, '"') orelse continue;
        return head[i + 1 .. end];
    }
    return "";
}

fn chunkJson(arena: std.mem.Allocator, id: []const u8, model: []const u8, delta: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .id = id,
        .object = "chat.completion.chunk",
        .model = model,
        .choices = .{.{ .index = 0, .delta = delta, .finish_reason = @as(?[]const u8, null) }},
    }, .{});
}

fn writeData(out: *std.Io.Writer, data: []const u8) !void {
    try out.writeAll("data: ");
    try out.writeAll(data);
    try out.writeAll("\n\n");
    try out.flush();
}

fn firstChoice(v: std.json.Value) ?*std.json.ObjectMap {
    if (v != .object) return null;
    const choices = v.object.getPtr("choices") orelse return null;
    if (choices.* != .array or choices.array.items.len == 0) return null;
    const c = &choices.array.items[0];
    return if (c.* == .object) &c.object else null;
}

/// The cap the request set, else the output the cut-off reply used.
fn capOf(o: std.json.ObjectMap, used: i64) i64 {
    const a = openrouter.jsonInt(o.get("max_completion_tokens"));
    if (a > 0) return a;
    const b = openrouter.jsonInt(o.get("max_tokens"));
    return if (b > 0) b else used;
}

/// Makes a tool call's arguments unparseable (see `truncation.cut_marker`).
fn markCut(arena: std.mem.Allocator, call: *std.json.Value) !void {
    if (call.* != .object) return;
    const f = call.object.getPtr("function") orelse return;
    if (f.* != .object) return;
    const args = openrouter.jsonStr(f.object.get("arguments")) orelse "";
    try f.object.put(arena, "arguments", .{ .string = try std.mem.concat(arena, u8, &.{ args, truncation.cut_marker }) });
}

/// Records a gateway call under the model that served it; server-side web
/// searches go in as their own "search" event.
fn meterUsage(app: *App, req: *anole.Request, who: auth.Identity, session: ?[]const u8, model: []const u8, route: App.Route, u: openrouter.Usage) !void {
    _ = try billing.charge(app, req, who.user_id, .{
        .kind = "gateway",
        .model = u.billedModel(model),
        .prompt_tokens = u.prompt_tokens,
        .completion_tokens = u.completion_tokens,
        .cached_tokens = u.cached_tokens,
        .cache_write_tokens = u.cache_write_tokens,
        .cost_usd = u.tokenCost(),
        .session = session,
        .api_key_id = who.key_id,
        .provider = route.provider,
        .byok = route.byok,
    });
    if (u.search_cost_usd > 0) _ = try billing.charge(app, req, who.user_id, .{
        .kind = "search",
        .model = u.billedModel(model),
        .cost_usd = u.search_cost_usd,
        .session = session,
        .api_key_id = who.key_id,
        .provider = route.provider,
        .byok = route.byok,
    });
}

/// LiteLLM drops `reasoning_effort` for models it doesn't know, so the app
/// sends the effort as `X-EveryAI-Effort`. It becomes OpenRouter's
/// `reasoning.effort` (the Anthropic adapter reads it too) unless the body
/// already sets one.
pub fn applyEffort(arena: std.mem.Allocator, o: *std.json.ObjectMap, header: ?[]const u8) !void {
    const effort = header orelse return;
    if (o.get("reasoning_effort") != null or o.get("reasoning") != null) return;
    for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }) |ok| {
        if (std.mem.eql(u8, effort, ok)) {
            try o.put(arena, "reasoning", try jsonObject(arena, &.{.{ "effort", .{ .string = ok } }}));
            return;
        }
    }
}

fn jsonObject(arena: std.mem.Allocator, fields: []const struct { []const u8, std.json.Value }) !std.json.Value {
    var m: std.json.ObjectMap = .empty;
    for (fields) |f| try m.put(arena, f[0], f[1]);
    return .{ .object = m };
}

fn cacheControl(arena: std.mem.Allocator, ttl: []const u8) !std.json.Value {
    if (std.mem.eql(u8, ttl, "1h")) return jsonObject(arena, &.{ .{ "type", .{ .string = "ephemeral" } }, .{ "ttl", .{ .string = "1h" } } });
    return jsonObject(arena, &.{.{ "type", .{ .string = "ephemeral" } }});
}

/// Breakpoints on: the last tool definition (tools + system prefix), the
/// system message, and the last message. Marks the client set are kept
/// (LiteLLM marks only the system message, so the growing conversation
/// needs ours too); the oldest message marks go beyond the provider's four.
/// Decided on the request's structure: text that merely mentions
/// `cache_control` (a project's docs in the system prompt) changes nothing.
pub fn addBreakpoints(arena: std.mem.Allocator, o: *std.json.ObjectMap, ttl: []const u8) !void {
    if (o.get("tools")) |t| if (t == .array and t.array.items.len > 0) {
        const last = &t.array.items[t.array.items.len - 1];
        if (last.* == .object and !last.object.contains("cache_control")) try last.object.put(arena, "cache_control", try cacheControl(arena, ttl));
    };
    const msgs = (o.get("messages") orelse return);
    if (msgs != .array or msgs.array.items.len == 0) return;
    const items = msgs.array.items;
    for (items) |*m| {
        if (m.* == .object and std.mem.eql(u8, openrouter.jsonStr(m.object.get("role")) orelse "", "system")) {
            if (!hasMark(m.*)) try markLastPart(arena, m, ttl);
            break;
        }
    }
    if (!hasMark(items[items.len - 1])) try markLastPart(arena, &items[items.len - 1], ttl);
    capBreakpoints(o);
}

const max_breakpoints = 4;

/// Whether a message carries a breakpoint (on itself or one of its parts).
fn hasMark(msg: std.json.Value) bool {
    if (msg != .object) return false;
    if (msg.object.contains("cache_control")) return true;
    const content = msg.object.get("content") orelse return false;
    if (content != .array) return false;
    for (content.array.items) |p| if (p == .object and p.object.contains("cache_control")) return true;
    return false;
}

/// Drops the oldest message breakpoints until at most four remain in all.
fn capBreakpoints(o: *std.json.ObjectMap) void {
    var total: usize = 0;
    if (o.get("tools")) |t| if (t == .array) {
        for (t.array.items) |b| if (b == .object and b.object.contains("cache_control")) {
            total += 1;
        };
    };
    const msgs = o.getPtr("messages") orelse return;
    if (msgs.* != .array) return;
    for (msgs.array.items) |m| total += countMarks(m);
    if (total <= max_breakpoints) return;
    var drop = total - max_breakpoints;
    for (msgs.array.items) |*m| {
        if (drop == 0) return;
        // The system message's mark covers the stable prefix: kept.
        if (m.* != .object or std.mem.eql(u8, openrouter.jsonStr(m.object.get("role")) orelse "", "system")) continue;
        if (m.object.swapRemove("cache_control")) drop -= 1;
        if (m.object.getPtr("content")) |c| if (c.* == .array) for (c.array.items) |*p| {
            if (drop == 0) break;
            if (p.* == .object and p.object.swapRemove("cache_control")) drop -= 1;
        };
    }
}

fn countMarks(msg: std.json.Value) usize {
    if (msg != .object) return 0;
    var n: usize = if (msg.object.contains("cache_control")) 1 else 0;
    if (msg.object.get("content")) |c| if (c == .array) for (c.array.items) |p| {
        if (p == .object and p.object.contains("cache_control")) n += 1;
    };
    return n;
}

/// Turns string content into a one-part array and marks its last text part.
fn markLastPart(arena: std.mem.Allocator, msg: *std.json.Value, ttl: []const u8) !void {
    if (msg.* != .object) return;
    const content = msg.object.getPtr("content") orelse return;
    switch (content.*) {
        .string => |s| {
            if (s.len == 0) return;
            var parts: std.json.Array = .init(arena);
            try parts.append(try jsonObject(arena, &.{ .{ "type", .{ .string = "text" } }, .{ "text", .{ .string = s } }, .{ "cache_control", try cacheControl(arena, ttl) } }));
            content.* = .{ .array = parts };
        },
        .array => |*parts| {
            var i = parts.items.len;
            while (i > 0) {
                i -= 1;
                const p = &parts.items[i];
                if (p.* == .object and std.mem.eql(u8, openrouter.jsonStr(p.object.get("type")) orelse "", "text")) {
                    try p.object.put(arena, "cache_control", try cacheControl(arena, ttl));
                    return;
                }
            }
        },
        else => {},
    }
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    const v1 = app.group("/v1", .{auth.Authenticate{ .app = state, .keys = true }});
    v1.post("/chat/completions", completions);
    v1.post("/fetch", fetch);
}

/// `POST /v1/fetch` for agent harnesses: a page through `safe_fetch` (no
/// local or private addresses, every redirect hop checked again, the body
/// capped), optionally only from the hosts in `allow` (research jobs), as
/// one window of readable text fenced as untrusted.
/// Body: `{"url", "allow"?: [host], "offset"?, "max_chars"?}`. A look-alike
/// of an official site is a 422 naming the real one; a host with a reason for
/// doubt fills `notice`, one line for the caller to show outside the fence.
const FetchBody = struct {
    url: []const u8,
    /// When given, the only hosts the fetch may reach, every redirect included
    /// (a research job's sites; see `safe_fetch.hostAllowed`).
    allow: ?[]const []const u8 = null,
    offset: i64 = 0,
    max_chars: ?i64 = null,

    pub const field_rules = .{
        .url = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxLength(8192) },
        .allow = .{anole.validate.maxItems(64)},
        .offset = .{anole.validate.min(0)},
        .max_chars = .{anole.validate.min(1)},
    };
};

fn fetch(app: *App, req: *anole.Request, res: *anole.Response) !void {
    // Up to five redirects, each with its own fetch budget.
    req.setTimeout(.fromSeconds(150));
    _ = try auth.identity(req);
    const fetcher = app.web orelse return res.fail(.service_unavailable, "fetching is not available here");
    const body = try req.bind(FetchBody);
    const url = body.url;
    const allow = body.allow;
    const offset: usize = @intCast(body.offset);
    const limit: usize = @intCast(std.math.clamp(body.max_chars orelse web.default_chars, web.min_chars, web.max_chars));
    var diag: safe_fetch.Diagnostics = .{};
    const page = fetcher.getAllowed(req.io, req.arena, url, "text/html,text/plain,application/xhtml+xml,application/json,*/*;q=0.5", allow, &diag) catch |err| {
        res.status = .unprocessable_entity;
        return res.json(.{ .@"error" = try safe_fetch.reason(req.arena, err, diag) });
    };
    if (page.status >= 400) {
        res.status = .unprocessable_entity;
        return res.json(.{ .@"error" = try std.fmt.allocPrint(req.arena, "HTTP {d}", .{page.status}) });
    }
    const html = std.mem.indexOf(u8, page.content_type, "html") != null;
    if (!html and !chat.textual(page.content_type)) {
        res.status = .unprocessable_entity;
        return res.json(.{ .@"error" = try std.fmt.allocPrint(req.arena, "not a text page ({s})", .{page.content_type}) });
    }
    // Source files and plain text keep their angle brackets.
    const text = if (html) try chat.readableText(req.arena, page.body, page.body.len) else page.body;
    const w = web.window(text, offset, limit);
    return res.json(.{
        .url = page.url,
        .status = page.status,
        .text = try safe_fetch.wrapUntrusted(req.arena, page.url, w.text),
        .notice = page.notice,
        .total_chars = w.total,
        .next_offset = if (w.end < w.total) @as(?usize, w.end) else null,
    });
}

test addBreakpoints {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"model":"anthropic/claude-sonnet-5.5","tools":[{"type":"function","function":{"name":"x"}}],
        \\ "messages":[{"role":"system","content":"sys"},{"role":"user","content":"hi"},{"role":"assistant","content":"yo"},{"role":"user","content":[{"type":"text","text":"more"}]}]}
    , .{});
    try addBreakpoints(a, &v.object, "1h");
    const out = try std.json.Stringify.valueAlloc(a, v, .{});
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "cache_control"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\"ttl\":\"1h\""));
}

test "breakpoints come from the request's structure, not text that mentions cache_control" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A project's docs in the system prompt mention cache_control: still marked.
    var docs = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"messages":[{"role":"system","content":"The gateway adds cache_control itself."},{"role":"user","content":"hi"}]}
    , .{});
    try addBreakpoints(a, &docs.object, "5m");
    var out = try std.json.Stringify.valueAlloc(a, docs, .{});
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\"cache_control\""));

    // LiteLLM marked only the system message: the last message gets one too.
    var litellm = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"messages":[{"role":"system","content":[{"type":"text","text":"sys","cache_control":{"type":"ephemeral"}}]},
        \\ {"role":"user","content":"a"},{"role":"assistant","content":"b"},{"role":"tool","tool_call_id":"t","content":"c"}]}
    , .{});
    try addBreakpoints(a, &litellm.object, "5m");
    out = try std.json.Stringify.valueAlloc(a, litellm, .{});
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\"cache_control\""));
    try std.testing.expect(hasMark(litellm.object.get("messages").?.array.items[3]));

    // Never more than four: the oldest message marks go first.
    var many = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"tools":[{"type":"function","function":{"name":"x"}}],"messages":[{"role":"system","content":"s"},
        \\ {"role":"user","content":[{"type":"text","text":"1","cache_control":{"type":"ephemeral"}}]},
        \\ {"role":"user","content":[{"type":"text","text":"2","cache_control":{"type":"ephemeral"}}]},
        \\ {"role":"user","content":"3"}]}
    , .{});
    try addBreakpoints(a, &many.object, "5m");
    const msgs = many.object.get("messages").?.array.items;
    try std.testing.expect(!hasMark(msgs[1]));
    try std.testing.expect(hasMark(msgs[0]) and hasMark(msgs[2]) and hasMark(msgs[3]));
}

test "held tool calls send progress notes with the file and its lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const up =
        \\data: {"id":"r","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"t","function":{"name":"write","arguments":"{\"file_path\": \"os.js\", \"content\": \"a\\nb"}}]}}]}
        \\
        \\data: {"id":"r","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\nc\"}"}}]}}]}
        \\
        \\data: [DONE]
        \\
        \\
    ;
    var reader: std.Io.Reader = .fixed(up);
    var out: std.Io.Writer.Allocating = .init(a);
    var held: Held = .{};
    try held.read(a, std.testing.io, &reader, &out.writer, true, .fromSeconds(60));
    try std.testing.expectEqualStrings("os.js", pathIn(held.progress.items[0].head.items));
    try std.testing.expectEqual(@as(usize, 2), held.progress.items[0].lines);
    const json = try held.progressJson(a);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"write\"") != null);
}

test "held tool-call chunks keep the stream alive with comments, then go out whole" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const up =
        \\data: {"id":"r","model":"m","choices":[{"index":0,"delta":{"content":"hi"}}]}
        \\
        \\data: {"id":"r","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a"}}]}}]}
        \\
        \\data: {"id":"r","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\":1}"}}]}}]}
        \\
        \\data: [DONE]
        \\
        \\
    ;
    var reader: std.Io.Reader = .fixed(up);
    var out: std.Io.Writer.Allocating = .init(a);
    var held: Held = .{};
    try held.read(a, std.testing.io, &reader, &out.writer, true, .fromMilliseconds(0));
    const sent = out.written();
    // The text went through; the tool call is held, with a keepalive per held chunk.
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"content\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "tool_calls") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, sent, ": keepalive\n\n"));
    try std.testing.expectEqual(@as(usize, 2), held.chunks.items.len);
    try std.testing.expect(held.tools);

    // With a long interval nothing extra is sent.
    var reader2: std.Io.Reader = .fixed(up);
    var out2: std.Io.Writer.Allocating = .init(a);
    var held2: Held = .{};
    try held2.read(a, std.testing.io, &reader2, &out2.writer, true, .fromSeconds(60));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out2.written(), "keepalive"));
}

test "the effort header fills in reasoning.effort when the body has none" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"model\":\"m\"}", .{});
    try applyEffort(a, &v.object, "medium");
    try std.testing.expectEqualStrings("medium", v.object.get("reasoning").?.object.get("effort").?.string);

    var kept = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"reasoning_effort\":\"low\"}", .{});
    try applyEffort(a, &kept.object, "high");
    try std.testing.expect(kept.object.get("reasoning") == null);

    var bogus = try std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{});
    try applyEffort(a, &bogus.object, "turbo");
    try std.testing.expect(bogus.object.get("reasoning") == null);
}
