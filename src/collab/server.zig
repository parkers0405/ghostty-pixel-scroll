//! Collab Server - TCP session host.
//!
//! Listens on a port, accepts guest connections, broadcasts presence
//! updates to all connected peers. One server per Ghostty session.
//! No cloud, no relay -- direct peer connection.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Profile = @import("profile.zig").Profile;
const protocol = @import("protocol.zig");
const Presence = protocol.Presence;

const log = std.log.scoped(.collab_server);

const MAX_PEERS = 8;

pub const Peer = struct {
    fd: posix.socket_t,
    profile: Profile,
    presence: Presence,
    connected: bool = true,
    read_buf: [4096]u8 = undefined,
    read_pos: u16 = 0,
};

pub const Server = struct {
    const Self = @This();

    alloc: Allocator,
    listen_fd: ?posix.socket_t = null,
    peers: [MAX_PEERS]?Peer = .{null} ** MAX_PEERS,
    peer_count: u8 = 0,
    port: u16 = 0,
    session_token: [16]u8 = undefined,
    host_profile: Profile,
    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Callback to deliver presence updates to the host renderer
    presence_callback: ?*const fn (peer_id: u8, presence: Presence, profile: Profile) void = null,
    join_callback: ?*const fn (profile: Profile) void = null,
    leave_callback: ?*const fn (peer_id: u8) void = null,

    pub fn init(alloc: Allocator, host_profile: Profile) Self {
        var server = Self{
            .alloc = alloc,
            .host_profile = host_profile,
        };
        // Generate random session token
        var prng = std.Random.DefaultPrng.init(@bitCast(std.time.timestamp()));
        prng.random().bytes(&server.session_token);
        return server;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        if (self.listen_fd) |fd| {
            posix.close(fd);
            self.listen_fd = null;
        }
        for (&self.peers) |*slot| {
            if (slot.*) |*peer| {
                posix.close(peer.fd);
                slot.* = null;
            }
        }
    }

    /// Start listening on a random available port.
    pub fn listen(self: *Self) !void {
        const addr = try std.net.Address.parseIp4("0.0.0.0", 0);
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);

        // Allow port reuse
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 8);

        // Get the assigned port
        var bound_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);
        self.port = std.mem.bigToNative(u16, bound_addr.port);
        self.listen_fd = fd;

        log.info("collab server listening on port {d}", .{self.port});
    }

    /// Start the server thread.
    pub fn start(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});
    }

    /// Stop the server thread.
    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Get the join code: token encoded as hex + port
    pub fn getJoinCode(self: *const Self, buf: *[64]u8) u8 {
        // Format: hex(token[0..4]):port  e.g. "a3f9c2d1:7777"
        const hex_chars = "0123456789abcdef";
        var pos: u8 = 0;
        for (self.session_token[0..4]) |b| {
            buf[pos] = hex_chars[b >> 4];
            buf[pos + 1] = hex_chars[b & 0x0f];
            pos += 2;
        }
        buf[pos] = ':';
        pos += 1;
        // Write port as decimal
        var port_buf: [5]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{self.port}) catch return 0;
        @memcpy(buf[pos .. pos + port_str.len], port_str);
        pos += @intCast(port_str.len);
        return pos;
    }

    fn serverLoop(self: *Self) void {
        log.info("collab server thread started", .{});

        while (!self.should_stop.load(.acquire)) {
            // Accept new connections
            self.tryAccept();

            // Poll all peers for data
            self.pollPeers();

            // Small sleep to avoid spinning (1ms)
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }

        log.info("collab server thread stopped", .{});
    }

    fn tryAccept(self: *Self) void {
        const listen_fd = self.listen_fd orelse return;

        const result = posix.accept(listen_fd, null, null, posix.SOCK.NONBLOCK) catch |err| {
            switch (err) {
                error.WouldBlock => return,
                else => {
                    log.warn("accept error: {}", .{err});
                    return;
                },
            }
        };

        // Find a free slot
        var slot_idx: ?u8 = null;
        for (&self.peers, 0..) |*slot, i| {
            if (slot.* == null) {
                slot_idx = @intCast(i);
                break;
            }
        }

        if (slot_idx) |idx| {
            self.peers[idx] = Peer{
                .fd = result,
                .profile = .{},
                .presence = .{},
            };
            self.peer_count += 1;
            log.info("new connection accepted (slot {d}, total {d})", .{ idx, self.peer_count });
        } else {
            log.warn("max peers reached, rejecting connection", .{});
            posix.close(result);
        }
    }

    fn pollPeers(self: *Self) void {
        for (&self.peers, 0..) |*slot, i| {
            const peer = &(slot.* orelse continue);
            if (!peer.connected) continue;

            // Try to read data
            const bytes_read = posix.read(peer.fd, peer.read_buf[peer.read_pos..]) catch |err| {
                switch (err) {
                    error.WouldBlock => continue,
                    else => {
                        self.removePeer(@intCast(i));
                        continue;
                    },
                }
            };

            if (bytes_read == 0) {
                self.removePeer(@intCast(i));
                continue;
            }

            peer.read_pos += @intCast(bytes_read);

            // Process complete messages
            self.processMessages(@intCast(i));
        }
    }

    fn processMessages(self: *Self, peer_idx: u8) void {
        const peer = &(self.peers[peer_idx] orelse return);
        var consumed: u16 = 0;

        while (consumed < peer.read_pos) {
            const remaining = peer.read_buf[consumed..peer.read_pos];
            const header = protocol.decodeHeader(remaining) orelse break;

            const total_len: u16 = 3 + header.payload_len;
            if (remaining.len < total_len) break; // incomplete message

            const payload = remaining[3..total_len];
            self.handleMessage(peer_idx, header.msg_type, payload);
            consumed += total_len;
        }

        // Shift remaining data to front
        if (consumed > 0 and consumed < peer.read_pos) {
            const remaining = peer.read_pos - consumed;
            std.mem.copyForwards(u8, peer.read_buf[0..remaining], peer.read_buf[consumed..peer.read_pos]);
            peer.read_pos = remaining;
        } else if (consumed >= peer.read_pos) {
            peer.read_pos = 0;
        }
    }

    fn handleMessage(self: *Self, peer_idx: u8, msg_type: protocol.MessageType, payload: []const u8) void {
        switch (msg_type) {
            .join => {
                if (payload.len < 38) return;
                var profile = Profile.deserialize(payload[0..38]);
                profile.peer_id = peer_idx + 1; // 0 is reserved for host

                const peer = &(self.peers[peer_idx] orelse return);
                peer.profile = profile;

                log.info("peer joined: {s} (id={d})", .{ profile.getName(), profile.peer_id });

                // Send welcome with assigned peer_id
                self.sendWelcome(peer_idx);

                // Broadcast join to all other peers
                self.broadcastJoin(peer_idx);

                // Notify host
                if (self.join_callback) |cb| cb(profile);
            },
            .presence => {
                if (protocol.Presence.deserialize(payload)) |presence| {
                    const peer = &(self.peers[peer_idx] orelse return);
                    peer.presence = presence;

                    // Broadcast to all OTHER peers (not sender)
                    self.broadcastPresence(peer_idx, payload);

                    // Notify host renderer
                    if (self.presence_callback) |cb| cb(
                        peer.profile.peer_id,
                        presence,
                        peer.profile,
                    );
                }
            },
            else => {},
        }
    }

    fn sendWelcome(self: *Self, peer_idx: u8) void {
        const peer = &(self.peers[peer_idx] orelse return);
        // Welcome payload: [1 assigned_peer_id][38 host_profile]
        var payload: [39]u8 = undefined;
        payload[0] = peer.profile.peer_id;
        self.host_profile.serialize(payload[1..39]);

        var msg_buf: [128]u8 = undefined;
        if (protocol.encodeMessage(.welcome, &payload, &msg_buf)) |len| {
            _ = posix.write(peer.fd, msg_buf[0..len]) catch {};
        }
    }

    fn broadcastJoin(self: *Self, new_peer_idx: u8) void {
        const new_peer = self.peers[new_peer_idx] orelse return;
        var payload: [38]u8 = undefined;
        new_peer.profile.serialize(&payload);

        var msg_buf: [128]u8 = undefined;
        const len = protocol.encodeMessage(.peer_joined, &payload, &msg_buf) orelse return;

        for (&self.peers, 0..) |*slot, i| {
            if (i == new_peer_idx) continue;
            const peer = &(slot.* orelse continue);
            if (!peer.connected) continue;
            _ = posix.write(peer.fd, msg_buf[0..len]) catch {};
        }
    }

    fn broadcastPresence(self: *Self, sender_idx: u8, payload: []const u8) void {
        var msg_buf: [512]u8 = undefined;
        const len = protocol.encodeMessage(.presence, payload, &msg_buf) orelse return;

        for (&self.peers, 0..) |*slot, i| {
            if (i == sender_idx) continue;
            const peer = &(slot.* orelse continue);
            if (!peer.connected) continue;
            _ = posix.write(peer.fd, msg_buf[0..len]) catch {};
        }
    }

    /// Broadcast the host's own presence to all connected peers.
    pub fn broadcastHostPresence(self: *Self, presence: Presence) void {
        var payload_buf: [512]u8 = undefined;
        const payload_len = presence.serialize(&payload_buf);
        if (payload_len == 0) return;

        var msg_buf: [512]u8 = undefined;
        const len = protocol.encodeMessage(.presence, payload_buf[0..payload_len], &msg_buf) orelse return;

        for (&self.peers) |*slot| {
            const peer = &(slot.* orelse continue);
            if (!peer.connected) continue;
            _ = posix.write(peer.fd, msg_buf[0..len]) catch {};
        }
    }

    fn removePeer(self: *Self, peer_idx: u8) void {
        const peer = self.peers[peer_idx] orelse return;
        log.info("peer disconnected: {s} (id={d})", .{ peer.profile.getName(), peer.profile.peer_id });

        // Notify host
        if (self.leave_callback) |cb| cb(peer.profile.peer_id);

        // Broadcast leave
        var payload: [1]u8 = .{peer.profile.peer_id};
        var msg_buf: [8]u8 = undefined;
        if (protocol.encodeMessage(.peer_left, &payload, &msg_buf)) |len| {
            for (&self.peers, 0..) |*slot, i| {
                if (i == peer_idx) continue;
                const other = &(slot.* orelse continue);
                if (!other.connected) continue;
                _ = posix.write(other.fd, msg_buf[0..len]) catch {};
            }
        }

        posix.close(peer.fd);
        self.peers[peer_idx] = null;
        if (self.peer_count > 0) self.peer_count -= 1;
    }
};
