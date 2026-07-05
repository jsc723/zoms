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
    const DiskSize = @sizeOf(u64) + @sizeOf(u32);
    const empty = ChunkRef{ .offset = 0, .size = 0 };
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
        config: Config,

        rootHash: Hash,
        pendingSize: u64,
        pending: HashChunkMap, // in memory not committed chunks
        journaledChunks: std.AutoHashMap(Hash, ChunkRef), // commited chunks (but not indexed)
        indexHeaders: std.ArrayList(IndexHeader), // indexes

        const Self = @This();
        const Config = struct {
            MaxJournaledChunksCount: u32 = 1000,
            MaxPendingSizeInByte: u64 = 1 << 20, // 1mb
            MaxPendingChunks: u32 = 250, // ~1mb
            IndexBranchingFactor: u32 = 10, // 10 level-N index will be merged into a level-N+1 index
        };

        pub fn init(alloc: std.mem.Allocator, journalPath: []const u8, config: Config) !Self {
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
                .config = config,
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
            var absent = remaining.items.len;
            while (i > 0) {
                i -= 1;
                const header = self.indexHeaders.items[i];
                try r.seekTo(header.offset);
                const found = try self.journalReader.searchManyInIndex(remaining);
                absent -= found;
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
                const found = try self.journalReader.searchManyInIndex(remaining);
                absent -= found;
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
                chunk.deinit(self.alloc);
                return;
            }
            try self.pending.put(chunk.h, chunk);
            self.pendingSize += chunk.data.len;
            if (self.pendingSize >= self.config.MaxPendingSizeInByte or self.pending.count() >= self.config.MaxPendingChunks) {
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
                    if (idxHeader.next != 0) {
                        try self.journalReader.reader.seekTo(idxHeader.next);
                    }
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
            // write chunks
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

            try self.journalWriter.writeChunksNoFlush(self.pending, &cb);
            try self.journalWriter.writer.flush();
            self.clearPending();

            // write index
            if (self.journaledChunks.count() >= self.config.MaxJournaledChunksCount) {
                const idx = try Index.init(self.alloc, self.journaledChunks);
                defer idx.deinit();
                const idxOffset = self.journalWriter.writer.logicalPos();
                try self.journalWriter.writeIndex(idx);
                try self.journalWriter.writer.flush();
                try self.indexHeaders.append(self.alloc, .{
                    .offset = idxOffset,
                    .count = idx.count,
                    .level = idx.level,
                    .next = idx.next,
                });
                self.journaledChunks.clearAndFree();
            }

            // merge index
            var count = mergableIndices(self.indexHeaders, self.config.IndexBranchingFactor);
            while (count > 0) {
                const end = self.indexHeaders.items.len;
                const begin = end - count;
                std.debug.assert(begin > 0); // because there is an empty index at begin whose level is super large
                const toMerge = self.indexHeaders.items[begin..end];
                const level = toMerge[0].level;
                if (level > Index.MaxMergableLevelInMemory) {
                    // TODO: should do an on-disk index merge, but leave that work to future for now.
                    // currently, just do not continue to merge, so number of index at MaxMergableLevelInMemory will grow linearly from here.
                    break;
                }
                // in memory merging
                const indices = try self.alloc.alloc(Index, count);
                defer self.alloc.free(indices);
                var readIndexCount: usize = 0;
                for (0..count) |j| {
                    try self.journalReader.reader.seekTo(toMerge[j].offset);
                    indices[j] = try Index.initFromReader(self.alloc, &self.journalReader.reader.interface);
                    readIndexCount += 1;
                }
                defer {
                    for (0..readIndexCount) |i| {
                        indices[i].deinit();
                    }
                }

                const merged = try mergeIndexInMemory(self.alloc, indices);
                defer merged.deinit();
                const startOfMerged = try self.journal.length(io);
                try self.indexHeaders.resize(self.alloc, begin + 1); // + 1for the merged header
                // replace the it with the merged header
                self.indexHeaders.items[begin] = IndexHeader{
                    .offset = startOfMerged,
                    .count = merged.count,
                    .level = merged.level,
                    .next = merged.next,
                };
                // update the prev's header's next field to point to the merged index
                self.indexHeaders.items[begin - 1].next = startOfMerged;
                try self.journalWriter.updateIndexHeader(self.indexHeaders.items[begin - 1], &self.journalReader.reader);
                try self.journalWriter.writeIndex(merged);

                count = mergableIndices(self.indexHeaders, self.config.IndexBranchingFactor);
            }
        }

        fn mergableIndices(indexHeaders: std.ArrayList(IndexHeader), factor: u32) u64 {
            std.debug.assert(indexHeaders.items.len > 0);

            const minLevel = indexHeaders.items[indexHeaders.items.len - 1].level;
            var count: u64 = 0;
            var i = indexHeaders.items.len;
            while (i > 0) {
                i -= 1;
                if (indexHeaders.items[i].level == minLevel) {
                    count += 1;
                } else {
                    break;
                }
            }
            if (count >= factor) {
                return count;
            }
            return 0;
        }

        fn mergeIndexInMemory(alloc: std.mem.Allocator, indices: []Index) !Index {
            var pairs = std.ArrayList(HashRefPair).empty;
            defer pairs.deinit(alloc);
            var maxLevel: u32 = 0;
            for (indices) |*idx| {
                maxLevel = @max(maxLevel, idx.level);
                var iter = idx.iterator();
                while (iter.next()) |item| {
                    try pairs.append(alloc, item);
                }
            }
            std.mem.sortUnstable(HashRefPair, pairs.items, {}, struct {
                fn less(_: void, a: HashRefPair, b: HashRefPair) bool {
                    return a.h.compare(b.h) == .lt;
                }
            }.less);
            return Index.initFromSorted(alloc, pairs.items, maxLevel + 1);
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

            try self.journalWriter.writeRootNoFlush(current);
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

// level         chunk_count        data_size        index_size(in memory)
// 0             1,000              4MB              36K
// 1             10,000             40MB             360K
// 2             100,000            400MB            3.6MB
// 3             1,000,000          4GB              36MB
// 4             10,000,000         40GB             360MB (merging 10 level-4 requires 7.2G in total, probably not want to do it)
// 5             100,000,000        400GB            3.6GB (starting from level-5, they have to be merged on disk)
// and so on
const Index = struct {
    const Prefix = u64;
    const PrefixSize = @sizeOf(u64);
    const Suffix = [12]u8;
    const SuffixSize = 12 * @sizeOf(u8);
    const MaxMergableLevelInMemory = 3; // see the reason above. this means in-memory merge should work until data size gets to ~40GB
    count: u64,
    level: u32,
    next: u64,
    prefixs: []Prefix,
    suffixs: []Suffix,
    refs: []ChunkRef,
    alloc: std.mem.Allocator,

    // init an level-0 index from chunk refs
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
        return Index.initFromSorted(alloc, pairs, 0);
    }

    pub fn initFromSorted(alloc: std.mem.Allocator, sorted: []HashRefPair, level: u32) !Index {
        const count = sorted.len;
        var prefixs = try alloc.alloc(u64, count);
        errdefer alloc.free(prefixs);
        var suffixs = try alloc.alloc(Suffix, count);
        errdefer alloc.free(suffixs);
        var refs = try alloc.alloc(ChunkRef, count);
        errdefer alloc.free(refs);
        var i: usize = 0;
        while (i < sorted.len) : (i += 1) {
            prefixs[i] = sorted[i].h.prefix();
            suffixs[i] = sorted[i].h.suffix();
            refs[i] = sorted[i].ref;
        }
        return Index{
            .count = count,
            .level = level,
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
        // header_crc
        const header_crc = hasher.final();
        const read_header_crc = try reader.takeInt(u32, .big);
        if (header_crc != read_header_crc) {
            return error.HeaderCrc32NotMatch;
        }

        hasher = .init();
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

    pub fn hashAt(self: Index, i: u64) Hash {
        var h = Hash.Empty;
        const pre = self.prefixs[i];
        const suf = self.suffixs[i];
        std.mem.writeInt(u64, h.bytes[0..8], pre, .big);
        std.mem.copyForwards(u8, h.bytes[8..], &suf);
        return h;
    }

    pub fn iterator(self: *Index) Iterator {
        return Iterator{
            .i = 0,
            .idx = self,
        };
    }

    const Iterator = struct {
        i: u64,
        idx: *Index,
        pub fn next(self: *Iterator) ?HashRefPair {
            if (self.i < self.idx.count) {
                const res = HashRefPair{
                    .h = self.idx.hashAt(self.i),
                    .ref = self.idx.refs[self.i],
                };
                self.i += 1;
                return res;
            }
            return null;
        }
    };
};

const JournalRecordType = enum { Chunks, Index, Root };

fn JournalWriter(comptime io: std.Io) type {
    return struct {
        const Self = @This();
        writer: std.Io.File.Writer, // writer should always points to the end of the file after each write
        alloc: std.mem.Allocator,
        buffer: []u8,

        pub fn init(alloc: std.mem.Allocator, file: std.Io.File) !Self {
            const buffer = try alloc.alloc(u8, 4096);
            var writer = file.writer(io, buffer);
            try writer.seekTo(try file.length(io));
            return .{
                .writer = writer,
                .alloc = alloc,
                .buffer = buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.buffer);
        }

        pub fn writeChunksNoFlush(self: *Self, chunkSets: HashChunkMap, onChunkWritten: anytype) !void {
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

        pub fn updateIndexHeader(self: *Self, header: IndexHeader, r: *std.Io.File.Reader) !void {
            const base_writer = &self.writer.interface;
            const curPos = self.writer.logicalPos();
            try self.writer.seekTo(header.offset);
            try r.seekTo(header.offset);
            var hasher = std.hash.Crc32.init();
            var w = WriterContext{ .bw = base_writer, .hasher = &hasher };
            const recordType: JournalRecordType = @enumFromInt(try r.interface.takeByte());
            if (recordType != .Index) {
                return error.ReadIndexTypeMismatch;
            }
            // count
            const count = try r.interface.takeInt(u64, .big);
            // level
            const level = try r.interface.takeInt(u32, .big);
            if (count != header.count) {
                return error.CountNotMatch;
            }
            if (level != header.level) {
                return error.LevelNotMatch;
            }
            // type (1)
            try w.writeByte(@intFromEnum(JournalRecordType.Index));
            // count (8)
            try w.writeInt(u64, header.count);
            // level (4)
            try w.writeInt(u32, header.level);
            // next (8)
            try w.writeInt(u64, header.next);
            // header crc (4)
            const header_crc32 = hasher.final();
            try base_writer.writeInt(u32, header_crc32, .big);
            try self.writer.flush();
            try self.writer.seekTo(curPos);
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
            var w = WriterContext{ .bw = base_writer, .hasher = &hasher };

            // type (1)
            try w.writeByte(@intFromEnum(JournalRecordType.Index));
            // count (8)
            try w.writeInt(u64, index.count);
            // level (4)
            try w.writeInt(u32, index.level);
            // next (8)
            try w.writeInt(u64, index.next);
            // header crc (4)
            const header_crc32 = hasher.final();
            try base_writer.writeInt(u32, header_crc32, .big);
            hasher = .init();
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
            // write index without a flush almost always results a bug
            try self.writer.flush();
        }

        pub fn writeRootNoFlush(self: *Self, root: Hash) !void {
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

            for (0..chunkCount) |_| {
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
            _ = try r.takeInt(u32, .big);
            const toSkip = count * (Index.PrefixSize + Index.SuffixSize + ChunkRef.DiskSize) + @sizeOf(u32);

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
            try self.reader.seekBy(@sizeOf(u64) + @sizeOf(u32) + @sizeOf(u32));
            // now at start of prefix
            const beginOfPrefix = self.reader.logicalPos();
            const beginOfSuffix = beginOfPrefix + Index.PrefixSize * count;
            const beginOfRefs = beginOfSuffix + Index.SuffixSize * count;

            const res = try lowerBound(&self.reader, h.prefix(), beginOfPrefix, 0, count);
            if (res == count) {
                return null; // prefix not found
            }
            const eqlCount = try countEql(&self.reader, h.prefix(), beginOfPrefix, res, count);
            try self.reader.seekTo(beginOfSuffix + Index.SuffixSize * res);
            var suffix: Index.Suffix = undefined;
            for (0..eqlCount) |_| {
                try r.readSliceAll(&suffix);
                if (h.suffixEqual(suffix)) {
                    try self.reader.seekTo(beginOfRefs + ChunkRef.DiskSize * res);
                    const offset = try r.takeInt(u64, .big);
                    const size = try r.takeInt(u32, .big);
                    return ChunkRef{
                        .offset = offset,
                        .size = size,
                    };
                }
            }
            return null;
        }

        // return number of hashes that are newly found in this index
        fn searchManyInIndex(self: *Self, sortedUniqueHashes: std.ArrayList(HashRefPair)) !u64 {
            const CheckRange = struct { i_index: u64, count: u64, i_input: u64 };
            const CheckedIndex = struct { i_index: u64, i_input: u64 };
            var r = &self.reader.interface;
            const recordType: JournalRecordType = @enumFromInt(try r.takeByte());
            if (recordType != .Index) {
                return error.SearchIndexTypeMismatch;
            }
            const count = try r.takeInt(u64, .big);
            try self.reader.seekBy(@sizeOf(u64) + 2 * @sizeOf(u32));
            // now at start of prefix
            const beginOfPrefix = self.reader.logicalPos();
            const beginOfSuffix = beginOfPrefix + Index.PrefixSize * count;
            const beginOfRefs = beginOfSuffix + Index.SuffixSize * count;

            var suffixRangeToCheck = std.ArrayList(CheckRange).empty;
            defer suffixRangeToCheck.deinit(self.alloc);
            var i: u64 = 0;
            for (0..sortedUniqueHashes.items.len) |i_input| {
                if (sortedUniqueHashes.items[i_input].ref.isValid()) {
                    // already found from other index, skip
                    continue;
                }
                const h = sortedUniqueHashes.items[i_input].h;

                const lub = try looseUpperBound(&self.reader, h.prefix(), beginOfPrefix, i, count);
                const res = try lowerBound(&self.reader, h.prefix(), beginOfPrefix, lub.last, lub.up);
                if (res == count) {
                    // there is no index who is >= currrent hash, therefore all hashes after this one can be skiped
                    break;
                }
                // res points at the first element >= h.prefix()
                const eqCount = try countEql(&self.reader, h.prefix(), beginOfPrefix, res, count);
                if (eqCount > 0) {
                    try suffixRangeToCheck.append(self.alloc, .{
                        .i_index = res,
                        .count = eqCount,
                        .i_input = i_input,
                    });
                }
                i = res; // because res is the first place whose value >= current input hash prefix
            }
            // verify idxAtValidPrefixes in suffix
            var idxAtValidSuffixes = try std.ArrayList(CheckedIndex).initCapacity(self.alloc, suffixRangeToCheck.items.len);
            defer idxAtValidSuffixes.deinit(self.alloc);
            for (suffixRangeToCheck.items) |cr| {
                var suffixBuf: Index.Suffix = undefined;
                try self.reader.seekTo(beginOfSuffix + Index.SuffixSize * cr.i_index);
                for (0..cr.count) |_| {
                    try self.reader.interface.readSliceAll(&suffixBuf);
                    if (sortedUniqueHashes.items[cr.i_input].h.suffixEqual(suffixBuf)) {
                        try idxAtValidSuffixes.append(self.alloc, .{
                            .i_index = cr.i_index,
                            .i_input = cr.i_input,
                        });
                        break;
                    }
                }
            }
            for (idxAtValidSuffixes.items) |ci| {
                try self.reader.seekTo(beginOfRefs + ChunkRef.DiskSize * ci.i_index);
                const offset = try r.takeInt(u64, .big);
                const size = try r.takeInt(u32, .big);
                sortedUniqueHashes.items[ci.i_input].ref = ChunkRef{
                    .offset = offset,
                    .size = size,
                };
            }
            return idxAtValidSuffixes.items.len;
        }

        // return some index whose element >= v
        // if there is multiple valid results, it can return any of them,
        // if not exist, return end and last (if not equal to end, then it is guarenteed that items[last] < v)
        // do this in log(k-begin)
        fn looseUpperBound(r: *std.Io.File.Reader, v: u64, beginOffset: u64, beginIndex: u64, endIndex: u64) !struct {
            up: u64,
            last: u64,
        } {
            var i = beginIndex;
            var step: u64 = 1;
            var last = i;
            while (i < endIndex) {
                try r.seekTo(beginOffset + i * @sizeOf(u64));
                const cur = try r.interface.takeInt(u64, .big);
                if (cur >= v) {
                    return .{ .up = i, .last = last };
                }
                last = i; // cur < v
                i += step;
                step *= 2;
            }
            return .{ .up = endIndex, .last = last };
        }

        // return the first index whose value >= v, if not exist return end
        fn lowerBound(r: *std.Io.File.Reader, v: u64, beginOffset: u64, beginIndex: u64, endIndex: u64) !u64 {
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
                return endIndex;
            }
            return i;
        }

        // start from startIdx, count num of elements that is equal to v until not equal or out of range
        fn countEql(r: *std.Io.File.Reader, v: u64, beginOffset: u64, beginIndex: u64, endIndex: u64) !u64 {
            try r.seekTo(beginOffset + beginIndex * @sizeOf(u64));
            var i = beginIndex;
            while (i < endIndex) {
                const u = try r.interface.takeInt(u64, .big);
                if (u != v) {
                    break;
                }
                i += 1; // find an equal item, continue
            }
            return i - beginIndex;
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
    var store = try JournalStore(io).init(alloc, tmpJournalPath, .{});
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
    try w.writeChunksNoFlush(chunkSet, &cb);
    try w.writeRootNoFlush(Hash.of("a"));
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
    var store = try JournalStore(io).init(alloc, tmpJournalPath, .{});
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
        try store.putMove(c); // put twice to test memory leak
    }

    try testing.expect(try store.commit(Hash.of("a"), try store.root()));

    // test rebase
    var store2 = try JournalStore(io).init(alloc, tmpJournalPath, .{});
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

    const h1 = try Hash.parse("00100000000000000000000000000003");
    const h11 = try Hash.parse("00100000000000000000000000000004");
    const h2 = try Hash.parse("00200000000000000000000000000002");
    const h21 = try Hash.parse("00200000000000000000000000000003");
    const h22 = try Hash.parse("00200000000000000000000000000004");
    const h3 = try Hash.parse("00300000000000000000000000000001");
    const hNotExist = try Hash.parse("00400000000000000000000000000000");

    try refs.put(h1, .{
        .offset = 0,
        .size = 10,
    });
    try refs.put(h11, .{
        .offset = 0,
        .size = 10,
    });
    try refs.put(h2, .{
        .offset = 10,
        .size = 20,
    });
    try refs.put(h21, .{
        .offset = 10,
        .size = 20,
    });
    try refs.put(h22, .{
        .offset = 10,
        .size = 20,
    });
    try refs.put(h3, .{
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
    var r_test = try JournalReader(io).init(alloc, journal);
    defer r_test.deinit();
    const readIdx = try r_test.readIndex();
    defer readIdx.deinit();
    try testing.expectEqualDeep(idx, readIdx);

    var r = try JournalReader(io).init(alloc, journal);
    defer r.deinit();
    const idxHeader = try r.skipIndex();
    try testing.expectEqual(refs.count(), idxHeader.count);
    try testing.expectEqual(0, idxHeader.level);
    try testing.expectEqual(0, idxHeader.next);

    try r.reader.seekTo(0);

    // search for existing hashes
    var iter = refs.iterator();
    while (iter.next()) |e| {
        try r.reader.seekTo(0);
        const ref = try r.searchInIndex(e.key_ptr.*);
        try testing.expect(ref != null);
        try testing.expectEqual(e.value_ptr.offset, ref.?.offset);
        try testing.expectEqual(e.value_ptr.size, ref.?.size);
    }

    // search for non-existing hash
    try r.reader.seekTo(0);
    const refNotExist = try r.searchInIndex(hNotExist);
    try testing.expectEqual(null, refNotExist);

    // search for hash smaller than all entries
    const hSmall = try Hash.parse("00000000000000000000000000000000");
    try r.reader.seekTo(0);
    const refSmall = try r.searchInIndex(hSmall);
    try testing.expectEqual(null, refSmall);

    // search for hash between existing entries
    const hBetween = try Hash.parse("00150000000000000000000000000000");
    try r.reader.seekTo(0);
    const refBetween = try r.searchInIndex(hBetween);
    try testing.expectEqual(null, refBetween);

    // test searchManyInIndex
    var searchPairs = std.ArrayList(HashRefPair).empty;
    defer searchPairs.deinit(alloc);

    {
        // search for 3 existing hashes (first in duplicate prefix) + 1 non-existing, sorted by hash
        defer searchPairs.clearAndFree(alloc);
        try searchPairs.append(alloc, .{ .h = h1, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h2, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h3, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = hNotExist, .ref = ChunkRef.empty });

        try r.reader.seekTo(0);
        const found = try r.searchManyInIndex(searchPairs);
        try testing.expectEqual(3, found); // only hNotExist is absent
        try testing.expectEqual(0, searchPairs.items[0].ref.offset);
        try testing.expectEqual(10, searchPairs.items[0].ref.size);
        try testing.expectEqual(10, searchPairs.items[1].ref.offset);
        try testing.expectEqual(20, searchPairs.items[1].ref.size);
        try testing.expectEqual(30, searchPairs.items[2].ref.offset);
        try testing.expectEqual(30, searchPairs.items[2].ref.size);
        try testing.expect(!searchPairs.items[3].ref.isValid()); // hNotExist not found
    }

    {
        defer searchPairs.clearAndFree(alloc);
        // search for existing hashes (may not be the first in duplicated prefix) + 1 non-existing, sorted by hash
        try searchPairs.append(alloc, .{ .h = h11, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h2, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h21, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h3, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = hNotExist, .ref = ChunkRef.empty });

        try r.reader.seekTo(0);
        const found = try r.searchManyInIndex(searchPairs);
        try testing.expectEqual(4, found); // only hNotExist is absent
        try testing.expectEqual(0, searchPairs.items[0].ref.offset);
        try testing.expectEqual(10, searchPairs.items[0].ref.size);
        try testing.expectEqual(10, searchPairs.items[1].ref.offset);
        try testing.expectEqual(20, searchPairs.items[1].ref.size);
        try testing.expectEqual(10, searchPairs.items[2].ref.offset);
        try testing.expectEqual(20, searchPairs.items[2].ref.size);
        try testing.expectEqual(30, searchPairs.items[3].ref.offset);
        try testing.expectEqual(30, searchPairs.items[3].ref.size);
        try testing.expect(!searchPairs.items[4].ref.isValid()); // hNotExist not found
    }

    {
        defer searchPairs.clearAndFree(alloc);
        // search all
        try searchPairs.append(alloc, .{ .h = h1, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h11, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h2, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h21, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h22, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h3, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = hNotExist, .ref = ChunkRef.empty });

        try r.reader.seekTo(0);
        const found = try r.searchManyInIndex(searchPairs);
        try testing.expectEqual(6, found); // only hNotExist is absent
        for (0..2) |i| {
            try testing.expectEqual(0, searchPairs.items[i].ref.offset);
            try testing.expectEqual(10, searchPairs.items[i].ref.size);
        }
        for (2..5) |i| {
            try testing.expectEqual(10, searchPairs.items[i].ref.offset);
            try testing.expectEqual(20, searchPairs.items[i].ref.size);
        }
        for (5..6) |i| {
            try testing.expectEqual(30, searchPairs.items[i].ref.offset);
            try testing.expectEqual(30, searchPairs.items[i].ref.size);
        }
        try testing.expect(!searchPairs.items[6].ref.isValid()); // hNotExist not found
    }

    { // search for only non-existing hashes
        defer searchPairs.clearAndFree(alloc);
        try searchPairs.append(alloc, .{ .h = hSmall, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = hNotExist, .ref = ChunkRef.empty });

        try r.reader.seekTo(0);
        const found2 = try r.searchManyInIndex(searchPairs);
        try testing.expectEqual(0, found2);
        try testing.expect(!searchPairs.items[0].ref.isValid());
        try testing.expect(!searchPairs.items[1].ref.isValid());
    }

    // search for only h1 and h3, skipping h2
    {
        defer searchPairs.clearAndFree(alloc);
        try searchPairs.append(alloc, .{ .h = h1, .ref = ChunkRef.empty });
        try searchPairs.append(alloc, .{ .h = h3, .ref = ChunkRef.empty });

        try r.reader.seekTo(0);
        const found3 = try r.searchManyInIndex(searchPairs);
        try testing.expectEqual(2, found3);
        try testing.expectEqual(0, searchPairs.items[0].ref.offset);
        try testing.expectEqual(10, searchPairs.items[0].ref.size);
        try testing.expectEqual(30, searchPairs.items[1].ref.offset);
        try testing.expectEqual(30, searchPairs.items[1].ref.size);
    }

    {
        defer searchPairs.clearAndFree(alloc);
        // test with already-found entries (ref.isValid() == true) mixed in
        // h1 already found (valid ref), h2 not found, h3 already found
        try searchPairs.append(alloc, .{ .h = h1, .ref = ChunkRef{ .offset = 0, .size = 10 } }); // already valid
        try searchPairs.append(alloc, .{ .h = h2, .ref = ChunkRef{ .offset = 0, .size = 0 } }); // not found
        try searchPairs.append(alloc, .{ .h = h3, .ref = ChunkRef{ .offset = 30, .size = 30 } }); // already valid

        try r.reader.seekTo(0);
        const found4 = try r.searchManyInIndex(searchPairs);
        try testing.expectEqual(1, found4); // h2 should be found
        try testing.expectEqual(10, searchPairs.items[1].ref.offset); // h2 found
        try testing.expectEqual(20, searchPairs.items[1].ref.size);
    }
}

// a test that will trigger auto pending flush and index write.
// and then test with get/getMany/has/hasMany
test "test everything in JournalStore" {
    const alloc = testing.allocator;
    const io = testing.io;
    const tStart = std.Io.Timestamp.now(io, .real);
    var cs = std.AutoHashMap(Hash, Chunk).init(alloc);
    defer {
        var iter = cs.valueIterator();
        while (iter.next()) |pchunk| {
            pchunk.deinit(alloc);
        }
        cs.deinit();
    }

    Dir.cwd().deleteTree(io, "tmp/testJournalStoreAll") catch {};
    const tmpJournalPath = "tmp/testJournalStoreAll/test.zjs";
    var store = try JournalStore(io).init(alloc, tmpJournalPath, .{
        .MaxPendingChunks = 25,
        .MaxJournaledChunksCount = 100,
    });
    defer Dir.cwd().deleteTree(io, "tmp/testJournalStoreAll") catch {};
    defer store.deinit();

    var i: u64 = 0;
    const totalChunks = 23666;
    while (i < totalChunks) : (i += 1) {
        var data: []u8 = undefined;
        if (i % 3 == 0) {
            data = try std.fmt.allocPrint(alloc, "data={d}", .{i});
        } else if (i % 3 == 1) {
            data = try std.fmt.allocPrint(alloc, "<data>{d:09}</data> ", .{i});
        } else if (i % 3 == 2) {
            data = try std.fmt.allocPrint(alloc, "[ \"data\": {d} ]", .{i});
        }
        try cs.put(Hash.of(data), try Chunk.init(alloc, data));
        try store.putMove(Chunk.moveInit(data));
    }

    const tWrite = std.Io.Timestamp.now(io, .real);
    std.debug.print("[perf] build: {d}ms\n", .{tStart.durationTo(tWrite).toMilliseconds()});

    // for (store.indexHeaders.items) |header| {
    //     std.debug.print("[debug] level={d}, count={d}\n", .{ header.level, header.count });
    // }
    try testing.expectEqual(1 + 2 + 3 + 6, store.indexHeaders.items.len); // 2 level-2, 3 level-1, 6 level-0
    // try testing.expectEqual(500, store.journaledChunks.count());
    // try testing.expectEqual(166, store.pending.count());

    const NotExist = Hash.of("not exist");
    const AlsoNotExist = Hash.of("also not exist");
    // has
    {
        const tHasStart = std.Io.Timestamp.now(io, .real);
        var iter = cs.iterator();
        var count: usize = 0;
        while (iter.next()) |e| {
            try testing.expect(try store.has(e.key_ptr.*));
            count += 1;
            if (count == 1000) break;
        }
        try testing.expect(!try store.has(NotExist));
        const tHasEnd = std.Io.Timestamp.now(io, .real);
        std.debug.print("[perf] has: {d}ms\n", .{tHasStart.durationTo(tHasEnd).toMilliseconds()});
    }

    // get
    {
        const tGetStart = std.Io.Timestamp.now(io, .real);
        var iter = cs.iterator();
        var count: usize = 0;
        while (iter.next()) |e| {
            const chunk = try store.get(e.key_ptr.*);
            try testing.expect(chunk != null);
            defer chunk.?.deinit(alloc);
            try testing.expectEqualSlices(u8, e.value_ptr.*.data, chunk.?.data);
            count += 1;
            if (count == 1000) break;
        }
        const tGetEnd = std.Io.Timestamp.now(io, .real);
        std.debug.print("[perf] get: {d}ms\n", .{tGetStart.durationTo(tGetEnd).toMilliseconds()});
    }

    // hasMany
    var checkSet = HashSet.init(alloc);
    defer checkSet.deinit();
    var iter = cs.iterator();
    var count: usize = 0;
    while (iter.next()) |e| {
        if (count >= 100) break;
        try checkSet.put(e.key_ptr.*, {});
        count += 1;
    }
    try checkSet.put(NotExist, {});
    try checkSet.put(AlsoNotExist, {});

    {
        const tHasManyStart = std.Io.Timestamp.now(io, .real);
        var absentInvoked: u32 = 0;
        var absentHashes = HashSet.init(alloc);
        defer absentHashes.deinit();
        var onAbsent = struct {
            pCount: *u32,
            pHashes: *HashSet,
            fn invoke(self: *@This(), h: Hash) !void {
                self.pCount.* += 1;
                try self.pHashes.put(h, {});
            }
        }{ .pCount = &absentInvoked, .pHashes = &absentHashes };

        const absentCount = try store.hasMany(&checkSet, &onAbsent);
        try testing.expectEqual(2, absentCount);
        try testing.expectEqual(2, absentInvoked);
        try testing.expect(absentHashes.contains(NotExist));
        try testing.expect(absentHashes.contains(AlsoNotExist));
        const tHasManyEnd = std.Io.Timestamp.now(io, .real);
        std.debug.print("[perf] hasMany: {d}ms\n", .{tHasManyStart.durationTo(tHasManyEnd).toMilliseconds()});
    }

    // getMany
    {
        const tGetManyStart = std.Io.Timestamp.now(io, .real);
        var foundChunks = std.AutoHashMap(Hash, Chunk).init(alloc);
        defer {
            var fit = foundChunks.valueIterator();
            while (fit.next()) |pchunk| {
                pchunk.deinit(alloc);
            }
            foundChunks.deinit();
        }
        var onFound = struct {
            pFound: *std.AutoHashMap(Hash, Chunk),
            fn invoke(self: *@This(), chunk: Chunk) !void {
                try self.pFound.put(chunk.getHash(), chunk);
            }
        }{ .pFound = &foundChunks };

        try store.getMany(&checkSet, &onFound);

        const tGetManyEnd = std.Io.Timestamp.now(io, .real);
        std.debug.print("[perf] getMany: {d}ms\n", .{tGetManyStart.durationTo(tGetManyEnd).toMilliseconds()});

        // should find all 100 existing chunks, not the 2 non-existing ones
        try testing.expectEqual(100, foundChunks.count());

        // verify each found chunk has correct data
        var fit = foundChunks.iterator();
        while (fit.next()) |e| {
            const expected = cs.get(e.key_ptr.*);
            try testing.expect(expected != null);
            try testing.expectEqualSlices(u8, expected.?.data, e.value_ptr.*.data);
        }
    }

    // getMany finds all
    {
        var allHashes = HashSet.init(alloc);
        defer allHashes.deinit();
        iter = cs.iterator();
        while (iter.next()) |e| {
            try allHashes.put(e.key_ptr.*, {});
        }
        var foundChunks = std.AutoHashMap(Hash, Chunk).init(alloc);
        defer {
            var fit = foundChunks.valueIterator();
            while (fit.next()) |pchunk| {
                pchunk.deinit(alloc);
            }
            foundChunks.deinit();
        }
        var onFound = struct {
            pFound: *std.AutoHashMap(Hash, Chunk),
            fn invoke(self: *@This(), chunk: Chunk) !void {
                try self.pFound.put(chunk.getHash(), chunk);
            }
        }{ .pFound = &foundChunks };

        const tGetManyStart = std.Io.Timestamp.now(io, .real);

        try store.getMany(&allHashes, &onFound);

        const tGetManyEnd = std.Io.Timestamp.now(io, .real);
        std.debug.print("[perf] getMany all: {d}ms\n", .{tGetManyStart.durationTo(tGetManyEnd).toMilliseconds()});

        // should find all chunks in cs
        try testing.expectEqual(cs.count(), foundChunks.count());

        // verify each found chunk has correct data
        var fit = foundChunks.iterator();
        while (fit.next()) |e| {
            const expected = cs.get(e.key_ptr.*);
            try testing.expect(expected != null);
            try testing.expectEqualSlices(u8, expected.?.data, e.value_ptr.*.data);
        }
    }

    // getMany with all non-existing keys
    {
        var emptySet = HashSet.init(alloc);
        defer emptySet.deinit();
        try emptySet.put(NotExist, {});
        try emptySet.put(AlsoNotExist, {});

        var foundChunks = std.AutoHashMap(Hash, Chunk).init(alloc);
        defer foundChunks.deinit();
        var onFound2 = struct {
            pFound: *std.AutoHashMap(Hash, Chunk),
            fn invoke(self: *@This(), chunk: Chunk) !void {
                try self.pFound.put(chunk.getHash(), chunk);
            }
        }{ .pFound = &foundChunks };
        try store.getMany(&emptySet, &onFound2);
        try testing.expectEqual(0, foundChunks.count());
    }

    // getMany with mix of existing and non-existing
    {
        var mixSet = HashSet.init(alloc);
        defer mixSet.deinit();
        iter = cs.iterator();
        count = 0;
        while (iter.next()) |e| {
            if (count >= 50) break;
            try mixSet.put(e.key_ptr.*, {});
            count += 1;
        }
        try mixSet.put(NotExist, {});

        var foundChunks = std.AutoHashMap(Hash, Chunk).init(alloc);
        defer {
            var fit3 = foundChunks.valueIterator();
            while (fit3.next()) |pchunk| {
                pchunk.deinit(alloc);
            }
            foundChunks.deinit();
        }
        var onFound3 = struct {
            pFound: *std.AutoHashMap(Hash, Chunk),
            fn invoke(self: *@This(), chunk: Chunk) !void {
                try self.pFound.put(chunk.getHash(), chunk);
            }
        }{ .pFound = &foundChunks };
        try store.getMany(&mixSet, &onFound3);
        try testing.expectEqual(50, foundChunks.count());
    }

    {
        // test rebase from a store with multi level of index
        var store2 = try JournalStore(io).init(alloc, tmpJournalPath, .{
            .MaxPendingChunks = 25,
            .MaxJournaledChunksCount = 100,
        });
        defer store2.deinit();

        try testing.expectEqual(store.indexHeaders.items.len, store2.indexHeaders.items.len);

        // test getMany on a loaded index
        const tGetManyStart = std.Io.Timestamp.now(io, .real);
        var foundChunks = std.AutoHashMap(Hash, Chunk).init(alloc);
        defer {
            var fit = foundChunks.valueIterator();
            while (fit.next()) |pchunk| {
                pchunk.deinit(alloc);
            }
            foundChunks.deinit();
        }
        var onFound = struct {
            pFound: *std.AutoHashMap(Hash, Chunk),
            fn invoke(self: *@This(), chunk: Chunk) !void {
                try self.pFound.put(chunk.getHash(), chunk);
            }
        }{ .pFound = &foundChunks };

        try store2.getMany(&checkSet, &onFound);

        const tGetManyEnd = std.Io.Timestamp.now(io, .real);
        std.debug.print("[perf] getMany: {d}ms\n", .{tGetManyStart.durationTo(tGetManyEnd).toMilliseconds()});

        // should find all 100 existing chunks, not the 2 non-existing ones
        try testing.expectEqual(100, foundChunks.count());

        // verify each found chunk has correct data
        var fit = foundChunks.iterator();
        while (fit.next()) |e| {
            const expected = cs.get(e.key_ptr.*);
            try testing.expect(expected != null);
            try testing.expectEqualSlices(u8, expected.?.data, e.value_ptr.*.data);
        }
    }
}

// todo
// block cache
// bloom filter
