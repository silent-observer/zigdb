const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = b.standardOptimizeOption(.{});

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });

    const uuid = b.dependency("uuid", .{
        .target = target,
        .optimize = optimize,
    });

    // Common module between client and server
    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/common.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "uuid", .module = uuid.module("uuid") },
        },
    });

    // Main library module for the server
    const mod = b.addModule("zigdb", .{
        .root_source_file = b.path("src/server/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common },
            .{ .name = "uuid", .module = uuid.module("uuid") },
            .{ .name = "zeit", .module = zeit.module("zeit") },
        },
    });

    // Server executable
    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigdb", .module = mod },
            },
        }),
        .use_llvm = true,
    });
    b.installArtifact(server_exe);

    // Copy of the above for auto checks
    const server_exe_check = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigdb", .module = mod },
            },
        }),
        .use_llvm = true,
    });

    // Client executable
    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "uuid", .module = uuid.module("uuid") },
                .{ .name = "common", .module = common },
            },
        }),
        .use_llvm = true,
    });
    b.installArtifact(client_exe);

    // Copy of the above for auto checks
    const client_exe_check = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "uuid", .module = uuid.module("uuid") },
                .{ .name = "common", .module = common },
            },
        }),
        .use_llvm = true,
    });

    const lib_unit_tests = b.addTest(.{ .root_module = mod });
    const lib_unit_tests_check = b.addTest(.{ .root_module = mod });
    b.installArtifact(lib_unit_tests);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Run the compilation checks (for ZLS)
    const check_step = b.step("check", "Check if zigdb compiles");
    check_step.dependOn(&server_exe_check.step);
    check_step.dependOn(&client_exe_check.step);
    check_step.dependOn(&lib_unit_tests_check.step);

    // Main executable steps
    const run_server_step = b.step("run-server", "Run the server");
    const run_client_step = b.step("run-client", "Run the client");

    const run_server_cmd = b.addRunArtifact(server_exe);
    const run_client_cmd = b.addRunArtifact(client_exe);
    run_server_step.dependOn(&run_server_cmd.step);
    run_client_step.dependOn(&run_client_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_server_cmd.step.dependOn(b.getInstallStep());
    run_client_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_server_cmd.addArgs(args);
        run_client_cmd.addArgs(args);
    }
}
