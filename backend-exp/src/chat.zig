//! POST /v1/chat/stream: one assistant turn over Server-Sent Events.
//!
//! The server runs the tool loop. UI tools (artifacts, SVG, diagrams, charts,
//! quizzes, flashcards, slides) are streamed to the app as `tool` events and
//! acknowledged to the model; server tools (web_fetch, web_search,
//! summarise_parts, generate_image, research) run here. Every upstream call
//! is metered (billing.charge).
//!
//! Client-executed tools: a UI tool the app names in `client_tools` is sent as
//! `tool_wait` instead of `tool`, and the loop waits until the app POSTs
//! `/v1/chat/tool_result {call_id, result, is_error?}` (or the wait times out);
//! the result, not an acknowledgement, goes back to the model. A `tool_status`
//! (done, or failed with detail "timed out") then closes the wait.
//!
//! Events: route {model, mode, tools_enabled} (first, for `everyai/auto`; auto.zig),
//! delta {text}, reasoning {text}, sources {sources} (new ones, appended), tool {id, name,
//! arguments}, tool_wait {id, name, arguments}, tool_status {id, name, status, detail?}, image {id, image_id, mime, data, prompt, revises?},
//! usage {kind: chat|followups, model, tokens..., charged_micros, byok_cost_micros}, followups {questions}, done {},
//! error {message, retryable}.
const std = @import("std");
const byok = @import("byok.zig");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const billing = @import("billing.zig");
const builtin = @import("builtin");
const models = @import("models.zig");
const openrouter = @import("openrouter.zig");
const tools = @import("tools.zig");
const util = @import("util.zig");
const images = @import("images.zig");
const tool_check = @import("tool_check.zig");
const tool_wait = @import("tool_wait.zig");
const truncation = @import("truncation.zig");
const safe_fetch = @import("net/safe_fetch.zig");
const web = @import("web.zig");
const routing = @import("routing.zig");
const modes = @import("modes.zig");
const research = @import("research.zig");
const summarise = @import("summarise.zig");
const auto = @import("auto.zig");

const Events = @typeInfo(@typeInfo(@TypeOf(anole.Response.startEventStream)).@"fn".return_type.?).error_union.payload;

pub const Mode = modes.Mode;

test {
    _ = modes;
}

pub const InMessage = struct {
    role: []const u8,
    /// A string, or OpenAI content parts (`text`, `image_url`, `file`,
    /// `input_audio`) for attachments, passed through to the model.
    content: std.json.Value,
};

/// Index of the newest user message (the one being sent now), or null.
pub fn newestUser(messages: []const InMessage) ?usize {
    var i = messages.len;
    while (i > 0) : (i -= 1) if (std.mem.eql(u8, messages[i - 1].role, "user")) return i - 1;
    return null;
}

pub const ChatRequest = struct {
    model: ?[]const u8 = null,
    mode: Mode = .chat,
    messages: []const InMessage,
    tools_enabled: bool = true,
    /// Client conversation id, for usage attribution.
    session: ?[]const u8 = null,
    /// UI tools the app runs itself and answers via `/v1/chat/tool_result`.
    client_tools: []const []const u8 = &.{},
    /// The conversation's images by id (`img_<n>` generated, `upload_<n>`
    /// attached), for `generate_image` edits and references.
    images: []const ImageRef = &.{},
    /// The user's saved notes (local memory), as the app froze them when the
    /// chat began: the same bytes every turn, sent right after the constant
    /// system prompt so the cached prefix holds.
    memory: ?[]const u8 = null,
    /// The user's skills for this chat (`<skills>`: sorted names and
    /// descriptions, built by the app from its local skill library), loaded
    /// on demand through the client-executed `load_skill`. Sent after the
    /// memory block, so the constant prefix stays cached and the catalog
    /// itself caches while the user's skills don't change.
    skills: ?[]const u8 = null,
    /// How hard a reasoning model thinks; ignored for models without
    /// reasoning, and null leaves the provider's default.
    effort: ?Effort = null,
    /// The language replies and follow-ups must be written in ("French"),
    /// from the app's settings; null or "auto" follows the user's message.
    /// Sent as one line after the memory and skills blocks: it changes only
    /// when the user changes the setting, so the cached prefix holds.
    reply_language: ?[]const u8 = null,
    /// A tool the model must call first (the `/quiz`, `/slides`... commands).
    /// Only the first upstream call of the turn is forced, so the loop goes
    /// on normally after the tool ran. Must name a tool in `tools.definitions`.
    force_tool: ?[]const u8 = null,
    /// Research mode: how far the researchers go (caps in research.zig);
    /// null is Standard, or Quick when the Auto model chose Research.
    research_depth: ?research.Depth = null,
};

pub const Effort = enum {
    low,
    medium,
    high,
    max,

    /// The `reasoning.effort` value for `provider`. Anthropic's own API
    /// (through the adapter) has a "max" level; OpenRouter's top is "xhigh".
    pub fn wire(self: Effort, provider: []const u8) []const u8 {
        if (self == .max and !std.mem.eql(u8, provider, "anthropic")) return "xhigh";
        return @tagName(self);
    }
};

/// The most memory text a request may carry (the app caps its notes far lower).
pub const memory_max = 16 * 1024;

/// The most skill-catalog text a request may carry.
pub const skills_max = 32 * 1024;

pub const ImageRef = struct {
    id: []const u8,
    /// A data: or https: URL; absent when the app left the bytes out.
    url: ?[]const u8 = null,
    /// Instead of `url`: the image is the n-th `image_url` part (from 0) in
    /// `messages`, so attached photos are not sent twice.
    message_image: ?u32 = null,
};

/// A message in the upstream conversation. `raw_tool_calls` is the assistant's
/// tool_calls array as JSON.
const Msg = struct {
    role: []const u8,
    content: []const u8 = "",
    /// Content parts instead of `content` (a message with attachments).
    parts: ?[]const std.json.Value = null,
    tool_call_id: ?[]const u8 = null,
    raw_tool_calls: ?[]const u8 = null,
    /// An assistant step's reasoning, sent back for the rest of the turn's
    /// tool loop (DeepSeek rejects tool loops without it; Anthropic needs its
    /// signed thinking blocks). `reasoning_details` is the structured JSON
    /// array; plain `reasoning` is used when there is none.
    reasoning: []const u8 = "",
    reasoning_details: []const u8 = "",
};

// ------------------------------------------------------------------ prompt caching

/// Providers that need explicit `cache_control` breakpoints. Others (OpenAI,
/// DeepSeek, Grok, ...) cache stable prefixes on their own.
pub fn wantsBreakpoints(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "anthropic/") or std.mem.startsWith(u8, model, "google/gemini");
}

fn writeCacheControl(s: *std.json.Stringify, ttl: []const u8) !void {
    try s.objectField("cache_control");
    try s.beginObject();
    try s.objectField("type");
    try s.write("ephemeral");
    if (std.mem.eql(u8, ttl, "1h")) {
        try s.objectField("ttl");
        try s.write("1h");
    }
    try s.endObject();
}

/// Text content, as a plain string or (with a breakpoint) a one-part array.
/// Parts go through as they are, the breakpoint on the last text part.
fn writeContent(s: *std.json.Stringify, text: []const u8, parts: ?[]const std.json.Value, breakpoint: bool, ttl: []const u8) !void {
    try s.objectField("content");
    if (parts) |list| {
        var mark: ?usize = null;
        if (breakpoint) for (list, 0..) |p, i| {
            if (p == .object and std.mem.eql(u8, openrouter.jsonStr(p.object.get("type")) orelse "", "text")) mark = i;
        };
        try s.beginArray();
        for (list, 0..) |p, i| {
            if (p != .object or mark != i) {
                try s.write(p);
                continue;
            }
            try s.beginObject();
            var it = p.object.iterator();
            while (it.next()) |e| {
                try s.objectField(e.key_ptr.*);
                try s.write(e.value_ptr.*);
            }
            try writeCacheControl(s, ttl);
            try s.endObject();
        }
        return s.endArray();
    }
    if (!breakpoint) return s.write(text);
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(text);
    try writeCacheControl(s, ttl);
    try s.endObject();
    try s.endArray();
}

/// The system message: the base prompt, then the mode's block as a second
/// part. With breakpoints each part gets one, so every mode reuses the base
/// prompt's cache and keeps its own.
fn writeSystem(s: *std.json.Stringify, mode_block: ?[]const u8, breakpoint: bool, ttl: []const u8) !void {
    const extra = mode_block orelse return writeContent(s, tools.system_prompt, null, breakpoint, ttl);
    try s.objectField("content");
    try s.beginArray();
    for ([_][]const u8{ tools.system_prompt, extra }) |text| {
        try s.beginObject();
        try s.objectField("type");
        try s.write("text");
        try s.objectField("text");
        try s.write(text);
        if (breakpoint) try writeCacheControl(s, ttl);
        try s.endObject();
    }
    try s.endArray();
}

/// Per-call knobs that don't change the cached prefix.
const CallOpts = struct {
    /// Output cap; null leaves the provider's default.
    max_tokens: ?i64 = null,
    /// The tools stay defined (the cache prefix and tool history need them)
    /// but the model may not call one.
    no_tool_calls: bool = false,
    /// `reasoning.effort`, already mapped for the route (`Effort.wire`).
    effort: ?[]const u8 = null,
    /// Makes the call use this tool (`tool_choice` names it). Sits after the
    /// tools and system prompt in the body, so the cached prefix is unchanged.
    force_tool: ?[]const u8 = null,
};

/// True when `name` is one of the tools every chat request defines.
pub fn knownTool(name: []const u8) bool {
    var buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"name\":\"{s}\"", .{name}) catch return false;
    return name.len > 0 and std.mem.indexOf(u8, tools.definitions, needle) != null;
}

/// The upstream request body. Prefix order (tools, system, history) never
/// varies, so caches hit; breakpoints go on the system prompt and the last
/// message (the conversation so far, reused by the next turn).
fn buildBody(arena: std.mem.Allocator, model: []const u8, mode: Mode, with_tools: bool, messages: []const Msg, ttl: []const u8, engine: []const u8, opts: CallOpts) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    const bp = wantsBreakpoints(model);

    try s.beginObject();
    try s.objectField("model");
    try s.write(model);
    try s.objectField("stream");
    try s.write(true);
    try s.objectField("usage");
    try s.print("{{\"include\":true}}", .{});
    if (opts.max_tokens) |n| {
        try s.objectField("max_tokens");
        try s.write(n);
    }
    if (opts.effort) |e| {
        try s.objectField("reasoning");
        try s.print("{{\"effort\":\"{s}\"}}", .{e});
    }
    if (with_tools) {
        try s.objectField("tools");
        try s.print("{s}", .{tools.definitions});
        if (opts.no_tool_calls) {
            try s.objectField("tool_choice");
            try s.write("none");
        } else if (opts.force_tool) |name| {
            try s.objectField("tool_choice");
            try s.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\"}}}}", .{name});
        }
    }
    if (modes.usesPlugin(mode, with_tools)) {
        try s.objectField("plugins");
        try s.print("[{{\"id\":\"web\",\"engine\":\"{s}\",\"max_results\":5}}]", .{engine});
    }
    try s.objectField("messages");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("role");
    try s.write("system");
    try writeSystem(&s, modes.block(mode, with_tools), bp, ttl);
    try s.endObject();
    for (messages, 0..) |m, i| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role);
        try writeContent(&s, m.content, m.parts, bp and i == messages.len - 1 and (m.content.len > 0 or m.parts != null), ttl);
        if (m.tool_call_id) |id| {
            try s.objectField("tool_call_id");
            try s.write(id);
        }
        if (m.raw_tool_calls) |raw| {
            try s.objectField("tool_calls");
            try s.print("{s}", .{raw});
        }
        if (m.reasoning_details.len > 0) {
            try s.objectField("reasoning_details");
            try s.print("{s}", .{m.reasoning_details});
        } else if (m.reasoning.len > 0) {
            try s.objectField("reasoning");
            try s.write(m.reasoning);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.written();
}

// ------------------------------------------------------------------ the turn

pub const Sink = struct {
    ev: *Events,
    scratch: *std.Io.Writer.Allocating,
    /// The turn's web sources: numbers citations, and lets only new ones out.
    ledger: *web.Ledger,
    arena: std.mem.Allocator,

    pub fn send(self: Sink, name: []const u8, value: anytype) !void {
        self.scratch.clearRetainingCapacity();
        try std.json.Stringify.value(value, .{}, &self.scratch.writer);
        try self.ev.send(self.scratch.written(), .{ .event = name });
    }

    pub fn onDelta(self: Sink, d: openrouter.Delta) !void {
        switch (d) {
            .text => |t| try self.send("delta", .{ .text = t }),
            .reasoning => |t| try self.send("reasoning", .{ .text = t }),
            .sources => |list| {
                const fresh = try self.ledger.addAll(self.arena, list);
                if (fresh.len > 0) try self.send("sources", .{ .sources = fresh });
            },
        }
    }

    /// The citation number of `source`, without telling the app (web_search
    /// sends its results as one `sources` event first).
    pub fn number(self: Sink, source: openrouter.Source) !usize {
        return (try self.ledger.add(self.arena, source)).n;
    }

    /// The citation number of `source`; the app hears of it the first time.
    pub fn cite(self: Sink, source: openrouter.Source) !usize {
        const e = try self.ledger.add(self.arena, source);
        if (e.new) try self.send("sources", .{ .sources = self.ledger.list.items[e.n - 1 ..][0..1] });
        return e.n;
    }

    /// Keeps the stream alive while a tool waits for the app; ends the wait
    /// when the server starts to drain.
    pub fn heartbeat(self: Sink) !void {
        if (self.ev.draining()) return error.ServerDraining;
        try self.ev.comment("waiting for the app");
    }
};

fn stream(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth.identity(req);
    // bindWith, not bind: content is a string or an array of parts (a
    // std.json.Value, which bind's mapper does not take).
    var body = req.bindWith(ChatRequest, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return res.fail(.unprocessable_entity, "body must be {model?, mode, messages: [{role, content}], tools_enabled, session?}"),
    };
    if (body.messages.len == 0) return req.invalid("messages", "chat.messages_empty", "must not be empty");
    if (body.memory) |m| if (m.len > memory_max) return req.invalid("memory", "chat.memory_too_long", "is too long");
    if (body.skills) |k| if (k.len > skills_max) return req.invalid("skills", "chat.skills_too_long", "is too long");
    if (body.force_tool) |t| if (!knownTool(t)) return req.invalid("force_tool", "chat.unknown_tool", "is not a known tool");
    for (body.messages) |m| if (m.content != .string and m.content != .array)
        return req.invalid("messages", "chat.content_shape", "content must be a string or an array of parts");

    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    // The Auto model: the decider picks the mode, rich answers and the
    // model, and the turn runs as if the app had sent them.
    var picked: ?auto.Pick = null;
    if (body.model) |m| if (std.mem.eql(u8, m, auto.model_id)) {
        const p = try auto.choose(app, req, who, body);
        body.model = p.model;
        if (p.mode == .research and body.mode != .research and body.research_depth == null) body.research_depth = .quick;
        body.mode = p.mode;
        body.tools_enabled = p.tools_enabled;
        picked = p;
    };
    var model = body.model orelse app.cfg.default_model;
    var facts = app.catalog.facts(req.io, model);
    // Research is led by the user's model with tools; one without them hands
    // the question to the deep-research model instead.
    if (body.mode == .research and !(facts.tools and body.tools_enabled)) {
        model = app.cfg.research_model;
        facts = app.catalog.facts(req.io, model);
    }
    // Only the newest user message's attachments are being sent now; earlier
    // ones (resent with the history) become notes when the model can't read them.
    const newest = newestUser(body.messages);
    const msgs = try req.arena.dupe(InMessage, body.messages);
    for (msgs, 0..) |*m, i| {
        if (newest != null and i == newest.?) {
            if (models.unsupportedPart(facts.inputs, m.content)) |what|
                return res.fail(.bad_request, try models.unsupportedMessage(req.arena, model, what));
        } else m.content = try models.dropUnsupported(req.arena, facts.inputs, m.content);
    }
    body.messages = msgs;
    const native_ok = modes.nativeOk(body.mode, body.tools_enabled and facts.tools);
    const on_key = byok.Keys.of(req).covers(model, native_ok);
    // A self-run server without its own key: the user's key or nothing.
    if (app.keyless(on_key, model, native_ok)) {
        res.status = .bad_request;
        return res.json(.{ .message = openrouter.no_key_message, .code = "no_api_key" });
    }
    billing.preflight(app, req, who.user_id, facts.free or on_key) catch {
        res.status = .payment_required;
        return res.json(.{ .message = "You're out of credits. Top up or upgrade your plan to keep using paid models.", .code = "out_of_credits" });
    };

    var buf: [16 * 1024]u8 = undefined;
    var ev = try res.startEventStream(&buf);
    var scratch: std.Io.Writer.Allocating = .init(req.arena);
    var ledger: web.Ledger = .{};
    const sink: Sink = .{ .ev = &ev, .scratch = &scratch, .ledger = &ledger, .arena = req.arena };
    if (picked) |p| {
        // What runs: Research without tools hands over to the research model.
        try sink.send("route", .{ .model = model, .mode = body.mode, .tools_enabled = body.tools_enabled });
        if (p.outcome) |o| try sink.send("usage", .{ .kind = "decide", .model = o.model, .prompt_tokens = o.prompt_tokens, .completion_tokens = o.completion_tokens, .cached_tokens = o.cached_tokens, .cache_write_tokens = 0, .charged_micros = o.charged_micros, .byok_cost_micros = o.byok_cost_micros });
    }

    run(app, req, who, model, body, facts, sink) catch |err| switch (err) {
        error.Upstream, error.OutOfCredits => {}, // already reported
        // A restart: the app retries the turn once the server is back.
        error.ServerDraining => sink.send("error", .{ .message = "The server is restarting. Try again in a moment.", .retryable = true }) catch {},
        else => {
            req.log().err("chat turn failed", .{ .err = @errorName(err) });
            sink.send("error", .{ .message = "Something went wrong while answering.", .retryable = true }) catch {};
        },
    };
    try ev.end();
}

fn run(app: *App, req: *anole.Request, who: auth.Identity, model: []const u8, body: ChatRequest, facts: @import("models.zig").Catalog.Facts, sink: Sink) !void {
    const arena = req.arena;
    var messages: std.ArrayList(Msg) = .empty;
    // Memory goes after the constant system prompt and before the history,
    // as user-role content: the model may have written it (possibly from
    // something it read on the web), so it must not carry system authority.
    if (body.memory) |m| if (std.mem.trim(u8, m, " \t\r\n").len > 0) try messages.append(arena, .{ .role = "user", .content = m });
    // The skill catalog: user content too (a skill may come from anywhere).
    if (body.skills) |k| if (std.mem.trim(u8, k, " \t\r\n").len > 0) try messages.append(arena, .{ .role = "user", .content = k });
    // The user's fixed reply language: one line, stable while the setting is.
    if (routing.fixedLanguage(body.reply_language)) |lang| try messages.append(arena, .{ .role = "user", .content = try routing.replyLanguageLine(arena, lang) });
    for (body.messages) |m| {
        const role = if (std.mem.eql(u8, m.role, "assistant")) "assistant" else "user";
        switch (m.content) {
            .array => |a| try messages.append(arena, .{ .role = role, .parts = a.items }),
            else => try messages.append(arena, .{ .role = role, .content = textOf(m.content) }),
        }
    }
    const with_tools = body.tools_enabled and facts.tools;
    var inquiry: research.State = .{ .depth = body.research_depth orelse .standard };
    var docs: Artifacts = .{};
    for (messages.items) |m| if (std.mem.eql(u8, m.role, "assistant")) try docs.seed(arena, m.content);
    var pictures: ImageBook = .{};
    try pictures.seed(arena, body.images, body.messages);
    var final_text: std.Io.Writer.Allocating = .init(arena);
    // The web plugin (Search without tools) and the Research model need OpenRouter.
    const route = try app.routeFor(req, model, modes.nativeOk(body.mode, with_tools));
    const effort: ?[]const u8 = if (body.effort) |e| (if (facts.reasoning) e.wire(route.provider) else null) else null;
    const turn: Turn = .{ .app = app, .req = req, .who = who, .model = model, .body = body, .route = route, .with_tools = with_tools, .effort = effort };

    var steps: u8 = 0;
    var continuations: u8 = 0;
    var cap: ?i64 = null;
    var out_of_steps = false;
    while (true) {
        // A draining server takes no new upstream call; the turn ends retryable.
        if (sink.ev.draining()) return error.ServerDraining;
        // The first call may be forced to one tool (see ChatRequest.force_tool).
        const wanted: ?[]const u8 = if (with_tools and steps == 0 and continuations == 0) body.force_tool else null;
        const nudge = wanted != null and nudgesTool(model, route.provider, effort);
        const sent = try withToolNudge(arena, messages.items, if (nudge) wanted else null);
        const forced: ?[]const u8 = if (nudge) null else wanted;
        var result = try turn.call(sent, .{ .max_tokens = cap, .force_tool = forced }, sink);

        // A cut-off tool call never runs. Ask again once with room for the
        // whole call; the app keeps what it already got of the reply.
        if (truncation.isLength(result.finish_reason) and result.tool_calls.len > 0) {
            if (truncation.boostedCap(cap orelse result.usage.completion_tokens, facts.max_output)) |bigger| {
                cap = bigger;
                var replay = truncation.Replay(Sink).init(arena, sink, result);
                result = try turn.call(sent, .{ .max_tokens = cap, .force_tool = forced }, &replay);
            }
        }
        const cut_off = truncation.isLength(result.finish_reason);
        try final_text.writer.writeAll(result.text);

        if (result.tool_calls.len == 0) {
            // Research gathered but stopped short of the report: once, ask for it.
            if (inquiry.gathered and !inquiry.reported and !inquiry.nudged and with_tools) {
                inquiry.nudged = true;
                try messages.append(arena, .{ .role = "assistant", .content = result.text, .reasoning = result.reasoning, .reasoning_details = result.reasoning_details });
                try messages.append(arena, .{ .role = "user", .content = research.report_nudge });
                continue;
            }
            // Cut-off text: let the model carry on where it stopped.
            if (cut_off and result.text.len > 0 and continuations < truncation.max_continuations) {
                continuations += 1;
                try messages.append(arena, .{ .role = "assistant", .content = result.text, .reasoning = result.reasoning, .reasoning_details = result.reasoning_details });
                try messages.append(arena, .{ .role = "user", .content = truncation.continue_nudge });
                continue;
            }
            break;
        }

        // The assistant turn with its tool calls, then one result per call.
        // When the reply was cut off, the last call is incomplete: it is
        // answered with an error and kept with empty arguments.
        const calls = result.tool_calls;
        const cut_call: ?usize = if (cut_off) calls.len - 1 else null;
        var kept = calls;
        if (cut_call) |i| {
            const copy = try arena.dupe(openrouter.ToolCall, calls);
            copy[i].arguments = "{}";
            kept = copy;
        }
        try messages.append(arena, .{
            .role = "assistant",
            .content = result.text,
            .raw_tool_calls = try toolCallsJson(arena, kept),
            .reasoning = result.reasoning,
            .reasoning_details = result.reasoning_details,
        });
        for (calls, 0..) |call, i| {
            const output = if (cut_call == i)
                try truncation.notRun(arena, call.name)
            else
                try runTool(app, req, who, body, call, sink, &docs, &pictures, &inquiry);
            try messages.append(arena, .{ .role = "tool", .tool_call_id = call.id, .content = output });
        }
        steps += 1;
        // A model that stopped for another reason than tools is done.
        if (!std.mem.eql(u8, result.finish_reason, "tool_calls") and !cut_off and result.text.len > 0) break;
        // Research needs room for its rounds, the report and its fixes.
        if (steps >= app.cfg.max_tool_steps + @as(u8, if (body.mode == .research) 8 else 0)) {
            out_of_steps = true;
            break;
        }
    }

    // Out of steps with tool results the model hasn't seen: one last call,
    // no tools, for a summary rather than a turn that ends on a tool call.
    if (out_of_steps) {
        try messages.append(arena, .{ .role = "user", .content = truncation.summary_nudge });
        const result = try turn.call(messages.items, .{ .no_tool_calls = true }, sink);
        try final_text.writer.writeAll(result.text);
    }

    if (final_text.written().len > 0) {
        followUps(app, req, who, body, final_text.written(), sink) catch |err| {
            // Test fixtures reuse their last (streamed) reply for this call; its parse error is expected.
            if (!builtin.is_test) req.log().warn("follow-ups failed", .{ .err = @errorName(err) });
        };
    }
    try sink.send("done", .{});
}

/// Whether a forced tool is asked for in words instead of `tool_choice`.
/// Claude's extended thinking refuses a forced tool choice: the native
/// Anthropic adapter drops it, and through OpenRouter it fails whenever an
/// effort turns thinking on.
fn nudgesTool(model: []const u8, provider: []const u8, effort: ?[]const u8) bool {
    if (std.mem.eql(u8, provider, "anthropic")) return true;
    return effort != null and std.mem.startsWith(u8, model, "anthropic/");
}

/// The tool request in words: a final user note naming the tool, sent for
/// this call only and never stored in the history (see `nudgesTool`).
fn withToolNudge(arena: std.mem.Allocator, messages: []const Msg, force: ?[]const u8) ![]const Msg {
    const name = force orelse return messages;
    const out = try arena.alloc(Msg, messages.len + 1);
    @memcpy(out[0..messages.len], messages);
    out[messages.len] = .{ .role = "user", .content = try std.fmt.allocPrint(arena, "(For this request, answer by calling the {s} tool.)", .{name}) };
    return out;
}

/// What every upstream call of one chat turn shares.
const Turn = struct {
    app: *App,
    req: *anole.Request,
    who: auth.Identity,
    model: []const u8,
    body: ChatRequest,
    route: App.Route,
    with_tools: bool,
    /// `reasoning.effort` for every call of the turn, or null.
    effort: ?[]const u8 = null,

    /// One metered completion; deltas go to `deltas`, the rest of the
    /// events to `sink`.
    fn call(self: Turn, messages: []const Msg, opts: CallOpts, deltas: anytype) !openrouter.Result {
        const app = self.app;
        const sink: Sink = switch (@TypeOf(deltas)) {
            Sink => deltas,
            else => deltas.inner,
        };
        var o = opts;
        o.effort = self.effort;
        const request_body = try buildBody(self.req.arena, self.model, self.body.mode, self.with_tools, messages, app.cfg.cache_ttl, app.cfg.search_engine, o);
        var up_err: openrouter.UpstreamError = .{ .status = 0, .message = "" };
        const result = openrouter.complete(self.route.up, openrouter.ctxOf(self.req), self.req.arena, request_body, &.{}, deltas, &up_err) catch |err| switch (err) {
            error.Upstream => {
                try sink.send("error", .{ .message = up_err.message, .retryable = up_err.status == 429 or up_err.status >= 500, .status = up_err.status });
                return err;
            },
            else => return err,
        };
        // Billed as the model that served (a fallback may differ); server-side
        // web searches are their own "search" event.
        const billed = result.usage.billedModel(self.model);
        const c = try billing.charge(app, self.req, self.who.user_id, .{
            .kind = "chat",
            .model = billed,
            .prompt_tokens = result.usage.prompt_tokens,
            .completion_tokens = result.usage.completion_tokens,
            .cached_tokens = result.usage.cached_tokens,
            .cache_write_tokens = result.usage.cache_write_tokens,
            .cost_usd = result.usage.tokenCost(),
            .session = self.body.session,
            .provider = self.route.provider,
            .byok = self.route.byok,
        });
        try sink.send("usage", .{
            .kind = "chat",
            .model = billed,
            .prompt_tokens = result.usage.prompt_tokens,
            .completion_tokens = result.usage.completion_tokens,
            .cached_tokens = result.usage.cached_tokens,
            .cache_write_tokens = result.usage.cache_write_tokens,
            .charged_micros = c.charged_micros,
            .byok_cost_micros = billing.ownKeyCost(c, self.route.byok),
        });
        if (result.usage.search_cost_usd > 0) {
            const sc = try billing.charge(app, self.req, self.who.user_id, .{ .kind = "search", .model = billed, .cost_usd = result.usage.search_cost_usd, .session = self.body.session, .provider = self.route.provider, .byok = self.route.byok });
            try sink.send("usage", .{ .kind = "search", .model = billed, .prompt_tokens = 0, .completion_tokens = 0, .cached_tokens = 0, .cache_write_tokens = 0, .charged_micros = sc.charged_micros, .byok_cost_micros = billing.ownKeyCost(sc, self.route.byok) });
        }
        return result;
    }
};

/// The latest content of each artifact in the conversation: seeded from the
/// `<artifact id="…">` blocks the app puts in earlier assistant turns, then
/// kept current by this turn's create/update/edit calls.
const Artifacts = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    const Edited = struct { applied: usize, message: []const u8 };

    fn seed(self: *Artifacts, arena: std.mem.Allocator, text: []const u8) !void {
        const open = "<artifact id=\"";
        var rest = text;
        while (std.mem.indexOf(u8, rest, open)) |at| {
            rest = rest[at + open.len ..];
            const id_end = std.mem.indexOfScalar(u8, rest, '"') orelse return;
            const id = rest[0..id_end];
            const body_start = (std.mem.indexOf(u8, rest, ">\n") orelse return) + 2;
            const close = std.mem.indexOf(u8, rest[body_start..], "\n</artifact>") orelse return;
            try self.map.put(arena, id, rest[body_start..][0..close]);
            rest = rest[body_start + close ..];
        }
    }

    /// Records create/update; applies an edit and describes the outcome
    /// (null for every other tool).
    fn track(self: *Artifacts, arena: std.mem.Allocator, tool: []const u8, args: std.json.Value) !?Edited {
        const id = openrouter.jsonString(args, "id") orelse return null;
        if (std.mem.eql(u8, tool, "create_artifact") or std.mem.eql(u8, tool, "update_artifact")) {
            if (openrouter.jsonString(args, "content")) |c| try self.map.put(arena, id, c);
            return null;
        }
        if (!std.mem.eql(u8, tool, "edit_artifact")) return null;
        var content = self.map.get(id) orelse return .{
            .applied = 0,
            .message = try std.fmt.allocPrint(arena, "Error: there is no artifact \"{s}\" in this chat. Use create_artifact.", .{id}),
        };
        const edits = if (args == .object) args.object.get("edits") else null;
        const list = if (edits) |e| (if (e == .array) e.array.items else &.{}) else &.{};
        var applied: usize = 0;
        var missed: std.Io.Writer.Allocating = .init(arena);
        for (list) |e| {
            const old = openrouter.jsonString(e, "old_text") orelse continue;
            const new = openrouter.jsonString(e, "new_text") orelse "";
            const at = if (old.len == 0) null else std.mem.indexOf(u8, content, old);
            if (at) |i| {
                content = try std.mem.concat(arena, u8, &.{ content[0..i], new, content[i + old.len ..] });
                applied += 1;
            } else {
                try missed.writer.print("\n- old_text not found: {s}", .{old[0..@min(old.len, 120)]});
            }
        }
        try self.map.put(arena, id, content);
        const message = if (missed.written().len == 0)
            try std.fmt.allocPrint(arena, "Edited \"{s}\": {d} edit(s) applied; shown to the user.", .{ id, applied })
        else
            try std.fmt.allocPrint(arena, "Edited \"{s}\": {d} of {d} edit(s) applied; these did not match the current content exactly (copy old_text verbatim from the latest version and retry them):{s}", .{ id, applied, list.len, missed.written() });
        return .{ .applied = applied, .message = message };
    }
};

test "artifacts: seed from history, edit, report misses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var docs: Artifacts = .{};
    try docs.seed(a, "Here it is.\n\n<artifact id=\"notes\" kind=\"markdown\" title=\"Notes\">\n# Title\nold line\n</artifact>");
    try std.testing.expectEqualStrings("# Title\nold line", docs.map.get("notes").?);
    const args = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"id":"notes","edits":[{"old_text":"old line","new_text":"new line"},{"old_text":"missing","new_text":"x"}]}
    , .{});
    const e = (try docs.track(a, "edit_artifact", args)).?;
    try std.testing.expectEqual(@as(usize, 1), e.applied);
    try std.testing.expect(std.mem.indexOf(u8, e.message, "1 of 2") != null);
    try std.testing.expectEqualStrings("# Title\nnew line", docs.map.get("notes").?);
    const unknown = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"id":"nope","edits":[]}
    , .{});
    try std.testing.expectEqual(@as(usize, 0), (try docs.track(a, "edit_artifact", unknown)).?.applied);
}

/// What is wrong with the ```chart blocks in `content` (each must be a JSON
/// object with `series`, like render_chart's arguments); null when nothing is.
fn chartProblems(arena: std.mem.Allocator, content: []const u8) !?[]const u8 {
    const fence = "```chart";
    var out: std.Io.Writer.Allocating = .init(arena);
    var rest = content;
    var n: usize = 0;
    while (std.mem.indexOf(u8, rest, fence)) |at| {
        rest = rest[at + fence.len ..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
        // ```chart must be the whole info string (not ```charts or ```chart.js).
        if (std.mem.trim(u8, rest[0..line_end], " \t\r").len > 0) continue;
        n += 1;
        rest = rest[line_end + 1 ..];
        const end = std.mem.indexOf(u8, rest, "```") orelse rest.len;
        const block = rest[0..end];
        rest = rest[end..];
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, block, .{}) catch {
            try out.writer.print("\n- chart {d}: not valid JSON", .{n});
            continue;
        };
        const series = if (value == .object) value.object.get("series") else null;
        if (series == null or series.? != .array or series.?.array.items.len == 0)
            try out.writer.print("\n- chart {d}: needs a JSON object with a non-empty series list", .{n});
    }
    if (out.written().len == 0) return null;
    return try std.fmt.allocPrint(arena, "Note: the app shows these ```chart blocks as plain code. Fix them with edit_artifact; each holds the same JSON object as render_chart's arguments:{s}", .{out.written()});
}

test "chart blocks in a document are checked" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = "# R\n```chart\n{\"type\":\"bar\",\"series\":[{\"name\":\"a\",\"points\":[{\"x\":\"q\",\"y\":1}]}]}\n```\n";
    try std.testing.expect(try chartProblems(a, good) == null);
    try std.testing.expect(try chartProblems(a, "```chart.js\nnot json\n```") == null);
    const bad = try chartProblems(a, good ++ "```chart\n{\"type\":\"bar\"\n```\n```chart\n{\"type\":\"pie\"}\n```");
    try std.testing.expect(std.mem.indexOf(u8, bad.?, "chart 2: not valid JSON") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad.?, "chart 3: needs") != null);
}

/// The text of a message's content: the string, or its text parts joined.
fn textOf(content: std.json.Value) []const u8 {
    return switch (content) {
        .string => |t| t,
        .array => |a| blk: {
            // The app puts the typed text last, after attachments.
            var i = a.items.len;
            while (i > 0) {
                i -= 1;
                const p = a.items[i];
                if (p == .object and std.mem.eql(u8, openrouter.jsonStr(p.object.get("type")) orelse "", "text"))
                    break :blk openrouter.jsonStr(p.object.get("text")) orelse "";
            }
            break :blk "";
        },
        else => "",
    };
}

fn toolCallsJson(arena: std.mem.Allocator, calls: []const openrouter.ToolCall) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginArray();
    for (calls) |c| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(c.id);
        try s.objectField("type");
        try s.write("function");
        try s.objectField("function");
        try s.beginObject();
        try s.objectField("name");
        try s.write(c.name);
        try s.objectField("arguments");
        try s.write(if (c.arguments.len == 0) "{}" else c.arguments);
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
    return out.written();
}

/// Runs or forwards one tool call; returns the text the model sees.
fn runTool(app: *App, req: *anole.Request, who: auth.Identity, body: ChatRequest, call: openrouter.ToolCall, sink: Sink, docs: *Artifacts, pictures: *ImageBook, inquiry: *research.State) ![]const u8 {
    const session = body.session;
    const args_text = if (call.arguments.len == 0) "{}" else call.arguments;
    const args = std.json.parseFromSliceLeaky(std.json.Value, req.arena, args_text, .{}) catch {
        return "Error: the tool arguments were not valid JSON. Call the tool again with valid JSON.";
    };
    const kind = tools.kindOf(call.name) orelse return "Error: unknown tool.";
    // Arguments that break the schema never reach the app or the upstream;
    // the model gets each problem by path and calls again.
    if (try tool_check.check(req.arena, call.name, args)) |problem| return problem;
    switch (kind) {
        .ui => {
            // Research: the report waits for the researchers.
            if (body.mode == .research and std.mem.eql(u8, call.name, "create_artifact") and !inquiry.gathered)
                return research.report_too_early;
            // An edit is checked here first, so the model learns about misses.
            const edited = try docs.track(req.arena, call.name, args);
            if (edited) |e| if (e.applied == 0) return e.message;
            if (declared(body.client_tools, call.name)) return waitForApp(app, req, who, call, args, sink);
            if (tools.clientOnly(call.name))
                return std.fmt.allocPrint(req.arena, "Error: {s} is turned off in the user's app. Carry on without it.", .{call.name});
            try sink.send("tool", .{ .id = call.id, .name = call.name, .arguments = args });
            const shown = if (edited) |e| e.message else try tool_check.shown(req.arena, call.name, args);
            // Charts inside a document the app can't draw: the model fixes them.
            const id = openrouter.jsonString(args, "id") orelse "";
            if (!std.mem.endsWith(u8, call.name, "_artifact")) return shown;
            const content = docs.map.get(id) orelse return shown;
            if (body.mode == .research and inquiry.gathered and std.mem.eql(u8, call.name, "create_artifact")) inquiry.reported = true;
            var notes: std.Io.Writer.Allocating = .init(req.arena);
            if (try chartProblems(req.arena, content)) |note| try notes.writer.print("\n{s}", .{note});
            // Citations are checked against this turn's sources, when it gathered any.
            if (inquiry.gathered) if (try research.citationProblems(req.arena, content, sink.ledger.list.items.len)) |note|
                try notes.writer.print("\n{s}", .{note});
            return std.mem.concat(req.arena, u8, &.{ shown, notes.written() });
        },
        .server => {
            try sink.send("tool_status", .{ .id = call.id, .name = call.name, .status = "running", .detail = openrouter.jsonString(args, "url") orelse openrouter.jsonString(args, "query") orelse openrouter.jsonString(args, "prompt") });
            const output = (if (std.mem.eql(u8, call.name, "research"))
                (if (body.mode == .research)
                    research.run(app, req, who, session, call.id, args, sink, inquiry, try app.aux(req))
                else
                    @as(anyerror![]const u8, "Error: research runs only in Research mode. Use web_search and web_fetch here, or offer the switch with suggest_mode."))
            else if (std.mem.eql(u8, call.name, "web_fetch"))
                webFetch(app, req, args, sink)
            else if (std.mem.eql(u8, call.name, "web_search"))
                webSearch(app, req, who, session, args, sink, try app.aux(req))
            else if (std.mem.eql(u8, call.name, "summarise_parts"))
                summarise.run(app, req, who, session, call.id, args, sink, try app.aux(req))
            else
                generateImage(app, req, who, session, call.id, args, sink, pictures)) catch |err| blk: {
                break :blk try std.fmt.allocPrint(req.arena, "Error: {t}", .{err});
            };
            try sink.send("tool_status", .{ .id = call.id, .name = call.name, .status = if (std.mem.startsWith(u8, output, "Error")) "failed" else "done" });
            return output;
        },
    }
}

fn declared(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The most of an app's answer the model sees.
const app_result_max = 100_000;

/// Hands a call to the app (`tool_wait`) and returns its answer for the model:
/// the result, an "Error: …" the app reported, or a typed timeout.
fn waitForApp(app: *App, req: *anole.Request, who: auth.Identity, call: openrouter.ToolCall, args: std.json.Value, sink: Sink) ![]const u8 {
    var w: tool_wait.Waiter = .{ .user_id = who.user_id, .call_id = call.id };
    // Linked before the app hears of it, so a quick answer finds it.
    app.waits.add(req.io, &w);
    sink.send("tool_wait", .{ .id = call.id, .name = call.name, .arguments = args }) catch |err| {
        app.waits.drop(req.io, app.gpa, &w);
        return err;
    };
    const timeout_ms = app.cfg.client_tool_timeout_ms;
    const outcome = try app.waits.wait(req.io, app.gpa, req.arena, &w, .fromMilliseconds(timeout_ms), .fromSeconds(15), sink);
    switch (outcome) {
        .timeout => {
            try sink.send("tool_status", .{ .id = call.id, .name = call.name, .status = "failed", .detail = "timed out" });
            return std.fmt.allocPrint(req.arena, "Error (timeout): the app did not answer this {s} call within {d} s. Carry on without its result.", .{ call.name, timeout_ms / 1000 });
        },
        .answered => |a| {
            try sink.send("tool_status", .{ .id = call.id, .name = call.name, .status = if (a.is_error) "failed" else "done" });
            const text = if (a.text.len > app_result_max)
                try std.mem.concat(req.arena, u8, &.{ a.text[0..app_result_max], "\n[truncated]" })
            else
                a.text;
            if (!a.is_error) return if (text.len == 0) "Done." else text;
            if (std.mem.startsWith(u8, text, "Error")) return text;
            return std.mem.concat(req.arena, u8, &.{ "Error: ", if (text.len == 0) "the app could not run this tool." else text });
        },
    }
}

const ToolResultBody = struct {
    call_id: []const u8,
    /// A string, or any JSON (sent to the model as JSON text).
    result: std.json.Value = .null,
    /// The app could not run the tool; `result` says why.
    is_error: bool = false,
};

/// POST /v1/chat/tool_result: the app's answer to a `tool_wait`.
fn toolResult(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth.identity(req);
    // `result` is any JSON (a std.json.Value): bindWith, as in `stream`.
    const body = req.bindWith(ToolResultBody, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return res.fail(.unprocessable_entity, "body must be {call_id, result, is_error?}"),
    };
    const text = switch (body.result) {
        .string => |t| t,
        .null => "",
        else => try std.json.Stringify.valueAlloc(req.arena, body.result, .{}),
    };
    if (!try app.waits.resolve(req.io, app.gpa, who.user_id, body.call_id, text, body.is_error))
        return res.fail(.not_found, "no chat turn is waiting for this call (it finished or timed out)");
    return res.json(.{ .ok = true });
}

/// One window of the page's readable text (tags, scripts and styles removed,
/// whitespace collapsed), fenced as untrusted, then the page's citation number
/// and, when the text goes on, `next_offset` for the next window. The fetch
/// goes through `safe_fetch`: no local or private addresses, every redirect
/// hop checked again, the body capped.
/// `req` is the request, or a task's own `*anole.db.Ctx` (research.zig).
pub fn webFetch(app: *App, req: anytype, args: std.json.Value, sink: anytype) ![]const u8 {
    const fetcher = app.web orelse return "Error: web_fetch is not available here.";
    const url = std.mem.trim(u8, openrouter.jsonString(args, "url") orelse "", " \t\r\n");
    const offset: usize = @intCast(@max(0, intArg(args, "offset") orelse 0));
    const limit: usize = @intCast(std.math.clamp(intArg(args, "max_chars") orelse web.default_chars, web.min_chars, web.max_chars));
    var diag: safe_fetch.Diagnostics = .{};
    const page = fetcher.get(req.io, req.arena, url, "text/html,text/plain,application/xhtml+xml,*/*;q=0.5", &diag) catch |err|
        return std.fmt.allocPrint(req.arena, "Error: {s}.", .{try safe_fetch.reason(req.arena, err, diag)});
    if (page.status >= 400) return std.fmt.allocPrint(req.arena, "Error: HTTP {d}", .{page.status});
    if (!textual(page.content_type)) return std.fmt.allocPrint(req.arena, "Error: the URL is not a web page ({s}); web_fetch reads text only.", .{page.content_type});
    const text = try readableText(req.arena, page.body, page.body.len);
    if (offset > 0 and offset >= text.len)
        return std.fmt.allocPrint(req.arena, "Error: offset {d} is past the end of the page ({d} characters).", .{ offset, text.len });
    const n = try sink.cite(.{
        .url = page.url,
        .title = (try web.titleOf(req.arena, page.body)) orelse page.url,
        .snippet = if (text.len > 0) web.clip(text, 300) else null,
    });
    const w = web.window(text, offset, limit);
    const fenced = try safe_fetch.wrapUntrusted(req.arena, page.url, w.text);
    const note = if (page.notice) |line| try std.mem.concat(req.arena, u8, &.{ line, "\n" }) else "";
    return std.mem.concat(req.arena, u8, &.{ note, fenced, "\n", try web.pagingNote(req.arena, n, w) });
}

fn intArg(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @intFromFloat(f) else null,
        else => null,
    };
}

/// `web_search`: OpenRouter's web plugin (the Search mode's engine) on the
/// utility model, metered like any call. The results join the turn's source
/// ledger, so the model cites the numbers it is given and the app gets them
/// as `sources`.
/// `req` is the request, or a task's own `*anole.db.Ctx` (research.zig).
/// `aux` is where side calls go (`App.aux`): the user's OpenRouter key or ours.
pub fn webSearch(app: *App, req: anytype, who: auth.Identity, session: ?[]const u8, args: std.json.Value, sink: anytype, aux: App.Route) ![]const u8 {
    const arena = req.arena;
    const query = std.mem.trim(u8, openrouter.jsonString(args, "query") orelse "", " \t\r\n");
    if (query.len == 0) return "Error: query is empty.";
    const limit: usize = @intCast(std.math.clamp(intArg(args, "max_results") orelse web.default_results, 1, web.max_results));
    // The web plugin bills per search even on a free model, so a search
    // needs credit even when the chat model is free.
    billing.preflight(app, req, who.user_id, aux.byok) catch |err| switch (err) {
        error.PaymentRequired => return "Error: the user is out of credits, so web_search is unavailable. Answer without it and say so if it matters.",
        else => return err,
    };
    // The same query in the same chat: the earlier results, free.
    const key = try web.SearchCache.key(arena, who.user_id, session, query, limit);
    const now = util.now(req.io);
    const cached = if (key) |k| try app.searches.get(req.io, arena, k, now) else null;
    const sources = cached orelse blk: {
        const body = try web.searchBody(arena, app.cfg.utility_model, app.cfg.search_engine, query, limit);
        const s = try aux.up.post(openrouter.ctxOf(req), "/chat/completions", body, &.{});
        defer s.close();
        const raw = try s.reader.allocRemaining(arena, .limited(1024 * 1024));
        if (s.status >= 300) return std.fmt.allocPrint(arena, "Error: the search failed ({s}). Try again or carry on without it.", .{openrouter.errorMessage(arena, raw)});
        const reply = web.parseSearch(arena, raw) catch return "Error: the search service sent an unreadable reply. Try again or carry on without it.";
        if (reply.usage) |u| {
            const c = try billing.charge(app, req, who.user_id, .{ .kind = "search", .model = app.cfg.utility_model, .prompt_tokens = u.prompt_tokens, .completion_tokens = u.completion_tokens, .cost_usd = u.cost_usd, .session = session, .byok = aux.byok });
            // Costs money; does not fill the conversation's context.
            try sink.send("usage", .{ .kind = "search", .model = app.cfg.utility_model, .prompt_tokens = u.prompt_tokens, .completion_tokens = u.completion_tokens, .cached_tokens = 0, .cache_write_tokens = 0, .charged_micros = c.charged_micros, .byok_cost_micros = billing.ownKeyCost(c, aux.byok) });
        }
        if (key) |k| if (reply.sources.len > 0) try app.searches.put(req.io, app.gpa, k, reply.sources, now);
        break :blk reply.sources;
    };
    // One `sources` event for the new results, then each one's number.
    try sink.onDelta(.{ .sources = sources });
    const numbered = try arena.alloc(web.Numbered, sources.len);
    for (sources, numbered) |src, *out| out.* = .{ .n = try sink.number(src), .source = src };
    return web.formatResults(arena, query, numbered, cached != null);
}

/// Content types `readableText` makes sense of; an absent one is tried.
pub fn textual(content_type: []const u8) bool {
    const ct = std.mem.trim(u8, content_type, " ");
    if (ct.len == 0) return true;
    inline for (.{ "text/", "application/xhtml", "application/xml", "application/json", "application/ld+json", "application/rss", "application/atom" }) |p| {
        if (ct.len >= p.len and std.ascii.eqlIgnoreCase(ct[0..p.len], p)) return true;
    }
    return false;
}

pub fn readableText(arena: std.mem.Allocator, html: []const u8, limit: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var space = true;
    while (i < html.len and out.items.len < limit) {
        const c = html[i];
        if (c == '<') {
            const rest = html[i..];
            inline for (.{ "script", "style", "noscript", "svg" }) |tag| {
                if (rest.len > tag.len + 1 and std.ascii.eqlIgnoreCase(rest[1 .. tag.len + 1], tag)) {
                    const close = "</" ++ tag;
                    if (indexOfIgnoreCase(rest, close)) |end| {
                        i += end + close.len;
                        break;
                    }
                }
            }
            const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            i = gt + 1;
            if (!space) {
                try out.append(arena, ' ');
                space = true;
            }
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            if (!space) try out.append(arena, ' ');
            space = true;
        } else {
            try out.append(arena, c);
            space = false;
        }
        i += 1;
    }
    return std.mem.trim(u8, out.items, " ");
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// The conversation's images by id: what the app sent (`ChatRequest.images`)
/// plus what this turn generated, so a later call can edit them.
const ImageBook = struct {
    /// id → data: or https: URL (null: known, but the app left the bytes out).
    map: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty,
    /// Number for the next generated image (`img_<next>`).
    next: u32 = 1,

    fn seed(self: *ImageBook, arena: std.mem.Allocator, refs: []const ImageRef, messages: []const InMessage) !void {
        var in_messages: std.ArrayList([]const u8) = .empty;
        for (messages) |m| if (m.content == .array) for (m.content.array.items) |p| {
            if (p != .object or !std.mem.eql(u8, openrouter.jsonStr(p.object.get("type")) orelse "", "image_url")) continue;
            const iu = p.object.get("image_url") orelse continue;
            if (openrouter.jsonString(iu, "url")) |u| try in_messages.append(arena, u);
        };
        for (refs) |r| {
            const from_messages = if (r.message_image) |n| (if (n < in_messages.items.len) in_messages.items[n] else null) else null;
            try self.map.put(arena, r.id, r.url orelse from_messages);
            if (numberOf(r.id)) |n| self.next = @max(self.next, n + 1);
        }
    }

    fn numberOf(id: []const u8) ?u32 {
        if (!std.mem.startsWith(u8, id, "img_")) return null;
        return std.fmt.parseInt(u32, id[4..], 10) catch null;
    }

    /// Records a generated image; returns its new id.
    fn add(self: *ImageBook, arena: std.mem.Allocator, img: images.Image) ![]const u8 {
        const id = try std.fmt.allocPrint(arena, "img_{d}", .{self.next});
        self.next += 1;
        try self.map.put(arena, id, try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ img.mime, img.data }));
        return id;
    }

    /// The URLs of `ids`, or the error text for the model.
    fn resolve(self: *const ImageBook, arena: std.mem.Allocator, ids: []const []const u8) !union(enum) { urls: []const []const u8, problem: []const u8 } {
        var urls: std.ArrayList([]const u8) = .empty;
        for (ids) |id| {
            const entry = self.map.get(id) orelse {
                var known: std.Io.Writer.Allocating = .init(arena);
                for (self.map.keys(), 0..) |k, i| try known.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", k });
                return .{ .problem = try std.fmt.allocPrint(arena, "Error: there is no image \"{s}\" in this chat. Known images: {s}.", .{ id, if (known.written().len == 0) "none" else known.written() }) };
            };
            const url = entry orelse return .{ .problem = try std.fmt.allocPrint(arena, "Error: image \"{s}\" is too old or too large to use as a reference here; describe it in the prompt instead.", .{id}) };
            try urls.append(arena, url);
        }
        return .{ .urls = urls.items };
    }
};

/// The image ids a generate_image call refers to: `edit_of` first, then
/// `references`, without repeats.
fn referencedIds(arena: std.mem.Allocator, args: std.json.Value) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    if (openrouter.jsonString(args, "edit_of")) |id| if (id.len > 0) try ids.append(arena, id);
    const refs = if (args == .object) args.object.get("references") else null;
    if (refs) |r| if (r == .array) for (r.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        for (ids.items) |seen| {
            if (std.mem.eql(u8, seen, item.string)) break;
        } else try ids.append(arena, item.string);
    };
    return ids.items;
}

/// Calls the image model; streams the image to the app as an `image` event
/// {id, image_id, mime, data, prompt, revises?}. An edit of a generated image
/// (`edit_of: "img_…"`) is its next version in the app.
fn generateImage(app: *App, req: *anole.Request, who: auth.Identity, session: ?[]const u8, id: []const u8, args: std.json.Value, sink: Sink, pictures: *ImageBook) ![]const u8 {
    const arena = req.arena;
    const prompt = openrouter.jsonString(args, "prompt") orelse return error.MissingPrompt;
    const vector = std.mem.eql(u8, openrouter.jsonString(args, "engine") orelse "", "vector");
    const refs = switch (try pictures.resolve(arena, try referencedIds(arena, args))) {
        .problem => |p| return p,
        .urls => |u| u,
    };
    var message: []const u8 = "the image model returned no image";
    const list = images.generate(app, req, who, session, .{
        .model = if (vector) app.cfg.vector_model else app.cfg.image_model,
        .prompt = prompt,
        .aspect_ratio = openrouter.jsonString(args, "aspect_ratio") orelse "1:1",
        .output_format = if (vector) "svg" else null,
        .references = refs,
    }, &message) catch |err| switch (err) {
        error.UpstreamFailed, error.NoImage => return std.fmt.allocPrint(arena, "Error: {s}.", .{message}),
        error.PaymentRequired => return "Error: the user does not have enough credit left to generate an image. Say so and carry on without it.",
        else => return err,
    };
    const img = list[0];
    const image_id = try pictures.add(arena, img);
    const edit_of = openrouter.jsonString(args, "edit_of");
    const revises = if (edit_of) |e| (if (ImageBook.numberOf(e) != null) e else null) else null;
    try sink.send("image", .{ .id = id, .image_id = image_id, .mime = img.mime, .data = img.data, .prompt = prompt, .revises = revises });
    const what = if (std.mem.eql(u8, img.mime, "image/svg+xml")) "an SVG illustration" else "an image";
    return std.fmt.allocPrint(arena, "Generated {s}, {s}, and showed it to the user. Use the id {s} to edit it or as a reference.", .{ what, image_id, image_id });
}

test "image book: ids continue from the app's, references resolve, unknown ids are named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var book: ImageBook = .{};
    try book.seed(a, &.{ .{ .id = "upload_1", .url = "data:image/png;base64,AA" }, .{ .id = "img_4" }, .{ .id = "img_2", .url = "https://x/y.png" } }, &.{});
    try std.testing.expectEqualStrings("img_5", try book.add(a, .{ .mime = "image/png", .data = "BB" }));
    const args = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"prompt":"p","edit_of":"img_5","references":["upload_1","img_5",""]}
    , .{});
    const ids = try referencedIds(a, args);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    const ok = try book.resolve(a, ids);
    try std.testing.expectEqualStrings("data:image/png;base64,BB", ok.urls[0]);
    try std.testing.expectEqualStrings("data:image/png;base64,AA", ok.urls[1]);
    const old = try book.resolve(a, &.{"img_4"});
    try std.testing.expect(std.mem.indexOf(u8, old.problem, "too old") != null);
    const missing = try book.resolve(a, &.{"img_9"});
    try std.testing.expect(std.mem.indexOf(u8, missing.problem, "Known images: upload_1, img_4, img_2, img_5") != null);
}

test "image book: attached images resolve from the message parts they came in" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[{"type":"image_url","image_url":{"url":"data:image/png;base64,P0"}},{"type":"text","text":"hi"},
        \\ {"type":"image_url","image_url":{"url":"data:image/png;base64,P1"}}]
    , .{});
    var book: ImageBook = .{};
    try book.seed(a, &.{ .{ .id = "upload_1", .message_image = 1 }, .{ .id = "upload_2", .message_image = 7 } }, &.{
        .{ .role = "user", .content = .{ .string = "text only" } },
        .{ .role = "user", .content = content },
    });
    try std.testing.expectEqualStrings("data:image/png;base64,P1", (try book.resolve(a, &.{"upload_1"})).urls[0]);
    try std.testing.expect(std.mem.indexOf(u8, (try book.resolve(a, &.{"upload_2"})).problem, "too old") != null);
}

/// Three short follow-up questions from the utility model.
fn followUps(app: *App, req: *anole.Request, who: auth.Identity, body: ChatRequest, answer: []const u8, sink: Sink) !void {
    const question = textOf(body.messages[body.messages.len - 1].content);
    const prompt = try std.fmt.allocPrint(req.arena,
        \\Question: {s}
        \\
        \\Answer (excerpt): {s}
        \\
        \\Suggest 3 short follow-up questions the user is likely to ask next. {s}
        \\Reply with only a JSON array of 3 strings.
    , .{ question[0..@min(question.len, 2000)], answer[0..@min(answer.len, 3000)], try routing.followUpLanguage(req.arena, body.reply_language, question) });
    const model = routing.modelFor(app.cfg, .followups);
    const aux = try app.aux(req);
    // Follow-ups are extra; a free-model turn with no credit left skips them.
    billing.preflight(app, req, who.user_id, app.catalog.facts(req.io, model).free or aux.byok) catch |err| switch (err) {
        error.PaymentRequired => return,
        else => return err,
    };
    const req_body = try std.json.Stringify.valueAlloc(req.arena, .{
        .model = model,
        .usage = .{ .include = true },
        .max_tokens = 200,
        .messages = .{.{ .role = "user", .content = prompt }},
    }, .{});
    const s = try aux.up.post(openrouter.ctxOf(req), "/chat/completions", req_body, &.{});
    defer s.close();
    const raw = try s.reader.allocRemaining(req.arena, .limited(1024 * 1024));
    if (s.status >= 300) return error.UpstreamFailed;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, req.arena, raw, .{});
    if (v.object.get("usage")) |u| if (u == .object) {
        const usage = openrouter.parseUsage(u.object);
        const c = try billing.charge(app, req, who.user_id, .{ .kind = "followups", .model = model, .prompt_tokens = usage.prompt_tokens, .completion_tokens = usage.completion_tokens, .cost_usd = usage.cost_usd, .session = body.session, .byok = aux.byok });
        // Counted in the conversation's cost, not its context window.
        try sink.send("usage", .{ .kind = "followups", .model = model, .prompt_tokens = usage.prompt_tokens, .completion_tokens = usage.completion_tokens, .cached_tokens = 0, .cache_write_tokens = 0, .charged_micros = c.charged_micros, .byok_cost_micros = billing.ownKeyCost(c, aux.byok) });
    };
    const content = v.object.get("choices").?.array.items[0].object.get("message").?.object.get("content").?.string;
    const start = std.mem.indexOfScalar(u8, content, '[') orelse return;
    const end = std.mem.lastIndexOfScalar(u8, content, ']') orelse return;
    if (end <= start) return;
    const list = std.json.parseFromSliceLeaky([]const []const u8, req.arena, content[start .. end + 1], .{}) catch return;
    try sink.send("followups", .{ .questions = list[0..@min(list.len, 3)] });
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    const v1 = app.group("/v1", .{auth.Authenticate{ .app = state }});
    v1.post("/chat/stream", stream);
    v1.post("/chat/tool_result", toolResult);
}

test {
    _ = tool_check;
    _ = truncation;
    _ = web;
    _ = summarise;
    _ = auto;
}

test buildBody {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Msg{ .{ .role = "user", .content = "hi" }, .{ .role = "assistant", .content = "hello" }, .{ .role = "user", .content = "again" } };
    // Search without tools: the web plugin, and no mode block.
    const anthropic = try buildBody(a, "anthropic/claude-haiku-5.5", .search, false, &msgs, "5m", "exa", .{});
    // System and last message carry breakpoints; the middle one does not.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, anthropic, "cache_control"));
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"plugins\":[{\"id\":\"web\"") != null);
    const openai = try buildBody(a, "openai/gpt-6.1-sol", .chat, true, &msgs, "5m", "exa", .{});
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, openai, "cache_control"));
    // The prefix (everything before the messages) is identical across turns.
    const turn2 = try buildBody(a, "openai/gpt-6.1-sol", .chat, true, msgs[0..1], "5m", "exa", .{});
    const cut = std.mem.indexOf(u8, openai, "\"role\":\"user\"").?;
    try std.testing.expectEqualStrings(openai[0..cut], turn2[0..cut]);
}

test "buildBody: a mode adds its block after the base prompt, each part cached" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Msg{.{ .role = "user", .content = "teach me" }};
    const learn = try buildBody(a, "anthropic/claude-haiku-5.5", .learn, true, &msgs, "5m", "exa", .{});
    // Base prompt, mode block and last message.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, learn, "cache_control"));
    try std.testing.expect(std.mem.indexOf(u8, learn, "is in Learn mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, learn, "plugins") == null);
    // Plain chat sends the base prompt alone, byte for byte the same up to it.
    const chat = try buildBody(a, "anthropic/claude-haiku-5.5", .chat, true, &msgs, "5m", "exa", .{});
    try std.testing.expect(std.mem.indexOf(u8, chat, "<mode name=") == null);
    const base_end = std.mem.indexOf(u8, learn, "<mode name=").?;
    const shared = std.mem.indexOf(u8, learn, "\"role\":\"system\"").?;
    try std.testing.expectEqualStrings(chat[0..shared], learn[0..shared]);
    try std.testing.expect(base_end > shared);
    const openai = try buildBody(a, "openai/gpt-6.1-sol", .summarise, true, &msgs, "5m", "exa", .{});
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, openai, "cache_control"));
    try std.testing.expect(std.mem.indexOf(u8, openai, "is in Summarise mode") != null);
}

test "buildBody: effort and reasoning passback on assistant steps" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Msg{
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .raw_tool_calls = "[]", .reasoning = "plain", .reasoning_details = "[{\"type\":\"reasoning.text\",\"text\":\"r\",\"signature\":\"s\"}]" },
        .{ .role = "assistant", .content = "ok", .reasoning = "only text" },
    };
    const body = try buildBody(a, "deepseek/deepseek-v4-pro", .chat, true, &msgs, "5m", "exa", .{ .effort = Effort.max.wire("openrouter") });
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"xhigh\"}") != null);
    // Structured details win over the plain text; plain text is the fallback.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_details\":[{\"type\":\"reasoning.text\",\"text\":\"r\",\"signature\":\"s\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":\"plain\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":\"only text\"") != null);
    try std.testing.expectEqualStrings("max", Effort.max.wire("anthropic"));
    try std.testing.expectEqualStrings("low", Effort.low.wire("openrouter"));
    // No effort: no reasoning object.
    const plain = try buildBody(a, "deepseek/deepseek-v4-pro", .chat, true, msgs[0..1], "5m", "exa", .{});
    try std.testing.expect(std.mem.indexOf(u8, plain, "effort") == null);
}

test "buildBody: a forced tool names it and leaves the rest of the body alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Msg{.{ .role = "user", .content = "quiz me on rivers" }};
    const plain = try buildBody(a, "openai/gpt-6.1-sol", .chat, true, &msgs, "5m", "exa", .{});
    const forced = try buildBody(a, "openai/gpt-6.1-sol", .chat, true, &msgs, "5m", "exa", .{ .force_tool = "make_quiz" });
    try std.testing.expect(std.mem.indexOf(u8, plain, "tool_choice") == null);
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":\"make_quiz\"}}") != null);
    // Tools and the system prompt come before the choice, byte for byte.
    const cut = std.mem.indexOf(u8, plain, "\"messages\"").?;
    const tools_end = std.mem.indexOf(u8, forced, ",\"tool_choice\"").?;
    try std.testing.expectEqualStrings(plain[0..tools_end], forced[0..tools_end]);
    try std.testing.expect(tools_end < cut);
    // No tools, no choice; and "none" wins over a forced tool.
    const bare = try buildBody(a, "openai/gpt-6.1-sol", .chat, false, &msgs, "5m", "exa", .{ .force_tool = "make_quiz" });
    try std.testing.expect(std.mem.indexOf(u8, bare, "tool_choice") == null);
    const none = try buildBody(a, "openai/gpt-6.1-sol", .chat, true, &msgs, "5m", "exa", .{ .force_tool = "make_quiz", .no_tool_calls = true });
    try std.testing.expect(std.mem.indexOf(u8, none, "\"tool_choice\":\"none\"") != null);
}

test "knownTool and the Anthropic nudge" {
    try std.testing.expect(knownTool("make_slides"));
    try std.testing.expect(knownTool("render_svg"));
    try std.testing.expect(!knownTool("rm_rf"));
    try std.testing.expect(!knownTool(""));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Msg{.{ .role = "user", .content = "hi" }};
    try std.testing.expect(nudgesTool("anthropic/claude-sonnet-5.5", "anthropic", null));
    try std.testing.expect(nudgesTool("anthropic/claude-sonnet-5.5", "openrouter", "high"));
    try std.testing.expect(!nudgesTool("anthropic/claude-sonnet-5.5", "openrouter", null));
    try std.testing.expect(!nudgesTool("openai/gpt-6.1-sol", "openrouter", "high"));
    try std.testing.expectEqual(@as(usize, 1), (try withToolNudge(a, &msgs, null)).len);
    const nudged = try withToolNudge(a, &msgs, "make_quiz");
    try std.testing.expectEqual(@as(usize, 2), nudged.len);
    try std.testing.expect(std.mem.indexOf(u8, nudged[1].content, "make_quiz") != null);
}

test readableText {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try readableText(arena.allocator(), "<html><head><style>x{}</style><script>var a=1</script></head><body><h1>Hi</h1>\n<p>there  you</p></body></html>", 100);
    try std.testing.expectEqualStrings("Hi there you", text);
}
