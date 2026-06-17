const std = @import("std");
const blake3 = std.crypto.hash.Blake3;
const ByteLen = 20;
const StringLen = 32;

const emptyHash: Hash = .{ .bytes = [_]u8{0} ** ByteLen };

const Hash = struct {
    bytes: [ByteLen]u8,

    pub fn Init() Hash {
        return emptyHash;
    }

    pub fn isValidString(str: []const u8) bool {
        if (str.len != StringLen) return false;

        for (str) |c| {
            switch (c) {
                '0'...'9', 'a'...'v' => continue,
                else => return false,
            }
        }
        return true;
    }

    pub fn IsEmpty(self: Hash) bool {
        return std.mem.eql(u8, self.bytes[0..], emptyHash.bytes[0..]);
    }

    pub fn ToString(self: Hash, dest: *[StringLen]u8) !void {
        encode(self.bytes, dest);
    }

    pub fn Of(data: []const u8) Hash {
        var h = Hash.Init();
        blake3.hash(data, &h.bytes, .{});
        return h;
    }
};

test "Hash.ToString fills custom slice correctly" {
    // 1. Create a known mock hash structure
    var sample_hash = Hash{ .bytes = [_]u8{0} ** ByteLen };
    sample_hash.bytes[ByteLen - 1] = 1; // Set the last byte so it isn't empty

    // 2. Prepare a destination buffer array on the stack
    var buf: [StringLen]u8 = undefined;

    // Pass it as a slice to ToString
    try sample_hash.ToString(&buf);

    // 3. Assert the result matches the encoded output
    try testing.expectEqualStrings("00000000000000000000000000000001", &buf);
}

test "Hash.Of allocation and hashing lifecycle" {
    const input_data = "hello world";

    // 1. Generate the hash pointer on the heap
    const hash_ptr = Hash.Of(input_data);

    // 3. Assert that the generated hash is populated and not completely zeroed
    try testing.expect(!hash_ptr.IsEmpty());

    // 4. Convert the hash to a string and verify its correctness
    var buf: [StringLen]u8 = undefined;
    try hash_ptr.ToString(&buf);
    try testing.expectEqualStrings("qt4o3rt71868g2sdhgcobk3lrf5vcudp", &buf);
}

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
