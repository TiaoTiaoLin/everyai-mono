//! Dev-build switches (registered only with DEV_AUTH on). For now, where
//! `anthropic/*` models go: OpenRouter or Anthropic's own API.
//!
//!   GET /v1/dev/upstream   {anthropic: "openrouter"|"anthropic", keys: {openrouter, anthropic}}
//!   PUT /v1/dev/upstream   {anthropic}
//!
//! The choice is server-wide and survives restarts (`settings` table).
//! Search and Research stay on OpenRouter (its web plugin) either way.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");

const Upstreams = struct {
    anthropic: []const u8,
    keys: struct { openrouter: bool, anthropic: bool },
};

fn current(app: *App) Upstreams {
    return .{
        .anthropic = if (app.native_anthropic.load(.monotonic)) "anthropic" else "openrouter",
        .keys = .{ .openrouter = app.cfg.openrouter_api_key != null, .anthropic = app.anthropic != null },
    };
}

fn get(app: *App, _: *anole.Request) Upstreams {
    return current(app);
}

const Change = struct {
    anthropic: []const u8,
    pub const field_rules = .{ .anthropic = .{anole.validate.oneOf(.{ "openrouter", "anthropic" })} };
};

fn put(app: *App, req: *anole.Request, res: *anole.Response, in: anole.In(.{ .body = Change })) !void {
    const native = std.mem.eql(u8, in.body.anthropic, "anthropic");
    if (native and app.anthropic == null) return res.fail(.unprocessable_entity, "ANTHROPIC_API_KEY is not set on the server");
    _ = try app.db.exec(req, "INSERT OR REPLACE INTO settings (key, value) VALUES ('upstream.anthropic', ?)", .{in.body.anthropic});
    app.native_anthropic.store(native, .monotonic);
    req.log().info("dev: anthropic/* models switched", .{ .to = in.body.anthropic });
    try res.json(current(app));
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    if (!state.cfg.dev_auth) return;
    const dev = app.group("/v1/dev", .{auth.Authenticate{ .app = state }});
    dev.get("/upstream", get);
    dev.put("/upstream", put);
}
