//! Collab - Multiplayer terminal sessions.
//!
//! One person hosts (ghostty-share), others join (ghostty-join).
//! Everyone gets their own Neovim with their own config, but they
//! see each other's cursors as colored ghost cursors with name labels.
//! Spring-animated, same physics as the main cursor.
//!
//! Architecture:
//! - Host runs a Server (TCP listener)
//! - Guests run a Client (TCP connection)
//! - Both share a CollabState that holds peer cursor positions
//! - The renderer reads peer cursors from CollabState each frame
//! - Neovim sends cursor updates via injected Lua (ghostty_presence RPC)

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Profile = @import("profile.zig").Profile;
pub const protocol = @import("protocol.zig");
pub const Server = @import("server.zig").Server;
pub const Client = @import("client.zig").Client;
const Presence = protocol.Presence;

const log = std.log.scoped(.collab);

pub const MAX_PEERS = 8;

/// Shared state read by the renderer each frame.
/// Thread-safe: collab I/O threads write, renderer reads.
pub const CollabState = struct {
    const Self = @This();

    mutex: std.Thread.Mutex = .{},

    /// Peer cursors visible this frame.
    peers: [MAX_PEERS]?PeerCursor = .{null} ** MAX_PEERS,
    peer_count: u8 = 0,

    /// Our own profile
    local_profile: Profile = .{},

    /// Are we hosting or connected?
    role: Role = .none,

    /// The server (if hosting) or client (if guest)
    server: ?*Server = null,
    client: ?*Client = null,

    alloc: Allocator,

    pub const Role = enum {
        none,
        host,
        guest,
    };

    /// A peer's cursor as seen by the renderer.
    pub const PeerCursor = struct {
        peer_id: u8 = 0,
        name: [32]u8 = .{0} ** 32,
        name_len: u8 = 0,
        color: u32 = 0x7aa2f7,

        /// Buffer position: 1-based line (pos[1]) and virtual column (virtcol)
        cursor_row: u32 = 0,
        cursor_col: u32 = 0,

        /// Which file they're in (for "same buffer" detection)
        file_name: [256]u8 = .{0} ** 256,
        file_name_len: u16 = 0,

        /// Vim mode
        mode: Presence.Mode = .normal,

        /// Is this cursor in the same buffer as us?
        same_buffer: bool = false,

        pub fn getName(self: *const PeerCursor) []const u8 {
            return self.name[0..self.name_len];
        }

        pub fn getFileName(self: *const PeerCursor) []const u8 {
            return self.file_name[0..self.file_name_len];
        }
    };

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.stopSession();
    }

    /// Start hosting a session.
    pub fn startHost(self: *Self, profile: Profile) !void {
        if (self.role != .none) return error.AlreadyInSession;

        self.local_profile = profile;
        self.local_profile.peer_id = 0; // host is always 0

        var server = try self.alloc.create(Server);
        server.* = Server.init(self.alloc, self.local_profile);
        server.presence_callback = &Self.onPresenceUpdate;
        server.join_callback = &Self.onPeerJoined;
        server.leave_callback = &Self.onPeerLeft;

        try server.listen();
        try server.start();

        self.server = server;
        self.role = .host;

        log.info("hosting collab session on port {d}", .{server.port});
    }

    /// Join an existing session.
    pub fn joinSession(self: *Self, profile: Profile, host: []const u8, port: u16) !void {
        if (self.role != .none) return error.AlreadyInSession;

        self.local_profile = profile;

        var client = try self.alloc.create(Client);
        client.* = Client.init(self.alloc, profile);
        client.presence_callback = &Self.onPresenceUpdate;
        client.join_callback = &Self.onPeerJoined;
        client.leave_callback = &Self.onPeerLeft;

        try client.connect(host, port);
        try client.start();

        self.client = client;
        self.role = .guest;

        log.info("joined collab session at {s}:{d}", .{ host, port });
    }

    /// Stop the current session.
    pub fn stopSession(self: *Self) void {
        if (self.server) |s| {
            s.deinit();
            self.alloc.destroy(s);
            self.server = null;
        }
        if (self.client) |c| {
            c.deinit();
            self.alloc.destroy(c);
            self.client = null;
        }
        self.role = .none;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.peers = .{null} ** MAX_PEERS;
        self.peer_count = 0;
    }

    /// Send our cursor position to all peers. Called from Neovim presence hook.
    pub fn sendPresence(self: *Self, presence: Presence) void {
        switch (self.role) {
            .host => if (self.server) |s| s.broadcastHostPresence(presence),
            .guest => if (self.client) |c| c.sendPresence(presence),
            .none => {},
        }
    }

    /// Get a snapshot of peer cursors for the renderer. Lock-free read.
    pub fn getPeers(self: *Self, out: *[MAX_PEERS]?PeerCursor) u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        out.* = self.peers;
        return self.peer_count;
    }

    /// Get the join code (host only).
    pub fn getJoinCode(self: *Self, buf: *[64]u8) u8 {
        if (self.server) |s| return s.getJoinCode(buf);
        return 0;
    }

    // --- Callbacks (called from server/client I/O threads) ---

    // Note: These are standalone functions because Zig function pointers
    // can't capture `self`. We use a thread-local or global for the instance.
    // For now, we use a simple global since there's one CollabState per app.

    pub var global_instance: ?*Self = null;

    pub fn setGlobalInstance(self: *Self) void {
        global_instance = self;
    }

    fn onPresenceUpdate(peer_id: u8, presence: Presence, profile: Profile) void {
        const self = global_instance orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find or create slot for this peer
        var slot_idx: ?usize = null;
        for (&self.peers, 0..) |*slot, i| {
            if (slot.*) |*existing| {
                if (existing.peer_id == peer_id) {
                    slot_idx = i;
                    break;
                }
            }
        }

        if (slot_idx == null) {
            // Find empty slot
            for (&self.peers, 0..) |*slot, i| {
                if (slot.* == null) {
                    slot_idx = i;
                    self.peer_count += 1;
                    break;
                }
            }
        }

        const idx = slot_idx orelse return;
        const cursor = &self.peers[idx];
        if (cursor.* == null) {
            cursor.* = PeerCursor{};
        }
        const c = &(cursor.*.?);
        c.peer_id = peer_id;
        c.cursor_row = presence.cursor_row;
        c.cursor_col = presence.cursor_col;
        c.mode = presence.mode;
        const file_len: u8 = @intCast(@min(presence.file_name_len, 256));
        c.file_name_len = file_len;
        if (file_len > 0) {
            @memcpy(c.file_name[0..file_len], presence.file_name[0..file_len]);
        }

        // Copy profile info
        c.color = profile.color;
        c.name_len = profile.name_len;
        @memcpy(&c.name, &profile.name);
    }

    fn onPeerJoined(profile: Profile) void {
        const self = global_instance orelse return;
        _ = self;
        log.info("peer joined session: {s}", .{profile.getName()});
    }

    fn onPeerLeft(peer_id: u8) void {
        const self = global_instance orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.peers) |*slot| {
            if (slot.*) |existing| {
                if (existing.peer_id == peer_id) {
                    slot.* = null;
                    if (self.peer_count > 0) self.peer_count -= 1;
                    break;
                }
            }
        }
    }
};
