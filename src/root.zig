//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

test {
    _ = @import("hash/hash.zig");
    _ = @import("hash/encoding.zig");
}
