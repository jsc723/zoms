const std = @import("std");
const chunks = @import("MOD.zig");
var threaded = std.Io.Threaded.init_single_threaded;
const io = threaded.io();
const Chunk = chunks.chunks.Chunk;
const Hash = chunks.hash.Hash;
pub const hash_iterator = @import("hash_iterator.zig");
pub const HashIterator = hash_iterator.HashIterator;
pub const ConstSliceIteraetor = hash_iterator.ConstSliceIterator;
pub const CArrayHashIterator = hash_iterator.CArrayHashIterator;

export fn journalStore_init(path: [*:0]const u8) ?*anyopaque {
    const alloc = std.heap.c_allocator;
    const store = alloc.create(chunks.JournalStore(io)) catch return null;
    store.* = chunks.JournalStore(io).init(alloc, std.mem.span(path), .{}) catch {
        alloc.destroy(store);
        return null;
    };
    return store;
}

export fn journalStore_deinit(handle: ?*anyopaque) void {
    if (handle) |h| {
        const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(h));
        store.deinit();
        std.heap.c_allocator.destroy(store);
    }
}

// todo: provide hash of data
export fn journalStore_put(handle: ?*anyopaque, hash: [*]const u8, data: [*]const u8, len: usize) void {
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle orelse return));
    const chunk = Chunk.initWithHash(std.heap.c_allocator, data[0..len], Hash.fromOther(hash)) catch return;
    store.putMove(chunk) catch {
        chunk.deinit(std.heap.c_allocator);
        return;
    };
}

pub const JournalSlice = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

// pub fn commit(self: *Self, current: Hash, last: Hash) !bool
export fn journalStore_commit(handle: ?*anyopaque, current: [*]const u8, last: [*]const u8) u32 {
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle orelse return 0));
    const hCurrent = Hash.fromOther(current);
    const hLast = Hash.fromOther(last);
    const res = store.commit(hCurrent, hLast) catch |e| {
        std.debug.print("ZJS Error: commit failed {any}\n", .{e});
        return 0;
    };
    if (res) {
        return 1;
    }
    return 0;
}

export fn journalStore_root(handle: ?*anyopaque, out: [*]u8) void {
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle orelse return));
    const res = store.root() catch |e| {
        std.debug.print("ZJS Error: commit failed {any}\n", .{e});
        return;
    };
    std.mem.copyForwards(u8, out[0..20], res.bytes[0..20]);
}

export fn journalStore_rebase(handle: ?*anyopaque) void {
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle orelse return));
    store.rebase() catch |e| {
        std.debug.print("ZJS Error: rebase failed {any}\n", .{e});
        return;
    };
}

export fn journalStore_has(handle: ?*anyopaque, key: ?[*]u8) bool {
    if (handle == null) {
        std.debug.print("ZJS Error: handle is null\n", .{});
        return false;
    }
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle.?));
    const h = Hash.fromOther(key.?);
    return store.has(h) catch |e| {
        std.debug.print("ZJS Error: has failed {any}\n", .{e});
        return false;
    };
}

export fn journalStore_hasMany(handle: ?*anyopaque, keys: ?[*]?[*]u8, out: ?[*]bool, len: usize) u64 {
    if (handle == null) {
        std.debug.print("ZJS Error: handle is null\n", .{});
        return 0;
    }
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle.?));

    var idxMap = std.AutoHashMap(Hash, u64).init(std.heap.c_allocator);
    defer idxMap.deinit();
    idxMap.ensureTotalCapacity(@intCast(len)) catch {
        std.debug.print("ZJS Error: failed to ensure capacity for idxMap\n", .{});
        return 0;
    };
    for (0..len) |i| {
        out.?[i] = true;
    }
    var keyIter = HashIterator{ .carray = CArrayHashIterator{
        .ptr = keys,
        .len = len,
        .i = 0,
        .cur = Hash.Empty,
    } };
    const Context = struct {
        idxMap: *std.AutoHashMap(Hash, u64),
        out: [*]bool,
        pub fn invoke(self: *@This(), h: Hash) !void {
            const i = self.idxMap.get(h).?;
            self.out[i] = false;
        }
    };
    var ctx = Context{
        .idxMap = &idxMap,
        .out = out.?,
    };
    const absent = store.hasMany(&keyIter, &ctx) catch |e| {
        std.debug.print("ZJS Error: hasMany failed {any}\n", .{e});
        return 0;
    };
    return absent;
}

export fn journalStore_get(handle: ?*anyopaque, key: ?[*]u8, out: ?*JournalSlice) void {
    if (handle == null) {
        std.debug.print("ZJS Error: handle is null\n", .{});
        return;
    }
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle.?));
    const h = Hash.fromOther(key.?);
    const res = store.get(h) catch |e| {
        std.debug.print("ZJS Error: get failed {any}\n", .{e});
        return;
    };
    if (res) |chunk| {
        out.?.* = JournalSlice{
            .ptr = chunk.data.ptr,
            .len = chunk.data.len,
        };
    }
}

export fn journalStore_getMany(handle: ?*anyopaque, keys: ?[*]?[*]u8, out_slices: ?[*]JournalSlice, len: usize) void {
    if (handle == null) {
        std.debug.print("ZJS Error: handle is null\n", .{});
        return;
    }
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle.?));
    var keyset = chunks.HashSet.init(std.heap.c_allocator);
    defer keyset.deinit();
    keyset.ensureTotalCapacity(@intCast(len)) catch {
        std.debug.print("ZJS Error: failed to ensure capacity for keyset\n", .{});
        return;
    };
    var idxMap = std.AutoHashMap(Hash, u64).init(std.heap.c_allocator);
    defer idxMap.deinit();
    idxMap.ensureTotalCapacity(@intCast(len)) catch {
        std.debug.print("ZJS Error: failed to ensure capacity for idxMap\n", .{});
        return;
    };
    for (0..len) |i| {
        const pHash = keys.?[i].?;
        const h = Hash.fromOther(pHash);
        keyset.put(h, {}) catch {
            std.debug.print("ZJS Error: keyset put failed\n", .{});
            return;
        };
        idxMap.put(h, i) catch {
            std.debug.print("ZJS Error: idxMap put failed\n", .{});
            return;
        };
    }
    const Context = struct {
        idxMap: *std.AutoHashMap(Hash, u64),
        out_slices: [*]JournalSlice,
        pub fn invoke(self: *@This(), chunk: Chunk) !void {
            const i = self.idxMap.get(chunk.h).?;
            self.out_slices[i] = JournalSlice{
                .ptr = chunk.data.ptr,
                .len = chunk.data.len,
            };
        }
    };
    var ctx = Context{
        .idxMap = &idxMap,
        .out_slices = out_slices.?,
    };
    store.getMany(&keyset, &ctx) catch |e| {
        std.debug.print("ZJS Error: getMany failed: {any}\n", .{e});
        return;
    };
}
