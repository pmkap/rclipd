const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const allocator = std.heap.c_allocator;
const log = std.log;
const Hash = std.hash.XxHash3;

const zqlite = @import("zqlite");

const Self = @This();

conn: zqlite.Conn,
seed: u32 = 42,

pub const Blob = struct {
    id: i64 = 0,
    hash: i64,
    data: []const u8,
    size: usize,

    const create_table =
        \\CREATE TABLE IF NOT EXISTS blob (
        \\    id INTEGER PRIMARY KEY,
        \\    hash INTEGER UNIQUE NOT NULL,
        \\    data BLOB NOT NULL,
        \\    size INTEGER NOT NULL
        \\);
    ;
    const insert =
        \\INSERT INTO blob (hash, data, size)
        \\VALUES (?, ?, ?)
        \\ON CONFLICT(hash) DO UPDATE
        \\    SET size = excluded.size
        \\RETURNING id;
    ;
};

pub const Entry = struct {
    id: i64 = 0,
    content_hash: i64,
    timestamp: i64 = 0,
    preview: []const u8,

    const create_table =
        \\CREATE TABLE IF NOT EXISTS entry (
        \\    id INTEGER PRIMARY KEY,
        \\    content_hash INTEGER UNIQUE NOT NULL,
        \\    timestamp INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        \\    preview TEXT
        \\);
    ;
    const insert =
        \\INSERT INTO entry (content_hash, preview)
        \\VALUES (?, ?)
        \\ON CONFLICT(content_hash) DO UPDATE
        \\    SET timestamp = strftime('%s','now')
        \\RETURNING id;
    ;
};

pub const Mime = struct {
    entry_id: i64,
    blob_id: i64,
    name: []const u8,

    const create_table =
        \\CREATE TABLE IF NOT EXISTS mime (
        \\    entry_id INTEGER NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
        \\    blob_id INTEGER NOT NULL REFERENCES blob(id) ON DELETE CASCADE,
        \\    name TEXT NOT NULL,
        \\    PRIMARY KEY(entry_id, name)
        \\);
    ;
    const insert =
        \\INSERT INTO mime (entry_id, blob_id, name)
        \\VALUES (?, ?, ?);
    ;
};

pub fn init() !Self {
    // good idea to pass EXResCode to get extended result codes (more detailed error codes)
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;

    var conn = try zqlite.open("/tmp/rclipd.db", flags);

    try conn.exec("PRAGMA foreign_keys = ON;", .{});
    try conn.exec("PRAGMA journal_mode = WAL;", .{});

    try conn.exec("BEGIN;", .{});
    {
        try conn.exec(Blob.create_table, .{});
        try conn.exec(Entry.create_table, .{});
        try conn.exec(Mime.create_table, .{});
        try conn.exec("CREATE INDEX IF NOT EXISTS idx_blob_hash ON blob(hash);", .{});
        try conn.exec("CREATE INDEX IF NOT EXISTS idx_entry_hash ON entry(content_hash);", .{});
    }
    try conn.exec("COMMIT;", .{});

    return Self{ .conn = conn };
}

pub fn deinit(self: *Self) void {
    self.conn.close();
}

pub fn addEntry(self: *Self, blobs: std.ArrayListUnmanaged([]const u8), mimes: std.ArrayListUnmanaged([]const u8)) !void {
    var content_hasher = Hash.init(self.seed);
    var blob_ids = std.ArrayListUnmanaged(i64){};
    defer blob_ids.deinit(allocator);

    for (blobs.items, mimes.items) |data, mime| {
        const hash: i64 = @bitCast(Hash.hash(self.seed, data));

        const blob_id = self.conn.row(Blob.insert, .{ hash, data, data.len }) catch |err| {
            log.err("SQLite error {s}: {s}", .{ @errorName(err), self.conn.lastError() });
            return err;
        };
        if (blob_id) |b| {
            defer b.deinit();
            const id = b.int(0);
            try blob_ids.append(allocator, id);
            log.debug("Db: blob upserted with id {}", .{id});
        } else {
            log.err("SQLite: No blob inserted or returned", .{});
            return error.Error;
        }

        content_hasher.update(mime);
        content_hasher.update(mem.asBytes(&hash));
    }
    const content_hash: i64 = @bitCast(content_hasher.final());

    const entry_id = self.conn.row(Entry.insert, .{ content_hash, "dummy preview" }) catch |err| {
        log.debug("SQLite error {s}: {s}", .{ @errorName(err), self.conn.lastError() });
        return err;
    };
    var eid: i64 = undefined;
    if (entry_id) |e| {
        defer e.deinit();
        eid = e.int(0);
        log.debug("Db: entry upserted with id {}", .{eid});
    } else {
        log.err("SQLite: No entry inserted or returned", .{});
        return error.Error;
    }

    assert(mimes.items.len == blob_ids.items.len);
    for (blob_ids.items, mimes.items) |blob_id, mime| {
        self.conn.exec(Mime.insert, .{ eid, blob_id, mime }) catch |err| {
            log.err("SQLite error {s}: {s}", .{ @errorName(err), self.conn.lastError() });
            return err;
        };
    }
}
