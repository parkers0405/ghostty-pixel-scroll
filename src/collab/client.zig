//! Collab Client - Connects to a session host.
//!
//! Sends our profile, receives presence updates from all peers,
//! sends our own presence updates. Runs on a dedicated I/O thread.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Profile = @import("profile.zig").Profile;
const protocol = @import("protocol.zig");
const Presence = protocol.Presence;

const log = std.log.scoped(.collab_client);

const MAX_PEERS = 8;

pub const Client = struct {
    const Self = @This();

    alloc: Allocator,
    socket: ?posix.socket_t = null,
    profile: Profile,
    my_peer_id: u8 = 0,

    /// All known peers (indexed by peer_id - 1)
    peers: [MAX_PEERS]?PeerInfo = .{null} ** MAX_PEERS,
    host_profile: Profile = .{},

    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    read_buf: [4096]u8 = undefined,
    read_pos: u16 = 0,

    /// Callbacks for the renderer
    presence_callback: ?*const fn (peer_id: u8, presence: Presence, profile: Profile) void = null,
    join_callback: ?*const fn (profile: Profile) void = null,
    leave_callback: ?*const fn (peer_id: u8) void = null,

    pub const PeerInfo = struct {
        profile: Profile,
        presence: Presence,
    };

    pub fn init(alloc: Allocator, profile: Profile) Self {
        return .{
            .alloc = alloc,
            .profile = profile,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        if (self.socket) |fd| {
            posix.close(fd);
            self.socket = null;
        }
    }

    /// Connect to a host at address:port.
    pub fn connect(self: *Self, host: []const u8, port: u16) !void {
        log.info("connecting to collab session at {s}:{d}", .{ host, port });

        const addr = try std.net.Address.resolveIp(host, port);
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        try posix.connect(fd, &addr.any, addr.getOsSockLen());

        // Set non-blocking after connect
        if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch {};
        } else |_| {}

        self.socket = fd;

        // Send join message with our profile
        self.sendJoin();

        log.info("connected to collab session", .{});
    }

    /// Start the client I/O thread.
    pub fn start(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, clientLoop, .{self});
    }

    /// Stop the client I/O thread.
    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Send our presence update to the host.
    pub fn sendPresence(self: *Self, presence: Presence) void {
        const fd = self.socket orelse return;
        var payload_buf: [512]u8 = undefined;
        const payload_len = presence.serialize(&payload_buf);
        if (payload_len == 0) return;

        var msg_buf: [512]u8 = undefined;
        const len = protocol.encodeMessage(.presence, payload_buf[0..payload_len], &msg_buf) orelse return;
        _ = posix.write(fd, msg_buf[0..len]) catch {};
    }

    fn sendJoin(self: *Self) void {
        const fd = self.socket orelse return;
        var payload: [38]u8 = undefined;
        self.profile.serialize(&payload);

        var msg_buf: [128]u8 = undefined;
        if (protocol.encodeMessage(.join, &payload, &msg_buf)) |len| {
            _ = posix.write(fd, msg_buf[0..len]) catch {};
        }
    }

    fn clientLoop(self: *Self) void {
        log.info("collab client thread started", .{});
        const fd = self.socket orelse return;

        while (!self.should_stop.load(.acquire)) {
            var fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const poll_result = posix.poll(&fds, 10) catch 0;

            if (poll_result > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
                const bytes_read = posix.read(fd, self.read_buf[self.read_pos..]) catch |err| {
                    switch (err) {
                        error.WouldBlock => continue,
                        else => {
                            log.info("connection lost", .{});
                            return;
                        },
                    }
                };

                if (bytes_read == 0) {
                    log.info("server disconnected", .{});
                    return;
                }

                self.read_pos += @intCast(bytes_read);
                self.processMessages();
            } else if (poll_result > 0 and (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                log.info("server connection closed", .{});
                return;
            }
        }

        log.info("collab client thread stopped", .{});
    }

    fn processMessages(self: *Self) void {
        var consumed: u16 = 0;

        while (consumed < self.read_pos) {
            const remaining = self.read_buf[consumed..self.read_pos];
            const header = protocol.decodeHeader(remaining) orelse break;

            const total_len: u16 = 3 + header.payload_len;
            if (remaining.len < total_len) break;

            const payload = remaining[3..total_len];
            self.handleMessage(header.msg_type, payload);
            consumed += total_len;
        }

        // Shift remaining data
        if (consumed > 0 and consumed < self.read_pos) {
            const remaining_len = self.read_pos - consumed;
            std.mem.copyForwards(u8, self.read_buf[0..remaining_len], self.read_buf[consumed..self.read_pos]);
            self.read_pos = remaining_len;
        } else if (consumed >= self.read_pos) {
            self.read_pos = 0;
        }
    }

    fn handleMessage(self: *Self, msg_type: protocol.MessageType, payload: []const u8) void {
        switch (msg_type) {
            .welcome => {
                if (payload.len < 39) return;
                self.my_peer_id = payload[0];
                self.profile.peer_id = payload[0];
                self.host_profile = Profile.deserialize(payload[1..39]);
                log.info("welcome! assigned peer_id={d}, host={s}", .{
                    self.my_peer_id,
                    self.host_profile.getName(),
                });
            },
            .peer_joined => {
                if (payload.len < 38) return;
                const profile = Profile.deserialize(payload[0..38]);
                if (profile.peer_id > 0 and profile.peer_id <= MAX_PEERS) {
                    self.peers[profile.peer_id - 1] = .{
                        .profile = profile,
                        .presence = .{},
                    };
                }
                log.info("peer joined: {s} (id={d})", .{ profile.getName(), profile.peer_id });
                if (self.join_callback) |cb| cb(profile);
            },
            .peer_left => {
                if (payload.len < 1) return;
                const peer_id = payload[0];
                if (peer_id > 0 and peer_id <= MAX_PEERS) {
                    self.peers[peer_id - 1] = null;
                }
                log.info("peer left (id={d})", .{peer_id});
                if (self.leave_callback) |cb| cb(peer_id);
            },
            .presence => {
                if (protocol.Presence.deserialize(payload)) |presence| {
                    // Find the profile for this peer
                    var profile: Profile = .{};
                    if (presence.peer_id == 0) {
                        // Host presence
                        profile = self.host_profile;
                    } else if (presence.peer_id > 0 and presence.peer_id <= MAX_PEERS) {
                        if (self.peers[presence.peer_id - 1]) |peer_info| {
                            profile = peer_info.profile;
                        }
                        self.peers[presence.peer_id - 1] = .{
                            .profile = profile,
                            .presence = presence,
                        };
                    }
                    if (self.presence_callback) |cb| cb(presence.peer_id, presence, profile);
                }
            },
            else => {},
        }
    }
};
