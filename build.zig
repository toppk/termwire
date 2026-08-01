const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Ghostty's VT engine, consumed as a Zig module straight out of the
    // vendored tree (third_party/ghostty exports "ghostty-vt").
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });
    const ghostty_vt = ghostty_dep.module("ghostty-vt");

    // Wire-format types shared by the daemon and clients.
    const protocol_mod = b.addModule("termwire-protocol", .{
        .root_source_file = b.path("protocol/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("daemon/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ghostty-vt", .module = ghostty_vt },
            .{ .name = "protocol", .module = protocol_mod },
        },
    });

    const daemon_exe = b.addExecutable(.{
        .name = "termwired",
        .root_module = daemon_mod,
    });
    b.installArtifact(daemon_exe);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });

    const cli_exe = b.addExecutable(.{
        .name = "tw",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    const webd_mod = b.createModule(.{
        .root_source_file = b.path("webd/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });

    const webd_exe = b.addExecutable(.{
        .name = "termwire-webd",
        .root_module = webd_mod,
    });
    b.installArtifact(webd_exe);

    const run_step = b.step("run", "Run the daemon (termwired)");
    const run_cmd = b.addRunArtifact(daemon_exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Web client: npm is only needed for these two steps.
    const web_step = b.step("web", "Build the web client (npm install + vite build)");
    const npm_install = b.addSystemCommand(&.{ "npm", "--prefix", "web", "install", "--no-fund", "--no-audit" });
    const npm_build = b.addSystemCommand(&.{ "npm", "--prefix", "web", "run", "build" });
    npm_build.step.dependOn(&npm_install.step);
    web_step.dependOn(&npm_build.step);

    const serve_step = b.step("serve", "Build the web client and serve it via termwire-webd");
    const serve_cmd = b.addRunArtifact(webd_exe);
    if (b.args) |args| serve_cmd.addArgs(args);
    serve_cmd.step.dependOn(&npm_build.step);
    serve_step.dependOn(&serve_cmd.step);

    const fmt_step = b.step("fmt", "Format Zig sources");
    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "daemon", "protocol", "cli", "webd" } });
    fmt_step.dependOn(&fmt.step);

    const test_step = b.step("test", "Run all tests");
    inline for (.{ daemon_mod, protocol_mod, cli_mod, webd_mod }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
