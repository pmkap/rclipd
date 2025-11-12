const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const posix = std.posix;
const log = std.log.scoped(.main);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const zwlr = wayland.client.zwlr;

const EventLoop = @import("event_loop.zig").EventLoop;

const Globals = struct {
    seat: ?*wl.Seat = null,
    zwlr_data_control_manager: ?*zwlr.DataControlManagerV1 = null,
    ext_data_control_manager: ?*ext.DataControlManagerV1 = null,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    //defer _ = gpa.deinit();

    var globals = Globals{};

    const display = try wl.Display.connect(null);

    const registry = try display.getRegistry();
    registry.setListener(*Globals, registryListener, &globals);

    _ = display.roundtrip();

    try EventLoop(zwlr).run(
        allocator,
        globals.seat.?,
        globals.zwlr_data_control_manager.?,
        display,
    );
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                globals.seat = registry.bind(global.name, wl.Seat, 5) catch return;
            } else if (mem.orderZ(u8, global.interface, zwlr.DataControlManagerV1.interface.name) == .eq) {
                globals.zwlr_data_control_manager = registry.bind(global.name, zwlr.DataControlManagerV1, 2) catch return;
            } else if (mem.orderZ(u8, global.interface, ext.DataControlManagerV1.interface.name) == .eq) {
                globals.ext_data_control_manager = registry.bind(global.name, ext.DataControlManagerV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}
