const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const log = std.log.scoped(.main);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const zwlr = wayland.client.zwlr;

const EventLoop = @import("event_loop.zig").EventLoop;
const Config = @import("Config.zig");

const fatal = @import("utils.zig").fatal;

const Globals = struct {
    seat: ?*wl.Seat = null,
    zwlr_data_control_manager: ?*zwlr.DataControlManagerV1 = null,
    ext_data_control_manager: ?*ext.DataControlManagerV1 = null,
};

pub var config: Config = undefined;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    //defer _ = gpa.deinit();

    config = try Config.init(allocator);

    var globals = Globals{};

    const display = try wl.Display.connect(null);

    const registry = try display.getRegistry();
    registry.setListener(*Globals, registryListener, &globals);

    _ = display.roundtrip();

    if (globals.ext_data_control_manager) |manager| {
        try EventLoop(ext).run(
            allocator,
            globals.seat.?,
            manager,
            display,
        );
    } else if (globals.zwlr_data_control_manager) |manager| {
        try EventLoop(zwlr).run(
            allocator,
            globals.seat.?,
            manager,
            display,
        );
    } else {
        fatal(.main, "Compositor does not implement ext-data-control or wlr-data-control.", .{});
    }
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
