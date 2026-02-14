//! Native Neovim GUI client integrated into Ghostty.
//! Connects via msgpack-rpc and renders through Ghostty's GPU pipeline.
//! I/O thread handles Neovim comms, render thread runs at refresh rate.

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

const rendered_window = @import("rendered_window.zig");
pub const RenderedWindow = rendered_window.RenderedWindow;
pub const ScrollCommand = rendered_window.ScrollCommand;
pub const GridCell = rendered_window.GridCell;
const ViewportMargins = rendered_window.ViewportMargins;
pub const Animation = @import("animation.zig");
pub const nvim_input = @import("input.zig");
pub const CursorRenderer = @import("cursor_renderer.zig").CursorRenderer;

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

    /// Default colors (Neovim's built-in defaults, overridden by default_colors_set)
    default_background: u32 = 0x1d1f21,
    default_foreground: u32 = 0xe0e0e0,
    default_special: u32 = 0xff0000,

    /// NormalFloat highlight ID (for floating window backgrounds)
    normal_float_hl_id: ?u64 = null,
    /// WinBar highlight IDs (for auto-detecting winbar when margins are missing)
    winbar_hl_id: ?u64 = null,
    winbar_nc_hl_id: ?u64 = null,

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

    /// Collab presence callback: called when Neovim reports cursor position.
    /// Surface sets this to forward presence to CollabState.
    collab_presence_callback: ?*const fn (row: u32, col: u32, file: []const u8, mode: u8) void = null,

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

    /// Image preview path and change token (from ghostty_image notifications)
    image_preview_path: []const u8 = "",
    image_preview_token: u64 = 0,

    /// Current buffer file name (from collab presence, for same-buffer detection)
    current_file: []const u8 = "",

    /// Resolved peer screen positions from receiver-side screenpos() calls.
    /// Flat array: [row0, col0, row1, col1, ...]. Row=0 means off-screen.
    /// Set by ghostty_peer_screen RPC notification.
    peer_screen_positions: [16]u32 = .{0} ** 16,
    peer_screen_count: u8 = 0, // number of peers (positions = count * 2)

    /// Frame counter for throttling periodic updates (badges etc.)
    frame_counter: u32 = 0,

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
        if (self.io) |io| io.deinit();

        for (self.local_events.items) |*event| event.deinit(self.alloc);
        self.local_events.deinit(self.alloc);
        self.event_queue.deinit();

        var it = self.windows.valueIterator();
        while (it.next()) |window_ptr| {
            window_ptr.*.deinit();
            self.alloc.destroy(window_ptr.*);
        }
        self.windows.deinit();
        self.hl_attrs.deinit();

        if (self.cursor_modes.len > 0) self.alloc.free(self.cursor_modes);
        if (self.title.len > 0) self.alloc.free(self.title);
        if (self.icon.len > 0) self.alloc.free(self.icon);
        if (self.image_preview_path.len > 0) self.alloc.free(self.image_preview_path);
        if (self.current_file.len > 0) self.alloc.free(self.current_file);

        var opt_it = self.options.iterator();
        while (opt_it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .string => |s| self.alloc.free(s),
                else => {},
            }
        }
        self.options.deinit();

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
        log.info("connecting to Neovim at: {s}", .{socket_path});
        self.io = try IoThread.init(self.alloc, socket_path, &self.event_queue);
        errdefer {
            self.io.?.deinit();
            self.io = null;
        }
        try self.io.?.connect();
        try self.finishConnection();
    }

    /// Connect to a remote Neovim via TCP (for collab sessions)
    pub fn connectTcp(self: *Self, host: []const u8, port: u16) !void {
        log.info("connecting to remote Neovim at {s}:{d}", .{ host, port });
        self.io = try IoThread.initTcp(self.alloc, host, port, &self.event_queue);
        errdefer {
            self.io.?.deinit();
            self.io = null;
        }
        try self.io.?.connect();
        try self.finishConnection();
    }

    /// Spawn Neovim in embedded mode (direct pipe communication)
    pub fn spawn(self: *Self, cwd: ?[]const u8) !void {
        log.info("spawning embedded Neovim (cwd: {?s})", .{cwd});
        self.io = try IoThread.initEmbedded(self.alloc, &self.event_queue, cwd);
        errdefer {
            self.io.?.deinit();
            self.io = null;
        }
        try self.io.?.connect();
        try self.finishConnection();
    }

    /// Spawn Neovim with --listen and connect via socket.
    /// This is the recommended mode: loads full user config, clean separation.
    pub fn spawnWithSocket(self: *Self, cwd: ?[]const u8) !void {
        log.info("spawning Neovim with socket (cwd: {?s})", .{cwd});

        const socket_path = try self.makeSocketPath();
        defer self.alloc.free(socket_path);
        std.fs.deleteFileAbsolute(socket_path) catch {};

        // Support --clean via GHOSTTY_NVIM_ARGS
        const extra_args_str = std.posix.getenv("GHOSTTY_NVIM_ARGS");
        const args: []const []const u8 = if (extra_args_str) |extra| blk: {
            if (std.mem.indexOf(u8, extra, "--clean")) |_| {
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

        // Poll until the socket appears (Neovim needs a moment to start)
        var attempts: u32 = 0;
        while (attempts < 100) : (attempts += 1) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            if (std.fs.accessAbsolute(socket_path, .{})) break else |_| {}
        }
        if (attempts >= 100) {
            log.err("timed out waiting for Neovim socket", .{});
            _ = child.kill() catch {};
            return error.SocketTimeout;
        }

        self.io = try IoThread.init(self.alloc, socket_path, &self.event_queue);
        errdefer {
            self.io.?.deinit();
            self.io = null;
        }
        try self.io.?.connect();
        try self.finishConnection();
    }

    /// Shared post-connect sequence: attach UI, start I/O thread, force resize.
    fn finishConnection(self: *Self) !void {
        try self.io.?.attachUi(self.grid_width, self.grid_height);
        try self.io.?.start();
        self.ready = true;
        try self.io.?.resizeUi(self.grid_width, self.grid_height);

        self.installImagePreviewAutocmd() catch |err| {
            log.warn("failed to install image preview autocmd: {}", .{err});
        };
        self.installCollabPresenceAutocmd() catch |err| {
            log.warn("failed to install collab presence autocmd: {}", .{err});
        };
    }

    fn installImagePreviewAutocmd(self: *Self) !void {
        if (self.io == null) return;
        const cmd =
            "lua if vim.g.ghostty_image_preview ~= 1 then " ++
            "vim.g.ghostty_image_preview = 1 " ++
            "local chan = vim.v.channel " ++
            "if type(chan) ~= 'number' then " ++
            "local uis = vim.api.nvim_list_uis() " ++
            "if uis and uis[1] and type(uis[1].chan) == 'number' then chan = uis[1].chan end " ++
            "end " ++
            "vim.g.ghostty_channel = chan " ++
            "local function ghostty_send() " ++
            "local c = vim.g.ghostty_channel " ++
            "if type(c) ~= 'number' then return end " ++
            "local bt = vim.bo.buftype " ++
            "local name = '' " ++
            "if bt == nil or bt == '' then " ++
            "name = vim.api.nvim_buf_get_name(0) " ++
            "if name == nil or name == '' then name = '' else name = vim.fn.fnamemodify(name, ':p') end " ++
            "end " ++
            "vim.rpcnotify(c, 'ghostty_image', name) " ++
            "end " ++
            "vim.api.nvim_create_autocmd({'BufEnter','BufWinEnter','WinEnter'}, {callback = ghostty_send}) " ++
            "ghostty_send() " ++
            "end";
        try self.io.?.sendCommand(cmd);
    }

    /// Install collab presence autocmds - sends cursor position and buffer name
    /// to Ghostty on every CursorMoved event via rpcnotify. This is what makes
    /// Update NvimTree collab peer badges by pushing peer file info to Lua.
    fn updateCollabPeerBadges(self: *Self) void {
        const io = self.io orelse return;
        const collab_main = @import("../collab/main.zig");
        const cs = collab_main.CollabState.global_instance orelse return;

        var raw_peers: [collab_main.MAX_PEERS]?collab_main.CollabState.PeerCursor = undefined;
        _ = cs.getPeers(&raw_peers);

        // Build Lua table string: {["file"] = "name", ...}
        var buf: [2048]u8 = undefined;
        var pos: usize = 0;
        const prefix = "lua vim.g.ghostty_collab_peers = {";
        @memcpy(buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;

        for (raw_peers[0..collab_main.MAX_PEERS]) |maybe_peer| {
            if (maybe_peer) |peer| {
                const file = peer.getFileName();
                const name = peer.getName();
                if (file.len == 0 or name.len == 0) continue;
                // Skip NvimTree buffers
                if (std.mem.startsWith(u8, file, "NvimTree")) continue;

                // ["file"] = "name",
                const entry_start = pos;
                if (pos + 6 + file.len + name.len >= buf.len - 10) break;
                buf[pos] = '[';
                buf[pos + 1] = '"';
                pos += 2;
                @memcpy(buf[pos .. pos + file.len], file);
                pos += file.len;
                buf[pos] = '"';
                buf[pos + 1] = ']';
                buf[pos + 2] = '=';
                buf[pos + 3] = '"';
                pos += 4;
                @memcpy(buf[pos .. pos + name.len], name);
                pos += name.len;
                buf[pos] = '"';
                buf[pos + 1] = ',';
                pos += 2;
                _ = entry_start;
            }
        }

        buf[pos] = '}';
        pos += 1;

        io.sendCommand(buf[0..pos]) catch {};
    }

    /// Push peer buffer positions to Neovim as vim.g._ghostty_peer_buf.
    /// The Lua autocmd will call screenpos() for each and send back resolved
    /// screen positions via ghostty_peer_screen RPC. This handles wraps,
    /// different gutter widths, and different window sizes correctly.
    fn pushPeerBufferPositions(self: *Self) void {
        const io = self.io orelse return;
        const collab_main = @import("../collab/main.zig");
        const cs = collab_main.CollabState.global_instance orelse return;

        var raw_peers: [collab_main.MAX_PEERS]?collab_main.CollabState.PeerCursor = undefined;
        _ = cs.getPeers(&raw_peers);

        // Build: lua vim.g._ghostty_peer_buf = {{line,col},{line,col}}
        var buf: [512]u8 = undefined;
        var pos: usize = 0;
        const prefix = "lua vim.g._ghostty_peer_buf = {";
        @memcpy(buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;

        const my_file = self.current_file;
        for (raw_peers[0..collab_main.MAX_PEERS]) |maybe_peer| {
            if (maybe_peer) |peer| {
                const peer_file = peer.getFileName();
                // Only include peers in the same file
                if (my_file.len == 0 or peer_file.len == 0) continue;
                if (!std.mem.eql(u8, my_file, peer_file)) continue;

                // {line,col},
                const entry = std.fmt.bufPrint(buf[pos..], "{{{d},{d}}},", .{ peer.cursor_row, peer.cursor_col }) catch break;
                pos += entry.len;
            }
        }

        buf[pos] = '}';
        pos += 1;

        io.sendCommand(buf[0..pos]) catch {};
    }

    /// peer ghost cursors work. Injected at runtime, no Neovim plugin needed.
    fn installCollabPresenceAutocmd(self: *Self) !void {
        if (self.io == null) return;
        log.info("installing collab presence autocmd", .{});
        const cmd =
            "lua if vim.g.ghostty_collab ~= 1 then " ++
            "vim.g.ghostty_collab = 1 " ++
            "local function get_chan() " ++
            "local c = vim.g.ghostty_channel " ++
            "if type(c) == 'number' then return c end " ++
            "local uis = vim.api.nvim_list_uis() " ++
            "if uis and uis[1] and type(uis[1].chan) == 'number' then " ++
            "vim.g.ghostty_channel = uis[1].chan " ++
            "return uis[1].chan end " ++
            "return nil end " ++
            "local function ghostty_presence() " ++
            "local c = get_chan() " ++
            "if not c then return end " ++
            "local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0) " ++
            "if not ok then return end " ++
            "local vcol = vim.fn.virtcol('.') " ++
            "local name = vim.api.nvim_buf_get_name(0) or '' " ++
            "if name ~= '' then name = vim.fn.fnamemodify(name, ':~:.') end " ++
            "local m = vim.fn.mode() " ++
            "vim.rpcnotify(c, 'ghostty_presence', pos[1], vcol, name, m) " ++
            "end " ++
            // Resolve peer buffer positions → screen positions on a fast timer.
            // Runs independently of our cursor so ghost cursors update live.
            "local function resolve_peers() " ++
            "local c = get_chan() " ++
            "if not c then return end " ++
            "local pbufs = vim.g._ghostty_peer_buf " ++
            "if not pbufs or #pbufs == 0 then return end " ++
            "local res = {} " ++
            "for _, p in ipairs(pbufs) do " ++
            "local sp = vim.fn.screenpos(0, p[1], p[2]) " ++
            "res[#res+1] = sp.row " ++
            "res[#res+1] = sp.col " ++
            "end " ++
            "vim.rpcnotify(c, 'ghostty_peer_screen', res) " ++
            "end " ++
            "local peer_timer = vim.uv.new_timer() " ++
            "peer_timer:start(6, 6, vim.schedule_wrap(resolve_peers)) " ++
            // Send our own presence on a fast timer too, so the peer sees us
            // moving continuously during held-key repeats (not just on CursorMoved).
            "local send_timer = vim.uv.new_timer() " ++
            "send_timer:start(6, 6, vim.schedule_wrap(ghostty_presence)) " ++
            "vim.api.nvim_create_autocmd({" ++
            "'ModeChanged','BufEnter','WinEnter'" ++
            "}, {callback = ghostty_presence}) " ++
            "ghostty_presence() " ++
            // -- Live file sync: auto-save on edit, auto-reload on change --
            "vim.o.autoread = true " ++
            "vim.o.updatetime = 200 " ++
            // Auto-save: write buffer after each text change (normal + insert)
            "vim.api.nvim_create_autocmd({'TextChanged','TextChangedI'}, {" ++
            "callback = function() " ++
            "local buf = vim.api.nvim_get_current_buf() " ++
            "if vim.bo[buf].modified and vim.bo[buf].modifiable " ++
            "and vim.bo[buf].buftype == '' " ++
            "and vim.api.nvim_buf_get_name(buf) ~= '' then " ++
            "pcall(vim.api.nvim_buf_call, buf, function() vim.cmd('silent! noautocmd write') end) " ++
            "end " ++
            "end}) " ++
            // File watcher: use inotify for instant reload on external changes
            "local watchers = {} " ++
            "local function watch_buf(buf) " ++
            "local name = vim.api.nvim_buf_get_name(buf) " ++
            "if name == '' or watchers[name] then return end " ++
            "local w = vim.uv.new_fs_event() " ++
            "if not w then return end " ++
            "local ok = pcall(w.start, w, name, {}, vim.schedule_wrap(function() " ++
            "pcall(vim.cmd, 'silent! checktime') " ++
            "end)) " ++
            "if ok then watchers[name] = w end " ++
            "end " ++
            "vim.api.nvim_create_autocmd({'BufEnter','BufReadPost'}, {" ++
            "callback = function() watch_buf(vim.api.nvim_get_current_buf()) end}) " ++
            // Also keep a slow fallback timer for edge cases
            "local timer = vim.uv.new_timer() " ++
            "timer:start(500, 500, vim.schedule_wrap(function() " ++
            "pcall(vim.cmd, 'silent! checktime') " ++
            "end)) " ++
            // -- NvimTree collab badges --
            "vim.g.ghostty_collab_peers = {} " ++
            // Define highlight group for collab badge
            "vim.api.nvim_set_hl(0, 'GhosttyCollabPeer', {fg = '#7aa2f7', bold = true}) " ++
            // Try to hook into nvim-tree renderer for badges
            "pcall(function() " ++
            "local api = require('nvim-tree.api') " ++
            "local Event = api.events.Event " ++
            "api.events.subscribe(Event.TreeRendered, function() " ++
            "local peers = vim.g.ghostty_collab_peers or {} " ++
            "if vim.tbl_isempty(peers) then return end " ++
            "local tree_buf = vim.api.nvim_get_current_buf() " ++
            "if vim.bo[tree_buf].filetype ~= 'NvimTree' then return end " ++
            "local ns = vim.api.nvim_create_namespace('ghostty_collab') " ++
            "vim.api.nvim_buf_clear_namespace(tree_buf, ns, 0, -1) " ++
            "local lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false) " ++
            "for i, line in ipairs(lines) do " ++
            "for pfile, pname in pairs(peers) do " ++
            "local basename = vim.fn.fnamemodify(pfile, ':t') " ++
            "if line:find(basename, 1, true) then " ++
            "pcall(vim.api.nvim_buf_set_extmark, tree_buf, ns, i-1, 0, " ++
            "{virt_text = {{' ● ' .. pname, 'GhosttyCollabPeer'}}, virt_text_pos = 'eol'}) " ++
            "end " ++
            "end " ++
            "end " ++
            "end) " ++
            "end) " ++
            "end";
        try self.io.?.sendCommand(cmd);
    }

    /// Build a unique socket path under XDG_RUNTIME_DIR (or /tmp as fallback).
    fn makeSocketPath(self: *Self) ![]u8 {
        const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse
            std.posix.getenv("TMPDIR") orelse
            "/tmp";
        const timestamp = std.time.timestamp();
        var prng = std.Random.DefaultPrng.init(@bitCast(timestamp));
        const random = prng.random().int(u32);
        return std.fmt.allocPrint(self.alloc, "{s}/ghostty-nvim-{d}-{d}.sock", .{ dir, timestamp, random });
    }

    /// Process pending Neovim events. Called from render thread, non-blocking.
    pub fn processEvents(self: *Self) !void {
        if (!self.ready) return;
        self.event_queue.popAll(&self.local_events);

        // Process all events in one go (like Neovide). Stopping at each flush
        // causes stuttering during rapid updates.
        for (self.local_events.items) |*event| {
            self.handleEvent(event.*) catch |err| {
                log.debug("event error: {}", .{err});
            };
            event.deinit(self.alloc);
        }
        self.local_events.clearRetainingCapacity();

        // Push peer buffer positions to Neovim every frame so the Lua timer
        // can resolve them via screenpos(). This ensures the ghost cursor
        // updates live when PEERS move, not just when WE move.
        self.pushPeerBufferPositions();
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
                // Grid-local coords; the renderer adds window offset when drawing
                self.cursor_grid = data.grid;
                self.cursor_row = data.row;
                self.cursor_col = data.col;
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
                    // Hide instantly -- fade-out causes grey rectangle artifacts
                    window.hidden = true;
                    window.fading_out = false;
                }
            },
            .win_close => |grid| {
                log.debug("win_close: grid={}", .{grid});
                if (self.windows.fetchRemove(grid)) |kv| {
                    kv.value.deinit();
                    self.alloc.destroy(kv.value);
                }
            },
            .grid_destroy => |grid| {
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
                log.debug("default_colors_set: fg=0x{x} bg=0x{x} sp=0x{x}", .{ data.fg, data.bg, data.sp });
                self.default_foreground = data.fg;
                self.default_background = data.bg;
                self.default_special = data.sp;
                self.dirty = true;
            },
            .mode_info_set => |data| {
                if (self.cursor_modes.len > 0) self.alloc.free(self.cursor_modes);
                self.cursor_modes = self.alloc.dupe(CursorMode, data.cursor_modes) catch &.{};
                self.cursor_style_enabled = data.cursor_style_enabled;
                self.dirty = true;
            },
            .mode_change => |data| {
                self.current_mode_idx = data.mode_idx;
                self.dirty = true;
            },
            .flush => {
                self.flush();
            },
            .suspend_event => {
                self.suspended = true;
            },
            .restart => {
                self.restarting = true;
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
                if (self.title.len > 0) {
                    self.alloc.free(self.title);
                }
                // Dupe since event.deinit will free the original
                self.title = self.alloc.dupe(u8, new_title) catch "";
            },
            .set_icon => |new_icon| {
                if (self.icon.len > 0) {
                    self.alloc.free(self.icon);
                }
                // Dupe since event.deinit will free the original
                self.icon = self.alloc.dupe(u8, new_icon) catch "";
            },
            .image_preview => |path| {
                if (self.image_preview_path.len > 0) {
                    self.alloc.free(self.image_preview_path);
                }
                // Dupe since event.deinit will free the original
                self.image_preview_path = self.alloc.dupe(u8, path) catch "";
                self.image_preview_token +%= 1;
                self.dirty = true;
            },
            .collab_presence => |data| {
                if (self.current_file.len > 0) {
                    self.alloc.free(self.current_file);
                }
                self.current_file = self.alloc.dupe(u8, data.file_name) catch "";

                if (self.collab_presence_callback) |cb| {
                    cb(data.row, data.col, data.file_name, data.mode);
                } else {
                    log.warn("no collab_presence_callback set", .{});
                }

                // Update NvimTree badges with peer file info
                self.updateCollabPeerBadges();
            },
            .collab_peer_screen => |data| {
                self.peer_screen_positions = data.positions;
                self.peer_screen_count = data.count;
                self.dirty = true;
                self.updateCollabPeerBadges();
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
            // Command line events
            .cmdline_show => {
                self.dirty = true;
            },
            .cmdline_hide => {
                self.dirty = true;
            },
            .cmdline_pos => {
                self.dirty = true;
            },
            .cmdline_special_char => {
                self.dirty = true;
            },
            .cmdline_block_show => {
                self.dirty = true;
            },
            .cmdline_block_hide => {
                self.dirty = true;
            },
            .cmdline_block_append => {
                self.dirty = true;
            },
            // Message events (ext_messages)
            .msg_show => |data| {
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
                self.clearMessages();
                self.dirty = true;
            },
            .msg_showmode => |data| {
                self.freeStyledContent(self.showmode_content);
                // Dupe new content
                self.showmode_content = try self.dupeStyledContent(data.content);
                self.dirty = true;
            },
            .msg_showcmd => |data| {
                self.freeStyledContent(self.showcmd_content);
                // Dupe new content
                self.showcmd_content = try self.dupeStyledContent(data.content);
                self.dirty = true;
            },
            .msg_ruler => |data| {
                self.freeStyledContent(self.ruler_content);
                // Dupe new content
                self.ruler_content = try self.dupeStyledContent(data.content);
                self.dirty = true;
            },
            .msg_history_show => |data| {
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
                if (std.mem.eql(u8, data.name, "NormalFloat")) {
                    self.normal_float_hl_id = data.hl_id;
                } else if (std.mem.eql(u8, data.name, "WinBar")) {
                    self.winbar_hl_id = data.hl_id;
                } else if (std.mem.eql(u8, data.name, "WinBarNC")) {
                    self.winbar_nc_hl_id = data.hl_id;
                }
                self.dirty = true;
            },
            // Window extmark (Neovim 0.10+)
            .win_extmark => {
                self.dirty = true;
            },
            // Popup menu events
            .popupmenu_show => {
                self.dirty = true;
            },
            .popupmenu_select => {
                self.dirty = true;
            },
            .popupmenu_hide => {
                self.dirty = true;
            },
            // Tabline events
            .tabline_update => {
                self.dirty = true;
            },
            .nvim_exited => {
                self.exited = true;
                self.dirty = true;
            },
        }
    }

    fn handleOptionSet(self: *Self, data: Event.OptionSet) !void {
        if (self.options.fetchRemove(data.name)) |existing| {
            self.alloc.free(existing.key);
            switch (existing.value) {
                .string => |s| self.alloc.free(s),
                else => {},
            }
        }

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
    }

    fn handleGridResize(self: *Self, grid: u64, width: u64, height: u64) !void {
        const window = try self.getOrCreateWindow(grid);
        try window.resize(@intCast(width), @intCast(height));

        // Pending anchor means win_float_pos arrived before grid_resize.
        // Now that we know the size, recalculate the position.
        if (window.pending_anchor) |pending| {
            const parent_pos: [2]f32 = if (self.windows.get(pending.anchor_grid)) |parent|
                parent.grid_position
            else
                .{ 0, 0 };

            const width_f: f32 = @floatFromInt(window.grid_width);
            const height_f: f32 = @floatFromInt(window.grid_height);

            var left: f32 = pending.anchor_col;
            var top: f32 = pending.anchor_row;

            switch (pending.anchor) {
                .NW => {},
                .NE => left = pending.anchor_col - width_f,
                .SW => top = pending.anchor_row - height_f,
                .SE => {
                    left = pending.anchor_col - width_f;
                    top = pending.anchor_row - height_f;
                },
            }

            left = @max(0, left + parent_pos[0]);
            top = @max(0, top + parent_pos[1]);

            const start_row: u64 = @intFromFloat(top);
            const start_col: u64 = @intFromFloat(left);

            window.setFloatPosition(start_row, start_col, pending.zindex, pending.compindex);
            window.window_type = .floating;

            window.pending_anchor = null;
        }

        self.dirty = true;
    }

    fn handleGridLine(self: *Self, grid: u64, row: u64, col_start: u64, cells: []const Event.Cell) void {
        const window = self.windows.get(grid) orelse return;

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

        const compindex: u64 = if (data.compindex) |ci| ci else blk: {
            if (window.zindex == data.zindex and window.composition_order != 0) {
                break :blk window.composition_order;
            }
            self.composition_order += 1;
            break :blk self.composition_order;
        };

        const parent_pos: [2]f32 = if (self.windows.get(data.anchor_grid)) |parent|
            parent.grid_position
        else
            .{ 0, 0 };

        const width_f: f32 = @floatFromInt(window.grid_width);
        const height_f: f32 = @floatFromInt(window.grid_height);

        var left: f32 = data.anchor_col;
        var top: f32 = data.anchor_row;

        switch (data.anchor) {
            .NW => {},
            .NE => left = data.anchor_col - width_f,
            .SW => top = data.anchor_row - height_f,
            .SE => {
                left = data.anchor_col - width_f;
                top = data.anchor_row - height_f;
            },
        }

        left = @max(0, left + parent_pos[0]);
        top = @max(0, top + parent_pos[1]);

        const start_row: u64 = @intFromFloat(top);
        const start_col: u64 = @intFromFloat(left);

        // If we don't have dimensions yet, stash the anchor so we can
        // recalculate once grid_resize arrives.
        if (window.grid_width == 0 or window.grid_height == 0) {
            window.pending_anchor = .{
                .anchor = data.anchor,
                .anchor_grid = data.anchor_grid,
                .anchor_row = data.anchor_row,
                .anchor_col = data.anchor_col,
                .zindex = data.zindex,
                .compindex = compindex,
            };
            log.debug("win_float_pos: grid={} has no size yet, deferring anchor", .{data.grid});
        } else {
            window.pending_anchor = null;
        }

        window.setFloatPosition(start_row, start_col, data.zindex, compindex);
        window.window_type = .floating;
        self.dirty = true;
    }

    fn handleWinViewport(self: *Self, data: Event.WinViewport) void {
        const window = self.windows.get(data.grid) orelse return;
        window.setViewport(data.topline, data.botline, data.scroll_delta);
    }

    fn handleWinViewportMargins(self: *Self, data: Event.WinViewportMargins) void {
        const window = self.windows.get(data.grid) orelse return;
        const old = window.viewport_margins;
        const new_margins = ViewportMargins{
            .top = @intCast(data.top),
            .bottom = @intCast(data.bottom),
            .left = @intCast(data.left),
            .right = @intCast(data.right),
        };
        window.viewport_margins = new_margins;

        // If margins changed, reset scroll animation immediately.
        // This prevents the winbar/statusline from being treated as scrollable
        // content during the transition (e.g., buffer switch via telescope).
        // The scrollback will be resized in the next flush() call.
        if (old.top != new_margins.top or old.bottom != new_margins.bottom) {
            window.scroll_animation.reset();
            window.scroll_delta = 0;
        }

        self.dirty = true;
    }

    fn handleWinExternalPos(self: *Self, data: Event.WinExternalPos) void {
        const window = self.windows.get(data.grid) orelse return;
        window.is_external = true;
        self.dirty = true;
    }

    fn handleMsgSetPos(self: *Self, data: Event.MsgSetPos) !void {
        const window = try self.getOrCreateWindow(data.grid);
        const parent_width: u32 = if (self.windows.get(1)) |grid1|
            grid1.grid_width
        else
            self.grid_width;

        const compindex: u64 = if (data.compindex) |ci| ci else blk: {
            if (window.zindex == data.zindex and window.composition_order != 0) {
                break :blk window.composition_order;
            }
            self.composition_order += 1;
            break :blk self.composition_order;
        };

        window.setMessagePosition(data.row, data.zindex, compindex, parent_width);
        self.dirty = true;
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
        var it = self.windows.valueIterator();
        while (it.next()) |window_ptr| {
            window_ptr.*.flush(self.winbar_hl_id, self.winbar_nc_hl_id);
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

    pub fn sendKey(self: *Self, key: []const u8) !void {
        if (self.io == null or !self.ready) return;
        try self.io.?.sendInputDirect(key);
    }

    pub fn setRenderWakeup(self: *Self, wakeup_ptr: *anyopaque, notify_fn: *const fn (*anyopaque) void) void {
        self.render_wakeup_ptr = wakeup_ptr;
        self.render_wakeup_notify = notify_fn;
        if (self.io) |io| {
            io.setRenderWakeup(self);
        }
    }

    pub fn triggerRenderWakeup(self: *Self) void {
        if (self.render_wakeup_ptr) |ptr| {
            if (self.render_wakeup_notify) |notify_fn| {
                notify_fn(ptr);
            }
        }
    }

    pub fn sendMouse(self: *Self, button: []const u8, action: []const u8, modifier: []const u8, grid: u64, row: u64, col: u64) !void {
        if (self.io == null or !self.ready) return;
        try self.io.?.sendInputMouse(button, action, modifier, grid, row, col);
    }

    pub fn sendScroll(self: *Self, direction: []const u8, grid_id: u64, col: u64, row: u64) !void {
        if (self.io == null or !self.ready) return;
        try self.io.?.sendInputMouse("wheel", direction, "", grid_id, row, col);
    }

    /// Find the topmost window at the given screen position (in cells).
    /// Checks floating windows first (highest z), then normal windows.
    pub fn findWindowAtPosition(self: *Self, screen_col: f32, screen_row: f32) ?struct { grid_id: u64, col: u64, row: u64 } {
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

        for (floating_windows[0..floating_count]) |entry| {
            const window = entry.window;
            const pos = window.grid_position;
            // Fall back to grid dimensions when display dimensions aren't set yet
            const width: f32 = if (window.display_width > 0)
                @floatFromInt(window.display_width)
            else
                @floatFromInt(window.grid_width);
            const height: f32 = if (window.display_height > 0)
                @floatFromInt(window.display_height)
            else
                @floatFromInt(window.grid_height);

            if (width == 0 or height == 0) continue;

            if (screen_col >= pos[0] and screen_col < pos[0] + width and
                screen_row >= pos[1] and screen_row < pos[1] + height)
            {
                const local_col: u64 = @intFromFloat(screen_col - pos[0]);
                const local_row: u64 = @intFromFloat(screen_row - pos[1]);
                return .{ .grid_id = entry.grid, .col = local_col, .row = local_row };
            }
        }

        // Check child windows first; grid 1 is the full-screen backdrop.
        var grid1_entry: ?@TypeOf(normal_windows[0]) = null;
        for (normal_windows[0..normal_count]) |entry| {
            if (entry.grid == 1) {
                grid1_entry = entry;
                continue;
            }

            const window = entry.window;
            const pos = window.grid_position;
            const width: f32 = if (window.display_width > 0)
                @floatFromInt(window.display_width)
            else
                @floatFromInt(window.grid_width);
            const height: f32 = if (window.display_height > 0)
                @floatFromInt(window.display_height)
            else
                @floatFromInt(window.grid_height);

            if (width == 0 or height == 0) continue;

            if (screen_col >= pos[0] and screen_col < pos[0] + width and
                screen_row >= pos[1] and screen_row < pos[1] + height)
            {
                const local_col: u64 = @intFromFloat(screen_col - pos[0]);
                const local_row: u64 = @intFromFloat(screen_row - pos[1]);
                return .{ .grid_id = entry.grid, .col = local_col, .row = local_row };
            }
        }

        if (grid1_entry) |entry| {
            const pos = [2]f32{ 0, 0 };
            const width: f32 = @floatFromInt(self.grid_width);
            const height: f32 = @floatFromInt(self.grid_height);

            if (width > 0 and height > 0 and
                screen_col >= pos[0] and screen_col < pos[0] + width and
                screen_row >= pos[1] and screen_row < pos[1] + height)
            {
                const local_col: u64 = @intFromFloat(screen_col - pos[0]);
                const local_row: u64 = @intFromFloat(screen_row - pos[1]);
                return .{ .grid_id = entry.grid, .col = local_col, .row = local_row };
            }
        }

        return null;
    }

    pub fn isDirty(self: *const Self) bool {
        return self.dirty;
    }

    pub fn clearDirty(self: *Self) void {
        self.dirty = false;
    }

    pub fn getMessages(self: *const Self) []const Event.MsgShow {
        return self.messages.items;
    }

    pub fn getShowModeContent(self: *const Self) []const StyledContent {
        return self.showmode_content;
    }

    pub fn getShowCmdContent(self: *const Self) []const StyledContent {
        return self.showcmd_content;
    }

    pub fn getRulerContent(self: *const Self) []const StyledContent {
        return self.ruler_content;
    }

    pub fn getMessageHistory(self: *const Self) []const Event.MsgHistoryEntry {
        return self.message_history;
    }

    pub fn hasMessages(self: *const Self) bool {
        return self.messages.items.len > 0;
    }

    pub fn hasStatusLineContent(self: *const Self) bool {
        return self.showmode_content.len > 0 or
            self.showcmd_content.len > 0 or
            self.ruler_content.len > 0;
    }

    fn freeStyledContent(self: *Self, content: []StyledContent) void {
        for (content) |sc| {
            self.alloc.free(sc.text);
        }
        if (content.len > 0) {
            self.alloc.free(content);
        }
    }

    fn clearMessages(self: *Self) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.alloc);
        }
        self.messages.clearRetainingCapacity();
    }

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
