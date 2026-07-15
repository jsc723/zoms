const std = @import("std");
const posix = std.posix;
const Dir = std.Io.Dir;
const util = @import("util");
const RefCount = util.RefCount;

const MappedSlice = struct {
    raw: []align(std.heap.page_size_min) u8,
    mem: []const u8,

    pub fn init(file: std.Io.File, offset: u64, length: usize) !MappedSlice {
        const page_size = std.heap.page_size_min;
        const aligned_offset = (offset / page_size) * page_size;
        const padding = offset - aligned_offset;
        const mapped_size = length + padding;

        const raw = try posix.mmap(
            null,
            mapped_size,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            file.handle,
            aligned_offset,
        );

        return MappedSlice{
            .raw = raw,
            .mem = raw[padding..mapped_size],
        };
    }

    pub fn deinit(self: *MappedSlice) void {
        posix.munmap(self.raw);
    }
};

pub const SharedMappedSlice = struct {
    shared: MappedSlice,
    rc: RefCount,
    alloc: std.mem.Allocator,
    pub fn init(alloc: std.mem.Allocator, file: std.Io.File, offset: u64, length: usize) !*SharedMappedSlice {
        const shared = try MappedSlice.init(file, offset, length);
        const s = try alloc.create(SharedMappedSlice);
        s.* = .{
            .shared = shared,
            .rc = .{
                .count = std.atomic.Value(usize).init(1),
                .dropFn = SharedMappedSlice.drop,
            },
            .alloc = alloc,
        };
        return s;
    }
    pub fn data(self: *SharedMappedSlice) []const u8 {
        return self.shared.mem;
    }
    pub fn ref(self: *SharedMappedSlice) *SharedMappedSlice {
        self.rc.ref();
        return self;
    }
    pub fn unref(self: *SharedMappedSlice) void {
        self.rc.unref();
    }

    fn drop(rc: *RefCount) void {
        var self: *SharedMappedSlice = @fieldParentPtr("rc", rc);
        self.shared.deinit();
        self.alloc.destroy(self);
    }
};

const openOrCreateFile = @import("util").file.openOrCreateFile;

const testing = std.testing;
test "mmap" {
    const io = testing.io;
    const alloc = testing.allocator;
    const tmpFileName = "tmp/testMmap";
    Dir.cwd().deleteTree(io, tmpFileName) catch {};
    const file: std.Io.File = try openOrCreateFile(io, tmpFileName, .{ .allowWrite = true });
    defer file.close(io);

    const buffer = try alloc.alloc(u8, 4096);
    defer alloc.free(buffer);
    var writer = file.writer(io, buffer);
    var w = &writer.interface;
    for (0..40960) |i| {
        try w.writeInt(u64, i, .big);
    }
    try w.flush();
    try file.sync(io);

    {
        const offset: u64 = 4096;
        const length: usize = 1024; // 128 * u64
        var slice = try MappedSlice.init(file, offset, length);
        defer slice.deinit();

        try testing.expectEqual(length, slice.mem.len);

        const first_val = std.mem.readInt(u64, slice.mem[0..8], .big);
        try testing.expectEqual(@as(u64, 512), first_val);
    }

    {
        const offset: u64 = 5003;
        const length: usize = 17;
        var slice = try MappedSlice.init(file, offset, length);
        defer slice.deinit();

        try testing.expectEqual(length, slice.mem.len);

        const readBuffer = try alloc.alloc(u8, 4096);
        defer alloc.free(readBuffer);
        var reader = file.reader(io, readBuffer);
        try reader.seekTo(offset);
        var expected_bytes: [17]u8 = undefined;
        _ = try reader.interface.readSliceAll(&expected_bytes);

        try testing.expectEqualSlices(u8, &expected_bytes, slice.mem);
    }

    {
        const offset: u64 = 4096;
        const length: usize = 1024; // 128 * u64
        var slice = try SharedMappedSlice.init(alloc, file, offset, length);
        defer slice.unref();

        try testing.expectEqual(length, slice.data().len);

        const first_val = std.mem.readInt(u64, slice.data()[0..8], .big);
        try testing.expectEqual(@as(u64, 512), first_val);

        var slice2 = slice.ref();
        var slice3 = slice2.ref();
        var slice4 = slice.ref();
        try testing.expectEqualSlices(u8, slice.data(), slice2.data());
        slice2.unref();
        try testing.expectEqualSlices(u8, slice.data(), slice3.data());
        try testing.expectEqualSlices(u8, slice3.data(), slice4.data());
        slice4.unref();
        try testing.expectEqualSlices(u8, slice.data(), slice3.data());
        slice3.unref();
    }

    defer Dir.cwd().deleteTree(io, "tmp/testJournalStoreAll") catch {};
}
