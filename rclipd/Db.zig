const std = @import("std");
const mem = std.mem;
const allocator = std.heap.c_allocator;

const Mime = struct {
    name: [*:0]const u8,
    content: []u8,
};

pub const Entry = struct {
    timestamp: i64,
    mimes: std.ArrayListUnmanaged(Mime) = .{},
};
