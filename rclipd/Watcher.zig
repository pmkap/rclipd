const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.Watcher);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Db = @import("Db.zig");

const Self = @This();

allocator: Allocator,

current_offer: ?*zwlr.DataControlOfferV1,
current_mimes: std.ArrayListUnmanaged([*:0]const u8),

// These are waiting for completion until all FDs are read out (blobs complete)
// Then they can be sent to the db and removed
pending_transfers: std.AutoHashMapUnmanaged(*Transfer, void) = .{},

// This is dispatched by the main loop
pollable_fds: std.ArrayListUnmanaged(i32) = .{},

db: Db,

const Transfer = struct {
    allocator: Allocator,

    mimes: std.ArrayListUnmanaged([]const u8) = .{},
    fds: std.ArrayListUnmanaged(i32) = .{},

    blobs: std.ArrayListUnmanaged(?[]const u8) = .{},

    pub fn create(allocator: Allocator) !*@This() {
        const self = try allocator.create(@This());
        self.* = @This(){ .allocator = allocator };
        return self;
    }

    pub fn deinitAndDestroy(self: *@This()) void {
        for (self.mimes.items) |i| self.allocator.free(i);
        for (self.blobs.items) |i| self.allocator.free(i.?);

        self.mimes.deinit(self.allocator);
        self.fds.deinit(self.allocator);
        self.blobs.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn append(self: *@This(), mime: []const u8, fd: i32) !void {
        try self.mimes.append(self.allocator, mime);
        try self.fds.append(self.allocator, fd);
        try self.blobs.append(self.allocator, null);
    }

    pub fn trySetBlob(self: *@This(), fd: i32, data: []const u8) bool {
        for (self.fds.items, 0..) |f, i| {
            if (fd == f) {
                self.blobs.items[i] = data;
                return true;
            }
        }
        return false;
    }

    pub fn isComplete(self: *@This()) bool {
        for (self.blobs.items) |b| {
            if (b == null) return false;
        }
        return true;
    }
};

pub fn init(allocator: Allocator, device: *zwlr.DataControlDeviceV1) !*Self {
    const db = try Db.init();
    const self = try allocator.create(Self);
    self.* = Self{
        .allocator = allocator,
        .current_offer = null,
        .current_mimes = std.ArrayListUnmanaged([*:0]const u8){},
        .db = db,
    };

    device.setListener(*Self, dataControlListener, self);

    return self;
}

pub fn deinit(self: *Self) void {
    self.db.deinit();
    self.current_mimes.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn dataControlListener(device: *zwlr.DataControlDeviceV1, event: zwlr.DataControlDeviceV1.Event, self: *Self) void {
    switch (event) {
        .data_offer => |ev| {
            log.debug("Event received: data offer", .{});
            assert(self.current_mimes.items.len == 0);
            if (self.current_offer) |old_offer| {
                old_offer.destroy();
            }
            self.current_offer = ev.id;
            self.current_offer.?.setListener(*Self, dataControlOfferListener, self);
        },
        .selection => |ev| {
            log.debug("Event received: selection {any}", .{ev.id});
            defer self.current_mimes.clearRetainingCapacity();
            defer for (self.current_mimes.items) |i| self.allocator.free(i[0 .. mem.len(i) + 1]);

            if (ev.id) |offer| {
                assert(offer == self.current_offer.?);

                var transfer = Transfer.create(self.allocator) catch return;
                for (self.current_mimes.items) |mime| {
                    const fd = requestData(offer, mime) catch return;
                    log.debug("Data transfer request send for mime {s}", .{mime});

                    const mime_copy = self.allocator.dupe(u8, mem.span(mime)) catch return;

                    transfer.append(mime_copy, fd) catch return;
                }

                self.pending_transfers.put(self.allocator, transfer, {}) catch return;
                self.pollable_fds.appendSlice(self.allocator, transfer.fds.items) catch return;
            } else {
                if (self.current_offer) |old_offer| {
                    old_offer.destroy();
                    self.current_offer = null;
                }
            }
        },
        .primary_selection => |ev| {
            for (self.current_mimes.items) |i| self.allocator.free(i[0 .. mem.len(i) + 1]);
            self.current_mimes.clearRetainingCapacity();

            if (ev.id) |offer| {
                assert(offer == self.current_offer.?);
            } else {
                if (self.current_offer) |old_offer| {
                    old_offer.destroy();
                    self.current_offer = null;
                }
            }
        },
        .finished => {
            device.destroy();
        },
    }
}

/// Watcher/Self owns the returned memory in self.current_mimes, careful with the length when freeing
fn dataControlOfferListener(_: *zwlr.DataControlOfferV1, event: zwlr.DataControlOfferV1.Event, self: *Self) void {
    switch (event) {
        .offer => |ev| {
            const mime_copy = std.mem.concat(
                self.allocator,
                u8,
                &.{ mem.span(ev.mime_type), "\x00" },
            ) catch return;

            const result: [*:0]const u8 = @ptrCast(mime_copy.ptr);
            self.current_mimes.append(self.allocator, result) catch return;
        },
    }
}

pub fn handleFdRead(self: *Self, fd: i32) !void {
    const data = try readFd(self.allocator, fd);

    var it = self.pending_transfers.keyIterator();

    while (it.next()) |ptr| {
        const transfer = ptr.*;

        if (transfer.trySetBlob(fd, data)) {
            if (transfer.isComplete()) {
                try self.db.addEntry(self.allocator, transfer.blobs, transfer.mimes);

                _ = self.pending_transfers.remove(transfer);
                transfer.deinitAndDestroy();
            }
            break;
        }
    }
}

/// Caller owns the returned memory
fn readFd(allocator: Allocator, fd: i32) ![]const u8 {
    defer std.posix.close(fd);

    var data = std.ArrayListUnmanaged(u8){};
    defer data.deinit(allocator);
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = try std.posix.read(fd, &buf);
        if (n == 0) break;

        try data.appendSlice(allocator, buf[0..n]);
    }

    return data.toOwnedSlice(allocator);
}

/// Caller has to close the returned pipe
fn requestData(offer: *zwlr.DataControlOfferV1, mime: [*:0]const u8) !i32 {
    const fd = try std.posix.pipe();
    const fd_read = fd[0];
    const fd_write = fd[1];

    offer.receive(mime, fd_write);

    _ = std.posix.close(fd_write);

    return fd_read;
}
