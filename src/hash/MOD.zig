const hash = @import("hash.zig");
pub const Hash = hash.Hash;
pub const base32 = @import("base32.zig");

test {
    _ = @import("hash.zig");
    _ = @import("base32.zig");
}
