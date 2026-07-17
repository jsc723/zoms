const std = @import("std");
const Dir = std.Io.Dir;
const File = std.Io.File;

const OpenCreateOptions = struct {
    allowWrite: bool = true,
};

pub fn openOrCreateFile(io: std.Io, path: []const u8, options: OpenCreateOptions) !struct {
    file: File,
    created: bool,
} {
    if (Dir.cwd().openFile(io, path, .{
        .mode = if (options.allowWrite) .read_write else .read_only,
    })) |f| {
        return .{
            .file = f,
            .created = false,
        };
    } else |err| switch (err) {
        error.FileNotFound => {
            if (!options.allowWrite) {
                return err;
            }
            if (Dir.path.dirname(path)) |parentDir| {
                try Dir.cwd().createDirPath(io, parentDir);
            }
            const f = try Dir.cwd().createFile(io, path, .{
                .read = true,
            });
            return .{
                .file = f,
                .created = true,
            };
        },
        else => {
            return err;
        },
    }
}

const testing = std.testing;
test "test openOrCreateFile" {
    const io = testing.io;
    const res = try openOrCreateFile(io, "tmp/testUtilFile/test.zjs", .{ .allowWrite = true });
    try testing.expect(res.created);
    defer Dir.cwd().deleteTree(io, "tmp/testUtilFile") catch {};
    defer res.file.close(io);
}
