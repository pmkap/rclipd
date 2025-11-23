const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const posix = std.posix;
const log = std.log.scoped(.main);

const wayland = @import("wayland");
const wl = wayland.client.wl;

const Watcher = @import("watcher.zig").Watcher;
const Offerer = @import("offerer.zig").Offerer;
const Ipc = @import("ipc.zig").Ipc;
const fatal = @import("utils.zig").fatal;
const config = &@import("main.zig").config;

const EventType = enum { wl, ipc, watcher, offerer };

pub fn EventLoop(comptime T: type) type {
    return struct {
        pub fn run(
            allocator: mem.Allocator,
            seat: *wl.Seat,
            manager: *T.DataControlManagerV1,
            display: *wl.Display,
        ) !void {
            const data_control_device = try manager.getDataDevice(seat);
            defer data_control_device.destroy();

            // Setup all tasks
            const watcher = try Watcher(T).create(allocator, data_control_device);
            defer watcher.destroy();

            const offerer = try Offerer(T).create(allocator, manager, data_control_device);
            defer offerer.destroy();

            var ipc = try Ipc(Offerer(T)).init(allocator, config.socket_path, offerer);
            defer ipc.deinit();

            var poll_fds = std.ArrayListUnmanaged(posix.pollfd){};
            var poll_events = std.ArrayListUnmanaged(EventType){};
            defer poll_fds.deinit(allocator);
            defer poll_events.deinit(allocator);

            const wl_fd = display.getFd();

            const revents_in = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;
            const revents_out = posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR;

            // wayland socket at index 0, do not remove
            try poll_fds.append(allocator, .{
                .fd = wl_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            });
            try poll_events.append(allocator, .wl);

            // IPC socket at index 1, do not remove
            try poll_fds.append(allocator, .{
                .fd = ipc.fd,
                .events = posix.POLL.IN,
                .revents = 0,
            });
            try poll_events.append(allocator, .ipc);

            while (true) {
                // build remaining poll_fds array
                poll_fds.shrinkRetainingCapacity(2);
                poll_events.shrinkRetainingCapacity(2);

                for (watcher.pollable_fds.items) |fd| {
                    try poll_fds.append(allocator, .{
                        .fd = fd,
                        .events = posix.POLL.IN,
                        .revents = 0,
                    });
                    try poll_events.append(allocator, .watcher);
                }

                for (offerer.pollable_fds.items) |fd| {
                    try poll_fds.append(allocator, .{
                        .fd = fd,
                        .events = posix.POLL.OUT,
                        .revents = 0,
                    });
                    try poll_events.append(allocator, .offerer);
                }

                assert(poll_fds.items.len == poll_events.items.len);

                log.debug("event loop continues with {d} FDs", .{poll_fds.items.len});

                flush_wayland_and_prepare_read(display);

                _ = try posix.poll(poll_fds.items, -1);

                for (poll_fds.items, poll_events.items) |pollfd, event_type| {
                    switch (event_type) {
                        .wl => {
                            if (pollfd.revents & revents_in != 0) {
                                _ = display.readEvents();
                                _ = display.dispatchPending();
                            } else {
                                display.cancelRead();
                            }
                        },

                        .ipc => {
                            if (pollfd.revents & revents_in != 0) {
                                ipc.accept();
                            }
                        },

                        .watcher => {
                            if (pollfd.revents & revents_in != 0) {
                                try watcher.handleFdRead(pollfd.fd);
                            }
                        },

                        .offerer => {
                            if (pollfd.revents & revents_out != 0) {
                                try offerer.handleFdWrite(pollfd.fd);
                            }
                        },
                    }
                }
            }
        }
    };
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
fn flush_wayland_and_prepare_read(display: *wl.Display) void {
    while (!display.prepareRead()) {
        const errno = display.dispatchPending();
        if (errno != .SUCCESS) {
            fatal(.event_loop, "failed to dispatch pending wayland events: E{s}", .{@tagName(errno)});
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
                fatal(.event_loop, "connection to wayland server unexpectedly terminated", .{});
            },
            .AGAIN => {
                // The socket buffer is full, so wait for it to become writable again.
                var wayland_out = [_]posix.pollfd{.{
                    .fd = display.getFd(),
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = posix.poll(&wayland_out, -1) catch |err| {
                    fatal(.event_loop, "poll() failed: {s}", .{@errorName(err)});
                };
                // No need to check for POLLHUP/POLLERR here, just fall
                // through to the next flush() to handle them in one place.
            },
            else => {
                fatal(.event_loop, "failed to flush wayland requests: E{s}", .{@tagName(errno)});
            },
        }
    }
}
