const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.Offerer);

const Db = @import("Db.zig");

pub fn Offerer(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,

        manager: *T.DataControlManagerV1,
        device: *T.DataControlDeviceV1,

        sources: std.ArrayListUnmanaged(Source) = .{},

        db: Db,

        // This is used by the main loop re-create the pollfds on every iteration
        pollable_fds: std.ArrayListUnmanaged(i32) = .{},

        const Source = struct {
            data_control_source: *T.DataControlSourceV1,
            entry_id: i64,

            // TODO: make struct to avoid having 3 maps
            fd_mime_map: std.AutoHashMapUnmanaged(i32, []const u8) = .{},
            fd_data: std.AutoHashMapUnmanaged(i32, []const u8) = .{},
            fd_bytes_written: std.AutoHashMapUnmanaged(i32, usize) = .{},

            to_free: std.ArrayListUnmanaged([*:0]const u8) = .{},

            pub fn deinit(self: *@This(), allocator: Allocator) void {
                var it = self.fd_mime_map.valueIterator();
                while (it.next()) |i| allocator.free(i.*);
                self.fd_mime_map.deinit(allocator);

                var it2 = self.fd_data.valueIterator();
                while (it2.next()) |i| allocator.free(i.*);
                self.fd_data.deinit(allocator);

                for (self.to_free.items) |i| allocator.free(i[0 .. std.mem.span(i).len + 1]);
                self.to_free.deinit(allocator);

                self.fd_bytes_written.deinit(allocator);

                self.data_control_source.destroy();
            }
        };

        pub fn create(
            allocator: Allocator,
            manager: *T.DataControlManagerV1,
            device: *T.DataControlDeviceV1,
        ) !*Self {
            const db = try Db.init(allocator);
            const self = try allocator.create(Self);
            self.* = Self{
                .allocator = allocator,
                .manager = manager,
                .device = device,
                .db = db,
            };
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.sources.deinit(self.allocator);
            self.pollable_fds.deinit(self.allocator);
            self.db.deinit();
            self.allocator.destroy(self);
        }

        pub fn setSource(self: *Self, entry_id: i64) !void {
            log.debug("set source", .{});
            const data_control_source = try self.manager.createDataSource();
            data_control_source.setListener(*Self, dataControlSourceListener, self);

            var source = Source{
                .data_control_source = data_control_source,
                .entry_id = entry_id,
            };

            var mimes = try self.db.getMimesAlloc(self.allocator, entry_id);
            defer mimes.deinit(self.allocator);
            defer for (mimes.items) |m| self.allocator.free(m);

            for (mimes.items) |m| {
                // not sure for how long wayland needs this c_str sent with offer, so duping them here and free later
                const c_str: [*:0]const u8 = @ptrCast(
                    try self.allocator.dupeZ(u8, m),
                );
                data_control_source.offer(c_str);
                try source.to_free.append(self.allocator, c_str);
            }

            self.device.setSelection(data_control_source);

            try self.sources.append(self.allocator, source);
        }

        fn dataControlSourceListener(data_control_source: *T.DataControlSourceV1, event: T.DataControlSourceV1.Event, self: *Self) void {
            switch (event) {
                .send => |ev| {
                    log.debug("listener event received: fd = {any}, mime_type = {s}", .{ ev.fd, ev.mime_type });

                    var source = for (self.sources.items) |*s| {
                        if (s.data_control_source == data_control_source) {
                            break s;
                        }
                    } else unreachable;

                    const mime_copy = self.allocator.dupe(
                        u8,
                        std.mem.span(ev.mime_type),
                    ) catch return;

                    source.fd_mime_map.put(self.allocator, ev.fd, mime_copy) catch return;
                    source.fd_bytes_written.put(self.allocator, ev.fd, 0) catch return;

                    self.pollable_fds.append(self.allocator, ev.fd) catch return;
                },
                .cancelled => {
                    for (self.sources.items, 0..) |*s, i| {
                        if (s.data_control_source == data_control_source) {
                            s.deinit(self.allocator);
                            _ = self.sources.orderedRemove(i);
                            return;
                        }
                    }
                    unreachable;
                },
            }
        }

        pub fn handleFdWrite(self: *Self, fd: i32) !void {
            const chunk_size = 4096;
            log.debug("handle write", .{});

            var mime: []const u8 = undefined;
            var source = for (self.sources.items) |*s| {
                if (s.fd_mime_map.get(fd)) |m| {
                    mime = m;
                    break s;
                }
            } else unreachable;
            log.debug("found source {any} for fd {}, mime {s}", .{ source.entry_id, fd, mime });

            const get_or_put_result = try source.fd_data.getOrPut(self.allocator, fd);
            if (!get_or_put_result.found_existing) {
                get_or_put_result.value_ptr.* = try self.db.getBlobAlloc(self.allocator, source.entry_id, mime);
            }
            const data = get_or_put_result.value_ptr.*;

            const bytes_written = source.fd_bytes_written.get(fd).?;
            const remaining = data[bytes_written..];
            const chunk = if (remaining.len > chunk_size)
                remaining[0..chunk_size]
            else
                remaining;

            const n = std.posix.write(fd, chunk) catch |err| switch (err) {
                error.WouldBlock => {
                    log.debug("WouldBLock", .{});
                    return;
                },
                else => return err,
            };

            const bytes_written_new = bytes_written + n;
            log.debug("total bytes written: {d}", .{bytes_written_new});
            source.fd_bytes_written.putAssumeCapacity(fd, bytes_written_new);

            if (n == 0 or bytes_written_new == data.len) {
                log.debug("fd {d} EOF", .{fd});

                const i = for (self.pollable_fds.items, 0..) |f, i| {
                    if (f == fd) break i;
                } else unreachable;
                _ = self.pollable_fds.orderedRemove(i);

                std.posix.close(fd);

                _ = source.fd_data.remove(fd);
                _ = source.fd_mime_map.remove(fd);
                _ = source.fd_bytes_written.remove(fd);
            }
        }
    };
}
