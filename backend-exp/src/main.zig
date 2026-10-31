//! EveryAI backend-exp: the prototype API on Anole.
//!
//!   zig build run     # http://localhost:8080
//!   zig build test
//!
//! Areas: auth (auth.zig), models shop (models.zig), chat over SSE with a
//! server-side tool loop (chat.zig), the OpenAI-compatible gateway for
//! OpenHands (gateway.zig), billing (billing.zig).
const std = @import("std");
const anole = @import("anole");
pub const config = @import("config.zig");
pub const migrations = @import("migrations.zig");
pub const auth = @import("auth.zig");
pub const billing = @import("billing.zig");
pub const models = @import("models.zig");
pub const chat = @import("chat.zig");
pub const gateway = @import("gateway.zig");
pub const util = @import("util.zig");
pub const openrouter = @import("openrouter.zig");
const agents = @import("agents.zig");
pub const tools = @import("tools.zig");
pub const images = @import("images.zig");
pub const routing = @import("routing.zig");
pub const polish = @import("polish.zig");
pub const anthropic = @import("anthropic.zig");
pub const devtools = @import("devtools.zig");
pub const safe_fetch = @import("net/safe_fetch.zig");
pub const tool_wait = @import("tool_wait.zig");
pub const remote = @import("remote.zig");
pub const byok = @import("byok.zig");
pub const decide = @import("decide.zig");

pub const std_options = anole.std_options;

/// The largest request body (chat attachments are inline base64).
pub const body_max = 32 << 20;
pub const panic = anole.panic;

/// The state every handler gets first.
pub const App = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    db: *anole.sqlite.Client,
    jwt_keys: [1]anole.auth.Key,
    google_keys: ?*anole.auth.Keyring = null,
    stripe_secrets: [1][]const u8 = .{""},
    /// OpenRouter: every model call goes here unless `route` says otherwise.
    /// Tests swap in a fake.
    upstream: openrouter.Upstream,
    /// Anthropic's own API (null without ANTHROPIC_API_KEY), for `anthropic/*`
    /// models while the dev switch `native_anthropic` is on.
    anthropic: ?openrouter.Upstream = null,
    native_anthropic: std.atomic.Value(bool) = .init(false),
    /// Tests: the transport for calls on a user's own key, instead of a
    /// client built with that key (the Anthropic adapter still wraps it).
    keyed_transport: ?openrouter.Upstream = null,
    catalog: models.Catalog,
    /// Chat turns parked on a tool the app runs (`POST /v1/chat/tool_result`).
    waits: tool_wait.Waits = .{},
    /// Fetches URLs from model tool calls (`web_fetch`), refusing local and
    /// private addresses; null (tests) fails every such fetch.
    web: ?*const safe_fetch.Fetcher = null,
    /// Live remote-host and client sockets (remote.zig).
    relay: remote.Relay = .{},
    /// Request buckets for the rate-limited routes (auth, pairing); set up in `routes`.
    limiter: anole.ratelimit.MemoryLimiter = undefined,
    /// The decoy password hash for sign-ins to unknown addresses (auth.zig).
    decoy: struct { mutex: std.Io.Mutex = .init, buf: [128]u8 = undefined, len: usize = 0 } = .{},
    /// Earlier web_search results per user and chat (web.zig).
    searches: @import("web.zig").SearchCache = .{},

    pub const Route = struct {
        up: openrouter.Upstream,
        provider: []const u8,
        /// On the user's own key (byok.zig): recorded, never charged.
        byok: bool = false,
    };

    /// Where a call to `model` goes. `native_ok` is false for calls that need
    /// OpenRouter features (the web plugin in Search mode).
    pub fn route(self: *App, model: []const u8, native_ok: bool) Route {
        if (native_ok and std.mem.startsWith(u8, model, "anthropic/") and self.native_anthropic.load(.monotonic)) {
            if (self.anthropic) |a| return .{ .up = a, .provider = "anthropic" };
        }
        return .{ .up = self.upstream, .provider = "openrouter" };
    }

    /// `route` for one request: a model the user's own key covers (byok.zig)
    /// goes out on that key and isn't charged. An Anthropic key takes
    /// `anthropic/*` models natively; an OpenRouter key takes the rest.
    pub fn routeFor(self: *App, req: *anole.Request, model: []const u8, native_ok: bool) !Route {
        const keys = byok.Keys.of(req);
        if (native_ok and byok.isAnthropic(model)) if (keys.anthropic) |k| {
            const adapter = try req.arena.create(anthropic.Adapter);
            adapter.* = .{ .inner = self.keyed_transport orelse inner: {
                const client = try req.arena.create(openrouter.Client);
                client.* = .{ .base_url = self.cfg.anthropic_base_url, .api_key = k, .auth = .anthropic };
                break :inner client.upstream();
            }, .catalog = &self.catalog };
            return .{ .up = adapter.upstream(), .provider = "anthropic", .byok = true };
        };
        if (keys.openrouter) |k| return self.onOpenRouterKey(req, k);
        return self.route(model, native_ok);
    }

    /// Whether a call nobody's key covers has nowhere to go: no server
    /// OpenRouter key, and not an `anthropic/*` model on a server Anthropic key.
    pub fn keyless(self: *App, covered: bool, model: []const u8, native_ok: bool) bool {
        if (covered or self.cfg.openrouter_api_key != null) return false;
        return !std.mem.eql(u8, self.route(model, native_ok).provider, "anthropic");
    }

    /// Side calls (follow-ups, titles, researchers, search, images) use
    /// OpenRouter models: on the user's OpenRouter key when there is one.
    pub fn aux(self: *App, req: *anole.Request) !Route {
        if (byok.Keys.of(req).openrouter) |k| return self.onOpenRouterKey(req, k);
        return .{ .up = self.upstream, .provider = "openrouter" };
    }

    fn onOpenRouterKey(self: *App, req: *anole.Request, key: []const u8) !Route {
        if (self.keyed_transport) |t| return .{ .up = t, .provider = "openrouter", .byok = true };
        const client = try req.arena.create(openrouter.Client);
        client.* = .{ .base_url = self.cfg.openrouter_base_url, .api_key = key, .referer = self.cfg.public_url };
        return .{ .up = client.upstream(), .provider = "openrouter", .byok = true };
    }
};

fn ping(_: *App, _: *anole.Request) struct { ok: bool, service: []const u8 } {
    return .{ .ok = true, .service = "everyai-backend-exp" };
}

fn catalogLoaded(ctx: ?*anyopaque) bool {
    const state: *App = @ptrCast(@alignCast(ctx.?));
    return state.catalog.fetched_at > 0;
}

/// Apart from `main` so the tests serve the same routes.
pub fn routes(app: *anole.Server(App), state: *App) !void {
    // One process: buckets live in memory (the caller deinits it).
    state.limiter = .init(state.gpa, app.io(), .{});
    // /readyz waits for the model catalog: without it chat can't price or route.
    try app.health(.{}).addCheck("catalog", catalogLoaded, state);
    app.openapi(.{ .info = .{ .title = "EveryAI API", .version = "0.1.0" } });
    app.get("/v1/ping", ping);
    auth.routes(app, state);
    billing.routes(app, state);
    models.routes(app, state);
    chat.routes(app, state);
    gateway.routes(app, state);
    images.routes(app, state);
    routing.routes(app, state);
    decide.routes(app, state);
    polish.routes(app, state);
    devtools.routes(app, state);
    agents.routes(app, state);
    remote.routes(app, state);
}

/// Schema and seed data; run before serving.
pub fn prepare(state: *App, ctx: anytype) !void {
    _ = try anole.db.migrate(state.db, ctx, &migrations.all);
    const saved = try state.db.optional([]const u8, ctx, "SELECT value FROM settings WHERE key = 'upstream.anthropic'", .{});
    state.native_anthropic.store(std.mem.eql(u8, saved orelse state.cfg.anthropic_upstream, "anthropic"), .monotonic);
    if (state.cfg.dev_auth) try auth.seedDevUser(state, ctx);
    try pruneExpired(state, ctx);
}

/// Drops refresh tokens and pairing codes nobody can use any more (expired
/// or revoked); they pile up otherwise. Runs at each start.
fn pruneExpired(state: *App, ctx: anytype) !void {
    const now = util.now(ctx.io);
    _ = try state.db.exec(ctx, "DELETE FROM refresh_tokens WHERE expires_at < ? OR revoked = 1", .{now});
    // A decided pairing stays a day for its status poll.
    _ = try state.db.exec(ctx, "DELETE FROM remote_pairings WHERE expires_at < ? AND (decide_by IS NULL OR decide_by < ?)", .{ now - 86_400, now - 86_400 });
}

pub fn main(init: std.process.Init) !void {
    // Development reads backend-exp/.env, then the monorepo's root .env; a
    // production process reads the real environment only (Config: a dev .env
    // copied into an image must not supply a production secret).
    const env_files: []const []const u8 = if (anole.env.environment() == .development) &.{ ".env", "../.env" } else &.{};
    const cfg = try anole.config.load(config.Config, init, .{ .env_files = env_files });

    if (config.lanExposure(cfg)) {
        std.log.err("refusing to start: HOST={s} is reachable from the network and DEV_AUTH=true lets anyone there use the dev account. " ++
            "Set DEV_AUTH=false, bind HOST=127.0.0.1, or set DEV_AUTH_LAN=true to accept this on a trusted LAN.", .{cfg.host});
        return error.DevAuthOnLan;
    }

    // Without JWT_SECRET (development only) a random one serves this run:
    // access tokens die at a restart, refresh tokens (rows) don't.
    var jwt_random: [32]u8 = undefined;
    var jwt_hex: [64]u8 = undefined;
    const jwt_secret: []const u8 = if (cfg.jwt_secret) |s| s.expose() else blk: {
        if (anole.env.environment() != .development) {
            std.log.err("refusing to start: JWT_SECRET is required in production", .{});
            return error.MissingJwtSecret;
        }
        try init.io.randomSecure(&jwt_random);
        jwt_hex = std.fmt.bytesToHex(jwt_random, .lower);
        std.log.info("JWT_SECRET not set: using a random one for this run", .{});
        break :blk &jwt_hex;
    };
    if (cfg.openrouter_api_key == null) std.log.info("OPENROUTER_API_KEY not set: model calls run on the keys users add in the app", .{});

    var state: App = .{
        .gpa = init.gpa,
        .cfg = cfg,
        .db = undefined,
        .jwt_keys = .{.{ .kid = "k1", .alg = .HS256, .material = .{ .hmac = jwt_secret } }},
        .upstream = undefined,
        .catalog = .init(init.gpa),
    };
    defer state.catalog.deinit();
    defer state.searches.deinit(init.gpa);
    // After the server (defers run last first): rooms outlive their sockets.
    defer state.relay.deinit();

    var app = try anole.Server(App).init(init.gpa, .{
        .http = .{ .address = cfg.host, .port = cfg.port },
        // The same files for Anole's own variables (ANOLE_*, PORT).
        .env_files = env_files,
        // Argon2 runs on the blocking pool, not an executor.
        .blocking = .{},
        // Upstream model calls stream, and a streamed fetch's budget ends at the
        // response head (openrouter.zig sets its own). Idempotent calls (the
        // catalog, Google's keys) are retried; a host that keeps failing
        // trips its breaker and fails fast (503) instead of hanging turns.
        .client = .{ .timeout = .fromSeconds(60), .retry = .{ .attempts = 3 }, .breaker = .{} },
        // Chat attachments (images, PDFs) arrive inline as base64.
        .limits = .{ .body_max = body_max },
        // A JSON API: its own errors (404, 405, res.fail) are JSON for every client.
        .errors = .json,
        // The default 30 s request deadline; slow handlers set their own
        // (req.setTimeout), and a stream's deadline ends at its head.
    }, &state);
    defer app.deinit();
    const io = app.io();

    var or_client: openrouter.Client = .{ .base_url = cfg.openrouter_base_url, .api_key = if (cfg.openrouter_api_key) |k| k.expose() else "", .referer = cfg.public_url };
    state.upstream = or_client.upstream();
    var an_client: openrouter.Client = .{ .base_url = cfg.anthropic_base_url, .api_key = if (cfg.anthropic_api_key) |k| k.expose() else "", .auth = .anthropic };
    var an_adapter: anthropic.Adapter = .{ .inner = an_client.upstream(), .catalog = &state.catalog };
    if (cfg.anthropic_api_key != null) state.anthropic = an_adapter.upstream();

    // Its own client: the shared one may reach local upstreams in development.
    var web_client = anole.http.Client.init(init.gpa, io, safe_fetch.clientOptions(.{}));
    defer web_client.deinit();
    const web: safe_fetch.Fetcher = .{ .http = &web_client };
    state.web = &web;

    if (cfg.google_client_ids.len > 0) {
        const keyring = try init.arena.allocator().create(anole.auth.Keyring);
        keyring.* = anole.auth.Keyring.init(init.gpa, io, app.client(), anole.auth.oidc.Provider.google.jwks_uri);
        state.google_keys = keyring;
    }
    defer if (state.google_keys) |k| k.deinit();

    app.use(anole.middleware.RequestId.init(.{}));
    app.use(anole.observe.AccessLog.init(.{ .exclude = &anole.observe.probe_paths }));
    app.use(anole.middleware.Cors.init(.{}));

    const dir = std.fs.path.dirname(cfg.database_path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    state.db = try app.sqlite(cfg.database_path);
    var setup_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer setup_arena.deinit();
    var setup: anole.db.Ctx = .{ .io = io, .arena = setup_arena.allocator() };
    try prepare(&state, &setup);
    // The catalog before the first request, so none waits for it (the first
    // stale one later refreshes; a failure here leaves that to it).
    state.catalog.refresh(state.upstream, io, cfg.markup) catch |err| std.log.warn("model catalog not loaded at start: {t}", .{err});

    try routes(&app, &state);
    defer state.limiter.deinit();
    std.log.info("EveryAI backend-exp on :{d} (dev_auth={}, markup={d:.2}, stripe={s}, claude via {s})", .{
        cfg.port, cfg.dev_auth, cfg.markup, if (cfg.stripe_secret_key == null) "mock" else "test", state.route("anthropic/", true).provider,
    });
    try app.run();
}

test {
    _ = util;
    _ = tools;
    _ = chat;
    _ = gateway;
    _ = safe_fetch;
    _ = models;
    _ = anthropic;
    _ = agents;
    _ = tool_wait;
    _ = polish;
    _ = remote;
    _ = byok;
    _ = decide;
    // Modules the app reaches only through others: listed so their tests run too.
    _ = @import("auth.zig");
    _ = @import("config.zig");
    _ = @import("openrouter.zig");
    _ = @import("images.zig");
    _ = @import("research.zig");
    _ = @import("routing.zig");
    _ = @import("truncation.zig");
    _ = @import("web.zig");
    _ = @import("tool_check.zig");
    _ = @import("modes.zig");
}
