const std = @import("std");
const mem = std.mem;
const allocator = std.heap.c_allocator;
const assert = std.debug.assert;
const log = std.log;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const display = &@import("main.zig").display;
const Db = @import("Db.zig");

const Self = @This();

offer: ?*zwlr.DataControlOfferV1,
mime_types: std.ArrayListUnmanaged([*:0]const u8),
db: Db,

pub fn init(device: *zwlr.DataControlDeviceV1) !*Self {
    const db = try Db.init();
    const self = try allocator.create(Self);
    self.* = Self{
        .offer = null,
        .mime_types = std.ArrayListUnmanaged([*:0]const u8){},
        .db = db,
    };

    device.setListener(*Self, dataControlListener, self);

    return self;
}

pub fn deinit(self: *Self) void {
    self.db.deinit();
    self.mime_types.deinit(allocator);
    allocator.destroy(self);
}

fn dataControlListener(device: *zwlr.DataControlDeviceV1, event: zwlr.DataControlDeviceV1.Event, self: *Self) void {
    switch (event) {
        .data_offer => |ev| {
            log.debug("Event received: data offer", .{});
            assert(self.mime_types.items.len == 0);
            if (self.offer) |old_offer| {
                old_offer.destroy();
            }
            self.offer = ev.id;
            self.offer.?.setListener(*Self, dataControlOfferListener, self);
        },
        .selection => |ev| {
            log.debug("Event received: selection {any}", .{ev.id});
            defer self.mime_types.clearRetainingCapacity();
            // TODO: free the underlying bytes of mime_types they are leaking currently

            if (ev.id) |offer| {
                assert(offer == self.offer.?);

                var blobs = std.ArrayListUnmanaged(Db.model.Blob){};
                defer blobs.deinit(allocator);

                var mimes = std.ArrayListUnmanaged(Db.model.Mime){};
                defer mimes.deinit(allocator);

                for (self.mime_types.items) |m| {
                    const content = receiveOffer(offer, m) catch return; // TODO: these need to freed as well, currently leaking
                    log.debug("Received {s} for event {any}", .{ m, offer });
                    blobs.append(allocator, Db.model.Blob{ .data = content, .size = content.len }) catch return;
                    mimes.append(allocator, Db.model.Mime{ .mime = mem.span(m) }) catch return;
                }
                self.db.addEntry(blobs, mimes) catch return;
            } else {
                if (self.offer) |old_offer| {
                    old_offer.destroy();
                    self.offer = null;
                }
            }
        },
        .primary_selection => |ev| {
            log.debug("Event received: primary selection {any}", .{ev.id});
            self.mime_types.clearRetainingCapacity();
            // TODO: free the underlying bytes of mime_types they are leaking currently

            if (ev.id) |offer| {
                assert(offer == self.offer.?);
            } else {
                if (self.offer) |old_offer| {
                    old_offer.destroy();
                    self.offer = null;
                }
            }
        },
        .finished => {
            device.destroy();
        },
    }
}

// Self owns the returned memory, careful with the length when freeing
fn dataControlOfferListener(_: *zwlr.DataControlOfferV1, event: zwlr.DataControlOfferV1.Event, self: *Self) void {
    switch (event) {
        .offer => |ev| {
            const mime_copy = std.mem.concat(
                allocator,
                u8,
                &.{ mem.span(ev.mime_type), "\x00" },
            ) catch return;

            const result: [*:0]const u8 = @ptrCast(mime_copy.ptr);
            self.mime_types.append(allocator, result) catch return;
        },
    }
}

// Caller owns the returned memory
fn receiveOffer(offer: *zwlr.DataControlOfferV1, mime: [*:0]const u8) ![]u8 {
    const fd = try std.posix.pipe();
    const fd_read = fd[0];
    const fd_write = fd[1];

    offer.receive(mime, fd_write);
    _ = display.*.flush();

    _ = std.posix.close(fd_write);

    var data = std.ArrayListUnmanaged(u8){};
    defer data.deinit(allocator);
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = try std.posix.read(fd_read, &buf);
        if (n == 0) break;

        try data.appendSlice(allocator, buf[0..n]);
    }

    _ = std.posix.close(fd_read);
    return data.toOwnedSlice(allocator);
}
