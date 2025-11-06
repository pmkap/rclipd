const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.Offerer);

const wayland = @import("wayland");
const zwlr = wayland.client.zwlr;

const Db = @import("Db.zig");

const Self = @This();

allocator: Allocator,

manager: *zwlr.DataControlManagerV1,
device: *zwlr.DataControlDeviceV1,

sources: std.ArrayListUnmanaged(Source) = .{},

db: Db,

// This is dispatched by the main loop
pollable_fds: std.ArrayListUnmanaged(i32) = .{},

const Source = struct {
    data_control_source: *zwlr.DataControlSourceV1,
    entry_id: i64,
    fd_mime_map: std.AutoHashMapUnmanaged(i32, []const u8) = .{},

    to_free: std.ArrayListUnmanaged([*:0]const u8) = .{},

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.fd_mime_map.deinit(allocator);
        for (self.to_free.items) |i| allocator.free(i[0 .. std.mem.span(i).len + 1]);
        self.to_free.deinit(allocator);

        self.data_control_source.destroy();
    }
};

pub fn init(
    allocator: Allocator,
    manager: *zwlr.DataControlManagerV1,
    device: *zwlr.DataControlDeviceV1,
) !*Self {
    const db = try Db.init();
    const self = try allocator.create(Self);
    self.* = Self{
        .allocator = allocator,
        .manager = manager,
        .device = device,
        .db = db,
    };
    return self;
}

pub fn setSource(self: *Self, entry_id: i64) !void {
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
        const c_str: [*:0]const u8 = @ptrCast(
            try std.mem.concat(self.allocator, u8, &.{ m, "\x00" }),
        );
        data_control_source.offer(c_str);
        try source.to_free.append(self.allocator, c_str);
    }

    self.device.setSelection(data_control_source);

    try self.sources.append(self.allocator, source);
}

fn dataControlSourceListener(data_control_source: *zwlr.DataControlSourceV1, event: zwlr.DataControlSourceV1.Event, self: *Self) void {
    switch (event) {
        .send => |ev| {
            log.debug("listener event received: fd = {any}, mime_type = {s}", .{ ev.fd, ev.mime_type });

            var source = for (self.sources.items) |*s| {
                if (s.data_control_source == data_control_source) {
                    break s;
                }
            } else unreachable;

            const mime_copy = self.allocator.dupe(u8, std.mem.span(ev.mime_type)) catch return; // TODO: free
            source.fd_mime_map.put(
                self.allocator,
                ev.fd,
                mime_copy,
            ) catch return;

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

pub fn handleFdWrite(self: *Self, fd: i32) !bool {
    _ = self;
    _ = fd;
    // This is called from the event loop
    // get mime type from self.sources' fd_mime_maps, get the respective blob from db and write to fd
}
