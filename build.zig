const std = @import("std");
const Build = std.Build;

const Scanner = @import("wayland").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("/usr/share/qt6/wayland/protocols/wlr-data-control/wlr-data-control-unstable-v1.xml");

    // Pass the maximum version implemented by your wayland server or client.
    // Requests, events, enums, etc. from newer versions will not be generated,
    // ensuring forwards compatibility with newer protocol xml.
    scanner.generate("wl_seat", 5);
    scanner.generate("zwlr_data_control_manager_v1", 2);

    const exe = b.addExecutable(.{
        .name = "rclipd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("rclipd/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("wayland", wayland);
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");

    b.installArtifact(exe);
}
