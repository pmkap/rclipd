const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Watcher = @import("Watcher.zig");

const Globals = struct {
    seat: ?*wl.Seat = null,
    data_control_manager: ?*zwlr.DataControlManagerV1 = null,
};

pub var display: *wl.Display = undefined;

pub fn main() anyerror!void {
    var globals = Globals{};

    display = try wl.Display.connect(null);

    const registry = try display.getRegistry();
    registry.setListener(*Globals, registryListener, &globals);

    _ = display.roundtrip();

    const data_control_device = try globals.data_control_manager.?.getDataDevice(globals.seat.?);

    // Setup all tasks
    _ = try Watcher.init(data_control_device);

    while (true) {
        _ = display.dispatch();
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                globals.seat = registry.bind(global.name, wl.Seat, 5) catch return;
            } else if (mem.orderZ(u8, global.interface, zwlr.DataControlManagerV1.interface.name) == .eq) {
                globals.data_control_manager = registry.bind(global.name, zwlr.DataControlManagerV1, 2) catch return;
            }
        },
        .global_remove => {},
    }
}
