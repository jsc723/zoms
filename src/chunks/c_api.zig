const std = @import("std");
const chunks = @import("MOD.zig");
var threaded = std.Io.Threaded.init_single_threaded;
const io = threaded.io();
const Chunk = chunks.chunks.Chunk;

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

export fn journalStore_put(handle: ?*anyopaque, data: [*]const u8, len: usize) bool {
    const store: *chunks.JournalStore(io) = @ptrCast(@alignCast(handle orelse return false));
    const chunk = Chunk.init(std.heap.c_allocator, data[0..len]) catch return false;
    store.putMove(chunk) catch {
        chunk.deinit(std.heap.c_allocator);
        return false;
    };
    return true;
}
