const std = @import("std");

const zqlite = @import("zqlite");

const Self = @This();

const Blob = model.Blob;
const Mime = model.Mime;

conn: zqlite.Conn,

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

pub fn init() !Self {
    // good idea to pass EXResCode to get extended result codes (more detailed error codes)
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;

    var conn = try zqlite.open("/tmp/rclipd.db", flags);

    try conn.exec("PRAGMA foreign_keys = ON;", .{});
    try conn.exec("PRAGMA journal_mode = WAL;", .{});

    try conn.exec("BEGIN;", .{});
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS blob (
        \\    id INTEGER PRIMARY KEY,
        \\    hash INTEGER UNIQUE NOT NULL,
        \\    data BLOB NOT NULL,
        \\    size INTEGER NOT NULL
        \\);
    , .{});

    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS entry (
        \\    id INTEGER PRIMARY KEY,
        \\    content_hash BLOB UNIQUE NOT NULL,
        \\    timestamp INTEGER NOT NULL,
        \\    preview TEXT
        \\);
    , .{});

    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS mime (
        \\    entry_id INTEGER NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
        \\    name TEXT NOT NULL,
        \\    blob_id INTEGER NOT NULL REFERENCES blob(id) ON DELETE CASCADE,
        \\    PRIMARY KEY(entry_id, name)
        \\);
    , .{});

    try conn.exec("CREATE INDEX IF NOT EXISTS idx_blob_hash ON blob(hash);", .{});
    try conn.exec("CREATE INDEX IF NOT EXISTS idx_entry_hash ON entry(content_hash);", .{});
    try conn.exec("COMMIT;", .{});

    return Self{ .conn = conn };
}

pub fn deinit(self: *Self) void {
    self.conn.close();
}

pub fn addEntry(_: *Self, blobs: std.ArrayListUnmanaged(Blob), mimes: std.ArrayListUnmanaged(Mime)) !void {
    _ = blobs;
    _ = mimes;
}
