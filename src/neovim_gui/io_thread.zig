//! Neovim I/O Thread
//!
//! This thread handles all communication with Neovim asynchronously,
//! allowing the render thread to run at full 165Hz without blocking.
//!
//! Architecture:
//! - I/O thread continuously reads from Neovim socket
//! - Parses msgpack-rpc messages and queues UI events
//! - Render thread polls events without blocking
//! - Input is sent via a separate write queue

const std = @import("std");
const Allocator = std.mem.Allocator;
const znvim = @import("znvim");
const msgpack = znvim.msgpack;
const protocol = znvim.protocol;
const encoder = protocol.encoder;
const decoder = protocol.decoder;
const Payload = msgpack.Value; // znvim uses Value, which is msgpack.Payload

const log = std.log.scoped(.neovim_io);

/// Thread-safe event queue for passing UI events from I/O thread to render thread
pub const EventQueue = struct {
    const Self = @This();

    mutex: std.Thread.Mutex = .{},
    events: std.ArrayListUnmanaged(Event) = .empty,
    alloc: Allocator,

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        // Free any remaining events
        for (self.events.items) |*event| {
            event.deinit(self.alloc);
        }
        self.events.deinit(self.alloc);
    }

    pub fn push(self: *Self, event: Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.events.append(self.alloc, event);
    }

    pub fn pushBatch(self: *Self, events: []const Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.events.appendSlice(self.alloc, events);
    }

    /// Pop all events (called from render thread)
    pub fn popAll(self: *Self, out: *std.ArrayListUnmanaged(Event)) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Swap buffers - render thread gets all events, we get empty list
        const tmp = out.*;
        out.* = self.events;
        self.events = tmp;
        self.events.clearRetainingCapacity();
    }

    pub fn isEmpty(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.items.len == 0;
    }
};

/// UI Event from Neovim
pub const Event = union(enum) {
    grid_resize: GridResize,
    grid_line: GridLine,
    grid_scroll: GridScroll,
    grid_clear: u64, // grid id
    grid_cursor_goto: GridCursorGoto,
    win_pos: WinPos,
    win_float_pos: WinFloatPos, // Floating windows (noice, which-key, etc.)
    win_viewport: WinViewport,
    win_hide: u64, // grid id
    win_close: u64, // grid id
    hl_attr_define: HlAttrDefine,
    default_colors_set: DefaultColors,
    mode_info_set: ModeInfoSet,
    mode_change: ModeChange,
    flush,
    option_set: OptionSet,

    pub const GridResize = struct {
        grid: u64,
        width: u64,
        height: u64,
    };

    pub const GridLine = struct {
        grid: u64,
        row: u64,
        col_start: u64,
        cells: []Cell,

        pub fn deinit(self: *GridLine, alloc: Allocator) void {
            for (self.cells) |*cell| {
                alloc.free(cell.text);
            }
            alloc.free(self.cells);
        }
    };

    pub const Cell = struct {
        text: []const u8,
        hl_id: u64 = 0,
        repeat: u64 = 1,
    };

    pub const GridScroll = struct {
        grid: u64,
        top: u64,
        bot: u64,
        left: u64,
        right: u64,
        rows: i64,
        cols: i64,
    };

    pub const GridCursorGoto = struct {
        grid: u64,
        row: u64,
        col: u64,
    };

    pub const WinPos = struct {
        grid: u64,
        win: u64,
        start_row: u64,
        start_col: u64,
        width: u64,
        height: u64,
    };

    /// Floating window position (noice, which-key, completion menus, etc.)
    pub const WinFloatPos = struct {
        grid: u64,
        win: u64,
        anchor: Anchor,
        anchor_grid: u64,
        anchor_row: f32,
        anchor_col: f32,
        focusable: bool,
        zindex: u64,

        pub const Anchor = enum {
            NW, // top-left
            NE, // top-right
            SW, // bottom-left
            SE, // bottom-right
        };
    };

    pub const WinViewport = struct {
        grid: u64,
        win: u64,
        topline: u64,
        botline: u64,
        curline: u64,
        curcol: u64,
        line_count: u64,
        scroll_delta: i64,
    };

    pub const HlAttrDefine = struct {
        id: u64,
        attr: HlAttr,
    };

    pub const HlAttr = struct {
        foreground: ?u32 = null,
        background: ?u32 = null,
        special: ?u32 = null,
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        undercurl: bool = false,
        strikethrough: bool = false,
        reverse: bool = false,
        blend: u8 = 0,
    };

    pub const DefaultColors = struct {
        fg: u32,
        bg: u32,
        sp: u32,
    };

    pub const ModeInfoSet = struct {
        cursor_style_enabled: bool,
        // Simplified - we'll parse mode info as needed
    };

    pub const ModeChange = struct {
        mode_idx: u64,
    };

    pub const OptionSet = struct {
        // We ignore most options for now
    };

    pub fn deinit(self: *Event, alloc: Allocator) void {
        switch (self.*) {
            .grid_line => |*gl| gl.deinit(alloc),
            else => {},
        }
    }
};

/// Connection mode for Neovim
pub const ConnectionMode = enum {
    socket,
    embedded,
};

/// Neovim I/O Thread
pub const IoThread = struct {
    const Self = @This();

    alloc: Allocator,

    // Connection mode
    mode: ConnectionMode,

    // Socket connection (for socket mode)
    socket: ?std.net.Stream = null,
    socket_path: ?[]const u8 = null,

    // Embedded Neovim process (for embedded mode)
    child: ?std.process.Child = null,
    stdin_file: ?std.fs.File = null,
    stdout_file: ?std.fs.File = null,

    // Read buffer for msgpack parsing
    read_buffer: std.ArrayListUnmanaged(u8) = .empty,

    // Event queue (shared with render thread)
    event_queue: *EventQueue,

    // Pointer to parent NeovimGui for render wakeup - forward declare type
    nvim_gui: ?*anyopaque = null,

    // Write queue for sending input to Neovim
    write_mutex: std.Thread.Mutex = .{},
    write_queue: std.ArrayListUnmanaged([]const u8) = .empty,

    // Thread control
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    // Message ID for RPC requests
    next_msgid: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Pending responses (for blocking requests during init)
    response_mutex: std.Thread.Mutex = .{},
    response_cond: std.Thread.Condition = .{},
    pending_response: ?Payload = null,
    pending_msgid: ?u32 = null,

    /// Initialize for socket connection
    pub fn init(alloc: Allocator, socket_path: []const u8, event_queue: *EventQueue) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .mode = .socket,
            .socket_path = try alloc.dupe(u8, socket_path),
            .event_queue = event_queue,
        };
        return self;
    }

    /// Initialize for embedded Neovim
    pub fn initEmbedded(alloc: Allocator, event_queue: *EventQueue) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .mode = .embedded,
            .event_queue = event_queue,
        };
        return self;
    }

    /// Set the parent NeovimGui pointer for render wakeup
    pub fn setRenderWakeup(self: *Self, nvim_gui: *anyopaque) void {
        self.nvim_gui = nvim_gui;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        switch (self.mode) {
            .socket => {
                if (self.socket) |socket| {
                    socket.close();
                }
                if (self.socket_path) |path| {
                    self.alloc.free(path);
                }
            },
            .embedded => {
                // Close pipes
                if (self.stdin_file) |f| f.close();
                if (self.stdout_file) |f| f.close();

                // Terminate child process
                if (self.child) |*child| {
                    _ = child.kill() catch {};
                    _ = child.wait() catch {};
                }
            },
        }

        // Free write queue
        self.write_mutex.lock();
        for (self.write_queue.items) |msg| {
            self.alloc.free(msg);
        }
        self.write_queue.deinit(self.alloc);
        self.write_mutex.unlock();

        self.read_buffer.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn connect(self: *Self) !void {
        const posix = std.posix;
        switch (self.mode) {
            .socket => {
                const path = self.socket_path orelse return error.NoSocketPath;
                log.info("Connecting to Neovim at: {s}", .{path});
                self.socket = try std.net.connectUnixSocket(path);

                // Set socket to non-blocking mode so reads don't block the I/O thread
                const socket = self.socket.?;
                if (posix.fcntl(socket.handle, posix.F.GETFL, 0)) |flags| {
                    _ = posix.fcntl(
                        socket.handle,
                        posix.F.SETFL,
                        flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
                    ) catch {};
                } else |_| {}
                log.info("Connected to Neovim (non-blocking)", .{});
            },
            .embedded => {
                log.info("Spawning embedded Neovim with user config", .{});

                // Spawn nvim --headless --embed
                // Note: --embed mode still loads user config (init.lua/init.vim)
                // unlike --headless alone which skips some initialization
                var child = std.process.Child.init(&.{ "nvim", "--embed" }, self.alloc);
                child.stdin_behavior = .Pipe;
                child.stdout_behavior = .Pipe;
                child.stderr_behavior = .Inherit;

                try child.spawn();

                // Store the pipes
                self.stdin_file = child.stdin;
                self.stdout_file = child.stdout;
                child.stdin = null;
                child.stdout = null;

                // Set stdout to non-blocking mode
                if (self.stdout_file) |f| {
                    if (posix.fcntl(f.handle, posix.F.GETFL, 0)) |flags| {
                        _ = posix.fcntl(
                            f.handle,
                            posix.F.SETFL,
                            flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
                        ) catch {};
                    } else |_| {}
                }

                self.child = child;
                log.info("Neovim spawned successfully (non-blocking)", .{});
            },
        }
    }

    pub fn start(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, ioThreadMain, .{self});
    }

    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// Send input directly to Neovim - immediate, no queuing (called from main thread)
    /// This is the fast path for keyboard input - zero latency
    pub fn sendInputDirect(self: *Self, keys: []const u8) !void {
        // Encode nvim_input notification
        const encoded = try self.encodeInputNotification(keys);
        defer self.alloc.free(encoded);

        // Write directly - no mutex needed for socket writes (atomic at OS level for small writes)
        try self.writeData(encoded);
    }

    /// Queue input to be sent to Neovim (called from main/render thread)
    /// Use sendInputDirect for keyboard input - this is for batch operations
    pub fn queueInput(self: *Self, keys: []const u8) !void {
        // Encode nvim_input notification
        const encoded = try self.encodeInputNotification(keys);

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.write_queue.append(self.alloc, encoded);
    }

    /// Send nvim_ui_attach (blocking, used during init)
    pub fn attachUi(self: *Self, width: u32, height: u32) !void {
        log.info("Attaching UI: {}x{}", .{ width, height });

        const msgid = self.next_msgid.fetchAdd(1, .monotonic);

        // Build the request using znvim helpers
        // Note: When passing a Value to msgpack.array, it's NOT cloned - it's used directly
        // So we should NOT free opts separately - it will be freed when params is freed
        const opts = try msgpack.object(self.alloc, .{
            .rgb = true,
            .ext_linegrid = true,
            .ext_multigrid = true,
        });
        // opts is now owned by params - do NOT free it

        const params = try msgpack.array(self.alloc, .{
            @as(u64, width),
            @as(u64, height),
            opts,
        });
        defer params.free(self.alloc);

        const request = protocol.message.Request{
            .msgid = msgid,
            .method = "nvim_ui_attach",
            .params = params,
        };

        const encoded = try encoder.encodeRequest(self.alloc, request);
        defer self.alloc.free(encoded);

        // Send and wait for response
        try self.writeData(encoded);

        // Wait for response (blocking)
        self.response_mutex.lock();
        defer self.response_mutex.unlock();

        self.pending_msgid = msgid;
        while (self.pending_msgid != null) {
            // Process incoming messages until we get our response
            self.response_mutex.unlock();
            self.readAndProcessMessages() catch {};
            self.response_mutex.lock();
        }

        if (self.pending_response) |resp| {
            resp.free(self.alloc);
            self.pending_response = null;
        }

        log.info("UI attached successfully", .{});
    }

    /// Send nvim_ui_try_resize (non-blocking)
    pub fn resizeUi(self: *Self, width: u32, height: u32) !void {
        log.debug("Resizing UI: {}x{}", .{ width, height });

        const params = try msgpack.array(self.alloc, .{
            @as(u64, width),
            @as(u64, height),
        });
        // Note: we don't defer free because params will be owned by the write queue

        const notification = protocol.message.Notification{
            .method = "nvim_ui_try_resize",
            .params = params,
        };

        const encoded = try encoder.encodeNotification(self.alloc, notification);
        params.free(self.alloc); // Free after encoding

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.write_queue.append(self.alloc, encoded);
    }

    fn encodeInputNotification(self: *Self, keys: []const u8) ![]const u8 {
        const str_val = try msgpack.string(self.alloc, keys);
        // Don't free str_val - it's owned by params now

        const params = try msgpack.array(self.alloc, .{str_val});
        defer params.free(self.alloc); // This will free str_val too

        const notification = protocol.message.Notification{
            .method = "nvim_input",
            .params = params,
        };

        return try encoder.encodeNotification(self.alloc, notification);
    }

    fn ioThreadMain(self: *Self) void {
        log.info("I/O thread started", .{});

        // Pure spin loop - maximum responsiveness, CPU be damned
        // This is what Neovide does - dedicated thread spinning on reads
        while (!self.should_stop.load(.acquire)) {
            // Process pending writes - immediate
            self.processPendingWrites() catch {};

            // Read all available data - non-blocking
            self.readAndProcessMessages() catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        // Spin - no sleep, no yield, pure speed
                    },
                    error.ConnectionClosed => {
                        log.info("Neovim connection closed", .{});
                        return;
                    },
                    else => {},
                }
            };
        }

        log.info("I/O thread stopped", .{});
    }

    fn processPendingWrites(self: *Self) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        for (self.write_queue.items) |msg| {
            self.writeData(msg) catch |err| {
                log.warn("Failed to write to Neovim: {}", .{err});
                return err;
            };
            self.alloc.free(msg);
        }
        self.write_queue.clearRetainingCapacity();
    }

    fn readAndProcessMessages(self: *Self) !void {
        var buffer: [8192]u8 = undefined;
        const bytes_read = try self.readData(&buffer);

        if (bytes_read == 0) {
            return error.ConnectionClosed;
        }

        try self.read_buffer.appendSlice(self.alloc, buffer[0..bytes_read]);

        // Process complete messages
        while (self.tryProcessMessage()) |_| {}
    }

    /// Write data to Neovim (socket or pipe)
    fn writeData(self: *Self, data: []const u8) !void {
        switch (self.mode) {
            .socket => {
                const socket = self.socket orelse return error.NotConnected;
                try socket.writeAll(data);
            },
            .embedded => {
                const file = self.stdin_file orelse return error.NotConnected;
                try file.writeAll(data);
            },
        }
    }

    /// Read data from Neovim (socket or pipe)
    fn readData(self: *Self, buffer: []u8) !usize {
        switch (self.mode) {
            .socket => {
                const socket = self.socket orelse return error.NotConnected;
                return socket.read(buffer);
            },
            .embedded => {
                const file = self.stdout_file orelse return error.NotConnected;
                return file.read(buffer);
            },
        }
    }

    fn tryProcessMessage(self: *Self) ?void {
        if (self.read_buffer.items.len == 0) return null;

        const decode_result = decoder.decode(self.alloc, self.read_buffer.items) catch |err| {
            // Incomplete message, wait for more data
            if (err == error.LengthReading) return null;
            log.warn("Decode error: {}", .{err});
            return null;
        };

        // Remove consumed bytes
        const remaining = self.read_buffer.items.len - decode_result.bytes_read;
        if (remaining > 0) {
            std.mem.copyForwards(
                u8,
                self.read_buffer.items[0..remaining],
                self.read_buffer.items[decode_result.bytes_read..],
            );
        }
        self.read_buffer.shrinkRetainingCapacity(remaining);

        // Handle the message
        defer protocol.message.deinitMessage(@constCast(&decode_result.message), self.alloc);

        switch (decode_result.message) {
            .Notification => |notif| {
                if (std.mem.eql(u8, notif.method, "redraw")) {
                    self.processRedraw(notif.params) catch |err| {
                        log.debug("Redraw processing error: {}", .{err});
                    };
                }
            },
            .Response => |resp| {
                // Check if this is a response we're waiting for
                self.response_mutex.lock();
                defer self.response_mutex.unlock();

                if (self.pending_msgid) |expected| {
                    if (resp.msgid == expected) {
                        if (resp.result) |result| {
                            self.pending_response = protocol.payload_utils.clonePayload(self.alloc, result) catch null;
                        }
                        self.pending_msgid = null;
                        self.response_cond.signal();
                    }
                }
            },
            .Request => {
                // Server requests not implemented
            },
        }

        return {};
    }

    fn processRedraw(self: *Self, params: Payload) !void {
        const events = switch (params) {
            .arr => |arr| arr,
            else => return,
        };

        for (events) |event_batch| {
            const batch = switch (event_batch) {
                .arr => |arr| arr,
                else => continue,
            };
            if (batch.len == 0) continue;

            const event_name = switch (batch[0]) {
                .str => |s| s.value(),
                else => continue,
            };

            // Process each set of arguments
            for (batch[1..]) |args_payload| {
                const args = switch (args_payload) {
                    .arr => |arr| arr,
                    else => continue,
                };

                self.processEvent(event_name, args) catch |err| {
                    log.debug("Event '{s}' error: {}", .{ event_name, err });
                };
            }
        }
    }

    fn processEvent(self: *Self, name: []const u8, args: []const Payload) !void {
        if (std.mem.eql(u8, name, "grid_resize")) {
            if (args.len >= 3) {
                const grid = extractU64(args[0]) orelse return;
                const width = extractU64(args[1]) orelse return;
                const height = extractU64(args[2]) orelse return;
                log.info("grid_resize: grid={} {}x{}", .{ grid, width, height });
                try self.event_queue.push(.{ .grid_resize = .{
                    .grid = grid,
                    .width = width,
                    .height = height,
                } });
            }
        } else if (std.mem.eql(u8, name, "grid_line")) {
            try self.handleGridLine(args);
        } else if (std.mem.eql(u8, name, "grid_scroll")) {
            if (args.len >= 7) {
                try self.event_queue.push(.{ .grid_scroll = .{
                    .grid = extractU64(args[0]) orelse return,
                    .top = extractU64(args[1]) orelse return,
                    .bot = extractU64(args[2]) orelse return,
                    .left = extractU64(args[3]) orelse return,
                    .right = extractU64(args[4]) orelse return,
                    .rows = extractI64(args[5]) orelse return,
                    .cols = extractI64(args[6]) orelse return,
                } });
            }
        } else if (std.mem.eql(u8, name, "grid_clear")) {
            if (args.len >= 1) {
                if (extractU64(args[0])) |grid| {
                    try self.event_queue.push(.{ .grid_clear = grid });
                }
            }
        } else if (std.mem.eql(u8, name, "grid_cursor_goto")) {
            if (args.len >= 3) {
                try self.event_queue.push(.{ .grid_cursor_goto = .{
                    .grid = extractU64(args[0]) orelse return,
                    .row = extractU64(args[1]) orelse return,
                    .col = extractU64(args[2]) orelse return,
                } });
            }
        } else if (std.mem.eql(u8, name, "win_pos")) {
            if (args.len >= 6) {
                const grid = extractU64(args[0]) orelse return;
                const start_row = extractU64(args[2]) orelse return;
                const start_col = extractU64(args[3]) orelse return;
                const width = extractU64(args[4]) orelse return;
                const height = extractU64(args[5]) orelse return;
                // args[1] is the window handle - it's an ext type, not a plain int
                // For now, use 0 as placeholder since we don't really need it
                const win = extractU64(args[1]) orelse 0;
                log.info("win_pos: grid={} win={} row={} col={} {}x{}", .{ grid, win, start_row, start_col, width, height });
                try self.event_queue.push(.{ .win_pos = .{
                    .grid = grid,
                    .win = win,
                    .start_row = start_row,
                    .start_col = start_col,
                    .width = width,
                    .height = height,
                } });
            }
        } else if (std.mem.eql(u8, name, "win_float_pos")) {
            // win_float_pos: [grid, win, anchor, anchor_grid, anchor_row, anchor_col, focusable, zindex]
            if (args.len >= 8) {
                const anchor_str = switch (args[2]) {
                    .str => |s| s.value(),
                    else => "NW",
                };
                const anchor: Event.WinFloatPos.Anchor = if (std.mem.eql(u8, anchor_str, "NE"))
                    .NE
                else if (std.mem.eql(u8, anchor_str, "SW"))
                    .SW
                else if (std.mem.eql(u8, anchor_str, "SE"))
                    .SE
                else
                    .NW;

                try self.event_queue.push(.{ .win_float_pos = .{
                    .grid = extractU64(args[0]) orelse return,
                    .win = extractU64(args[1]) orelse return,
                    .anchor = anchor,
                    .anchor_grid = extractU64(args[3]) orelse 1,
                    .anchor_row = extractF32(args[4]) orelse 0,
                    .anchor_col = extractF32(args[5]) orelse 0,
                    .focusable = extractBool(args[6]),
                    .zindex = extractU64(args[7]) orelse 50,
                } });
            }
        } else if (std.mem.eql(u8, name, "win_hide")) {
            if (args.len >= 1) {
                if (extractU64(args[0])) |grid| {
                    try self.event_queue.push(.{ .win_hide = grid });
                }
            }
        } else if (std.mem.eql(u8, name, "win_close")) {
            if (args.len >= 1) {
                if (extractU64(args[0])) |grid| {
                    try self.event_queue.push(.{ .win_close = grid });
                }
            }
        } else if (std.mem.eql(u8, name, "win_viewport")) {
            if (args.len >= 8) {
                try self.event_queue.push(.{ .win_viewport = .{
                    .grid = extractU64(args[0]) orelse return,
                    .win = extractU64(args[1]) orelse return,
                    .topline = extractU64(args[2]) orelse 0,
                    .botline = extractU64(args[3]) orelse 0,
                    .curline = extractU64(args[4]) orelse 0,
                    .curcol = extractU64(args[5]) orelse 0,
                    .line_count = extractU64(args[6]) orelse 0,
                    .scroll_delta = extractI64(args[7]) orelse 0,
                } });
            }
        } else if (std.mem.eql(u8, name, "hl_attr_define")) {
            try self.handleHlAttrDefine(args);
        } else if (std.mem.eql(u8, name, "default_colors_set")) {
            if (args.len >= 3) {
                try self.event_queue.push(.{ .default_colors_set = .{
                    .fg = @intCast(extractU64(args[0]) orelse 0xffffff),
                    .bg = @intCast(extractU64(args[1]) orelse 0x1e1e2e),
                    .sp = @intCast(extractU64(args[2]) orelse 0xff0000),
                } });
            }
        } else if (std.mem.eql(u8, name, "flush")) {
            try self.event_queue.push(.flush);
            // IMMEDIATELY wake up renderer on flush - this is the key to zero latency
            if (self.nvim_gui) |nvim_ptr| {
                const neovim_gui = @import("main.zig");
                const nvim: *neovim_gui.NeovimGui = @ptrCast(@alignCast(nvim_ptr));
                nvim.triggerRenderWakeup();
            }
        } else if (std.mem.eql(u8, name, "mode_change")) {
            if (args.len >= 2) {
                try self.event_queue.push(.{ .mode_change = .{
                    .mode_idx = extractU64(args[1]) orelse 0,
                } });
            }
        }
        // Silently ignore other events
    }

    fn handleGridLine(self: *Self, args: []const Payload) !void {
        if (args.len < 4) return;

        const grid = extractU64(args[0]) orelse return;
        const row = extractU64(args[1]) orelse return;
        const col_start = extractU64(args[2]) orelse return;

        const cells_array = switch (args[3]) {
            .arr => |arr| arr,
            else => return,
        };

        var cells = std.ArrayListUnmanaged(Event.Cell){};
        errdefer {
            for (cells.items) |cell| {
                self.alloc.free(cell.text);
            }
            cells.deinit(self.alloc);
        }

        var current_hl_id: u64 = 0;

        for (cells_array) |cell_val| {
            const cell_data = switch (cell_val) {
                .arr => |arr| arr,
                else => continue,
            };
            if (cell_data.len == 0) continue;

            const text = switch (cell_data[0]) {
                .str => |s| s.value(),
                else => "",
            };

            if (cell_data.len >= 2) {
                if (extractU64(cell_data[1])) |hl| {
                    current_hl_id = hl;
                }
            }

            var repeat: u64 = 1;
            if (cell_data.len >= 3) {
                repeat = extractU64(cell_data[2]) orelse 1;
            }

            // Duplicate text for storage
            const text_copy = try self.alloc.dupe(u8, text);
            errdefer self.alloc.free(text_copy);

            try cells.append(self.alloc, .{
                .text = text_copy,
                .hl_id = current_hl_id,
                .repeat = repeat,
            });
        }

        try self.event_queue.push(.{ .grid_line = .{
            .grid = grid,
            .row = row,
            .col_start = col_start,
            .cells = try cells.toOwnedSlice(self.alloc),
        } });
    }

    fn handleHlAttrDefine(self: *Self, args: []const Payload) !void {
        if (args.len < 2) return;

        const id = extractU64(args[0]) orelse return;

        // args[1] is the RGB attributes map
        const rgb_map = switch (args[1]) {
            .map => args[1],
            else => return,
        };

        var attr = Event.HlAttr{};

        if (rgb_map.mapGet("foreground") catch null) |fg| {
            attr.foreground = @intCast(extractU64(fg) orelse 0);
        }
        if (rgb_map.mapGet("background") catch null) |bg| {
            attr.background = @intCast(extractU64(bg) orelse 0);
        }
        if (rgb_map.mapGet("special") catch null) |sp| {
            attr.special = @intCast(extractU64(sp) orelse 0);
        }
        if (rgb_map.mapGet("bold") catch null) |v| {
            attr.bold = extractBool(v);
        }
        if (rgb_map.mapGet("italic") catch null) |v| {
            attr.italic = extractBool(v);
        }
        if (rgb_map.mapGet("underline") catch null) |v| {
            attr.underline = extractBool(v);
        }
        if (rgb_map.mapGet("undercurl") catch null) |v| {
            attr.undercurl = extractBool(v);
        }
        if (rgb_map.mapGet("strikethrough") catch null) |v| {
            attr.strikethrough = extractBool(v);
        }
        if (rgb_map.mapGet("reverse") catch null) |v| {
            attr.reverse = extractBool(v);
        }

        try self.event_queue.push(.{ .hl_attr_define = .{
            .id = id,
            .attr = attr,
        } });
    }
};

fn extractU64(val: Payload) ?u64 {
    return switch (val) {
        .uint => |v| v,
        .int => |v| if (v >= 0) @intCast(v) else null,
        else => null,
    };
}

fn extractI64(val: Payload) ?i64 {
    return switch (val) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => null,
    };
}

fn extractF32(val: Payload) ?f32 {
    return switch (val) {
        .float => |v| @floatCast(v),
        .uint => |v| @floatFromInt(v),
        .int => |v| @floatFromInt(v),
        else => null,
    };
}

fn extractBool(val: Payload) bool {
    return switch (val) {
        .bool => |v| v,
        else => false,
    };
}
