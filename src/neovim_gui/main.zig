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
pub const CursorMode = Event.CursorMode;
pub const CursorShape = Event.CursorShape;
pub const OptionValue = Event.OptionValue;
pub const StyledContent = io_thread.StyledContent;
pub const MessageKind = io_thread.MessageKind;

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

    /// NormalFloat highlight ID (for floating window backgrounds)
    normal_float_hl_id: ?u64 = null,

    /// Whether we're connected and ready
    ready: bool = false,

    /// Dirty flag - something changed and needs render
    dirty: bool = true,

    /// Composition order for floating windows (used when compindex is not provided)
    composition_order: u64 = 0,

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

    /// Cursor modes from mode_info_set event (indexed by mode_idx)
    cursor_modes: []CursorMode = &.{},

    /// Whether cursor style is enabled (from mode_info_set)
    cursor_style_enabled: bool = true,

    /// Neovide-style cursor renderer with trail and particles
    cursor_renderer: CursorRenderer = CursorRenderer.init(),

    /// Busy state (Neovim is processing)
    is_busy: bool = false,

    /// Mouse enabled state
    mouse_enabled: bool = true,

    /// Suspend state (Ctrl+Z was pressed)
    suspended: bool = false,

    /// Restart state (Neovim is restarting, preserves state)
    restarting: bool = false,

    /// Exited state (Neovim exited via :q, :qall, etc.)
    exited: bool = false,

    /// Window title from Neovim (set_title event)
    title: []const u8 = "",

    /// Window icon name from Neovim (set_icon event, rarely used)
    icon: []const u8 = "",

    /// Neovim options received via option_set event
    /// Key is the option name (owned), value is the option value
    options: std.StringHashMap(OptionValue),

    // Message state (ext_messages)
    /// Current messages from msg_show events
    messages: std.ArrayListUnmanaged(Event.MsgShow) = .empty,
    /// Mode display content from msg_showmode (e.g., "-- INSERT --")
    showmode_content: []StyledContent = &.{},
    /// Partial command content from msg_showcmd
    showcmd_content: []StyledContent = &.{},
    /// Ruler content from msg_ruler (line/col info)
    ruler_content: []StyledContent = &.{},
    /// Message history from msg_history_show
    message_history: []Event.MsgHistoryEntry = &.{},

    pub fn init(alloc: Allocator) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .event_queue = EventQueue.init(alloc),
            .windows = std.AutoHashMap(u64, *RenderedWindow).init(alloc),
            .hl_attrs = std.AutoHashMap(u64, HlAttr).init(alloc),
            .options = std.StringHashMap(OptionValue).init(alloc),
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

        // Free cursor modes if allocated
        if (self.cursor_modes.len > 0) {
            self.alloc.free(self.cursor_modes);
        }

        // Free title and icon strings if allocated
        if (self.title.len > 0) {
            self.alloc.free(self.title);
        }
        if (self.icon.len > 0) {
            self.alloc.free(self.icon);
        }

        // Free options - both keys and string values are owned
        var opt_it = self.options.iterator();
        while (opt_it.next()) |entry| {
            // Free the key (option name)
            self.alloc.free(entry.key_ptr.*);
            // Free string values
            switch (entry.value_ptr.*) {
                .string => |s| self.alloc.free(s),
                else => {},
            }
        }
        self.options.deinit();

        // Free message state
        self.clearMessages();
        self.messages.deinit(self.alloc);
        self.freeStyledContent(self.showmode_content);
        self.freeStyledContent(self.showcmd_content);
        self.freeStyledContent(self.ruler_content);
        self.freeMessageHistory();

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

        // Set cmdheight=0 to eliminate the blank cmdline row at the bottom
        // With cmdheight=0, messages appear via vim.notify (handled by noice.nvim)
        // and the cmdline appears as a floating window when typing :
        try self.io.?.sendCommand("set cmdheight=0");

        // Force resize - Neovim may ignore the size in attachUi
        try self.io.?.resizeUi(self.grid_width, self.grid_height);

        log.info("Connected to Neovim successfully", .{});
    }

    /// Spawn Neovim in embedded mode (direct pipe communication)
    pub fn spawn(self: *Self, cwd: ?[]const u8) !void {
        log.info("Spawning embedded Neovim (cwd: {?s})", .{cwd});

        // Create I/O thread for embedded mode
        self.io = try IoThread.initEmbedded(self.alloc, &self.event_queue, cwd);
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

        // Set cmdheight=0 to eliminate the blank cmdline row at the bottom
        try self.io.?.sendCommand("set cmdheight=0");

        // Force resize - Neovim may ignore the size in attachUi
        try self.io.?.resizeUi(self.grid_width, self.grid_height);

        log.info("Embedded Neovim spawned successfully", .{});
    }

    /// Spawn Neovim with a socket and connect to it
    /// This is the recommended mode - spawns nvim with --listen and connects via socket
    /// Benefits: Full user config loaded, clean separation, can attach other clients
    pub fn spawnWithSocket(self: *Self, cwd: ?[]const u8) !void {
        log.info("Spawning Neovim with socket (cwd: {?s})", .{cwd});

        // Generate a unique socket path using timestamp and random
        const timestamp = std.time.timestamp();
        var prng = std.Random.DefaultPrng.init(@bitCast(timestamp));
        const random = prng.random().int(u32);
        const socket_path = try std.fmt.allocPrint(self.alloc, "/tmp/ghostty-nvim-{d}-{d}.sock", .{ timestamp, random });
        defer self.alloc.free(socket_path);

        // Remove any existing socket
        std.fs.deleteFileAbsolute(socket_path) catch {};

        // Spawn nvim --headless --listen <socket>
        // Support passing additional args via GHOSTTY_NVIM_ARGS env var (e.g., "--clean")
        const extra_args_str = std.posix.getenv("GHOSTTY_NVIM_ARGS");

        const args: []const []const u8 = if (extra_args_str) |extra| blk: {
            log.info("GHOSTTY_NVIM_ARGS: {s}", .{extra});
            // For simplicity, just support --clean for now
            if (std.mem.indexOf(u8, extra, "--clean")) |_| {
                log.info("Launching Neovim with --clean", .{});
                break :blk &.{ "nvim", "--clean", "--headless", "--listen", socket_path };
            }
            break :blk &.{ "nvim", "--headless", "--listen", socket_path };
        } else &.{ "nvim", "--headless", "--listen", socket_path };

        var child = std.process.Child.init(args, self.alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.cwd = cwd;
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

        // Set cmdheight=0 to eliminate the blank cmdline row at the bottom
        try self.io.?.sendCommand("set cmdheight=0");

        // Force resize - Neovim may ignore the size in attachUi
        try self.io.?.resizeUi(self.grid_width, self.grid_height);

        log.info("Connected to spawned Neovim successfully", .{});
    }

    /// Process incoming Neovim events (called from render thread - non-blocking!)
    pub fn processEvents(self: *Self) !void {
        if (!self.ready) return;

        // Swap event buffers - this is the only synchronization point
        self.event_queue.popAll(&self.local_events);

        // Process ALL events in the batch - don't stop at flush
        // This matches Neovide's approach: process all events, render once per frame.
        // Stopping at each flush causes stuttering during rapid updates (like nvim-tree animation).
        for (self.local_events.items) |*event| {
            self.handleEvent(event.*) catch |err| {
                log.err("Event error: {}", .{err});
            };
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
                // Store GRID-LOCAL coordinates - window offset applied at render time
                // This matches Neovide's approach: cursor stores (grid_id, local_pos)
                // and the renderer adds window.grid_position when drawing
                self.cursor_grid = data.grid;
                self.cursor_row = data.row;
                self.cursor_col = data.col;
                self.dirty = true;

                // NOTE: We don't update cursor_renderer here anymore.
                // The renderer will calculate screen position and update cursor_renderer
                // at render time when it has the most up-to-date window positions.
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
                log.err("win_close: grid={}", .{grid});
                if (self.windows.fetchRemove(grid)) |kv| {
                    kv.value.deinit();
                    self.alloc.destroy(kv.value);
                }
            },
            .grid_destroy => |grid| {
                // grid_destroy: grid will not be used anymore, remove it
                log.err("grid_destroy: grid={}", .{grid});
                if (self.windows.fetchRemove(grid)) |kv| {
                    kv.value.deinit();
                    self.alloc.destroy(kv.value);
                }
            },
            .msg_set_pos => |data| {
                try self.handleMsgSetPos(data);
            },
            .hl_attr_define => |data| {
                try self.hl_attrs.put(data.id, data.attr);
            },
            .default_colors_set => |data| {
                log.info("default_colors_set: fg=0x{x} bg=0x{x} sp=0x{x}", .{ data.fg, data.bg, data.sp });
                self.default_foreground = data.fg;
                self.default_background = data.bg;
                self.default_special = data.sp;
                self.dirty = true;
            },
            .mode_info_set => |data| {
                // Free old cursor modes if any
                if (self.cursor_modes.len > 0) {
                    self.alloc.free(self.cursor_modes);
                }
                // Store new cursor modes (take ownership of the slice)
                self.cursor_modes = self.alloc.dupe(CursorMode, data.cursor_modes) catch &.{};
                self.cursor_style_enabled = data.cursor_style_enabled;
                self.dirty = true;
            },
            .mode_change => |data| {
                self.current_mode_idx = data.mode_idx;
                self.dirty = true;
            },
            .flush => {
                // Process flush but don't stop - continue processing all events
                // This matches Neovide's approach: batch all events, render once per frame
                self.flush();
            },
            .suspend_event => {
                log.info("Neovim suspend event received", .{});
                self.suspended = true;
                // TODO: Could trigger terminal suspend behavior here
            },
            .restart => {
                log.info("Neovim restart event received", .{});
                self.restarting = true;
                // Clear state and wait for re-initialization
                self.ready = false;
            },
            .busy_start => {
                self.is_busy = true;
            },
            .busy_stop => {
                self.is_busy = false;
            },
            .mouse_on => {
                self.mouse_enabled = true;
            },
            .mouse_off => {
                self.mouse_enabled = false;
            },
            .set_title => |new_title| {
                log.info("set_title: {s}", .{new_title});
                // Free old title if allocated
                if (self.title.len > 0) {
                    self.alloc.free(self.title);
                }
                // Dupe since event.deinit will free the original
                self.title = self.alloc.dupe(u8, new_title) catch "";
            },
            .set_icon => |new_icon| {
                log.info("set_icon: {s}", .{new_icon});
                // Free old icon if allocated
                if (self.icon.len > 0) {
                    self.alloc.free(self.icon);
                }
                // Dupe since event.deinit will free the original
                self.icon = self.alloc.dupe(u8, new_icon) catch "";
            },
            .win_viewport_margins => |data| {
                self.handleWinViewportMargins(data);
            },
            .win_external_pos => |data| {
                self.handleWinExternalPos(data);
            },
            .option_set => |data| {
                try self.handleOptionSet(data);
            },
            // Command line events (ext_cmdline) - just log for now
            .cmdline_show => |data| {
                log.info("cmdline_show: level={} pos={} firstc='{s}' prompt='{s}' indent={}", .{
                    data.level,
                    data.pos,
                    data.firstc,
                    data.prompt,
                    data.indent,
                });
                self.dirty = true;
            },
            .cmdline_hide => |data| {
                log.info("cmdline_hide: level={}", .{data.level});
                self.dirty = true;
            },
            .cmdline_pos => |data| {
                log.info("cmdline_pos: pos={} level={}", .{ data.pos, data.level });
                self.dirty = true;
            },
            .cmdline_special_char => |data| {
                log.info("cmdline_special_char: char='{s}' shift={} level={}", .{
                    data.character,
                    data.shift,
                    data.level,
                });
                self.dirty = true;
            },
            .cmdline_block_show => |data| {
                log.info("cmdline_block_show: {} lines", .{data.lines.len});
                self.dirty = true;
            },
            .cmdline_block_hide => {
                log.info("cmdline_block_hide", .{});
                self.dirty = true;
            },
            .cmdline_block_append => |data| {
                log.info("cmdline_block_append: {} content items", .{data.line.len});
                self.dirty = true;
            },
            // Message events (ext_messages)
            .msg_show => |data| {
                log.info("msg_show: kind={} replace_last={} content_items={}", .{
                    @intFromEnum(data.kind),
                    data.replace_last,
                    data.content.len,
                });
                // If replace_last, remove the last message
                if (data.replace_last and self.messages.items.len > 0) {
                    if (self.messages.pop()) |last| {
                        for (last.content) |sc| {
                            self.alloc.free(sc.text);
                        }
                        self.alloc.free(last.content);
                    }
                }
                // Dupe the content since event.deinit will free the original
                const content_dupe = try self.dupeStyledContent(data.content);
                try self.messages.append(self.alloc, .{
                    .kind = data.kind,
                    .content = content_dupe,
                    .replace_last = data.replace_last,
                });
                self.dirty = true;
            },
            .msg_clear => {
                log.info("msg_clear", .{});
                self.clearMessages();
                self.dirty = true;
            },
            .msg_showmode => |data| {
                log.info("msg_showmode: {} content items", .{data.content.len});
                // Free old content
                self.freeStyledContent(self.showmode_content);
                // Dupe new content
                self.showmode_content = try self.dupeStyledContent(data.content);
                self.dirty = true;
            },
            .msg_showcmd => |data| {
                log.info("msg_showcmd: {} content items", .{data.content.len});
                // Free old content
                self.freeStyledContent(self.showcmd_content);
                // Dupe new content
                self.showcmd_content = try self.dupeStyledContent(data.content);
                self.dirty = true;
            },
            .msg_ruler => |data| {
                log.info("msg_ruler: {} content items", .{data.content.len});
                // Free old content
                self.freeStyledContent(self.ruler_content);
                // Dupe new content
                self.ruler_content = try self.dupeStyledContent(data.content);
                self.dirty = true;
            },
            .msg_history_show => |data| {
                log.info("msg_history_show: {} entries", .{data.entries.len});
                // Free old history
                self.freeMessageHistory();
                // Dupe new history
                if (data.entries.len > 0) {
                    var new_history = try self.alloc.alloc(Event.MsgHistoryEntry, data.entries.len);
                    errdefer self.alloc.free(new_history);

                    var i: usize = 0;
                    errdefer {
                        for (new_history[0..i]) |entry| {
                            for (entry.content) |sc| {
                                self.alloc.free(sc.text);
                            }
                            self.alloc.free(entry.content);
                        }
                    }

                    for (data.entries) |entry| {
                        new_history[i] = .{
                            .kind = entry.kind,
                            .content = try self.dupeStyledContent(entry.content),
                        };
                        i += 1;
                    }
                    self.message_history = new_history;
                }
                self.dirty = true;
            },
            // Highlight group set
            .hl_group_set => |data| {
                log.info("hl_group_set: {s} -> {}", .{ data.name, data.hl_id });
                // Track NormalFloat for floating window backgrounds
                if (std.mem.eql(u8, data.name, "NormalFloat")) {
                    self.normal_float_hl_id = data.hl_id;
                    log.info("NormalFloat hl_id set to {}", .{data.hl_id});
                }
                self.dirty = true;
            },
            // Window extmark (Neovim 0.10+)
            .win_extmark => |data| {
                log.info("win_extmark: grid={} win={}", .{ data.grid, data.win });
                // Extmarks are for advanced features - store if needed
                self.dirty = true;
            },
            // Popup menu events
            .popupmenu_show => |data| {
                log.info("popupmenu_show: {} items, selected={}, pos=({},{})", .{
                    data.items.len,
                    data.selected,
                    data.row,
                    data.col,
                });
                // Store popup state for rendering if ext_popupmenu is enabled
                self.dirty = true;
            },
            .popupmenu_select => |data| {
                log.info("popupmenu_select: {}", .{data.selected});
                self.dirty = true;
            },
            .popupmenu_hide => {
                log.info("popupmenu_hide", .{});
                self.dirty = true;
            },
            // Tabline events
            .tabline_update => |data| {
                log.info("tabline_update: current_tab={}, {} tabs", .{ data.current_tab, data.tabs.len });
                // Store tabline state for rendering if ext_tabline is enabled
                self.dirty = true;
            },
            .nvim_exited => {
                log.info("Neovim exited - setting exited flag", .{});
                self.exited = true;
                self.dirty = true;
            },
        }
    }

    fn handleOptionSet(self: *Self, data: Event.OptionSet) !void {
        log.info("handleOptionSet: {s}", .{data.name});

        // Check if this option already exists
        if (self.options.fetchRemove(data.name)) |existing| {
            // Free old key and value
            self.alloc.free(existing.key);
            switch (existing.value) {
                .string => |s| self.alloc.free(s),
                else => {},
            }
        }

        // Dupe the name and value since event.deinit will free them
        const name_dupe = try self.alloc.dupe(u8, data.name);
        errdefer self.alloc.free(name_dupe);

        const value_dupe: OptionValue = switch (data.value) {
            .string => |s| .{ .string = try self.alloc.dupe(u8, s) },
            .integer => |i| .{ .integer = i },
            .boolean => |b| .{ .boolean = b },
        };
        errdefer {
            switch (value_dupe) {
                .string => |s| self.alloc.free(s),
                else => {},
            }
        }

        try self.options.put(name_dupe, value_dupe);

        // Log specific important options
        switch (value_dupe) {
            .string => |s| log.info("  option_set: {s} = \"{s}\"", .{ name_dupe, s }),
            .integer => |i| log.info("  option_set: {s} = {}", .{ name_dupe, i }),
            .boolean => |b| log.info("  option_set: {s} = {}", .{ name_dupe, b }),
        }
    }

    fn handleGridResize(self: *Self, grid: u64, width: u64, height: u64) !void {
        const is_new = self.windows.get(grid) == null;
        log.err("grid_resize: grid={} {}x{} is_new={}", .{ grid, width, height, is_new });

        const window = try self.getOrCreateWindow(grid);
        log.info("handleGridResize: got window grid={} old_size={}x{}", .{ grid, window.grid_width, window.grid_height });
        try window.resize(@intCast(width), @intCast(height));

        // If there's a pending anchor (win_float_pos arrived before grid_resize),
        // recalculate position now that we have the correct dimensions
        if (window.pending_anchor) |pending| {
            log.info("handleGridResize: recalculating pending anchor for grid={}", .{grid});

            // Get parent window position (anchor grid)
            const parent_pos: [2]f32 = if (self.windows.get(pending.anchor_grid)) |parent|
                parent.grid_position
            else
                .{ 0, 0 };

            // Calculate position based on anchor type (like Neovide's modified_top_left)
            const width_f: f32 = @floatFromInt(window.grid_width);
            const height_f: f32 = @floatFromInt(window.grid_height);

            var left: f32 = pending.anchor_col;
            var top: f32 = pending.anchor_row;

            // Adjust position based on anchor type
            switch (pending.anchor) {
                .NW => {},
                .NE => {
                    // top-right corner: window extends left from anchor
                    left = pending.anchor_col - width_f;
                },
                .SW => {
                    // bottom-left corner: window extends up from anchor
                    top = pending.anchor_row - height_f;
                },
                .SE => {
                    // bottom-right corner: window extends up and left from anchor
                    left = pending.anchor_col - width_f;
                    top = pending.anchor_row - height_f;
                },
            }

            // Add parent position offset
            left += parent_pos[0];
            top += parent_pos[1];

            // Clamp to valid range
            left = @max(0, left);
            top = @max(0, top);

            const start_row: u64 = @intFromFloat(top);
            const start_col: u64 = @intFromFloat(left);

            log.info("handleGridResize: anchor recalc - anchor={s} parent_pos=({d:.1},{d:.1}) size={}x{} -> pos=({},{}))", .{
                @tagName(pending.anchor),
                parent_pos[0],
                parent_pos[1],
                window.grid_width,
                window.grid_height,
                start_col,
                start_row,
            });

            window.setFloatPosition(start_row, start_col, pending.zindex, pending.compindex);
            window.window_type = .floating;

            // Clear pending anchor - we've processed it
            window.pending_anchor = null;
        }

        self.dirty = true;
        log.info("handleGridResize DONE: grid={} new_size={}x{}", .{ grid, window.grid_width, window.grid_height });
    }

    fn handleGridLine(self: *Self, grid: u64, row: u64, col_start: u64, cells: []const Event.Cell) void {
        const window = self.windows.get(grid) orelse {
            log.err("grid_line: DROPPED - window not found for grid={} row={}", .{ grid, row });
            return;
        };

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
        self.dirty = true;
    }

    fn handleWinFloatPos(self: *Self, data: Event.WinFloatPos) !void {
        const window = try self.getOrCreateWindow(data.grid);

        // Determine composition order (compindex) for stable float layering
        const compindex: u64 = if (data.compindex) |ci| ci else blk: {
            if (window.zindex == data.zindex and window.composition_order != 0) {
                break :blk window.composition_order;
            }
            self.composition_order += 1;
            break :blk self.composition_order;
        };

        // Get parent window position (anchor grid)
        const parent_pos: [2]f32 = if (self.windows.get(data.anchor_grid)) |parent|
            parent.grid_position
        else
            .{ 0, 0 };

        // Calculate position based on anchor type (like Neovide's modified_top_left)
        // The anchor position is relative to the anchor grid
        // Note: If grid_resize hasn't arrived yet, width/height will be 0, but we still
        // store the anchor info so position can be recalculated when resize arrives
        const width_f: f32 = @floatFromInt(window.grid_width);
        const height_f: f32 = @floatFromInt(window.grid_height);

        var left: f32 = data.anchor_col;
        var top: f32 = data.anchor_row;

        // Adjust position based on anchor type
        switch (data.anchor) {
            .NW => {},
            .NE => {
                // top-right corner: window extends left from anchor
                left = data.anchor_col - width_f;
            },
            .SW => {
                // bottom-left corner: window extends up from anchor
                top = data.anchor_row - height_f;
            },
            .SE => {
                // bottom-right corner: window extends up and left from anchor
                left = data.anchor_col - width_f;
                top = data.anchor_row - height_f;
            },
        }

        // Add parent position offset
        left += parent_pos[0];
        top += parent_pos[1];

        // Clamp to valid range
        left = @max(0, left);
        top = @max(0, top);

        const start_row: u64 = @intFromFloat(top);
        const start_col: u64 = @intFromFloat(left);

        // Store the anchor info for recalculation on resize ONLY if dimensions are currently 0
        // (meaning grid_resize hasn't arrived yet). This is the case where position is wrong.
        if (window.grid_width == 0 or window.grid_height == 0) {
            window.pending_anchor = .{
                .anchor = data.anchor,
                .anchor_grid = data.anchor_grid,
                .anchor_row = data.anchor_row,
                .anchor_col = data.anchor_col,
                .zindex = data.zindex,
                .compindex = compindex,
            };
            log.info("handleWinFloatPos: grid={} has no size yet, storing pending_anchor", .{data.grid});
        } else {
            // Dimensions are known, clear any pending anchor
            window.pending_anchor = null;
        }

        window.setFloatPosition(start_row, start_col, data.zindex, compindex);
        window.window_type = .floating;
        self.dirty = true;
    }

    fn handleWinViewport(self: *Self, data: Event.WinViewport) void {
        const window = self.windows.get(data.grid) orelse return;
        // Log large scroll deltas that might indicate file navigation
        if (data.scroll_delta != 0) {
            log.err("win_viewport: grid={} topline={} botline={} scroll_delta={}", .{
                data.grid, data.topline, data.botline, data.scroll_delta,
            });
        }
        window.setViewport(data.topline, data.botline, data.scroll_delta);
    }

    fn handleWinViewportMargins(self: *Self, data: Event.WinViewportMargins) void {
        const window = self.windows.get(data.grid) orelse return;
        const old_top = window.viewport_margins.top;
        const old_bottom = window.viewport_margins.bottom;
        window.viewport_margins = .{
            .top = @intCast(data.top),
            .bottom = @intCast(data.bottom),
            .left = @intCast(data.left),
            .right = @intCast(data.right),
        };
        log.err("win_viewport_margins: grid={} top={}->{} bottom={}->{} left={} right={} type={s}", .{
            data.grid,
            old_top,
            data.top,
            old_bottom,
            data.bottom,
            data.left,
            data.right,
            @tagName(window.window_type),
        });
        self.dirty = true;
    }

    fn handleWinExternalPos(self: *Self, data: Event.WinExternalPos) void {
        const window = self.windows.get(data.grid) orelse return;
        window.is_external = true;
        log.info("win_external_pos: grid={} win={} - marked as external window", .{ data.grid, data.win });
        self.dirty = true;
    }

    fn handleMsgSetPos(self: *Self, data: Event.MsgSetPos) !void {
        log.info("handleMsgSetPos START: grid={} row={} zindex={}", .{ data.grid, data.row, data.zindex });

        // msg_set_pos positions the message/cmdline grid
        // It's a FLOATING window anchored to grid 1 at the specified row
        // Uses parent (grid 1) width for the message grid
        const window = try self.getOrCreateWindow(data.grid);
        log.info("handleMsgSetPos: got window grid={} size={}x{}", .{ data.grid, window.grid_width, window.grid_height });

        // Get parent (grid 1) width - like Neovide does
        const parent_width: u32 = if (self.windows.get(1)) |grid1|
            grid1.grid_width
        else
            self.grid_width;

        // Use the new setMessagePosition method which sets anchor_info
        const compindex: u64 = if (data.compindex) |ci| ci else blk: {
            if (window.zindex == data.zindex and window.composition_order != 0) {
                break :blk window.composition_order;
            }
            self.composition_order += 1;
            break :blk self.composition_order;
        };

        window.setMessagePosition(data.row, data.zindex, compindex, parent_width);
        self.dirty = true;

        log.info("handleMsgSetPos DONE: grid={} row={} zindex={} parent_width={} final_pos=({d:.1},{d:.1})", .{
            data.grid,
            data.row,
            data.zindex,
            parent_width,
            window.grid_position[0],
            window.grid_position[1],
        });
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
            window_ptr.*.flush();
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
    /// Returns attributes with default colors filled in for null fg/bg
    pub fn getHlAttr(self: *const Self, id: u64) HlAttr {
        if (id == 0) {
            return HlAttr{
                .foreground = self.default_foreground,
                .background = self.default_background,
            };
        }
        if (self.hl_attrs.get(id)) |attr| {
            // Return attr but ensure fg/bg have values (use defaults if null)
            return HlAttr{
                .foreground = attr.foreground orelse self.default_foreground,
                .background = attr.background orelse self.default_background,
                .special = attr.special,
                .bold = attr.bold,
                .italic = attr.italic,
                .underline = attr.underline,
                .undercurl = attr.undercurl,
                .underdotted = attr.underdotted,
                .underdashed = attr.underdashed,
                .underdouble = attr.underdouble,
                .strikethrough = attr.strikethrough,
                .reverse = attr.reverse,
                .blend = attr.blend,
            };
        }
        return HlAttr{
            .foreground = self.default_foreground,
            .background = self.default_background,
        };
    }

    /// Get highlight attributes for a floating window context
    /// Same as getHlAttr - just use the colors Neovim sends
    pub fn getHlAttrForFloat(self: *const Self, id: u64) HlAttr {
        return self.getHlAttr(id);
    }

    /// Get the current cursor mode based on mode_idx
    /// Returns null if cursor_style is disabled or mode_idx is out of range
    pub fn getCurrentCursorMode(self: *const Self) ?CursorMode {
        if (!self.cursor_style_enabled) return null;
        if (self.cursor_modes.len == 0) return null;
        if (self.current_mode_idx >= self.cursor_modes.len) return null;
        return self.cursor_modes[self.current_mode_idx];
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

    /// Send mouse input to Neovim using nvim_input_mouse API
    /// This targets a specific grid (window) by ID and position
    pub fn sendMouse(self: *Self, button: []const u8, action: []const u8, modifier: []const u8, grid: u64, row: u64, col: u64) !void {
        if (self.io == null or !self.ready) return;
        try self.io.?.sendInputMouse(button, action, modifier, grid, row, col);
    }

    /// Send scroll event to Neovim targeting a specific window
    /// This is the Neovide-style scroll handling that properly targets the window under cursor
    /// direction: "up" or "down"
    /// grid_id: the ID of the window/grid to scroll
    /// col, row: position within the grid in cells
    pub fn sendScroll(self: *Self, direction: []const u8, grid_id: u64, col: u64, row: u64) !void {
        if (self.io == null or !self.ready) return;
        // nvim_input_mouse("wheel", direction, modifier, grid, row, col)
        try self.io.?.sendInputMouse("wheel", direction, "", grid_id, row, col);
    }

    /// Find the window (grid) under the given screen position (in cells)
    /// Returns the grid_id and the position within that grid
    /// Checks floating windows first (highest zindex), then normal windows
    pub fn findWindowAtPosition(self: *Self, screen_col: f32, screen_row: f32) ?struct { grid_id: u64, col: u64, row: u64 } {
        // Collect all visible windows and sort by zindex (highest first for floating windows)
        var floating_windows: [32]struct { grid: u64, window: *RenderedWindow } = undefined;
        var floating_count: usize = 0;

        var normal_windows: [32]struct { grid: u64, window: *RenderedWindow } = undefined;
        var normal_count: usize = 0;

        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const window = entry.value_ptr.*;
            if (window.hidden) continue;
            if (!window.has_position and window.id != 1) continue;

            if (window.window_type == .floating or window.window_type == .message) {
                if (floating_count < 32) {
                    floating_windows[floating_count] = .{ .grid = entry.key_ptr.*, .window = window };
                    floating_count += 1;
                }
            } else {
                if (normal_count < 32) {
                    normal_windows[normal_count] = .{ .grid = entry.key_ptr.*, .window = window };
                    normal_count += 1;
                }
            }
        }

        // Sort floating windows by zindex, then composition order (highest first)
        const FloatingEntry = @TypeOf(floating_windows[0]);
        const sortFn = struct {
            fn lessThan(_: void, a: FloatingEntry, b: FloatingEntry) bool {
                if (a.window.zindex == b.window.zindex) {
                    if (a.window.composition_order == b.window.composition_order) {
                        return a.window.id > b.window.id;
                    }
                    return a.window.composition_order > b.window.composition_order;
                }
                return a.window.zindex > b.window.zindex;
            }
        }.lessThan;
        std.mem.sort(FloatingEntry, floating_windows[0..floating_count], {}, sortFn);

        // Check floating windows first (they're on top)
        for (floating_windows[0..floating_count]) |entry| {
            const window = entry.window;
            const pos = window.grid_position;
            // For floating windows, use grid dimensions if display dimensions not set
            // This happens when win_float_pos arrives before win_pos (which sets display_width/height)
            // setFloatPosition() doesn't set display dimensions, so we fall back to grid dimensions
            const width: f32 = if (window.display_width > 0)
                @floatFromInt(window.display_width)
            else
                @floatFromInt(window.grid_width);
            const height: f32 = if (window.display_height > 0)
                @floatFromInt(window.display_height)
            else
                @floatFromInt(window.grid_height);

            // Skip windows with no size yet (grid_resize hasn't arrived)
            if (width == 0 or height == 0) continue;

            if (screen_col >= pos[0] and screen_col < pos[0] + width and
                screen_row >= pos[1] and screen_row < pos[1] + height)
            {
                const local_col: u64 = @intFromFloat(screen_col - pos[0]);
                const local_row: u64 = @intFromFloat(screen_row - pos[1]);
                return .{ .grid_id = entry.grid, .col = local_col, .row = local_row };
            }
        }

        // Check normal windows
        for (normal_windows[0..normal_count]) |entry| {
            const window = entry.window;

            // Grid 1 is the outer container - use full grid dimensions
            const pos = if (entry.grid == 1) [2]f32{ 0, 0 } else window.grid_position;
            // Use display dimensions if set, otherwise fall back to grid dimensions
            const width: f32 = if (entry.grid == 1)
                @floatFromInt(self.grid_width)
            else if (window.display_width > 0)
                @floatFromInt(window.display_width)
            else
                @floatFromInt(window.grid_width);
            const height: f32 = if (entry.grid == 1)
                @floatFromInt(self.grid_height)
            else if (window.display_height > 0)
                @floatFromInt(window.display_height)
            else
                @floatFromInt(window.grid_height);

            // Skip windows with no size yet
            if (width == 0 or height == 0) continue;

            if (screen_col >= pos[0] and screen_col < pos[0] + width and
                screen_row >= pos[1] and screen_row < pos[1] + height)
            {
                const local_col: u64 = @intFromFloat(screen_col - pos[0]);
                const local_row: u64 = @intFromFloat(screen_row - pos[1]);
                return .{ .grid_id = entry.grid, .col = local_col, .row = local_row };
            }
        }

        return null;
    }

    /// Check if dirty and needs redraw
    pub fn isDirty(self: *const Self) bool {
        return self.dirty;
    }

    /// Clear dirty flag
    pub fn clearDirty(self: *Self) void {
        self.dirty = false;
    }

    // Message state accessors (for renderer)

    /// Get current messages to display
    pub fn getMessages(self: *const Self) []const Event.MsgShow {
        return self.messages.items;
    }

    /// Get current mode display (e.g., "-- INSERT --")
    pub fn getShowModeContent(self: *const Self) []const StyledContent {
        return self.showmode_content;
    }

    /// Get current partial command display
    pub fn getShowCmdContent(self: *const Self) []const StyledContent {
        return self.showcmd_content;
    }

    /// Get current ruler content (line/col info)
    pub fn getRulerContent(self: *const Self) []const StyledContent {
        return self.ruler_content;
    }

    /// Get message history
    pub fn getMessageHistory(self: *const Self) []const Event.MsgHistoryEntry {
        return self.message_history;
    }

    /// Check if there are any messages to display
    pub fn hasMessages(self: *const Self) bool {
        return self.messages.items.len > 0;
    }

    /// Check if there's any statusline content (showmode, showcmd, or ruler)
    pub fn hasStatusLineContent(self: *const Self) bool {
        return self.showmode_content.len > 0 or
            self.showcmd_content.len > 0 or
            self.ruler_content.len > 0;
    }

    // Message state helpers (private)

    /// Free styled content array
    fn freeStyledContent(self: *Self, content: []StyledContent) void {
        for (content) |sc| {
            self.alloc.free(sc.text);
        }
        if (content.len > 0) {
            self.alloc.free(content);
        }
    }

    /// Clear all messages
    fn clearMessages(self: *Self) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.alloc);
        }
        self.messages.clearRetainingCapacity();
    }

    /// Free message history
    fn freeMessageHistory(self: *Self) void {
        for (self.message_history) |entry| {
            for (entry.content) |sc| {
                self.alloc.free(sc.text);
            }
            self.alloc.free(entry.content);
        }
        if (self.message_history.len > 0) {
            self.alloc.free(self.message_history);
            self.message_history = &.{};
        }
    }

    /// Duplicate styled content array
    fn dupeStyledContent(self: *Self, content: []const StyledContent) ![]StyledContent {
        if (content.len == 0) return &.{};

        var result = try self.alloc.alloc(StyledContent, content.len);
        errdefer self.alloc.free(result);

        var i: usize = 0;
        errdefer {
            for (result[0..i]) |sc| {
                self.alloc.free(sc.text);
            }
        }

        for (content) |sc| {
            result[i] = .{
                .attr_id = sc.attr_id,
                .text = try self.alloc.dupe(u8, sc.text),
            };
            i += 1;
        }
        return result;
    }
};

test "NeovimGui init/deinit" {
    const alloc = std.testing.allocator;
    const gui = try NeovimGui.init(alloc);
    defer gui.deinit();
}
