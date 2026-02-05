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

/// Styled content - text with an attribute ID (used in messages)
pub const StyledContent = struct {
    attr_id: u64,
    text: []const u8,
};

/// Message kind for msg_show events
pub const MessageKind = enum {
    unknown,
    confirm,
    confirm_sub,
    emsg, // error
    echo,
    echomsg,
    echoerr,
    lua_error,
    rpc_error,
    return_prompt,
    quickfix,
    search_count,
    wmsg, // warning

    pub fn parse(kind_str: []const u8) MessageKind {
        if (std.mem.eql(u8, kind_str, "confirm")) return .confirm;
        if (std.mem.eql(u8, kind_str, "confirm_sub")) return .confirm_sub;
        if (std.mem.eql(u8, kind_str, "emsg")) return .emsg;
        if (std.mem.eql(u8, kind_str, "echo")) return .echo;
        if (std.mem.eql(u8, kind_str, "echomsg")) return .echomsg;
        if (std.mem.eql(u8, kind_str, "echoerr")) return .echoerr;
        if (std.mem.eql(u8, kind_str, "lua_error")) return .lua_error;
        if (std.mem.eql(u8, kind_str, "rpc_error")) return .rpc_error;
        if (std.mem.eql(u8, kind_str, "return_prompt")) return .return_prompt;
        if (std.mem.eql(u8, kind_str, "quickfix")) return .quickfix;
        if (std.mem.eql(u8, kind_str, "search_count")) return .search_count;
        if (std.mem.eql(u8, kind_str, "wmsg")) return .wmsg;
        return .unknown;
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
    grid_destroy: u64, // grid id - grid will not be used anymore
    msg_set_pos: MsgSetPos, // Message/cmdline area position
    hl_attr_define: HlAttrDefine,
    default_colors_set: DefaultColors,
    mode_info_set: ModeInfoSet,
    mode_change: ModeChange,
    flush,
    option_set: OptionSet,
    busy_start,
    busy_stop,
    mouse_on,
    mouse_off,
    suspend_event, // Ctrl+Z pressed (named to avoid keyword conflict)
    restart, // Neovim is restarting (preserves state)
    set_title: []const u8, // Window title from Neovim
    set_icon: []const u8, // Window icon name (rarely used)
    win_viewport_margins: WinViewportMargins,
    win_external_pos: WinExternalPos,
    nvim_exited, // Neovim process exited (:q, :qall, etc.)

    // Message events (ext_messages)
    msg_show: MsgShow,
    msg_clear,
    msg_showmode: MsgShowMode,
    msg_showcmd: MsgShowCmd,
    msg_ruler: MsgRuler,
    msg_history_show: MsgHistoryShow,

    // Command line events (ext_cmdline)
    cmdline_show: CmdlineShow,
    cmdline_hide: CmdlineHide,
    cmdline_pos: CmdlinePos,
    cmdline_special_char: CmdlineSpecialChar,
    cmdline_block_show: CmdlineBlockShow,
    cmdline_block_hide,
    cmdline_block_append: CmdlineBlockAppend,

    // Highlight group mapping
    hl_group_set: HlGroupSet,

    // Extmark events (ext_multigrid, Neovim 0.10+)
    win_extmark: WinExtmark,

    // Popup menu events (ext_popupmenu)
    popupmenu_show: PopupmenuShow,
    popupmenu_select: PopupmenuSelect,
    popupmenu_hide,

    // Tabline events (ext_tabline)
    tabline_update: TablineUpdate,

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

    /// Message/cmdline area position
    pub const MsgSetPos = struct {
        grid: u64,
        row: u64,
        scrolled: bool,
        zindex: u64,
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
        underdotted: bool = false,
        underdashed: bool = false,
        underdouble: bool = false,
        strikethrough: bool = false,
        reverse: bool = false,
        blend: u8 = 0,
    };

    pub const DefaultColors = struct {
        fg: u32,
        bg: u32,
        sp: u32,
    };

    /// Cursor shape for different modes
    pub const CursorShape = enum {
        block,
        horizontal,
        vertical,
    };

    /// Cursor mode information from mode_info_set event
    pub const CursorMode = struct {
        shape: ?CursorShape = null,
        cell_percentage: ?f32 = null,
        blinkwait: ?u64 = null,
        blinkon: ?u64 = null,
        blinkoff: ?u64 = null,
        attr_id: ?u64 = null,
    };

    pub const ModeInfoSet = struct {
        cursor_style_enabled: bool,
        cursor_modes: []CursorMode,

        pub fn deinit(self: *ModeInfoSet, alloc: Allocator) void {
            alloc.free(self.cursor_modes);
        }
    };

    /// Command line show event (ext_cmdline)
    pub const CmdlineShow = struct {
        content: []StyledContent,
        pos: u64,
        firstc: []const u8,
        prompt: []const u8,
        indent: u64,
        level: u64,

        pub fn deinit(self: *CmdlineShow, alloc: Allocator) void {
            for (self.content) |sc| {
                alloc.free(sc.text);
            }
            alloc.free(self.content);
            alloc.free(self.firstc);
            alloc.free(self.prompt);
        }
    };

    /// Command line hide event (ext_cmdline)
    pub const CmdlineHide = struct {
        level: u64,
    };

    /// Command line cursor position event (ext_cmdline)
    pub const CmdlinePos = struct {
        pos: u64,
        level: u64,
    };

    /// Command line special character event (ext_cmdline)
    pub const CmdlineSpecialChar = struct {
        character: []const u8,
        shift: bool,
        level: u64,

        pub fn deinit(self: *CmdlineSpecialChar, alloc: Allocator) void {
            alloc.free(self.character);
        }
    };

    /// Command line block show event (ext_cmdline)
    pub const CmdlineBlockShow = struct {
        lines: [][]StyledContent,

        pub fn deinit(self: *CmdlineBlockShow, alloc: Allocator) void {
            for (self.lines) |line| {
                for (line) |sc| {
                    alloc.free(sc.text);
                }
                alloc.free(line);
            }
            alloc.free(self.lines);
        }
    };

    /// Command line block append event (ext_cmdline)
    pub const CmdlineBlockAppend = struct {
        line: []StyledContent,

        pub fn deinit(self: *CmdlineBlockAppend, alloc: Allocator) void {
            for (self.line) |sc| {
                alloc.free(sc.text);
            }
            alloc.free(self.line);
        }
    };

    // Message event structs (ext_messages)

    /// Message show event - displays a message
    pub const MsgShow = struct {
        kind: MessageKind,
        content: []StyledContent,
        replace_last: bool,

        pub fn deinit(self: *MsgShow, alloc: Allocator) void {
            for (self.content) |sc| {
                alloc.free(sc.text);
            }
            alloc.free(self.content);
        }
    };

    /// Message showmode event - shows mode like "-- INSERT --"
    pub const MsgShowMode = struct {
        content: []StyledContent,

        pub fn deinit(self: *MsgShowMode, alloc: Allocator) void {
            for (self.content) |sc| {
                alloc.free(sc.text);
            }
            alloc.free(self.content);
        }
    };

    /// Message showcmd event - shows partial command
    pub const MsgShowCmd = struct {
        content: []StyledContent,

        pub fn deinit(self: *MsgShowCmd, alloc: Allocator) void {
            for (self.content) |sc| {
                alloc.free(sc.text);
            }
            alloc.free(self.content);
        }
    };

    /// Message ruler event - shows ruler (line/col info)
    pub const MsgRuler = struct {
        content: []StyledContent,

        pub fn deinit(self: *MsgRuler, alloc: Allocator) void {
            for (self.content) |sc| {
                alloc.free(sc.text);
            }
            alloc.free(self.content);
        }
    };

    /// Message history entry for msg_history_show
    pub const MsgHistoryEntry = struct {
        kind: MessageKind,
        content: []StyledContent,
    };

    /// Message history show event - shows :messages output
    pub const MsgHistoryShow = struct {
        entries: []MsgHistoryEntry,

        pub fn deinit(self: *MsgHistoryShow, alloc: Allocator) void {
            for (self.entries) |entry| {
                for (entry.content) |sc| {
                    alloc.free(sc.text);
                }
                alloc.free(entry.content);
            }
            alloc.free(self.entries);
        }
    };
    pub const ModeChange = struct {
        mode_idx: u64,
    };

    /// Value type for option_set event - options can be strings, integers, or booleans
    pub const OptionValue = union(enum) {
        string: []const u8,
        integer: i64,
        boolean: bool,
    };

    pub const OptionSet = struct {
        name: []const u8,
        value: OptionValue,

        pub fn deinit(self: *OptionSet, alloc: Allocator) void {
            alloc.free(self.name);
            switch (self.value) {
                .string => |s| alloc.free(s),
                else => {},
            }
        }
    };

    /// Window viewport margins - fixed rows that don't scroll (winbar, borders, etc.)
    pub const WinViewportMargins = struct {
        grid: u64,
        win: u64,
        top: u64,
        bottom: u64,
        left: u64,
        right: u64,
    };

    /// Window external position - marks a window as external (separate OS window)
    pub const WinExternalPos = struct {
        grid: u64,
        win: u64,
    };

    /// Highlight group name to ID mapping
    pub const HlGroupSet = struct {
        name: []const u8,
        hl_id: u64,

        pub fn deinit(self: *HlGroupSet, alloc: Allocator) void {
            alloc.free(self.name);
        }
    };

    /// Window extmark event (Neovim 0.10+) - extmark positions in a window
    pub const WinExtmark = struct {
        grid: u64,
        win: u64,
        // Extmarks are complex - for now just store basic info
        // Full implementation would need ns_id, mark_id, row, col, etc.
    };

    /// Popup menu item
    pub const PopupmenuItem = struct {
        word: []const u8,
        kind: []const u8,
        menu: []const u8,
        info: []const u8,
    };

    /// Popup menu show event
    pub const PopupmenuShow = struct {
        items: []PopupmenuItem,
        selected: i64,
        row: u64,
        col: u64,
        grid: u64,

        pub fn deinit(self: *PopupmenuShow, alloc: Allocator) void {
            for (self.items) |item| {
                alloc.free(item.word);
                alloc.free(item.kind);
                alloc.free(item.menu);
                alloc.free(item.info);
            }
            alloc.free(self.items);
        }
    };

    /// Popup menu select event
    pub const PopupmenuSelect = struct {
        selected: i64,
    };

    /// Tab info for tabline
    pub const TabInfo = struct {
        id: u64,
        name: []const u8,
    };

    /// Tabline update event
    pub const TablineUpdate = struct {
        current_tab: u64,
        tabs: []TabInfo,

        pub fn deinit(self: *TablineUpdate, alloc: Allocator) void {
            for (self.tabs) |tab| {
                alloc.free(tab.name);
            }
            alloc.free(self.tabs);
        }
    };

    pub fn deinit(self: *Event, alloc: Allocator) void {
        switch (self.*) {
            .grid_line => |*gl| gl.deinit(alloc),
            .option_set => |*os| os.deinit(alloc),
            .set_title => |title| alloc.free(title),
            .set_icon => |icon| alloc.free(icon),
            .mode_info_set => |*mis| mis.deinit(alloc),
            .cmdline_show => |*cs| cs.deinit(alloc),
            .cmdline_special_char => |*csc| csc.deinit(alloc),
            .cmdline_block_show => |*cbs| cbs.deinit(alloc),
            .cmdline_block_append => |*cba| cba.deinit(alloc),
            .msg_show => |*ms| ms.deinit(alloc),
            .msg_showmode => |*msm| msm.deinit(alloc),
            .msg_showcmd => |*msc| msc.deinit(alloc),
            .msg_ruler => |*mr| mr.deinit(alloc),
            .msg_history_show => |*mhs| mhs.deinit(alloc),
            .hl_group_set => |*hgs| hgs.deinit(alloc),
            .popupmenu_show => |*ps| ps.deinit(alloc),
            .tabline_update => |*tu| tu.deinit(alloc),
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

    // Working directory for spawning Neovim
    cwd: ?[]const u8 = null,

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
    pub fn initEmbedded(alloc: Allocator, event_queue: *EventQueue, cwd: ?[]const u8) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .mode = .embedded,
            .event_queue = event_queue,
            .cwd = if (cwd) |c| try alloc.dupe(u8, c) else null,
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

        // Free cwd if allocated
        if (self.cwd) |c| {
            self.alloc.free(c);
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
                log.info("Spawning embedded Neovim with user config (cwd: {?s})", .{self.cwd});

                // Spawn nvim --headless --embed
                // Note: --embed mode still loads user config (init.lua/init.vim)
                // unlike --headless alone which skips some initialization
                var child = std.process.Child.init(&.{ "nvim", "--embed" }, self.alloc);
                child.stdin_behavior = .Pipe;
                child.stdout_behavior = .Pipe;
                child.stderr_behavior = .Inherit;
                child.cwd = self.cwd;

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
        // NOTE: Do NOT enable ext_messages or ext_cmdline - they conflict with noice.nvim
        // and other plugins that handle messages/cmdline themselves.
        // Neovide also doesn't enable these - it handles msg_set_pos events instead.
        // ext_hlstate gives us detailed highlight info including winhighlight resolution
        const opts = try msgpack.object(self.alloc, .{
            .rgb = true,
            .ext_linegrid = true,
            .ext_multigrid = true,
            .ext_hlstate = true,
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
        log.info("Resizing UI: {}x{}", .{ width, height });

        const params = try msgpack.array(self.alloc, .{
            @as(u64, width),
            @as(u64, height),
        });

        const notification = protocol.message.Notification{
            .method = "nvim_ui_try_resize",
            .params = params,
        };

        const encoded = try encoder.encodeNotification(self.alloc, notification);
        defer self.alloc.free(encoded);
        params.free(self.alloc);

        // Write directly instead of queuing
        try self.writeData(encoded);
    }

    /// Send a command to Neovim
    pub fn sendCommand(self: *Self, cmd: []const u8) !void {
        const str_val = try msgpack.string(self.alloc, cmd);
        const params = try msgpack.array(self.alloc, .{str_val});

        const notification = protocol.message.Notification{
            .method = "nvim_command",
            .params = params,
        };

        const encoded = try encoder.encodeNotification(self.alloc, notification);
        defer self.alloc.free(encoded);
        params.free(self.alloc);

        try self.writeData(encoded);
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

    /// Send nvim_input_mouse for mouse events with grid targeting (like Neovide)
    /// This allows scroll events to target specific windows by grid ID and position
    pub fn sendInputMouse(
        self: *Self,
        button: []const u8,
        action: []const u8,
        modifier: []const u8,
        grid: u64,
        row: u64,
        col: u64,
    ) !void {
        // nvim_input_mouse(button, action, modifier, grid, row, col)
        const button_val = try msgpack.string(self.alloc, button);
        const action_val = try msgpack.string(self.alloc, action);
        const modifier_val = try msgpack.string(self.alloc, modifier);

        const params = try msgpack.array(self.alloc, .{
            button_val,
            action_val,
            modifier_val,
            grid,
            row,
            col,
        });
        defer params.free(self.alloc);

        const notification = protocol.message.Notification{
            .method = "nvim_input_mouse",
            .params = params,
        };

        const encoded = try encoder.encodeNotification(self.alloc, notification);
        defer self.alloc.free(encoded);

        try self.writeData(encoded);
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
                        log.info("Neovim connection closed - sending nvim_exited event", .{});
                        self.event_queue.push(.nvim_exited) catch {};
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
        } else if (std.mem.eql(u8, name, "grid_destroy")) {
            if (args.len >= 1) {
                if (extractU64(args[0])) |grid| {
                    try self.event_queue.push(.{ .grid_destroy = grid });
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
            // win_float_pos: [grid, win, anchor, anchor_grid, anchor_row, anchor_col, focusable, zindex, compindex, screen_row, screen_col]
            // Newer Neovim versions provide screen_row and screen_col which are the final calculated positions
            if (args.len >= 8) {
                const grid = extractU64(args[0]) orelse {
                    log.err("win_float_pos: failed to extract grid from args[0]", .{});
                    return;
                };
                // Window handle is often an ext type (window handle) that we can't easily parse
                const win = extractU64(args[1]) orelse grid;
                const zindex = extractU64(args[7]) orelse 50;

                // Try to use screen_row/screen_col if available (args[9] and args[10])
                // These are the pre-calculated screen positions from Neovim
                var use_screen_pos = false;
                var screen_row: f32 = 0;
                var screen_col: f32 = 0;

                if (args.len >= 11) {
                    if (extractF32(args[9])) |sr| {
                        if (extractF32(args[10])) |sc| {
                            screen_row = sr;
                            screen_col = sc;
                            use_screen_pos = true;
                            log.info("win_float_pos: grid={} using screen_pos=({d:.1},{d:.1}) zindex={}", .{ grid, screen_col, screen_row, zindex });
                        }
                    }
                }

                if (use_screen_pos) {
                    // Use the pre-calculated screen position from Neovim
                    // This is simpler and more reliable than calculating from anchor
                    try self.event_queue.push(.{
                        .win_float_pos = .{
                            .grid = grid,
                            .win = win,
                            .anchor = .NW, // Position is absolute, so anchor doesn't matter
                            .anchor_grid = 1, // Relative to main grid
                            .anchor_row = screen_row,
                            .anchor_col = screen_col,
                            .focusable = extractBool(args[6]),
                            .zindex = zindex,
                        },
                    });
                } else {
                    // Fall back to anchor-based positioning for older Neovim versions
                    const anchor_grid = extractU64(args[3]) orelse {
                        log.err("win_float_pos: failed to extract anchor_grid from args[3], grid={}", .{grid});
                        return;
                    };
                    const anchor_row = extractF32(args[4]) orelse 0;
                    const anchor_col = extractF32(args[5]) orelse 0;

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

                    log.info("win_float_pos: grid={} anchor={s} anchor_grid={} row={d:.1} col={d:.1} zindex={}", .{ grid, anchor_str, anchor_grid, anchor_row, anchor_col, zindex });
                    try self.event_queue.push(.{ .win_float_pos = .{
                        .grid = grid,
                        .win = win,
                        .anchor = anchor,
                        .anchor_grid = anchor_grid,
                        .anchor_row = anchor_row,
                        .anchor_col = anchor_col,
                        .focusable = extractBool(args[6]),
                        .zindex = zindex,
                    } });
                }
            } else {
                log.err("win_float_pos: args.len={} < 8, skipping", .{args.len});
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
                const scroll_delta = extractI64(args[7]) orelse 0;
                const grid = extractU64(args[0]) orelse return;
                if (scroll_delta != 0) {
                    log.debug("win_viewport: grid={} scroll_delta={}", .{ grid, scroll_delta });
                }
                // Note: args[1] is 'win' which is an ext type (window handle), not a u64
                // We don't need it for scroll animation, so just skip it
                try self.event_queue.push(.{
                    .win_viewport = .{
                        .grid = grid,
                        .win = 0, // Not used - the real win is an ext type we can't extract
                        .topline = extractU64(args[2]) orelse 0,
                        .botline = extractU64(args[3]) orelse 0,
                        .curline = extractU64(args[4]) orelse 0,
                        .curcol = extractU64(args[5]) orelse 0,
                        .line_count = extractU64(args[6]) orelse 0,
                        .scroll_delta = scroll_delta,
                    },
                });
            }
        } else if (std.mem.eql(u8, name, "msg_set_pos")) {
            // msg_set_pos: [grid, row, scrolled, sep_char, zindex, compindex]
            if (args.len >= 3) {
                const grid = extractU64(args[0]) orelse return;
                const row = extractU64(args[1]) orelse return;
                const scrolled = extractBool(args[2]);
                const zindex = if (args.len >= 5) extractU64(args[4]) orelse 200 else 200;
                log.info("msg_set_pos: grid={} row={} scrolled={} zindex={}", .{ grid, row, scrolled, zindex });
                try self.event_queue.push(.{ .msg_set_pos = .{
                    .grid = grid,
                    .row = row,
                    .scrolled = scrolled,
                    .zindex = zindex,
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
        } else if (std.mem.eql(u8, name, "mode_info_set")) {
            try self.handleModeInfoSet(args);
        } else if (std.mem.eql(u8, name, "mode_change")) {
            // mode_change: [mode_name, mode_idx]
            if (args.len >= 2) {
                const mode_idx = extractU64(args[1]) orelse 0;
                const mode_name = if (args[0] == .str) args[0].str.value() else "unknown";
                log.info("mode_change: mode='{s}' idx={}", .{ mode_name, mode_idx });
                try self.event_queue.push(.{ .mode_change = .{
                    .mode_idx = mode_idx,
                } });
            }
        } else if (std.mem.eql(u8, name, "busy_start")) {
            try self.event_queue.push(.busy_start);
        } else if (std.mem.eql(u8, name, "busy_stop")) {
            try self.event_queue.push(.busy_stop);
        } else if (std.mem.eql(u8, name, "mouse_on")) {
            try self.event_queue.push(.mouse_on);
        } else if (std.mem.eql(u8, name, "mouse_off")) {
            try self.event_queue.push(.mouse_off);
        } else if (std.mem.eql(u8, name, "suspend")) {
            try self.event_queue.push(.suspend_event);
        } else if (std.mem.eql(u8, name, "restart")) {
            try self.event_queue.push(.restart);
        } else if (std.mem.eql(u8, name, "set_title")) {
            if (args.len >= 1) {
                const title = switch (args[0]) {
                    .str => |s| s.value(),
                    else => return,
                };
                // Dupe the string since args will be freed
                const duped = try self.alloc.dupe(u8, title);
                try self.event_queue.push(.{ .set_title = duped });
            }
        } else if (std.mem.eql(u8, name, "set_icon")) {
            if (args.len >= 1) {
                const icon = switch (args[0]) {
                    .str => |s| s.value(),
                    else => return,
                };
                // Dupe the string since args will be freed
                const duped = try self.alloc.dupe(u8, icon);
                try self.event_queue.push(.{ .set_icon = duped });
            }
        } else if (std.mem.eql(u8, name, "win_viewport_margins")) {
            // win_viewport_margins: [grid, win, top, bottom, left, right]
            // DEBUG: Log what we actually receive
            log.err("win_viewport_margins RAW: args.len={}", .{args.len});
            for (args, 0..) |arg, i| {
                log.err("  arg[{}] = {}", .{ i, arg });
            }
            if (args.len >= 6) {
                const grid = extractU64(args[0]) orelse return;
                const win = extractU64(args[1]) orelse 0;
                const top = extractU64(args[2]) orelse 0;
                const bottom = extractU64(args[3]) orelse 0;
                const left = extractU64(args[4]) orelse 0;
                const right = extractU64(args[5]) orelse 0;
                log.err("win_viewport_margins PARSED: grid={} win={} top={} bottom={} left={} right={}", .{ grid, win, top, bottom, left, right });
                try self.event_queue.push(.{ .win_viewport_margins = .{
                    .grid = grid,
                    .win = win,
                    .top = top,
                    .bottom = bottom,
                    .left = left,
                    .right = right,
                } });
            }
        } else if (std.mem.eql(u8, name, "win_external_pos")) {
            // win_external_pos: [grid, win]
            if (args.len >= 2) {
                const grid = extractU64(args[0]) orelse return;
                const win = extractU64(args[1]) orelse 0;
                log.info("win_external_pos: grid={} win={}", .{ grid, win });
                try self.event_queue.push(.{ .win_external_pos = .{
                    .grid = grid,
                    .win = win,
                } });
            }
        } else if (std.mem.eql(u8, name, "option_set")) {
            // option_set: [name, value]
            // Value can be string, integer, or boolean depending on the option
            if (args.len >= 2) {
                const opt_name = switch (args[0]) {
                    .str => |s| s.value(),
                    else => return,
                };

                // Detect value type and extract appropriately
                const value: Event.OptionValue = switch (args[1]) {
                    .str => |s| .{ .string = try self.alloc.dupe(u8, s.value()) },
                    .bool => |b| .{ .boolean = b },
                    .int => |i| .{ .integer = i },
                    .uint => |u| .{ .integer = @intCast(u) },
                    .float => |f| .{ .integer = @intFromFloat(f) },
                    else => return, // Unknown type, skip
                };
                errdefer {
                    switch (value) {
                        .string => |s| self.alloc.free(s),
                        else => {},
                    }
                }

                // Dupe the name since args will be freed
                const duped_name = try self.alloc.dupe(u8, opt_name);
                errdefer self.alloc.free(duped_name);

                log.info("option_set: {s} = {}", .{ duped_name, value });
                try self.event_queue.push(.{ .option_set = .{
                    .name = duped_name,
                    .value = value,
                } });
            }
            // Command line events (ext_cmdline)
        } else if (std.mem.eql(u8, name, "cmdline_show")) {
            try self.handleCmdlineShow(args);
        } else if (std.mem.eql(u8, name, "cmdline_hide")) {
            // cmdline_hide: [level]
            if (args.len >= 1) {
                try self.event_queue.push(.{ .cmdline_hide = .{
                    .level = extractU64(args[0]) orelse 0,
                } });
            }
        } else if (std.mem.eql(u8, name, "cmdline_pos")) {
            // cmdline_pos: [pos, level]
            if (args.len >= 2) {
                try self.event_queue.push(.{ .cmdline_pos = .{
                    .pos = extractU64(args[0]) orelse 0,
                    .level = extractU64(args[1]) orelse 0,
                } });
            }
        } else if (std.mem.eql(u8, name, "cmdline_special_char")) {
            // cmdline_special_char: [c, shift, level]
            if (args.len >= 3) {
                const char = switch (args[0]) {
                    .str => |s| s.value(),
                    else => return,
                };
                const duped_char = try self.alloc.dupe(u8, char);
                try self.event_queue.push(.{ .cmdline_special_char = .{
                    .character = duped_char,
                    .shift = extractBool(args[1]),
                    .level = extractU64(args[2]) orelse 0,
                } });
            }
        } else if (std.mem.eql(u8, name, "cmdline_block_show")) {
            try self.handleCmdlineBlockShow(args);
        } else if (std.mem.eql(u8, name, "cmdline_block_hide")) {
            try self.event_queue.push(.cmdline_block_hide);
        } else if (std.mem.eql(u8, name, "cmdline_block_append")) {
            try self.handleCmdlineBlockAppend(args);
        }
        // Message events (ext_messages)
        else if (std.mem.eql(u8, name, "msg_show")) {
            try self.handleMsgShow(args);
        } else if (std.mem.eql(u8, name, "msg_clear")) {
            try self.event_queue.push(.msg_clear);
        } else if (std.mem.eql(u8, name, "msg_showmode")) {
            try self.handleMsgShowMode(args);
        } else if (std.mem.eql(u8, name, "msg_showcmd")) {
            try self.handleMsgShowCmd(args);
        } else if (std.mem.eql(u8, name, "msg_ruler")) {
            try self.handleMsgRuler(args);
        } else if (std.mem.eql(u8, name, "msg_history_show")) {
            try self.handleMsgHistoryShow(args);
        }
        // Highlight group set
        else if (std.mem.eql(u8, name, "hl_group_set")) {
            // hl_group_set: [name, hl_id]
            if (args.len >= 2) {
                const name_str = switch (args[0]) {
                    .str => |s| s.value(),
                    else => return,
                };
                const duped_name = try self.alloc.dupe(u8, name_str);
                try self.event_queue.push(.{ .hl_group_set = .{
                    .name = duped_name,
                    .hl_id = extractU64(args[1]) orelse 0,
                } });
            }
        }
        // Window extmark (Neovim 0.10+)
        else if (std.mem.eql(u8, name, "win_extmark")) {
            // win_extmark: [grid, win, ...] - simplified for now
            if (args.len >= 2) {
                try self.event_queue.push(.{ .win_extmark = .{
                    .grid = extractU64(args[0]) orelse return,
                    .win = extractU64(args[1]) orelse 0,
                } });
            }
        }
        // Popup menu events (ext_popupmenu)
        else if (std.mem.eql(u8, name, "popupmenu_show")) {
            try self.handlePopupmenuShow(args);
        } else if (std.mem.eql(u8, name, "popupmenu_select")) {
            // popupmenu_select: [selected]
            if (args.len >= 1) {
                try self.event_queue.push(.{ .popupmenu_select = .{
                    .selected = extractI64(args[0]) orelse -1,
                } });
            }
        } else if (std.mem.eql(u8, name, "popupmenu_hide")) {
            try self.event_queue.push(.popupmenu_hide);
        }
        // Tabline events (ext_tabline)
        else if (std.mem.eql(u8, name, "tabline_update")) {
            try self.handleTablineUpdate(args);
        }
        // Log unhandled events to catch any we're missing
        else {
            // Only log events that might be relevant (skip very common ones)
            if (!std.mem.eql(u8, name, "chdir") and
                !std.mem.eql(u8, name, "busy_start") and
                !std.mem.eql(u8, name, "busy_stop"))
            {
                log.debug("Unhandled event: '{s}' with {} args", .{ name, args.len });
            }
        }
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
        // Additional underline styles (Neovim uses both short and long names)
        if (rgb_map.mapGet("underdotted") catch null) |v| {
            attr.underdotted = extractBool(v);
        } else if (rgb_map.mapGet("underdot") catch null) |v| {
            attr.underdotted = extractBool(v);
        }
        if (rgb_map.mapGet("underdashed") catch null) |v| {
            attr.underdashed = extractBool(v);
        } else if (rgb_map.mapGet("underdash") catch null) |v| {
            attr.underdashed = extractBool(v);
        }
        if (rgb_map.mapGet("underdouble") catch null) |v| {
            attr.underdouble = extractBool(v);
        } else if (rgb_map.mapGet("underlineline") catch null) |v| {
            attr.underdouble = extractBool(v);
        }
        if (rgb_map.mapGet("strikethrough") catch null) |v| {
            attr.strikethrough = extractBool(v);
        }
        if (rgb_map.mapGet("reverse") catch null) |v| {
            attr.reverse = extractBool(v);
        }
        if (rgb_map.mapGet("blend") catch null) |v| {
            attr.blend = @intCast(extractU64(v) orelse 0);
        }

        try self.event_queue.push(.{ .hl_attr_define = .{
            .id = id,
            .attr = attr,
        } });
    }

    fn handleModeInfoSet(self: *Self, args: []const Payload) !void {
        // mode_info_set: [cursor_style_enabled, mode_info_list]
        if (args.len < 2) return;

        const cursor_style_enabled = extractBool(args[0]);
        const mode_info_list = switch (args[1]) {
            .arr => |arr| arr,
            else => return,
        };

        log.info("mode_info_set: cursor_style_enabled={} num_modes={}", .{ cursor_style_enabled, mode_info_list.len });

        var cursor_modes = std.ArrayListUnmanaged(Event.CursorMode){};
        errdefer cursor_modes.deinit(self.alloc);

        for (mode_info_list) |mode_info_val| {
            const mode_map = switch (mode_info_val) {
                .map => mode_info_val,
                else => continue,
            };

            var cursor_mode = Event.CursorMode{};

            // Parse cursor_shape
            if (mode_map.mapGet("cursor_shape") catch null) |shape_val| {
                const shape_str = switch (shape_val) {
                    .str => |s| s.value(),
                    else => "",
                };
                if (std.mem.eql(u8, shape_str, "block")) {
                    cursor_mode.shape = .block;
                } else if (std.mem.eql(u8, shape_str, "horizontal")) {
                    cursor_mode.shape = .horizontal;
                } else if (std.mem.eql(u8, shape_str, "vertical")) {
                    cursor_mode.shape = .vertical;
                }
            }

            // Parse cell_percentage (0-100 -> 0.0-1.0)
            if (mode_map.mapGet("cell_percentage") catch null) |pct_val| {
                if (extractU64(pct_val)) |pct| {
                    cursor_mode.cell_percentage = @as(f32, @floatFromInt(pct)) / 100.0;
                }
            }

            // Parse blink timings
            if (mode_map.mapGet("blinkwait") catch null) |v| {
                cursor_mode.blinkwait = extractU64(v);
            }
            if (mode_map.mapGet("blinkon") catch null) |v| {
                cursor_mode.blinkon = extractU64(v);
            }
            if (mode_map.mapGet("blinkoff") catch null) |v| {
                cursor_mode.blinkoff = extractU64(v);
            }

            // Parse attr_id (highlight attribute for cursor)
            if (mode_map.mapGet("attr_id") catch null) |v| {
                cursor_mode.attr_id = extractU64(v);
            }

            try cursor_modes.append(self.alloc, cursor_mode);
        }

        try self.event_queue.push(.{ .mode_info_set = .{
            .cursor_style_enabled = cursor_style_enabled,
            .cursor_modes = try cursor_modes.toOwnedSlice(self.alloc),
        } });
    }

    /// Parse styled content array: [[attr_id, text], [attr_id, text], ...]
    fn parseStyledContent(self: *Self, content_val: Payload) ![]StyledContent {
        const content_arr = switch (content_val) {
            .arr => |arr| arr,
            else => return &[_]StyledContent{},
        };

        var styled = std.ArrayListUnmanaged(StyledContent){};
        errdefer {
            for (styled.items) |sc| {
                self.alloc.free(sc.text);
            }
            styled.deinit(self.alloc);
        }

        for (content_arr) |item| {
            const tuple = switch (item) {
                .arr => |arr| arr,
                else => continue,
            };
            if (tuple.len < 2) continue;

            const attr_id = extractU64(tuple[0]) orelse 0;
            const text = switch (tuple[1]) {
                .str => |s| s.value(),
                else => continue,
            };

            const duped_text = try self.alloc.dupe(u8, text);
            errdefer self.alloc.free(duped_text);

            try styled.append(self.alloc, .{
                .attr_id = attr_id,
                .text = duped_text,
            });
        }

        return try styled.toOwnedSlice(self.alloc);
    }

    fn handleCmdlineShow(self: *Self, args: []const Payload) !void {
        // cmdline_show: [content, pos, firstc, prompt, indent, level]
        if (args.len < 6) return;

        const content = try self.parseStyledContent(args[0]);
        errdefer {
            for (content) |sc| {
                self.alloc.free(sc.text);
            }
            self.alloc.free(content);
        }

        const pos = extractU64(args[1]) orelse 0;

        const firstc = switch (args[2]) {
            .str => |s| s.value(),
            else => "",
        };
        const duped_firstc = try self.alloc.dupe(u8, firstc);
        errdefer self.alloc.free(duped_firstc);

        const prompt = switch (args[3]) {
            .str => |s| s.value(),
            else => "",
        };
        const duped_prompt = try self.alloc.dupe(u8, prompt);
        errdefer self.alloc.free(duped_prompt);

        const indent = extractU64(args[4]) orelse 0;
        const level = extractU64(args[5]) orelse 0;

        try self.event_queue.push(.{ .cmdline_show = .{
            .content = content,
            .pos = pos,
            .firstc = duped_firstc,
            .prompt = duped_prompt,
            .indent = indent,
            .level = level,
        } });
    }

    fn handleCmdlineBlockShow(self: *Self, args: []const Payload) !void {
        // cmdline_block_show: [lines]
        // lines is an array of styled content arrays
        if (args.len < 1) return;

        const lines_arr = switch (args[0]) {
            .arr => |arr| arr,
            else => return,
        };

        var lines = std.ArrayListUnmanaged([]StyledContent){};
        errdefer {
            for (lines.items) |line| {
                for (line) |sc| {
                    self.alloc.free(sc.text);
                }
                self.alloc.free(line);
            }
            lines.deinit(self.alloc);
        }

        for (lines_arr) |line_val| {
            const line = try self.parseStyledContent(line_val);
            try lines.append(self.alloc, line);
        }

        try self.event_queue.push(.{ .cmdline_block_show = .{
            .lines = try lines.toOwnedSlice(self.alloc),
        } });
    }

    fn handleCmdlineBlockAppend(self: *Self, args: []const Payload) !void {
        // cmdline_block_append: [line]
        // line is a styled content array
        if (args.len < 1) return;

        const line = try self.parseStyledContent(args[0]);
        try self.event_queue.push(.{ .cmdline_block_append = .{
            .line = line,
        } });
    }

    // Message event handlers (ext_messages)

    fn handleMsgShow(self: *Self, args: []const Payload) !void {
        // msg_show: [kind, content, replace_last]
        // content is array of [attr_id, text] pairs
        if (args.len < 3) return;

        const kind_str = switch (args[0]) {
            .str => |s| s.value(),
            else => "",
        };
        const kind = MessageKind.parse(kind_str);

        const content = try self.parseStyledContent(args[1]);
        errdefer {
            for (content) |sc| {
                self.alloc.free(sc.text);
            }
            self.alloc.free(content);
        }

        const replace_last = extractBool(args[2]);

        try self.event_queue.push(.{ .msg_show = .{
            .kind = kind,
            .content = content,
            .replace_last = replace_last,
        } });
    }

    fn handleMsgShowMode(self: *Self, args: []const Payload) !void {
        // msg_showmode: [content]
        // content is array of [attr_id, text] pairs
        if (args.len < 1) return;

        const content = try self.parseStyledContent(args[0]);
        try self.event_queue.push(.{ .msg_showmode = .{
            .content = content,
        } });
    }

    fn handleMsgShowCmd(self: *Self, args: []const Payload) !void {
        // msg_showcmd: [content]
        // content is array of [attr_id, text] pairs
        if (args.len < 1) return;

        const content = try self.parseStyledContent(args[0]);
        try self.event_queue.push(.{ .msg_showcmd = .{
            .content = content,
        } });
    }

    fn handleMsgRuler(self: *Self, args: []const Payload) !void {
        // msg_ruler: [content]
        // content is array of [attr_id, text] pairs
        if (args.len < 1) return;

        const content = try self.parseStyledContent(args[0]);
        try self.event_queue.push(.{ .msg_ruler = .{
            .content = content,
        } });
    }

    fn handleMsgHistoryShow(self: *Self, args: []const Payload) !void {
        // msg_history_show: [entries]
        // entries is array of [kind, content] pairs
        if (args.len < 1) return;

        const entries_array = switch (args[0]) {
            .arr => |arr| arr,
            else => return,
        };

        var entries = std.ArrayListUnmanaged(Event.MsgHistoryEntry){};
        errdefer {
            for (entries.items) |entry| {
                for (entry.content) |sc| {
                    self.alloc.free(sc.text);
                }
                self.alloc.free(entry.content);
            }
            entries.deinit(self.alloc);
        }

        for (entries_array) |entry_val| {
            const entry_arr = switch (entry_val) {
                .arr => |arr| arr,
                else => continue,
            };
            if (entry_arr.len < 2) continue;

            const kind_str = switch (entry_arr[0]) {
                .str => |s| s.value(),
                else => "",
            };
            const kind = MessageKind.parse(kind_str);

            const content = try self.parseStyledContent(entry_arr[1]);

            try entries.append(self.alloc, .{
                .kind = kind,
                .content = content,
            });
        }

        try self.event_queue.push(.{ .msg_history_show = .{
            .entries = try entries.toOwnedSlice(self.alloc),
        } });
    }

    // Popup menu event handler
    fn handlePopupmenuShow(self: *Self, args: []const Payload) !void {
        // popupmenu_show: [items, selected, row, col, grid]
        // items is array of [word, kind, menu, info] tuples
        if (args.len < 5) return;

        const items_array = switch (args[0]) {
            .arr => |arr| arr,
            else => return,
        };

        var items = std.ArrayListUnmanaged(Event.PopupmenuItem){};
        errdefer {
            for (items.items) |item| {
                self.alloc.free(item.word);
                self.alloc.free(item.kind);
                self.alloc.free(item.menu);
                self.alloc.free(item.info);
            }
            items.deinit(self.alloc);
        }

        for (items_array) |item_val| {
            const item_arr = switch (item_val) {
                .arr => |arr| arr,
                else => continue,
            };
            if (item_arr.len < 4) continue;

            const word = switch (item_arr[0]) {
                .str => |s| try self.alloc.dupe(u8, s.value()),
                else => try self.alloc.dupe(u8, ""),
            };
            errdefer self.alloc.free(word);

            const kind_str = switch (item_arr[1]) {
                .str => |s| try self.alloc.dupe(u8, s.value()),
                else => try self.alloc.dupe(u8, ""),
            };
            errdefer self.alloc.free(kind_str);

            const menu = switch (item_arr[2]) {
                .str => |s| try self.alloc.dupe(u8, s.value()),
                else => try self.alloc.dupe(u8, ""),
            };
            errdefer self.alloc.free(menu);

            const info = switch (item_arr[3]) {
                .str => |s| try self.alloc.dupe(u8, s.value()),
                else => try self.alloc.dupe(u8, ""),
            };

            try items.append(self.alloc, .{
                .word = word,
                .kind = kind_str,
                .menu = menu,
                .info = info,
            });
        }

        try self.event_queue.push(.{ .popupmenu_show = .{
            .items = try items.toOwnedSlice(self.alloc),
            .selected = extractI64(args[1]) orelse -1,
            .row = extractU64(args[2]) orelse 0,
            .col = extractU64(args[3]) orelse 0,
            .grid = extractU64(args[4]) orelse 0,
        } });
    }

    // Tabline event handler
    fn handleTablineUpdate(self: *Self, args: []const Payload) !void {
        // tabline_update: [current, tabs, curbuf, buffers]
        // tabs is array of {id, name} maps
        if (args.len < 2) return;

        const current_tab = extractU64(args[0]) orelse 0;

        const tabs_array = switch (args[1]) {
            .arr => |arr| arr,
            else => return,
        };

        var tabs = std.ArrayListUnmanaged(Event.TabInfo){};
        errdefer {
            for (tabs.items) |tab| {
                self.alloc.free(tab.name);
            }
            tabs.deinit(self.alloc);
        }

        for (tabs_array) |tab_val| {
            const tab_map = switch (tab_val) {
                .map => tab_val,
                else => continue,
            };

            var tab_id: u64 = 0;
            var tab_name: []const u8 = "";

            // Use mapGet to access map entries
            if (tab_map.mapGet("tab") catch null) |id_val| {
                tab_id = extractU64(id_val) orelse 0;
            }
            if (tab_map.mapGet("name") catch null) |name_val| {
                tab_name = switch (name_val) {
                    .str => |s| s.value(),
                    else => "",
                };
            }

            try tabs.append(self.alloc, .{
                .id = tab_id,
                .name = try self.alloc.dupe(u8, tab_name),
            });
        }

        try self.event_queue.push(.{ .tabline_update = .{
            .current_tab = current_tab,
            .tabs = try tabs.toOwnedSlice(self.alloc),
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
