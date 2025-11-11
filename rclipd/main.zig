const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const posix = std.posix;
const log = std.log.scoped(.main);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const zwlr = wayland.client.zwlr;

const Watcher = @import("watcher.zig").Watcher;
const Offerer = @import("offerer.zig").Offerer;
const Ipc = @import("ipc.zig").Ipc;

const Globals = struct {
    seat: ?*wl.Seat = null,
    zwlr_data_control_manager: ?*zwlr.DataControlManagerV1 = null,
    ext_data_control_manager: ?*ext.DataControlManagerV1 = null,
};

pub var display: *wl.Display = undefined;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    //defer _ = gpa.deinit();

    var globals = Globals{};

    display = try wl.Display.connect(null);

    const registry = try display.getRegistry();
    registry.setListener(*Globals, registryListener, &globals);

    _ = display.roundtrip();

    const data_control_device = try globals.zwlr_data_control_manager.?.getDataDevice(globals.seat.?);
    defer data_control_device.destroy();

    // Setup all tasks
    const watcher = try Watcher(zwlr).create(allocator, data_control_device);
    defer watcher.destroy();
    defer watcher.pollable_fds.deinit(allocator);

    const offerer = try Offerer(zwlr).create(
        allocator,
        globals.zwlr_data_control_manager.?,
        data_control_device,
    );
    defer offerer.destroy();
    defer offerer.pollable_fds.deinit(allocator);

    var ipc = try Ipc(Offerer(zwlr)).init(allocator, "/tmp/rclipd.sock", offerer);
    defer ipc.deinit();

    var poll_fds = std.ArrayListUnmanaged(posix.pollfd){};
    defer poll_fds.deinit(allocator);

    const wl_fd = display.getFd();

    // wl_fd is permanently polled, don't remove this
    try poll_fds.append(allocator, .{
        .fd = wl_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    // ipc, permanently pulled, don't remove
    try poll_fds.append(allocator, .{
        .fd = ipc.fd,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    while (true) {
        flush_wayland_and_prepare_read();

        // build rest of the poll_fds array
        for (watcher.pollable_fds.items) |fd| {
            try poll_fds.append(allocator, .{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            });
        }
        watcher.pollable_fds.clearRetainingCapacity();

        const offerer_offset = poll_fds.items.len;
        for (offerer.pollable_fds.items) |fd| {
            try poll_fds.append(allocator, .{
                .fd = fd,
                .events = posix.POLL.OUT,
                .revents = 0,
            });
        }
        offerer.pollable_fds.clearRetainingCapacity();

        _ = try posix.poll(poll_fds.items, -1);

        // wayland
        assert(poll_fds.items[0].fd == wl_fd);
        if ((poll_fds.items[0].revents & posix.POLL.IN) != 0) {
            _ = display.readEvents();
            _ = display.dispatchPending();
        } else {
            display.cancelRead();
        }

        // ipc
        if ((poll_fds.items[1].revents & posix.POLL.IN) != 0) {
            try ipc.tryAccept();
        }

        var to_remove = std.ArrayListUnmanaged(usize){};
        defer to_remove.deinit(allocator);

        // watcher
        for (poll_fds.items[2..poll_fds.items.len], 0..) |poll_fd, i| {
            if ((poll_fd.revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
                const eof = try watcher.handleFdRead(poll_fd.fd);
                if (eof) {
                    posix.close(poll_fd.fd);
                    try to_remove.append(allocator, i + 2);
                }
            }
        }

        // offerer
        for (poll_fds.items[offerer_offset..poll_fds.items.len], 0..) |poll_fd, i| {
            if ((poll_fd.revents & posix.POLL.OUT) != 0) {
                const eof = try offerer.handleFdWrite(poll_fd.fd);
                if (eof) {
                    posix.close(poll_fd.fd);
                    try to_remove.append(allocator, i + offerer_offset);
                }
            }
        }

        while (to_remove.items.len > 0) {
            const i = to_remove.pop();
            _ = poll_fds.swapRemove(i.?);
        }

        log.debug("event loop continues with {d} FDs", .{poll_fds.items.len});
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                globals.seat = registry.bind(global.name, wl.Seat, 5) catch return;
            } else if (mem.orderZ(u8, global.interface, zwlr.DataControlManagerV1.interface.name) == .eq) {
                globals.zwlr_data_control_manager = registry.bind(global.name, zwlr.DataControlManagerV1, 2) catch return;
            }
        },
        .global_remove => {},
    }
}

/// The following function is adapted from https://codeberg.org/ifreund/waylock
///
/// Original license:
/// =============================================================================
/// Copyright 2022 Isaac Freund
///
/// Permission to use, copy, modify, and /or distribute this software for any
/// purpose with or without fee is hereby granted, provided that the above
/// copyright notice and this permission notice appear in all copies.
///
/// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
/// REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
/// AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
/// INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
/// LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
/// OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
/// PERFORMANCE OF THIS SOFTWARE.
/// =============================================================================
///
/// This function does the following:
///  1. Dispatch buffered wayland events to their listener callbacks.
///  2. Prepare the wayland connection for reading.
///  3. Send all buffered wayland requests to the server.
/// After this function has been called, either wl.Display.readEvents() or
/// wl.Display.cancelRead() read must be called.
fn flush_wayland_and_prepare_read() void {
    while (!display.prepareRead()) {
        const errno = display.dispatchPending();
        if (errno != .SUCCESS) {
            fatal("failed to dispatch pending wayland events: E{s}", .{@tagName(errno)});
        }
    }

    while (true) {
        const errno = display.flush();
        switch (errno) {
            .SUCCESS => return,
            .PIPE => {
                // libwayland uses this error to indicate that the wayland server
                // closed its side of the wayland socket. We want to continue to
                // read any buffered messages from the server though as there is
                // likely a protocol error message we'd like libwayland to log.
                _ = display.readEvents();
                fatal("connection to wayland server unexpectedly terminated", .{});
            },
            .AGAIN => {
                // The socket buffer is full, so wait for it to become writable again.
                var wayland_out = [_]posix.pollfd{.{
                    .fd = display.getFd(),
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = posix.poll(&wayland_out, -1) catch |err| {
                    fatal("poll() failed: {s}", .{@errorName(err)});
                };
                // No need to check for POLLHUP/POLLERR here, just fall
                // through to the next flush() to handle them in one place.
            },
            else => {
                fatal("failed to flush wayland requests: E{s}", .{@tagName(errno)});
            },
        }
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.posix.exit(1);
}
