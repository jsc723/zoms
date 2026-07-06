const std = @import("std");
const chunks = @import("MOD.zig");
var threaded = std.Io.Threaded.init_single_threaded;
const io = threaded.io();
const Chunk = chunks.chunks.Chunk;
const Hash = chunks.hash.Hash;

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
export fn journalStore_put(handle: ?*anyopaque, hash: [*]const u8, data: [*]const u8, len: usize) bool {
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle orelse return false));
    const chunk = Chunk.initWithHash(std.heap.c_allocator, data[0..len], Hash.fromOther(hash)) catch return false;
    store.putMove(chunk) catch {
        chunk.deinit(std.heap.c_allocator);
        return false;
    };
    return true;
}

pub const JournalSlice = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

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
