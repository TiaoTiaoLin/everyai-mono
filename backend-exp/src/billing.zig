//! Plans, quotas and the prepaid wallet. Every paid upstream call costs
//! upstream cost × markup (micro-USD), taken first from the plan's monthly
//! included usage, then from the wallet. Zero-cost (free) models never charge.
//! Periods renew lazily on the first charge after they end.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const util = @import("util.zig");
const auth = @import("auth.zig");

pub const Plan = struct {
    id: []const u8,
    name: []const u8,
    /// Monthly price in cents (Stripe).
    price_cents: i64,
    /// Charged usage included per period, micro-USD (already marked up).
    included_micros: i64,
    blurb: []const u8,
};

pub const plans = [_]Plan{
    .{ .id = "free", .name = "Free", .price_cents = 0, .included_micros = 1_000_000, .blurb = "All free models, plus $1 of premium usage a month" },
    .{ .id = "pro", .name = "Pro", .price_cents = 2000, .included_micros = 20_000_000, .blurb = "$20 of usage a month, then pay as you go" },
    .{ .id = "max", .name = "Max", .price_cents = 10000, .included_micros = 100_000_000, .blurb = "$100 of usage a month, then pay as you go" },
};

pub const period_seconds = 30 * 24 * 3600;

pub fn planById(id: []const u8) ?Plan {
    for (plans) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

pub const CreditKind = enum { topup, usage, grant, refund };

pub fn credit(app: *App, ctx: anytype, user_id: []const u8, micros: i64, kind: CreditKind, ref: ?[]const u8) !void {
    try creditIn(app.db, ctx, user_id, micros, kind, ref);
}

// The `...In` helpers take a database handle: the client, or a transaction's
// `Tx` (the same calls), so callers can group writes into one transaction.

fn creditIn(db: anytype, ctx: anytype, user_id: []const u8, micros: i64, kind: CreditKind, ref: ?[]const u8) !void {
    _ = try db.exec(ctx, "INSERT INTO wallet_ledger (user_id, amount_micros, kind, ref, created_at) VALUES (?, ?, ?, ?, ?)", .{
        user_id, micros, @tagName(kind), ref, util.now(ctx.io),
    });
}

/// Opens a period for `plan_id` starting now (plan change or renewal), in
/// one transaction.
pub fn startPeriod(app: *App, ctx: anytype, user_id: []const u8, plan_id: []const u8) !void {
    const Run = struct {
        fn run(tx: *anole.sqlite.Tx, c: @TypeOf(ctx), user: []const u8, plan: []const u8) !void {
            try startPeriodIn(tx, c, user, plan);
        }
    };
    try app.db.transaction(ctx, .{ .retries = 3 }, Run.run, .{ ctx, user_id, plan_id });
}

pub fn startPeriodIn(db: anytype, ctx: anytype, user_id: []const u8, plan_id: []const u8) !void {
    const plan = planById(plan_id) orelse return error.UnknownPlan;
    const now = util.now(ctx.io);
    // Close any open period first.
    _ = try db.exec(ctx, "UPDATE quota_periods SET period_end = ? WHERE user_id = ? AND period_end > ?", .{ now, user_id, now });
    _ = try db.exec(ctx, "INSERT OR REPLACE INTO quota_periods (user_id, period_start, period_end, included_micros) VALUES (?, ?, ?, ?)", .{
        user_id, now, now + period_seconds, plan.included_micros,
    });
    _ = try db.exec(ctx, "UPDATE users SET plan = ? WHERE id = ?", .{ plan_id, user_id });
}

const Period = struct { period_start: i64, period_end: i64, included_micros: i64, used_micros: i64 };

const open_period_sql = "SELECT period_start, period_end, included_micros, used_micros FROM quota_periods WHERE user_id = ? AND period_end > ? ORDER BY period_start DESC LIMIT 1";

/// The open period. One that ended renews in a transaction (only a read
/// otherwise).
fn currentPeriod(app: *App, ctx: anytype, user_id: []const u8) !Period {
    if (try app.db.optional(Period, ctx, open_period_sql, .{ user_id, util.now(ctx.io) })) |p| return p;
    const Run = struct {
        fn run(tx: *anole.sqlite.Tx, c: @TypeOf(ctx), user: []const u8) !Period {
            return currentPeriodIn(tx, c, user);
        }
    };
    return app.db.transaction(ctx, .{ .retries = 3 }, Run.run, .{ ctx, user_id });
}

fn currentPeriodIn(db: anytype, ctx: anytype, user_id: []const u8) !Period {
    const now = util.now(ctx.io);
    if (try db.optional(Period, ctx, open_period_sql, .{ user_id, now })) |p| return p;
    const plan = try db.one([]const u8, ctx, "SELECT plan FROM users WHERE id = ?", .{user_id});
    try startPeriodIn(db, ctx, user_id, plan);
    return db.one(Period, ctx, open_period_sql, .{ user_id, now });
}

pub fn walletBalance(app: *App, ctx: anytype, user_id: []const u8) !i64 {
    return app.db.one(i64, ctx, "SELECT COALESCE(SUM(amount_micros), 0) FROM wallet_ledger WHERE user_id = ?", .{user_id});
}

/// What a paid request may still spend: quota left plus wallet.
pub fn available(app: *App, ctx: anytype, user_id: []const u8) !i64 {
    const p = try currentPeriod(app, ctx, user_id);
    return @max(0, p.included_micros - p.used_micros) + try walletBalance(app, ctx, user_id);
}

/// 402 before a paid call when nothing is left. Free models always pass.
pub fn preflight(app: *App, ctx: anytype, user_id: []const u8, model_is_free: bool) !void {
    if (model_is_free) return;
    if (try available(app, ctx, user_id) <= 0) return error.PaymentRequired;
}

pub const Usage = struct {
    kind: []const u8,
    model: []const u8,
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    cached_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
    /// Upstream cost in USD as reported.
    cost_usd: f64 = 0,
    session: ?[]const u8 = null,
    api_key_id: ?[]const u8 = null,
    /// Who served the call: "openrouter" or "anthropic".
    provider: []const u8 = "openrouter",
    /// Ran on the user's own key (byok.zig): recorded at cost, never charged.
    byok: bool = false,
};

pub const Charge = struct { cost_micros: i64, charged_micros: i64, from_quota: i64, from_wallet: i64 };

/// What a call on the user's own key cost them upstream (0 on credits), for
/// usage events: the app's meter shows it next to what EveryAI charged.
pub fn ownKeyCost(c: Charge, byok: bool) i64 {
    return if (byok) c.cost_micros else 0;
}

/// Records one upstream call and takes its price from quota, then wallet.
/// The wallet may go slightly negative on the call that crosses zero; the
/// next preflight stops further paid calls. One transaction (it holds the
/// writer), so concurrent calls (parallel researchers) can't both spend
/// the same quota.
pub fn charge(app: *App, ctx: anytype, user_id: []const u8, u: Usage) !Charge {
    const Run = struct {
        fn run(tx: *anole.sqlite.Tx, c: @TypeOf(ctx), user: []const u8, call: Usage, markup: f64) !Charge {
            return chargeIn(tx, c, user, call, markup);
        }
    };
    return app.db.transaction(ctx, .{ .retries = 3 }, Run.run, .{ ctx, user_id, u, app.cfg.markup });
}

fn chargeIn(db: anytype, ctx: anytype, user_id: []const u8, u: Usage, markup: f64) !Charge {
    const cost = util.usdToMicros(u.cost_usd);
    const charged = if (u.byok) 0 else util.applyMarkup(cost, markup);
    var from_quota: i64 = 0;
    var from_wallet: i64 = 0;
    if (charged > 0) {
        const p = try currentPeriodIn(db, ctx, user_id);
        from_quota = @min(charged, @max(0, p.included_micros - p.used_micros));
        from_wallet = charged - from_quota;
        if (from_quota > 0) _ = try db.exec(ctx, "UPDATE quota_periods SET used_micros = used_micros + ? WHERE user_id = ? AND period_start = ?", .{ from_quota, user_id, p.period_start });
        if (from_wallet > 0) try creditIn(db, ctx, user_id, -from_wallet, .usage, u.model);
    }
    _ = try db.exec(ctx,
        \\INSERT INTO usage_events (user_id, api_key_id, session, kind, model, prompt_tokens, completion_tokens,
        \\  cached_tokens, cache_write_tokens, cost_micros, charged_micros, from_quota_micros, from_wallet_micros, created_at, provider)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    , .{ user_id, u.api_key_id, u.session, u.kind, u.model, u.prompt_tokens, u.completion_tokens, u.cached_tokens, u.cache_write_tokens, cost, charged, from_quota, from_wallet, util.now(ctx.io), providerLabel(u) });
    return .{ .cost_micros = cost, .charged_micros = charged, .from_quota = from_quota, .from_wallet = from_wallet };
}

/// usage_events.provider: "openrouter" | "anthropic", with "-byok" on the user's key.
fn providerLabel(u: Usage) []const u8 {
    if (!u.byok) return u.provider;
    return if (std.mem.eql(u8, u.provider, "anthropic")) "anthropic-byok" else "openrouter-byok";
}

// ------------------------------------------------------------------ routes

const UsageRow = struct {
    created_at: i64,
    kind: []const u8,
    model: []const u8,
    prompt_tokens: i64,
    completion_tokens: i64,
    cached_tokens: i64,
    cache_write_tokens: i64,
    charged_micros: i64,
    session: ?[]const u8,
    provider: []const u8,
};

const usage_columns = "created_at, kind, model, prompt_tokens, completion_tokens, cached_tokens, cache_write_tokens, charged_micros, session, provider";

fn summary(app: *App, req: *anole.Request) !struct {
    plan: Plan,
    plans: []const Plan,
    period_start: i64,
    period_end: i64,
    included_micros: i64,
    used_micros: i64,
    wallet_micros: i64,
    markup: f64,
    month_tokens: i64,
    month_cached_tokens: i64,
    recent: []const UsageRow,
} {
    const who = try auth.identity(req);
    const user = try auth.loadUser(app, req, who.user_id);
    const p = try currentPeriod(app, req, who.user_id);
    const tokens = try app.db.one(struct { t: i64, c: i64 }, req, "SELECT COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS t, COALESCE(SUM(cached_tokens), 0) AS c FROM usage_events WHERE user_id = ? AND created_at >= ?", .{ who.user_id, p.period_start });
    return .{
        .plan = planById(user.plan) orelse plans[0],
        .plans = &plans,
        .period_start = p.period_start,
        .period_end = p.period_end,
        .included_micros = p.included_micros,
        .used_micros = p.used_micros,
        .wallet_micros = try walletBalance(app, req, who.user_id),
        .markup = app.cfg.markup,
        .month_tokens = tokens.t,
        .month_cached_tokens = tokens.c,
        .recent = try app.db.all(UsageRow, req, "SELECT " ++ usage_columns ++ " FROM usage_events WHERE user_id = ? ORDER BY id DESC LIMIT 50", .{who.user_id}),
    };
}

const UsageQuery = struct {
    from: i64 = 0,
    to: i64 = std.math.maxInt(i64),
    limit: u32 = 500,
    /// "day" or "week" returns aggregates instead of rows.
    group: []const u8 = "",
    /// What each series is keyed by: "model", "kind" or "provider".
    by: []const u8 = "model",
    /// The caller's UTC offset in seconds, so buckets start at local midnight.
    tz_offset: i64 = 0,
    pub const field_rules = .{
        .group = .{anole.validate.oneOf(.{ "", "day", "week" })},
        .by = .{anole.validate.oneOf(.{ "model", "kind", "provider" })},
        // Real UTC offsets run from -12h to +14h; anything else is a bad request.
        .tz_offset = .{anole.validate.range(-max_tz_offset, max_tz_offset)},
    };
};

/// The widest real UTC offset, in seconds (UTC+14).
pub const max_tz_offset: i64 = 14 * 3600;

/// `GET /v1/usage`: the raw rows, or with `group=day|week` the totals per
/// bucket and key (`by=model|kind|provider`), per key and overall. Each
/// aggregate carries `saved_micros`, what cache reads saved against the
/// uncached input price (marked up; 0 for models the catalog doesn't list).
fn usage(app: *App, req: *anole.Request, res: *anole.Response, in: anole.In(.{ .query = UsageQuery })) !void {
    const who = try auth.identity(req);
    const q = in.query;
    if (q.group.len == 0) {
        return res.json(try app.db.all(UsageRow, req, "SELECT " ++ usage_columns ++ " FROM usage_events WHERE user_id = ? AND created_at BETWEEN ? AND ? ORDER BY id DESC LIMIT ?", .{ who.user_id, q.from, q.to, q.limit }));
    }
    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    try res.json(try aggregate(app, req, who.user_id, q));
}

pub const Bucket = struct {
    /// Unix seconds where the bucket starts (0 for per-key totals).
    start: i64 = 0,
    key: []const u8 = "",
    calls: i64 = 0,
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    cached_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
    charged_micros: i64 = 0,
    saved_micros: i64 = 0,

    fn add(self: *Bucket, o: Bucket) void {
        self.calls += o.calls;
        self.prompt_tokens += o.prompt_tokens;
        self.completion_tokens += o.completion_tokens;
        self.cached_tokens += o.cached_tokens;
        self.cache_write_tokens += o.cache_write_tokens;
        self.charged_micros += o.charged_micros;
        self.saved_micros += o.saved_micros;
    }
};

pub const Aggregate = struct {
    group: []const u8,
    by: []const u8,
    from: i64,
    to: i64,
    /// Ordered by start, then key.
    buckets: []const Bucket,
    /// One per key over the whole range, most charged first.
    keys: []const Bucket,
    total: Bucket,
};

/// Day buckets start at local midnight; week buckets on local Monday (the
/// epoch was a Thursday, hence the 3-day shift).
pub fn bucketStart(t: i64, week: bool, tz_offset: i64) i64 {
    const size: i64 = if (week) 7 * 86400 else 86400;
    // Clamped so no input can overflow below; `t` is a stored unix time.
    const shift: i64 = std.math.clamp(tz_offset, -max_tz_offset, max_tz_offset) + @as(i64, if (week) 3 * 86400 else 0);
    return @divFloor(t + shift, size) * size - shift;
}

fn aggregate(app: *App, req: *anole.Request, user_id: []const u8, q: UsageQuery) !Aggregate {
    const Row = struct { created_at: i64, key: []const u8, model: []const u8, prompt_tokens: i64, completion_tokens: i64, cached_tokens: i64, cache_write_tokens: i64, charged_micros: i64 };
    const cols = "created_at, model, prompt_tokens, completion_tokens, cached_tokens, cache_write_tokens, charged_micros FROM usage_events WHERE user_id = ? AND created_at BETWEEN ? AND ? ORDER BY created_at";
    const args = .{ user_id, q.from, q.to };
    const rows = if (std.mem.eql(u8, q.by, "kind"))
        try app.db.all(Row, req, "SELECT kind AS key, " ++ cols, args)
    else if (std.mem.eql(u8, q.by, "provider"))
        try app.db.all(Row, req, "SELECT provider AS key, " ++ cols, args)
    else
        try app.db.all(Row, req, "SELECT model AS key, " ++ cols, args);

    const week = std.mem.eql(u8, q.group, "week");
    var buckets: std.ArrayList(Bucket) = .empty;
    var keys: std.ArrayList(Bucket) = .empty;
    var total: Bucket = .{};
    for (rows) |r| {
        var saved: i64 = 0;
        if (r.cached_tokens > 0) if (app.catalog.pricesOf(req.io, r.model)) |p| {
            const per = p.base.prompt - p.base.cache_read;
            if (per > 0) saved = @intFromFloat(@round(per * @as(f64, @floatFromInt(r.cached_tokens)) * 1_000_000.0 * app.cfg.markup));
        };
        const one: Bucket = .{
            .start = bucketStart(r.created_at, week, q.tz_offset),
            .key = r.key,
            .calls = 1,
            .prompt_tokens = r.prompt_tokens,
            .completion_tokens = r.completion_tokens,
            .cached_tokens = r.cached_tokens,
            .cache_write_tokens = r.cache_write_tokens,
            .charged_micros = r.charged_micros,
            .saved_micros = saved,
        };
        total.add(one);
        // Rows come in time order, so the current bucket's entries are at the tail.
        var i = buckets.items.len;
        const b = while (i > 0 and buckets.items[i - 1].start == one.start) : (i -= 1) {
            if (std.mem.eql(u8, buckets.items[i - 1].key, one.key)) break &buckets.items[i - 1];
        } else blk: {
            try buckets.append(req.arena, .{ .start = one.start, .key = one.key });
            break :blk &buckets.items[buckets.items.len - 1];
        };
        b.add(one);
        const k = for (keys.items) |*k| {
            if (std.mem.eql(u8, k.key, one.key)) break k;
        } else blk: {
            try keys.append(req.arena, .{ .key = one.key });
            break :blk &keys.items[keys.items.len - 1];
        };
        k.add(one);
    }
    std.mem.sort(Bucket, buckets.items, {}, struct {
        fn lt(_: void, a: Bucket, b: Bucket) bool {
            if (a.start != b.start) return a.start < b.start;
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    std.mem.sort(Bucket, keys.items, {}, struct {
        fn lt(_: void, a: Bucket, b: Bucket) bool {
            if (a.charged_micros != b.charged_micros) return a.charged_micros > b.charged_micros;
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    return .{ .group = q.group, .by = q.by, .from = q.from, .to = q.to, .buckets = buckets.items, .keys = keys.items, .total = total };
}

const SessionTotals = struct {
    calls: i64,
    prompt_tokens: i64,
    completion_tokens: i64,
    cached_tokens: i64,
    cache_write_tokens: i64,
    charged_micros: i64,
    /// What calls on the user's own keys cost upstream (not charged): a
    /// spend cap counts these too.
    byok_cost_micros: i64 = 0,
    /// The latest model call (not follow-ups or images): how full the
    /// context window is now.
    last_prompt_tokens: i64 = 0,
    last_completion_tokens: i64 = 0,
};

/// Totals for one chat conversation or Code session (the `session` the app
/// or the gateway's `X-EveryAI-Session` named), for the composer meter.
fn sessionUsage(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !SessionTotals {
    const who = try auth.identity(req);
    var t = try app.db.one(SessionTotals, req,
        \\SELECT COUNT(*) AS calls, COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens, COALESCE(SUM(completion_tokens), 0) AS completion_tokens,
        \\  COALESCE(SUM(cached_tokens), 0) AS cached_tokens, COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
        \\  COALESCE(SUM(charged_micros), 0) AS charged_micros,
        \\  COALESCE(SUM(CASE WHEN provider LIKE '%-byok' THEN cost_micros ELSE 0 END), 0) AS byok_cost_micros,
        \\  0 AS last_prompt_tokens, 0 AS last_completion_tokens
        \\FROM usage_events WHERE user_id = ? AND session = ?
    , .{ who.user_id, in.path.id });
    if (try app.db.optional(struct { p: i64, c: i64 }, req, "SELECT prompt_tokens AS p, completion_tokens AS c FROM usage_events WHERE user_id = ? AND session = ? AND kind IN ('chat', 'gateway') ORDER BY id DESC LIMIT 1", .{ who.user_id, in.path.id })) |last| {
        t.last_prompt_tokens = last.p;
        t.last_completion_tokens = last.c;
    }
    return t;
}

const Checkout = struct {
    /// "topup" or "subscription".
    kind: []const u8,
    /// Top-up amount in cents (min $5).
    amount_cents: i64 = 0,
    /// Plan id for subscriptions.
    plan: []const u8 = "",
    pub const field_rules = .{ .kind = .{anole.validate.oneOf(.{ "topup", "subscription" })} };
};

/// Returns a Stripe Checkout URL, or (no Stripe key: mock mode) applies the
/// purchase right away and returns `mock: true`.
fn checkout(app: *App, req: *anole.Request, in: anole.In(.{ .body = Checkout })) !struct { url: ?[]const u8, mock: bool } {
    const who = try auth.identity(req);
    const is_topup = std.mem.eql(u8, in.body.kind, "topup");
    if (is_topup and in.body.amount_cents < 500) return error.UnprocessableEntity;
    const plan = if (is_topup) null else (planById(in.body.plan) orelse return error.UnprocessableEntity);

    const key = app.cfg.stripe_secret_key orelse {
        if (plan) |p| try startPeriod(app, req, who.user_id, p.id) else try credit(app, req, who.user_id, in.body.amount_cents * 10_000, .topup, "mock checkout");
        return .{ .url = null, .mock = true };
    };

    var form: std.Io.Writer.Allocating = .init(req.arena);
    const w = &form.writer;
    try w.print("success_url={s}/billing/done&cancel_url={s}/billing/cancel&client_reference_id={s}&line_items[0][quantity]=1&line_items[0][price_data][currency]=usd", .{ app.cfg.public_url, app.cfg.public_url, who.user_id });
    if (plan) |p| {
        try w.print("&mode=subscription&line_items[0][price_data][unit_amount]={d}&line_items[0][price_data][recurring][interval]=month&line_items[0][price_data][product_data][name]=EveryAI%20{s}&metadata[kind]=subscription&metadata[plan]={s}&subscription_data[metadata][user_id]={s}&subscription_data[metadata][plan]={s}", .{ p.price_cents, p.name, p.id, who.user_id, p.id });
    } else {
        try w.print("&mode=payment&line_items[0][price_data][unit_amount]={d}&line_items[0][price_data][product_data][name]=EveryAI%20credits&metadata[kind]=topup&metadata[amount_cents]={d}", .{ in.body.amount_cents, in.body.amount_cents });
    }

    var r = try anole.client(req).fetch("https://api.stripe.com/v1/checkout/sessions", .{
        .method = .post,
        .headers = &.{
            .{ "Authorization", try std.fmt.allocPrint(req.arena, "Bearer {s}", .{key.expose()}) },
            .{ "Content-Type", "application/x-www-form-urlencoded" },
            // Makes the POST safe to retry: Stripe answers a repeat with the same session.
            .{ "Idempotency-Key", try util.uuid(req.arena, req.io) },
        },
        .body = form.written(),
    });
    defer r.deinit();
    if (@backingInt(r.status()) >= 300) {
        req.log().err("stripe checkout failed", .{ .status = @backingInt(r.status()), .body = r.body() catch "" });
        return error.BadGateway;
    }
    const session = try r.json(struct { url: []const u8 }, req.arena);
    return .{ .url = session.url, .mock = false };
}

/// Stripe webhook (signature and duplicate deliveries handled by Anole's
/// `webhookVerify` preset). Credits top-ups and applies subscriptions.
/// The parts of a Stripe event this handler reads. Every field is optional:
/// a signed event of another shape is acknowledged, never a crash.
const StripeEvent = struct {
    type: []const u8 = "",
    data: ?struct { object: ?StripeObject = null } = null,
};

const StripeObject = struct {
    id: ?[]const u8 = null,
    client_reference_id: ?[]const u8 = null,
    /// An id, or the expanded object on newer API versions.
    subscription: ?std.json.Value = null,
    metadata: ?struct { kind: ?[]const u8 = null, amount_cents: ?[]const u8 = null, plan: ?[]const u8 = null } = null,

    fn subscriptionId(self: StripeObject) ?[]const u8 {
        const v = self.subscription orelse return null;
        return switch (v) {
            .string => |id| id,
            .object => |o| if (o.get("id")) |id| (if (id == .string) id.string else null) else null,
            else => null,
        };
    }
};

fn stripeWebhook(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const event = try req.bind(StripeEvent);
    const obj: StripeObject = if (event.data) |d| d.object orelse .{} else .{};
    const meta = obj.metadata orelse @as(@TypeOf(obj.metadata.?), .{});

    if (std.mem.eql(u8, event.type, "checkout.session.completed")) checkout: {
        const user_id = obj.client_reference_id orelse break :checkout;
        const kind = meta.kind orelse "";
        if (std.mem.eql(u8, kind, "topup")) {
            const cents = std.fmt.parseInt(i64, meta.amount_cents orelse break :checkout, 10) catch break :checkout;
            try credit(app, req, user_id, cents * 10_000, .topup, obj.id);
        } else if (std.mem.eql(u8, kind, "subscription")) {
            const plan = meta.plan orelse break :checkout;
            if (planById(plan) == null) break :checkout;
            const Run = struct {
                fn run(tx: *anole.sqlite.Tx, r: *anole.Request, user: []const u8, p: []const u8, sub_id: ?[]const u8) !void {
                    try startPeriodIn(tx, r, user, p);
                    _ = try tx.exec(r, "INSERT OR REPLACE INTO subscriptions (user_id, plan, status, stripe_subscription_id) VALUES (?, ?, 'active', ?)", .{ user, p, sub_id });
                }
            };
            try app.db.transaction(req, .{ .retries = 3 }, Run.run, .{ req, user_id, plan, obj.subscriptionId() });
        }
    } else if (std.mem.eql(u8, event.type, "invoice.paid")) {
        // Renewal: a fresh period for the subscription's plan.
        if (obj.subscriptionId()) |s| {
            if (try app.db.optional(struct { user_id: []const u8, plan: []const u8 }, req, "SELECT user_id, plan FROM subscriptions WHERE stripe_subscription_id = ?", .{s})) |sub|
                try startPeriod(app, req, sub.user_id, sub.plan);
        }
    } else if (std.mem.eql(u8, event.type, "customer.subscription.deleted")) {
        if (obj.id) |s| if (try app.db.optional([]const u8, req, "SELECT user_id FROM subscriptions WHERE stripe_subscription_id = ?", .{s})) |user_id| {
            const Run = struct {
                fn run(tx: *anole.sqlite.Tx, r: *anole.Request, user: []const u8) !void {
                    _ = try tx.exec(r, "UPDATE subscriptions SET status = 'canceled' WHERE user_id = ?", .{user});
                    try startPeriodIn(tx, r, user, "free");
                }
            };
            try app.db.transaction(req, .{ .retries = 3 }, Run.run, .{ req, user_id });
        };
    }
    res.status = .ok;
    try res.json(.{ .received = true });
}

fn listPlans(_: *App, _: *anole.Request) []const Plan {
    return &plans;
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    app.get("/v1/plans", listPlans);
    const user = app.group("/v1", .{auth.Authenticate{ .app = state }});
    user.get("/billing", summary);
    user.get("/usage", usage);
    user.get("/usage/session/:id", sessionUsage);
    user.post("/billing/checkout", checkout);
    if (state.cfg.stripe_webhook_secret) |secret| {
        // The middleware keeps the slice: it must outlive this function.
        state.stripe_secrets[0] = secret.expose();
        const hook = app.webhookVerify(.{ .preset = .stripe, .secrets = state.stripe_secrets[0..1] });
        app.with(.{hook}).post("/v1/billing/webhook", stripeWebhook);
    }
}
