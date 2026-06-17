const std = @import("std");
const testing = std.testing;
const blake3 = std.crypto.hash.Blake3;
const encoding = @import("encoding.zig");

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
        encoding.encode(self.bytes, dest);
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
