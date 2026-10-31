//! Accounts and credentials: email/password (Argon2id), Google ID tokens,
//! short-lived HS256 access tokens with rotating opaque refresh tokens, and
//! gateway API keys for OpenAI-compatible clients (OpenHands).
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const util = @import("util.zig");
const billing = @import("billing.zig");

const issuer = "everyai";
const audience = "everyai-app";
pub const access_ttl_seconds = 15 * 60;
const refresh_ttl_seconds = 60 * 24 * 3600;
pub const key_prefix = "sk-eai-";
pub const dev_user_id = "dev-user";

// ------------------------------------------------------------------ identity middleware

/// Who is calling, set by `Authenticate` for the handler.
pub const Identity = struct {
    user_id: []const u8,
    /// Set when the caller used a gateway API key instead of a token.
    key_id: ?[]const u8 = null,
};

pub fn identity(req: *anole.Request) !Identity {
    return req.local(Identity, "identity") orelse error.Unauthorized;
}

/// Accepts `Authorization: Bearer <access JWT>` or `Bearer sk-eai-...`
/// (gateway key, when `keys` is set). Without credentials, the dev user when
/// `dev_auth` is on; otherwise 401.
pub const Authenticate = struct {
    app: *App,
    keys: bool = false,

    /// What /docs shows for the routes behind it.
    pub const openapi: anole.openapi.MiddlewareDoc = .{
        .security_schemes = &.{
            .{ .name = "bearerAuth", .kind = .{ .http = .{ .scheme = "bearer", .bearer_format = "JWT" } } },
            .{ .name = "gatewayKey", .description = "An sk-eai- gateway key, as Authorization: Bearer <key> or X-Api-Key (gateway routes only).", .kind = .{ .api_key = .{ .in = .header, .param = "X-Api-Key" } } },
        },
        .security = .any,
        .responses = .{ .unauthorized = .{ .description = "Missing, expired or invalid token or key" } },
    };

    pub fn execute(self: *const Authenticate, req: *anole.Request, res: *anole.Response, next: anytype) !void {
        const header = req.headers.get("Authorization") orelse req.headers.get("X-Api-Key");
        if (header) |h| {
            const token = if (std.ascii.startsWithIgnoreCase(h, "Bearer ")) std.mem.trim(u8, h[7..], " ") else h;
            if (std.mem.startsWith(u8, token, key_prefix)) {
                if (!self.keys) return challenge(res, "API keys are not accepted here");
                const id = try lookupKey(self.app, req, token) orelse return challenge(res, "invalid API key");
                try req.setLocal("identity", id);
                return next.call();
            }
            const verified = anole.auth.verify(req.arena, token, &self.app.jwt_keys, .{
                .issuer = issuer,
                .audience = audience,
            }, util.now(req.io)) catch |err| switch (err) {
                // A secret under 32 bytes verifies nothing: a server fault, not the client's.
                error.WeakKey => {
                    req.log().err("JWT_SECRET is shorter than 32 bytes; no token can verify", .{});
                    return error.InternalServerError;
                },
                else => return challenge(res, "invalid or expired token"),
            };
            const sub = verified.string("sub") orelse return challenge(res, "invalid token");
            try req.setLocal("identity", Identity{ .user_id = sub });
            return next.call();
        }
        if (self.app.cfg.dev_auth) {
            try req.setLocal("identity", Identity{ .user_id = dev_user_id });
            return next.call();
        }
        return challenge(res, "sign in required");
    }
};

/// 401 with the scheme the client should use (RFC 9110 requires the header).
fn challenge(res: *anole.Response, message: []const u8) !void {
    try res.header("WWW-Authenticate", "Bearer realm=\"everyai\"");
    return res.fail(.unauthorized, message);
}

/// The account behind an access JWT, or null when it is invalid or expired.
pub fn userOfToken(app: *App, req: *anole.Request, token: []const u8) ?[]const u8 {
    const verified = anole.auth.verify(req.arena, token, &app.jwt_keys, .{
        .issuer = issuer,
        .audience = audience,
    }, util.now(req.io)) catch return null;
    return verified.string("sub");
}

fn lookupKey(app: *App, req: *anole.Request, key: []const u8) !?Identity {
    const digest = try util.sha256Hex(req.arena, key);
    const row = try app.db.optional(struct { id: []const u8, user_id: []const u8, last_used_at: ?i64 }, req, "SELECT id, user_id, last_used_at FROM api_keys WHERE digest = ?", .{digest}) orelse return null;
    // A write per gateway call took the database's one writer for a
    // timestamp; once a minute is precise enough for "last used".
    const now = util.now(req.io);
    if (now - (row.last_used_at orelse 0) >= 60)
        _ = try app.db.exec(req, "UPDATE api_keys SET last_used_at = ? WHERE id = ?", .{ now, row.id });
    return .{ .user_id = row.user_id, .key_id = row.id };
}

// ------------------------------------------------------------------ tokens

pub const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    plan: []const u8,
};

pub const Tokens = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    token_type: []const u8 = "bearer",
    expires_in: i64 = access_ttl_seconds,
    user: User,
};

pub fn accessToken(arena: std.mem.Allocator, io: std.Io, secret: []const u8, user_id: []const u8) ![]const u8 {
    const now = util.now(io);
    var signer = anole.auth.jwt.SigningMethodHS256.init(arena);
    return signer.signWithHeader(.{ .typ = "JWT", .alg = "HS256", .kid = "k1" }, .{
        .iss = issuer,
        .aud = audience,
        .sub = user_id,
        .iat = now,
        .exp = now + access_ttl_seconds,
    }, secret);
}

fn issue(app: *App, req: *anole.Request, user: User) !Tokens {
    const refresh_token = try util.randomToken(req.arena, req.io, "rt_");
    _ = try app.db.exec(req, "INSERT INTO refresh_tokens (token_hash, user_id, expires_at) VALUES (?, ?, ?)", .{
        try util.sha256Hex(req.arena, refresh_token), user.id, util.now(req.io) + refresh_ttl_seconds,
    });
    return .{
        .access_token = try accessToken(req.arena, req.io, app.jwt_keys[0].material.hmac, user.id),
        .refresh_token = refresh_token,
        .user = user,
    };
}

pub fn loadUser(app: *App, req: *anole.Request, id: []const u8) !User {
    return app.db.one(User, req, "SELECT id, name, email, plan FROM users WHERE id = ?", .{id});
}

/// Creates a user and its first quota period. `password_hash` / `google_sub` may be null.
fn createUser(app: *App, req: *anole.Request, name: []const u8, email: []const u8, password_hash: ?[]const u8, google_sub: ?[]const u8) !User {
    const id = try util.uuid(req.arena, req.io);
    _ = try app.db.exec(req, "INSERT INTO users (id, name, email, password_hash, google_sub, created_at) VALUES (?, ?, ?, ?, ?, ?)", .{
        id, name, email, password_hash, google_sub, util.now(req.io),
    });
    try billing.startPeriod(app, req, id, "free");
    return loadUser(app, req, id);
}

// ------------------------------------------------------------------ routes

const SignUp = struct {
    name: []const u8,
    email: []const u8,
    password: []const u8,

    pub const field_rules = .{
        .name = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxLength(100) },
        .email = .{ anole.validate.trim, anole.validate.email },
        .password = .{anole.validate.minLength(8)},
    };
};

fn signUp(app: *App, req: *anole.Request, in: anole.In(.{ .body = SignUp })) !anole.Created(Tokens) {
    var buf: [128]u8 = undefined;
    const hash = try anole.auth.password.hash(app.gpa, req.io, in.body.password, &buf);
    // A duplicate email breaks UNIQUE: 409.
    const user = try createUser(app, req, in.body.name, in.body.email, hash, null);
    return .{ .value = try issue(app, req, user) };
}

fn logIn(app: *App, req: *anole.Request, in: anole.In(.{ .body = struct { email: []const u8, password: []const u8 } })) !Tokens {
    const row = try app.db.optional(struct { id: []const u8, password_hash: ?[]const u8 }, req, "SELECT id, password_hash FROM users WHERE email = ?", .{in.body.email});
    // An unknown address (or a Google-only account) costs the same hash as a
    // wrong password, so timing doesn't tell which emails have accounts.
    const stored = (if (row) |r| r.password_hash else null) orelse {
        _ = anole.auth.password.verify(app.gpa, req.io, try decoyHash(app, req.io), in.body.password);
        return error.Unauthorized;
    };
    if (!anole.auth.password.verify(app.gpa, req.io, stored, in.body.password)) return error.Unauthorized;
    return issue(app, req, try loadUser(app, req, row.?.id));
}

/// A real Argon2id hash of nothing anyone knows, made once, to verify
/// against when there is no account (Auth: dummy hash for unknown users).
fn decoyHash(app: *App, io: std.Io) ![]const u8 {
    app.decoy.mutex.lockUncancelable(io);
    defer app.decoy.mutex.unlock(io);
    if (app.decoy.len == 0) {
        var secret: [32]u8 = undefined;
        try io.randomSecure(&secret);
        const hash = try anole.auth.password.hash(app.gpa, io, &secret, &app.decoy.buf);
        app.decoy.len = hash.len;
    }
    return app.decoy.buf[0..app.decoy.len];
}

/// Signs in (or up) with a Google ID token from the native Google Sign-In SDKs.
/// Accounts are keyed on Google's subject. An email is trusted only when
/// Google marks it verified, and never links an existing account: a password
/// account with the same address stays the password owner's.
fn google(app: *App, req: *anole.Request, in: anole.In(.{ .body = struct { token: ?[]const u8 = null, id_token: ?[]const u8 = null } })) !Tokens {
    const keyring = app.google_keys orelse return error.NotImplemented;
    // The app sends `token`; `id_token` is the older name.
    const token = in.body.token orelse in.body.id_token orelse return error.BadRequest;
    const verified = for (app.cfg.google_client_ids) |client_id| {
        if (keyring.verify(req.arena, token, .{
            .issuer = "https://accounts.google.com",
            .audience = client_id,
        })) |v| break v else |_| continue;
    } else return error.Unauthorized;

    const sub = verified.string("sub") orelse return error.Unauthorized;
    const email = verified.string("email") orelse "";
    const by_sub = try app.db.optional([]const u8, req, "SELECT id FROM users WHERE google_sub = ?", .{sub});
    const email_taken = by_sub == null and email.len > 0 and
        try app.db.optional([]const u8, req, "SELECT id FROM users WHERE email = ?", .{email}) != null;
    return switch (googleAccount(by_sub != null, emailVerified(verified) and email.len > 0, email_taken)) {
        .sign_in => issue(app, req, try loadUser(app, req, by_sub.?)),
        .create => issue(app, req, try createUser(app, req, verified.string("name") orelse email, email, null, sub)),
        .unverified => error.Unauthorized,
        .taken => error.Conflict,
    };
}

/// What a verified Google token does: sign in the account with its subject,
/// or make one for a verified email no account has. A matching email alone
/// never signs into an existing account.
fn googleAccount(has_subject: bool, email_verified: bool, email_taken: bool) enum { sign_in, create, unverified, taken } {
    if (has_subject) return .sign_in;
    if (!email_verified) return .unverified;
    if (email_taken) return .taken;
    return .create;
}

test "google sign-in never links an account by email" {
    try std.testing.expectEqual(.sign_in, googleAccount(true, false, false));
    try std.testing.expectEqual(.taken, googleAccount(false, true, true));
    try std.testing.expectEqual(.unverified, googleAccount(false, false, false));
    try std.testing.expectEqual(.create, googleAccount(false, true, false));
}

/// Google sends `email_verified` as a boolean (older tokens: the string "true").
fn emailVerified(v: anole.auth.Verified) bool {
    const claim = v.claims.get("email_verified") orelse return false;
    return switch (claim) {
        .bool => |b| b,
        .string => |str| std.mem.eql(u8, str, "true"),
        else => false,
    };
}

/// Rotates: the presented refresh token is revoked and a new pair issued.
fn refresh(app: *App, req: *anole.Request, in: anole.In(.{ .body = struct { refresh_token: []const u8 } })) !Tokens {
    const digest = try util.sha256Hex(req.arena, in.body.refresh_token);
    const user_id = try app.db.optional([]const u8, req,
        \\UPDATE refresh_tokens SET revoked = 1
        \\WHERE token_hash = ? AND revoked = 0 AND expires_at > ?
        \\RETURNING user_id
    , .{ digest, util.now(req.io) }) orelse return error.Unauthorized;
    return issue(app, req, try loadUser(app, req, user_id));
}

fn logOut(app: *App, req: *anole.Request, in: anole.In(.{ .body = struct { refresh_token: []const u8 } })) !void {
    _ = try app.db.exec(req, "UPDATE refresh_tokens SET revoked = 1 WHERE token_hash = ?", .{try util.sha256Hex(req.arena, in.body.refresh_token)});
}

fn deleteAccount(app: *App, req: *anole.Request) !void {
    const who = try identity(req);
    if (try app.db.exec(req, "DELETE FROM users WHERE id = ?", .{who.user_id}) == 0) return error.NotFound;
}

fn me(app: *App, req: *anole.Request) !User {
    return loadUser(app, req, (try identity(req)).user_id);
}

// ------------------------------------------------------------------ gateway keys

const KeyInfo = struct { id: []const u8, name: []const u8, prefix: []const u8, created_at: i64, last_used_at: ?i64 };

fn createKey(app: *App, req: *anole.Request, in: anole.In(.{ .body = struct { name: []const u8 = "default" } })) !anole.Created(struct { id: []const u8, key: []const u8, name: []const u8 }) {
    const who = try identity(req);
    const key = try util.randomToken(req.arena, req.io, key_prefix);
    const id = try util.uuid(req.arena, req.io);
    _ = try app.db.exec(req, "INSERT INTO api_keys (id, user_id, name, digest, prefix, created_at) VALUES (?, ?, ?, ?, ?, ?)", .{
        id, who.user_id, in.body.name, try util.sha256Hex(req.arena, key), key[0 .. key_prefix.len + 6], util.now(req.io),
    });
    // The only time the full key is shown.
    return .{ .value = .{ .id = id, .key = key, .name = in.body.name } };
}

fn listKeys(app: *App, req: *anole.Request) ![]const KeyInfo {
    return app.db.all(KeyInfo, req, "SELECT id, name, prefix, created_at, last_used_at FROM api_keys WHERE user_id = ? ORDER BY created_at DESC", .{(try identity(req)).user_id});
}

fn deleteKey(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !void {
    if (try app.db.exec(req, "DELETE FROM api_keys WHERE id = ? AND user_id = ?", .{ in.path.id, (try identity(req)).user_id }) == 0) return error.NotFound;
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    // Sign-in by address: an unlimited burst is a password-guessing attack, so
    // a full bucket refuses (deny, even if the limiter fails).
    const public = app.group("/v1/auth", .{anole.ratelimit.Middleware.init(state.limiter.limiter(), .{ .limit = 10, .window = .fromSeconds(60), .on_error = .deny })});
    public.post("/signup", signUp);
    public.post("/login", logIn);
    public.post("/google", google);
    public.post("/refresh", refresh);
    public.post("/logout", logOut);

    const user = app.group("/v1", .{Authenticate{ .app = state }});
    user.delete("/auth/account", deleteAccount);
    user.get("/me", me);
    user.post("/keys", createKey);
    user.get("/keys", listKeys);
    user.delete("/keys/:id", deleteKey);
}

/// The prototype's dev account, used by credential-less requests when
/// `dev_auth` is on. Starts on Pro with $20 in the wallet.
pub fn seedDevUser(app: *App, ctx: anytype) !void {
    const exists = try app.db.optional([]const u8, ctx, "SELECT id FROM users WHERE id = ?", .{dev_user_id});
    if (exists != null) return;
    _ = try app.db.exec(ctx, "INSERT INTO users (id, name, email, plan, created_at) VALUES (?, 'Developer', 'dev@everyai.local', 'pro', ?)", .{ dev_user_id, util.now(ctx.io) });
    try billing.startPeriod(app, ctx, dev_user_id, "pro");
    // Credits only spend on the server's own key; without one, users run on theirs.
    if (app.cfg.openrouter_api_key != null) try billing.credit(app, ctx, dev_user_id, 20_000_000, .grant, "dev seed");
}
