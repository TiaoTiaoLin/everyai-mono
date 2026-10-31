//! The model shop: OpenRouter's catalog, refreshed hourly, with prices shown
//! marked up. The response is OpenAI-list shaped (`object: list`, `data[].id`)
//! so OpenAI-compatible clients (OpenHands) can read it too.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const util = @import("util.zig");
const openrouter = @import("openrouter.zig");

/// Added to "My models" on first run (the app seeds its local list from these).
pub const defaults = [_][]const u8{
    "anthropic/claude-haiku-5.5",
    "anthropic/claude-sonnet-5.5",
    "anthropic/claude-opus-5.5",
    "openai/gpt-6.1-sol",
    "openai/gpt-6.1-terra",
    "openai/gpt-5.4-mini",
    "xingchen-agi/xing4.0-29b-a4b:free",
    "dots-studio/dots-3-note-preview:free",
};

/// The Auto model's shop entry (`everyai/auto`, auto.zig). Its prices are
/// 0 but it is not free: each message is billed as the model it ran on.
pub const auto_model: Model = .{
    .id = "everyai/auto",
    .owned_by = "everyai",
    .name = "EveryAI · Auto",
    .provider = "EveryAI",
    .blurb = "Picks the mode and the model for each message: fast, balanced or best, with web search, research or rich answers when they help.",
    .context_length = 1_000_000,
    .input_modalities = &.{ "text", "image", "file" },
    .output_modalities = &.{"text"},
    .prompt_per_mtok = 0,
    .completion_per_mtok = 0,
    .free = false,
    .tools = true,
    .reasoning = true,
    .web_search = true,
    .default = false,
    .created = 0,
};

pub const Model = struct {
    id: []const u8,
    object: []const u8 = "model",
    owned_by: []const u8,
    name: []const u8,
    provider: []const u8,
    blurb: []const u8,
    context_length: i64,
    /// Most output tokens per reply (OpenRouter `top_provider.max_completion_tokens`; 0 = not listed).
    max_output_tokens: i64 = 0,
    input_modalities: []const []const u8,
    output_modalities: []const []const u8,
    /// USD per million tokens, markup included.
    prompt_per_mtok: f64,
    completion_per_mtok: f64,
    free: bool,
    tools: bool,
    reasoning: bool,
    web_search: bool,
    default: bool,
    created: i64,
};

/// Raw upstream prices in USD per token (no markup), for providers that
/// report tokens but not cost (Anthropic's API).
pub const Rates = struct {
    prompt: f64 = 0,
    completion: f64 = 0,
    cache_read: f64 = 0,
    /// 5-minute cache writes.
    cache_write: f64 = 0,
    cache_write_1h: f64 = 0,
};

pub const Prices = struct {
    base: Rates,
    /// Long-context tier: applies from `over_min` prompt tokens.
    over: ?Rates = null,
    over_min: i64 = 0,

    pub const Tokens = struct {
        /// Uncached input.
        input: i64,
        cache_read: i64,
        cache_write_5m: i64,
        cache_write_1h: i64,
        output: i64,
    };

    pub fn cost(self: Prices, t: Tokens) f64 {
        const total_prompt = t.input + t.cache_read + t.cache_write_5m + t.cache_write_1h;
        const r = if (self.over) |o| (if (total_prompt >= self.over_min) o else self.base) else self.base;
        const f = struct {
            fn n(x: i64) f64 {
                return @floatFromInt(x);
            }
        }.n;
        return f(t.input) * r.prompt + f(t.cache_read) * r.cache_read + f(t.cache_write_5m) * r.cache_write +
            f(t.cache_write_1h) * r.cache_write_1h + f(t.output) * r.completion;
    }
};

const ttl_seconds = 3600;

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    arena: ?*std.heap.ArenaAllocator = null,
    models: []const Model = &.{},
    /// Parallel to `models`.
    prices: []const Prices = &.{},
    /// The serialized `/v1/models` body.
    json: []const u8 = "{\"object\":\"list\",\"data\":[]}",
    fetched_at: i64 = 0,
    /// Set while one request refreshes (`ensureFresh`).
    refreshing: std.atomic.Value(bool) = .init(false),
    /// No refresh before this (after a failure).
    retry_at: std.atomic.Value(i64) = .init(0),

    pub fn init(gpa: std.mem.Allocator) Catalog {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Catalog) void {
        if (self.arena) |a| {
            a.deinit();
            self.gpa.destroy(a);
        }
    }

    /// Refetches when older than an hour. A failed fetch keeps the old list.
    /// The wait after a failed refresh.
    const retry_seconds = 60;

    /// Refreshes a stale catalog. One request does it while the others go on
    /// with the copy they have; a failure waits `retry_seconds` before the next
    /// try instead of costing every request an upstream call.
    pub fn ensureFresh(self: *Catalog, up: openrouter.Upstream, io: std.Io, markup: f64) void {
        const now = util.now(io);
        if (now - self.fetched_at < ttl_seconds or now < self.retry_at.load(.monotonic)) return;
        if (self.refreshing.swap(true, .acquire)) return;
        defer self.refreshing.store(false, .release);
        self.refresh(up, io, markup) catch |err| {
            self.retry_at.store(now + retry_seconds, .monotonic);
            std.log.warn("model catalog refresh failed: {t}", .{err});
        };
    }

    pub fn refresh(self: *Catalog, up: openrouter.Upstream, io: std.Io, markup: f64) !void {
        const arena = try self.gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(self.gpa);
        errdefer {
            arena.deinit();
            self.gpa.destroy(arena);
        }
        const a = arena.allocator();
        const raw = try up.get(io, a, "/models");
        const parsed = try parse(a, raw, markup);
        const json = try std.json.Stringify.valueAlloc(a, .{ .object = "list", .data = parsed.models }, .{});

        self.mutex.lockUncancelable(io);
        const old = self.arena;
        self.arena = arena;
        self.models = parsed.models;
        self.prices = parsed.prices;
        self.json = json;
        self.fetched_at = util.now(io);
        self.mutex.unlock(io);
        // Requests copy what they read under the lock, so the old arena is free.
        if (old) |o| {
            o.deinit();
            self.gpa.destroy(o);
        }
    }

    pub fn jsonCopy(self: *Catalog, io: std.Io, arena: std.mem.Allocator) ![]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return arena.dupe(u8, self.json);
    }

    pub const Facts = struct {
        known: bool,
        free: bool,
        tools: bool,
        web_search: bool,
        max_output: i64 = 0,
        reasoning: bool = false,
        inputs: Inputs = .{},

        /// Which attachment kinds the model takes (all, when the catalog doesn't say).
        pub const Inputs = struct { image: bool = true, file: bool = true, audio: bool = true };
    };

    pub fn facts(self: *Catalog, io: std.Io, id: []const u8) Facts {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.models) |m| if (std.mem.eql(u8, m.id, id)) return .{ .known = true, .free = m.free, .tools = m.tools, .web_search = m.web_search, .max_output = m.max_output_tokens, .reasoning = m.reasoning, .inputs = inputsOf(m.input_modalities) };
        // Unknown (catalog not loaded): treat as paid, assume tools.
        return .{ .known = false, .free = std.mem.endsWith(u8, id, ":free"), .tools = true, .web_search = true };
    }

    /// Raw prices for `id`, or null when the catalog doesn't list it.
    pub fn pricesOf(self: *Catalog, io: std.Io, id: []const u8) ?Prices {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.models, self.prices) |m, p| if (std.mem.eql(u8, m.id, id)) return p;
        return null;
    }
};

fn inputsOf(modalities: []const []const u8) Catalog.Facts.Inputs {
    if (modalities.len == 0) return .{};
    var in: Catalog.Facts.Inputs = .{ .image = false, .file = false, .audio = false };
    for (modalities) |m| {
        if (std.mem.eql(u8, m, "image")) in.image = true;
        if (std.mem.eql(u8, m, "file")) in.file = true;
        if (std.mem.eql(u8, m, "audio")) in.audio = true;
    }
    return in;
}

/// The first attachment kind in `content` (a string or OpenAI content parts)
/// that `inputs` does not accept, as the name users know it ("image", "PDF",
/// "audio"); null when everything is accepted.
pub fn unsupportedPart(inputs: Catalog.Facts.Inputs, content: std.json.Value) ?[]const u8 {
    if (content != .array) return null;
    for (content.array.items) |p| if (partUnsupported(inputs, p)) |what| return what;
    return null;
}

/// What kind of attachment the content part `p` is, when the model can't read it.
fn partUnsupported(inputs: Catalog.Facts.Inputs, p: std.json.Value) ?[]const u8 {
    if (p != .object) return null;
    const kind = openrouter.jsonStr(p.object.get("type")) orelse return null;
    if (!inputs.image and std.mem.eql(u8, kind, "image_url")) return "image";
    if (!inputs.file and std.mem.eql(u8, kind, "file")) return "PDF or file";
    if (!inputs.audio and std.mem.eql(u8, kind, "input_audio")) return "audio";
    return null;
}

/// `content` with every part the model can't read swapped for a short text
/// note, for attachments sent in earlier turns (the app resends history, so
/// switching a chat to a text-only model must not fail every later turn).
/// Returns `content` itself when nothing needs dropping.
pub fn dropUnsupported(arena: std.mem.Allocator, inputs: Catalog.Facts.Inputs, content: std.json.Value) !std.json.Value {
    if (unsupportedPart(inputs, content) == null) return content;
    var out: std.json.Array = .init(arena);
    for (content.array.items) |p| {
        if (partUnsupported(inputs, p)) |w| {
            var note: std.json.ObjectMap = .empty;
            try note.put(arena, "type", .{ .string = "text" });
            try note.put(arena, "text", .{ .string = try std.fmt.allocPrint(arena, "[An earlier {s} attachment was left out: this model can't read it.]", .{w}) });
            try out.append(.{ .object = note });
        } else try out.append(p);
    }
    return .{ .array = out };
}

/// 400 text for a rejected attachment.
pub fn unsupportedMessage(arena: std.mem.Allocator, model: []const u8, what: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s} does not accept {s} attachments. Remove them or pick a model that does.", .{ model, what });
}

const Parsed = struct { models: []const Model, prices: []const Prices };

fn ratesOf(o: std.json.ObjectMap) Rates {
    const prompt = priceOf(o.get("prompt"));
    return .{
        .prompt = prompt,
        .completion = priceOf(o.get("completion")),
        // Anthropic's multipliers when OpenRouter lists no cache prices.
        .cache_read = if (o.get("input_cache_read")) |v| priceOf(v) else prompt * 0.1,
        .cache_write = if (o.get("input_cache_write")) |v| priceOf(v) else prompt * 1.25,
        .cache_write_1h = if (o.get("input_cache_write_1h")) |v| priceOf(v) else prompt * 2,
    };
}

fn pricesFrom(pricing: std.json.ObjectMap) Prices {
    var p: Prices = .{ .base = ratesOf(pricing) };
    if (pricing.get("overrides")) |ov| if (ov == .array and ov.array.items.len > 0 and ov.array.items[0] == .object) {
        const o = ov.array.items[0].object;
        p.over = ratesOf(o);
        p.over_min = openrouter.jsonInt(o.get("min_prompt_tokens"));
    };
    return p;
}

fn parse(a: std.mem.Allocator, raw: []const u8, markup: f64) !Parsed {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
    const data = (root.object.get("data") orelse return error.BadCatalog).array.items;
    var out: std.ArrayList(Model) = .empty;
    var prices: std.ArrayList(Prices) = .empty;
    // Ours, first: it runs each message on one of the models below (auto.zig),
    // priced as that model.
    try out.append(a, auto_model);
    try prices.append(a, .{ .base = .{} });
    for (data) |item| {
        const o = item.object;
        const id = openrouter.jsonStr(o.get("id")) orelse continue;
        // Batch variants are not for interactive use.
        if (std.mem.endsWith(u8, id, ":batch")) continue;
        const pricing = if (o.get("pricing")) |p| p.object else continue;
        const prompt = priceOf(pricing.get("prompt"));
        const completion = priceOf(pricing.get("completion"));
        const arch = if (o.get("architecture")) |x| x.object else null;
        const params = if (o.get("supported_parameters")) |p| p.array.items else &.{};
        const slash = std.mem.indexOfScalar(u8, id, '/') orelse 0;
        // "~openai/gpt-latest" is an alias that follows a vendor's newest model.
        const vendor = std.mem.trimStart(u8, id[0..slash], "~");
        var name = openrouter.jsonStr(o.get("name")) orelse id;
        // "Anthropic: Claude Haiku 5.5" -> "Claude Haiku 5.5"
        if (std.mem.indexOf(u8, name, ": ")) |i| name = name[i + 2 ..];
        try out.append(a, .{
            .id = id,
            .owned_by = vendor,
            .name = name,
            .provider = vendor,
            .blurb = try blurbOf(a, openrouter.jsonStr(o.get("description")) orelse ""),
            .context_length = openrouter.jsonInt(o.get("context_length")),
            .max_output_tokens = if (o.get("top_provider")) |t| (if (t == .object) openrouter.jsonInt(t.object.get("max_completion_tokens")) else 0) else 0,
            .input_modalities = try strings(a, if (arch) |x| x.get("input_modalities") else null),
            .output_modalities = try strings(a, if (arch) |x| x.get("output_modalities") else null),
            .prompt_per_mtok = prompt * 1_000_000 * markup,
            .completion_per_mtok = completion * 1_000_000 * markup,
            .free = prompt == 0 and completion == 0,
            .tools = contains(params, "tools"),
            .reasoning = contains(params, "reasoning") or contains(params, "include_reasoning"),
            .web_search = pricing.get("web_search") != null,
            .default = isDefault(id),
            .created = openrouter.jsonInt(o.get("created")),
        });
        try prices.append(a, pricesFrom(pricing));
    }
    return .{ .models = out.items, .prices = prices.items };
}

fn priceOf(v: ?std.json.Value) f64 {
    const x = v orelse return 0;
    return switch (x) {
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => openrouter.jsonFloat(x),
    };
}

fn strings(a: std.mem.Allocator, v: ?std.json.Value) ![]const []const u8 {
    const x = v orelse return &.{};
    if (x != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (x.array.items) |s| if (s == .string) try out.append(a, s.string);
    return out.items;
}

fn contains(items: []const std.json.Value, name: []const u8) bool {
    for (items) |i| if (i == .string and std.mem.eql(u8, i.string, name)) return true;
    return false;
}

fn isDefault(id: []const u8) bool {
    for (defaults) |d| if (std.mem.eql(u8, d, id)) return true;
    return false;
}

/// The description's first sentence; past 160 characters, cut at a word with "…".
fn blurbOf(a: std.mem.Allocator, desc: []const u8) ![]const u8 {
    const sentence = if (std.mem.indexOf(u8, desc, ". ")) |i| desc[0 .. i + 1] else desc;
    if (sentence.len <= 160) return sentence;
    const cut = std.mem.lastIndexOfScalar(u8, sentence[0..160], ' ') orelse 160;
    return std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, sentence[0..cut], " ,;:"), "…" });
}

// ------------------------------------------------------------------ routes

fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    res.content_type = .json;
    res.body = try app.catalog.jsonCopy(req.io, req.arena);
}

fn defaultList(_: *App, _: *anole.Request) struct { models: []const []const u8 } {
    return .{ .models = &defaults };
}

pub fn routes(app: *anole.Server(App), _: *App) void {
    app.get("/v1/models", list);
    app.get("/v1/models/defaults", defaultList);
}

test "attachments the model cannot read are named" {
    const inputs = inputsOf(&.{ "text", "image" });
    const a = std.testing.allocator;
    var img = try std.json.parseFromSlice(std.json.Value, a, "[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:\"}}]", .{});
    defer img.deinit();
    try std.testing.expect(unsupportedPart(inputs, img.value) == null);
    var pdf = try std.json.parseFromSlice(std.json.Value, a, "[{\"type\":\"file\",\"file\":{}}]", .{});
    defer pdf.deinit();
    try std.testing.expectEqualStrings("PDF or file", unsupportedPart(inputs, pdf.value).?);
    var aud = try std.json.parseFromSlice(std.json.Value, a, "[{\"type\":\"input_audio\"}]", .{});
    defer aud.deinit();
    try std.testing.expectEqualStrings("audio", unsupportedPart(inputs, aud.value).?);
    try std.testing.expect(unsupportedPart(inputsOf(&.{"text"}), img.value) != null);
    // A model the catalog says nothing about takes anything; plain strings are fine.
    try std.testing.expect(unsupportedPart(inputsOf(&.{}), pdf.value) == null);
    try std.testing.expect(unsupportedPart(inputsOf(&.{"text"}), .{ .string = "hi" }) == null);
}

test "earlier attachments a model can't read become notes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"type\":\"text\",\"text\":\"see\"},{\"type\":\"file\",\"file\":{}},{\"type\":\"image_url\"}]", .{});
    const text_only = inputsOf(&.{"text"});
    const out = try dropUnsupported(a, text_only, parsed);
    try std.testing.expect(unsupportedPart(text_only, out) == null);
    try std.testing.expectEqual(@as(usize, 3), out.array.items.len);
    try std.testing.expectEqualStrings("see", out.array.items[0].object.get("text").?.string);
    try std.testing.expect(std.mem.indexOf(u8, out.array.items[1].object.get("text").?.string, "PDF or file") != null);
    // A model that reads everything keeps the parts as they were.
    const same = try dropUnsupported(a, inputsOf(&.{ "text", "image", "file" }), parsed);
    try std.testing.expectEqual(parsed.array.items.ptr, same.array.items.ptr);
}
