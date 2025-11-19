const std = @import("std");

pub fn fatal(comptime scope: anytype, comptime format: []const u8, args: anytype) noreturn {
    std.log.scoped(scope).err(format, args);
    std.posix.exit(1);
}
