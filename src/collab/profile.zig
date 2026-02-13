//! Collab Profile - Identity for collaborative sessions.
//!
//! A profile is just a name and a color. No accounts, no sign-up.
//! The name floats above your cursor. The color tints your ghost cursor.
//! Loaded from ghostty config: collab-name, collab-color.

const std = @import("std");

pub const Profile = struct {
    /// Display name (max 32 bytes). Shows as a label above the cursor.
    name: [32]u8 = .{0} ** 32,
    name_len: u8 = 0,

    /// Cursor color as 0xRRGGBB. Other participants see this.
    color: u32 = 0x7aa2f7,

    /// Unique session ID assigned on connect (0 = not connected).
    peer_id: u8 = 0,

    pub fn setName(self: *Profile, src: []const u8) void {
        const len: u8 = @intCast(@min(src.len, 32));
        @memcpy(self.name[0..len], src[0..len]);
        self.name_len = len;
    }

    pub fn getName(self: *const Profile) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setColor(self: *Profile, r: u8, g: u8, b: u8) void {
        self.color = (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    }

    /// Create a profile from ghostty config values.
    pub fn fromConfig(name: []const u8, color_r: u8, color_g: u8, color_b: u8) Profile {
        var p = Profile{};
        if (name.len > 0) {
            p.setName(name);
        } else {
            // Fallback to system username
            const user = std.posix.getenv("USER") orelse
                std.posix.getenv("USERNAME") orelse "anon";
            p.setName(user);
        }
        p.setColor(color_r, color_g, color_b);
        return p;
    }

    /// Serialize to bytes for network transmission (fixed 38 bytes).
    /// Layout: [1 peer_id][1 name_len][32 name][4 color] = 38 bytes
    pub fn serialize(self: *const Profile, buf: *[38]u8) void {
        buf[0] = self.peer_id;
        buf[1] = self.name_len;
        @memcpy(buf[2..34], &self.name);
        buf[34] = @intCast((self.color >> 24) & 0xFF);
        buf[35] = @intCast((self.color >> 16) & 0xFF);
        buf[36] = @intCast((self.color >> 8) & 0xFF);
        buf[37] = @intCast(self.color & 0xFF);
    }

    /// Deserialize from bytes.
    pub fn deserialize(buf: *const [38]u8) Profile {
        var p = Profile{};
        p.peer_id = buf[0];
        p.name_len = buf[1];
        @memcpy(&p.name, buf[2..34]);
        p.color = (@as(u32, buf[34]) << 24) |
            (@as(u32, buf[35]) << 16) |
            (@as(u32, buf[36]) << 8) |
            @as(u32, buf[37]);
        return p;
    }
};
