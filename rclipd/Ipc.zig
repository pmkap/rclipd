const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log.scoped(.Ipc);

const Db = @import("Db.zig");
const Offerer = @import("Offerer.zig");

const Self = @This();

allocator: Allocator,

server: std.net.Server,
fd: posix.fd_t,

db: Db,
offerer: *Offerer,

const Command = union(enum) {
    list: void,
    set: u32,
    invalid: void,
};

pub fn init(allocator: Allocator, path: []const u8, offerer: *Offerer) !Self {
    _ = std.fs.cwd().deleteFile(path) catch {};

    const addr = try std.net.Address.initUnix(path);

    var server = try addr.listen(.{ .force_nonblocking = true });
    errdefer server.deinit();

    log.debug("listening on {s}", .{path});

    const db = try Db.init();

    return Self{
        .allocator = allocator,
        .server = server,
        .fd = server.stream.handle,
        .db = db,
        .offerer = offerer,
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

    var buf: [64]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch |err| switch (err) {
        error.WouldBlock => return, // no data yet
        else => return err,
    };
    if (n == 0) return; // disconnected

    const msg = buf[0..n];
    log.debug("message received: \"{s}\"", .{msg});

    switch (parseCommand(msg)) {
        .list => {
            const result = try self.db.listAlloc(self.allocator);
            defer self.allocator.free(result);
            _ = try posix.write(client_fd, result);
        },
        .set => |m| {
            try self.offerer.setSource(m);
        },
        .invalid => {
            log.debug("failed to parse command \"{s}\"", .{msg});
        },
    }
}

fn parseCommand(msg: []const u8) Command {
    var it = mem.splitScalar(u8, msg, ' ');

    const first = it.next() orelse return .invalid;

    if (mem.eql(u8, first, "list")) {
        return .list;
    }

    const second = it.next() orelse return .invalid;

    if (mem.eql(u8, first, "set")) {
        const n = std.fmt.parseInt(u32, second, 10) catch return .invalid;
        return .{ .set = n };
    }

    return .invalid;
}
