const std = @import("std");
const mem = std.mem;
const allocator = std.heap.c_allocator;

const Blob = model.Blob;
const Mime = model.Mime;

pub const model = struct {
    pub const Blob = struct {
        id: i64 = 0,
        hash: ?u64 = null,
        data: []const u8,
        size: usize,
    };

    pub const Entry = struct {
        id: i64,
        content_hash: [32]u8,
        timestamp: i64,
        preview: []const u8,
    };

    pub const Mime = struct {
        entry_id: ?i64 = null,
        mime: []const u8,
        blob_id: ?i64 = null,
    };
};

pub fn addEntry(blobs: std.ArrayListUnmanaged(Blob), mimes: std.ArrayListUnmanaged(Mime)) !void {
    _ = blobs;
    _ = mimes;
}
