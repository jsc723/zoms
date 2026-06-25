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

    pub fn initWithoutOwnership(data: []const u8) Chunk {
        // same as moveInit, but just be explicit
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

// /*
//   Chunk Serialization:
//     Chunk 0
//     Chunk 1
//      ..
//     Chunk N

//   Chunk:
//     Hash  // 20-byte hash
//     Len   // 4-byte int
//     Data  // len(Data) == Len
// */

pub fn serialize(chunk: Chunk, writer: anytype) !void {
    std.debug.assert(!chunk.isEmpty());

    const h = chunk.getHash();
    try writer.writeAll(&h.bytes);

    const chunkSize: u32 = @intCast(chunk.data.len);
    try writer.writeInt(u32, chunkSize, .big);

    try writer.writeAll(chunk.data);
}

pub const ChunkDeserializer = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) ChunkDeserializer {
        return .{ .allocator = allocator, .reader = reader };
    }

    pub fn next(self: *ChunkDeserializer) !?Chunk {
        const c = deserializeChunk(self.allocator, self.reader) catch |err| {
            if (err == error.EndOfStream) return null;
            return err;
        };
        return c;
    }
};

fn deserializeChunk(alc: std.mem.Allocator, reader: *std.Io.Reader) !Chunk {
    var h = Hash.Empty;
    try reader.readSliceAll(&h.bytes);

    const chunkSize = try reader.takeInt(u32, .big);

    const data = try alc.alloc(u8, chunkSize);
    errdefer alc.free(data);
    try reader.readSliceAll(data);

    const c = Chunk.moveInit(data);
    if (!c.getHash().equals(h)) {
        return error.HashMismatch;
    }
    return c;
}

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

test "test serialize" {
    const alc = testing.allocator;
    var w = std.Io.Writer.Allocating.init(alc);
    defer w.deinit();

    // first chunk
    const data = "abc123";
    const chunk = try Chunk.init(alc, data);
    defer chunk.deinit(alc);
    try serialize(chunk, &w.writer);

    const written1 = w.written();
    try testing.expectEqual(@as(usize, 30), written1.len);
    try testing.expectEqualSlices(u8, &chunk.getHash().bytes, written1[0..20]);
    const size1 = std.mem.readInt(u32, written1[20..24], .big);
    try testing.expectEqual(@as(u32, 6), size1);
    try testing.expectEqualSlices(u8, data, written1[24..30]);

    // second chunk
    const data2 = "日本語";
    const chunk2 = try Chunk.init(alc, data2);
    defer chunk2.deinit(alc);
    try serialize(chunk2, &w.writer);

    const written2 = w.written();
    const offset = 30;
    try testing.expectEqual(@as(usize, offset + 20 + 4 + data2.len), written2.len);
    try testing.expectEqualSlices(u8, &chunk2.getHash().bytes, written2[offset..][0..20]);
    const size2 = std.mem.readInt(u32, written2[offset + 20 ..][0..4], .big);
    try testing.expectEqual(@as(u32, data2.len), size2);
    try testing.expectEqualSlices(u8, data2, written2[offset + 24 ..]);
}

test "test deserializer empty" {
    const alc = testing.allocator;
    var w = std.Io.Writer.Allocating.init(alc);
    defer w.deinit();

    var reader = std.Io.Reader.fixed(w.written());

    var deserializer = ChunkDeserializer.init(alc, &reader);
    const result = try deserializer.next();
    try testing.expectEqual(@as(?Chunk, null), result);
}

test "test deserializer single chunk" {
    const alc = testing.allocator;

    // serialize
    const data = "abc123";
    const chunk = try Chunk.init(alc, data);
    defer chunk.deinit(alc);

    var w = std.Io.Writer.Allocating.init(alc);
    defer w.deinit();
    try serialize(chunk, &w.writer);

    // deserialize
    const written = w.written();
    var reader = std.Io.Reader.fixed(written);
    var deserializer = ChunkDeserializer.init(alc, &reader);

    const c = try deserializer.next();
    try testing.expect(c != null);
    defer c.?.deinit(alc);
    try testing.expectEqualSlices(u8, data, c.?.getData());
    try testing.expect(chunk.getHash().equals(c.?.getHash()));

    // should be done
    try testing.expectEqual(@as(?Chunk, null), try deserializer.next());
}

test "test deserializer multiple chunks" {
    const alc = testing.allocator;

    const chunks_data = [_][]const u8{ "abc123", "日本語", "hello world" };

    // serialize all chunks
    var w = std.Io.Writer.Allocating.init(alc);
    defer w.deinit();
    for (chunks_data) |data| {
        const c = try Chunk.init(alc, data);
        defer c.deinit(alc);
        try serialize(c, &w.writer);
    }

    // deserialize and verify round trip
    const written = w.written();
    var reader = std.Io.Reader.fixed(written);
    var deserializer = ChunkDeserializer.init(alc, &reader);

    for (chunks_data) |expected_data| {
        const c = try deserializer.next();
        try testing.expect(c != null);
        defer c.?.deinit(alc);
        try testing.expectEqualSlices(u8, expected_data, c.?.getData());
    }
    try testing.expectEqual(@as(?Chunk, null), try deserializer.next());
}

test "test deserializer hash mismatch" {
    const alc = testing.allocator;

    // manually corrupt the hash bytes
    var w = std.Io.Writer.Allocating.init(alc);
    defer w.deinit();
    const data = "abc123";
    const chunk = try Chunk.init(alc, data);
    defer chunk.deinit(alc);
    try serialize(chunk, &w.writer);

    // flip first byte of hash
    const written = w.written();
    written[0] ^= 0xFF;

    var reader = std.Io.Reader.fixed(written);
    var deserializer = ChunkDeserializer.init(alc, &reader);
    try testing.expectError(error.HashMismatch, deserializer.next());
}
