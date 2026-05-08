const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = b.standardOptimizeOption(.{});

    // Common module between client and server
    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/common.zig"),
        .target = target,
    });

    // Main library module for the server
    const mod = b.addModule("zigdb", .{
        .root_source_file = b.path("src/server/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common },
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
                .{ .name = "common", .module = common },
            },
        }),
        .use_llvm = true,
    });

    // Run the compilation checks (for ZLS)
    const check_step = b.step("check", "Check if zigdb compiles");
    check_step.dependOn(&server_exe_check.step);
    check_step.dependOn(&client_exe_check.step);

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
