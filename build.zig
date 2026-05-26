const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend = b.option(
        []const u8,
        "backend",
        "Override the default event loop backend (io_uring, epoll, kqueue, iocp, poll)",
    );
    //troupe
    const troupe = b.dependency("troupe", .{
        .target = target,
        .optimize = optimize,
    });

    //zio
    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
    });

    const tracy = b.option([]const u8, "tracy", "Enable Tracy integration. Supply path to Tracy source");
    const tracy_callstack = b.option(bool, "tracy-callstack", "Include callstack information with Tracy data. Does nothing if -Dtracy is not provided") orelse (tracy != null);
    const tracy_allocation = b.option(bool, "tracy-allocation", "Include allocation information with Tracy data. Does nothing if -Dtracy is not provided") orelse (tracy != null);
    const tracy_callstack_depth: u32 = b.option(u32, "tracy-callstack-depth", "Declare callstack depth for Tracy data. Does nothing if -Dtracy_callstack is not provided") orelse 10;

    const options = b.addOptions();
    options.addOption(bool, "enable_tracy", tracy != null);
    options.addOption(bool, "enable_tracy_callstack", tracy_callstack);
    options.addOption(bool, "enable_tracy_allocation", tracy_allocation);
    options.addOption(u32, "tracy_callstack_depth", tracy_callstack_depth);

    const exe = b.addExecutable(.{
        .name = "s3",
        .use_llvm = true, //arch sframe bug: https://codeberg.org/ziglang/zig/issues/30959
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "troupe", .module = troupe.module("root") },
                .{ .name = "zio", .module = zio.module("zio") },
            },
            .strip = if (tracy != null) false else if (optimize == .Debug) false else true,
        }),
    });

    exe.root_module.addOptions("build_options", options);

    if (tracy) |tracy_path| {
        const client_cpp = b.pathJoin(
            &[_][]const u8{ tracy_path, "public", "TracyClient.cpp" },
        );
        const tracy_c_flags: []const []const u8 = &.{
            "-DTRACY_ENABLE=1",
            "-fno-sanitize=undefined",
            //TODO: tracy fiber
        };

        exe.root_module.addIncludePath(.{ .cwd_relative = tracy_path });
        exe.root_module.addCSourceFile(.{
            .file = .{ .cwd_relative = client_cpp },
            .flags = tracy_c_flags,
        });
        exe.root_module.link_libc = true;
        exe.root_module.link_libcpp = true;
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
