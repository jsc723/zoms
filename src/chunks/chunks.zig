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

pub const ChunkSerializer = struct {
    alloc: std.mem.Allocator,
    compressionBuffer: std.ArrayList(u8),
    pub fn init(alloc: std.mem.Allocator) ChunkSerializer {
        return .{
            .alloc = alloc,
            .compressionBuffer = .empty,
        };
    }
    pub fn deinit(self: *ChunkSerializer) void {
        self.compressionBuffer.deinit(self.alloc);
    }
    pub fn serialize(self: *ChunkSerializer, chunk: Chunk, writer: *std.Io.Writer) !u32 {
        std.debug.assert(!chunk.isEmpty());

        const h = chunk.getHash();
        try writer.writeAll(&h.bytes);

        const max_compressed_size: usize = @intCast(lz4.LZ4_compressBound(@intCast(chunk.data.len)));
        try self.compressionBuffer.resize(self.alloc, max_compressed_size);
        const compressedSize: u32 = @intCast(lz4.LZ4_compress_default(
            @ptrCast(chunk.data.ptr),
            @ptrCast(self.compressionBuffer.items.ptr),
            @intCast(chunk.data.len),
            @intCast(max_compressed_size),
        ));
        try writer.writeInt(u32, compressedSize, .big);

        const rawSize: u32 = @intCast(chunk.data.len);
        try writer.writeInt(u32, rawSize, .big);

        try writer.writeAll(self.compressionBuffer.items[0..compressedSize]);
        return compressedSize;
    }
};

pub const ChunkDeserializer = struct {
    alloc: std.mem.Allocator,
    compressedBuffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) ChunkDeserializer {
        return .{
            .alloc = allocator,
            .compressedBuffer = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.compressedBuffer.deinit(self.alloc);
    }

    pub fn deserialize(self: *ChunkDeserializer, reader: *std.Io.Reader) !Chunk {
        var h = Hash.Empty;
        try reader.readSliceAll(&h.bytes);

        const compressedSize = try reader.takeInt(u32, .big);
        const rawSize = try reader.takeInt(u32, .big);

        const c = try self.deserializeData(reader, compressedSize, rawSize);
        errdefer c.deinit(self.alloc);
        if (!c.getHash().equals(h)) {
            return error.HashMismatch;
        }
        return c;
    }

    pub fn deserializeData(self: *ChunkDeserializer, reader: *std.Io.Reader, compressedSize: u32, rawSize: u32) !Chunk {
        try self.compressedBuffer.resize(self.alloc, compressedSize);
        try reader.readSliceAll(self.compressedBuffer.items);

        const data = try self.alloc.alloc(u8, rawSize);
        const decompressedLen: u32 = @intCast(lz4.LZ4_decompress_safe(
            @ptrCast(self.compressedBuffer.items.ptr),
            @ptrCast(data.ptr),
            @intCast(compressedSize),
            @intCast(rawSize),
        ));
        if (rawSize != decompressedLen) {
            return error.DecompressedLenNotMatchRawSize;
        }
        return Chunk.moveInit(data);
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

test "test serialize" {
    const alc = testing.allocator;
    var w = std.Io.Writer.Allocating.init(alc);
    defer w.deinit();

    // ==========================================
    // First Chunk: "abc123"
    // ==========================================
    const data = "abc123";
    const chunk = try Chunk.init(alc, data);
    defer chunk.deinit(alc);

    var srz = ChunkSerializer.init(alc);
    defer srz.deinit();

    // serialize returns the dynamic compressedSize
    const compSize1 = try srz.serialize(chunk, &w.writer);

    var written1 = w.written();
    // Layout check: 20 (Hash) + 4 (compSize) + 4 (rawSize) + compSize1
    const expected_len1 = 20 + 4 + 4 + compSize1;
    try testing.expectEqual(@as(usize, expected_len1), written1.len);

    // 1. Verify Hash
    try testing.expectEqualSlices(u8, &chunk.getHash().bytes, written1[0..20]);

    // 2. Verify compressedSize metadata
    const size1 = std.mem.readInt(u32, written1[20..24], .big);
    try testing.expectEqual(@as(u32, compSize1), size1);

    // 3. Verify rawSize metadata
    const rawSize1 = std.mem.readInt(u32, written1[24..28], .big);
    try testing.expectEqual(@as(u32, data.len), rawSize1);

    // 4. Verify Payload is compressed (should match our buffer)
    try testing.expectEqualSlices(u8, srz.compressionBuffer.items[0..compSize1], written1[28 .. 28 + compSize1]);

    // ==========================================
    // Second Chunk: "日本語"
    // ==========================================
    const data2 = "日本語";
    const chunk2 = try Chunk.init(alc, data2);
    defer chunk2.deinit(alc);

    const compSize2 = try srz.serialize(chunk2, &w.writer);

    var written2 = w.written();
    const offset = expected_len1; // Start of the second chunk

    const expected_len2 = offset + 20 + 4 + 4 + compSize2;
    try testing.expectEqual(@as(usize, expected_len2), written2.len);

    // 1. Verify Hash
    try testing.expectEqualSlices(u8, &chunk2.getHash().bytes, written2[offset..][0..20]);

    // 2. Verify compressedSize metadata
    const size2 = std.mem.readInt(u32, written2[offset + 20 ..][0..4], .big);
    try testing.expectEqual(@as(u32, compSize2), size2);

    // 3. Verify rawSize metadata
    const rawSize2 = std.mem.readInt(u32, written2[offset + 24 ..][0..4], .big);
    try testing.expectEqual(@as(u32, data2.len), rawSize2);

    // 4. Verify Payload
    try testing.expectEqualSlices(u8, srz.compressionBuffer.items[0..compSize2], written2[offset + 28 ..]);
}

test "test deserializer single chunk" {
    const alc = testing.allocator;

    // serialize
    const data = "abc123";
    const chunk = try Chunk.init(alc, data);
    defer chunk.deinit(alc);

    var srz = ChunkSerializer.init(alc);
    defer srz.deinit();

    var w = std.Io.Writer.Allocating.init(alc);
    defer w.deinit();
    _ = try srz.serialize(chunk, &w.writer);

    // deserialize
    const written = w.written();
    var reader = std.Io.Reader.fixed(written);
    var deserializer = ChunkDeserializer.init(alc);
    defer deserializer.deinit();

    const c = try deserializer.deserialize(&reader);
    defer c.deinit(alc);
    try testing.expectEqualSlices(u8, data, c.getData());
    try testing.expect(chunk.getHash().equals(c.getHash()));

    try testing.expectError(error.EndOfStream, reader.take(1));
}

test "test deserializer multiple chunks" {
    const alc = testing.allocator;

    const chunks_data = [_][]const u8{ "abc123", "日本語", "hello world" };

    // serialize all chunks
    var w = std.Io.Writer.Allocating.init(alc);
    defer w.deinit();
    var srz = ChunkSerializer.init(alc);
    defer srz.deinit();
    for (chunks_data) |data| {
        const c = try Chunk.init(alc, data);
        defer c.deinit(alc);
        _ = try srz.serialize(c, &w.writer);
    }

    // deserialize and verify round trip
    const written = w.written();

    var reader = std.Io.Reader.fixed(written);
    var deserializer = ChunkDeserializer.init(alc);
    defer deserializer.deinit();

    for (chunks_data) |expected_data| {
        const c = try deserializer.deserialize(&reader);
        defer c.deinit(alc);
        try testing.expectEqualSlices(u8, expected_data, c.getData());
    }
    try testing.expectError(error.EndOfStream, reader.take(1));
}

test "test deserializer hash mismatch" {
    const alc = testing.allocator;

    // manually corrupt the hash bytes
    var w = std.Io.Writer.Allocating.init(alc);
    defer w.deinit();
    const data = "abc123";
    const chunk = try Chunk.init(alc, data);
    defer chunk.deinit(alc);
    var srz = ChunkSerializer.init(alc);
    defer srz.deinit();
    _ = try srz.serialize(chunk, &w.writer);

    // flip first byte of hash
    const written = w.written();
    written[0] ^= 0xFF;

    var reader = std.Io.Reader.fixed(written);
    var deserializer = ChunkDeserializer.init(alc);
    defer deserializer.deinit();
    try testing.expectError(error.HashMismatch, deserializer.deserialize(&reader));
}

const lz4 = @import("lz4");
test "lz4 compression" {
    const allocator = std.testing.allocator;

    // 1. Prepare compressible raw test data
    const raw_data = "ZJS Engine Test! " ** 20; // Generates 340 bytes of repetitive text

    // 2. Calculate the worst-case maximum size required for LZ4 compression
    const max_compressed_size: usize = @intCast(lz4.LZ4_compressBound(@intCast(raw_data.len)));

    // 3. Allocate the compression buffer
    const compressed_buf = try allocator.alloc(u8, max_compressed_size);
    defer allocator.free(compressed_buf);

    // 4. Call the compression interface
    const compressed_size = lz4.LZ4_compress_default(
        @ptrCast(raw_data.ptr),
        @ptrCast(compressed_buf.ptr),
        @intCast(raw_data.len),
        @intCast(max_compressed_size),
    );

    // Verify that compression succeeded (return value should be greater than 0)
    try std.testing.expect(compressed_size > 0);
    const final_compressed_slice = compressed_buf[0..@as(usize, @intCast(compressed_size))];

    // 5. Allocate the decompression buffer (in production, raw_data.len will be retrieved from the Index)
    const decompressed_buf = try allocator.alloc(u8, raw_data.len);
    defer allocator.free(decompressed_buf);

    // 6. Call the decompression interface (LZ4_decompress_safe is the recommended safe variant)
    const decompress_result = lz4.LZ4_decompress_safe(
        @ptrCast(final_compressed_slice.ptr),
        @ptrCast(decompressed_buf.ptr),
        @intCast(final_compressed_slice.len),
        @intCast(raw_data.len),
    );

    // Verify that the decompressed size matches the original length exactly
    try std.testing.expectEqual(@as(i32, @intCast(raw_data.len)), decompress_result);

    // 7. Ultimate verification: ensure raw data and decompressed data are identical
    try std.testing.expectEqualSlices(u8, raw_data, decompressed_buf);
}
