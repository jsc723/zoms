const std = @import("std");
const Io = std.Io;

const zoms = @import("zoms");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("Hello zig\n", .{});
    const gpa = init.gpa;
    const empty: []const u8 = &.{};
    gpa.free(empty);
}
