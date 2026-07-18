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

    const lz4_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("libs/lz4/lz4.h"),
        .target = target,
        .optimize = optimize,
    });
    const lz4 = lz4_translate_c.createModule();

    const hash_mod = b.addModule("hash", .{
        .root_source_file = b.path("src/hash/MOD.zig"),
        .target = target,
        .optimize = optimize,
    });
    const util_mod = b.addModule("util", .{
        .root_source_file = b.path("src/util/MOD.zig"),
        .target = target,
        .optimize = optimize,
    });
    const chunks_mod = b.addModule("chunks", .{
        .root_source_file = b.path("src/chunks/MOD.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hash", .module = hash_mod },
            .{ .name = "util", .module = util_mod },
            .{ .name = "lz4", .module = lz4 },
        },
    });
    chunks_mod.addCSourceFiles(.{
        .files = &.{"libs/lz4/lz4.c"},
        .flags = &.{},
    });

    const zjs_lib = b.addLibrary(.{
        .name = "zjs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/chunks/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hash", .module = hash_mod },
                .{ .name = "util", .module = util_mod },
                .{ .name = "lz4", .module = lz4 },
            },
            .link_libc = true,
        }),
        .linkage = .static,
    });
    zjs_lib.root_module.addCSourceFiles(.{
        .files = &.{"libs/lz4/lz4.c"},
        .flags = &.{},
    });
    b.installArtifact(zjs_lib);
    const install_header = b.addInstallHeaderFile(b.path("src/chunks/zjs.h"), "zjs.h");
    b.getInstallStep().dependOn(&install_header.step);

    const mod = b.addModule("zoms", .{ .root_source_file = b.path("src/root.zig"), .target = target, .imports = &.{
        .{ .name = "hash", .module = hash_mod },
        .{ .name = "chunks", .module = chunks_mod },
        .{ .name = "util", .module = util_mod },
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

    // ---- chunks test ---- //
    const chunks_test_mod = b.createModule(.{
        .root_source_file = b.path("src/chunks/MOD.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hash", .module = hash_mod },
            .{ .name = "util", .module = util_mod },
            .{ .name = "lz4", .module = lz4 },
        },
    });
    chunks_test_mod.addCSourceFiles(.{
        .files = &.{"libs/lz4/lz4.c"},
        .flags = &.{},
    });

    const chunks_tests = b.addTest(.{
        .root_module = chunks_test_mod,
    });

    const run_chunks_tests = b.addRunArtifact(chunks_tests);
    const chunks_test_step = b.step("test-chunks", "Run chunks tests only");
    chunks_test_step.dependOn(&run_chunks_tests.step);

    // ---- util test ---- //
    const util_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/util/MOD.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_util_tests = b.addRunArtifact(util_tests);
    const util_tests_step = b.step("test-util", "Run util tests only");
    util_tests_step.dependOn(&run_util_tests.step);

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
    test_step.dependOn(&run_util_tests.step);

    // for zls
    const check_step = b.step("check", "Check compilation");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&hash_tests.step);
    check_step.dependOn(&chunks_tests.step);
    check_step.dependOn(&util_tests.step);
}
