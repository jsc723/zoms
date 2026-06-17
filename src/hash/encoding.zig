const std = @import("std");

// Noms custom alphabet: 32 characters
const alphabet = "0123456789abcdefghijklmnopqrstuv";

/// Encodes a 20-byte slice into a 32-byte string buffer.
/// Noms hashes have fixed sizes, so we can avoid dynamic allocation.
pub fn encode(src: [20]u8, dest: *[32]u8) void {
    var bit_buf: u40 = 0;
    var bit_count: u6 = 0;
    var dest_idx: usize = 0;

    for (src) |byte| {
        bit_buf = (bit_buf << 8) | byte;
        bit_count += 8;

        while (bit_count >= 5) {
            bit_count -= 5;
            const shift: u5 = @intCast(bit_count);
            const index = (bit_buf >> shift) & 0x1F;
            dest[dest_idx] = alphabet[index];
            dest_idx += 1;
        }
    }

    // Handle remaining bits if any (for 20 bytes, 160 bits divides perfectly by 5, so no remainder)
    if (bit_count > 0) {
        const shift: u5 = @intCast(5 - bit_count);
        const index = (bit_buf << shift) & 0x1F;
        dest[dest_idx] = alphabet[index];
    }
}

/// Decodes a 32-byte encoded string back into a 20-byte array in-place.
/// Returns an error if an invalid character is encountered.
pub fn decode(src: [32]u8, dest: *[20]u8) !void {
    var bit_buf: u40 = 0;
    var bit_count: u6 = 0;
    var dest_idx: usize = 0;

    for (src) |c| {
        // Reverse lookup the character to its 5-bit value
        const val: u5 = switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'v' => @intCast(c - 'a' + 10),
            else => return error.InvalidBase32Char,
        };

        bit_buf = (bit_buf << 5) | val;
        bit_count += 5;

        if (bit_count >= 8) {
            bit_count -= 8;
            const shift: u5 = @intCast(bit_count);
            dest[dest_idx] = @intCast((bit_buf >> shift) & 0xFF);
            dest_idx += 1;
        }
    }
}

const testing = std.testing;

// Assuming your encode/decode functions are in the same file,
// or imported from your hash module.

test "Base32Encode" {
    var d = [_]u8{0} ** 20;
    var buf: [32]u8 = undefined;

    encode(d, &buf);
    try testing.expectEqualStrings("00000000000000000000000000000000", &buf);

    d[19] = 1;
    encode(d, &buf);
    try testing.expectEqualStrings("00000000000000000000000000000001", &buf);

    d[19] = 10;
    encode(d, &buf);
    try testing.expectEqualStrings("0000000000000000000000000000000a", &buf);

    d[19] = 20;
    encode(d, &buf);
    try testing.expectEqualStrings("0000000000000000000000000000000k", &buf);

    d[19] = 31;
    encode(d, &buf);
    try testing.expectEqualStrings("0000000000000000000000000000000v", &buf);

    d[19] = 32;
    encode(d, &buf);
    try testing.expectEqualStrings("00000000000000000000000000000010", &buf);

    d[19] = 63;
    encode(d, &buf);
    try testing.expectEqualStrings("0000000000000000000000000000001v", &buf);

    d[19] = 64;
    encode(d, &buf);
    try testing.expectEqualStrings("00000000000000000000000000000020", &buf);

    // Largest!
    @memset(&d, 0xff);
    encode(d, &buf);
    try testing.expectEqualStrings("vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv", &buf);
}

test "Base32Decode" {
    var d = [_]u8{0} ** 20;
    var out: [20]u8 = undefined;

    try decode("00000000000000000000000000000000".*, &out);
    try testing.expectEqualSlices(u8, &d, &out);

    d[19] = 1;
    try decode("00000000000000000000000000000001".*, &out);
    try testing.expectEqualSlices(u8, &d, &out);

    d[19] = 10;
    try decode("0000000000000000000000000000000a".*, &out);
    try testing.expectEqualSlices(u8, &d, &out);

    d[19] = 20;
    try decode("0000000000000000000000000000000k".*, &out);
    try testing.expectEqualSlices(u8, &d, &out);

    d[19] = 31;
    try decode("0000000000000000000000000000000v".*, &out);
    try testing.expectEqualSlices(u8, &d, &out);

    d[19] = 32;
    try decode("00000000000000000000000000000010".*, &out);
    try testing.expectEqualSlices(u8, &d, &out);

    d[19] = 63;
    try decode("0000000000000000000000000000001v".*, &out);
    try testing.expectEqualSlices(u8, &d, &out);

    d[19] = 64;
    try decode("00000000000000000000000000000020".*, &out);
    try testing.expectEqualSlices(u8, &d, &out);

    // Largest!
    @memset(&d, 0xff);
    try decode("vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv".*, &out);
    try testing.expectEqualSlices(u8, &d, &out);
}
