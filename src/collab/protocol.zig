//! Collab Protocol - Wire format for collaborative sessions.
//!
//! Lightweight binary protocol over TCP. No JSON, no HTTP, no overhead.
//! Every message is: [1 type][2 length (big-endian)][N payload]
//!
//! Designed for <1ms encode/decode. Presence updates are ~50 bytes.

const std = @import("std");
const Profile = @import("profile.zig").Profile;

/// Message types on the wire.
pub const MessageType = enum(u8) {
    /// Client -> Server: "I want to join" (carries profile)
    join = 0x01,
    /// Server -> Client: "Welcome, here's your peer_id and all current peers"
    welcome = 0x02,
    /// Server -> All: "A new peer joined" (carries their profile)
    peer_joined = 0x03,
    /// Server -> All: "A peer left"
    peer_left = 0x04,
    /// Bidirectional: cursor position + buffer name update
    presence = 0x10,
    /// Server -> Client: session token for auth
    session_token = 0x20,
};

/// A presence update: where is this peer's cursor right now?
pub const Presence = struct {
    peer_id: u8 = 0,
    cursor_row: u32 = 0, // pos[1] — 1-based buffer line number
    cursor_col: u32 = 0, // virtcol('.') — 1-based virtual column
    mode: Mode = .normal,
    /// Buffer/file name (relative path, variable length)
    file_name: [256]u8 = .{0} ** 256,
    file_name_len: u16 = 0,

    pub const Mode = enum(u8) {
        normal = 0,
        insert = 1,
        visual = 2,
        command = 3,
        replace = 4,
    };

    pub fn getFileName(self: *const Presence) []const u8 {
        return self.file_name[0..self.file_name_len];
    }

    pub fn setFileName(self: *Presence, name: []const u8) void {
        const len: u16 = @intCast(@min(name.len, 256));
        @memcpy(self.file_name[0..len], name[0..len]);
        self.file_name_len = len;
    }

    /// Serialize presence to bytes.
    /// Layout: [1 peer_id][4 row][4 col][1 mode][2 file_len][N file] = 12 + N bytes
    pub fn serialize(self: *const Presence, buf: []u8) u16 {
        if (buf.len < 12 + self.file_name_len) return 0;
        buf[0] = self.peer_id;
        std.mem.writeInt(u32, buf[1..5], self.cursor_row, .big);
        std.mem.writeInt(u32, buf[5..9], self.cursor_col, .big);
        buf[9] = @intFromEnum(self.mode);
        std.mem.writeInt(u16, buf[10..12], self.file_name_len, .big);
        if (self.file_name_len > 0) {
            @memcpy(buf[12 .. 12 + self.file_name_len], self.file_name[0..self.file_name_len]);
        }
        return 12 + self.file_name_len;
    }

    /// Deserialize presence from bytes.
    pub fn deserialize(buf: []const u8) ?Presence {
        if (buf.len < 12) return null;
        var p = Presence{};
        p.peer_id = buf[0];
        p.cursor_row = std.mem.readInt(u32, buf[1..5], .big);
        p.cursor_col = std.mem.readInt(u32, buf[5..9], .big);
        p.mode = @enumFromInt(buf[9]);
        p.file_name_len = std.mem.readInt(u16, buf[10..12], .big);
        if (p.file_name_len > 0 and buf.len >= 12 + p.file_name_len) {
            @memcpy(p.file_name[0..p.file_name_len], buf[12 .. 12 + p.file_name_len]);
        }
        return p;
    }
};

/// Encode a message with header: [1 type][2 length][N payload]
pub fn encodeMessage(msg_type: MessageType, payload: []const u8, out: []u8) ?u16 {
    const total: u16 = @intCast(3 + payload.len);
    if (out.len < total) return null;
    out[0] = @intFromEnum(msg_type);
    std.mem.writeInt(u16, out[1..3], @intCast(payload.len), .big);
    if (payload.len > 0) {
        @memcpy(out[3 .. 3 + payload.len], payload);
    }
    return total;
}

/// Decode a message header. Returns (type, payload_length) or null if not enough data.
pub fn decodeHeader(buf: []const u8) ?struct { msg_type: MessageType, payload_len: u16 } {
    if (buf.len < 3) return null;
    const msg_type: MessageType = @enumFromInt(buf[0]);
    const payload_len = std.mem.readInt(u16, buf[1..3], .big);
    return .{ .msg_type = msg_type, .payload_len = payload_len };
}
