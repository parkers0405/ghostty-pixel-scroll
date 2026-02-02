//! Neovim GUI Mode for Ghostty
//!
//! This module implements a native Neovim GUI client, similar to Neovide,
//! but integrated directly into Ghostty. It connects to Neovim via the
//! msgpack-rpc UI protocol and renders using Ghostty's GPU renderer.
//!
//! Architecture:
//! - I/O thread handles all Neovim communication asynchronously
//! - Render thread runs at full refresh rate (165Hz) without blocking
//! - Events flow through a thread-safe queue

const std = @import("std");
const Allocator = std.mem.Allocator;

const io_thread = @import("io_thread.zig");
pub const IoThread = io_thread.IoThread;
pub const EventQueue = io_thread.EventQueue;
pub const Event = io_thread.Event;
pub const HlAttr = Event.HlAttr;

pub const RenderedWindow = @import("rendered_window.zig").RenderedWindow;
pub const ScrollCommand = @import("rendered_window.zig").ScrollCommand;
pub const GridCell = @import("rendered_window.zig").GridCell;
pub const Animation = @import("animation.zig");
pub const nvim_input = @import("input.zig");
pub const CursorRenderer = @import("cursor_renderer.zig").CursorRenderer;
pub const VfxMode = @import("cursor_renderer.zig").VfxMode;

const log = std.log.scoped(.neovim_gui);

/// Main Neovim GUI state. One instance per Ghostty surface running in Neovim mode.
pub const NeovimGui = struct {
    const Self = @This();

    alloc: Allocator,

    /// I/O thread for async Neovim communication
    io: ?*IoThread = null,

    /// Event queue (shared with I/O thread)
    event_queue: EventQueue,

    /// Local buffer for processing events (avoids allocations in render loop)
    local_events: std.ArrayListUnmanaged(Event) = .empty,

    /// All windows received from Neovim, keyed by grid ID
    windows: std.AutoHashMap(u64, *RenderedWindow),

    /// Highlight attributes table
    hl_attrs: std.AutoHashMap(u64, HlAttr),

    /// Grid dimensions
    grid_width: u32 = 80,
    grid_height: u32 = 24,

    /// Cell dimensions in pixels
    cell_width: f32 = 0,
    cell_height: f32 = 0,

    /// Default colors
    default_background: u32 = 0x1e1e2e,
    default_foreground: u32 = 0xcdd6f4,
    default_special: u32 = 0xff0000,

    /// Whether we're connected and ready
    ready: bool = false,

    /// Dirty flag - something changed and needs render
    dirty: bool = true,

    /// Opaque pointer to renderer wakeup (xev.Async) for zero-latency wakeup
    render_wakeup_ptr: ?*anyopaque = null,
    /// Function to call notify on the wakeup
    render_wakeup_notify: ?*const fn (*anyopaque) void = null,

    /// Cursor position
    cursor_grid: u64 = 1,
    cursor_row: u64 = 0,
    cursor_col: u64 = 0,

    /// Current mode index
    current_mode_idx: u64 = 0,

    /// Neovide-style cursor renderer with trail and particles
    cursor_renderer: CursorRenderer = CursorRenderer.init(),

    pub fn init(alloc: Allocator) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .event_queue = EventQueue.init(alloc),
            .windows = std.AutoHashMap(u64, *RenderedWindow).init(alloc),
            .hl_attrs = std.AutoHashMap(u64, HlAttr).init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Stop I/O thread
        if (self.io) |io| {
            io.deinit();
        }

        // Free local events
        for (self.local_events.items) |*event| {
            event.deinit(self.alloc);
        }
        self.local_events.deinit(self.alloc);

        // Free event queue
        self.event_queue.deinit();

        // Free all windows
        var it = self.windows.valueIterator();
        while (it.next()) |window_ptr| {
            window_ptr.*.deinit();
            self.alloc.destroy(window_ptr.*);
        }
        self.windows.deinit();

        self.hl_attrs.deinit();
        self.alloc.destroy(self);
    }

    /// Connect to Neovim at the given socket path
    pub fn connect(self: *Self, socket_path: []const u8) !void {
        log.info("Connecting to Neovim at: {s}", .{socket_path});

        // Create I/O thread
        self.io = try IoThread.init(self.alloc, socket_path, &self.event_queue);
        errdefer {
            self.io.?.deinit();
            self.io = null;
        }

        // Connect to socket
        try self.io.?.connect();

        // Attach UI (blocking, happens before I/O thread starts)
        try self.io.?.attachUi(self.grid_width, self.grid_height);

        // Start I/O thread
        try self.io.?.start();

        self.ready = true;
        log.info("Connected to Neovim successfully", .{});
    }

    /// Spawn Neovim in embedded mode (direct pipe communication)
    pub fn spawn(self: *Self) !void {
        log.info("Spawning embedded Neovim", .{});

        // Create I/O thread for embedded mode
        self.io = try IoThread.initEmbedded(self.alloc, &self.event_queue);
        errdefer {
            self.io.?.deinit();
            self.io = null;
        }

        // Spawn and connect to embedded Neovim
        try self.io.?.connect();

        // Attach UI (blocking, happens before I/O thread starts)
        try self.io.?.attachUi(self.grid_width, self.grid_height);

        // Start I/O thread
        try self.io.?.start();

        self.ready = true;
        log.info("Embedded Neovim spawned successfully", .{});
    }

    /// Spawn Neovim with a socket and connect to it
    /// This is the recommended mode - spawns nvim with --listen and connects via socket
    /// Benefits: Full user config loaded, clean separation, can attach other clients
    pub fn spawnWithSocket(self: *Self) !void {
        log.info("Spawning Neovim with socket", .{});

        // Generate a unique socket path using timestamp and random
        const timestamp = std.time.timestamp();
        var prng = std.Random.DefaultPrng.init(@bitCast(timestamp));
        const random = prng.random().int(u32);
        const socket_path = try std.fmt.allocPrint(self.alloc, "/tmp/ghostty-nvim-{d}-{d}.sock", .{ timestamp, random });
        defer self.alloc.free(socket_path);

        // Remove any existing socket
        std.fs.deleteFileAbsolute(socket_path) catch {};

        // Spawn nvim --listen <socket>
        var child = std.process.Child.init(&.{ "nvim", "--listen", socket_path }, self.alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        // Wait for socket to be available (Neovim needs time to start)
        var attempts: u32 = 0;
        while (attempts < 100) : (attempts += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms); // 10ms
            // Try to stat the socket file
            if (std.fs.accessAbsolute(socket_path, .{})) {
                break;
            } else |_| {}
        }

        if (attempts >= 100) {
            log.err("Timeout waiting for Neovim socket", .{});
            _ = child.kill() catch {};
            return error.SocketTimeout;
        }

        log.info("Neovim socket ready at: {s}", .{socket_path});

        // Now connect to it like normal socket mode
        self.io = try IoThread.init(self.alloc, socket_path, &self.event_queue);
        errdefer {
            self.io.?.deinit();
            self.io = null;
        }

        try self.io.?.connect();
        try self.io.?.attachUi(self.grid_width, self.grid_height);
        try self.io.?.start();

        self.ready = true;
        log.info("Connected to spawned Neovim successfully", .{});
    }

    /// Process incoming Neovim events (called from render thread - non-blocking!)
    pub fn processEvents(self: *Self) !void {
        if (!self.ready) return;

        // Swap event buffers - this is the only synchronization point
        self.event_queue.popAll(&self.local_events);

        // Process all events
        for (self.local_events.items) |*event| {
            self.handleEvent(event.*) catch {};
            event.deinit(self.alloc);
        }
        self.local_events.clearRetainingCapacity();
    }

    fn handleEvent(self: *Self, event: Event) !void {
        switch (event) {
            .grid_resize => |data| {
                try self.handleGridResize(data.grid, data.width, data.height);
            },
            .grid_line => |data| {
                self.handleGridLine(data.grid, data.row, data.col_start, data.cells);
            },
            .grid_scroll => |data| {
                self.handleGridScroll(data);
            },
            .grid_clear => |grid| {
                self.handleGridClear(grid);
            },
            .grid_cursor_goto => |data| {
                const first_position = (self.cursor_row == 0 and self.cursor_col == 0 and
                    self.cursor_renderer.dest_x == 0 and self.cursor_renderer.dest_y == 0);
                self.cursor_grid = data.grid;
                self.cursor_row = data.row;
                self.cursor_col = data.col;

                // On first cursor position, snap immediately (no animation from 0,0)
                if (first_position) {
                    self.cursor_renderer.snap(
                        @intCast(data.col),
                        @intCast(data.row),
                        self.cell_width,
                        self.cell_height,
                    );
                } else {
                    self.cursor_renderer.setCursorPosition(
                        @intCast(data.col),
                        @intCast(data.row),
                        self.cell_width,
                        self.cell_height,
                    );
                }
                self.dirty = true;
            },
            .win_pos => |data| {
                try self.handleWinPos(data);
            },
            .win_float_pos => |data| {
                try self.handleWinFloatPos(data);
            },
            .win_viewport => |data| {
                self.handleWinViewport(data);
            },
            .win_hide => |grid| {
                if (self.windows.get(grid)) |window| {
                    window.hidden = true;
                }
            },
            .win_close => |grid| {
                if (self.windows.fetchRemove(grid)) |kv| {
                    kv.value.deinit();
                    self.alloc.destroy(kv.value);
                }
            },
            .hl_attr_define => |data| {
                try self.hl_attrs.put(data.id, data.attr);
            },
            .default_colors_set => |data| {
                self.default_foreground = data.fg;
                self.default_background = data.bg;
                self.default_special = data.sp;
                self.dirty = true;
            },
            .mode_change => |data| {
                self.current_mode_idx = data.mode_idx;
                self.dirty = true;
            },
            .flush => {
                self.flush();
            },
            else => {},
        }
    }

    fn handleGridResize(self: *Self, grid: u64, width: u64, height: u64) !void {
        log.debug("Grid resize: grid={} {}x{}", .{ grid, width, height });

        const window = try self.getOrCreateWindow(grid);
        try window.resize(@intCast(width), @intCast(height));
        self.dirty = true;
    }

    fn handleGridLine(self: *Self, grid: u64, row: u64, col_start: u64, cells: []const Event.Cell) void {
        const window = self.windows.get(grid) orelse return;

        // Convert Event.Cell to the format expected by RenderedWindow
        var col = col_start;
        for (cells) |cell| {
            var i: u64 = 0;
            while (i < cell.repeat) : (i += 1) {
                if (col < window.grid_width) {
                    window.setCell(@intCast(row), @intCast(col), cell.text, cell.hl_id);
                    col += 1;
                }
            }
        }
        self.dirty = true;
    }

    fn handleGridScroll(self: *Self, data: Event.GridScroll) void {
        log.debug("Grid scroll: grid={} rows={} region=[{}-{}]x[{}-{}]", .{
            data.grid,
            data.rows,
            data.top,
            data.bot,
            data.left,
            data.right,
        });

        const window = self.windows.get(data.grid) orelse return;
        window.handleScroll(.{
            .top = data.top,
            .bottom = data.bot,
            .left = data.left,
            .right = data.right,
            .rows = data.rows,
            .cols = data.cols,
        });
        self.dirty = true;
    }

    fn handleGridClear(self: *Self, grid: u64) void {
        const window = self.windows.get(grid) orelse return;
        window.clear();
        self.dirty = true;
    }

    fn handleWinPos(self: *Self, data: Event.WinPos) !void {
        const window = try self.getOrCreateWindow(data.grid);
        window.setPosition(data.start_row, data.start_col, data.width, data.height);
        window.window_type = .editor;
        self.dirty = true;
    }

    fn handleWinFloatPos(self: *Self, data: Event.WinFloatPos) !void {
        const window = try self.getOrCreateWindow(data.grid);

        // Floating windows are positioned relative to an anchor grid
        // For simplicity, we use the anchor_row/anchor_col directly as the position
        // These are in grid coordinates (rows/columns)
        const start_row: u64 = @intFromFloat(@max(0, data.anchor_row));
        const start_col: u64 = @intFromFloat(@max(0, data.anchor_col));

        window.setFloatPosition(start_row, start_col, data.zindex);
        window.window_type = .floating;
        self.dirty = true;

        log.debug("Float window: grid={} pos=({d:.1},{d:.1}) zindex={}", .{
            data.grid,
            data.anchor_row,
            data.anchor_col,
            data.zindex,
        });
    }

    fn handleWinViewport(self: *Self, data: Event.WinViewport) void {
        const window = self.windows.get(data.grid) orelse return;
        window.setViewport(data.topline, data.botline, data.scroll_delta);
    }

    fn getOrCreateWindow(self: *Self, grid: u64) !*RenderedWindow {
        if (self.windows.get(grid)) |window| {
            return window;
        }

        const window = try self.alloc.create(RenderedWindow);
        window.* = RenderedWindow.init(self.alloc, grid);
        try self.windows.put(grid, window);
        return window;
    }

    fn flush(self: *Self) void {
        // Called after a batch of updates - trigger render
        var it = self.windows.valueIterator();
        while (it.next()) |window_ptr| {
            window_ptr.*.flush(self.cell_height);
        }
        self.dirty = true;
    }

    /// Animate all windows, returns true if any window is still animating
    pub fn animate(self: *Self, dt: f32) bool {
        var animating = false;
        var it = self.windows.valueIterator();
        while (it.next()) |window_ptr| {
            if (window_ptr.*.animate(dt)) {
                animating = true;
            }
        }
        return animating;
    }

    /// Get window by grid ID
    pub fn getWindow(self: *Self, grid: u64) ?*RenderedWindow {
        return self.windows.get(grid);
    }

    /// Get highlight attributes for a given ID
    pub fn getHlAttr(self: *const Self, id: u64) HlAttr {
        if (id == 0) {
            return HlAttr{
                .foreground = self.default_foreground,
                .background = self.default_background,
            };
        }
        return self.hl_attrs.get(id) orelse HlAttr{
            .foreground = self.default_foreground,
            .background = self.default_background,
        };
    }

    /// Resize the UI
    pub fn resize(self: *Self, width: u32, height: u32, cell_width: f32, cell_height: f32) !void {
        self.grid_width = width;
        self.grid_height = height;
        self.cell_width = cell_width;
        self.cell_height = cell_height;

        if (self.io != null and self.ready) {
            try self.io.?.resizeUi(width, height);
        }
    }

    /// Send key input to Neovim - direct write for zero latency
    pub fn sendKey(self: *Self, key: []const u8) !void {
        if (self.io == null or !self.ready) return;
        // Use direct send for immediate delivery - no queuing delay
        try self.io.?.sendInputDirect(key);
    }

    /// Set the render wakeup for zero latency
    pub fn setRenderWakeup(self: *Self, wakeup_ptr: *anyopaque, notify_fn: *const fn (*anyopaque) void) void {
        self.render_wakeup_ptr = wakeup_ptr;
        self.render_wakeup_notify = notify_fn;
        if (self.io) |io| {
            io.setRenderWakeup(self);
        }
    }

    /// Called by I/O thread to wake up the renderer
    pub fn triggerRenderWakeup(self: *Self) void {
        if (self.render_wakeup_ptr) |ptr| {
            if (self.render_wakeup_notify) |notify_fn| {
                notify_fn(ptr);
            }
        }
    }

    /// Send mouse input to Neovim
    pub fn sendMouse(self: *Self, button: []const u8, action: []const u8, modifier: []const u8, grid: u64, row: i32, col: i32) !void {
        _ = self;
        _ = button;
        _ = action;
        _ = modifier;
        _ = grid;
        _ = row;
        _ = col;
        // TODO: Implement mouse input
    }

    /// Check if dirty and needs redraw
    pub fn isDirty(self: *const Self) bool {
        return self.dirty;
    }

    /// Clear dirty flag
    pub fn clearDirty(self: *Self) void {
        self.dirty = false;
    }
};

test "NeovimGui init/deinit" {
    const alloc = std.testing.allocator;
    const gui = try NeovimGui.init(alloc);
    defer gui.deinit();
}
