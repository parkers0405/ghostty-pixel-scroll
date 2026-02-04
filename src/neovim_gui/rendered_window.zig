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
    /// Neovide default is 0.3s
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

    /// Window type
    window_type: WindowType = .editor,

    /// Grid dimensions
    grid_width: u32 = 0,
    grid_height: u32 = 0,

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

    /// The actual lines - current viewport content from Neovim
    /// This is what Neovim sees - rotated by grid_scroll
    actual_lines: ?RingBuffer(?*GridLine) = null,

    /// Scrollback buffer - 2x viewport height for smooth scroll animation
    /// Used during rendering to show content during scroll animation
    scrollback_lines: ?RingBuffer(?*GridLine) = null,

    /// Pending scroll delta from win_viewport (for animation)
    scroll_delta: isize = 0,

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

        // Free old buffers
        if (self.actual_lines) |*al| {
            al.deinit();
        }
        if (self.scrollback_lines) |*sb| {
            sb.deinit();
        }

        // Allocate actual_lines (viewport height)
        self.actual_lines = try RingBuffer(?*GridLine).init(self.alloc, height);

        // Initialize actual_lines with new GridLine objects
        var i: u32 = 0;
        while (i < height) : (i += 1) {
            const line = try GridLine.init(self.alloc, width);
            self.actual_lines.?.set(@intCast(i), line);
        }

        // Allocate scrollback (2x viewport height)
        const scrollback_size = height * 2;
        self.scrollback_lines = try RingBuffer(?*GridLine).init(self.alloc, scrollback_size);

        // Initialize scrollback - populate BOTH halves with the same content
        // This ensures negative indices (scroll down) have valid data immediately
        // First half: scrollback[0..height]
        // Second half: scrollback[height..2*height] (for negative index wrapping)
        i = 0;
        while (i < height) : (i += 1) {
            const line = try GridLine.init(self.alloc, width);
            // Copy from actual_lines
            if (self.actual_lines.?.getConst(@intCast(i))) |src| {
                line.copyFromSlice(src.cells);
            }
            self.scrollback_lines.?.set(@intCast(i), line);
        }
        // Populate second half with same content (for scroll down support)
        while (i < scrollback_size) : (i += 1) {
            const line = try GridLine.init(self.alloc, width);
            // Copy from corresponding position in first half
            const src_idx = i - height;
            if (self.actual_lines.?.getConst(@intCast(src_idx))) |src| {
                line.copyFromSlice(src.cells);
            }
            self.scrollback_lines.?.set(@intCast(i), line);
        }

        self.grid_width = width;
        self.grid_height = height;
        self.scroll_delta = 0;
        self.scroll_animation.reset();
        self.valid = true;
        self.dirty = true;
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
    }

    pub fn setPosition(self: *Self, row: u64, col: u64, _: u64, _: u64) void {
        self.grid_position = .{ @floatFromInt(col), @floatFromInt(row) };
        self.target_position = self.grid_position;
        self.position_spring_x.position = 0;
        self.position_spring_y.position = 0;

        self.valid = true;
        self.hidden = false;
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

        // Get inner (scrollable) region bounds
        const inner_top: isize = @intCast(self.viewport_margins.top);
        const inner_bottom: isize = @intCast(self.grid_height -| self.viewport_margins.bottom);
        const inner_size = inner_bottom - inner_top;

        if (inner_size <= 0) return;

        // Check if scrollback needs resizing (viewport margins changed)
        const expected_scrollback_size: usize = @intCast(inner_size * 2);
        if (scrollback.length() != expected_scrollback_size) {
            // Resize scrollback - this resets the animation
            log.err("!!! SCROLLBACK RESIZE grid={}: old_size={} new_size={} inner_size={} pos_before={d:.2}", .{
                self.id, scrollback.length(), expected_scrollback_size, inner_size, self.scroll_animation.position,
            });
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

        // Debug: show actual_lines content at flush time
        if (scroll_delta != 0) {
            // Check first cell of first and last inner row
            const first_row = actual.getConst(inner_top);
            const last_row = actual.getConst(inner_bottom - 1);
            const first_char: u8 = if (first_row) |r| (if (r.cells.len > 0) r.cells[0].text[0] else 0) else 0;
            const last_char: u8 = if (last_row) |r| (if (r.cells.len > 0) r.cells[0].text[0] else 0) else 0;
            log.err("FLUSH grid={}: delta={}, pos={d:.2}, actual[{}] first='{c}', actual[{}] last='{c}'", .{
                self.id,
                scroll_delta,
                self.scroll_animation.position,
                inner_top,
                first_char,
                inner_bottom - 1,
                last_char,
            });

            // Debug: show first few chars of row 0 (the potential winbar row)
            const row0 = actual.getConst(0);
            if (row0) |r| {
                var row0_preview: [32]u8 = undefined;
                var preview_len: usize = 0;
                for (r.cells[0..@min(r.cells.len, 30)]) |cell| {
                    if (cell.text[0] != 0 and preview_len < 31) {
                        row0_preview[preview_len] = cell.text[0];
                        preview_len += 1;
                    }
                }
                row0_preview[preview_len] = 0;
                log.err("ROW0 grid={}: '{s}' margins=({},{})", .{
                    self.id,
                    row0_preview[0..preview_len],
                    self.viewport_margins.top,
                    self.viewport_margins.bottom,
                });
            }
        }

        // Rotate scrollback by scroll_delta
        scrollback.rotate(scroll_delta);

        // Debug: Check what's at scrollback[-1] BEFORE copy (this is what we'll read during animation)
        if (scroll_delta > 0) {
            const check_idx: isize = -1;
            const check_line = scrollback.getConst(check_idx);
            if (check_line) |line| {
                // Check if line has content
                const has_content = if (line.cells.len > 0)
                    (line.cells[0].text[0] != 0)
                else
                    false;
                log.debug("flush pre-copy: scrollback[-1] exists, has_content={}, cells_len={}", .{
                    has_content,
                    line.cells.len,
                });
            } else {
                log.debug("flush pre-copy: scrollback[-1] is NULL!", .{});
            }
        }

        // Copy inner view from actual_lines into scrollback at position 0..inner_size
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

        // Update scroll animation (Neovide-style)
        if (scroll_delta != 0) {
            var scroll_offset = self.scroll_animation.position;

            const max_delta: f32 = @floatFromInt(inner_size);

            scroll_offset -= @as(f32, @floatFromInt(scroll_delta));
            scroll_offset = std.math.clamp(scroll_offset, -max_delta, max_delta);

            self.scroll_animation.position = scroll_offset;

            log.debug("flush: scroll_delta={}, new_pos={d:.2}, current_index={}, inner_size={}", .{
                scroll_delta,
                self.scroll_animation.position,
                scrollback.current_index,
                inner_size,
            });

            // Debug: Check what's at the edge positions after copy
            // For scroll down (pos > 0), we'll read scrollback[floor(pos) + inner_size - 1]
            // For scroll up (pos < 0), we'll read scrollback[floor(pos) + 0]
            const floor_pos: isize = @intFromFloat(@floor(scroll_offset));
            if (scroll_offset > 0) {
                // Scroll down: check position inner_size (one past visible)
                const edge_idx = floor_pos + inner_size;
                const edge_line = scrollback.getConst(edge_idx);
                const has_data = if (edge_line) |line| line.cells.len > 0 else false;
                log.err("SCROLL_DOWN: pos={d:.2}, floor={}, edge_idx={}, has_data={}", .{
                    scroll_offset,
                    floor_pos,
                    edge_idx,
                    has_data,
                });
            } else if (scroll_offset < 0) {
                // Scroll up: check position -1 (one before visible)
                const edge_idx = floor_pos - 1;
                const edge_line = scrollback.getConst(edge_idx);
                const has_data = if (edge_line) |line| line.cells.len > 0 else false;
                log.err("SCROLL_UP: pos={d:.2}, floor={}, edge_idx={}, has_data={}", .{
                    scroll_offset,
                    floor_pos,
                    edge_idx,
                    has_data,
                });
            }
        }

        self.scroll_delta = 0;
    }

    /// Animate the window, returns true if still animating
    pub fn animate(self: *Self, dt: f32) bool {
        var animating = false;

        // Animate scroll using critically damped spring
        if (self.scroll_animation.update(dt, self.scroll_settings.animation_length, 0)) {
            animating = true;
        }

        // Animate position (window movement)
        const snap_threshold: f32 = 10.0;

        if (@abs(self.position_spring_x.position) > snap_threshold) {
            self.position_spring_x.reset();
        } else if (self.position_spring_x.update(dt, self.position_animation_length, 0)) {
            animating = true;
        }

        if (@abs(self.position_spring_y.position) > snap_threshold) {
            self.position_spring_y.reset();
        } else if (self.position_spring_y.update(dt, self.position_animation_length, 0)) {
            animating = true;
        }

        // Update grid_position from springs
        self.grid_position[0] = self.target_position[0] + self.position_spring_x.position;
        self.grid_position[1] = self.target_position[1] + self.position_spring_y.position;

        return animating;
    }

    /// Get a cell from the scrollback buffer for rendering during scroll animation.
    /// This reads from scrollback_lines[floor(scroll_pos) + row] where row is
    /// relative to the inner (scrollable) region.
    ///
    /// Returns null if the position is outside the scrollback buffer or if
    /// this is a margin row (which should be read from actual_lines instead).
    pub fn getScrollbackCell(self: *const Self, row: u32, col: u32) ?*const GridCell {
        if (self.scrollback_lines == null) return null;
        if (col >= self.grid_width) return null;

        // Check if this is a margin row
        if (row < self.viewport_margins.top) return null;
        if (row >= self.grid_height -| self.viewport_margins.bottom) return null;

        // Convert to inner row index
        const inner_row: isize = @as(isize, @intCast(row)) - @as(isize, @intCast(self.viewport_margins.top));

        // Get the scroll offset in lines
        const scroll_offset_lines: isize = @intFromFloat(@floor(self.scroll_animation.position));

        // Calculate the scrollback index
        const scrollback_row: isize = scroll_offset_lines + inner_row;

        // Get the line from scrollback
        const scrollback = &self.scrollback_lines.?;
        const line = scrollback.getConst(scrollback_row) orelse {
            // Debug: log when we get null from scrollback
            if (col == 0) { // Only log once per row
                log.warn("scrollback NULL: row={}, inner_row={}, scroll_offset={}, scrollback_row={}, current_index={}, buffer_len={}", .{
                    row,
                    inner_row,
                    scroll_offset_lines,
                    scrollback_row,
                    scrollback.current_index,
                    scrollback.length(),
                });
            }
            return null;
        };

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

        // Use trunc instead of floor - this rounds toward zero for both positive and negative
        // For scroll UP (pos > 0): trunc(1.5) = 1, same as floor
        // For scroll DOWN (pos < 0): trunc(-1.5) = -1, but floor(-1.5) = -2
        // This fixes the off-by-one when scrolling down
        const scroll_offset_lines: isize = @intFromFloat(@trunc(self.scroll_animation.position));
        const scrollback_idx: isize = scroll_offset_lines + @as(isize, inner_row);

        const scrollback = &self.scrollback_lines.?;
        const line = scrollback.getConst(scrollback_idx) orelse {
            // Debug: log when we get null from scrollback (only once per row)
            if (col == 0 and self.scroll_animation.position != 0) {
                log.warn("getScrollbackCellByInnerRowSigned NULL: inner_row={}, pos={d:.2}, scroll_offset={}, scrollback_idx={}, current_idx={}, buf_len={}", .{
                    inner_row,
                    self.scroll_animation.position,
                    scroll_offset_lines,
                    scrollback_idx,
                    scrollback.current_index,
                    scrollback.length(),
                });
            }
            return null;
        };
        if (col >= line.cells.len) return null;
        return &line.cells[col];
    }

    /// Check if scrollback has valid data for smooth scrolling
    /// Returns false if scrollback would return null for the edge rows during animation
    pub fn hasValidScrollbackData(self: *const Self) bool {
        if (self.scrollback_lines == null) return false;

        const pos = self.scroll_animation.position;
        if (pos == 0) return true; // No animation, always valid

        const scrollback = &self.scrollback_lines.?;
        // Use trunc to match getScrollbackCellByInnerRowSigned
        const trunc_pos: isize = @intFromFloat(@trunc(pos));

        // For scroll animation, we read scrollback[trunc_pos + row] for each inner row
        // We need valid data at trunc_pos (first row we'll read)
        // Check both the first and edge rows we'll need

        // Check first row we'll read (trunc_pos + 0 = trunc_pos)
        const first_line = scrollback.getConst(trunc_pos);
        if (first_line == null) return false;
        if (first_line.?.cells.len == 0) return false;

        return true;
    }

    /// Get pixel offset for smooth scroll rendering (sub-line portion only)
    /// Uses trunc (round toward zero) to match getScrollbackCellByInnerRowSigned
    ///
    /// Example for scroll DOWN: position = -1.5, cell_height = 51
    /// - trunc(-1.5) = -1
    /// - scroll_offset = -1 - (-1.5) = 0.5
    /// - pixel_offset = 0.5 * 51 = 25.5 pixels (shift content DOWN)
    ///
    /// Example for scroll UP: position = 1.5, cell_height = 51
    /// - trunc(1.5) = 1
    /// - scroll_offset = 1 - 1.5 = -0.5
    /// - pixel_offset = -0.5 * 51 = -25.5 pixels (shift content UP)
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
