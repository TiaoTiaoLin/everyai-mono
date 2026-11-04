//! Remote hosts: pairing over the routes in memory, and the relay over
//! loopback WebSockets (`anole.testing` cannot upgrade).
const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");
const openrouter = app_main.openrouter;
const config = app_main.config;

const alloc = std.testing.allocator;
const Server = anole.Server(app_main.App);

const Env = struct {
    state: app_main.App,
    fake: openrouter.Fake,
    server: Server,
    t: anole.testing.Client(Server),

    fn deinit(self: *Env) void {
        self.t.deinit();
        self.server.deinit();
        self.state.limiter.deinit();
        self.state.global_limiter.deinit();
        self.state.relay.deinit();
        self.state.catalog.deinit();
        self.fake.deinit();
    }
};

fn start(env: *Env, dev_auth: bool) !void {
    env.fake = .{ .responses = &.{""}, .gpa = alloc };
    const cfg: config.Config = .{
        .jwt_secret = .init("test-secret-0123456789abcdef0123456789"),
        .openrouter_api_key = .init("sk-or-test"),
        .dev_auth = dev_auth,
    };
    env.state = .{
        .gpa = alloc,
        .cfg = cfg,
        .db = undefined,
        .jwt_keys = .{.{ .kid = "k1", .alg = .HS256, .material = .{ .hmac = cfg.jwt_secret.?.expose() } }},
        .upstream = env.fake.upstream(),
        .catalog = .init(alloc),
    };
    env.server = try Server.init(alloc, .{ .executors = .exact(2) }, &env.state);
    env.state.db = try env.server.sqlite(":memory:");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = arena.allocator() };
    try app_main.prepare(&env.state, &c);
    try app_main.routes(&env.server, &env.state);
    env.t = try anole.testing.client(&env.server);
}

const Tokens = struct { access_token: []const u8 };
const NewHost = struct { id: []const u8, host_token: []const u8 };
const Code = struct { id: []const u8, code: []const u8, expires_at: i64 };
const Redeemed = struct { id: []const u8, status: []const u8, device_id: []const u8, device_token: []const u8, host: struct { id: []const u8, public_key: []const u8 } };
const Status = struct { status: []const u8 };
const HostList = []const struct { id: []const u8, online: bool, devices: []const struct { id: []const u8, name: []const u8 } };

fn signUp(env: *Env, a: std.mem.Allocator, email: []const u8) ![]const u8 {
    var res = try env.t.post("/v1/auth/signup", .{ .json = .{ .name = "Ada", .email = email, .password = "correct horse" } });
    defer res.deinit();
    try res.expectStatus(.created);
    return std.fmt.allocPrint(a, "Bearer {s}", .{(try res.json(Tokens)).access_token});
}

test "remote: pairing is single use, same account only, and needs the host's approval" {
    var env: Env = undefined;
    try start(&env, false);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const ada = try signUp(&env, a, "ada@example.com");
    const bob = try signUp(&env, a, "bob@example.com");

    var made = try env.t.post("/v1/remote/hosts", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .name = "Studio Mac", .platform = "macos", .public_key = "aG9zdC1wdWJsaWMta2V5" } });
    defer made.deinit();
    try made.expectStatus(.created);
    const host = try made.json(NewHost);
    try std.testing.expect(std.mem.startsWith(u8, host.host_token, "rh_"));

    // Someone else's host cannot hand out codes.
    var stranger = try env.t.post("/v1/remote/pair", .{ .headers = &.{.{ "Authorization", bob }}, .json = .{ .host_id = host.id } });
    defer stranger.deinit();
    try stranger.expectStatus(.not_found);

    var paired = try env.t.post("/v1/remote/pair", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .host_id = host.id } });
    defer paired.deinit();
    try paired.expectStatus(.created);
    const code = try paired.json(Code);
    try std.testing.expectEqual(@as(usize, 9), code.code.len);
    try std.testing.expectEqual(@as(u8, '-'), code.code[4]);

    // Another account's redeem looks like a wrong code.
    var other = try env.t.post("/v1/remote/pair/redeem", .{ .headers = &.{.{ "Authorization", bob }}, .json = .{ .code = code.code, .device_name = "Bob's phone", .public_key = "Ym9i" } });
    defer other.deinit();
    try other.expectStatus(.not_found);

    // Typed in lower case without the dash.
    const typed = try std.ascii.allocLowerString(a, try std.mem.replaceOwned(u8, a, code.code, "-", ""));
    var red = try env.t.post("/v1/remote/pair/redeem", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .code = typed, .device_name = "Ada's phone", .public_key = "cGhvbmU" } });
    defer red.deinit();
    try red.expectStatus(.ok);
    const redeemed = try red.json(Redeemed);
    try std.testing.expectEqualStrings("pending", redeemed.status);
    try std.testing.expectEqualStrings("aG9zdC1wdWJsaWMta2V5", redeemed.host.public_key);
    try std.testing.expect(std.mem.startsWith(u8, redeemed.device_token, "rd_"));

    var again = try env.t.post("/v1/remote/pair/redeem", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .code = code.code, .device_name = "Twice", .public_key = "eA" } });
    defer again.deinit();
    try again.expectStatus(.not_found);

    const status_path = try std.fmt.allocPrint(a, "/v1/remote/pair/{s}", .{redeemed.id});
    var pending = try env.t.get(status_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer pending.deinit();
    try std.testing.expectEqualStrings("pending", (try pending.json(Status)).status);

    // A pending device is not listed and cannot open a socket yet; the
    // client cannot approve itself without the host's token.
    const approve_path = try std.fmt.allocPrint(a, "/v1/remote/pair/{s}/approve", .{redeemed.id});
    var self_approve = try env.t.post(approve_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer self_approve.deinit();
    try self_approve.expectStatus(.unauthorized);
    var wrong_owner = try env.t.post(approve_path, .{ .headers = &.{ .{ "Authorization", bob }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer wrong_owner.deinit();
    try wrong_owner.expectStatus(.unauthorized);

    var ok = try env.t.post(approve_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer ok.deinit();
    try ok.expectStatus(.ok);
    try std.testing.expectEqualStrings("approved", (try ok.json(Status)).status);
    var twice = try env.t.post(approve_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer twice.deinit();
    try twice.expectStatus(.not_found);

    var approved = try env.t.get(status_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer approved.deinit();
    try std.testing.expectEqualStrings("approved", (try approved.json(Status)).status);

    var list = try env.t.get("/v1/remote/hosts", .{ .headers = &.{.{ "Authorization", ada }} });
    defer list.deinit();
    const hosts = try list.json(HostList);
    try std.testing.expectEqual(@as(usize, 1), hosts.len);
    try std.testing.expect(!hosts[0].online);
    try std.testing.expectEqual(@as(usize, 1), hosts[0].devices.len);
    try std.testing.expectEqualStrings("Ada's phone", hosts[0].devices[0].name);
    var bobs = try env.t.get("/v1/remote/hosts", .{ .headers = &.{.{ "Authorization", bob }} });
    defer bobs.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try bobs.json(HostList)).len);

    // An expired code is refused; a denied pairing leaves no device.
    var p2 = try env.t.post("/v1/remote/pair", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .host_id = host.id } });
    defer p2.deinit();
    const code2 = try p2.json(Code);
    var c: anole.db.Ctx = .{ .io = env.server.io(), .arena = a };
    _ = try env.state.db.exec(&c, "UPDATE remote_pairings SET expires_at = 0 WHERE id = ?", .{code2.id});
    var late = try env.t.post("/v1/remote/pair/redeem", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .code = code2.code, .device_name = "Late", .public_key = "eA" } });
    defer late.deinit();
    try late.expectStatus(.not_found);

    var p3 = try env.t.post("/v1/remote/pair", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .host_id = host.id } });
    defer p3.deinit();
    var r3 = try env.t.post("/v1/remote/pair/redeem", .{ .headers = &.{.{ "Authorization", ada }}, .json = .{ .code = (try p3.json(Code)).code, .device_name = "Tablet", .public_key = "eA" } });
    defer r3.deinit();
    const deny_path = try std.fmt.allocPrint(a, "/v1/remote/pair/{s}/deny", .{(try r3.json(Redeemed)).id});
    var denied = try env.t.post(deny_path, .{ .headers = &.{ .{ "Authorization", ada }, .{ "X-Remote-Host-Token", host.host_token } } });
    defer denied.deinit();
    try std.testing.expectEqualStrings("denied", (try denied.json(Status)).status);
    try std.testing.expectEqual(@as(i64, 1), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM remote_devices", .{}));

    // Unpairing and removing the host.
    const dev_path = try std.fmt.allocPrint(a, "/v1/remote/devices/{s}", .{redeemed.device_id});
    var gone = try env.t.delete(dev_path, .{ .headers = &.{.{ "Authorization", bob }} });
    defer gone.deinit();
    try gone.expectStatus(.not_found);
    var unpair = try env.t.delete(dev_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer unpair.deinit();
    try std.testing.expect(unpair.status == .no_content or unpair.status == .ok);
    const host_path = try std.fmt.allocPrint(a, "/v1/remote/hosts/{s}", .{host.id});
    var drop = try env.t.delete(host_path, .{ .headers = &.{.{ "Authorization", ada }} });
    defer drop.deinit();
    try std.testing.expect(drop.status == .no_content or drop.status == .ok);
    try std.testing.expectEqual(@as(i64, 0), try env.state.db.one(i64, &c, "SELECT COUNT(*) FROM remote_pairings", .{}));
}

/// The next text notice whose `type` is `want`, skipping others.
fn expectNotice(ws: *anole.websocket.Client, a: std.mem.Allocator, want: []const u8) !std.json.Value {
    for (0..8) |_| {
        const msg = try ws.receive();
        if (msg.type != .text) return error.UnexpectedBinary;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try a.dupe(u8, msg.data), .{});
        if (std.mem.eql(u8, v.object.get("type").?.string, want)) return v;
    }
    return error.NoSuchNotice;
}

test "remote: the relay carries opaque frames between host and client, and unpairing cuts the client off" {
    var env: Env = undefined;
    try start(&env, true); // the dev user, no tokens on the REST calls
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var made = try env.t.post("/v1/remote/hosts", .{ .json = .{ .name = "Studio Mac", .public_key = "aG9zdA" } });
    defer made.deinit();
    const host = try made.json(NewHost);
    var p = try env.t.post("/v1/remote/pair", .{ .json = .{ .host_id = host.id } });
    defer p.deinit();
    var r = try env.t.post("/v1/remote/pair/redeem", .{ .json = .{ .code = (try p.json(Code)).code, .device_name = "Phone", .public_key = "cGhvbmU" } });
    defer r.deinit();
    const device = try r.json(Redeemed);
    var ok = try env.t.post(try std.fmt.allocPrint(a, "/v1/remote/pair/{s}/approve", .{device.id}), .{ .headers = &.{.{ "X-Remote-Host-Token", host.host_token }} });
    defer ok.deinit();
    try ok.expectStatus(.ok);

    const Check = struct {
        fn run(srv: *Server, st: *app_main.App, ar: std.mem.Allocator, host_id: []const u8, host_token: []const u8, dev: Redeemed) !void {
            defer srv.stop();
            try srv.waitReady();
            const io = srv.io();
            const port = srv.addresses()[0].ip.getPort();
            var client = anole.client(io).http;

            // The host, with its token in a header.
            var keys: [1][]const u8 = undefined;
            var values: [1][]const u8 = undefined;
            var hashes: [1]u8 = undefined;
            var headers: anole.http.Headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
            try headers.put("Authorization", try std.fmt.allocPrint(ar, "Bearer {s}", .{host_token}));
            var h = try client.connectWebSocket(try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/host", .{port}), .{ .headers = &headers });
            defer h.deinit();
            const hello = try expectNotice(&h, ar, "hello");
            try std.testing.expectEqual(@as(usize, 0), hello.object.get("clients").?.array.items.len);
            try std.testing.expect(st.relay.online(io, host_id));

            // A wrong device token is refused before the upgrade.
            try std.testing.expectError(error.WebSocketUpgradeFailed, client.connectWebSocket(try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/client/{s}?token=rd_nope", .{ port, host_id }), .{}));

            // The device token alone is not enough: the caller's account JWT has to match too.
            const secret = st.cfg.jwt_secret.?.expose();
            const other = try app_main.auth.accessToken(ar, io, secret, "someone-else");
            const mine = try app_main.auth.accessToken(ar, io, secret, "dev-user");
            const base = try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/client/{s}?token={s}", .{ port, host_id, dev.device_token });
            try std.testing.expectError(error.WebSocketUpgradeFailed, client.connectWebSocket(try std.fmt.allocPrint(ar, "{s}&user_token={s}", .{ base, other }), .{}));
            try std.testing.expectError(error.WebSocketUpgradeFailed, client.connectWebSocket(try std.fmt.allocPrint(ar, "{s}&user_token=garbage", .{base}), .{}));
            const host_url = try std.fmt.allocPrint(ar, "ws://127.0.0.1:{d}/v1/remote/host?token={s}&user_token={s}", .{ port, host_token, other });
            try std.testing.expectError(error.WebSocketUpgradeFailed, client.connectWebSocket(host_url, .{}));

            // The client, with its token and its account's JWT in the query.
            var c = try client.connectWebSocket(try std.fmt.allocPrint(ar, "{s}&user_token={s}", .{ base, mine }), .{});
            defer c.deinit();
            const chello = try expectNotice(&c, ar, "hello");
            try std.testing.expect(chello.object.get("host_online").?.bool);
            const channel: u32 = @intCast(chello.object.get("channel").?.integer);
            const open = try expectNotice(&h, ar, "client_open");
            try std.testing.expectEqual(@as(i64, channel), open.object.get("channel").?.integer);
            try std.testing.expectEqualStrings(dev.device_id, open.object.get("device_id").?.string);
            try std.testing.expectEqualStrings("cGhvbmU", open.object.get("public_key").?.string);

            // Client to host: the payload, untouched, behind its channel.
            const sealed = "\x00\xffsealed box\x01";
            try c.send(.binary, sealed);
            const up = try h.receive();
            try std.testing.expect(up.type == .binary);
            try std.testing.expectEqual(channel, std.mem.readInt(u32, up.data[0..4], .big));
            try std.testing.expectEqualStrings(sealed, up.data[4..]);

            // Host to client: the channel is stripped.
            var down: [4 + 5]u8 = undefined;
            std.mem.writeInt(u32, down[0..4], channel, .big);
            @memcpy(down[4..], "reply");
            try h.send(.binary, &down);
            const got = try c.receive();
            try std.testing.expect(got.type == .binary);
            try std.testing.expectEqualStrings("reply", got.data);

            // Unpairing: the client is told and cut off, the host sees it go.
            var del = try anole.client(io).fetch(try std.fmt.allocPrint(ar, "http://127.0.0.1:{d}/v1/remote/devices/{s}", .{ port, dev.device_id }), .{ .method = .delete });
            defer del.deinit();
            try std.testing.expect(del.status() == .no_content or del.status() == .ok);
            _ = try expectNotice(&c, ar, "revoked");
            const closed = try expectNotice(&h, ar, "client_close");
            try std.testing.expectEqual(@as(i64, channel), closed.object.get("channel").?.integer);
            try c.send(.binary, "after");
            const end = try c.receive();
            try std.testing.expect(end.type == .close);

            try h.close(.normal, "");
            _ = h.receive() catch {};
        }
    };
    var checking = try env.server.io().concurrent(Check.run, .{ &env.server, &env.state, a, host.id, host.host_token, device });
    try env.server.listen("127.0.0.1:0");
    try checking.await(env.server.io());
}
