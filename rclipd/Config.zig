const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Self = @This();

allocator: Allocator,

db_path: []const u8,
socket_path: []const u8,

pub fn init(allocator: Allocator) !Self {
    _ = std.c.umask(0o077);

    const data_home_dir = try fs.getAppDataDir(allocator, "rclipd");
    defer allocator.free(data_home_dir);

    const runtime_dir = if (posix.getenv("XDG_RUNTIME_DIR")) |dir| if (dir.len > 0)
        dir
    else
        "/tmp" else "/tmp";

    const db_path_default = try fs.path.join(
        allocator,
        &[_][]const u8{ data_home_dir, "db.sqlite" },
    );
    defer allocator.free(db_path_default);

    const db_path = try allocator.dupe(
        u8,
        if (posix.getenv("RCLIPD_DB_PATH")) |path| if (path.len > 0)
            path
        else
            db_path_default else db_path_default,
    );

    try std.fs.cwd().makePath(fs.path.dirnamePosix(db_path).?);

    const default_socket_path = try fs.path.join(
        allocator,
        &[_][]const u8{ runtime_dir, "rclipd.sock" },
    );

    return Self{
        .allocator = allocator,
        .socket_path = default_socket_path,
        .db_path = db_path,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.db_path);
    self.allocator.free(self.socket_path);
}
