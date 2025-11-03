const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const log = std.log.scoped(.Db);
const Hash = std.hash.XxHash3;

const zqlite = @import("zqlite");

const Self = @This();
const Db = @This();

conn: zqlite.Conn,
seed: u32 = 42,

const Blob = struct {
    fn createTable(db: *Db) !void {
        try db.conn.exec(
            \\CREATE TABLE IF NOT EXISTS blob (
            \\    id INTEGER PRIMARY KEY,
            \\    hash INTEGER UNIQUE NOT NULL,
            \\    data BLOB NOT NULL,
            \\    size INTEGER NOT NULL
            \\);
        , .{});
    }

    fn upsert(db: *Db, hash: i64, data: []const u8) !i64 {
        const row = try db.conn.row(
            \\SELECT id FROM blob
            \\where hash = ?;
        , .{hash});
        if (row) |r| {
            defer r.deinit();
            return r.int(0);
        } else {
            try db.conn.exec(
                \\INSERT INTO blob (hash, data, size)
                \\VALUES (?, ?, ?)
            , .{ hash, data, data.len });
            const id = db.conn.lastInsertedRowId();
            log.debug("blob {} inserted", .{id});
            return id;
        }
    }
};

const Entry = struct {
    fn createTable(db: *Db) !void {
        try db.conn.exec(
            \\CREATE TABLE IF NOT EXISTS entry (
            \\    id INTEGER PRIMARY KEY,
            \\    content_hash INTEGER UNIQUE NOT NULL,
            \\    timestamp INTEGER NOT NULL DEFAULT (strftime('%s','now')),
            \\    preview TEXT
            \\);
        , .{});
    }

    const UpsertResult = struct {
        id: i64,
        updated: bool,
    };

    fn upsert(db: *Db, content_hash: i64, preview: []const u8) !UpsertResult {
        const row = try db.conn.row(
            \\SELECT id FROM entry
            \\WHERE content_hash = ?;
        , .{content_hash});
        if (row) |r| {
            defer r.deinit();
            const id = r.int(0);
            try db.conn.exec(
                \\UPDATE entry
                \\SET timestamp = strftime('%s','now'),
                \\    preview = ?
                \\WHERE id = ?;
            , .{ preview, id });
            log.debug("entry {} updated", .{id});
            return .{ .id = id, .updated = true };
        } else {
            try db.conn.exec(
                \\INSERT INTO entry (content_hash, preview)
                \\VALUES (?, ?)
            , .{ content_hash, preview });
            const id = db.conn.lastInsertedRowId();
            log.debug("entry {} inserted", .{id});
            return .{ .id = id, .updated = false };
        }
    }

    /// This creates a table of ids and previews
    /// \n and \t are used as delimiter so it can be used with with a dmenu-like tool
    /// Caller owns the returned memory
    fn listAlloc(allocator: mem.Allocator, db: Db) ![]const u8 {
        var rows = try db.conn.rows(
            \\SELECT id, preview FROM entry
            \\ORDER BY timestamp DESC;
        , .{});
        defer rows.deinit();

        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(allocator);

        while (rows.next()) |row| {
            try std.fmt.format(result.writer(allocator), "{}\t{s}\n", .{
                row.int(0),
                row.text(1),
            });
        }
        if (rows.err) |err| return err;

        return result.toOwnedSlice(allocator);
    }
};

const Mime = struct {
    fn createTable(db: *Db) !void {
        try db.conn.exec(
            \\CREATE TABLE IF NOT EXISTS mime (
            \\    entry_id INTEGER NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
            \\    blob_id INTEGER NOT NULL REFERENCES blob(id),
            \\    name TEXT NOT NULL,
            \\    PRIMARY KEY(entry_id, blob_id, name)
            \\);
        , .{});
    }

    fn insert(db: *Db, entry_id: i64, blob_id: i64, name: []const u8) !void {
        try db.conn.exec(
            \\INSERT INTO mime (entry_id, blob_id, name)
            \\VALUES (?, ?, ?)
            \\ON CONFLICT DO NOTHING;
        , .{ entry_id, blob_id, name });
        log.debug("mime inserted", .{});
    }
};

pub fn init() !Self {
    _ = std.c.umask(0o077);

    // good idea to pass EXResCode to get extended result codes (more detailed error codes)
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;

    var conn = try zqlite.open("/tmp/rclipd.db", flags);
    var self = Self{ .conn = conn };

    try conn.exec("PRAGMA foreign_keys = ON;", .{});
    try conn.exec("PRAGMA journal_mode = WAL;", .{});

    try conn.exec("BEGIN;", .{});
    {
        try Blob.createTable(&self);
        try Entry.createTable(&self);
        try Mime.createTable(&self);
    }
    try conn.exec("COMMIT;", .{});

    return self;
}

pub fn deinit(self: Self) void {
    self.conn.close();
}

pub fn listAlloc(self: Self, allocator: mem.Allocator) ![]const u8 {
    return Entry.listAlloc(allocator, self);
}

pub fn addEntry(
    self: *Self,
    allocator: mem.Allocator,
    blobs: std.ArrayListUnmanaged(?[]const u8),
    mimes: std.ArrayListUnmanaged([]const u8),
) !void {
    try self.conn.exec("BEGIN IMMEDIATE;", .{});
    errdefer self.conn.exec("ROLLBACK;", .{}) catch {};
    {
        var blob_hashes = std.ArrayListUnmanaged(i64){};
        defer blob_hashes.deinit(allocator);

        var content_hasher = Hash.init(self.seed);
        var preview: []const u8 = "no preview";

        for (blobs.items, mimes.items) |data, mime| {
            const hash: i64 = @bitCast(Hash.hash(self.seed, data.?));
            try blob_hashes.append(allocator, hash);

            content_hasher.update(mime);
            content_hasher.update(mem.asBytes(&hash));
            if (std.ascii.startsWithIgnoreCase(mime, "text/plain")) {
                preview = try generatePreviewAlloc(allocator, data.?); // TODO: cleanup?
            }
        }
        const content_hash: i64 = @bitCast(content_hasher.final());

        const entry_result = Entry.upsert(self, content_hash, preview) catch |err| {
            log.err("SQLite error when upserting entry {s}: {s}", .{ @errorName(err), self.conn.lastError() });
            return err;
        };

        var blob_ids = std.ArrayListUnmanaged(i64){};
        defer blob_ids.deinit(allocator);

        if (!entry_result.updated) {
            for (blobs.items, blob_hashes.items) |data, hash| {
                const blob_id = Blob.upsert(self, hash, data.?) catch |err| {
                    log.err("SQLite error when upserting blob{s}: {s}", .{ @errorName(err), self.conn.lastError() });
                    return err;
                };
                try blob_ids.append(allocator, blob_id);
            }

            assert(mimes.items.len == blob_ids.items.len);
            for (blob_ids.items, mimes.items) |blob_id, mime| {
                Mime.insert(self, entry_result.id, blob_id, mime) catch |err| {
                    log.err("SQLite error when inserting mime {s}: {s}", .{ @errorName(err), self.conn.lastError() });
                    return err;
                };
            }
        }
    }
    try self.conn.exec("COMMIT;", .{});
}

fn generatePreviewAlloc(allocator: mem.Allocator, data: []const u8) ![]const u8 {
    const slice = data[0..@min(data.len, 100)];

    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);

    for (slice) |c| {
        switch (c) {
            '\n', '\t' => try result.append(allocator, ' '),
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}
