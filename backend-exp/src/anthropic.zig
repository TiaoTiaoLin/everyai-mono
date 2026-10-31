//! Anthropic's Messages API behind the OpenAI chat-completions shape the rest
//! of the backend speaks. `Adapter` is an `openrouter.Upstream`: it translates
//! the request, posts it to `/messages` through an inner transport (the real
//! API, or a fake in tests), and translates the reply (SSE or JSON) back into
//! OpenAI chunks. Anthropic reports tokens but no cost, so the usage chunk's
//! `cost` is computed from the catalog's prices; `complete()`, the gateway and
//! billing then work unchanged.
//!
//! The usage is priced as the model the reply says served it (a server-side
//! fallback may differ), named in `usage.served_model`; `usage.by_kind`
//! splits the cost into tokens and server-tool fees (web search) so callers
//! bill those as their own kind. A `pause_turn` stop (a long server-tool turn)
//! is continued by re-sending the partial reply, up to `max_continues` times.
//! Server tool definitions pass through; their calls stay upstream and their
//! results come out as `url_citation` annotations.
//!
//! Thinking comes out as `reasoning` text plus OpenRouter-style
//! `reasoning_details` (signed `reasoning.text`, `reasoning.encrypted` for
//! redacted blocks). Details on an assistant message go back in as thinking
//! blocks, so a tool loop keeps its reasoning; messages without them (earlier
//! turns, other callers) still work, as the 5.5 models accept that.
const std = @import("std");
const anole = @import("anole");
const openrouter = @import("openrouter.zig");
const models = @import("models.zig");
const sse = anole.sse;
const util = @import("util.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const jsonStr = openrouter.jsonStr;
const jsonInt = openrouter.jsonInt;

/// The `format` of reasoning details this adapter makes and takes back.
const details_format = "anthropic-claude-v1";

/// Lets a request say what to do with a replayed thinking block whose
/// earlier conversation changed (see `translateRequest`).
const thinking_binding_beta = "thinking-binding-controls-2026-08-01";
const fallback_beta = "server-side-fallback-2026-07-01";

pub const Adapter = struct {
    /// Posts raw Messages API requests (`openrouter.Client` with `.auth = .anthropic`).
    inner: openrouter.Upstream,
    catalog: *models.Catalog,

    pub fn upstream(self: *Adapter) openrouter.Upstream {
        return .{ .ptr = self, .vtable = &.{ .post = post, .get = get } };
    }

    /// The catalog always comes from OpenRouter.
    fn get(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
        return error.Unsupported;
    }

    fn post(ptr: *anyopaque, cx: openrouter.Ctx, path: []const u8, body: []const u8, extra: []const [2][]const u8) anyerror!openrouter.Stream {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, path, "/chat/completions")) return error.Unsupported;
        const arena = cx.arena;
        const in = try std.json.parseFromSliceLeaky(Value, arena, body, .{});
        if (in != .object) return error.BadRequest;
        const t = try translateRequest(arena, in.object);

        var headers: std.ArrayList([2][]const u8) = .empty;
        try headers.appendSlice(arena, extra);
        try headers.append(arena, .{ "anthropic-beta", if (t.fallbacks) thinking_binding_beta ++ "," ++ fallback_beta else thinking_binding_beta });
        const up = try self.inner.post(cx, "/messages", t.body, headers.items);

        const prices = self.catalog.pricesOf(cx.io, t.model);
        if (prices == null) std.log.warn("no catalog prices for {s}; the call is billed as free", .{t.model});
        var meta: Meta = .{
            .model = t.model,
            .api_id = try anthropicId(arena, t.model),
            .prices = prices,
            .created = util.now(cx.io),
            .resolver = .{ .ctx = self, .io = cx.io, .lookupFn = lookup },
        };

        if (up.status >= 300) {
            defer up.close();
            const raw = up.reader.allocRemaining(arena, .limited(64 * 1024)) catch "";
            // 529 (overloaded) is Anthropic-only; clients know 503. The body
            // keeps `code: 529` and the upstream's Retry-After goes along.
            const status: u16 = if (up.status == 529) 503 else up.status;
            var out = try fixed(arena, status, try translateError(arena, raw, up.status));
            out.retry_after = up.retry_after;
            return out;
        }
        const cont: Cont = .{ .inner = self.inner, .cx = cx, .body = t.body, .headers = headers.items };
        if (!t.stream) return fixed(arena, 200, try self.whole(arena, up, cont, &meta));
        const tr = try arena.create(Translator);
        tr.init(arena, up, meta);
        tr.cont = cont;
        return .{ .status = 200, .reader = &tr.reader, .ctx = tr, .closeFn = Translator.close };
    }

    /// A non-streamed reply; a `pause_turn` (a long server-tool turn) is
    /// continued by sending the partial reply back, and the parts are joined.
    fn whole(_: *Adapter, arena: std.mem.Allocator, first: openrouter.Stream, cont: Cont, meta: *Meta) ![]const u8 {
        var up = first;
        var body = cont.body;
        var bill: Bill = .{};
        var content: std.json.Array = .init(arena);
        var id: []const u8 = "";
        var stop: []const u8 = "end_turn";
        var round: usize = 0;
        while (true) : (round += 1) {
            const raw = blk: {
                defer up.close();
                break :blk try up.reader.allocRemaining(arena, .limited(64 << 20));
            };
            const v = try std.json.parseFromSliceLeaky(Value, arena, raw, .{});
            if (v != .object) return error.BadGateway;
            const o = v.object;
            if (id.len == 0) id = jsonStr(o.get("id")) orelse "";
            try meta.serve(arena, jsonStr(o.get("model")) orelse "");
            if (o.get("usage")) |u| if (u == .object) bill.current.merge(u.object);
            const part = if (o.get("content")) |c| (if (c == .array) c.array.items else &.{}) else &.{};
            try content.appendSlice(part);
            stop = jsonStr(o.get("stop_reason")) orelse "end_turn";
            if (!std.mem.eql(u8, stop, "pause_turn") or round >= max_continues) break;

            const next_body = try continueBody(arena, body, part);
            const next = cont.inner.post(cont.cx, "/messages", next_body, cont.headers) catch |err| {
                std.log.warn("anthropic pause_turn continuation failed: {t}", .{err});
                break;
            };
            if (next.status >= 300) {
                std.log.warn("anthropic pause_turn continuation failed: HTTP {d}", .{next.status});
                next.close();
                break;
            }
            bill.rollover(meta.prices);
            body = next_body;
            up = next;
        }
        if (std.mem.eql(u8, stop, "pause_turn")) stop = "end_turn";
        return translateMessage(arena, id, content.items, stop, bill, meta.*);
    }

    /// The catalog entry for the model Anthropic says served the call.
    fn lookup(ctx: *anyopaque, io: std.Io, arena: std.mem.Allocator, api_id: []const u8) ?Priced {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        const c = self.catalog;
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        for (c.models, c.prices) |m, p| if (std.mem.startsWith(u8, m.id, "anthropic/") and sameModel(m.id, api_id)) {
            return .{ .model = arena.dupe(u8, m.id) catch return null, .prices = p };
        };
        return null;
    }
};

/// Most `pause_turn` continuations of one reply.
const max_continues = 5;

/// What re-posting a paused turn needs.
const Cont = struct {
    inner: openrouter.Upstream,
    cx: openrouter.Ctx,
    /// The Messages request that was last sent.
    body: []const u8,
    headers: []const [2][]const u8,
};

/// The request again with the partial assistant reply at the end (merged into
/// a trailing assistant message), which is how Anthropic resumes a paused turn.
fn continueBody(arena: std.mem.Allocator, body: []const u8, blocks: []const Value) ![]const u8 {
    var v = try std.json.parseFromSliceLeaky(Value, arena, body, .{});
    if (v != .object) return error.BadRequest;
    const msgs = v.object.getPtr("messages") orelse return error.BadRequest;
    if (msgs.* != .array) return error.BadRequest;
    const items = msgs.array.items;
    if (items.len > 0 and items[items.len - 1] == .object and
        std.mem.eql(u8, jsonStr(items[items.len - 1].object.get("role")) orelse "", "assistant"))
    {
        const last = items[items.len - 1].object.getPtr("content") orelse return error.BadRequest;
        if (last.* == .string) {
            var arr: std.json.Array = .init(arena);
            try arr.append(try textBlock(arena, last.string));
            last.* = .{ .array = arr };
        }
        if (last.* != .array) return error.BadRequest;
        try last.array.appendSlice(blocks);
    } else {
        var arr: std.json.Array = .init(arena);
        try arr.appendSlice(blocks);
        try msgs.array.append(try obj(arena, &.{ .{ "role", str("assistant") }, .{ "content", .{ .array = arr } } }));
    }
    return std.json.Stringify.valueAlloc(arena, v, .{});
}

/// "anthropic/claude-opus-5.5" names the model "claude-opus-5-5".
fn sameModel(or_id: []const u8, api_id: []const u8) bool {
    var id = or_id;
    if (std.mem.indexOfScalar(u8, id, '/')) |i| id = id[i + 1 ..];
    // Variants (":thinking") price the same model differently; skip them.
    if (std.mem.indexOfScalar(u8, id, ':') != null) return false;
    if (id.len != api_id.len) return false;
    for (id, api_id) |a, b| if (a != b and !(a == '.' and b == '-')) return false;
    return true;
}

const Fixed = struct { reader: std.Io.Reader };

fn fixed(arena: std.mem.Allocator, status: u16, bytes: []const u8) !openrouter.Stream {
    const f = try arena.create(Fixed);
    f.reader = .fixed(bytes);
    return .{ .status = status, .reader = &f.reader, .ctx = f, .closeFn = noClose };
}

fn noClose(_: *anyopaque) void {}

// ------------------------------------------------------------------ request

pub const Translated = struct {
    body: []const u8,
    /// The OpenRouter id the caller used (prices, and echoed in replies).
    model: []const u8,
    stream: bool,
    fallbacks: bool,
};

/// "anthropic/claude-haiku-5.5" -> "claude-haiku-5-5".
pub fn anthropicId(arena: std.mem.Allocator, model: []const u8) ![]const u8 {
    var id = model;
    if (std.mem.indexOfScalar(u8, id, '/')) |i| id = id[i + 1 ..];
    if (std.mem.indexOfScalar(u8, id, ':')) |i| id = id[0..i];
    const out = try arena.dupe(u8, id);
    std.mem.replaceScalar(u8, out, '.', '-');
    return out;
}

/// Most cache breakpoints one request may carry.
const max_breakpoints = 4;

pub fn translateRequest(arena: std.mem.Allocator, in: ObjectMap) !Translated {
    const model = jsonStr(in.get("model")) orelse return error.BadRequest;
    const id = try anthropicId(arena, model);
    var out: ObjectMap = .empty;
    try out.put(arena, "model", .{ .string = id });

    const max = jsonInt(in.get("max_completion_tokens"));
    const max2 = jsonInt(in.get("max_tokens"));
    try out.put(arena, "max_tokens", .{ .integer = if (max > 0) max else if (max2 > 0) max2 else 32000 });

    const stream = if (in.get("stream")) |s| s == .bool and s.bool else false;
    if (stream) try out.put(arena, "stream", .{ .bool = true });

    // Summarized thinking streams as `reasoning`. A signed thinking block is
    // bound to the exact conversation before it; callers edit history (the
    // Code harness clears old tool output, compacts, prunes images, seeds
    // forks), which used to fail the whole call with "Invalid signature in
    // thinking block". drop_block makes Anthropic drop such a block instead.
    try out.put(arena, "thinking", try obj(arena, &.{
        .{ "type", str("adaptive") },
        .{ "display", str("summarized") },
        .{ "block_binding", try obj(arena, &.{.{ "prefix_mismatch_behavior", str("drop_block") }}) },
    }));
    const effort = jsonStr(in.get("reasoning_effort")) orelse
        (if (in.get("reasoning")) |r| (if (r == .object) jsonStr(r.object.get("effort")) else null) else null);
    if (effort) |e| for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }) |ok| {
        if (std.mem.eql(u8, e, ok)) {
            try out.put(arena, "output_config", try obj(arena, &.{.{ "effort", str(ok) }}));
            break;
        }
    };

    // Refusal fallbacks (recommended on the models that have them).
    const fallbacks = std.mem.indexOf(u8, id, "opus-5-5") != null or std.mem.indexOf(u8, id, "sonnet-5-5") != null;
    if (fallbacks) try out.put(arena, "fallbacks", str("default"));

    if (in.get("stop")) |s| {
        var list: std.json.Array = .init(arena);
        switch (s) {
            .string => |x| if (std.mem.trim(u8, x, " \n\t").len > 0) try list.append(str(x)),
            .array => |a| for (a.items) |x| if (x == .string and std.mem.trim(u8, x.string, " \n\t").len > 0) try list.append(x),
            else => {},
        }
        if (list.items.len > 0) try out.put(arena, "stop_sequences", .{ .array = list });
    }

    // Tools.
    var marks: std.ArrayList(*ObjectMap) = .empty;
    var fixed_marks: usize = 0;
    var has_tools = false;
    if (in.get("tools")) |tv| if (tv == .array and tv.array.items.len > 0) {
        var tools: std.json.Array = .init(arena);
        for (tv.array.items) |t| {
            if (t != .object) continue;
            // Anthropic's web search and fetch tools go as they are; other
            // server tools (code execution, ...) carry fees we don't meter, so
            // they are dropped like any other non-function tool.
            if (isServerTool(t.object)) {
                try tools.append(t);
                continue;
            }
            const f = (t.object.get("function") orelse continue);
            if (f != .object) continue;
            var tool: ObjectMap = .empty;
            try tool.put(arena, "name", f.object.get("name") orelse continue);
            if (f.object.get("description")) |d| if (d == .string) try tool.put(arena, "description", d);
            try tool.put(arena, "input_schema", f.object.get("parameters") orelse try obj(arena, &.{ .{ "type", str("object") }, .{ "properties", try obj(arena, &.{}) } }));
            if (t.object.get("cache_control") orelse f.object.get("cache_control")) |cc| try tool.put(arena, "cache_control", cc);
            try tools.append(.{ .object = tool });
        }
        if (tools.items.len > 0) {
            has_tools = true;
            try out.put(arena, "tools", .{ .array = tools });
        }
    };
    if (has_tools) {
        const none = if (in.get("tool_choice")) |c| (c == .string and std.mem.eql(u8, c.string, "none")) else false;
        // Forced choices ("required", a named tool) are rejected with thinking on.
        try out.put(arena, "tool_choice", try obj(arena, &.{.{ "type", str(if (none) "none" else "auto") }}));
    }

    // Messages: system ones hoisted; tool results grouped into user turns.
    var system: std.json.Array = .init(arena);
    var msgs: std.ArrayList(Msg) = .empty;
    const list = in.get("messages") orelse return error.BadRequest;
    if (list != .array) return error.BadRequest;
    for (list.array.items) |m| {
        if (m != .object) continue;
        const role = jsonStr(m.object.get("role")) orelse continue;
        const content = m.object.get("content");
        if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "developer")) {
            try blocksOf(arena, content, &system);
        } else if (std.mem.eql(u8, role, "assistant")) {
            var blocks: std.json.Array = .init(arena);
            try thinkingOf(arena, m.object.get("reasoning_details"), &blocks);
            try blocksOf(arena, content, &blocks);
            if (m.object.get("tool_calls")) |tc| if (tc == .array) for (tc.array.items) |call| {
                if (call != .object) continue;
                const f = call.object.get("function") orelse continue;
                if (f != .object) continue;
                const args = jsonStr(f.object.get("arguments")) orelse "{}";
                const input = std.json.parseFromSliceLeaky(Value, arena, if (args.len == 0) "{}" else args, .{}) catch try obj(arena, &.{});
                try blocks.append(try obj(arena, &.{
                    .{ "type", str("tool_use") },
                    .{ "id", call.object.get("id") orelse str("") },
                    .{ "name", f.object.get("name") orelse str("") },
                    .{ "input", if (input == .object) input else try obj(arena, &.{}) },
                }));
            };
            try appendMsg(arena, &msgs, "assistant", blocks);
        } else if (std.mem.eql(u8, role, "tool")) {
            var inner: std.json.Array = .init(arena);
            try blocksOf(arena, content, &inner);
            var result: ObjectMap = .empty;
            try result.put(arena, "type", str("tool_result"));
            try result.put(arena, "tool_use_id", m.object.get("tool_call_id") orelse str(""));
            // A breakpoint inside the result moves onto the result block.
            for (inner.items) |*b| if (b.object.fetchSwapRemove("cache_control")) |kv| try result.put(arena, "cache_control", kv.value);
            if (inner.items.len == 0) {
                try result.put(arena, "content", str("(no output)"));
            } else {
                try result.put(arena, "content", .{ .array = inner });
            }
            var blocks: std.json.Array = .init(arena);
            try blocks.append(.{ .object = result });
            try appendMsg(arena, &msgs, "user", blocks);
        } else {
            var blocks: std.json.Array = .init(arena);
            try blocksOf(arena, content, &blocks);
            try appendMsg(arena, &msgs, "user", blocks);
        }
    }
    if (msgs.items.len == 0 or !std.mem.eql(u8, msgs.items[0].role, "user")) {
        var blocks: std.json.Array = .init(arena);
        try blocks.append(try textBlock(arena, "(continue)"));
        try msgs.insert(arena, 0, .{ .role = "user", .blocks = blocks });
    }

    // Keep at most four breakpoints: tools and system first, then the latest messages.
    if (out.getPtr("tools")) |t| for (t.array.items) |*b| if (b.object.contains("cache_control")) try marks.append(arena, &b.object);
    for (system.items) |*b| if (b.object.contains("cache_control")) try marks.append(arena, &b.object);
    fixed_marks = marks.items.len;
    for (msgs.items) |*msg| for (msg.blocks.items) |*b| if (b.object.contains("cache_control")) try marks.append(arena, &b.object);
    var drop = if (marks.items.len > max_breakpoints) marks.items.len - max_breakpoints else 0;
    var i: usize = fixed_marks;
    while (drop > 0 and i < marks.items.len) : (i += 1) {
        _ = marks.items[i].swapRemove("cache_control");
        drop -= 1;
    }
    i = 0;
    while (drop > 0) : (i += 1) {
        _ = marks.items[i].swapRemove("cache_control");
        drop -= 1;
    }

    if (system.items.len > 0) try out.put(arena, "system", .{ .array = system });
    var out_msgs: std.json.Array = .init(arena);
    for (msgs.items) |msg| try out_msgs.append(try obj(arena, &.{ .{ "role", str(msg.role) }, .{ "content", .{ .array = msg.blocks } } }));
    try out.put(arena, "messages", .{ .array = out_msgs });

    return .{
        .body = try std.json.Stringify.valueAlloc(arena, Value{ .object = out }, .{}),
        .model = model,
        .stream = stream,
        .fallbacks = fallbacks,
    };
}

/// A server tool definition we pass through (`{"type":"web_search_20250305",
/// "name":…}`). Only the ones whose cost is metered: searches are billed per
/// request (`Bill`), fetched pages arrive as input tokens.
fn isServerTool(t: ObjectMap) bool {
    if (t.contains("function")) return false;
    const kind = jsonStr(t.get("type")) orelse return false;
    for ([_][]const u8{ "web_search_", "web_fetch_" }) |p| if (std.mem.startsWith(u8, kind, p)) return true;
    return false;
}

const Msg = struct { role: []const u8, blocks: std.json.Array };

/// Consecutive same-role turns merge (Anthropic wants them alternating). An
/// empty turn is dropped.
fn appendMsg(arena: std.mem.Allocator, msgs: *std.ArrayList(Msg), role: []const u8, blocks: std.json.Array) !void {
    if (blocks.items.len == 0) return;
    if (msgs.items.len > 0) {
        const last = &msgs.items[msgs.items.len - 1];
        if (std.mem.eql(u8, last.role, role)) return last.blocks.appendSlice(blocks.items);
    }
    try msgs.append(arena, .{ .role = role, .blocks = blocks });
}

/// Signed reasoning details as thinking blocks (they lead the assistant
/// message). Unsigned text and other providers' formats are dropped: Anthropic
/// rejects thinking it can't verify.
fn thinkingOf(arena: std.mem.Allocator, details: ?Value, out: *std.json.Array) !void {
    const list = details orelse return;
    if (list != .array) return;
    for (list.array.items) |d| {
        if (d != .object) continue;
        if (jsonStr(d.object.get("format"))) |f| if (!std.mem.startsWith(u8, f, "anthropic")) continue;
        const kind = jsonStr(d.object.get("type")) orelse continue;
        if (std.mem.eql(u8, kind, "reasoning.text")) {
            const sig = jsonStr(d.object.get("signature")) orelse continue;
            if (sig.len == 0) continue;
            try out.append(try obj(arena, &.{ .{ "type", str("thinking") }, .{ "thinking", str(jsonStr(d.object.get("text")) orelse "") }, .{ "signature", str(sig) } }));
        } else if (std.mem.eql(u8, kind, "reasoning.encrypted")) {
            const data = jsonStr(d.object.get("data")) orelse continue;
            try out.append(try obj(arena, &.{ .{ "type", str("redacted_thinking") }, .{ "data", str(data) } }));
        }
    }
}

/// OpenAI content (a string or parts) as Anthropic blocks. Empty text is
/// skipped (Anthropic rejects it); `cache_control` is kept.
fn blocksOf(arena: std.mem.Allocator, content: ?Value, out: *std.json.Array) !void {
    const c = content orelse return;
    switch (c) {
        .string => |s| if (s.len > 0) try out.append(try textBlock(arena, s)),
        .array => |parts| for (parts.items) |p| {
            if (p != .object) continue;
            const kind = jsonStr(p.object.get("type")) orelse continue;
            var block: Value = undefined;
            if (std.mem.eql(u8, kind, "text")) {
                const t = jsonStr(p.object.get("text")) orelse continue;
                if (t.len == 0) continue;
                block = try textBlock(arena, t);
            } else if (std.mem.eql(u8, kind, "image_url")) {
                const iu = p.object.get("image_url") orelse continue;
                const url = (if (iu == .object) jsonStr(iu.object.get("url")) else jsonStr(iu)) orelse continue;
                block = if (parseDataUrl(url)) |d|
                    try obj(arena, &.{ .{ "type", str("image") }, .{ "source", try obj(arena, &.{ .{ "type", str("base64") }, .{ "media_type", str(d.mime) }, .{ "data", str(d.data) } }) } })
                else
                    try obj(arena, &.{ .{ "type", str("image") }, .{ "source", try obj(arena, &.{ .{ "type", str("url") }, .{ "url", str(url) } }) } });
            } else if (std.mem.eql(u8, kind, "file")) {
                const f = p.object.get("file") orelse continue;
                if (f != .object) continue;
                const name = jsonStr(f.object.get("filename")) orelse "file";
                const d = parseDataUrl(jsonStr(f.object.get("file_data")) orelse "") orelse continue;
                block = if (std.mem.eql(u8, d.mime, "application/pdf"))
                    try obj(arena, &.{ .{ "type", str("document") }, .{ "title", str(name) }, .{ "source", try obj(arena, &.{ .{ "type", str("base64") }, .{ "media_type", str(d.mime) }, .{ "data", str(d.data) } }) } })
                else
                    try textBlock(arena, try std.fmt.allocPrint(arena, "[{s} ({s}) can't be read by this model]", .{ name, d.mime }));
            } else if (std.mem.eql(u8, kind, "input_audio")) {
                block = try textBlock(arena, "[An audio clip was attached; this model can't listen to audio]");
            } else continue;
            if (p.object.get("cache_control")) |cc| try block.object.put(arena, "cache_control", cc);
            try out.append(block);
        },
        else => {},
    }
}

const DataUrl = struct { mime: []const u8, data: []const u8 };

/// "data:image/png;base64,AAAA" -> {image/png, AAAA}.
fn parseDataUrl(url: []const u8) ?DataUrl {
    if (!std.mem.startsWith(u8, url, "data:")) return null;
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return null;
    const head = url[5..comma];
    if (!std.mem.endsWith(u8, head, ";base64")) return null;
    return .{ .mime = head[0 .. head.len - ";base64".len], .data = url[comma + 1 ..] };
}

fn str(s: []const u8) Value {
    return .{ .string = s };
}

fn obj(arena: std.mem.Allocator, fields: []const struct { []const u8, Value }) !Value {
    var m: ObjectMap = .empty;
    for (fields) |f| try m.put(arena, f[0], f[1]);
    return .{ .object = m };
}

fn textBlock(arena: std.mem.Allocator, text: []const u8) !Value {
    return obj(arena, &.{ .{ "type", str("text") }, .{ "text", str(text) } });
}

// ------------------------------------------------------------------ response

/// A catalog model and its prices.
pub const Priced = struct { model: []const u8, prices: ?models.Prices };

/// Finds the catalog entry for an Anthropic API id (the served model).
pub const Resolver = struct {
    ctx: *anyopaque,
    io: std.Io,
    lookupFn: *const fn (ctx: *anyopaque, io: std.Io, arena: std.mem.Allocator, api_id: []const u8) ?Priced,
};

const Meta = struct {
    /// The OpenRouter id the caller asked for (echoed in chunks).
    model: []const u8,
    /// Its Anthropic API id.
    api_id: []const u8 = "",
    /// Prices of the model that served the call (the asked one until a
    /// reply names another, as server-side fallbacks may).
    prices: ?models.Prices,
    created: i64,
    /// The OpenRouter id of the model that served, when not `model`.
    served: []const u8 = "",
    resolver: ?Resolver = null,

    /// Notes the model a reply came from; a fallback is priced as itself.
    fn serve(self: *Meta, arena: std.mem.Allocator, api_id: []const u8) !void {
        if (api_id.len == 0 or self.api_id.len == 0 or std.mem.eql(u8, api_id, self.api_id)) return;
        if (self.served.len > 0 and sameModel(self.served, api_id)) return;
        const found = if (self.resolver) |r| r.lookupFn(r.ctx, r.io, arena, api_id) else null;
        if (found) |f| {
            self.served = f.model;
            if (f.prices) |p| self.prices = p;
        } else {
            self.served = try std.fmt.allocPrint(arena, "anthropic/{s}", .{api_id});
            std.log.warn("{s} served {s}, which has no catalog prices; billed at {s}'s", .{ self.model, api_id, self.model });
        }
    }

    fn servedModel(self: Meta) []const u8 {
        return if (self.served.len > 0) self.served else self.model;
    }
};

/// What web search costs per request (Anthropic: $10 per 1,000).
const web_search_usd = 0.01;

/// One Messages call's usage.
const Usage = struct {
    input: i64 = 0,
    cache_read: i64 = 0,
    cache_creation: i64 = 0,
    cache_5m: i64 = 0,
    cache_1h: i64 = 0,
    output: i64 = 0,
    searches: i64 = 0,
    fetches: i64 = 0,

    fn merge(self: *Usage, u: ObjectMap) void {
        if (u.get("input_tokens")) |v| self.input = jsonInt(v);
        if (u.get("output_tokens")) |v| self.output = jsonInt(v);
        if (u.get("cache_read_input_tokens")) |v| self.cache_read = jsonInt(v);
        if (u.get("cache_creation_input_tokens")) |v| self.cache_creation = jsonInt(v);
        if (u.get("cache_creation")) |c| if (c == .object) {
            self.cache_5m = jsonInt(c.object.get("ephemeral_5m_input_tokens"));
            self.cache_1h = jsonInt(c.object.get("ephemeral_1h_input_tokens"));
        };
        if (u.get("server_tool_use")) |s| if (s == .object) {
            self.searches = jsonInt(s.object.get("web_search_requests"));
            self.fetches = jsonInt(s.object.get("web_fetch_requests"));
        };
    }

    fn add(self: *Usage, o: Usage) void {
        inline for (@typeInfo(Usage).@"struct".field_names) |n| @field(self, n) += @field(o, n);
    }

    /// Token cost only (server-tool fees are billed by kind; see `Bill`).
    fn cost(self: Usage, prices: ?models.Prices) f64 {
        const p = prices orelse return 0;
        // No TTL breakdown: price every write as a 5-minute one.
        const split = self.cache_5m + self.cache_1h == self.cache_creation;
        return p.cost(.{
            .input = self.input,
            .cache_read = self.cache_read,
            .cache_write_5m = if (split) self.cache_5m else self.cache_creation,
            .cache_write_1h = if (split) self.cache_1h else 0,
            .output = self.output,
        });
    }
};

/// A reply's usage across the calls of a paused-and-continued turn.
const Bill = struct {
    current: Usage = .{},
    /// Earlier calls, summed, and their token cost (each at its own prices).
    earlier: Usage = .{},
    earlier_cost: f64 = 0,

    /// Closes the current call before a continuation.
    fn rollover(self: *Bill, prices: ?models.Prices) void {
        self.earlier_cost += self.current.cost(prices);
        self.earlier.add(self.current);
        self.current = .{};
    }

    /// The OpenAI/OpenRouter usage object (`prompt_tokens` includes cached),
    /// plus what this adapter adds: `served_model` (the model priced) and
    /// `by_kind`, the cost split by kind ("tokens", "search") so callers can
    /// record server-tool fees as their own usage events. `cost` is the total.
    fn write(self: Bill, s: *std.json.Stringify, prices: ?models.Prices, served_model: []const u8) !void {
        var u = self.earlier;
        u.add(self.current);
        const prompt = u.input + u.cache_read + u.cache_creation;
        const tokens = self.earlier_cost + self.current.cost(prices);
        const search: f64 = @as(f64, @floatFromInt(u.searches)) * web_search_usd;
        try s.beginObject();
        try s.objectField("prompt_tokens");
        try s.write(prompt);
        try s.objectField("completion_tokens");
        try s.write(u.output);
        try s.objectField("total_tokens");
        try s.write(prompt + u.output);
        try s.objectField("cost");
        try s.write(tokens + search);
        try s.objectField("prompt_tokens_details");
        try s.write(.{ .cached_tokens = u.cache_read, .cache_write_tokens = u.cache_creation });
        try s.objectField("served_model");
        try s.write(served_model);
        if (u.searches + u.fetches > 0) {
            try s.objectField("server_tool_use");
            try s.write(.{ .web_search_requests = u.searches, .web_fetch_requests = u.fetches });
        }
        try s.objectField("by_kind");
        try s.beginArray();
        try s.write(.{ .kind = "tokens", .cost = tokens });
        if (u.searches > 0) try s.write(.{ .kind = "search", .requests = u.searches, .cost = search });
        try s.endArray();
        try s.endObject();
    }
};

fn finishReason(stop: []const u8) []const u8 {
    const map = [_][2][]const u8{
        .{ "tool_use", "tool_calls" },
        .{ "max_tokens", "length" },
        .{ "model_context_window_exceeded", "length" },
        .{ "refusal", "content_filter" },
    };
    for (map) |m| if (std.mem.eql(u8, stop, m[0])) return m[1];
    return "stop";
}

/// Anthropic SSE in, OpenAI `chat.completion.chunk` SSE out, as a reader.
/// A `pause_turn` stop (a long server-tool turn) is continued in place: the
/// partial reply goes back as the request's last assistant message and the
/// next stream carries on, with one id, one finish chunk and summed usage.
const Translator = struct {
    reader: std.Io.Reader,
    buffer: [16 * 1024]u8,
    up: openrouter.Stream,
    parser: sse.Parser,
    arena: std.mem.Allocator,
    scratch: std.heap.ArenaAllocator,
    out: std.Io.Writer.Allocating,
    pos: usize = 0,
    meta: Meta,
    id: []const u8 = "",
    started: bool = false,
    /// Anthropic block index -> OpenAI tool_calls index (-1: not a tool).
    tool_of: std.ArrayList(i64) = .empty,
    tools: i64 = 0,
    bill: Bill = .{},
    done: bool = false,
    /// How to continue a paused turn; null leaves `pause_turn` as a stop.
    cont: ?Cont = null,
    continues: usize = 0,
    paused: bool = false,
    /// The current call's blocks, rebuilt for a continuation.
    blocks: std.ArrayList(Block) = .empty,
    /// Blocks of earlier calls (keeps `reasoning_details` indexes unique).
    base: usize = 0,

    /// A content block as it streams in.
    const Block = struct {
        /// The `content_block` of `content_block_start`, as JSON.
        start: []const u8 = "",
        text: std.ArrayList(u8) = .empty,
        signature: std.ArrayList(u8) = .empty,
        json: std.ArrayList(u8) = .empty,
        citations: std.ArrayList([]const u8) = .empty,
    };

    fn init(self: *Translator, arena: std.mem.Allocator, up: openrouter.Stream, meta: Meta) void {
        self.* = .{
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
            .buffer = undefined,
            .up = up,
            .parser = sse.Parser.init(arena, up.reader, .{}),
            .arena = arena,
            .scratch = .init(arena),
            .out = .init(arena),
            .meta = meta,
        };
        self.reader.buffer = &self.buffer;
    }

    fn close(ctx: *anyopaque) void {
        const self: *Translator = @ptrCast(@alignCast(ctx));
        self.parser.deinit();
        self.up.close();
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Translator = @alignCast(@fieldParentPtr("reader", r));
        while (self.pos >= self.out.written().len) {
            if (self.done) return error.EndOfStream;
            self.out.clearRetainingCapacity();
            self.pos = 0;
            self.pump() catch |err| {
                std.log.err("anthropic stream: {t}", .{err});
                return error.ReadFailed;
            };
        }
        const pending = self.out.written()[self.pos..];
        const n = limit.minInt(pending.len);
        try w.writeAll(pending[0..n]);
        self.pos += n;
        return n;
    }

    fn block(self: *Translator, index: usize) !*Block {
        while (self.blocks.items.len <= index) try self.blocks.append(self.arena, .{});
        return &self.blocks.items[index];
    }

    /// Translates the next upstream event into zero or more output chunks.
    fn pump(self: *Translator) !void {
        const ev = (try self.parser.next()) orelse return self.stop();
        _ = self.scratch.reset(.retain_capacity);
        const v = std.json.parseFromSliceLeaky(Value, self.scratch.allocator(), ev.data, .{}) catch return;
        if (v != .object) return;
        const o = v.object;
        const kind = jsonStr(o.get("type")) orelse return;

        if (std.mem.eql(u8, kind, "message_start")) {
            const m = (o.get("message") orelse return).object;
            try self.meta.serve(self.arena, jsonStr(m.get("model")) orelse "");
            if (m.get("usage")) |u| if (u == .object) self.bill.current.merge(u.object);
            if (self.started) return;
            self.started = true;
            self.id = try self.arena.dupe(u8, jsonStr(m.get("id")) orelse "");
            try self.chunk(.{ .role = "assistant", .content = "" }, null);
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            const index: usize = @intCast(@max(0, jsonInt(o.get("index"))));
            const cb = o.get("content_block") orelse return;
            if (cb != .object) return;
            const b = cb.object;
            const rec = try self.block(index);
            rec.start = try std.json.Stringify.valueAlloc(self.arena, cb, .{});
            const btype = jsonStr(b.get("type")) orelse "";
            while (self.tool_of.items.len <= index) try self.tool_of.append(self.arena, -1);
            if (std.mem.eql(u8, btype, "tool_use")) {
                const ti = self.tools;
                self.tools += 1;
                self.tool_of.items[index] = ti;
                try self.chunk(.{ .tool_calls = .{.{
                    .index = ti,
                    .id = jsonStr(b.get("id")) orelse "",
                    .type = "function",
                    .function = .{ .name = jsonStr(b.get("name")) orelse "", .arguments = "" },
                }} }, null);
            } else if (std.mem.eql(u8, btype, "text")) {
                const t = jsonStr(b.get("text")) orelse "";
                try rec.text.appendSlice(self.arena, t);
                if (t.len > 0) try self.chunk(.{ .content = t }, null);
            } else if (std.mem.eql(u8, btype, "thinking")) {
                try rec.text.appendSlice(self.arena, jsonStr(b.get("thinking")) orelse "");
            } else if (std.mem.eql(u8, btype, "redacted_thinking")) {
                const data = jsonStr(b.get("data")) orelse "";
                try self.chunk(.{ .reasoning_details = .{.{ .type = "reasoning.encrypted", .data = data, .format = details_format, .index = self.base + index }} }, null);
            } else {
                // Server tools run upstream: their calls stay hidden and
                // their results surface as citations.
                var anns: std.json.Array = .init(self.scratch.allocator());
                try resultCitations(self.scratch.allocator(), b, &anns);
                if (anns.items.len > 0) try self.chunk(.{ .content = "", .annotations = Value{ .array = anns } }, null);
            }
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const index: usize = @intCast(@max(0, jsonInt(o.get("index"))));
            const dv = o.get("delta") orelse return;
            if (dv != .object) return;
            const d = dv.object;
            const rec = try self.block(index);
            const dtype = jsonStr(d.get("type")) orelse "";
            if (std.mem.eql(u8, dtype, "text_delta")) {
                const t = jsonStr(d.get("text")) orelse "";
                try rec.text.appendSlice(self.arena, t);
                if (t.len > 0) try self.chunk(.{ .content = t }, null);
            } else if (std.mem.eql(u8, dtype, "thinking_delta")) {
                const t = jsonStr(d.get("thinking")) orelse "";
                try rec.text.appendSlice(self.arena, t);
                if (t.len > 0) try self.chunk(.{
                    .reasoning = t,
                    .reasoning_content = t,
                    .reasoning_details = .{.{ .type = "reasoning.text", .text = t, .format = details_format, .index = self.base + index }},
                }, null);
            } else if (std.mem.eql(u8, dtype, "signature_delta")) {
                const sig = jsonStr(d.get("signature")) orelse "";
                try rec.signature.appendSlice(self.arena, sig);
                if (sig.len > 0) try self.chunk(.{ .reasoning_details = .{.{ .type = "reasoning.text", .signature = sig, .format = details_format, .index = self.base + index }} }, null);
            } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
                const part = jsonStr(d.get("partial_json")) orelse "";
                try rec.json.appendSlice(self.arena, part);
                if (part.len == 0 or index >= self.tool_of.items.len or self.tool_of.items[index] < 0) return;
                try self.chunk(.{ .tool_calls = .{.{ .index = self.tool_of.items[index], .function = .{ .arguments = part } }} }, null);
            } else if (std.mem.eql(u8, dtype, "citations_delta")) {
                const c = d.get("citation") orelse return;
                try rec.citations.append(self.arena, try std.json.Stringify.valueAlloc(self.arena, c, .{}));
                var anns: std.json.Array = .init(self.scratch.allocator());
                try citationOf(self.scratch.allocator(), c, &anns);
                if (anns.items.len > 0) try self.chunk(.{ .content = "", .annotations = Value{ .array = anns } }, null);
            }
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            if (o.get("usage")) |u| if (u == .object) self.bill.current.merge(u.object);
            const d = (o.get("delta") orelse return).object;
            const reason = jsonStr(d.get("stop_reason")) orelse return;
            if (std.mem.eql(u8, reason, "pause_turn")) {
                self.paused = true;
            } else try self.chunk(struct {}{}, finishReason(reason));
        } else if (std.mem.eql(u8, kind, "message_stop")) {
            try self.stop();
        } else if (std.mem.eql(u8, kind, "error")) {
            const e = o.get("error");
            const message = if (e) |x| openrouter.jsonString(x, "message") orelse "upstream error" else "upstream error";
            try self.out.writer.writeAll("data: ");
            try std.json.Stringify.value(.{ .@"error" = .{ .message = message, .code = if (e) |x| openrouter.jsonString(x, "type") orelse "error" else "error" } }, .{}, &self.out.writer);
            try self.out.writer.writeAll("\n\n");
            try self.finish();
        }
    }

    /// The end of one upstream message: continue a paused turn, or finish.
    fn stop(self: *Translator) !void {
        if (self.done) return;
        if (self.paused) {
            if (try self.resume_()) return;
            // Out of continuations: end the reply where it paused.
            try self.chunk(struct {}{}, "stop");
        }
        try self.finish();
    }

    /// Posts the continuation of a paused turn and switches to its stream.
    fn resume_(self: *Translator) !bool {
        var cont = self.cont orelse return false;
        if (self.continues >= max_continues) return false;
        const body = try continueBody(self.arena, cont.body, try self.assistantBlocks());
        const next = cont.inner.post(cont.cx, "/messages", body, cont.headers) catch |err| {
            std.log.warn("anthropic pause_turn continuation failed: {t}", .{err});
            return false;
        };
        if (next.status >= 300) {
            std.log.warn("anthropic pause_turn continuation failed: HTTP {d}", .{next.status});
            next.close();
            return false;
        }
        self.parser.deinit();
        self.up.close();
        self.up = next;
        self.parser = sse.Parser.init(self.arena, next.reader, .{});
        cont.body = body;
        self.cont = cont;
        self.continues += 1;
        self.paused = false;
        self.bill.rollover(self.meta.prices);
        self.base += self.blocks.items.len;
        self.blocks.clearRetainingCapacity();
        self.tool_of.clearRetainingCapacity();
        return true;
    }

    /// The current call's content blocks, as Anthropic sent them.
    fn assistantBlocks(self: *Translator) ![]const Value {
        const a = self.arena;
        var out: std.json.Array = .init(a);
        for (self.blocks.items) |*rec| {
            if (rec.start.len == 0) continue;
            var v = std.json.parseFromSliceLeaky(Value, a, rec.start, .{}) catch continue;
            if (v != .object) continue;
            const btype = jsonStr(v.object.get("type")) orelse continue;
            if (std.mem.eql(u8, btype, "text")) {
                if (rec.text.items.len == 0) continue;
                try v.object.put(a, "text", str(rec.text.items));
                if (rec.citations.items.len > 0) {
                    var list: std.json.Array = .init(a);
                    for (rec.citations.items) |c| try list.append(try std.json.parseFromSliceLeaky(Value, a, c, .{}));
                    try v.object.put(a, "citations", .{ .array = list });
                }
            } else if (std.mem.eql(u8, btype, "thinking")) {
                try v.object.put(a, "thinking", str(rec.text.items));
                try v.object.put(a, "signature", str(rec.signature.items));
            } else if (rec.json.items.len > 0 and v.object.contains("input")) {
                const input = std.json.parseFromSliceLeaky(Value, a, rec.json.items, .{}) catch null;
                if (input) |x| if (x == .object) try v.object.put(a, "input", x);
            }
            try out.append(v);
        }
        return out.items;
    }

    fn chunk(self: *Translator, delta: anytype, finish_reason: ?[]const u8) !void {
        const w = &self.out.writer;
        try w.writeAll("data: ");
        try std.json.Stringify.value(.{
            .id = self.id,
            .object = "chat.completion.chunk",
            .created = self.meta.created,
            .model = self.meta.model,
            .choices = .{.{ .index = 0, .delta = delta, .finish_reason = finish_reason }},
        }, .{}, w);
        try w.writeAll("\n\n");
    }

    /// The usage chunk and `[DONE]`, once.
    fn finish(self: *Translator) !void {
        if (self.done) return;
        self.done = true;
        const w = &self.out.writer;
        var s: std.json.Stringify = .{ .writer = w };
        try w.writeAll("data: ");
        try s.beginObject();
        try s.objectField("id");
        try s.write(self.id);
        try s.objectField("object");
        try s.write("chat.completion.chunk");
        try s.objectField("created");
        try s.write(self.meta.created);
        try s.objectField("model");
        try s.write(self.meta.model);
        try s.objectField("choices");
        try s.beginArray();
        try s.endArray();
        try s.objectField("usage");
        try self.bill.write(&s, self.meta.prices, self.meta.servedModel());
        try s.endObject();
        try w.writeAll("\n\ndata: [DONE]\n\n");
    }
};

/// OpenAI `url_citation` annotations for a server tool's result block
/// (web search results; other results add none).
fn resultCitations(arena: std.mem.Allocator, b: ObjectMap, out: *std.json.Array) !void {
    const content = b.get("content") orelse return;
    if (content != .array) return; // an error result
    for (content.array.items) |r| {
        if (r != .object) continue;
        const url = jsonStr(r.object.get("url")) orelse continue;
        try out.append(try annotation(arena, url, jsonStr(r.object.get("title")) orelse url, null));
    }
}

/// A text block's citation (`web_search_result_location` and friends) as an
/// annotation; citations without a URL (documents) add none.
fn citationOf(arena: std.mem.Allocator, c: Value, out: *std.json.Array) !void {
    if (c != .object) return;
    const url = jsonStr(c.object.get("url")) orelse return;
    try out.append(try annotation(arena, url, jsonStr(c.object.get("title")) orelse url, jsonStr(c.object.get("cited_text"))));
}

fn annotation(arena: std.mem.Allocator, url: []const u8, title: []const u8, snippet: ?[]const u8) !Value {
    var cit: ObjectMap = .empty;
    try cit.put(arena, "url", str(url));
    try cit.put(arena, "title", str(title));
    if (snippet) |s| try cit.put(arena, "content", str(s));
    return obj(arena, &.{ .{ "type", str("url_citation") }, .{ "url_citation", .{ .object = cit } } });
}

/// A whole (non-streamed) reply, its parts joined, as a `chat.completion`.
fn translateMessage(arena: std.mem.Allocator, id: []const u8, content: []const Value, stop: []const u8, bill: Bill, meta: Meta) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    var reasoning: std.Io.Writer.Allocating = .init(arena);
    var calls: std.json.Array = .init(arena);
    var details: std.json.Array = .init(arena);
    var anns: std.json.Array = .init(arena);
    for (content, 0..) |b, i| {
        if (b != .object) continue;
        const btype = jsonStr(b.object.get("type")) orelse continue;
        if (std.mem.eql(u8, btype, "text")) {
            try text.writer.writeAll(jsonStr(b.object.get("text")) orelse "");
            if (b.object.get("citations")) |cs| if (cs == .array) for (cs.array.items) |c| try citationOf(arena, c, &anns);
        } else if (std.mem.eql(u8, btype, "thinking")) {
            const t = jsonStr(b.object.get("thinking")) orelse "";
            try reasoning.writer.writeAll(t);
            try details.append(try obj(arena, &.{
                .{ "type", str("reasoning.text") },
                .{ "text", str(t) },
                .{ "signature", b.object.get("signature") orelse str("") },
                .{ "format", str(details_format) },
                .{ "index", .{ .integer = @intCast(i) } },
            }));
        } else if (std.mem.eql(u8, btype, "redacted_thinking")) {
            try details.append(try obj(arena, &.{
                .{ "type", str("reasoning.encrypted") },
                .{ "data", b.object.get("data") orelse str("") },
                .{ "format", str(details_format) },
                .{ "index", .{ .integer = @intCast(i) } },
            }));
        } else if (std.mem.eql(u8, btype, "tool_use")) {
            const args = try std.json.Stringify.valueAlloc(arena, b.object.get("input") orelse try obj(arena, &.{}), .{});
            try calls.append(try obj(arena, &.{
                .{ "id", b.object.get("id") orelse str("") },
                .{ "type", str("function") },
                .{ "function", try obj(arena, &.{ .{ "name", b.object.get("name") orelse str("") }, .{ "arguments", str(args) } }) },
            }));
        } else {
            // Server tool calls and results: citations only.
            try resultCitations(arena, b.object, &anns);
        }
    }
    var message: ObjectMap = .empty;
    try message.put(arena, "role", str("assistant"));
    try message.put(arena, "content", if (text.written().len > 0) str(text.written()) else .null);
    if (reasoning.written().len > 0) {
        try message.put(arena, "reasoning", str(reasoning.written()));
        try message.put(arena, "reasoning_content", str(reasoning.written()));
    }
    if (details.items.len > 0) try message.put(arena, "reasoning_details", .{ .array = details });
    if (calls.items.len > 0) try message.put(arena, "tool_calls", .{ .array = calls });
    if (anns.items.len > 0) try message.put(arena, "annotations", .{ .array = anns });

    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    try s.objectField("object");
    try s.write("chat.completion");
    try s.objectField("created");
    try s.write(meta.created);
    try s.objectField("model");
    try s.write(meta.model);
    try s.objectField("choices");
    try s.write(.{.{ .index = 0, .message = Value{ .object = message }, .finish_reason = finishReason(stop) }});
    try s.objectField("usage");
    try bill.write(&s, meta.prices, meta.servedModel());
    try s.endObject();
    return out.written();
}

/// Anthropic's error body in OpenAI's shape (`openrouter.complete` and
/// LiteLLM read `error.message`).
fn translateError(arena: std.mem.Allocator, raw: []const u8, status: u16) ![]const u8 {
    var message: []const u8 = if (raw.len > 0) raw else "upstream error";
    var kind: []const u8 = "upstream_error";
    if (std.json.parseFromSliceLeaky(Value, arena, raw, .{})) |v| {
        if (v == .object) if (v.object.get("error")) |e| {
            message = openrouter.jsonString(e, "message") orelse message;
            kind = openrouter.jsonString(e, "type") orelse kind;
        };
    } else |_| {}
    return std.json.Stringify.valueAlloc(arena, .{ .@"error" = .{ .message = message, .type = kind, .code = status } }, .{});
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test anthropicId {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("claude-haiku-5-5", try anthropicId(arena.allocator(), "anthropic/claude-haiku-5.5"));
    try testing.expectEqualStrings("claude-opus-5-5", try anthropicId(arena.allocator(), "anthropic/claude-opus-5.5:thinking"));
}

test translateRequest {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try std.json.parseFromSliceLeaky(Value, a,
        \\{"model":"anthropic/claude-sonnet-5.5","stream":true,"temperature":0.2,"top_p":1,"usage":{"include":true},
        \\ "plugins":[{"id":"web"}],"tool_choice":"required",
        \\ "tools":[{"type":"function","function":{"name":"make_quiz","description":"Quiz","parameters":{"type":"object"}},"cache_control":{"type":"ephemeral"}}],
        \\ "messages":[
        \\  {"role":"system","content":[{"type":"text","text":"sys","cache_control":{"type":"ephemeral"}}]},
        \\  {"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBO"}},
        \\     {"type":"file","file":{"filename":"a.pdf","file_data":"data:application/pdf;base64,JVBE"}},{"type":"text","text":"what's this?","cache_control":{"type":"ephemeral"}}]},
        \\  {"role":"assistant","content":"","tool_calls":[{"id":"toolu_1","type":"function","function":{"name":"make_quiz","arguments":"{\"title\":\"x\"}"}}]},
        \\  {"role":"tool","tool_call_id":"toolu_1","content":"Shown to the user."},
        \\  {"role":"user","content":[{"type":"text","text":"thanks","cache_control":{"type":"ephemeral"}}]},
        \\  {"role":"assistant","content":"sure"},
        \\  {"role":"user","content":[{"type":"text","text":"more","cache_control":{"type":"ephemeral"}}]}
        \\ ]}
    , .{});
    const t = try translateRequest(a, in.object);
    try testing.expect(t.stream and t.fallbacks);
    try testing.expectEqualStrings("anthropic/claude-sonnet-5.5", t.model);
    const out = (try std.json.parseFromSliceLeaky(Value, a, t.body, .{})).object;
    try testing.expectEqualStrings("claude-sonnet-5-5", out.get("model").?.string);
    for ([_][]const u8{ "temperature", "top_p", "usage", "plugins" }) |k| try testing.expect(out.get(k) == null);
    try testing.expectEqualStrings("auto", out.get("tool_choice").?.object.get("type").?.string);
    // A replayed thinking block whose earlier history changed is dropped, not a 400.
    const binding = out.get("thinking").?.object.get("block_binding").?.object;
    try testing.expectEqualStrings("drop_block", binding.get("prefix_mismatch_behavior").?.string);
    try testing.expectEqualStrings("sys", out.get("system").?.array.items[0].object.get("text").?.string);
    const msgs = out.get("messages").?.array.items;
    // user, assistant(tool_use), user(tool_result + thanks), assistant, user
    try testing.expectEqual(@as(usize, 5), msgs.len);
    const first = msgs[0].object.get("content").?.array.items;
    try testing.expectEqualStrings("image", first[0].object.get("type").?.string);
    try testing.expectEqualStrings("image/png", first[0].object.get("source").?.object.get("media_type").?.string);
    try testing.expectEqualStrings("document", first[1].object.get("type").?.string);
    const tool_use = msgs[1].object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("x", tool_use.get("input").?.object.get("title").?.string);
    const merged = msgs[2].object.get("content").?.array.items;
    try testing.expectEqualStrings("tool_result", merged[0].object.get("type").?.string);
    try testing.expectEqualStrings("thanks", merged[1].object.get("text").?.string);
    // Five breakpoints in: the oldest message one is dropped.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, t.body, "cache_control"));
    try testing.expect(first[2].object.get("cache_control") == null);
    try testing.expect(merged[1].object.get("cache_control") != null);
}

test "stream translation: text, thinking, tool call, usage with computed cost" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const upstream_sse =
        \\event: message_start
        \\data: {"type":"message_start","message":{"id":"msg_1","model":"claude-haiku-5-5","usage":{"input_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":200},"output_tokens":1}}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hmm."}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Here you go."}}
        \\
        \\event: ping
        \\data: {"type":"ping"}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_9","name":"make_quiz","input":{}}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"title\":"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"Zig\"}"}}
        \\
        \\event: message_delta
        \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}
        \\
        \\event: message_stop
        \\data: {"type":"message_stop"}
        \\
        \\
    ;
    var src: std.Io.Reader = .fixed(upstream_sse);
    const tr = try a.create(Translator);
    tr.init(a, .{ .status = 200, .reader = &src, .ctx = undefined, .closeFn = noClose }, .{
        .model = "anthropic/claude-haiku-5.5",
        .created = 1,
        .prices = .{ .base = .{ .prompt = 1e-6, .completion = 5e-6, .cache_read = 1e-7, .cache_write = 1.25e-6, .cache_write_1h = 2e-6 } },
    });
    defer tr.parser.deinit();

    // The same parser `openrouter.complete` uses reads it back.
    const Sink = struct {
        text: std.ArrayList(u8) = .empty,
        a: std.mem.Allocator,
        pub fn onDelta(self: *@This(), d: openrouter.Delta) !void {
            switch (d) {
                .text => |t| try self.text.appendSlice(self.a, t),
                .reasoning => |t| try self.text.appendSlice(self.a, t),
                .sources => {},
            }
        }
    };
    var sink: Sink = .{ .a = a };
    var err: openrouter.UpstreamError = .{ .status = 0, .message = "" };
    const translated = try tr.reader.allocRemaining(a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, translated, "\"delta\":[]") == null);
    try testing.expect(std.mem.endsWith(u8, translated, "data: [DONE]\n\n"));
    var again: std.Io.Reader = .fixed(translated);
    const result = try openrouter.parseStream(a, &again, &sink, &err);
    try testing.expectEqualStrings("Hmm.Here you go.", sink.text.items);
    try testing.expectEqualStrings("Here you go.", result.text);
    try testing.expectEqualStrings("Hmm.", result.reasoning);
    try testing.expectEqualStrings(
        \\[{"type":"reasoning.text","format":"anthropic-claude-v1","signature":"EqQB","text":"Hmm.","index":0}]
    , result.reasoning_details);
    try testing.expectEqualStrings("tool_calls", result.finish_reason);
    try testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try testing.expectEqualStrings("toolu_9", result.tool_calls[0].id);
    try testing.expectEqualStrings("{\"title\":\"Zig\"}", result.tool_calls[0].arguments);
    try testing.expectEqual(@as(i64, 1300), result.usage.prompt_tokens);
    try testing.expectEqual(@as(i64, 1000), result.usage.cached_tokens);
    try testing.expectEqual(@as(i64, 200), result.usage.cache_write_tokens);
    try testing.expectEqual(@as(i64, 40), result.usage.completion_tokens);
    // 100×1e-6 + 1000×1e-7 + 200×2e-6 + 40×5e-6 = 0.0008
    try testing.expectApproxEqAbs(@as(f64, 0.0008), result.usage.cost_usd, 1e-12);
}

test "signed reasoning details go back as thinking blocks ahead of the tool call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try std.json.parseFromSliceLeaky(Value, a,
        \\{"model":"anthropic/claude-haiku-5.5","reasoning":{"effort":"max"},"messages":[
        \\  {"role":"user","content":"go"},
        \\  {"role":"assistant","content":"","reasoning":"Hmm.","reasoning_details":[
        \\    {"type":"reasoning.text","text":"Hmm.","signature":"EqQB","format":"anthropic-claude-v1","index":0},
        \\    {"type":"reasoning.encrypted","data":"RED","format":"anthropic-claude-v1","index":1},
        \\    {"type":"reasoning.text","text":"unsigned","index":2},
        \\    {"type":"reasoning.text","text":"other","signature":"x","format":"openai-responses-v1","index":3}],
        \\   "tool_calls":[{"id":"toolu_1","type":"function","function":{"name":"web_fetch","arguments":"{}"}}]},
        \\  {"role":"tool","tool_call_id":"toolu_1","content":"page"}
        \\]}
    , .{});
    const t = try translateRequest(a, in.object);
    const out = (try std.json.parseFromSliceLeaky(Value, a, t.body, .{})).object;
    try testing.expectEqualStrings("max", out.get("output_config").?.object.get("effort").?.string);
    const blocks = out.get("messages").?.array.items[1].object.get("content").?.array.items;
    try testing.expectEqual(@as(usize, 3), blocks.len);
    try testing.expectEqualStrings("thinking", blocks[0].object.get("type").?.string);
    try testing.expectEqualStrings("Hmm.", blocks[0].object.get("thinking").?.string);
    try testing.expectEqualStrings("EqQB", blocks[0].object.get("signature").?.string);
    try testing.expectEqualStrings("redacted_thinking", blocks[1].object.get("type").?.string);
    try testing.expectEqualStrings("tool_use", blocks[2].object.get("type").?.string);
}

test "errors come back in OpenAI shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try translateError(arena.allocator(), "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}", 529);
    try testing.expectEqualStrings("{\"error\":{\"message\":\"Overloaded\",\"type\":\"overloaded_error\",\"code\":529}}", out);
}

test sameModel {
    try testing.expect(sameModel("anthropic/claude-opus-5.5", "claude-opus-5-5"));
    try testing.expect(!sameModel("anthropic/claude-opus-5.5:thinking", "claude-opus-5-5"));
    try testing.expect(!sameModel("anthropic/claude-opus-5", "claude-opus-5-5"));
}

test "server tools pass through; a fallback is priced as the model that served; searches billed by kind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const in = try std.json.parseFromSliceLeaky(Value, a,
        \\{"model":"anthropic/claude-sonnet-5.5","stream":true,"messages":[{"role":"user","content":"news?"}],
        \\ "tools":[{"type":"web_search_20250305","name":"web_search","max_uses":3},
        \\  {"type":"code_execution_20250825","name":"code_execution"}]}
    , .{});
    const t = try translateRequest(a, in.object);
    const tools = (try std.json.parseFromSliceLeaky(Value, a, t.body, .{})).object.get("tools").?.array.items;
    // Code execution bills container time we don't meter, so it never reaches Anthropic.
    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("web_search_20250305", tools[0].object.get("type").?.string);
    try testing.expectEqual(@as(i64, 3), tools[0].object.get("max_uses").?.integer);

    const upstream_sse =
        \\data: {"type":"message_start","message":{"id":"msg_f","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":1}}}
        \\
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}
        \\
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"zig\"}"}}
        \\
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","url":"https://ziglang.org","title":"Zig","encrypted_content":"E1"}]}}
        \\
        \\data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}
        \\
        \\data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://ziglang.org/news","title":"News","cited_text":"0.17 is out","encrypted_index":"Eo"}}}
        \\
        \\data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Zig 0.17 shipped."}}
        \\
        \\data: {"type":"message_delta","delta":{"stop_reason":"pause_turn"},"usage":{"output_tokens":10,"server_tool_use":{"web_search_requests":2}}}
        \\
        \\data: {"type":"message_stop"}
        \\
        \\
    ;
    const Table = struct {
        fn lookup(_: *anyopaque, _: std.Io, _: std.mem.Allocator, api_id: []const u8) ?Priced {
            if (!std.mem.eql(u8, api_id, "claude-opus-5-5")) return null;
            return .{ .model = "anthropic/claude-opus-5.5", .prices = .{ .base = .{ .prompt = 1e-5, .completion = 1e-4 } } };
        }
    };
    var dummy: u8 = 0;
    var src: std.Io.Reader = .fixed(upstream_sse);
    const tr = try a.create(Translator);
    tr.init(a, .{ .status = 200, .reader = &src, .ctx = undefined, .closeFn = noClose }, .{
        .model = "anthropic/claude-sonnet-5.5",
        .api_id = "claude-sonnet-5-5",
        .created = 1,
        .prices = .{ .base = .{ .prompt = 1e-6, .completion = 1e-6 } },
        .resolver = .{ .ctx = &dummy, .io = undefined, .lookupFn = Table.lookup },
    });
    defer tr.parser.deinit();
    const translated = try tr.reader.allocRemaining(a, .unlimited);

    var err: openrouter.UpstreamError = .{ .status = 0, .message = "" };
    var again: std.Io.Reader = .fixed(translated);
    const r = try openrouter.parseStream(a, &again, NoSink{}, &err);
    // The server tool call stays upstream; its results become sources.
    try testing.expectEqual(@as(usize, 0), r.tool_calls.len);
    try testing.expectEqualStrings("Zig 0.17 shipped.", r.text);
    try testing.expectEqual(@as(usize, 2), r.sources.len);
    try testing.expectEqualStrings("https://ziglang.org", r.sources[0].url);
    try testing.expectEqualStrings("0.17 is out", r.sources[1].snippet.?);
    // Without a way to continue, the pause ends the reply.
    try testing.expectEqualStrings("stop", r.finish_reason);
    try testing.expectEqualStrings("anthropic/claude-opus-5.5", r.usage.served_model);
    // Opus prices: 100×1e-5 + 10×1e-4 = 0.002, plus 2 searches × $0.01.
    try testing.expectApproxEqAbs(@as(f64, 0.022), r.usage.cost_usd, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.02), r.usage.search_cost_usd, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.002), r.usage.tokenCost(), 1e-12);
    try testing.expectEqual(@as(i64, 2), r.usage.search_requests);

    // What a continuation would send back: the blocks as Anthropic sent them.
    const blocks = try tr.assistantBlocks();
    try testing.expectEqual(@as(usize, 3), blocks.len);
    try testing.expectEqualStrings("zig", blocks[0].object.get("input").?.object.get("query").?.string);
    try testing.expectEqualStrings("E1", blocks[1].object.get("content").?.array.items[0].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("Zig 0.17 shipped.", blocks[2].object.get("text").?.string);
    try testing.expectEqualStrings("Eo", blocks[2].object.get("citations").?.array.items[0].object.get("encrypted_index").?.string);
    const body = try continueBody(a, t.body, blocks);
    const msgs = (try std.json.parseFromSliceLeaky(Value, a, body, .{})).object.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 2), msgs.len);
    try testing.expectEqualStrings("assistant", msgs[1].object.get("role").?.string);
    // A second pause appends to the same assistant turn.
    const body2 = try continueBody(a, body, blocks[2..]);
    const msgs2 = (try std.json.parseFromSliceLeaky(Value, a, body2, .{})).object.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 2), msgs2.len);
    try testing.expectEqual(@as(usize, 4), msgs2[1].object.get("content").?.array.items.len);
}

const NoSink = struct {
    pub fn onDelta(_: NoSink, _: openrouter.Delta) !void {}
};
