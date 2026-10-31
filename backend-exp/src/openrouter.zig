//! OpenRouter (OpenAI-compatible) upstream: one streamed chat completion,
//! accumulated into text, reasoning, tool calls, URL citations and usage.
//! `Upstream` is the seam tests replace with canned SSE.
const std = @import("std");
const anole = @import("anole");
const sse = anole.sse;

// anole.http does not export the core response types; take them from `fetch`.
const CoreResponse = @typeInfo(@typeInfo(@TypeOf(anole.http.Client.fetch)).@"fn".return_type.?).error_union.payload;
const BodyReader = @typeInfo(@typeInfo(@TypeOf(CoreResponse.reader)).@"fn".return_type.?).error_union.payload;

// ------------------------------------------------------------------ the seam

/// An open upstream response body.
pub const Stream = struct {
    status: u16,
    reader: *std.Io.Reader,
    ctx: *anyopaque,
    closeFn: *const fn (*anyopaque) void,
    /// The upstream's `Retry-After` on an error status (copied to the
    /// call's arena), so the gateway can pass it on to clients that back off.
    retry_after: ?[]const u8 = null,

    pub fn close(self: Stream) void {
        self.closeFn(self.ctx);
    }
};

/// What an upstream call needs from its caller: the runtime and an arena
/// for the call's memory. A handler passes `ctxOf(req)`; a task it starts
/// passes its own (Clients: give such a task its own allocator).
pub const Ctx = anole.db.Ctx;

/// The call context of a request, a `*anole.db.Ctx` or anything else with
/// `io` and `arena`.
pub fn ctxOf(c: anytype) Ctx {
    return .{ .io = c.io, .arena = c.arena };
}

pub const Upstream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// POST `path` (relative to the API root) with a JSON body, streamed.
        post: *const fn (ptr: *anyopaque, cx: Ctx, path: []const u8, body: []const u8, extra_headers: []const [2][]const u8) anyerror!Stream,
        /// GET `path`, whole body, for catalog refreshes (no request needed).
        get: *const fn (ptr: *anyopaque, io: std.Io, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8,
    };

    pub fn post(self: Upstream, cx: Ctx, path: []const u8, body: []const u8, extra_headers: []const [2][]const u8) !Stream {
        return self.vtable.post(self.ptr, cx, path, body, extra_headers);
    }

    pub fn get(self: Upstream, io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        return self.vtable.get(self.ptr, io, arena, path);
    }
};

/// The real OpenRouter client, through the server's pooled HTTP client. With
/// `.auth = .anthropic` it is the raw transport for Anthropic's API instead
/// (`x-api-key` + `anthropic-version`; see anthropic.zig).
pub const Client = struct {
    base_url: []const u8,
    api_key: []const u8,
    referer: []const u8 = "",
    auth: enum { bearer, anthropic } = .bearer,

    const Live = struct {
        response: CoreResponse,
        buffer: [64 * 1024]u8,
        body: BodyReader,
    };

    pub fn upstream(self: *Client) Upstream {
        return .{ .ptr = self, .vtable = &.{ .post = post, .get = get } };
    }

    fn headers(self: *Client, arena: std.mem.Allocator, extra: []const [2][]const u8) !anole.http.Headers {
        var h = try anole.http.Headers.init(arena, 6 + extra.len);
        try h.put("Content-Type", "application/json");
        switch (self.auth) {
            .bearer => {
                try h.put("Authorization", try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key}));
                try h.put("HTTP-Referer", self.referer);
                try h.put("X-Title", "EveryAI");
            },
            .anthropic => {
                try h.put("x-api-key", self.api_key);
                try h.put("anthropic-version", "2026-10-21");
            },
        }
        for (extra) |e| try h.put(e[0], e[1]);
        return h;
    }

    fn post(ptr: *anyopaque, cx: Ctx, path: []const u8, body: []const u8, extra: []const [2][]const u8) anyerror!Stream {
        const self: *Client = @ptrCast(@alignCast(ptr));
        // No key here (and none from the user): answered at once, the way
        // OpenRouter answers a call without credentials, with what to do.
        if (self.api_key.len == 0) {
            const reader = try cx.arena.create(std.Io.Reader);
            reader.* = .fixed(no_key_body);
            return .{ .status = 401, .reader = reader, .ctx = reader, .closeFn = noClose };
        }
        const url = try std.fmt.allocPrint(cx.arena, "{s}{s}", .{ self.base_url, path });
        const h = try self.headers(cx.arena, extra);
        const live = try cx.arena.create(Live);
        live.response = try anole.client(cx.io).http.fetch(url, .{
            .method = .post,
            .headers = &h,
            .body = body,
            .stream = true,
            // Until the response head; the body streams on the turn's time.
            .timeout = .{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } },
        });
        live.body = try live.response.reader(&live.buffer);
        const status: u16 = @intCast(@backingInt(live.response.status()));
        const retry_after = if (status >= 300) live.response.headers().get("Retry-After") else null;
        return .{
            .status = status,
            .reader = &live.body.interface,
            .ctx = live,
            .closeFn = closeLive,
            .retry_after = if (retry_after) |v| try cx.arena.dupe(u8, v) else null,
        };
    }

    fn noClose(_: *anyopaque) void {}

    fn closeLive(ctx: *anyopaque) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        live.response.deinit();
    }

    fn get(ptr: *anyopaque, io: std.Io, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *Client = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base_url, path });
        var r = switch (self.auth) {
            // The model list is public: no key, no header.
            .bearer => if (self.api_key.len == 0)
                try anole.client(io).fetch(url, .{})
            else
                try anole.client(io).fetch(url, .{ .headers = &.{.{ "Authorization", try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key}) }} }),
            .anthropic => try anole.client(io).fetch(url, .{ .headers = &.{ .{ "x-api-key", self.api_key }, .{ "anthropic-version", "2026-10-21" } } }),
        };
        defer r.deinit();
        if (@backingInt(r.status()) >= 300) return error.BadGateway;
        return arena.dupe(u8, try r.body());
    }
};

// ------------------------------------------------------------------ one completion

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// JSON text as the model produced it.
    arguments: []const u8,
};

pub const Source = struct {
    url: []const u8,
    title: []const u8,
    snippet: ?[]const u8 = null,
};

pub const Usage = struct {
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    cached_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
    /// Total cost, server-tool fees included.
    cost_usd: f64 = 0,
    /// The model that actually served and was priced, when the upstream
    /// says (the Anthropic adapter, under server-side fallbacks); "" = the
    /// model asked for. Points into the parsed JSON: dupe before keeping.
    served_model: []const u8 = "",
    /// Server-side web searches and their share of `cost_usd` (the usage
    /// object's `by_kind` "search" entry); billed as kind "search".
    search_requests: i64 = 0,
    search_cost_usd: f64 = 0,

    /// The model to bill: the served one when known.
    pub fn billedModel(self: Usage, asked: []const u8) []const u8 {
        return if (self.served_model.len > 0) self.served_model else asked;
    }

    /// The token part of the cost (without server-tool fees).
    pub fn tokenCost(self: Usage) f64 {
        return @max(0, self.cost_usd - self.search_cost_usd);
    }
};

pub const Result = struct {
    text: []const u8,
    reasoning: []const u8,
    /// OpenRouter's structured reasoning (a JSON array, signatures and
    /// encrypted blocks included), merged per block; "" when none came.
    /// Sent back verbatim on the assistant message within a tool loop.
    reasoning_details: []const u8 = "",
    tool_calls: []const ToolCall,
    sources: []const Source,
    usage: Usage,
    finish_reason: []const u8,
    model: []const u8,
};

/// What a completion reports while it streams.
pub const Delta = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    /// Sources new since the last event, in citation order; the client appends.
    sources: []const Source,
};

/// What the user is told when a call has no key to run on.
pub const no_key_message = "No API key for this model. Add your OpenRouter or Anthropic key in Settings → API keys.";
const no_key_body = "{\"error\":{\"message\":\"" ++ no_key_message ++ "\",\"code\":\"no_api_key\"}}";

pub const UpstreamError = struct {
    status: u16,
    message: []const u8,
};

/// Streams one `/chat/completions` call. `sink.onDelta(Delta)` is called as
/// content arrives; the accumulated result is returned (memory in `arena`).
/// An upstream failure returns `error.Upstream` with `err_out` filled in.
pub fn complete(up: Upstream, cx: Ctx, arena: std.mem.Allocator, body: []const u8, extra_headers: []const [2][]const u8, sink: anytype, err_out: *UpstreamError) !Result {
    const stream = try up.post(cx, "/chat/completions", body, extra_headers);
    defer stream.close();

    if (stream.status >= 300) {
        const raw = stream.reader.allocRemaining(arena, .limited(64 * 1024)) catch "";
        err_out.* = .{ .status = stream.status, .message = errorMessage(arena, raw) };
        return error.Upstream;
    }
    return parseStream(arena, stream.reader, sink, err_out);
}

/// Reads an OpenAI-style chunk stream to the end (see `complete`).
pub fn parseStream(arena: std.mem.Allocator, reader: *std.Io.Reader, sink: anytype, err_out: *UpstreamError) !Result {
    var text: std.Io.Writer.Allocating = .init(arena);
    var reasoning: std.Io.Writer.Allocating = .init(arena);
    var calls: std.ArrayList(PartialCall) = .empty;
    var details: Details = .{};
    var sources: std.ArrayList(Source) = .empty;
    var usage: Usage = .{};
    var finish: []const u8 = "";
    var model: []const u8 = "";

    var scratch: std.heap.ArenaAllocator = .init(arena);
    defer scratch.deinit();

    var parser = sse.Parser.init(arena, reader, .{});
    defer parser.deinit();
    while (try parser.next()) |ev| {
        if (std.mem.eql(u8, ev.data, "[DONE]")) break;
        _ = scratch.reset(.retain_capacity);
        const chunk = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), ev.data, .{}) catch continue;
        if (chunk != .object) continue;
        const o = chunk.object;

        if (o.get("error")) |e| {
            err_out.* = .{ .status = 502, .message = try arena.dupe(u8, jsonString(e, "message") orelse "upstream error") };
            return error.Upstream;
        }
        if (model.len == 0) if (jsonStr(o.get("model"))) |m| {
            model = try arena.dupe(u8, m);
        };
        if (o.get("usage")) |u| if (u == .object) {
            usage = parseUsage(u.object);
            usage.served_model = try arena.dupe(u8, usage.served_model);
        };

        const choices = o.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0].object;
        if (jsonStr(choice.get("finish_reason"))) |f| finish = try arena.dupe(u8, f);
        const delta = (choice.get("delta") orelse choice.get("message") orelse continue);
        if (delta != .object) continue;
        const d = delta.object;

        if (jsonStr(d.get("content"))) |c| if (c.len > 0) {
            try text.writer.writeAll(c);
            try sink.onDelta(.{ .text = c });
        };
        // `reasoning_content` is DeepSeek's own name for it.
        if (jsonStr(d.get("reasoning")) orelse jsonStr(d.get("reasoning_content"))) |r| if (r.len > 0) {
            try reasoning.writer.writeAll(r);
            try sink.onDelta(.{ .reasoning = r });
        };
        if (d.get("reasoning_details")) |rd| if (rd == .array) for (rd.array.items) |item| {
            if (item == .object) try details.merge(arena, item.object);
        };
        if (d.get("tool_calls")) |tc| if (tc == .array) for (tc.array.items) |item| {
            try mergeToolCall(arena, &calls, item.object);
        };
        if (d.get("annotations")) |ann| if (ann == .array) {
            const first = sources.items.len;
            for (ann.array.items) |a| {
                const cit = (a.object.get("url_citation") orelse continue).object;
                const url = jsonStr(cit.get("url")) orelse continue;
                if (hasSource(sources.items, url)) continue;
                try sources.append(arena, .{
                    .url = try arena.dupe(u8, url),
                    .title = try arena.dupe(u8, jsonStr(cit.get("title")) orelse url),
                    .snippet = if (jsonStr(cit.get("content"))) |s| try arena.dupe(u8, s[0..@min(s.len, 300)]) else null,
                });
            }
            if (sources.items.len > first) try sink.onDelta(.{ .sources = sources.items[first..] });
        };
    }

    const tool_calls = try arena.alloc(ToolCall, calls.items.len);
    for (calls.items, tool_calls) |*c, *out| out.* = .{ .id = c.id, .name = c.name, .arguments = c.args.written() };
    return .{
        .text = text.written(),
        .reasoning = reasoning.written(),
        .reasoning_details = try details.json(arena),
        .tool_calls = tool_calls,
        .sources = sources.items,
        .usage = usage,
        .finish_reason = finish,
        .model = model,
    };
}

/// `reasoning_details` deltas merged into whole blocks: entries with the same
/// `index` are one block, whose `text`, `summary` and `data` arrive in pieces;
/// other fields (type, signature, format, id) keep their latest value.
const Details = struct {
    blocks: std.ArrayList(Block) = .empty,

    const Block = struct {
        index: ?i64,
        fields: std.json.ObjectMap = .empty,
        text: ?std.Io.Writer.Allocating = null,
        summary: ?std.Io.Writer.Allocating = null,
        data: ?std.Io.Writer.Allocating = null,
    };

    fn merge(self: *Details, arena: std.mem.Allocator, o: std.json.ObjectMap) !void {
        const index: ?i64 = if (o.get("index")) |i| (if (i == .integer) i.integer else null) else null;
        const block = for (self.blocks.items) |*b| {
            if (index != null and b.index == index) break b;
        } else blk: {
            try self.blocks.append(arena, .{ .index = index });
            break :blk &self.blocks.items[self.blocks.items.len - 1];
        };
        var it = o.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const v = e.value_ptr.*;
            if (std.mem.eql(u8, key, "index")) continue;
            const piece: ?*?std.Io.Writer.Allocating = if (std.mem.eql(u8, key, "text"))
                &block.text
            else if (std.mem.eql(u8, key, "summary"))
                &block.summary
            else if (std.mem.eql(u8, key, "data"))
                &block.data
            else
                null;
            if (piece) |w| if (v == .string) {
                if (w.* == null) w.* = .init(arena);
                try w.*.?.writer.writeAll(v.string);
                continue;
            };
            if (v == .null or (v == .string and v.string.len == 0)) continue;
            // Values live in the per-chunk scratch arena: copy them out.
            const copy = try std.json.parseFromSliceLeaky(std.json.Value, arena, try std.json.Stringify.valueAlloc(arena, v, .{}), .{});
            try block.fields.put(arena, try arena.dupe(u8, key), copy);
        }
    }

    /// The merged blocks as a JSON array, or "" when there were none.
    fn json(self: *Details, arena: std.mem.Allocator) ![]const u8 {
        if (self.blocks.items.len == 0) return "";
        var out: std.Io.Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginArray();
        for (self.blocks.items) |*b| {
            try s.beginObject();
            var it = b.fields.iterator();
            while (it.next()) |e| {
                try s.objectField(e.key_ptr.*);
                try s.write(e.value_ptr.*);
            }
            inline for (.{ "text", "summary", "data" }) |key| if (@field(b, key)) |*w| {
                try s.objectField(key);
                try s.write(w.written());
            };
            if (b.index) |i| {
                try s.objectField("index");
                try s.write(i);
            }
            try s.endObject();
        }
        try s.endArray();
        return out.written();
    }
};

const PartialCall = struct { index: i64, id: []const u8, name: []const u8, args: std.Io.Writer.Allocating };

fn mergeToolCall(arena: std.mem.Allocator, calls: *std.ArrayList(PartialCall), o: std.json.ObjectMap) !void {
    const index: i64 = if (o.get("index")) |i| (if (i == .integer) i.integer else 0) else 0;
    const call = for (calls.items) |*c| {
        if (c.index == index) break c;
    } else blk: {
        try calls.append(arena, .{ .index = index, .id = "", .name = "", .args = .init(arena) });
        break :blk &calls.items[calls.items.len - 1];
    };
    if (jsonStr(o.get("id"))) |id| if (id.len > 0) {
        call.id = try arena.dupe(u8, id);
    };
    if (o.get("function")) |f| if (f == .object) {
        if (jsonStr(f.object.get("name"))) |n| if (n.len > 0) {
            call.name = try arena.dupe(u8, n);
        };
        if (jsonStr(f.object.get("arguments"))) |a| try call.args.writer.writeAll(a);
    };
}

fn hasSource(list: []const Source, url: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s.url, url)) return true;
    return false;
}

pub fn parseUsage(u: std.json.ObjectMap) Usage {
    var out: Usage = .{
        .prompt_tokens = jsonInt(u.get("prompt_tokens")),
        .completion_tokens = jsonInt(u.get("completion_tokens")),
        .cost_usd = jsonFloat(u.get("cost")),
    };
    if (u.get("prompt_tokens_details")) |d| if (d == .object) {
        out.cached_tokens = jsonInt(d.object.get("cached_tokens"));
        out.cache_write_tokens = jsonInt(d.object.get("cache_write_tokens"));
    };
    // DeepSeek reports its context-cache hits at the top level of usage.
    if (out.cached_tokens == 0) out.cached_tokens = jsonInt(u.get("prompt_cache_hit_tokens"));
    out.served_model = jsonStr(u.get("served_model")) orelse "";
    if (u.get("by_kind")) |kinds| if (kinds == .array) for (kinds.array.items) |k| {
        if (k != .object or !std.mem.eql(u8, jsonStr(k.object.get("kind")) orelse "", "search")) continue;
        out.search_requests += jsonInt(k.object.get("requests"));
        out.search_cost_usd += jsonFloat(k.object.get("cost"));
    };
    return out;
}

pub fn errorMessage(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return if (raw.len > 0) raw else "upstream error";
    if (v == .object) if (v.object.get("error")) |e| if (jsonString(e, "message")) |m| return m;
    return if (raw.len > 0) raw else "upstream error";
}

pub fn jsonStr(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

pub fn jsonString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    return jsonStr(v.object.get(key));
}

pub fn jsonInt(v: ?std.json.Value) i64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

pub fn jsonFloat(v: ?std.json.Value) f64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

// ------------------------------------------------------------------ test double

/// Serves canned SSE bodies in order, recording each request body.
pub const Fake = struct {
    responses: []const []const u8,
    status: u16 = 200,
    retry_after: ?[]const u8 = null,
    next_index: usize = 0,
    bodies: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,
    models_json: []const u8 = "{\"data\":[]}",

    const Open = struct { reader: std.Io.Reader };

    pub fn upstream(self: *Fake) Upstream {
        return .{ .ptr = self, .vtable = &.{ .post = fakePost, .get = fakeGet } };
    }

    pub fn deinit(self: *Fake) void {
        for (self.bodies.items) |b| self.gpa.free(b);
        self.bodies.deinit(self.gpa);
    }

    fn fakePost(ptr: *anyopaque, cx: Ctx, _: []const u8, body: []const u8, _: []const [2][]const u8) anyerror!Stream {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        try self.bodies.append(self.gpa, try self.gpa.dupe(u8, body));
        const i = @min(self.next_index, self.responses.len - 1);
        self.next_index += 1;
        const open = try cx.arena.create(Open);
        open.reader = .fixed(self.responses[i]);
        return .{ .status = self.status, .reader = &open.reader, .ctx = open, .closeFn = noClose, .retry_after = self.retry_after };
    }

    fn noClose(_: *anyopaque) void {}

    fn fakeGet(ptr: *anyopaque, _: std.Io, arena: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        return arena.dupe(u8, self.models_json);
    }
};

const NoSink = struct {
    fn onDelta(_: NoSink, _: Delta) !void {}
};

test "parseStream merges reasoning_details per block and reads reasoning_content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var reader: std.Io.Reader = .fixed(
        \\data: {"choices":[{"index":0,"delta":{"reasoning_content":"Let me ","reasoning_details":[{"type":"reasoning.text","text":"Let me ","format":"anthropic-claude-v1","index":0}]}}]}
        \\
        \\data: {"choices":[{"index":0,"delta":{"reasoning_content":"think.","reasoning_details":[{"type":"reasoning.text","text":"think.","index":0}]}}]}
        \\
        \\data: {"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.text","signature":"sig==","index":0},{"type":"reasoning.encrypted","data":"AAA","index":1}]}}]}
        \\
        \\data: [DONE]
        \\
        \\
    );
    var err: UpstreamError = .{ .status = 0, .message = "" };
    const r = try parseStream(arena, &reader, NoSink{}, &err);
    try std.testing.expectEqualStrings("Let me think.", r.reasoning);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, r.reasoning_details, .{});
    try std.testing.expectEqual(@as(usize, 2), v.array.items.len);
    const first = v.array.items[0].object;
    try std.testing.expectEqualStrings("Let me think.", first.get("text").?.string);
    try std.testing.expectEqualStrings("sig==", first.get("signature").?.string);
    try std.testing.expectEqualStrings("anthropic-claude-v1", first.get("format").?.string);
    try std.testing.expectEqualStrings("AAA", v.array.items[1].object.get("data").?.string);
}

test "parseUsage reads DeepSeek prompt_cache_hit_tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ds = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"prompt_tokens":100,"completion_tokens":5,"prompt_cache_hit_tokens":80,"prompt_cache_miss_tokens":20}
    , .{});
    try std.testing.expectEqual(@as(i64, 80), parseUsage(ds.object).cached_tokens);
    const oa = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"prompt_tokens":100,"prompt_tokens_details":{"cached_tokens":60},"prompt_cache_hit_tokens":80}
    , .{});
    try std.testing.expectEqual(@as(i64, 60), parseUsage(oa.object).cached_tokens);
}
