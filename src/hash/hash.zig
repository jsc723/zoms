const std = @import("std");
const testing = std.testing;
const blake3 = std.crypto.hash.Blake3;
const encoding = @import("encoding.zig");

const ByteLen = 20;
const StringLen = 32;

const Hash = struct {
    bytes: [ByteLen]u8,

    pub const Empty: Hash = .{ .bytes = [_]u8{0} ** ByteLen };

    pub fn IsValidString(str: []const u8) bool {
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
        return std.mem.eql(u8, &self.bytes, &Empty.bytes);
    }

    pub fn ToString(self: Hash, dest: *[StringLen]u8) !void {
        encoding.encode(self.bytes, dest);
    }

    pub fn Of(data: []const u8) Hash {
        var h = Hash.Empty;
        // truncate first 20 bytes of blake3 hash (which has 32 bytes). The library does truncate automatically.
        blake3.hash(data, &h.bytes, .{});
        return h;
    }

    pub fn Parse(s: []const u8) !Hash {
        if (!Hash.IsValidString(s)) {
            return error.InvalidHashString;
        }
        var h = Hash.Empty;
        try encoding.decode(s, &h.bytes);
        return h;
    }

    pub fn Equal(self: Hash, other: Hash) bool {
        return self.bytes == other.bytes;
    }

    pub fn Compare(self: Hash, other: Hash) std.math.Order {
        return std.mem.order(u8, self.bytes[0..], other.bytes[0..]);
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

test "test is empty" {
    const empty = try Hash.Parse("00000000000000000000000000000000");
    try testing.expect(empty.IsEmpty());

    const notEmpty = try Hash.Parse("00000000000000000000000000000001");
    try testing.expect(!notEmpty.IsEmpty());
}

test "test parse" {
    try testing.expectError(error.InvalidHashString, Hash.Parse("foo"));
    // too few digits
    try testing.expectError(error.InvalidHashString, Hash.Parse("0000000000000000000000000000000"));

    // too many digits
    try testing.expectError(error.InvalidHashString, Hash.Parse("000000000000000000000000000000000"));

    // 'w' not valid base32
    try testing.expectError(error.InvalidHashString, Hash.Parse("00000000000000000000000000000000w"));

    _ = try Hash.Parse("00000000000000000000000000000000");
}

test "Hash.Compare equal" {
    const a = Hash.Empty;
    const b = Hash.Empty;

    try testing.expectEqual(std.math.Order.eq, a.Compare(b));
}

test "Hash.Compare less on first byte" {
    var a = Hash.Empty;
    var b = Hash.Empty;

    a.bytes[0] = 1;
    b.bytes[0] = 2;

    try testing.expectEqual(std.math.Order.lt, a.Compare(b));
    try testing.expectEqual(std.math.Order.gt, b.Compare(a));
}

test "Hash.Compare less on last byte" {
    var a = Hash.Empty;
    var b = Hash.Empty;

    a.bytes[19] = 1;
    b.bytes[19] = 2;

    try testing.expectEqual(std.math.Order.lt, a.Compare(b));
    try testing.expectEqual(std.math.Order.gt, b.Compare(a));
}

test "Hash.Compare less on middle byte" {
    var a = Hash.Empty;
    var b = Hash.Empty;

    a.bytes[10] = 7;
    b.bytes[10] = 8;

    try testing.expectEqual(std.math.Order.lt, a.Compare(b));
    try testing.expectEqual(std.math.Order.gt, b.Compare(a));
}

test "Hash.Compare all zero and all ff" {
    const zero = Hash.Empty;

    const ff = Hash{
        .bytes = [_]u8{0xff} ** 20,
    };

    try testing.expectEqual(std.math.Order.lt, zero.Compare(ff));
    try testing.expectEqual(std.math.Order.gt, ff.Compare(zero));
}
