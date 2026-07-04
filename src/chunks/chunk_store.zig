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

        pub fn hasMany(self: Self, keys: *const HashSet, onAbsent: anytype) !u64 {
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

        // putMove takes ownership of chunk
        pub fn putMove(self: Self, chunk: Chunk) !void {
            return switch (self) {
                inline else => |m| m.putMove(chunk),
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
        alloc: std.mem.Allocator,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, storage: *MemoryStorage(io)) Self {
            return .{
                .pending = HashChunkMap.init(alloc),
                .rootHash = Hash.Empty,
                .mu = std.Io.RwLock.init,
                .storage = storage,
                .alloc = alloc,
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
                return try Chunk.init(self.alloc, c.data);
            }
            if (try self.storage.get(key)) |c| {
                return try Chunk.init(self.alloc, c.data);
            }
            return null;
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
                    try onFound.invoke(try Chunk.init(self.alloc, foundChunk.data));
                }
            }
        }

        pub fn has(self: *Self, key: Hash) !bool {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.pending.contains(key) or try self.storage.has(key);
        }

        pub fn hasMany(self: *Self, keys: *const HashSet, onAbsent: anytype) !u64 {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            var absentCount: u64 = 0;
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

        pub fn putMove(self: *Self, chunk: Chunk) !void {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            try self.pending.put(chunk.h, chunk);
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

const ChunkRef = struct {
    offset: u64,
    size: u32,

    pub fn isValid(self: ChunkRef) bool {
        return self.size > 0;
    }
};

// JournalStore assume only one instance of JournalStore will have access to the underlying journel file.
// This means you cannot have multiple processes writing to the same journel file otherwise your file get corrupted.
pub fn JournalStore(comptime io: std.Io) type {
    return struct {
        mu: std.Io.RwLock,
        alloc: std.mem.Allocator,
        journal: File,
        journalReader: JournalReader(io),
        journalWriter: JournalWriter(io),

        rootHash: Hash,
        pendingSize: u64,
        pending: HashChunkMap, // in memory not committed chunks
        journaledChunks: std.AutoHashMap(Hash, ChunkRef), // commited chunks (but not indexed)
        indexHeaders: std.ArrayList(IndexHeader), // indexes

        const Self = @This();
        const MaxJournaledChunksCount = 1000;
        const MaxPendingSizeInByte = 1 << 20; // 1mb

        pub fn init(alloc: std.mem.Allocator, journalPath: []const u8) !Self {
            const journal = try openOrCreateFile(io, journalPath, .{ .allowWrite = true });
            var writer = try JournalWriter(io).init(alloc, journal);
            errdefer writer.deinit();
            if (try journal.length(io) == 0) {
                const placeholderIndex = Index.initHeader(alloc);
                try writer.writeIndex(placeholderIndex);
                try writer.flush();
            }
            var reader = try JournalReader(io).init(alloc, journal);
            errdefer reader.deinit();
            var self = Self{
                .pendingSize = 0,
                .pending = HashChunkMap.init(alloc),
                .rootHash = Hash.Empty,
                .mu = std.Io.RwLock.init,
                .alloc = alloc,
                .journal = journal,
                .journalReader = reader,
                .journalWriter = writer,
                .journaledChunks = .init(alloc),
                .indexHeaders = .empty,
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
            self.indexHeaders.deinit(self.alloc);
            self.journal.close(io);
        }

        pub fn asChunkStore(self: *Self) ChunkStore(io) {
            return .{ .journalStore = self };
        }

        pub fn get(self: *Self, key: Hash) !?Chunk {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            var r = &self.journalReader.reader;
            if (self.pending.get(key)) |val| {
                return try Chunk.init(self.alloc, val.data);
            }
            if (self.journaledChunks.get(key)) |info| {
                try r.seekTo(info.offset);
                const data = try r.interface.readAlloc(self.alloc, info.size);
                return Chunk.moveInit(data);
            }
            var i = self.indexHeaders.items.len;
            while (i > 0) {
                i -= 1;
                const header = self.indexHeaders.items[i];
                try r.seekTo(header.offset);
                const maybeRef = try self.journalReader.searchInIndex(key);
                if (maybeRef) |ref| {
                    try r.seekTo(ref.offset);
                    const data = try r.interface.readAlloc(self.alloc, ref.size);
                    return Chunk.moveInit(data);
                }
            }
            return null;
        }

        pub fn getMany(self: *Self, keys: *const HashSet, onFound: anytype) !void {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);

            var iter = keys.keyIterator();
            var journaledRefs = std.ArrayList(HashRefPair).empty;
            defer journaledRefs.deinit(self.alloc);
            var remaining = std.ArrayList(HashRefPair).empty;
            defer remaining.deinit(self.alloc);
            var r = &self.journalReader.reader;
            while (iter.next()) |pk| {
                if (self.pending.get(pk.*)) |foundChunk| {
                    try onFound.invoke(try Chunk.initWithHash(self.alloc, foundChunk.data, pk.*));
                } else if (self.journaledChunks.get(pk.*)) |ref| {
                    try journaledRefs.append(self.alloc, .{
                        .h = pk.*,
                        .ref = ref,
                    });
                } else {
                    try remaining.append(self.alloc, .{
                        .h = pk.*,
                        .ref = ChunkRef{
                            .offset = 0,
                            .size = 0,
                        },
                    });
                }
            }
            std.mem.sortUnstable(HashRefPair, journaledRefs.items, {}, struct {
                fn less(_: void, a: HashRefPair, b: HashRefPair) bool {
                    return a.ref.offset < b.ref.offset;
                }
            }.less);
            std.mem.sortUnstable(HashRefPair, remaining.items, {}, struct {
                fn less(_: void, a: HashRefPair, b: HashRefPair) bool {
                    return a.h.compare(b.h) == .lt;
                }
            }.less);
            var i = self.indexHeaders.items.len;
            while (i > 0) {
                i -= 1;
                const header = self.indexHeaders.items[i];
                try r.seekTo(header.offset);
                const absent = try self.journalReader.searchManyInIndex(remaining);
                if (absent == 0) {
                    break;
                }
            }
            std.mem.sortUnstable(HashRefPair, remaining.items, {}, struct {
                fn less(_: void, a: HashRefPair, b: HashRefPair) bool {
                    return a.ref.offset < b.ref.offset;
                }
            }.less);
            i = 0;
            var j: usize = 0;
            while (i < journaledRefs.items.len and j < remaining.items.len) {
                var toFetch: ChunkRef = undefined;
                if (journaledRefs.items[i].ref.offset <= remaining.items[j].ref.offset) {
                    toFetch = journaledRefs.items[i].ref;
                    i += 1;
                } else {
                    toFetch = remaining.items[j].ref;
                    j += 1;
                }
                if (!toFetch.isValid()) {
                    continue;
                }
                try r.seekTo(toFetch.offset);
                const data = try r.interface.readAlloc(self.alloc, toFetch.size);
                try onFound.invoke(Chunk.moveInit(data));
            }
            while (i < journaledRefs.items.len) : (i += 1) {
                const toFetch = journaledRefs.items[i].ref;
                if (!toFetch.isValid()) continue;
                try r.seekTo(toFetch.offset);
                const data = try r.interface.readAlloc(self.alloc, toFetch.size);
                try onFound.invoke(Chunk.moveInit(data));
            }
            while (j < remaining.items.len) : (j += 1) {
                const toFetch = remaining.items[j].ref;
                if (!toFetch.isValid()) continue;
                try r.seekTo(toFetch.offset);
                const data = try r.interface.readAlloc(self.alloc, toFetch.size);
                try onFound.invoke(Chunk.moveInit(data));
            }
        }

        pub fn has(self: *Self, key: Hash) !bool {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            var r = &self.journalReader.reader;
            if (self.pending.contains(key) or self.journaledChunks.contains(key)) {
                return true;
            }
            var i = self.indexHeaders.items.len;
            while (i > 0) {
                i -= 1;
                const header = self.indexHeaders.items[i];
                try r.seekTo(header.offset);
                const maybeRef = try self.journalReader.searchInIndex(key);
                if (maybeRef != null) {
                    return true;
                }
            }
            return false;
        }

        pub fn hasMany(self: *Self, keys: *const HashSet, onAbsent: anytype) !u64 {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            var iter = keys.keyIterator();
            var remaining = std.ArrayList(HashRefPair).empty;
            defer remaining.deinit(self.alloc);
            var r = &self.journalReader.reader;

            while (iter.next()) |pk| {
                if (self.pending.contains(pk.*) or self.journaledChunks.contains(pk.*)) {
                    continue;
                }
                try remaining.append(self.alloc, .{
                    .h = pk.*,
                    .ref = ChunkRef{
                        .offset = 0,
                        .size = 0,
                    },
                });
            }
            std.mem.sortUnstable(HashRefPair, remaining.items, {}, struct {
                fn less(_: void, a: HashRefPair, b: HashRefPair) bool {
                    return a.h.compare(b.h) == .lt;
                }
            }.less);
            var i = self.indexHeaders.items.len;
            var absent: u64 = @intCast(remaining.items.len);
            while (i > 0) {
                i -= 1;
                const header = self.indexHeaders.items[i];
                try r.seekTo(header.offset);
                // absent can only be smaller or equal for each call to searchManyInIndex
                absent = try self.journalReader.searchManyInIndex(remaining);
                if (absent == 0) {
                    return 0;
                }
            }
            for (remaining.items) |item| {
                if (!item.ref.isValid()) {
                    try onAbsent.invoke(item.h);
                }
            }

            return absent;
        }

        pub fn putMove(self: *Self, chunk: Chunk) !void {
            try self.mu.lock(io);
            defer self.mu.unlock(io);
            if (self.journaledChunks.contains(chunk.h)) {
                return;
            }
            try self.pending.put(chunk.h, chunk);
            self.pendingSize += chunk.data.len;
            if (self.pendingSize > Self.MaxPendingSizeInByte) {
                try self.writePending();
            }
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
                                res.value_ptr.* = ChunkRef{
                                    .offset = fileReader.logicalPos(),
                                    .size = chunkSize,
                                };
                            }
                            try fileReader.seekBy(chunkSize);
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
                .Index => {
                    const idxHeader = try self.journalReader.skipIndex();
                    try self.indexHeaders.append(self.alloc, idxHeader);
                },
            } else |err| switch (err) {
                error.EndOfStream => {
                    return;
                },
                else => return err,
            }
        }

        pub fn root(self: *Self) !Hash {
            try self.mu.lockShared(io);
            defer self.mu.unlockShared(io);
            return self.rootHash;
        }

        fn writePending(self: *Self) !void {
            // assume is locked
            const WriteChunkCallBack = struct {
                store: *Self,
                fn invoke(closure: *@This(), h: Hash, offset: u64, size: u32) !void {
                    try closure.store.journaledChunks.put(h, .{
                        .offset = offset,
                        .size = size,
                    });
                }
            };
            var cb = WriteChunkCallBack{
                .store = self,
            };

            try self.journalWriter.writeChunks(self.pending, &cb);
            try self.journalWriter.writer.flush();
            self.clearPending();
        }

        fn clearPending(self: *Self) void {
            // assume is locked
            self.pendingSize = 0;
            var it = self.pending.valueIterator();
            while (it.next()) |pVal| {
                pVal.deinit(self.alloc);
            }
            self.pending.clearAndFree();
        }

        pub fn commit(self: *Self, current: Hash, last: Hash) !bool {
            try self.mu.lock(io);
            defer self.mu.unlock(io);

            if (!last.equals(self.rootHash)) {
                return false;
            }

            try self.writePending();
            if (self.journaledChunks.count() > Self.MaxJournaledChunksCount) {
                const idx = try Index.init(self.alloc, self.journaledChunks);
                const idxOffset = self.journalWriter.writer.logicalPos();
                try self.journalWriter.writeIndex(idx);
                try self.indexHeaders.append(self.alloc, .{
                    .offset = idxOffset,
                    .count = idx.count,
                    .level = idx.level,
                    .next = idx.next,
                });
                self.journaledChunks.clearAndFree();
            }
            try self.journalWriter.writeRoot(current);
            try self.journalWriter.writer.flush();
            self.rootHash = current;

            return true;
        }
    };
}

const IndexHeader = struct {
    offset: u64,
    count: u64,
    level: u32,
    next: u64,
};

const Index = struct {
    const Prefix = u64;
    const Suffix = [12]u8;
    count: u64,
    level: u32,
    next: u64,
    prefixs: []Prefix,
    suffixs: []Suffix,
    refs: []ChunkRef,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, chunkRefs: std.AutoHashMap(Hash, ChunkRef)) !Index {
        const count = chunkRefs.count();
        var pairs = try alloc.alloc(HashRefPair, count);
        defer alloc.free(pairs);
        var it = chunkRefs.iterator();
        var i: usize = 0;
        while (it.next()) |e| {
            pairs[i] = .{
                .h = e.key_ptr.*,
                .ref = e.value_ptr.*,
            };
            i += 1;
        }
        // sort refs by hash

        std.mem.sortUnstable(HashRefPair, pairs, {}, struct {
            fn less(_: void, lhs: HashRefPair, rhs: HashRefPair) bool {
                return lhs.h.compare(rhs.h) == .lt;
            }
        }.less);
        var prefixs = try alloc.alloc(u64, count);
        errdefer alloc.free(prefixs);
        var suffixs = try alloc.alloc(Suffix, count);
        errdefer alloc.free(suffixs);
        var refs = try alloc.alloc(ChunkRef, count);
        errdefer alloc.free(refs);
        i = 0;
        while (i < pairs.len) : (i += 1) {
            prefixs[i] = pairs[i].h.prefix();
            suffixs[i] = pairs[i].h.suffix();
            refs[i] = pairs[i].ref;
        }
        return Index{
            .count = count,
            .level = 0,
            .next = 0,
            .prefixs = prefixs,
            .suffixs = suffixs,
            .refs = refs,
            .alloc = alloc,
        };
    }

    // this is used for the special index at the beginning of the journal file which serves as a header.
    // It has a very large level so it will never be merged.
    pub fn initHeader(alloc: std.mem.Allocator) Index {
        return Index{
            .count = 0,
            .level = 1 << 30, // some very large number
            .next = 0,
            .prefixs = &.{},
            .suffixs = &.{},
            .refs = &.{},
            .alloc = alloc,
        };
    }

    pub fn initFromReader(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Index {
        var hasher = std.hash.Crc32.init();
        const ReaderContext = struct {
            br: *std.Io.Reader,
            hasher: *std.hash.Crc32,

            fn readAll(ctx: *@This(), buffer: []u8) !void {
                try ctx.br.readSliceAll(buffer);
                ctx.hasher.update(buffer);
            }
            fn takeByte(ctx: *@This()) !u8 {
                const byte = try ctx.br.takeByte();
                ctx.hasher.update(&[_]u8{byte});
                return byte;
            }
            fn takeInt(ctx: *@This(), comptime T: type) !T {
                var buf: [@sizeOf(T)]u8 = undefined;
                try ctx.br.readSliceAll(&buf);
                ctx.hasher.update(&buf);
                return std.mem.readInt(T, &buf, .big);
            }
        };
        var r = ReaderContext{ .br = reader, .hasher = &hasher };

        // type
        const recordType: JournalRecordType = @enumFromInt(try r.takeByte());
        if (recordType != .Index) {
            return error.ReadIndexTypeMismatch;
        }
        // count
        const count = try r.takeInt(u64);
        // level
        const level = try r.takeInt(u32);
        // next
        const next = try r.takeInt(u64);

        var prefixs = try alloc.alloc(u64, count);
        errdefer alloc.free(prefixs);
        var suffixs = try alloc.alloc(Suffix, count);
        errdefer alloc.free(suffixs);
        var refs = try alloc.alloc(ChunkRef, count);
        errdefer alloc.free(refs);
        // prefix
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            prefixs[i] = try r.takeInt(u64);
        }
        // suffix
        i = 0;
        while (i < count) : (i += 1) {
            try r.readAll(&suffixs[i]);
        }
        // refs
        i = 0;
        while (i < count) : (i += 1) {
            const offset = try r.takeInt(u64);
            const size = try r.takeInt(u32);
            refs[i] = .{
                .offset = offset,
                .size = size,
            };
        }
        const crc32 = hasher.final();
        const readCrc32 = try reader.takeInt(u32, .big);
        if (readCrc32 != crc32) {
            return error.IndexCrc32NotMatch;
        }
        return Index{
            .count = count,
            .level = level,
            .next = next,
            .prefixs = prefixs,
            .suffixs = suffixs,
            .refs = refs,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: Index) void {
        self.alloc.free(self.prefixs);
        self.alloc.free(self.suffixs);
        self.alloc.free(self.refs);
    }
};

const JournalRecordType = enum { Chunks, Index, Root };

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

        pub fn writeChunks(self: *Self, chunkSets: HashChunkMap, onChunkWritten: anytype) !void {
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
                const offset = self.writer.logicalPos() - entry.value_ptr.data.len;
                const size: u32 = @intCast(entry.value_ptr.data.len);
                try onChunkWritten.invoke(entry.key_ptr.*, offset, size);
                hashAcc = hashAcc.add(entry.key_ptr.*);
            }
            // hash(number of chunks, chunk1.hash, chunk2.hash, ...) (20)
            try w.writeAll(&hashAcc.bytes);
        }

        pub fn writeIndex(self: *Self, index: Index) !void {
            const base_writer = &self.writer.interface;
            if (index.prefixs.len != index.count) {
                return error.PrefixLenInvalid;
            }
            if (index.refs.len != index.count) {
                return error.RefsLenInvalid;
            }
            if (index.suffixs.len != index.count) {
                return error.SuffixsLenInvalid;
            }
            var hasher = std.hash.Crc32.init();
            const WriterContext = struct {
                bw: *std.Io.Writer,
                hasher: *std.hash.Crc32,

                fn writeAll(ctx: *@This(), bytes: []const u8) !void {
                    try ctx.bw.writeAll(bytes);
                    ctx.hasher.update(bytes);
                }
                fn writeByte(ctx: *@This(), byte: u8) !void {
                    try ctx.bw.writeByte(byte);
                    ctx.hasher.update(&[_]u8{byte});
                }
                fn writeInt(ctx: *@This(), comptime T: type, n: T) !void {
                    var buf: [@sizeOf(T)]u8 = undefined;
                    std.mem.writeInt(T, &buf, n, .big);
                    try ctx.bw.writeAll(&buf);
                    ctx.hasher.update(&buf);
                }
            };
            var w = WriterContext{ .bw = base_writer, .hasher = &hasher };

            // type (1)
            try w.writeByte(@intFromEnum(JournalRecordType.Index));
            // count (8)
            try w.writeInt(u64, index.count);
            // level (4)
            try w.writeInt(u32, index.level);
            // next (8)
            try w.writeInt(u64, index.next);
            // prefix
            for (index.prefixs) |prefix| {
                try w.writeInt(u64, prefix);
            }
            // suffix
            for (index.suffixs) |suffix| {
                try w.writeAll(&suffix);
            }
            // refs
            for (index.refs) |ref| {
                try w.writeInt(u64, ref.offset);
                try w.writeInt(u32, ref.size);
            }
            // crc32
            const crc32 = hasher.final();
            try base_writer.writeInt(u32, crc32, .big);
        }

        pub fn writeRoot(self: *Self, root: Hash) !void {
            var w = &self.writer.interface;
            // type (1)
            try w.writeByte(@intFromEnum(JournalRecordType.Root));
            // root hash (20)
            try w.writeAll(&root.bytes);
        }

        pub fn flush(self: *Self) !void {
            try self.writer.flush();
        }
    };
}

const HashRefPair = struct {
    h: Hash,
    ref: ChunkRef,
};

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

        pub fn readIndex(self: *Self) !Index {
            return try Index.initFromReader(self.alloc, &self.reader.interface);
        }

        pub fn skipIndex(self: *Self) !IndexHeader {
            var r = &self.reader.interface;
            const offset = self.reader.logicalPos();
            const recordType: JournalRecordType = @enumFromInt(try r.takeByte());
            if (recordType != .Index) {
                return error.ReadIndexTypeMismatch;
            }
            const count = try r.takeInt(u64, .big);
            const level = try r.takeInt(u32, .big);
            const next = try r.takeInt(u64, .big);
            const toSkip = count * (@sizeOf(Index.Prefix) + @sizeOf(Index.Suffix) + @sizeOf(ChunkRef)) + @sizeOf(u32);

            try self.reader.seekBy(@intCast(toSkip));
            return .{
                .offset = offset,
                .count = count,
                .level = level,
                .next = next,
            };
        }

        fn searchInIndex(self: *Self, h: Hash) !?ChunkRef {
            var r = &self.reader.interface;
            const recordType: JournalRecordType = @enumFromInt(try r.takeByte());
            if (recordType != .Index) {
                return error.SearchIndexTypeMismatch;
            }
            const count = try r.takeInt(u64, .big);
            try self.reader.seekBy(@sizeOf(u64) + @sizeOf(u32));
            // now at start of prefix
            const beginOfPrefix = self.reader.logicalPos();
            const beginOfSuffix = beginOfPrefix + @sizeOf(Index.Prefix) * count;
            const beginOfRefs = beginOfSuffix + @sizeOf(Index.Suffix) * count;

            const candidate = try lowerBound(&self.reader, h.prefix(), beginOfPrefix, 0, count);
            if (!candidate.eql) {
                return null; // prefix not found
            }
            try self.reader.seekTo(beginOfSuffix + @sizeOf(Index.Suffix) * candidate.res);
            var suffix: Index.Suffix = undefined;
            try r.readSliceAll(&suffix);
            if (!h.suffixEqual(suffix)) {
                return null;
            }
            try self.reader.seekTo(beginOfRefs + @sizeOf(ChunkRef) * candidate.res);
            const offset = try r.takeInt(u64, .big);
            const size = try r.takeInt(u32, .big);
            return ChunkRef{
                .offset = offset,
                .size = size,
            };
        }

        // return number of hashes that are still not found in the sortedUniqueHashes
        fn searchManyInIndex(self: *Self, sortedUniqueHashes: std.ArrayList(HashRefPair)) !u64 {
            const IndicesPair = struct { i_index: u64, i_input: u64 };
            var r = &self.reader.interface;
            const recordType: JournalRecordType = @enumFromInt(try r.takeByte());
            if (recordType != .Index) {
                return error.SearchIndexTypeMismatch;
            }
            const count = try r.takeInt(u64, .big);
            try self.reader.seekBy(@sizeOf(u64) + @sizeOf(u32));
            // now at start of prefix
            const beginOfPrefix = self.reader.logicalPos();
            const beginOfSuffix = beginOfPrefix + @sizeOf(Index.Prefix) * count;
            const beginOfRefs = beginOfSuffix + @sizeOf(Index.Suffix) * count;

            var idxAtValidPrefixes = std.ArrayList(IndicesPair).empty;
            defer idxAtValidPrefixes.deinit(self.alloc);
            var i: u64 = 0;
            var i_input: u64 = 0;
            var absent: u64 = 0;
            while (i_input < sortedUniqueHashes.items.len) : (i_input += 1) {
                if (sortedUniqueHashes.items[i_input].ref.isValid()) {
                    // already found from other index, skip
                    continue;
                }
                const h = sortedUniqueHashes.items[i_input].h;
                const up = try looseUpperBound(&self.reader, h.prefix(), beginOfPrefix, i, count);
                const low = i + (up - i) / 2;
                const candidate = try lowerBound(&self.reader, h.prefix(), beginOfPrefix, low, up);
                if (candidate.res != up) {
                    if (candidate.eql) {
                        try idxAtValidPrefixes.append(self.alloc, .{
                            .i_index = candidate.res,
                            .i_input = i_input,
                        });
                        i = candidate.res + 1; // +1 is ok because input hashes are unique
                    } else {
                        // so candidate.res points to some elements greater than h.prefix()
                        absent += 1;
                        i = low; // low will be the safe lower bound for the next hash (> the current hash)
                    }
                } else {
                    // h.prefix() is already larger than all hashes in the index, can break early
                    // but make sure to count the absent number correctly
                    while (i_input < sortedUniqueHashes.items.len) : (i_input += 1) {
                        if (!sortedUniqueHashes.items[i_input].ref.isValid()) {
                            absent += 1;
                        }
                    }
                    break;
                }
            }
            // verify idxAtValidPrefixes in suffix
            var idxAtValidSuffixes = try std.ArrayList(IndicesPair).initCapacity(self.alloc, idxAtValidPrefixes.items.len);
            defer idxAtValidSuffixes.deinit(self.alloc);
            for (idxAtValidPrefixes.items) |ci| {
                var suffixBuf: Index.Suffix = undefined;
                try self.reader.seekTo(beginOfSuffix + @sizeOf(Index.Suffix) * ci.i_index);
                try self.reader.interface.readSliceAll(&suffixBuf);
                if (sortedUniqueHashes.items[ci.i_input].h.suffixEqual(suffixBuf)) {
                    try idxAtValidSuffixes.append(self.alloc, ci);
                } else {
                    absent += 1; // suffix not match, not found
                }
            }
            for (idxAtValidSuffixes.items) |ci| {
                try self.reader.seekTo(beginOfRefs + @sizeOf(ChunkRef) * ci.i_index);
                const offset = try r.takeInt(u64, .big);
                const size = try r.takeInt(u32, .big);
                sortedUniqueHashes.items[ci.i_input].ref = ChunkRef{
                    .offset = offset,
                    .size = size,
                };
            }
            return absent;
        }

        // return some index whose element is greater than v
        // if there is multiple valid results, it can return any of them,
        // and guarentee item[(result+beginIndex)/2] <= v;
        // if not exist, return end
        // do this in log(k-begin)
        fn looseUpperBound(r: *std.Io.File.Reader, v: u64, beginOffset: u64, beginIndex: u64, endIndex: u64) !u64 {
            var i = beginIndex;
            var step: u64 = 1;
            while (i < endIndex) {
                try r.seekTo(beginOffset + i * @sizeOf(u64));
                const cur = try r.interface.peekInt(u64, .big);
                if (cur > v) {
                    return i;
                }
                i += step;
                step *= 2;
            }
            return endIndex;
        }

        // return the first index whose value >= v, if not exist return end
        fn lowerBound(r: *std.Io.File.Reader, v: u64, beginOffset: u64, beginIndex: u64, endIndex: u64) !struct {
            res: u64,
            eql: bool,
        } {
            var i = beginIndex;
            var j = endIndex;
            while (j > i) {
                const step = (j - i) / 2;
                try r.seekTo(beginOffset + (i + step) * @sizeOf(u64));
                const cur = try r.interface.takeInt(u64, .big);
                if (cur < v) {
                    i = i + step + 1;
                } else {
                    j = i + step;
                }
            }
            if (i == endIndex) {
                return .{ .res = i, .eql = false };
            }
            try r.seekTo(beginOffset + i * @sizeOf(u64));
            const u = try r.interface.takeInt(u64, .big);
            return .{ .res = i, .eql = u == v };
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

fn testChunkStore(comptime _: []const u8, store: ChunkStore(testing.io), alloc: std.mem.Allocator) !void {
    // put
    try store.putMove(try Chunk.init(alloc, "data"));
    try store.putMove(try Chunk.init(alloc, "hello"));
    try store.putMove(try Chunk.init(alloc, "world"));
    //commit
    try testing.expect(try store.commit(Hash.of("a"), try store.root()));
    try store.putMove(try Chunk.init(alloc, "pending"));

    // has
    try testing.expect(try store.has(Hash.of("data")));
    try testing.expect(try store.has(Hash.of("hello")));
    try testing.expect(try store.has(Hash.of("world")));
    try testing.expect(try store.has(Hash.of("pending")));
    try testing.expect(!try store.has(Hash.of("notexist")));

    // get
    const data = try store.get(Hash.of("data")) orelse @panic("data is null");
    defer data.deinit(alloc);
    try testing.expect(std.mem.eql(u8, data.getData(), "data"));
    const pending = try store.get(Hash.of("pending")) orelse @panic("data (pending) is null");
    defer pending.deinit(alloc);
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
    defer {
        var it = found.valueIterator();
        while (it.next()) |v| {
            v.deinit(alloc);
        }
        found.deinit();
    }
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
    const current = Hash.of("current");
    try testing.expect(try store.commit(current, try store.root()));
    try testing.expectEqual(current, try store.root());

    // getMany2
    var found2 = HashChunkMap.init(alloc);
    defer {
        var it = found2.valueIterator();
        while (it.next()) |v| {
            v.deinit(alloc);
        }
        found2.deinit();
    }
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
}

test "test memory view chunk store" {
    const io = testing.io;
    const alloc = testing.allocator;
    var storage = MemoryStorage(io).init(alloc);
    defer storage.deinit();
    var view = MemoryStorageView(io).init(alloc, &storage);
    defer view.deinit();
    try testChunkStore("memview", view.asChunkStore(), alloc);
}

test "test journal chunk store" {
    const io = testing.io;
    const alloc = testing.allocator;
    Dir.cwd().deleteTree(io, "tmp/testJournalStore") catch {};
    const tmpJournalPath = "tmp/testJournalStore/test.zjs";
    var store = try JournalStore(io).init(alloc, tmpJournalPath);
    defer Dir.cwd().deleteTree(io, "tmp/testJournalStore") catch {};
    defer store.deinit();

    try testChunkStore("journal", store.asChunkStore(), alloc);
}

test "test journal writer and reader" {
    const io = testing.io;
    const alloc = testing.allocator;
    Dir.cwd().deleteTree(io, "tmp/testJournalWriter") catch {};
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
        try chunkSet.put(c.h, c);
    }
    const NoopCB = struct {
        fn invoke(_: *@This(), _: Hash, _: u64, _: u64) !void {}
    };
    var cb = NoopCB{};
    try w.writeChunks(chunkSet, &cb);
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
    Dir.cwd().deleteTree(io, "tmp/testJournalStore2") catch {};
    const tmpJournalPath = "tmp/testJournalStore2/test.zjs";
    var store = try JournalStore(io).init(alloc, tmpJournalPath);
    defer Dir.cwd().deleteTree(io, "tmp/testJournalStore2") catch {};
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
        try store.putMove(c);
    }

    try testing.expect(try store.commit(Hash.of("a"), try store.root()));

    // test rebase
    var store2 = try JournalStore(io).init(alloc, tmpJournalPath);
    defer store2.deinit();
    try store2.rebase();
}

test "test index init" {
    const alloc = testing.allocator;
    var refs = std.AutoHashMap(Hash, ChunkRef).init(alloc);
    defer refs.deinit();
    try refs.put(try Hash.parse("00100000000000000000000000000003"), .{
        .offset = 0,
        .size = 10,
    });
    try refs.put(try Hash.parse("00200000000000000000000000000002"), .{
        .offset = 10,
        .size = 20,
    });
    try refs.put(try Hash.parse("00300000000000000000000000000001"), .{
        .offset = 30,
        .size = 30,
    });
    const idx = try Index.init(alloc, refs);
    defer idx.deinit();
    try testing.expectEqual(3, idx.count);
    try testing.expectEqual(3, idx.prefixs.len);
    try testing.expectEqual(3, idx.suffixs.len);
    try testing.expectEqual(3, idx.refs.len);
    try testing.expectEqual(0, idx.refs[0].offset);
    try testing.expectEqual(10, idx.refs[0].size);
    try testing.expectEqual(10, idx.refs[1].offset);
    try testing.expectEqual(20, idx.refs[1].size);
    try testing.expectEqual(30, idx.refs[2].offset);
    try testing.expectEqual(30, idx.refs[2].size);
    try testing.expectEqual(0x3, idx.suffixs[0][11]);
    try testing.expectEqual(0x2, idx.suffixs[1][11]);
    try testing.expectEqual(0x1, idx.suffixs[2][11]);
}

test "index read/write" {
    const alloc = testing.allocator;
    const io = testing.io;
    var refs = std.AutoHashMap(Hash, ChunkRef).init(alloc);
    defer refs.deinit();
    try refs.put(try Hash.parse("00100000000000000000000000000003"), .{
        .offset = 0,
        .size = 10,
    });
    try refs.put(try Hash.parse("00200000000000000000000000000002"), .{
        .offset = 10,
        .size = 20,
    });
    try refs.put(try Hash.parse("00300000000000000000000000000001"), .{
        .offset = 30,
        .size = 30,
    });
    const idx = try Index.init(alloc, refs);
    defer idx.deinit();
    Dir.cwd().deleteTree(io, "tmp/testIndexSerialize") catch {};
    const tmpJournalPath = "tmp/testIndexSerialize/test.zjs";
    const journal = try openOrCreateFile(io, tmpJournalPath, .{ .allowWrite = true });
    defer Dir.cwd().deleteTree(io, "tmp/testIndexSerialize") catch {};
    var w = try JournalWriter(io).init(alloc, journal);
    defer w.deinit();
    try w.writeIndex(idx);
    try w.flush();
    var r = try JournalReader(io).init(alloc, journal);
    defer r.deinit();
    const readIdx = try r.readIndex();
    defer readIdx.deinit();
    try testing.expectEqualDeep(idx, readIdx);

    var r2 = try JournalReader(io).init(alloc, journal);
    defer r2.deinit();
    const idxHeader = try r2.skipIndex();
    try testing.expectEqual(3, idxHeader.count);
    try testing.expectEqual(0, idxHeader.level);
    try testing.expectEqual(0, idxHeader.next);

    try r2.reader.seekTo(0);
}

// todo: add test that will trigger auto pending flush and index write.
// and then test with get/getMany/has/hasMany
