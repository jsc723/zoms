const std = @import("std");
const chunks = @import("chunks.zig");
const hash = @import("hash");
const Chunk = chunks.Chunk;
const Hash = hash.Hash;
pub const HashChunkMap = std.AutoHashMap(Hash, Chunk);
pub const HashSet = Hash.Set;

pub const HashIterator = union(enum) {
    map: HashChunkMap.KeyIterator,
    set: HashSet.KeyIterator,
    slice: ConstSliceIterator(Hash),
    carray: CArrayHashIterator,
    custom: struct {
        ptr: *anyopaque,
        nextFn: *const fn (*anyopaque) ?*const Hash,
    },

    const Self = @This();

    pub fn next(self: *Self) ?*const Hash {
        switch (self.*) {
            .custom => |c| return c.nextFn(c.ptr),
            inline else => |*iter| return iter.next(),
        }
    }
};

pub fn ConstSliceIterator(comptime T: type) type {
    return struct {
        slice: []const T,
        i: usize,
        const Self = @This();
        pub fn init(slice: []const T) Self {
            return .{
                .slice = slice,
                .i = 0,
            };
        }
        pub fn next(self: *Self) ?*const T {
            if (self.i < self.slice.len) {
                defer self.i += 1;
                return &self.slice[self.i];
            }
            return null;
        }
    };
}

pub const CArrayHashIterator = struct {
    ptr: ?[*]?[*]u8,
    len: usize,
    i: usize,
    cur: Hash,
    pub fn next(self: *CArrayHashIterator) ?*const Hash {
        if (self.i >= self.len) {
            return null;
        }
        defer self.i += 1;
        const pHash = self.ptr.?[self.i].?;
        self.cur = Hash.fromOther(pHash);
        return &self.cur;
    }
};

const testing = std.testing;
test "hash iterator" {
    const alloc = testing.allocator;
    const h1 = Hash.of("h1");
    const h2 = Hash.of("h2");
    const h3 = Hash.of("h3");
    var set = HashSet.init(alloc);
    defer set.deinit();
    try set.put(h1, {});
    try set.put(h2, {});
    try set.put(h3, {});
    var setIter = HashIterator{
        .set = set.keyIterator(),
    };

    try testing.expect(set.contains(setIter.next().?.*));
    try testing.expect(set.contains(setIter.next().?.*));
    try testing.expect(set.contains(setIter.next().?.*));
    try testing.expect(setIter.next() == null);

    const hashes = [3]Hash{ h1, h2, h3 };
    var sliceIter = HashIterator{
        .slice = ConstSliceIterator(Hash).init(&hashes),
    };
    try testing.expect(sliceIter.next().?.equals(h1));
    try testing.expect(sliceIter.next().?.equals(h2));
    try testing.expect(sliceIter.next().?.equals(h3));
    try testing.expect(sliceIter.next() == null);

    var map = HashChunkMap.init(alloc);
    defer {
        var it = map.valueIterator();
        while (it.next()) |c| {
            c.deinit(alloc);
        }
        map.deinit();
    }

    try map.put(h1, try Chunk.init(alloc, "h1"));
    try map.put(h2, try Chunk.init(alloc, "h2"));
    try map.put(h3, try Chunk.init(alloc, "h3"));

    var mapIter = HashIterator{
        .map = map.keyIterator(),
    };

    try testing.expect(set.contains(mapIter.next().?.*));
    try testing.expect(set.contains(mapIter.next().?.*));
    try testing.expect(set.contains(mapIter.next().?.*));
    try testing.expect(mapIter.next() == null);
}
