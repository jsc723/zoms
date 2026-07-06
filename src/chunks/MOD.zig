pub const chunks = @import("chunks.zig");
pub const chunk_store = @import("chunk_store.zig");
pub const JournalStore = chunk_store.JournalStore;

test {
    _ = @import("chunks.zig");
    _ = @import("chunk_store.zig");
}
