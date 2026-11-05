//! Look-alike addresses of official sites: a host spelled with punycode or
//! Unicode letters that read as an official domain (`xn--gthub-n2e.com`,
//! a Cyrillic "і" in github.com), and host labels that mix Latin with
//! Cyrillic or Greek letters. `safe_fetch` judges every hop's host with
//! `judge` and refuses both.
//!
//! The method is the one browsers use for IDN spoofing (Chromium's
//! `idn_spoof_checker`, Unicode UTS #39): reduce each label to a skeleton
//! through a small confusables map and compare it with a list of official
//! sites (`official_sites.txt`). Written from those descriptions, not copied.
//! Plain ASCII typos (`gihtub.com`) are not judged here.
const std = @import("std");

/// The official domains, from `official_sites.txt` (one per line, `#` comments).
pub const official: []const []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    const raw = @embedFile("official_sites.txt");
    var list: []const []const u8 = &.{};
    var it = std.mem.tokenizeScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const d = std.mem.trim(u8, line, " \t\r");
        if (d.len == 0 or d[0] == '#') continue;
        list = list ++ [_][]const u8{d};
    }
    break :blk list;
};

pub const Verdict = union(enum) {
    ok,
    /// Reads as this official domain (or a subdomain of it) but is not it.
    look_alike: []const u8,
    /// A label mixes Latin, Cyrillic or Greek letters.
    mixed_script,
};

/// Judges `host` (a name, not an IP literal; any case, no trailing dot).
pub fn judge(host: []const u8) Verdict {
    if (host.len == 0 or host.len > 253) return .ok;
    var skeleton: [256]u8 = undefined;
    var len: usize = 0;
    var spelled = true; // every letter reduced to ASCII
    var international = false;
    var mixed = false;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (len > 0) {
            skeleton[len] = '.';
            len += 1;
        }
        var cps: [256]u21 = undefined;
        const points = codePoints(label, &cps) orelse return .ok;
        var scripts: u3 = 0;
        for (points) |cp| {
            if (cp >= 0x80) international = true;
            scripts |= scriptOf(cp);
            if (len >= skeleton.len) return .ok;
            if (base(cp)) |c| {
                skeleton[len] = c;
                len += 1;
            } else spelled = false;
        }
        if (@popCount(scripts) > 1) mixed = true;
    }
    if (!international) return .ok;
    if (spelled) if (officialFor(skeleton[0..len])) |real| return .{ .look_alike = real };
    if (mixed) return .mixed_script;
    return .ok;
}

/// The official domain `host` is, or is a subdomain of.
fn officialFor(host: []const u8) ?[]const u8 {
    for (official) |d| {
        if (std.mem.eql(u8, host, d)) return d;
        if (host.len > d.len and host[host.len - d.len - 1] == '.' and std.mem.endsWith(u8, host, d)) return d;
    }
    return null;
}

/// The label's code points: punycode decoded for `xn--`, UTF-8 decoded
/// otherwise, ASCII lower-cased. Null when it can't be read.
fn codePoints(label: []const u8, out: []u21) ?[]const u21 {
    if (label.len > 4 and std.ascii.eqlIgnoreCase(label[0..4], "xn--")) return punycode(label[4..], out);
    const view = std.unicode.Utf8View.init(label) catch return null;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (n == out.len) return null;
        out[n] = if (cp < 0x80) std.ascii.toLower(@intCast(cp)) else cp;
        n += 1;
    }
    return out[0..n];
}

const latin: u3 = 1;
const cyrillic: u3 = 2;
const greek: u3 = 4;

fn scriptOf(cp: u21) u3 {
    return switch (cp) {
        'a'...'z', 0xC0...0x24F => latin,
        0x370...0x3FF => greek,
        0x400...0x52F => cyrillic,
        else => 0,
    };
}

/// The ASCII letter `cp` reads as: itself for ASCII, else from the small
/// confusables map (Cyrillic and Greek look-alikes, accented Latin letters).
fn base(cp: u21) ?u8 {
    if (cp < 0x80) return @intCast(cp);
    return switch (cp) {
        // Accented Latin (Latin-1 Supplement and Extended-A, the common ones).
        0xE0...0xE5, 0x101, 0x103, 0x105 => 'a',
        0xE7, 0x107, 0x109, 0x10B, 0x10D => 'c',
        0x10F, 0x111 => 'd',
        0xE8...0xEB, 0x113, 0x115, 0x117, 0x119, 0x11B => 'e',
        0x11D, 0x11F, 0x121, 0x123, 0x261 => 'g',
        0xEC...0xEF, 0x129, 0x12B, 0x12D, 0x12F, 0x131 => 'i',
        0x142, 0x13A, 0x13C, 0x13E => 'l',
        0xF1, 0x144, 0x146, 0x148 => 'n',
        0xF2...0xF6, 0xF8, 0x14D, 0x14F, 0x151 => 'o',
        0x155, 0x157, 0x159 => 'r',
        0x15B, 0x15D, 0x15F, 0x161 => 's',
        0x163, 0x165 => 't',
        0xF9...0xFC, 0x169, 0x16B, 0x16D, 0x16F, 0x171, 0x173 => 'u',
        0xFD, 0xFF => 'y',
        0x17A, 0x17C, 0x17E => 'z',
        // Cyrillic.
        0x430 => 'a',
        0x432 => 'b',
        0x441 => 'c',
        0x501 => 'd',
        0x435, 0x450, 0x451 => 'e',
        0x4BB => 'h',
        0x456, 0x457 => 'i',
        0x458 => 'j',
        0x43A => 'k',
        0x4CF => 'l',
        0x43E => 'o',
        0x440 => 'p',
        0x51B => 'q',
        0x455 => 's',
        0x443 => 'y',
        0x51D => 'w',
        0x445 => 'x',
        // Greek.
        0x3B1 => 'a',
        0x3B9 => 'i',
        0x3BA => 'k',
        0x3BD => 'v',
        0x3BF, 0x3CC => 'o',
        0x3C1 => 'p',
        0x3C4 => 't',
        0x3C5 => 'u',
        else => null,
    };
}

/// RFC 3492 decoding of a label's part after `xn--`. Null when malformed.
fn punycode(input: []const u8, out: []u21) ?[]const u21 {
    const b = 36;
    const tmin = 1;
    const tmax = 26;
    var n: u32 = 128;
    var i: u32 = 0;
    var bias: u32 = 72;
    var len: usize = 0;
    const delim = std.mem.lastIndexOfScalar(u8, input, '-');
    if (delim) |d| for (input[0..d]) |c| {
        if (c >= 0x80 or len == out.len) return null;
        out[len] = std.ascii.toLower(c);
        len += 1;
    };
    var in: usize = if (delim) |d| d + 1 else 0;
    while (in < input.len) {
        const old = i;
        var w: u32 = 1;
        var k: u32 = b;
        while (true) : (k += b) {
            if (in >= input.len) return null;
            const c = std.ascii.toLower(input[in]);
            in += 1;
            const digit: u32 = switch (c) {
                'a'...'z' => c - 'a',
                '0'...'9' => c - '0' + 26,
                else => return null,
            };
            i = std.math.add(u32, i, std.math.mul(u32, digit, w) catch return null) catch return null;
            const t: u32 = if (k <= bias) tmin else if (k >= bias + tmax) tmax else k - bias;
            if (digit < t) break;
            w = std.math.mul(u32, w, b - t) catch return null;
        }
        const points: u32 = @intCast(len + 1);
        bias = adapt(i - old, points, old == 0);
        n = std.math.add(u32, n, i / points) catch return null;
        i %= points;
        if (n > 0x10FFFF or len == out.len) return null;
        std.mem.copyBackwards(u21, out[i + 1 .. len + 1], out[i..len]);
        out[i] = @intCast(n);
        len += 1;
        i += 1;
    }
    return out[0..len];
}

fn adapt(delta_in: u32, points: u32, first: bool) u32 {
    var delta = if (first) delta_in / 700 else delta_in / 2;
    delta += delta / points;
    var k: u32 = 0;
    while (delta > ((36 - 1) * 26) / 2) : (k += 36) delta /= 36 - 1;
    return k + (36 - 1 + 1) * delta / (delta + 38);
}

fn expectLookAlike(host: []const u8, real: []const u8) !void {
    switch (judge(host)) {
        .look_alike => |r| try std.testing.expectEqualStrings(real, r),
        else => |v| {
            std.debug.print("{s}: {t}\n", .{ host, v });
            return error.TestUnexpectedResult;
        },
    }
}

test "punycode decodes RFC 3492 labels" {
    var buf: [64]u21 = undefined;
    const got = punycode("mnchen-3ya", &buf).?;
    try std.testing.expectEqualSlices(u21, &[_]u21{ 'm', 0xFC, 'n', 'c', 'h', 'e', 'n' }, got);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0x43F, 0x440, 0x438, 0x43C, 0x435, 0x440 }, punycode("e1afmkfd", &buf).?);
    try std.testing.expect(punycode("abc-!!", &buf) == null);
}

test "judge: homographs of official sites are refused, naming the real one" {
    try expectLookAlike("xn--gthub-n2e.com", "github.com");
    try expectLookAlike("g\u{456}thub.com", "github.com");
    try expectLookAlike("raw.xn--gthub-n2e.com", "github.com");
    try expectLookAlike("XN--80AK6AA92E.com", "apple.com"); // whole-Cyrillic "аррӏе"
    try expectLookAlike("xn--pyp-lhd.org", "pypi.org");
    try expectLookAlike("xn--googl-fsa.com", "google.com"); // googlé
    try expectLookAlike("xn--l-7sba6dbr.com", "paypal.com");
}

test "judge: mixed alphabets are refused, real sites and genuine IDNs pass" {
    try std.testing.expectEqual(Verdict.mixed_script, judge("xn--p-4tbj1f.net")); // "руpі", off the list
    try std.testing.expectEqual(Verdict.mixed_script, judge("pay\u{440}al-login.net"));
    for ([_][]const u8{ "github.com", "api.GitHub.com", "raw.githubusercontent.com", "example.org", "xn--mnchen-3ya.de", "xn--e1afmkfd.xn--p1ai", "127.0.0.1", "xn--broken!" }) |h| {
        if (judge(h) != .ok) {
            std.debug.print("refused: {s}\n", .{h});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(official.len > 30);
    for (official) |d| try std.testing.expectEqual(Verdict.ok, judge(d));
}
