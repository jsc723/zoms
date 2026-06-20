const std = @import("std");
const hash = @import("hash");
const Hash = hash.Hash;

pub const Chunk = struct {
    h: Hash,
    data: []const u8,

    pub const Empty = Chunk{ .h = Hash.Empty, .data = &.{} };

    pub fn getHash(self: *const Chunk) Hash {
        return self.h;
    }

    pub fn getData(self: *const Chunk) []const u8 {
        return self.data;
    }

    pub fn isEmpty(self: *const Chunk) bool {
        return self.data.len == 0;
    }

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Chunk {
        const dupData = try allocator.dupe(u8, data);
        return Chunk{
            .h = Hash.of(dupData),
            .data = dupData,
        };
    }

    pub fn initWithHash(allocator: std.mem.Allocator, data: []const u8, h: Hash) !Chunk {
        const dupData = try allocator.dupe(u8, data);
        return Chunk{
            .h = h,
            .data = dupData,
        };
    }

    pub fn moveInit(data: []const u8) Chunk {
        return Chunk{
            .h = Hash.of(data),
            .data = data,
        };
    }

    pub fn deinit(self: *const Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const ChunkWriter = struct {
    allocator: std.mem.Allocator,
    buffer: ?std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) ChunkWriter {
        return ChunkWriter{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).empty,
        };
    }

    pub fn write(self: *ChunkWriter, data: []const u8) void {
        const buffer = if (self.buffer != null) &self.buffer.? else {
            @panic("write() cannot be called after chunk() or close()");
        };
        buffer.appendSlice(self.allocator, data) catch |err| {
            std.debug.panic("chunk writer failed to append to buffer {any}", .{err});
        };
    }

    pub fn finish(self: *ChunkWriter) Chunk {
        const buf = if (self.buffer != null) &self.buffer.? else {
            std.debug.panic("chunk writer has already finished", .{});
        };
        const ownedData = buf.toOwnedSlice(self.allocator) catch |err| {
            std.debug.panic("chunk writer failed on converting buf's ownership {any}", .{err});
        };
        self.buffer = null;

        return Chunk.moveInit(ownedData);
    }

    pub fn deinit(self: *ChunkWriter) void {
        if (self.buffer != null) {
            self.buffer.?.deinit(self.allocator);
            self.buffer = null;
        }
    }
};

const testing = std.testing;

test "test chunk" {
    const alc = testing.allocator;
    const c0 = try Chunk.init(alc, "123");
    defer c0.deinit(alc);
    try testing.expectEqualStrings(
        "123",
        c0.getData(),
    );
    try testing.expect(!c0.getHash().isEmpty());
}

test "test chunk writer" {
    const alc = testing.allocator;
    var writer = ChunkWriter.init(alc);
    writer.write("abc");
    writer.write("123");
    writer.write("日本語");
    const c = writer.finish();
    defer c.deinit(alc);
    try testing.expectEqualStrings("abc123日本語", c.getData());

    var writer2 = ChunkWriter.init(alc);
    writer2.write("aaa");
    writer2.deinit();
}
