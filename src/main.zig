const std = @import("std");
const Io = std.Io;

const zoms = @import("zoms");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("hello zig", .{});
    const alloc = init.gpa;
    const empty: []const u8 = &.{};
    alloc.free(empty);
}
