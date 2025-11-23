const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log.scoped(.Ipc);

const Db = @import("Db.zig");

pub fn Ipc(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,

        server: std.net.Server,
        fd: posix.fd_t,

        db: Db,
        offerer: *T,

        const Command = union(enum) {
            list: void,
            set: u32,
            invalid: void,
        };

        pub fn init(allocator: Allocator, path: []const u8, offerer: *T) !Self {
            _ = std.fs.cwd().deleteFile(path) catch {};

            const addr = try std.net.Address.initUnix(path);

            var server = try addr.listen(.{ .force_nonblocking = true });
            errdefer server.deinit();

            log.debug("listening on {s}", .{path});

            const db = try Db.init(allocator);

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

        pub fn accept(self: *Self) void {
            var addr: posix.sockaddr = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

            const client_fd = posix.accept(self.fd, &addr, &addr_len, 0) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    log.err("accept connection error: {}", .{err});
                    return;
                },
            };
            defer posix.close(client_fd);

            var buf: [64]u8 = undefined;
            const n = posix.read(client_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => {
                    log.warn("client connected but no data sent immediately, dropping", .{});
                    return;
                },
                else => {
                    log.err("read error: {}", .{err});
                    return;
                },
            };
            if (n == 0) return;

            const msg = buf[0..n];
            log.debug("message received: \"{s}\"", .{msg});

            switch (parseCommand(msg)) {
                .list => {
                    const result = self.db.listAlloc(self.allocator) catch |err| {
                        log.err("db connection error: {}", .{err});
                        return;
                    };
                    defer self.allocator.free(result);

                    var written: usize = 0;
                    while (written < result.len) {
                        const m = posix.write(client_fd, result[written..]) catch |err| switch (err) {
                            error.WouldBlock => {
                                log.warn("client not ready, response truncated", .{});
                                break;
                            },
                            else => {
                                log.err("write error: {}", .{err});
                                return;
                            },
                        };
                        if (m == 0) break;
                        written += m;
                    }
                },
                .set => |m| {
                    self.offerer.setSource(m) catch |err| {
                        log.err("error setting clipboard source: {}", .{err});
                        return;
                    };
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
    };
}
