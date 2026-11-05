//! Checks tool-call arguments against the schemas in `tools.definitions`
//! (types, required fields, enums, array sizes) plus a few rules the schema
//! cannot say (quiz answers in range, an SVG with a viewBox). A failed check
//! becomes a tool result that names every problem by path, so the model can
//! fix the call instead of the app rendering something broken. A passing UI
//! call gets a short confirmation naming what the user now sees.
const std = @import("std");
const tools = @import("tools.zig");

const Value = std.json.Value;

/// At most this many problems are listed; the rest are summarized.
const max_issues = 8;

const Issues = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,
    extra: usize = 0,

    fn add(self: *Issues, comptime fmt: []const u8, args: anytype) !void {
        if (self.list.items.len >= max_issues) {
            self.extra += 1;
            return;
        }
        try self.list.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }
};

/// The `parameters` schema of a tool, parsed from the constant definitions.
pub fn schemaOf(arena: std.mem.Allocator, name: []const u8) !?Value {
    const defs = try std.json.parseFromSliceLeaky(Value, arena, tools.definitions, .{});
    for (defs.array.items) |t| {
        const f = t.object.get("function") orelse continue;
        const n = f.object.get("name") orelse continue;
        if (n == .string and std.mem.eql(u8, n.string, name)) return f.object.get("parameters");
    }
    return null;
}

/// Null when the arguments are fine; otherwise the error text for the model.
pub fn check(arena: std.mem.Allocator, name: []const u8, args: Value) !?[]const u8 {
    var issues: Issues = .{ .arena = arena };
    if (try schemaOf(arena, name)) |schema| try validate(&issues, schema, args, "");
    if (issues.list.items.len == 0) try semantic(&issues, name, args);
    if (issues.list.items.len == 0) return null;

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("Error: the {s} arguments are invalid, so nothing was shown to the user:", .{name});
    for (issues.list.items) |i| try out.writer.print("\n- {s}", .{i});
    if (issues.extra > 0) try out.writer.print("\n- …and {d} more", .{issues.extra});
    try out.writer.print("\nFix these and call {s} again with the complete arguments.", .{name});
    return out.written();
}

fn label(path: []const u8) []const u8 {
    return if (path.len == 0) "arguments" else path;
}

fn typeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "a boolean",
        .integer => "an integer",
        .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

fn isType(v: Value, t: []const u8) bool {
    if (std.mem.eql(u8, t, "string")) return v == .string;
    if (std.mem.eql(u8, t, "object")) return v == .object;
    if (std.mem.eql(u8, t, "array")) return v == .array;
    if (std.mem.eql(u8, t, "boolean")) return v == .bool;
    if (std.mem.eql(u8, t, "null")) return v == .null;
    if (std.mem.eql(u8, t, "number")) return v == .integer or v == .float or v == .number_string;
    if (std.mem.eql(u8, t, "integer")) return switch (v) {
        .integer => true,
        .float => |f| @floor(f) == f,
        else => false,
    };
    return true; // An unknown type keyword constrains nothing.
}

fn matchesType(v: Value, t: Value) bool {
    return switch (t) {
        .string => |s| isType(v, s),
        .array => |a| for (a.items) |s| {
            if (s == .string and isType(v, s.string)) break true;
        } else false,
        else => true,
    };
}

fn typeWanted(arena: std.mem.Allocator, t: Value) ![]const u8 {
    if (t == .string) return t.string;
    var out: std.Io.Writer.Allocating = .init(arena);
    if (t == .array) for (t.array.items, 0..) |s, i| {
        if (i > 0) try out.writer.writeAll(" or ");
        if (s == .string) try out.writer.writeAll(s.string);
    };
    return out.written();
}

fn validate(issues: *Issues, schema: Value, v: Value, path: []const u8) error{ OutOfMemory, WriteFailed }!void {
    if (schema != .object) return;
    const a = issues.arena;
    if (schema.object.get("type")) |t| if (!matchesType(v, t)) {
        const hint: []const u8 = if (v == .string and (t == .string and (std.mem.eql(u8, t.string, "array") or std.mem.eql(u8, t.string, "object"))))
            " (pass the value itself, not JSON text in a string)"
        else
            "";
        return issues.add("{s} must be {s}, got {s}{s}", .{ label(path), try typeWanted(a, t), typeName(v), hint });
    };
    if (schema.object.get("enum")) |e| if (e == .array and v == .string) {
        const ok = for (e.array.items) |o| {
            if (o == .string and std.mem.eql(u8, o.string, v.string)) break true;
        } else false;
        if (!ok) {
            var opts: std.Io.Writer.Allocating = .init(a);
            for (e.array.items, 0..) |o, i| if (o == .string) try opts.writer.print("{s}\"{s}\"", .{ if (i > 0) ", " else "", o.string });
            try issues.add("{s} is \"{s}\", which is not one of {s}", .{ label(path), v.string, opts.written() });
        }
    };
    switch (v) {
        .object => |obj| {
            if (schema.object.get("required")) |r| if (r == .array) for (r.array.items) |k| {
                if (k == .string and obj.get(k.string) == null)
                    try issues.add("{s} is missing", .{try join(a, path, k.string)});
            };
            if (schema.object.get("properties")) |props| if (props == .object) {
                var it = props.object.iterator();
                while (it.next()) |p| if (obj.get(p.key_ptr.*)) |child| {
                    try validate(issues, p.value_ptr.*, child, try join(a, path, p.key_ptr.*));
                };
            };
        },
        .array => |list| {
            const n = list.items.len;
            if (intOf(schema.object.get("minItems"))) |min| if (n < min)
                try issues.add("{s} has {d} item(s); it needs at least {d}", .{ label(path), n, min });
            if (intOf(schema.object.get("maxItems"))) |max| if (n > max)
                try issues.add("{s} has {d} items; it allows at most {d}", .{ label(path), n, max });
            if (schema.object.get("items")) |items| for (list.items, 0..) |child, i| {
                try validate(issues, items, child, try std.fmt.allocPrint(a, "{s}[{d}]", .{ label(path), i }));
            };
        },
        else => {},
    }
}

fn join(arena: std.mem.Allocator, path: []const u8, key: []const u8) ![]const u8 {
    return if (path.len == 0) key else std.fmt.allocPrint(arena, "{s}.{s}", .{ path, key });
}

fn intOf(v: ?Value) ?usize {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0 and @floor(f) == f) @intFromFloat(f) else null,
        else => null,
    };
}

fn str(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn arr(v: Value, key: []const u8) []const Value {
    if (v != .object) return &.{};
    const x = v.object.get(key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn blank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Rules the schema cannot express. Runs only on schema-valid arguments, so
/// fields have the right types here.
fn semantic(issues: *Issues, name: []const u8, args: Value) !void {
    // Fields the app cannot render when empty.
    const nonempty: []const []const u8 = if (eql(name, "create_artifact"))
        &.{ "id", "content" }
    else if (eql(name, "update_artifact") or eql(name, "edit_artifact"))
        &.{"id"}
    else if (eql(name, "render_svg"))
        &.{"svg"}
    else if (eql(name, "render_diagram"))
        &.{"mermaid"}
    else if (eql(name, "web_fetch"))
        &.{"url"}
    else if (eql(name, "summarise_parts"))
        &.{ "url", "question" }
    else if (eql(name, "generate_image"))
        &.{"prompt"}
    else if (eql(name, "load_skill"))
        &.{"name"}
    else if (eql(name, "read_skill_file"))
        &.{ "skill", "path" }
    else
        &.{};
    for (nonempty) |k| if (str(args, k)) |s| if (blank(s)) try issues.add("{s} is empty", .{k});

    // Non-empty lists of things to show.
    const list: ?[]const u8 = if (eql(name, "render_chart"))
        "series"
    else if (eql(name, "make_quiz"))
        "questions"
    else if (eql(name, "make_flashcards"))
        "cards"
    else if (eql(name, "make_slides"))
        "slides"
    else
        null;
    if (list) |k| if (arr(args, k).len == 0) try issues.add("{s} is empty; add at least one", .{k});

    if (eql(name, "render_svg")) try checkSvg(issues, "svg", str(args, "svg") orelse "");
    if (eql(name, "create_artifact") and eql(str(args, "kind") orelse "", "svg"))
        try checkSvg(issues, "content", str(args, "content") orelse "");
    if (eql(name, "create_artifact") and eql(str(args, "kind") orelse "", "drawing"))
        try checkDrawing(issues, str(args, "content") orelse "");
    if (eql(name, "web_fetch") or eql(name, "summarise_parts")) if (str(args, "url")) |u| if (!blank(u) and !std.mem.startsWith(u8, u, "https://") and !std.mem.startsWith(u8, u, "http://"))
        try issues.add("url must start with https:// or http://", .{});

    if (eql(name, "memory")) {
        const action = str(args, "action") orelse "";
        if (!eql(action, "remove") and blank(str(args, "text") orelse "")) try issues.add("text is required for action {s}", .{action});
        if (!eql(action, "add") and blank(str(args, "old_text") orelse "")) try issues.add("old_text is required for action {s}", .{action});
    }
    if (eql(name, "search_chats") and blank(str(args, "query") orelse "") and blank(str(args, "chat_id") orelse ""))
        try issues.add("give a query or a chat_id", .{});

    if (eql(name, "render_chart")) for (arr(args, "series"), 0..) |s, i| {
        if (arr(s, "points").len == 0) try issues.add("series[{d}].points is empty", .{i});
    };

    if (eql(name, "make_quiz")) for (arr(args, "questions"), 0..) |q, i| {
        const options = arr(q, "options").len;
        const n: i64 = @intCast(options);
        const single: ?i64 = if (q.object.get("answer_index")) |x| indexOf(x) else null;
        const multi = arr(q, "answer_indices");
        if (single == null and multi.len == 0) {
            try issues.add("questions[{d}] needs answer_index (one correct option) or answer_indices (several)", .{i});
            continue;
        }
        if (single) |s| if (s < 0 or s >= n)
            try issues.add("questions[{d}].answer_index must be between 0 and {d} (it has {d} options)", .{ i, options -| 1, options });
        for (multi, 0..) |x, j| {
            const k = indexOf(x) orelse -1;
            if (k < 0 or k >= n)
                try issues.add("questions[{d}].answer_indices[{d}] must be between 0 and {d} (it has {d} options)", .{ i, j, options -| 1, options });
        }
    };
}

fn indexOf(v: Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .float => |f| if (@abs(f) < 1e15) @intFromFloat(f) else null,
        else => null,
    };
}

pub fn hasViewBox(svg: []const u8) bool {
    const needle = "viewbox=";
    if (svg.len < needle.len) return false;
    for (0..svg.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(svg[i..][0..needle.len], needle)) return true;
    return false;
}

fn checkSvg(issues: *Issues, field: []const u8, svg: []const u8) !void {
    if (blank(svg)) return;
    if (std.mem.indexOf(u8, svg, "<svg") == null) return issues.add("{s} must be a complete <svg> element", .{field});
    if (!hasViewBox(svg)) try issues.add("{s}: the root <svg> needs a viewBox attribute", .{field});
    // Figures with many shapes need ids so edit_artifact can target parts.
    if (shapeCount(svg) >= min_shapes_for_ids and !hasId(svg))
        try issues.add("{s}: give the layers and key shapes stable ids (e.g. <g id=\"sky\">, <circle id=\"sun\">) so later edits can find them", .{field});
}

/// A drawing is Excalidraw scene JSON (or a bare element list) whose
/// elements each name a type; the app fills in the rest of each element.
fn checkDrawing(issues: *Issues, content: []const u8) !void {
    if (blank(content)) return;
    const scene = std.json.parseFromSliceLeaky(Value, issues.arena, content, .{}) catch
        return issues.add("content must be Excalidraw scene JSON: {{\"type\":\"excalidraw\",\"elements\":[...]}}", .{});
    const elements: []const Value = switch (scene) {
        .array => |a| a.items,
        .object => arr(scene, "elements"),
        else => &.{},
    };
    if (elements.len == 0) return issues.add("content: the scene has no elements", .{});
    for (elements, 0..) |e, i| {
        if (e != .object or str(e, "type") == null) try issues.add("content: elements[{d}] needs a string type (rectangle, ellipse, diamond, text, arrow, line)", .{i});
    }
}

const min_shapes_for_ids = 6;

fn shapeCount(svg: []const u8) usize {
    const tags = [_][]const u8{ "<rect", "<circle", "<ellipse", "<line", "<polygon", "<polyline", "<path" };
    var n: usize = 0;
    for (tags) |t| n += std.mem.count(u8, svg, t);
    return n;
}

pub fn hasId(svg: []const u8) bool {
    return std.mem.indexOf(u8, svg, " id=\"") != null or std.mem.indexOf(u8, svg, " id='") != null;
}

/// Look rules for a render_svg `style`, appended to the tool result (after
/// the cached prefix) so they guide revisions without touching the prompt.
fn styleRules(style: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "flat", "no outlines, at most 4 colors, bold simple shapes, no gradients except a subtle background" },
        .{ "line_icon", "a 24 or 48 unit grid, 2 unit round-capped strokes, no fills except one accent color" },
        .{ "isometric", "30 degree axes, three face shades per solid (light top, mid left, dark right), consistent scale" },
        .{ "geometric_logo", "built on a simple grid from circles and straight lines, 2 colors, must still work in one color" },
        .{ "hand_drawn", "slightly irregular strokes, round caps and joins, a warm paper-toned palette, no perfect symmetry" },
        .{ "poster", "one strong focal shape, large type-free composition, depth from light gradients and layered shapes" },
    };
    for (table) |e| if (eql(e[0], style)) return e[1];
    return null;
}

/// The tool result for a UI call that passed the checks: what the user sees.
pub fn shown(arena: std.mem.Allocator, name: []const u8, args: Value) ![]const u8 {
    const title = str(args, "title");
    const titled: []const u8 = if (title) |t| (if (blank(t)) "" else try std.fmt.allocPrint(arena, " \"{s}\"", .{t})) else "";
    if (eql(name, "create_artifact"))
        return std.fmt.allocPrint(arena, "Shown to the user: {s} artifact{s} (id \"{s}\") in the side panel.", .{ str(args, "kind") orelse "", titled, str(args, "id") orelse "" });
    if (eql(name, "update_artifact"))
        return std.fmt.allocPrint(arena, "Shown to the user: a new version of artifact \"{s}\" in the side panel.", .{str(args, "id") orelse ""});
    if (eql(name, "render_svg")) {
        const rules = if (str(args, "style")) |st| styleRules(st) else null;
        if (rules) |r| return std.fmt.allocPrint(arena, "Shown to the user: SVG illustration{s}. Style rules for any revision ({s}): {s}. Keep existing ids.", .{ titled, str(args, "style").?, r });
        return std.fmt.allocPrint(arena, "Shown to the user: SVG illustration{s}.", .{titled});
    }
    if (eql(name, "render_diagram")) return std.fmt.allocPrint(arena, "Shown to the user: Mermaid diagram{s}.", .{titled});
    if (eql(name, "render_chart"))
        return std.fmt.allocPrint(arena, "Shown to the user: {s} chart{s} with {d} series.", .{ str(args, "type") orelse "", titled, arr(args, "series").len });
    if (eql(name, "make_quiz"))
        return std.fmt.allocPrint(arena, "Shown to the user: quiz{s} with {d} question(s).", .{ titled, arr(args, "questions").len });
    if (eql(name, "make_flashcards"))
        return std.fmt.allocPrint(arena, "Shown to the user: flashcard deck{s} with {d} card(s).", .{ titled, arr(args, "cards").len });
    if (eql(name, "make_slides"))
        return std.fmt.allocPrint(arena, "Shown to the user: slide deck{s} with {d} slide(s).", .{ titled, arr(args, "slides").len });
    // Only when the app did not take the call itself (no `client_tools`).
    if (eql(name, "ask_user"))
        return std.fmt.allocPrint(arena, "Shown to the user: {d} question(s). The app cannot wait for the answers here, so end your turn now; the user answers in their next message.", .{arr(args, "questions").len});
    if (eql(name, "security_alert")) return "Shown to the user: a security notice. Don't repeat it in full; carry on without the harmful step.";
    if (eql(name, "suggest_mode"))
        return std.fmt.allocPrint(arena, "Shown to the user: a button to run this request again in {s} mode. Don't mention it again.", .{str(args, "mode") orelse ""});
    return "Shown to the user.";
}

fn parse(a: std.mem.Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{});
}

test "every tool has a parameters schema" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    inline for (tools.ui_tools ++ tools.server_tools) |n| try std.testing.expect((try schemaOf(arena.allocator(), n)) != null);
    try std.testing.expect((try schemaOf(arena.allocator(), "nope")) == null);
}

test "valid calls pass and get a named confirmation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const quiz = try parse(a,
        \\{"title":"Cells","questions":[{"question":"Q?","options":["a","b","c"],"answer_index":2,"explanation":"e"},
        \\ {"question":"Pick","options":["a","b"],"answer_indices":[0,1],"explanation":"e"}]}
    );
    try std.testing.expect((try check(a, "make_quiz", quiz)) == null);
    try std.testing.expectEqualStrings("Shown to the user: quiz \"Cells\" with 2 question(s).", try shown(a, "make_quiz", quiz));

    const chart = try parse(a,
        \\{"type":"bar","series":[{"name":"s","points":[{"x":"Mon","y":1},{"x":2,"y":2.5}]}]}
    );
    try std.testing.expect((try check(a, "render_chart", chart)) == null);
    try std.testing.expectEqualStrings("Shown to the user: bar chart with 1 series.", try shown(a, "render_chart", chart));

    const svg = try parse(a,
        \\{"svg":"<svg viewBox=\"0 0 10 10\"><circle r=\"2\"/></svg>","title":"Dot"}
    );
    try std.testing.expect((try check(a, "render_svg", svg)) == null);

    const art = try parse(a,
        \\{"id":"notes","title":"Notes","kind":"markdown","content":"# Hi"}
    );
    try std.testing.expect((try check(a, "create_artifact", art)) == null);
    try std.testing.expectEqualStrings("Shown to the user: markdown artifact \"Notes\" (id \"notes\") in the side panel.", try shown(a, "create_artifact", art));
}

test "ask_user needs 1-4 questions with 2-4 labeled options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try parse(a,
        \\{"questions":[{"question":"Which tone?","header":"Tone","options":[{"label":"Formal","description":"d"},{"label":"Casual"}]}]}
    );
    try std.testing.expect((try check(a, "ask_user", ok)) == null);
    try std.testing.expect(std.mem.startsWith(u8, try shown(a, "ask_user", ok), "Shown to the user: 1 question(s)."));

    const one_option = try parse(a,
        \\{"questions":[{"question":"Which tone?","options":[{"label":"Formal"}]}]}
    );
    try std.testing.expect((try check(a, "ask_user", one_option)) != null);
    const unlabeled = try parse(a,
        \\{"questions":[{"question":"Which tone?","options":[{"label":"Formal"},{"description":"no label"}]}]}
    );
    try std.testing.expect((try check(a, "ask_user", unlabeled)) != null);
}

test "memory and search_chats need the fields their action uses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try check(a, "memory", try parse(a,
        \\{"action":"add","target":"user","text":"Prefers metric units."}
    ))) == null);
    try std.testing.expect((try check(a, "memory", try parse(a,
        \\{"action":"replace","target":"notes","text":"x"}
    ))) != null);
    try std.testing.expect((try check(a, "memory", try parse(a,
        \\{"action":"forget","target":"user","old_text":"x"}
    ))) != null);
    try std.testing.expect((try check(a, "search_chats", try parse(a, "{}"))) != null);
    try std.testing.expect((try check(a, "search_chats", try parse(a,
        \\{"query":"tax return"}
    ))) == null);
}

test "skill tools need a name, and a skill and path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try check(a, "load_skill", try parse(a, "{}"))) != null);
    try std.testing.expect((try check(a, "load_skill", try parse(a,
        \\{"name":" "}
    ))) != null);
    try std.testing.expect((try check(a, "load_skill", try parse(a,
        \\{"name":"make-deck"}
    ))) == null);
    try std.testing.expect((try check(a, "read_skill_file", try parse(a,
        \\{"skill":"make-deck"}
    ))) != null);
    try std.testing.expect((try check(a, "read_skill_file", try parse(a,
        \\{"skill":"make-deck","path":"references/style.md"}
    ))) == null);
}

test "drawings are Excalidraw scene JSON with typed elements" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try check(a, "create_artifact", try parse(a,
        \\{"id":"d","title":"D","kind":"drawing","content":"{\"type\":\"excalidraw\",\"elements\":[{\"type\":\"rectangle\",\"x\":0,\"y\":0}]}"}
    ))) == null);
    try std.testing.expect((try check(a, "create_artifact", try parse(a,
        \\{"id":"d","title":"D","kind":"drawing","content":"a box"}
    ))) != null);
    try std.testing.expect((try check(a, "create_artifact", try parse(a,
        \\{"id":"d","title":"D","kind":"drawing","content":"{\"elements\":[{\"x\":1}]}"}
    ))) != null);
    try std.testing.expect((try check(a, "create_artifact", try parse(a,
        \\{"id":"d","title":"D","kind":"drawing","content":"[]"}
    ))) != null);
}

test "svg style rules and stable ids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const many = try parse(a,
        \\{"svg":"<svg viewBox=\"0 0 9 9\"><rect/><rect/><rect/><circle/><circle/><path d=\"M0 0\"/></svg>"}
    );
    const msg = (try check(a, "render_svg", many)).?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "stable ids") != null);

    const ok = try parse(a,
        \\{"style":"flat","svg":"<svg viewBox=\"0 0 9 9\"><g id=\"bg\"><rect/><rect/><rect/><circle/><circle/><path d=\"M0 0\"/></g></svg>"}
    );
    try std.testing.expect((try check(a, "render_svg", ok)) == null);
    const res = try shown(a, "render_svg", ok);
    try std.testing.expect(std.mem.indexOf(u8, res, "Style rules") != null);

    const bad = try parse(a,
        \\{"style":"neon","svg":"<svg viewBox=\"0 0 9 9\"/>"}
    );
    try std.testing.expect((try check(a, "render_svg", bad)) != null);
}

test "schema problems are named by path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const has = struct {
        fn f(msg: []const u8, needle: []const u8) !void {
            if (std.mem.indexOf(u8, msg, needle) == null) {
                std.debug.print("missing \"{s}\" in:\n{s}\n", .{ needle, msg });
                return error.TestExpectedSubstring;
            }
        }
    }.f;

    const chart = (try check(a, "render_chart", try parse(a,
        \\{"type":"radar","series":[{"name":"s","points":[{"x":true,"y":"3"}]}]}
    ))).?;
    try has(chart, "Error: the render_chart arguments are invalid");
    try has(chart, "type is \"radar\", which is not one of \"bar\", \"line\"");
    try has(chart, "series[0].points[0].x must be string or number, got a boolean");
    try has(chart, "series[0].points[0].y must be number, got a string");

    const quiz = (try check(a, "make_quiz", try parse(a,
        \\{"questions":[{"question":"Q","options":["only"],"answer_index":1.5}]}
    ))).?;
    try has(quiz, "- title is missing");
    try has(quiz, "questions[0].explanation is missing");
    try has(quiz, "questions[0].options has 1 item(s); it needs at least 2");
    try has(quiz, "questions[0].answer_index must be integer, got a number");

    const stringified = (try check(a, "make_flashcards", try parse(a,
        \\{"title":"T","cards":"[{\"front\":\"a\",\"back\":\"b\"}]"}
    ))).?;
    try has(stringified, "cards must be array, got a string (pass the value itself");

    const edit = (try check(a, "edit_artifact", try parse(a,
        \\{"id":"x","edits":[]}
    ))).?;
    try has(edit, "edits has 0 item(s); it needs at least 1");

    try has((try check(a, "web_fetch", try parse(a, "[]"))).?, "arguments must be object, got an array");
}

test "rules beyond the schema" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const quiz = (try check(a, "make_quiz", try parse(a,
        \\{"title":"T","questions":[{"question":"Q","options":["a","b"],"answer_index":2,"explanation":"e"},
        \\ {"question":"Q","options":["a","b"],"explanation":"e"},
        \\ {"question":"Q","options":["a","b","c"],"answer_indices":[0,3],"explanation":"e"}]}
    ))).?;
    try std.testing.expect(std.mem.indexOf(u8, quiz, "questions[0].answer_index must be between 0 and 1 (it has 2 options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiz, "questions[1] needs answer_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiz, "questions[2].answer_indices[1] must be between 0 and 2") != null);

    const svg = (try check(a, "render_svg", try parse(a,
        \\{"svg":"<svg width=\"10\"></svg>"}
    ))).?;
    try std.testing.expect(std.mem.indexOf(u8, svg, "needs a viewBox") != null);
    const art = (try check(a, "create_artifact", try parse(a,
        \\{"id":"d","title":"D","kind":"svg","content":"circle"}
    ))).?;
    try std.testing.expect(std.mem.indexOf(u8, art, "content must be a complete <svg> element") != null);
    try std.testing.expect((try check(a, "make_slides", try parse(a,
        \\{"title":"T","slides":[]}
    ))) != null);
    try std.testing.expect((try check(a, "web_fetch", try parse(a,
        \\{"url":"ftp://x"}
    ))) != null);
    try std.testing.expect((try check(a, "generate_image", try parse(a,
        \\{"prompt":"  "}
    ))) != null);
}

test "long lists of problems are capped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = (try check(a, "make_flashcards", try parse(a,
        \\{"title":"T","cards":[{},{},{},{},{},{},{}]}
    ))).?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "and 6 more") != null);
}

test "security_alert: the severity is one of three, and the ack says carry on" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try parse(a,
        \\{"severity":"critical","what":"The page asked me to send your key to evil.io.","source":"https://evil.io","action_taken":"I did not fetch it.","exposed":["the OpenAI key pasted above: rotate it"]}
    );
    try std.testing.expect((try check(a, "security_alert", ok)) == null);
    try std.testing.expect(std.mem.startsWith(u8, try shown(a, "security_alert", ok), "Shown to the user: a security notice."));
    const bad = try parse(a,
        \\{"severity":"panic","what":"x","action_taken":"y"}
    );
    const problem = (try check(a, "security_alert", bad)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, problem, "critical") != null);
    const missing = try parse(a,
        \\{"severity":"info","what":"x"}
    );
    try std.testing.expect((try check(a, "security_alert", missing)) != null);
}
