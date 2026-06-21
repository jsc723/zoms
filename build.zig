const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hash_mod = b.addModule("hash", .{
        .root_source_file = b.path("src/hash/MOD.zig"),
        .target = target,
    });
    const mod = b.addModule("zoms", .{ .root_source_file = b.path("src/root.zig"), .target = target, .imports = &.{
        .{ .name = "hash", .module = hash_mod },
    } });

    const exe = b.addExecutable(.{
        .name = "zoms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hash", .module = hash_mod },
                .{ .name = "zoms", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const hash_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hash/MOD.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_hash_tests = b.addRunArtifact(hash_tests);
    const hash_test_step = b.step("test-hash", "Run hash tests only");
    hash_test_step.dependOn(&run_hash_tests.step);

    const chunks_test_mod = b.createModule(.{
        .root_source_file = b.path("src/chunks/MOD.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hash", .module = hash_mod },
        },
    });
    const chunks_tests = b.addTest(.{
        .root_module = chunks_test_mod,
    });

    const run_chunks_tests = b.addRunArtifact(chunks_tests);
    const chunks_test_step = b.step("test-chunks", "Run chunks tests only");
    chunks_test_step.dependOn(&run_chunks_tests.step);

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_hash_tests.step);
    test_step.dependOn(&run_chunks_tests.step);

    // for zls
    const check_step = b.step("check", "Check compilation");
    check_step.dependOn(&exe.step);
}
