//! `GET /v1/usage` aggregates (the Settings → Usage screen), in memory.
const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");
const openrouter = app_main.openrouter;
const config = app_main.config;
const billing = app_main.billing;

const alloc = std.testing.allocator;
const Server = anole.Server(app_main.App);

const models_json =
    \\{"data":[
    \\{"id":"anthropic/claude-haiku-5.5","name":"Anthropic: Claude Haiku 5.5","description":"Fast.","context_length":1000000,
    \\ "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
    \\ "pricing":{"prompt":"0.000001","completion":"0.000005","input_cache_read":"0.0000001"},"supported_parameters":["tools"]}
    \\]}
;

const Env = struct {
    state: app_main.App,
    fake: openrouter.Fake,
    server: Server,
    t: anole.testing.Client(Server),

    fn deinit(self: *Env) void {
        self.t.deinit();
        self.server.deinit();
        self.state.catalog.deinit();
        self.fake.deinit();
    }
};

fn start(env: *Env) !void {
    env.fake = .{ .responses = &.{""}, .gpa = alloc, .models_json = models_json };
    const cfg: config.Config = .{
        .jwt_secret = .init("test-secret-0123456789abcdef0123456789"),
        .openrouter_api_key = .init("sk-or-test"),
        .dev_auth = true,
    };
    env.state = .{
        .gpa = alloc,
        .cfg = cfg,
        .db = undefined,
        .jwt_keys = .{.{ .kid = "k1", .alg = .HS256, .material = .{ .hmac = cfg.jwt_secret.?.expose() } }},
        .upstream = env.fake.upstream(),
        .catalog = .init(alloc),
    };
    env.server = try Server.init(alloc, .{ .executors = .exact(2), .limits = .{ .body_max = app_main.body_max } }, &env.state);
    env.state.db = try env.server.sqlite(":memory:");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    try app_main.prepare(&env.state, &c);
    try app_main.routes(&env.server, &env.state);
    env.t = try anole.testing.client(&env.server);
}

test "bucketStart: local midnight and Monday weeks" {
    // 2026-10-30 (a Friday) 15:00 UTC.
    const t: i64 = 1_793_372_400;
    try std.testing.expectEqual(@as(i64, 1_793_318_400), billing.bucketStart(t, false, 0));
    // UTC-4: local midnight is 04:00 UTC.
    try std.testing.expectEqual(@as(i64, 1_793_318_400 + 4 * 3600), billing.bucketStart(t, false, -4 * 3600));
    // Monday 2026-10-26 00:00 UTC.
    try std.testing.expectEqual(@as(i64, 1_792_972_800), billing.bucketStart(t, true, 0));
    try std.testing.expectEqual(@as(i64, 1_792_972_800), billing.bucketStart(1_792_972_800, true, 0));
    // Offsets past the real range are clamped rather than overflowing.
    _ = billing.bucketStart(t, true, std.math.maxInt(i64));
    _ = billing.bucketStart(t, false, std.math.minInt(i64));
}

test "usage: day and week aggregates by model, kind and provider with cache savings" {
    var env: Env = undefined;
    try start(&env);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };

    const day: i64 = 1_793_318_400; // Friday 2026-10-30 00:00 UTC
    const Ev = struct { t: i64, kind: []const u8, model: []const u8, provider: []const u8, cached: i64, charged: i64 };
    const events = [_]Ev{
        .{ .t = day - 86400 + 60, .kind = "chat", .model = "anthropic/claude-haiku-5.5", .provider = "anthropic", .cached = 1_000_000, .charged = 500 },
        .{ .t = day + 60, .kind = "chat", .model = "anthropic/claude-haiku-5.5", .provider = "openrouter", .cached = 0, .charged = 300 },
        .{ .t = day + 120, .kind = "gateway", .model = "anthropic/claude-haiku-5.5", .provider = "anthropic", .cached = 0, .charged = 200 },
        .{ .t = day + 180, .kind = "followups", .model = "unknown/model", .provider = "openrouter", .cached = 50, .charged = 10 },
    };
    for (events) |e| _ = try env.state.db.exec(&c,
        \\INSERT INTO usage_events (user_id, kind, model, prompt_tokens, completion_tokens, cached_tokens, cache_write_tokens,
        \\  cost_micros, charged_micros, from_quota_micros, from_wallet_micros, created_at, provider)
        \\VALUES ('dev-user', ?, ?, 100, 10, ?, 0, 0, ?, 0, 0, ?, ?)
    , .{ e.kind, e.model, e.cached, e.charged, e.t, e.provider });

    const Agg = struct {
        group: []const u8,
        by: []const u8,
        buckets: []const billing.Bucket,
        keys: []const billing.Bucket,
        total: billing.Bucket,
    };

    var by_model = try env.t.get("/v1/usage?group=day&by=model", .{});
    defer by_model.deinit();
    try by_model.expectStatus(.ok);
    const m = try by_model.json(Agg);
    try std.testing.expectEqual(@as(usize, 3), m.buckets.len);
    try std.testing.expectEqual(day - 86400, m.buckets[0].start);
    try std.testing.expectEqual(day, m.buckets[1].start);
    try std.testing.expectEqualStrings("anthropic/claude-haiku-5.5", m.buckets[1].key);
    try std.testing.expectEqual(@as(i64, 2), m.buckets[1].calls);
    try std.testing.expectEqual(@as(i64, 500), m.buckets[1].charged_micros);
    // 1M cached tokens at $0.90/M saved, marked up 1.15.
    try std.testing.expectEqual(@as(i64, 1_035_000), m.buckets[0].saved_micros);
    try std.testing.expectEqual(@as(i64, 1_035_000), m.total.saved_micros);
    try std.testing.expectEqual(@as(i64, 1010), m.total.charged_micros);
    try std.testing.expectEqual(@as(i64, 4), m.total.calls);
    try std.testing.expectEqualStrings("anthropic/claude-haiku-5.5", m.keys[0].key);
    try std.testing.expectEqual(@as(i64, 1000), m.keys[0].charged_micros);

    var by_provider = try env.t.get("/v1/usage?group=week&by=provider", .{});
    defer by_provider.deinit();
    const p = try by_provider.json(Agg);
    try std.testing.expectEqual(@as(usize, 2), p.buckets.len); // both days fall in one week
    try std.testing.expectEqualStrings("anthropic", p.keys[0].key);
    try std.testing.expectEqual(@as(i64, 700), p.keys[0].charged_micros);
    try std.testing.expectEqual(@as(i64, 310), p.keys[1].charged_micros);

    var by_kind = try env.t.get("/v1/usage?group=day&by=kind&from=1793318400", .{});
    defer by_kind.deinit();
    const k = try by_kind.json(Agg);
    try std.testing.expectEqual(@as(usize, 3), k.keys.len);
    try std.testing.expectEqual(@as(i64, 3), k.total.calls);

    var bad = try env.t.get("/v1/usage?group=month", .{});
    defer bad.deinit();
    try std.testing.expect(@backingInt(bad.status) >= 400);

    // Out-of-range offsets are refused instead of overflowing the bucket math.
    var huge = try env.t.get("/v1/usage?group=week&tz_offset=9223372036854775807", .{});
    defer huge.deinit();
    try std.testing.expect(@backingInt(huge.status) >= 400);
    var tiny = try env.t.get("/v1/usage?group=day&tz_offset=-9223372036854775808", .{});
    defer tiny.deinit();
    try std.testing.expect(@backingInt(tiny.status) >= 400);

    var rows = try env.t.get("/v1/usage", .{});
    defer rows.deinit();
    const r = try rows.json([]const struct { kind: []const u8 });
    try std.testing.expectEqual(@as(usize, 4), r.len);
}
