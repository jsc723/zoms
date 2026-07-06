const std = @import("std");
const testing = std.testing;
const blake3 = std.crypto.hash.Blake3;
const encoding = @import("base32.zig");

const ByteLen = 20;
const StringLen = 32;

pub const Hash = struct {
    bytes: [ByteLen]u8,

    pub const Empty: Hash = .{ .bytes = [_]u8{0} ** ByteLen };

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

    pub fn fromReader(reader: *std.Io.Reader) !Hash {
        var h = Empty;
        try reader.*.readSliceAll(&h.bytes);
        return h;
    }

    pub fn isEmpty(self: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &Empty.bytes);
    }

    pub fn toString(self: Hash) [StringLen]u8 {
        var dest: [StringLen]u8 = .{0} ** StringLen;
        encoding.encode(self.bytes, &dest);
        return dest;
    }

    pub fn of(data: []const u8) Hash {
        var h = Hash.Empty;
        // truncate first 20 bytes of blake3 hash (which has 32 bytes). The library does truncate automatically.
        blake3.hash(data, &h.bytes, .{});
        return h;
    }

    // used for c-binding (hasher may not be blake3)
    pub fn fromOther(data: [*]const u8) Hash {
        var h = Hash.Empty;
        std.mem.copyForwards(u8, &h.bytes, data[0..20]);
        return h;
    }

    pub fn ofNumber(comptime T: type, num: T) Hash {
        var buf: [@sizeOf(T)]u8 = .{0} ** @sizeOf(T);
        std.mem.writeInt(T, &buf, num, .big);
        var h = Hash.Empty;
        blake3.hash(&buf, &h.bytes, .{});
        return h;
    }

    pub fn parse(s: []const u8) !Hash {
        if (!Hash.isValidString(s)) {
            return error.InvalidHashString;
        }
        var h = Hash.Empty;
        try encoding.decode(s, &h.bytes);
        return h;
    }

    pub fn equals(self: Hash, other: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn compare(self: Hash, other: Hash) std.math.Order {
        return std.mem.order(u8, self.bytes[0..], other.bytes[0..]);
    }

    pub fn add(self: Hash, other: Hash) Hash {
        var buf: [ByteLen * 2]u8 = .{0} ** (ByteLen * 2);
        std.mem.copyForwards(u8, buf[0..ByteLen], self.bytes[0..]);
        std.mem.copyForwards(u8, buf[ByteLen..], other.bytes[0..]);
        return Hash.of(&buf);
    }

    pub fn prefix(self: Hash) u64 {
        return std.mem.readInt(u64, self.bytes[0..8], .big);
    }

    pub fn suffix(self: Hash) [12]u8 {
        var s: [12]u8 = undefined;
        std.mem.copyForwards(u8, &s, self.bytes[8..]);
        return s;
    }

    pub fn suffixEqual(self: Hash, other: [12]u8) bool {
        return std.mem.eql(u8, self.bytes[8..], &other);
    }

    pub const Context = HashContext;
    pub const Set = std.AutoHashMap(Hash, void);
};

pub const HashContext = struct {
    pub fn hash(_: HashContext, h: Hash) u64 {
        return std.hash.Wyhash.hash(0, &h.bytes);
    }

    pub fn eql(_: HashContext, a: Hash, b: Hash) bool {
        return a.equals(b);
    }
};

test "Hash.ToString fills custom slice correctly" {
    // 1. Create a known mock hash structure
    var sample_hash = Hash{ .bytes = [_]u8{0} ** ByteLen };
    sample_hash.bytes[ByteLen - 1] = 1; // Set the last byte so it isn't empty

    // Pass it as a slice to ToString
    const str = sample_hash.toString();

    // 3. Assert the result matches the encoded output
    try testing.expectEqualStrings("00000000000000000000000000000001", &str);
}

test "Hash.of" {
    const input_data = "hello world";

    // 1. Generate the hash pointer on the heap
    const hash_ptr = Hash.of(input_data);

    // 3. Assert that the generated hash is populated and not completely zeroed
    try testing.expect(!hash_ptr.isEmpty());

    // 4. Convert the hash to a string and verify its correctness
    const str = hash_ptr.toString();
    try testing.expectEqualStrings("qt4o3rt71868g2sdhgcobk3lrf5vcudp", &str);
}

test "Hash.ofNumber" {
    const input_data = 42;
    const hash = Hash.ofNumber(u32, input_data);
    try testing.expect(!hash.isEmpty());
    try testing.expect(hash.equals(Hash.ofNumber(u32, 42)));
    try testing.expect(!hash.equals(Hash.ofNumber(u32, 4111)));
    try testing.expect(!hash.equals(Hash.ofNumber(u8, 42)));
}

test "test is empty" {
    const empty = try Hash.parse("00000000000000000000000000000000");
    try testing.expect(empty.isEmpty());

    const notEmpty = try Hash.parse("00000000000000000000000000000001");
    try testing.expect(!notEmpty.isEmpty());
}

test "test parse" {
    try testing.expectError(error.InvalidHashString, Hash.parse("foo"));
    // too few digits
    try testing.expectError(error.InvalidHashString, Hash.parse("0000000000000000000000000000000"));

    // too many digits
    try testing.expectError(error.InvalidHashString, Hash.parse("000000000000000000000000000000000"));

    // 'w' not valid base32
    try testing.expectError(error.InvalidHashString, Hash.parse("00000000000000000000000000000000w"));

    _ = try Hash.parse("00000000000000000000000000000000");
}

test "Hash.Compare equal" {
    const a = Hash.Empty;
    const b = Hash.Empty;

    try testing.expectEqual(std.math.Order.eq, a.compare(b));
}

test "Hash.Compare less on first byte" {
    var a = Hash.Empty;
    var b = Hash.Empty;

    a.bytes[0] = 1;
    b.bytes[0] = 2;

    try testing.expectEqual(std.math.Order.lt, a.compare(b));
    try testing.expectEqual(std.math.Order.gt, b.compare(a));
}

test "Hash.Compare less on last byte" {
    var a = Hash.Empty;
    var b = Hash.Empty;

    a.bytes[19] = 1;
    b.bytes[19] = 2;

    try testing.expectEqual(std.math.Order.lt, a.compare(b));
    try testing.expectEqual(std.math.Order.gt, b.compare(a));
}

test "Hash.Compare less on middle byte" {
    var a = Hash.Empty;
    var b = Hash.Empty;

    a.bytes[10] = 7;
    b.bytes[10] = 8;

    _ = Hash.compare(a, b) == .eq;

    try testing.expectEqual(std.math.Order.lt, a.compare(b));
    try testing.expectEqual(std.math.Order.gt, b.compare(a));
}

test "Hash.Compare all zero and all ff" {
    const zero = Hash.Empty;

    const ff = Hash{
        .bytes = [_]u8{0xff} ** 20,
    };

    try testing.expectEqual(std.math.Order.lt, zero.compare(ff));
    try testing.expectEqual(std.math.Order.gt, ff.compare(zero));
}

test "hash add" {
    const a = Hash.of("a");
    const b = Hash.of("b");
    const res = Hash.add(a, b);
    try testing.expect(!res.isEmpty());
    try testing.expect(!a.equals(res));
    try testing.expect(!b.equals(res));
}

test "hash prefix suffix" {
    var a = Hash.Empty;
    try testing.expectEqual(0, a.prefix());

    a.bytes[7] = 0x34;
    try testing.expectEqual(0x34, a.prefix());
    a.bytes[6] = 0x12;
    try testing.expectEqual(0x1234, a.prefix());

    a.bytes[8] = 0x56;
    try testing.expectEqual(0x1234, a.prefix());
    try testing.expectEqual(0x56, a.suffix()[0]);
    a.bytes[19] = 0x78;
    try testing.expectEqual(0x78, a.suffix()[11]);
}
