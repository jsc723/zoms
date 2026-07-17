pub const hash = @import("hash");
pub const chunks = @import("chunks.zig");
pub const chunk_store = @import("chunk_store.zig");
pub const JournalStore = chunk_store.JournalStore;
pub const HashSet = chunk_store.HashSet;
pub const HashChunkMap = chunk_store.HashChunkMap;
pub const hash_iterator = @import("hash_iterator.zig");
pub const HashIterator = hash_iterator.HashIterator;
pub const ConstSliceIteraetor = hash_iterator.ConstSliceIterator;

test {
    _ = @import("chunks.zig");
    _ = @import("chunk_store.zig");
    _ = @import("mmap.zig");
    _ = @import("hash_iterator.zig");
}
