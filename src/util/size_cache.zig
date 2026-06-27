const std = @import("std");
const testing = std.testing;

pub fn SizeCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const ExpireCallBack = *const fn (key: K, elem: V) void;
        const Entry = struct {
            size: u64,
            lruEntry: std.DoublyLinkedList.Node,
            key: K,
            data: V,
        };

        totalSize: u64,
        maxSize: u64,
        lru: std.DoublyLinkedList,
        cache: std.AutoHashMap(K, *Entry),
        expireCb: ?ExpireCallBack,
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator, maxSize: u64, expireCb: ?ExpireCallBack) Self {
            return Self{
                .totalSize = 0,
                .maxSize = maxSize,
                .lru = .{},
                .cache = .init(alloc),
                .expireCb = expireCb,
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.lru.first;
            while (it != null) {
                const node = it.?;
                it = node.next;
                const pEntry: *Entry = @fieldParentPtr("lruEntry", node);
                if (self.expireCb) |cb| {
                    cb(pEntry.key, pEntry.data);
                }
                self.alloc.destroy(pEntry);
            }
            self.cache.deinit();
        }

        // entry() checks if |key| is in the cache.
        // If it is not in the cache, it returns null.
        // if it is in the cache, it move the entry to the back of the lru list, then return a pointer to the entry.
        fn entry(self: *Self, key: K) ?*Entry {
            const maybeEntry = self.cache.get(key);
            if (maybeEntry) |e| {
                self.lru.remove(&e.lruEntry);
                e.lruEntry.next = null;
                e.lruEntry.prev = null;
                self.lru.append(&e.lruEntry);
            }
            return maybeEntry;
        }

        pub fn get(self: *Self, key: K) ?V {
            const maybeEntry = self.entry(key);
            if (maybeEntry) |e| {
                return e.data;
            }
            return null;
        }

        // add() first evicts all old entries from the lru to ensure there is enough space for the new item. Then, adds this new item to the cache at the back of the lru. If the item is too large (>maxSize), it will not be added to the cache
        pub fn add(self: *Self, key: K, val: V, size: u64) !void {
            if (size > self.maxSize or self.entry(key) != null) {
                return;
            }

            while (self.totalSize + size > self.maxSize) {
                const nodeToRemove = self.lru.popFirst().?; // because totalSize > 0 (otherwise the function will already return
                const pEntry: *Entry = @fieldParentPtr("lruEntry", nodeToRemove);
                if (self.expireCb) |cb| {
                    cb(pEntry.key, pEntry.data);
                }
                self.totalSize -= pEntry.size;
                _ = self.cache.remove(pEntry.key);
                self.alloc.destroy(pEntry);
            }
            var newEntry: *Entry = try self.alloc.create(Entry);
            errdefer self.alloc.destroy(newEntry);
            newEntry.* = .{ .size = size, .key = key, .data = val, .lruEntry = .{} };
            try self.cache.put(key, newEntry);
            self.lru.append(&newEntry.lruEntry);
            self.totalSize += size;
        }

        pub fn drop(self: *Self, key: K) void {
            if (self.entry(key)) |pEntry| {
                if (self.expireCb) |cb| {
                    cb(pEntry.key, pEntry.data);
                }
                self.totalSize -= pEntry.size;
                self.lru.remove(&pEntry.lruEntry);
                _ = self.cache.remove(pEntry.key);
                self.alloc.destroy(pEntry);
            }
        }

        pub fn getSize(self: *Self) u64 {
            return self.totalSize;
        }
    };
}

pub fn ConcurrentSizeCache(comptime io: std.Io, comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Impl = SizeCache(K, V);
        impl: Impl,
        mu: std.Io.Mutex,

        pub fn init(alloc: std.mem.Allocator, maxSize: u64, expireCb: ?Impl.ExpireCallBack) Self {
            return Self{
                .impl = Impl.init(alloc, maxSize, expireCb),
                .mu = std.Io.Mutex.init,
            };
        }

        pub fn deinit(self: *Self) void {
            self.impl.deinit();
        }

        pub fn get(self: *Self, key: K) !?V {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            return self.impl.get(key);
        }

        pub fn add(self: *Self, key: K, val: V, size: u64) !void {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            try self.impl.add(key, val, size);
        }

        pub fn drop(self: *Self, key: K) !void {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            self.impl.drop(key);
        }

        pub fn getSize(self: *Self) !u64 {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            return self.impl.getSize();
        }
    };
}

fn testCb(_: i32, _: []const u8) void {}

test "test size cache init" {
    const alloc = testing.allocator;
    const io = testing.io;
    var cacheNoCb = SizeCache(i32, []const u8).init(alloc, 8, null);
    defer cacheNoCb.deinit();

    var cache = SizeCache(i32, []const u8).init(alloc, 8, testCb);
    defer cache.deinit();

    var cc = ConcurrentSizeCache(io, i32, []const u8).init(alloc, 8, testCb);
    defer cc.deinit();
}
test "test size cache ops" {
    const alloc = testing.allocator;
    var cache = SizeCache(i32, []const u8).init(alloc, 8, null);
    defer cache.deinit();

    // basic add and get
    try cache.add(1, "1", 1);
    try cache.add(2, "2", 2);
    try cache.add(3, "3", 3);
    try testing.expectEqual(6, cache.getSize());
    try testing.expectEqualStrings("1", cache.get(1).?);
    try testing.expectEqualStrings("2", cache.get(2).?);
    try testing.expectEqualStrings("3", cache.get(3).?);

    // adding existing key is a no-op
    try cache.add(1, "new1", 5);
    try testing.expectEqualStrings("1", cache.get(1).?); // unchanged
    try testing.expectEqual(6, cache.getSize()); // size unchanged

    // eviction: adding 5 (size 5) needs to evict to stay under 8
    // lru order before: 2, 3, 1 (1 was accessed last via get and add no-op)
    // so 2 and 3 should be evicted
    try cache.add(5, "5", 5);
    try testing.expectEqual(6, cache.getSize()); // 1 + 5
    try testing.expectEqualStrings("1", cache.get(1).?);
    try testing.expectEqualStrings("5", cache.get(5).?);
    try testing.expectEqual(null, cache.get(2));
    try testing.expectEqual(null, cache.get(3));

    // item too large to cache is silently ignored
    try cache.add(9, "toobig", 9);
    try testing.expectEqual(null, cache.get(9));
    try testing.expectEqual(6, cache.getSize()); // unchanged

    // drop existing key
    cache.drop(5);
    try testing.expectEqual(null, cache.get(5));
    try testing.expectEqual(1, cache.getSize());

    // drop non-existing key is a no-op
    cache.drop(999);
    try testing.expectEqual(1, cache.getSize());

    // fill to exact capacity
    try cache.add(7, "7", 7);
    try testing.expectEqual(8, cache.getSize());
    try testing.expectEqualStrings("1", cache.get(1).?);
    try testing.expectEqualStrings("7", cache.get(7).?);
}

test "test size cache expire callback" {
    const alloc = testing.allocator;
    // can't use function pointer with state, so test callback via drop/eviction
    // using a global counter instead
    const State = struct {
        var count: u32 = 0;
        fn cb(_: i32, _: []const u8) void {
            count += 1;
        }
    };
    State.count = 0;
    var cache = SizeCache(i32, []const u8).init(alloc, 4, State.cb);
    defer cache.deinit();

    try cache.add(1, "1", 2);
    try cache.add(2, "2", 2);
    try cache.add(3, "3", 2); // evicts 1
    try testing.expectEqual(1, State.count);

    try cache.add(4, "4", 2); // evicts 2
    try testing.expectEqual(2, State.count);

    cache.drop(3); // explicit drop also triggers cb
    try testing.expectEqual(3, State.count);

    // deinit triggers cb for remaining entries
    // (tested implicitly — if cb panics on invalid data, deinit would fail)
}

test "test size cache lru ordering" {
    const alloc = testing.allocator;
    var cache = SizeCache(i32, []const u8).init(alloc, 6, null);
    defer cache.deinit();

    try cache.add(1, "1", 2);
    try cache.add(2, "2", 2);
    try cache.add(3, "3", 2);
    // lru order: 1, 2, 3 (3 is most recent)

    // access 1 to make it most recently used
    _ = cache.get(1);
    // lru order: 2, 3, 1 (1 is now most recent)

    // adding size 2 item should evict 2 (least recently used)
    try cache.add(4, "4", 2);
    try testing.expectEqual(null, cache.get(2)); // evicted
    try testing.expectEqualStrings("3", cache.get(3).?);
    try testing.expectEqualStrings("1", cache.get(1).?);
    try testing.expectEqualStrings("4", cache.get(4).?);
}

test "test concurrent size cache" {
    const alloc = testing.allocator;
    const io = testing.io;
    var cache = ConcurrentSizeCache(io, i32, []const u8).init(alloc, 8, null);
    defer cache.deinit();

    try cache.add(1, "1", 1);
    try cache.add(2, "2", 2);
    try cache.add(3, "3", 3);

    try testing.expectEqualStrings("1", (try cache.get(1)).?);
    try testing.expectEqualStrings("2", (try cache.get(2)).?);
    try testing.expectEqualStrings("3", (try cache.get(3)).?);
    try testing.expectEqual(null, try cache.get(99));

    try testing.expectEqual(6, try cache.getSize());

    try cache.drop(2);
    try testing.expectEqual(null, try cache.get(2));
    try testing.expectEqual(4, try cache.getSize());
}
