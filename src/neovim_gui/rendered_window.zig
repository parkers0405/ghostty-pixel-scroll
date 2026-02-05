//! Rendered Window - Per-window state for Neovim GUI
//!
//! This is a faithful port of Neovide's RenderedWindow concept. Each Neovim window
//! (grid) has its own:
//! - actual_lines: Ring buffer with current viewport content (rotated by grid_scroll)
//! - scrollback_lines: Ring buffer 2x viewport height for smooth scroll animation
//! - scroll_animation: Critically damped spring for pixel-perfect smooth scrolling
//! - viewport_margins: Fixed rows at top/bottom (winbar, statusline, etc.)
//!
//! Key insight from Neovide:
//! - grid_scroll rotates actual_lines (content movement)
//! - win_viewport provides scroll_delta for animation
//! - On flush: rotate scrollback by scroll_delta, copy actual_lines into scrollback
//! - On render: read from scrollback_lines[floor(scroll_pos) + row]
//! - The animation position animates toward 0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Animation = @import("animation.zig");
const io_thread = @import("io_thread.zig");

const log = std.log.scoped(.rendered_window);

/// Scroll command parameters from grid_scroll event
pub const ScrollCommand = struct {
    top: u64,
    bottom: u64,
    left: u64,
    right: u64,
    rows: i64,
    cols: i64,
};

/// A cell in the grid - stores text and highlight info
pub const GridCell = struct {
    /// UTF-8 text content (can be empty, single char, or multi-byte grapheme)
    text: [16]u8 = .{0} ** 16,
    text_len: u8 = 0,
    /// Highlight group ID
    hl_id: u64 = 0,
    /// Double-width flag (this cell is the left half of a wide char)
    double_width: bool = false,
    /// This cell is the right half of a wide char (continuation)
    is_continuation: bool = false,

    pub fn setText(self: *GridCell, str: []const u8) void {
        const len = @min(str.len, 16);
        @memcpy(self.text[0..len], str[0..len]);
        self.text_len = @intCast(len);
    }

    pub fn getText(self: *const GridCell) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn clear(self: *GridCell) void {
        self.text_len = 0;
        self.hl_id = 0;
        self.double_width = false;
        self.is_continuation = false;
    }

    pub fn copyFrom(self: *GridCell, other: *const GridCell) void {
        self.* = other.*;
    }
};

/// A single line of cells (row in the grid)
pub const GridLine = struct {
    cells: []GridCell,
    alloc: Allocator,

    pub fn init(alloc: Allocator, width: u32) !*GridLine {
        const self = try alloc.create(GridLine);
        errdefer alloc.destroy(self);

        self.cells = try alloc.alloc(GridCell, width);
        self.alloc = alloc;
        for (self.cells) |*cell| {
            cell.* = GridCell{};
        }
        return self;
    }

    pub fn deinit(self: *GridLine) void {
        if (self.cells.len > 0) {
            self.alloc.free(self.cells);
        }
        self.alloc.destroy(self);
    }

    pub fn clear(self: *GridLine) void {
        for (self.cells) |*cell| {
            cell.clear();
        }
    }

    pub fn copyFromSlice(self: *GridLine, cells: []const GridCell) void {
        const len = @min(self.cells.len, cells.len);
        for (0..len) |i| {
            self.cells[i].copyFrom(&cells[i]);
        }
    }

    /// Resize the line width, preserving existing content where possible
    /// Used to optimize nvim-tree animation (only width changes, not height)
    pub fn resizeWidth(self: *GridLine, alloc: Allocator, new_width: u32) !void {
        if (self.cells.len == new_width) return;

        const old_cells = self.cells;
        const old_width = old_cells.len;

        // Allocate new cell array
        const new_cells = try alloc.alloc(GridCell, new_width);

        // Copy old content and initialize new cells
        if (new_width > old_width) {
            // Growing: copy all old cells, init new ones
            @memcpy(new_cells[0..old_width], old_cells);
            for (new_cells[old_width..]) |*cell| {
                cell.* = GridCell{};
            }
        } else {
            // Shrinking: copy what fits
            @memcpy(new_cells, old_cells[0..new_width]);
        }

        // Free old array and update
        alloc.free(old_cells);
        self.cells = new_cells;
    }
};

/// Ring buffer for efficient scrolling - O(1) rotation via index adjustment
/// Supports negative indexing via euclidean modulo (like Neovide)
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: []T,
        /// Logical index 0 maps to this array index
        current_index: isize = 0,
        alloc: Allocator,

        pub fn init(alloc: Allocator, size: usize) !Self {
            const elements = try alloc.alloc(T, size);
            for (elements) |*e| {
                e.* = null;
            }
            return .{
                .elements = elements,
                .current_index = 0,
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free any GridLine pointers stored in the buffer
            for (self.elements) |maybe_line| {
                if (maybe_line) |line| {
                    line.deinit();
                }
            }
            self.alloc.free(self.elements);
        }

        /// O(1) rotation - just adjust the logical index
        pub fn rotate(self: *Self, amount: isize) void {
            self.current_index += amount;
        }

        /// Get array index from logical index using euclidean modulo
        fn getArrayIndex(self: *const Self, logical_index: isize) usize {
            const len: isize = @intCast(self.elements.len);
            // Euclidean modulo handles negative indices correctly
            return @intCast(@mod(self.current_index + logical_index, len));
        }

        pub fn get(self: *Self, logical_index: isize) *T {
            return &self.elements[self.getArrayIndex(logical_index)];
        }

        pub fn getConst(self: *const Self, logical_index: isize) T {
            return self.elements[self.getArrayIndex(logical_index)];
        }

        pub fn set(self: *Self, logical_index: isize, value: T) void {
            self.elements[self.getArrayIndex(logical_index)] = value;
        }

        pub fn length(self: *const Self) usize {
            return self.elements.len;
        }

        /// Reset to initial state
        pub fn reset(self: *Self) void {
            self.current_index = 0;
        }

        /// Clone content from an iterator into positions 0..n
        pub fn cloneFromIter(self: *Self, iter: anytype) void {
            var i: isize = 0;
            while (iter.next()) |item| {
                self.set(i, item);
                i += 1;
            }
        }
    };
}

pub const WindowType = enum {
    editor,
    message,
    floating,
};

/// Anchor info - if present, window is floating; if null, window is a root window
pub const AnchorInfo = struct {
    anchor_grid_id: u64,
    anchor_left: f32,
    anchor_top: f32,
    z_index: u64,
};

/// Pending anchor info for recalculating position after resize
pub const PendingAnchor = struct {
    /// Use the same Anchor type as the event to avoid conversion
    anchor: io_thread.Event.WinFloatPos.Anchor,
    anchor_grid: u64,
    anchor_row: f32,
    anchor_col: f32,
    zindex: u64,
};

/// Viewport margins - fixed rows/cols that don't scroll (winbar, borders, etc.)
pub const ViewportMargins = struct {
    top: u32 = 0,
    bottom: u32 = 0,
    left: u32 = 0,
    right: u32 = 0,
};

/// Scroll animation settings
pub const ScrollSettings = struct {
    /// Animation duration in seconds
    /// Neovide default is 0.3s for smooth, lag-free scrolling
    animation_length: f32 = 0.3,
    /// For "far" scrolls (> buffer capacity), show this many lines of animation
    scroll_animation_far_lines: u32 = 1,
};

/// Per-window rendering state - faithful port of Neovide's RenderedWindow
pub const RenderedWindow = struct {
    const Self = @This();

    alloc: Allocator,

    /// Grid ID from Neovim
    id: u64,

    /// Whether this window is valid/visible
    valid: bool = false,
    hidden: bool = false,

    /// Whether this window has received a win_pos event
    /// Windows without position should not be rendered (except grid 1)
    has_position: bool = false,

    /// After resize, we need to receive content before rendering
    /// This prevents black flashes when scrollback is populated with empty lines
    needs_content: bool = false,

    /// Window type
    window_type: WindowType = .editor,

    /// Grid dimensions (buffer size - from grid_resize)
    grid_width: u32 = 0,
    grid_height: u32 = 0,

    /// Display dimensions (from win_pos - may differ from grid dimensions during resize)
    /// These are the dimensions we should use for RENDERING, as they reflect the
    /// actual visible area reported by Neovim. This fixes artifacts during resize
    /// animations where win_pos arrives before grid_resize.
    display_width: u32 = 0,
    display_height: u32 = 0,

    /// Position in grid coordinates (col, row)
    grid_position: [2]f32 = .{ 0, 0 },

    /// Target position for animation
    target_position: [2]f32 = .{ 0, 0 },

    /// Position animation springs
    position_spring_x: Animation.CriticallyDampedSpring = .{},
    position_spring_y: Animation.CriticallyDampedSpring = .{},

    /// Z-index for floating windows (higher = on top)
    zindex: u64 = 0,

    /// Anchor info - if not null, this is a floating window
    anchor_info: ?AnchorInfo = null,

    /// Pending anchor info - stored when win_float_pos arrives before grid_resize
    /// Used to recalculate position when resize happens
    pending_anchor: ?PendingAnchor = null,

    /// The actual lines - current viewport content from Neovim
    /// This is what Neovim sees - rotated by grid_scroll
    actual_lines: ?RingBuffer(?*GridLine) = null,

    /// Scrollback buffer - 2x viewport height for smooth scroll animation
    /// Used during rendering to show content during scroll animation
    scrollback_lines: ?RingBuffer(?*GridLine) = null,

    /// Pending scroll delta from win_viewport (for animation)
    scroll_delta: isize = 0,

    /// Whether this window has ever received a non-zero scroll_delta
    /// Used to disable smooth scroll for windows like nvim-tree that don't really scroll
    has_scrolled: bool = false,

    /// Fixed rows/cols at edges (winbar, borders, etc.)
    viewport_margins: ViewportMargins = .{},

    /// Whether this window is external (separate OS window)
    is_external: bool = false,

    /// Scroll animation using critically damped spring (Neovide-style)
    /// Position represents offset from final position:
    /// - 0 = at final position
    /// - negative = content needs to move down
    /// - positive = content needs to move up
    scroll_animation: Animation.CriticallyDampedSpring = .{},

    /// Scroll settings
    scroll_settings: ScrollSettings = .{},

    /// Position animation length
    position_animation_length: f32 = 0.15,

    /// Dirty flag - set when content changes
    dirty: bool = true,

    pub fn init(alloc: Allocator, id: u64) Self {
        return .{
            .alloc = alloc,
            .id = id,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free actual_lines buffer
        if (self.actual_lines) |*al| {
            al.deinit();
        }

        // Free scrollback buffer
        if (self.scrollback_lines) |*sb| {
            sb.deinit();
        }
    }

    pub fn resize(self: *Self, width: u32, height: u32) !void {
        if (width == self.grid_width and height == self.grid_height) return;

        log.debug("Window {} resize: {}x{} -> {}x{}", .{
            self.id,
            self.grid_width,
            self.grid_height,
            width,
            height,
        });

        // Grid 1 is special - it's the outer container with statusline/cmdline at the bottom.
        // Don't preserve content for grid 1 since positions change completely on resize.
        // Also don't preserve if we have no old content to preserve.
        // Also don't preserve if width is SHRINKING - this causes color bleeding artifacts
        // from statusline/tabline highlights that extend to the window edge.
        const width_shrinking = (self.grid_width > 0) and (width < self.grid_width);
        const should_preserve = (self.id != 1) and (self.actual_lines != null) and (self.grid_height > 0) and !width_shrinking;

        // Optimization: if only width changed and height is the same, just resize existing lines
        // This is common during nvim-tree animations (1x25 -> 2x25 -> 3x25 -> ...)
        // Only use this fast path when GROWING - shrinking can cause color artifacts
        const height_unchanged = (height == self.grid_height and self.actual_lines != null);
        const width_growing = (width > self.grid_width);
        if (height_unchanged and width_growing) {
            // Just resize each line's cell array
            if (self.actual_lines) |*al| {
                var i: u32 = 0;
                while (i < height) : (i += 1) {
                    if (al.getConst(@intCast(i))) |line| {
                        line.resizeWidth(self.alloc, width) catch {};
                    }
                }
            }
            if (self.scrollback_lines) |*sb| {
                var i: u32 = 0;
                const sb_size = sb.length();
                while (i < sb_size) : (i += 1) {
                    const ptr = sb.get(@intCast(i));
                    if (ptr.*) |line| {
                        line.resizeWidth(self.alloc, width) catch {};
                    }
                }
            }
            self.grid_width = width;
            self.dirty = true;
            return;
        }

        // Preserve old content during resize to prevent black flashes
        // This is critical for smooth animations (hy3 layout changes, nvim-tree, etc.)
        // But NOT for grid 1 (outer container) where statusline position changes
        const old_actual = if (should_preserve) self.actual_lines else null;
        const old_scrollback = self.scrollback_lines;
        const old_width = if (should_preserve) self.grid_width else 0;
        const old_height = if (should_preserve) self.grid_height else 0;

        // Allocate new actual_lines (viewport height)
        var new_actual = try RingBuffer(?*GridLine).init(self.alloc, height);
        errdefer new_actual.deinit();

        // Initialize actual_lines with new GridLine objects, copying old content where possible
        var i: u32 = 0;
        while (i < height) : (i += 1) {
            const line = try GridLine.init(self.alloc, width);
            // Copy content from old buffer if available (only for non-grid1 windows)
            if (old_actual != null and i < old_height) {
                if (old_actual.?.getConst(@intCast(i))) |old_line| {
                    const copy_width = @min(width, old_width);
                    var col: u32 = 0;
                    while (col < copy_width) : (col += 1) {
                        line.cells[col].copyFrom(&old_line.cells[col]);
                    }
                }
            }
            new_actual.set(@intCast(i), line);
        }

        // Allocate scrollback (2x viewport height)
        const scrollback_size = height * 2;
        var new_scrollback = try RingBuffer(?*GridLine).init(self.alloc, scrollback_size);
        errdefer new_scrollback.deinit();

        // Initialize scrollback with content from actual_lines
        i = 0;
        while (i < height) : (i += 1) {
            const line = try GridLine.init(self.alloc, width);
            // Copy from new actual_lines
            if (new_actual.getConst(@intCast(i))) |src| {
                line.copyFromSlice(src.cells);
            }
            new_scrollback.set(@intCast(i), line);
        }
        // Populate second half with same content (for scroll down support)
        while (i < scrollback_size) : (i += 1) {
            const line = try GridLine.init(self.alloc, width);
            // Copy from corresponding position in first half
            const src_idx = i - height;
            if (new_actual.getConst(@intCast(src_idx))) |src| {
                line.copyFromSlice(src.cells);
            }
            new_scrollback.set(@intCast(i), line);
        }

        // Now free old buffers AFTER new ones are ready
        // Note: old_actual may be null if we didn't preserve (grid 1), but self.actual_lines has the real old value
        if (self.actual_lines) |*al| {
            var al_mut = al.*;
            al_mut.deinit();
        }
        if (old_scrollback) |*sb| {
            var sb_mut = sb.*;
            sb_mut.deinit();
        }

        // Install new buffers
        self.actual_lines = new_actual;
        self.scrollback_lines = new_scrollback;
        self.grid_width = width;
        self.grid_height = height;
        self.scroll_delta = 0;
        self.scroll_animation.reset();
        self.valid = true;
        self.dirty = true;
        // Don't set needs_content since we preserved old content - it's safe to render immediately
    }

    pub fn clear(self: *Self) void {
        if (self.actual_lines) |*al| {
            var i: usize = 0;
            while (i < al.length()) : (i += 1) {
                if (al.getConst(@intCast(i))) |line| {
                    line.clear();
                }
            }
        }

        // Clear scrollback and reset animation
        if (self.scrollback_lines) |*sb| {
            var i: usize = 0;
            while (i < sb.length()) : (i += 1) {
                const ptr = sb.get(@intCast(i));
                if (ptr.*) |line| {
                    line.deinit();
                    ptr.* = null;
                }
            }
            sb.reset();
        }
        self.scroll_delta = 0;
        self.scroll_animation.reset();
        self.dirty = true;
    }

    /// Set a cell in actual_lines (used by grid_line events)
    pub fn setCell(self: *Self, row: u32, col: u32, text: []const u8, hl_id: u64) void {
        if (self.actual_lines == null) return;
        if (row >= self.grid_height or col >= self.grid_width) return;

        const line = self.actual_lines.?.getConst(@intCast(row)) orelse return;
        if (col >= line.cells.len) return;

        line.cells[col].setText(text);
        line.cells[col].hl_id = hl_id;
        self.dirty = true;
        // Content received - safe to render this window now
        self.needs_content = false;
    }

    pub fn setPosition(self: *Self, row: u64, col: u64, width: u64, height: u64) void {
        self.grid_position = .{ @floatFromInt(col), @floatFromInt(row) };
        self.target_position = self.grid_position;
        self.position_spring_x.position = 0;
        self.position_spring_y.position = 0;

        // Update display dimensions from win_pos
        // These may differ from grid_width/grid_height during resize animations
        // win_pos arrives BEFORE grid_resize, so we use these for rendering
        self.display_width = @intCast(width);
        self.display_height = @intCast(height);

        self.valid = true;
        self.hidden = false;
        self.has_position = true;
        // DON'T reset zindex/window_type if already set as floating
        // win_pos can come after win_float_pos and we don't want to lose the float info
        // Only reset if this is being set as a docked window (zindex was 0)
        if (self.window_type != .floating and self.window_type != .message) {
            self.zindex = 0;
            self.anchor_info = null;
            self.window_type = .editor;
        }
    }

    pub fn setFloatPosition(self: *Self, row: u64, col: u64, zindex: u64) void {
        const new_x: f32 = @floatFromInt(col);
        const new_y: f32 = @floatFromInt(row);

        self.grid_position = .{ new_x, new_y };
        self.target_position = .{ new_x, new_y };
        self.position_spring_x.position = 0;
        self.position_spring_y.position = 0;

        self.valid = true;
        self.hidden = false;
        self.has_position = true; // Floating windows have positions too!
        self.zindex = zindex;
        self.window_type = .floating;
        self.anchor_info = .{
            .anchor_grid_id = 1,
            .anchor_left = new_x,
            .anchor_top = new_y,
            .z_index = zindex,
        };
    }

    pub fn setMessagePosition(self: *Self, row: u64, zindex: u64, parent_width: u32) void {
        _ = parent_width;
        const new_y: f32 = @floatFromInt(row);

        self.grid_position = .{ 0, new_y };
        self.target_position = .{ 0, new_y };
        self.position_spring_x.position = 0;
        self.position_spring_y.position = 0;

        self.valid = true;
        self.hidden = false;
        self.has_position = true; // Message windows have positions too!
        self.zindex = zindex;
        self.window_type = .message;
        self.anchor_info = .{
            .anchor_grid_id = 1,
            .anchor_left = 0,
            .anchor_top = new_y,
            .z_index = zindex,
        };
    }

    /// Handle win_viewport event - sets scroll_delta for animation (like Neovide)
    /// IMPORTANT: Only set scroll_delta when non-zero! Neovim sends multiple win_viewport
    /// events per scroll - one with the actual delta, then one with delta=0 to "confirm".
    /// If we blindly accept 0, it overwrites the real delta before flush() processes it.
    /// This matches Neovide's behavior of using Option<i64> and only acting on Some values.
    pub fn setViewport(self: *Self, topline: u64, botline: u64, scroll_delta: i64) void {
        _ = topline;
        _ = botline;
        // Only set scroll_delta when non-zero - ignore the "confirmation" events with delta=0
        if (scroll_delta != 0) {
            self.scroll_delta = @intCast(scroll_delta);
            self.has_scrolled = true; // Mark that this window can scroll
        }
    }

    /// Handle grid_scroll event - rotates actual_lines (content movement)
    /// This is called when Neovim scrolls content. We rotate actual_lines.
    /// NOTE: scroll_delta for animation comes from win_viewport, not here.
    pub fn handleScroll(self: *Self, cmd: ScrollCommand) void {
        const top = @as(u32, @intCast(cmd.top));
        const bot = @as(u32, @intCast(cmd.bottom));
        const left = @as(u32, @intCast(cmd.left));
        const right = @as(u32, @intCast(cmd.right));
        const rows = cmd.rows;

        if (rows == 0) return;
        if (self.grid_width == 0 or self.grid_height == 0) return;
        if (self.actual_lines == null) return;

        // Only do simple rotation if it's a full-width scroll of the entire grid
        // (Like Neovide does)
        if (top == 0 and bot == self.grid_height and left == 0 and right == self.grid_width) {
            self.actual_lines.?.rotate(rows);
        } else {
            // Partial scroll - need to actually move cells
            // This is more complex, handle the traditional way
            self.handlePartialScroll(top, bot, left, right, rows);
        }

        self.dirty = true;
    }

    fn handlePartialScroll(self: *Self, top: u32, bot: u32, left: u32, right: u32, rows: i64) void {
        if (self.actual_lines == null) return;

        if (rows > 0) {
            // Scrolling up - content moves up
            const scroll_amount: u32 = @intCast(rows);
            var y: u32 = top;
            while (y + scroll_amount < bot) : (y += 1) {
                const dest_line = self.actual_lines.?.getConst(@intCast(y)) orelse continue;
                const src_line = self.actual_lines.?.getConst(@intCast(y + scroll_amount)) orelse continue;

                var x: u32 = left;
                while (x < right) : (x += 1) {
                    if (x < dest_line.cells.len and x < src_line.cells.len) {
                        dest_line.cells[x].copyFrom(&src_line.cells[x]);
                    }
                }
            }
            // Clear newly exposed rows at bottom
            y = bot - scroll_amount;
            while (y < bot) : (y += 1) {
                const line = self.actual_lines.?.getConst(@intCast(y)) orelse continue;
                var x: u32 = left;
                while (x < right) : (x += 1) {
                    if (x < line.cells.len) {
                        line.cells[x].clear();
                    }
                }
            }
        } else {
            // Scrolling down - content moves down
            const scroll_amount: u32 = @intCast(-rows);
            var y: u32 = bot;
            while (y > top + scroll_amount) {
                y -= 1;
                const dest_line = self.actual_lines.?.getConst(@intCast(y)) orelse continue;
                const src_line = self.actual_lines.?.getConst(@intCast(y - scroll_amount)) orelse continue;

                var x: u32 = left;
                while (x < right) : (x += 1) {
                    if (x < dest_line.cells.len and x < src_line.cells.len) {
                        dest_line.cells[x].copyFrom(&src_line.cells[x]);
                    }
                }
            }
            // Clear newly exposed rows at top
            y = top;
            while (y < top + scroll_amount) : (y += 1) {
                const line = self.actual_lines.?.getConst(@intCast(y)) orelse continue;
                var x: u32 = left;
                while (x < right) : (x += 1) {
                    if (x < line.cells.len) {
                        line.cells[x].clear();
                    }
                }
            }
        }
    }

    /// Draw a line of cells from grid_line event
    pub fn drawLine(self: *Self, row: u64, col_start: u64, cells: anytype) void {
        if (self.actual_lines == null) return;
        if (row >= self.grid_height) return;

        const line = self.actual_lines.?.getConst(@intCast(row)) orelse return;

        var col: u64 = col_start;
        for (cells) |cell| {
            const repeat = if (@hasField(@TypeOf(cell), "repeat")) cell.repeat else 1;

            var i: u64 = 0;
            while (i < repeat) : (i += 1) {
                if (col >= self.grid_width) break;
                if (col >= line.cells.len) break;

                line.cells[col].setText(cell.text);
                line.cells[col].hl_id = cell.hl_id;
                col += 1;
            }
        }
        self.dirty = true;
    }

    /// Get the width to use for rendering
    /// Uses display_width (from win_pos) if set, clamped to grid_width (buffer size)
    pub fn getRenderWidth(self: *const Self) u32 {
        if (self.display_width > 0) {
            return @min(self.display_width, self.grid_width);
        }
        return self.grid_width;
    }

    /// Get the height to use for rendering
    /// Uses display_height (from win_pos) if set, clamped to grid_height (buffer size)
    pub fn getRenderHeight(self: *const Self) u32 {
        if (self.display_height > 0) {
            return @min(self.display_height, self.grid_height);
        }
        return self.grid_height;
    }

    /// Get cell from actual_lines (current viewport)
    pub fn getCell(self: *const Self, row: u32, col: u32) ?*const GridCell {
        if (self.actual_lines == null) return null;
        if (row >= self.grid_height or col >= self.grid_width) return null;

        const line = self.actual_lines.?.getConst(@intCast(row)) orelse return null;
        if (col >= line.cells.len) return null;
        return &line.cells[col];
    }

    /// Flush pending updates - called after Neovim's "flush" event
    /// This is where we update the scrollback buffer and animation (Neovide-style)
    pub fn flush(self: *Self) void {
        if (!self.valid) return;
        if (self.actual_lines == null or self.scrollback_lines == null) return;

        var scrollback = &self.scrollback_lines.?;
        const actual = &self.actual_lines.?;

        log.debug("flush: scroll_delta={}, scrollback_idx={}, actual_idx={}", .{
            self.scroll_delta,
            scrollback.current_index,
            actual.current_index,
        });

        // Get inner (scrollable) region bounds (exactly like Neovide)
        const inner_top: isize = @intCast(self.viewport_margins.top);
        const inner_bottom: isize = @intCast(self.grid_height -| self.viewport_margins.bottom);
        const inner_size = inner_bottom - inner_top;

        if (inner_size <= 0) return;

        // Check if scrollback needs resizing (viewport margins changed)
        const expected_scrollback_size: usize = @intCast(inner_size * 2);
        if (scrollback.length() != expected_scrollback_size) {
            // Resize scrollback - this resets the animation
            scrollback.deinit();
            self.scrollback_lines = RingBuffer(?*GridLine).init(self.alloc, expected_scrollback_size) catch return;
            scrollback = &self.scrollback_lines.?;

            // Copy inner view to BOTH halves of scrollback
            // This ensures negative indices (scroll down) have valid data immediately
            var i: isize = 0;
            // First half: scrollback[0..inner_size]
            while (i < inner_size) : (i += 1) {
                const src_row = inner_top + i;
                if (actual.getConst(src_row)) |src_line| {
                    const new_line = GridLine.init(self.alloc, self.grid_width) catch continue;
                    new_line.copyFromSlice(src_line.cells);
                    scrollback.set(i, new_line);
                }
            }
            // Second half: scrollback[inner_size..2*inner_size] (for negative index wrapping)
            while (i < inner_size * 2) : (i += 1) {
                const src_idx = i - inner_size; // Map to first half
                const src_row = inner_top + src_idx;
                if (actual.getConst(src_row)) |src_line| {
                    const new_line = GridLine.init(self.alloc, self.grid_width) catch continue;
                    new_line.copyFromSlice(src_line.cells);
                    scrollback.set(i, new_line);
                }
            }

            self.scroll_delta = 0;
            self.scroll_animation.reset();
            return;
        }

        const scroll_delta = self.scroll_delta;
        self.scroll_delta = 0;

        // Rotate scrollback by scroll_delta
        if (scroll_delta != 0) {
            scrollback.rotate(scroll_delta);
        }

        // ALWAYS copy inner view from actual_lines into scrollback
        // This is required because we don't have GPU buffer caching - scrollback
        // must always reflect current content for rendering
        var i: isize = 0;
        while (i < inner_size) : (i += 1) {
            const src_row = inner_top + i;
            const src_line = actual.getConst(src_row) orelse continue;

            // Get or create scrollback line at position i
            const sb_ptr = scrollback.get(i);
            if (sb_ptr.* == null) {
                sb_ptr.* = GridLine.init(self.alloc, self.grid_width) catch continue;
            }
            if (sb_ptr.*) |sb_line| {
                sb_line.copyFromSlice(src_line.cells);
            }
        }

        // Update scroll animation (Neovide-style: simple accumulation, no capping)
        if (scroll_delta != 0) {
            const current_pos = self.scroll_animation.position;
            const delta_f: f32 = @floatFromInt(scroll_delta);
            const new_delta = -delta_f; // scroll_delta > 0 -> position goes negative
            const new_pos = current_pos + new_delta;

            const max_delta: f32 = @floatFromInt(inner_size);
            self.scroll_animation.position = std.math.clamp(new_pos, -max_delta, max_delta);
        }

        // Content has been flushed - safe to render this window now
        self.needs_content = false;
    }

    /// Animate the window, returns true if still animating
    pub fn animate(self: *Self, dt: f32) bool {
        var animating = false;

        // Animate scroll using critically damped spring (Neovide-style)
        // Use constant animation length - no catchup logic like Neovide
        const anim_length = self.scroll_settings.animation_length;

        if (self.scroll_animation.update(dt, anim_length, 0)) {
            animating = true;
        }

        // Window position: INSTANT (no animation)
        // Neovim plugins like nvim-tree have their own animations - don't interfere
        self.grid_position[0] = self.target_position[0];
        self.grid_position[1] = self.target_position[1];
        self.position_spring_x.reset();
        self.position_spring_y.reset();

        return animating;
    }

    /// Get a cell from the scrollback buffer for rendering during scroll animation.
    /// This reads from scrollback_lines[trunc(scroll_pos) + row] where row is
    /// relative to the inner (scrollable) region.
    ///
    /// Returns null if the position is outside the scrollback buffer or if
    /// this is a margin row (which should be read from actual_lines instead).
    ///
    /// NOTE: Uses @trunc to match getScrollbackCellByInnerRowSigned and getSubLineOffset.
    pub fn getScrollbackCell(self: *const Self, row: u32, col: u32) ?*const GridCell {
        if (self.scrollback_lines == null) return null;
        if (col >= self.grid_width) return null;

        // Check if this is a margin row
        if (row < self.viewport_margins.top) return null;
        if (row >= self.grid_height -| self.viewport_margins.bottom) return null;

        // Convert to inner row index
        const inner_row: isize = @as(isize, @intCast(row)) - @as(isize, @intCast(self.viewport_margins.top));

        // Get the scroll offset in lines (use trunc for cell lookup)
        const scroll_offset_lines: isize = @intFromFloat(@trunc(self.scroll_animation.position));

        // Calculate the scrollback index
        const scrollback_row: isize = scroll_offset_lines + inner_row;

        // Get the line from scrollback
        const scrollback = &self.scrollback_lines.?;
        const line = scrollback.getConst(scrollback_row) orelse return null;

        // Get the cell
        if (col >= line.cells.len) return null;
        return &line.cells[col];
    }

    /// Get scrollback cell by inner row index (0-based from top of scrollable region)
    /// Like Neovide's iter_scrollable_lines which iterates 0..inner_size+1
    /// This allows reading one extra row at the edge during animation
    pub fn getScrollbackCellByInnerRow(self: *const Self, inner_row: u32, col: u32) ?*const GridCell {
        return self.getScrollbackCellByInnerRowSigned(@intCast(inner_row), col);
    }

    /// Get scrollback cell by signed inner row index (can be -1 for extra top row)
    /// This supports rendering one extra row above the visible region during scroll animation
    pub fn getScrollbackCellByInnerRowSigned(self: *const Self, inner_row: i32, col: u32) ?*const GridCell {
        if (self.scrollback_lines == null) return null;
        if (col >= self.grid_width) return null;

        // Use trunc (round toward zero) for cell lookup
        // This ensures we read from the correct row during animation
        // The pixel offset uses floor for smooth sub-pixel animation
        const scroll_offset_lines: isize = @intFromFloat(@trunc(self.scroll_animation.position));
        const scrollback_idx: isize = scroll_offset_lines + @as(isize, inner_row);

        const scrollback = &self.scrollback_lines.?;
        const line = scrollback.getConst(scrollback_idx) orelse return null;
        if (col >= line.cells.len) return null;
        return &line.cells[col];
    }

    /// Check if scrollback has valid data for smooth scrolling
    /// Returns false if scrollback would return null for the edge rows during animation
    /// Also returns false for windows that have never scrolled (like nvim-tree)
    pub fn hasValidScrollbackData(self: *const Self) bool {
        // Don't enable smooth scroll for windows that have never received scroll events
        // This prevents statusline jitter in windows like nvim-tree
        if (!self.has_scrolled) return false;
        if (self.scrollback_lines == null) return false;

        const scrollback = &self.scrollback_lines.?;

        // Check if scrollback has been populated at all
        // Even when pos == 0, we need valid data at row 0
        const first_line = scrollback.getConst(0);
        if (first_line == null) return false;
        if (first_line.?.cells.len == 0) return false;

        const pos = self.scroll_animation.position;
        if (pos == 0) return true; // No animation, first row check passed

        // Use trunc to match getScrollbackCellByInnerRowSigned
        const trunc_pos: isize = @intFromFloat(@trunc(pos));

        // For scroll animation, we read scrollback[trunc_pos + row] for each inner row
        // Check the first row we'll read during animation
        const anim_first_line = scrollback.getConst(trunc_pos);
        if (anim_first_line == null) return false;
        if (anim_first_line.?.cells.len == 0) return false;

        return true;
    }

    /// Get the sub-line pixel offset for smooth scrolling.
    /// Uses @trunc to match cell lookup (getScrollbackCellByInnerRowSigned).
    ///
    /// Example: position = -1.5 (scrolling down, animation in progress)
    /// - scroll_offset_lines = trunc(-1.5) = -1
    /// - scroll_offset = -1 - (-1.5) = 0.5
    /// - pixel_offset = 0.5 * 51 = +25.5 pixels (shift content DOWN)
    ///
    /// When scrolling DOWN, we show new content shifting DOWN into place.
    pub fn getSubLineOffset(self: *const Self, cell_height: f32) f32 {
        const pos = self.scroll_animation.position;
        const scroll_offset_lines = @trunc(pos);
        const scroll_offset = scroll_offset_lines - pos;
        return scroll_offset * cell_height;
    }

    /// Get the scrollable region bounds (excluding viewport margins)
    pub fn getScrollableRegion(self: *const Self) struct { top: u32, bottom: u32 } {
        return .{
            .top = self.viewport_margins.top,
            .bottom = self.grid_height -| self.viewport_margins.bottom,
        };
    }

    /// Check if a row is in the scrollable region (not a margin row)
    pub fn isRowScrollable(self: *const Self, row: u32) bool {
        return row >= self.viewport_margins.top and
            row < (self.grid_height -| self.viewport_margins.bottom);
    }

    /// Check if window is currently animating
    pub fn isAnimating(self: *const Self) bool {
        return self.scroll_animation.position != 0.0 or
            self.position_spring_x.position != 0.0 or
            self.position_spring_y.position != 0.0;
    }

    /// Get the current scroll animation position (in lines, can be fractional)
    pub fn getScrollPosition(self: *const Self) f32 {
        return self.scroll_animation.position;
    }
};
