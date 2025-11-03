const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.Ipc);
const allocator = std.heap.c_allocator;

const Db = @import("Db.zig");

const Self = @This();

server: std.net.Server,
fd: posix.fd_t,
db: Db,

pub fn init(path: []const u8) !Self {
    _ = std.fs.cwd().deleteFile(path) catch {};

    const addr = try std.net.Address.initUnix(path);

    var server = try addr.listen(.{ .force_nonblocking = true });
    errdefer server.deinit();

    log.debug("listening on {s}", .{path});

    const db = try Db.init();

    return Self{
        .server = server,
        .fd = server.stream.handle,
        .db = db,
    };
}

pub fn deinit(self: *Self) void {
    self.server.deinit();
}

pub fn tryAccept(self: *Self) !void {
    var addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    const client_fd = posix.accept(self.fd, &addr, &addr_len, 0) catch |err| switch (err) {
        error.WouldBlock => return, // nothing pending
        else => return err,
    };
    defer posix.close(client_fd);

    var buf: [256]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch |err| switch (err) {
        error.WouldBlock => return, // no data yet
        else => return err,
    };
    if (n == 0) return; // disconnected
    log.debug("message: {s}", .{buf});

    // TODO: command parser
    const result = try self.db.listAlloc(allocator);
    defer allocator.free(result);
    _ = try posix.write(client_fd, result);
}
