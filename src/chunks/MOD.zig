pub const hash = @import("hash");
pub const chunks = @import("chunks.zig");
pub const chunk_store = @import("chunk_store.zig");
pub const JournalStore = chunk_store.JournalStore;
pub const HashSet = chunk_store.HashSet;
pub const HashChunkMap = chunk_store.HashChunkMap;

test {
    _ = @import("chunks.zig");
    _ = @import("chunk_store.zig");
    _ = @import("mmap.zig");
}
