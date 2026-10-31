//! The Auto model (`everyai/auto`): before a chat turn, the decider reads the
//! newest message (with up to two earlier turns for context) and picks the
//! mode, whether rich answers help, and a model tier (AUTO_FAST_MODEL,
//! AUTO_BALANCED_MODEL, AUTO_BEST_MODEL). The turn then runs exactly as if
//! the app had sent those values; the app hears of them first, in a `route
//! {model, mode, tools_enabled}` event.
//!
//! What the request fixed stays: a mode other than Chat is kept (and not
//! asked), and rich answers turned off stay off. An "unsure" answer, or a
//! decider that can't run, falls back to the request's mode and rich setting
//! on the balanced tier.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const chat = @import("chat.zig");
const decide = @import("decide.zig");
const modes = @import("modes.zig");
const openrouter = @import("openrouter.zig");
const web = @import("web.zig");

pub const model_id = "everyai/auto";

pub const Tier = enum { fast, balanced, best };

pub const Pick = struct {
    model: []const u8,
    mode: modes.Mode,
    tools_enabled: bool,
    /// The decider's call, when it ran (for its usage event).
    outcome: ?decide.Outcome = null,
};

// The questions are constant, so the decider's prompt prefix caches; only
// the conversation text changes.
const mode_question: decide.Question = .{
    .id = "mode",
    .kind = .choice,
    .prompt = "Which mode serves this message best? chat: conversation, writing, coding, advice, and questions general knowledge answers. search: it needs current facts from the web (news, prices, releases, schedules, anything recent or that changes). research: it needs a thorough report that weighs many sources (comparisons, market or literature overviews). learn: the user wants to be taught or tested on a topic step by step. summarise: the user wants a given text, file, page or earlier chat condensed.",
    .choices = &.{ "chat", "search", "research", "learn", "summarise" },
};
const rich_question: decide.Question = .{
    .id = "rich",
    .kind = .bool,
    .prompt = "Would rendered content clearly help the answer: a chart, diagram, quiz, flashcards, slides, an interactive widget, or a document the user keeps? false for plain conversation, short answers and quick facts.",
};
const tier_question: decide.Question = .{
    .id = "tier",
    .kind = .choice,
    .prompt = "How capable a model does the answer need? fast: greetings, short or simple questions, quick rewrites and lookups. balanced: most tasks, ordinary writing, coding and analysis. best: hard reasoning, proofs, long careful writing, large or tricky code, high-stakes advice.",
    .choices = &.{ "fast", "balanced", "best" },
};

/// The model of a tier, from the config.
pub fn modelOf(app: *const App, tier: Tier) []const u8 {
    return switch (tier) {
        .fast => app.cfg.auto_fast_model,
        .balanced => app.cfg.auto_balanced_model,
        .best => app.cfg.auto_best_model,
    };
}

/// What to ask: the mode only in Chat, rich only while it is allowed.
pub fn questionsFor(arena: std.mem.Allocator, mode: modes.Mode, tools_enabled: bool) ![]const decide.Question {
    var list: std.ArrayList(decide.Question) = .empty;
    if (mode == .chat) try list.append(arena, mode_question);
    if (tools_enabled) try list.append(arena, rich_question);
    try list.append(arena, tier_question);
    return list.items;
}

/// The pick from the decider's answers, with the request's values for
/// anything it was unsure of or wasn't asked.
pub fn fromAnswers(app: *const App, outcome: ?decide.Outcome, mode: modes.Mode, tools_enabled: bool) Pick {
    var pick: Pick = .{ .model = modelOf(app, .balanced), .mode = mode, .tools_enabled = tools_enabled, .outcome = outcome };
    const o = outcome orelse return pick;
    if (mode == .chat) switch (o.get("mode")) {
        .choice => |c| pick.mode = std.meta.stringToEnum(modes.Mode, c) orelse mode,
        else => {},
    };
    if (tools_enabled) switch (o.get("rich")) {
        .yes_no => |b| pick.tools_enabled = b,
        else => {},
    };
    // The research lead works through tools; without them Research would
    // hand the turn to the deep-research model instead.
    if (pick.mode == .research and tools_enabled) pick.tools_enabled = true;
    switch (o.get("tier")) {
        .choice => |c| if (std.meta.stringToEnum(Tier, c)) |t| {
            pick.model = modelOf(app, t);
        },
        else => {},
    }
    return pick;
}

/// The decider's view of the conversation: up to two earlier turns, cut
/// short, then the newest user message (and what it attaches).
pub fn context(arena: std.mem.Allocator, messages: []const chat.InMessage) ![]const u8 {
    const newest = chat.newestUser(messages) orelse return "";
    var out: std.Io.Writer.Allocating = .init(arena);
    const first = newest -| 4;
    if (first < newest) {
        try out.writer.writeAll("Earlier in the conversation (context only):\n");
        for (messages[first..newest]) |m| {
            const who = if (std.mem.eql(u8, m.role, "assistant")) "Assistant" else "User";
            try out.writer.print("{s}: {s}\n", .{ who, web.clip(std.mem.trim(u8, textOf(m.content), " \t\r\n"), 1500) });
        }
        try out.writer.writeAll("\n");
    }
    try out.writer.writeAll("The message to route:\n");
    const latest = messages[newest].content;
    try out.writer.writeAll(web.clip(std.mem.trim(u8, textOf(latest), " \t\r\n"), 8000));
    if (latest == .array) {
        var images: usize = 0;
        var files: usize = 0;
        var audio: usize = 0;
        for (latest.array.items) |p| {
            const kind = if (p == .object) openrouter.jsonStr(p.object.get("type")) orelse "" else "";
            if (std.mem.eql(u8, kind, "image_url")) images += 1;
            if (std.mem.eql(u8, kind, "file")) files += 1;
            if (std.mem.eql(u8, kind, "input_audio")) audio += 1;
        }
        if (images + files + audio > 0) try out.writer.print("\n[Attached: {d} image(s), {d} file(s), {d} audio clip(s)]", .{ images, files, audio });
    }
    return out.written();
}

/// A message's typed text: the string, or its last text part (as chat.zig reads it).
fn textOf(content: std.json.Value) []const u8 {
    return switch (content) {
        .string => |t| t,
        .array => |a| blk: {
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

/// Runs the decider for a chat request on `everyai/auto`. Never fails the
/// turn over the decider: out of credit or an upstream failure is the fallback.
pub fn choose(app: *App, req: *anole.Request, who: auth.Identity, body: chat.ChatRequest) !Pick {
    const questions = try questionsFor(req.arena, body.mode, body.tools_enabled);
    const text = try context(req.arena, body.messages);
    const aux = try app.aux(req);
    const outcome = decide.decide(app, req, who.user_id, aux, questions, text, .{ .job = "auto", .session = body.session }) catch |err| switch (err) {
        error.PaymentRequired, error.UpstreamFailed => null,
        else => return err,
    };
    return fromAnswers(app, outcome, body.mode, body.tools_enabled);
}

test "questions follow what the request fixed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 3), (try questionsFor(a, .chat, true)).len);
    const kept = try questionsFor(a, .learn, false);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("tier", kept[0].id);
    try std.testing.expect(decide.problem(try questionsFor(a, .chat, true)) == null);
}

test "context: two earlier turns, cut short, then the message and its attachments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parts = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[{"type":"image_url","image_url":{"url":"data:"}},{"type":"text","text":"What is this?"}]
    , .{});
    const msgs = [_]chat.InMessage{
        .{ .role = "user", .content = .{ .string = "oldest" } },
        .{ .role = "assistant", .content = .{ .string = "a1" } },
        .{ .role = "user", .content = .{ .string = "u2" } },
        .{ .role = "assistant", .content = .{ .string = "a2" } },
        .{ .role = "user", .content = .{ .string = "u3" } },
        .{ .role = "user", .content = parts },
    };
    const text = try context(a, &msgs);
    try std.testing.expect(std.mem.indexOf(u8, text, "oldest") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Assistant: a1\nUser: u2\nAssistant: a2\nUser: u3\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "The message to route:\nWhat is this?\n[Attached: 1 image(s), 0 file(s), 0 audio clip(s)]"));
}
