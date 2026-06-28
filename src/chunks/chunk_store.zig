const std = @import("std");
const Dir = std.Io.Dir;
const File = std.Io.File;
const path = std.Io.Dir.path;
const openOrCreateFile = @import("util").file.openOrCreateFile;
const chunks = @import("chunks.zig");
const hash = @import("hash");
const Chunk = chunks.Chunk;
const Hash = hash.Hash;
pub const HashChunkMap = std.AutoHashMap(Hash, Chunk);
const HashSet = Hash.Set;

pub fn ChunkStore(comptime io: std.Io) type {
    return union(enum) {
        const Self = @This();

        memoryStoreView: *MemoryStorageView(io),
        journalStore: *JournalStore(io),

        pub fn has(self: Self, h: Hash) !bool {
            return switch (self) {
                inline else => |m| m.has(h),
            };
        }

        pub fn hasMany(self: Self, keys: *const HashSet, onAbsent: anytype) !u32 {
            return switch (self) {
                inline else => |m| m.hasMany(keys, onAbsent),
            };
        }

        pub fn get(self: Self, h: Hash) !?Chunk {
            return switch (self) {
                inline else => |m| m.get(h),
            };
        }

        pub fn getMany(self: Self, keys: *const HashSet, onFound: anytype) !void {
            return switch (self) {
                inline else => |m| m.getMany(keys, onFound),
            };
        }

        pub fn put(self: Self, key: Hash, chunk: Chunk) !void {
            return switch (self) {
                inline else => |m| m.put(key, chunk),
            };
        }

        pub fn rebase(self: Self) !void {
            return switch (self) {
                inline else => |m| m.rebase(),
            };
        }

        pub fn root(self: Self) !Hash {
            return switch (self) {
                inline else => |m| m.root(),
            };
        }

        pub fn commit(self: Self, current: Hash, last: Hash) !bool {
            return switch (self) {
                inline else => |m| m.commit(current, last),
            };
        }

        pub fn deinit(self: Self) void {
            switch (self) {
                inline else => |m| m.deinit(),
            }
        }
    };
}

// MemoryStorage provides a "persistent" storage layer to back multiple
// MemoryStoreViews. A MemoryStorage instance holds the ground truth for the
// root and set of chunks that are visible to all MemoryStoreViews vended by
// NewView(), allowing them to implement the transaction-style semantics that
// ChunkStore requires.
pub fn MemoryStorage(comptime io: std.Io) type {
    return struct {
        data: HashChunkMap,
        rootHash: Hash,
        mu: std.Io.RwLock,
        alloc: std.mem.Allocator,
        const Self = @This();

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .data = HashChunkMap.init(alloc),
                .rootHash = Hash.Empty,
                .mu = std.Io.RwLock.init,
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            var iter = self.data.valueIterator();
            while (iter.next()) |pValue| {
                pValue.deinit(self.alloc);
            }
            self.data.deinit();
        }

        pub fn get(self: *Self, h: Hash) !?Chunk {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.data.get(h);
        }

        pub fn has(self: *Self, h: Hash) !bool {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.data.contains(h);
        }

        pub fn len(self: *Self) !u64 {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.data.count();
        }

        // root returns the currently "persisted" root hash of this in-memory store.
        pub fn root(self: *Self) !Hash {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.rootHash;
        }

        // Update checks the "persisted" root against last and, iff it matches,
        // updates the root to current, adds all of novel to ms.data, and returns
        // true. Otherwise returns false.
        pub fn update(self: *Self, current: Hash, last: Hash, novel: *const HashChunkMap) !bool {
            try self.mu.lock(io);
            defer self.mu.unlock(io);

            if (!last.equals(self.rootHash)) {
                return false;
            }
            self.rootHash = current;
            var it = novel.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                const v = entry.value_ptr.*;
                self.data.put(k, v) catch |err| {
                    std.debug.panic("failed to insert chunk {any}", .{err});
                };
            }
            return true;
        }
    };
}

pub fn MemoryStorageView(comptime io: std.Io) type {
    return struct {
        pending: HashChunkMap,
        rootHash: Hash,
        mu: std.Io.RwLock,
        storage: *MemoryStorage(io),

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, storage: *MemoryStorage(io)) Self {
            return .{
                .pending = HashChunkMap.init(alloc),
                .rootHash = Hash.Empty,
                .mu = std.Io.RwLock.init,
                .storage = storage,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pending.deinit();
        }

        pub fn asChunkStore(self: *Self) ChunkStore(io) {
            return .{ .memoryStoreView = self };
        }

        pub fn get(self: *Self, key: Hash) !?Chunk {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            if (self.pending.get(key)) |c| {
                return c;
            }
            return try self.storage.get(key);
        }

        pub fn getMany(self: *Self, keys: *const HashSet, onFound: anytype) !void {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);

            var iter = keys.keyIterator();
            while (iter.next()) |pk| {
                var chunk = self.pending.get(pk.*);
                if (chunk == null) {
                    chunk = try self.storage.get(pk.*);
                }
                if (chunk) |foundChunk| {
                    try onFound.invoke(foundChunk);
                }
            }
        }

        pub fn has(self: *Self, key: Hash) !bool {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.pending.contains(key) or try self.storage.has(key);
        }

        pub fn hasMany(self: *Self, keys: *const HashSet, onAbsent: anytype) !u32 {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            var absentCount: u32 = 0;
            var iter = keys.keyIterator();
            while (iter.next()) |pk| {
                if (self.pending.contains(pk.*) or (try self.storage.has(pk.*))) {
                    continue;
                }
                try onAbsent.invoke(pk.*);
                absentCount += 1;
            }
            return absentCount;
        }

        pub fn put(self: *Self, key: Hash, chunk: Chunk) !void {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            try self.pending.put(key, chunk);
        }

        pub fn rebase(self: *Self) !void {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            self.rootHash = try self.storage.root();
        }

        pub fn root(self: *Self) !Hash {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.rootHash;
        }

        pub fn commit(self: *Self, current: Hash, last: Hash) !bool {
            try self.mu.lock(io);
            defer self.mu.unlock(io);

            if (!last.equals(self.rootHash)) {
                return false;
            }

            const success = try self.storage.update(current, last, &self.pending);
            if (success) {
                // no need to free chunks here because they are now owned by MemoryStorage
                self.pending.clearAndFree();
            }
            self.rootHash = try self.storage.root();
            return success;
        }
    };
}

// JournalStore assume only one instance of JournalStore will have access to the underlying journel file.
// This means you cannot have multiple processes writing to the same journel file otherwise your file get corrupted.
pub fn JournalStore(comptime io: std.Io) type {
    const ChunkInfo = struct {
        offset: u64,
        size: u64,
    };
    return struct {
        pending: HashChunkMap,
        rootHash: Hash,
        mu: std.Io.RwLock,
        alloc: std.mem.Allocator,
        journal: File,
        journalReader: JournalReader(io),
        journalWriter: JournalWriter(io),
        journaledChunks: std.AutoHashMap(Hash, ChunkInfo),

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, journalPath: []const u8) !Self {
            const journal = try openOrCreateFile(io, journalPath, .{ .allowWrite = true });
            var self = Self{
                .pending = HashChunkMap.init(alloc),
                .rootHash = Hash.Empty,
                .mu = std.Io.RwLock.init,
                .alloc = alloc,
                .journal = journal,
                .journalReader = try .init(alloc, journal),
                .journalWriter = try .init(alloc, journal),
                .journaledChunks = .init(alloc),
            };

            try self.rebase();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.clearPending();
            self.pending.deinit();
            self.journalReader.deinit();
            self.journalWriter.deinit();
            self.journaledChunks.deinit();
            self.journal.close(io);
        }

        pub fn asChunkStore(self: *Self) ChunkStore(io) {
            return .{ .journalStore = self };
        }

        pub fn get(self: *Self, key: Hash) !?Chunk {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.pending.get(key);
            // todo
        }

        pub fn getMany(self: *Self, keys: *const HashSet, onFound: anytype) !void {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);

            var iter = keys.keyIterator();
            while (iter.next()) |pk| {
                if (self.pending.get(pk.*)) |foundChunk| {
                    try onFound.invoke(foundChunk);
                }
                // todo
            }
        }

        pub fn has(self: *Self, key: Hash) !bool {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            // todo
            return self.pending.contains(key);
        }

        pub fn hasMany(self: *Self, keys: *const HashSet, onAbsent: anytype) !u32 {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            var absentCount: u32 = 0;
            var iter = keys.keyIterator();
            while (iter.next()) |pk| {
                if (self.pending.contains(pk.*)) {
                    continue;
                }
                // todo
                try onAbsent.invoke(pk.*);
                absentCount += 1;
            }
            return absentCount;
        }

        pub fn put(self: *Self, key: Hash, chunk: Chunk) !void {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            try self.pending.put(key, chunk);
        }

        pub fn rebase(self: *Self) !void {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            try self.journalReader.reader.seekTo(0);
            while (self.journalReader.peekType()) |nextType| switch (nextType) {
                .Chunks => {
                    const RebaseChunksConsumer = struct {
                        store: *JournalStore(io),
                        fn invoke(closure: *@This(), h: Hash, chunkSize: u32, fileReader: *std.Io.File.Reader) !void {
                            const res = try closure.store.journaledChunks.getOrPut(h);
                            if (!res.found_existing) {
                                res.value_ptr.* = ChunkInfo{
                                    .offset = fileReader.logicalPos(),
                                    .size = chunkSize,
                                };
                            }
                            try fileReader.interface.discardAll(chunkSize);
                        }
                    };
                    var consumer = RebaseChunksConsumer{
                        .store = self,
                    };
                    try self.journalReader.readChunks(&consumer);
                },
                .Root => {
                    self.rootHash = try self.journalReader.readRoot();
                },
                .Table => {
                    @panic("not implemented");
                },
            } else |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            }
        }

        pub fn root(self: *Self) !Hash {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.rootHash;
        }

        pub fn commit(self: *Self, current: Hash, last: Hash) !bool {
            try self.mu.lock(io);
            defer self.mu.unlock(io);

            if (!last.equals(self.rootHash)) {
                return false;
            }

            try self.journalWriter.writeChunks(self.pending);
            try self.journalWriter.writeRoot(current);
            try self.journalWriter.writer.flush();
            self.clearPending();

            return true;
        }

        fn clearPending(self: *Self) void {
            var it = self.pending.valueIterator();
            while (it.next()) |pVal| {
                pVal.deinit(self.alloc);
            }
            self.pending.clearAndFree();
        }
    };
}

const JournalRecordType = enum { Chunks, Table, Root };

fn JournalWriter(comptime io: std.Io) type {
    return struct {
        const Self = @This();
        writer: std.Io.File.Writer,
        alloc: std.mem.Allocator,
        buffer: []u8,

        pub fn init(alloc: std.mem.Allocator, file: std.Io.File) !Self {
            const buffer = try alloc.alloc(u8, 4096);
            const writer = file.writer(io, buffer);
            return .{
                .writer = writer,
                .alloc = alloc,
                .buffer = buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.buffer);
        }

        pub fn writeChunks(self: *Self, chunkSets: HashChunkMap) !void {
            var w = &self.writer.interface;

            // type (1)
            try w.writeByte(@intFromEnum(JournalRecordType.Chunks));
            // number of chunks (4)
            const chunkCount = chunkSets.count();
            try w.writeInt(u32, chunkCount, .big);
            var hashAcc = Hash.ofNumber(u32, chunkCount);
            // chunks
            var it = chunkSets.iterator();
            while (it.next()) |entry| {
                try chunks.serialize(entry.value_ptr.*, w);
                hashAcc = hashAcc.add(entry.key_ptr.*);
            }
            // hash(number of chunks, chunk1.hash, chunk2.hash, ...) (20)
            try w.writeAll(&hashAcc.bytes);
        }

        pub fn writeRoot(self: *Self, root: Hash) !void {
            var w = &self.writer.interface;
            // type (1)
            try w.writeByte(@intFromEnum(JournalRecordType.Root));
            // root hash (20)
            try w.writeAll(&root.bytes);
        }
    };
}

fn JournalReader(comptime io: std.Io) type {
    return struct {
        const Self = @This();

        reader: std.Io.File.Reader,
        alloc: std.mem.Allocator,
        buffer: []u8,

        pub fn init(alloc: std.mem.Allocator, file: std.Io.File) !Self {
            const buffer = try alloc.alloc(u8, 4096);
            const reader = file.reader(io, buffer);
            return .{
                .reader = reader,
                .alloc = alloc,
                .buffer = buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.buffer);
        }

        pub fn peekType(self: *Self) !JournalRecordType {
            var r = &self.reader.interface;
            const typeByte = try r.peekByte();
            return @enumFromInt(typeByte);
        }

        // !! chunkConsumer must consume the chunk, either by read it or discard it. !!
        pub fn readChunks(self: *Self, chunkConsumer: anytype) !void {
            var r = &self.reader.interface;
            // type (1)
            const recordType: JournalRecordType = @enumFromInt(try r.takeByte());
            if (recordType != .Chunks) {
                return error.ReadChunksTypeMismatch;
            }
            // number of chunks (4)
            const chunkCount = try r.takeInt(u32, .big);
            var hashAcc = Hash.ofNumber(u32, chunkCount);

            var i: u32 = 0;
            while (i < chunkCount) : (i += 1) {
                //hash
                const h = try Hash.fromReader(r);
                hashAcc = hashAcc.add(h);
                //size
                const chunkSize = try r.takeInt(u32, .big);
                //data
                const expectPos = self.reader.logicalPos() + chunkSize;
                try chunkConsumer.invoke(h, chunkSize, &self.reader);
                if (self.reader.logicalPos() != expectPos) {
                    @panic("read chunk contract is violated");
                }
            }
            const readHashAcc = try Hash.fromReader(r);
            if (!readHashAcc.equals(hashAcc)) {
                return error.ChunksCorrupted;
            }
        }

        pub fn readRoot(self: *Self) !Hash {
            var r = &self.reader.interface;
            const recordType: JournalRecordType = @enumFromInt(try r.takeByte());
            if (recordType != .Root) {
                return error.ReadRootTypeMismatch;
            }
            return try Hash.fromReader(r);
        }
    };
}

const testing = std.testing;
test "test memory storage" {
    const io = testing.io;
    const alloc = testing.allocator;
    var storage = MemoryStorage(io).init(alloc);
    defer storage.deinit();

    // initial state
    try testing.expectEqual(0, try storage.len());
    const oldRoot = try storage.root();
    try testing.expect(oldRoot.isEmpty());

    // populate
    var pending = HashChunkMap.init(alloc);
    defer pending.deinit();
    const datas: [3][]const u8 = .{ "data", "hello", "world" };
    for (datas) |data| {
        try pending.put(Hash.of(data), try Chunk.init(alloc, data));
    }

    // successful update
    try testing.expect(try storage.update(Hash.of("a"), oldRoot, &pending));
    try testing.expectEqual(3, try storage.len());
    try testing.expect((try storage.root()).equals(Hash.of("a")));

    // failed update (wrong last root)
    try testing.expect(!try storage.update(Hash.of("c"), Hash.of("b"), &pending));
    try testing.expectEqual(3, try storage.len());

    // get and has
    try testing.expect(try storage.has(Hash.of("data")));
    try testing.expect(!try storage.has(Hash.of("notexist")));
    const c = try storage.get(Hash.of("data")) orelse @panic("data is null");
    try testing.expect(std.mem.eql(u8, c.getData(), "data"));
}

fn testChunkStore(store: ChunkStore(testing.io), alloc: std.mem.Allocator) !void {
    // put
    try store.put(Hash.of("pending"), try Chunk.init(alloc, "pending"));

    // has
    try testing.expect(try store.has(Hash.of("data")));
    try testing.expect(try store.has(Hash.of("hello")));
    try testing.expect(try store.has(Hash.of("world")));
    try testing.expect(try store.has(Hash.of("pending")));
    try testing.expect(!try store.has(Hash.of("notexist")));

    // get
    const data = try store.get(Hash.of("data")) orelse @panic("data is null");
    try testing.expect(std.mem.eql(u8, data.getData(), "data"));
    const pending = try store.get(Hash.of("pending")) orelse @panic("data (pending) is null");
    try testing.expect(std.mem.eql(u8, pending.getData(), "pending"));

    // hasMany
    var checkSet = HashSet.init(alloc);
    defer checkSet.deinit();
    try checkSet.put(Hash.of("data"), {});
    try checkSet.put(Hash.of("world"), {});
    try checkSet.put(Hash.of("pending"), {});
    try checkSet.put(Hash.of("nonexist"), {});

    var onAbsentInvoked: u32 = 0;
    var onAbsent = struct {
        pOnAbsentInvoked: *u32,
        fn invoke(self: *@This(), _: Hash) !void {
            self.pOnAbsentInvoked.* += 1;
        }
    }{ .pOnAbsentInvoked = &onAbsentInvoked };

    const absentCount = try store.hasMany(&checkSet, &onAbsent);
    try testing.expectEqual(1, absentCount);
    try testing.expectEqual(1, onAbsentInvoked);

    // getMany
    var found = HashChunkMap.init(alloc);
    defer found.deinit();
    var onFound = struct {
        found: *HashChunkMap,
        fn invoke(self: *@This(), chunk: Chunk) !void {
            try self.found.put(chunk.getHash(), chunk);
        }
    }{ .found = &found };
    try store.getMany(&checkSet, &onFound);
    try testing.expectEqual(3, found.count());
    try testing.expect(found.contains(Hash.of("data")));
    try testing.expect(found.contains(Hash.of("world")));
    try testing.expect(found.contains(Hash.of("pending")));

    try store.rebase();
    const last = try store.root();
    const current = Hash.of("current");
    try testing.expect(try store.commit(current, last));
    try testing.expectEqual(current, try store.root());

    // getMany2
    var found2 = HashChunkMap.init(alloc);
    defer found2.deinit();
    var onFound2 = struct {
        found: *HashChunkMap,
        fn invoke(self: *@This(), chunk: Chunk) !void {
            try self.found.put(chunk.getHash(), chunk);
        }
    }{ .found = &found2 };
    try store.getMany(&checkSet, &onFound2);
    try testing.expectEqual(3, found.count());
    try testing.expect(found.contains(Hash.of("data")));
    try testing.expect(found.contains(Hash.of("world")));
    try testing.expect(found.contains(Hash.of("pending")));
}

test "test memory storage view" {
    const io = testing.io;
    const alloc = testing.allocator;

    // set up storage with some chunks
    var storage = MemoryStorage(io).init(alloc);
    defer storage.deinit();
    var pending = HashChunkMap.init(alloc);
    defer pending.deinit();
    const datas: [3][]const u8 = .{ "data", "hello", "world" };
    for (datas) |data| {
        try pending.put(Hash.of(data), try Chunk.init(alloc, data));
    }

    try testing.expect(try storage.update(Hash.of("a"), Hash.Empty, &pending));

    var view = MemoryStorageView(io).init(alloc, &storage);
    defer view.deinit();

    try testChunkStore(view.asChunkStore(), alloc);
}

test "test journal writer and reader" {
    const io = testing.io;
    const alloc = testing.allocator;
    const tmpJournalPath = "tmp/testJournalWriter/test.zjs";
    const journal = try openOrCreateFile(io, tmpJournalPath, .{ .allowWrite = true });
    defer Dir.cwd().deleteTree(io, "tmp/testJournalWriter") catch {};

    var w = try JournalWriter(io).init(alloc, journal);
    defer w.deinit();

    const datas = [_][]const u8{ "hello", "world", "data" };
    var chunkSet = HashChunkMap.init(alloc);
    defer {
        var it = chunkSet.valueIterator();
        while (it.next()) |pVal| {
            pVal.deinit(alloc);
        }
        chunkSet.deinit();
    }
    for (datas) |data| {
        const c = try Chunk.init(alloc, data);
        try chunkSet.put(Hash.of(data), c);
    }
    try w.writeChunks(chunkSet);
    try w.writeRoot(Hash.of("a"));
    try w.writer.flush();

    var r = try JournalReader(io).init(alloc, journal);
    defer r.deinit();

    try r.reader.seekTo(0);
    const ChunkConsumer = struct {
        chunkSet: *HashChunkMap,
        fn invoke(self: *@This(), h: Hash, chunkSize: u32, fileReader: *std.Io.File.Reader) !void {
            var ri = &fileReader.interface;
            const buf = try testing.allocator.alloc(u8, chunkSize);
            try ri.readSliceAll(buf);
            const dataChunk = Chunk.moveInit(buf);
            defer dataChunk.deinit(alloc);
            try testing.expect(h.equals(dataChunk.getHash()));
            try testing.expect(self.chunkSet.contains(h));
        }
    };
    var consumer = ChunkConsumer{ .chunkSet = &chunkSet };
    try r.readChunks(&consumer);
    const rootRead = try r.readRoot();
    try testing.expectEqual(Hash.of("a"), rootRead);
}

test "test journal store" {
    const io = testing.io;
    const alloc = testing.allocator;
    const tmpJournalPath = "tmp/testJournalStore/test.zjs";
    var store = try JournalStore(io).init(alloc, tmpJournalPath);
    defer Dir.cwd().deleteTree(io, "tmp/testJournalWriter") catch {};
    defer store.deinit();

    const datas = [_][]const u8{ "hello", "world", "data" };
    var chunkSet = HashChunkMap.init(alloc);
    defer {
        var it = chunkSet.valueIterator();
        while (it.next()) |pVal| {
            pVal.deinit(alloc);
        }
        chunkSet.deinit();
    }
    for (datas) |data| {
        const c = try Chunk.init(alloc, data);
        try store.put(Hash.of(data), c);
    }

    try testing.expect(try store.commit(Hash.of("a"), try store.root()));

    // test rebase
    var store2 = try JournalStore(io).init(alloc, tmpJournalPath);
    defer store2.deinit();
    try store2.rebase();
}
