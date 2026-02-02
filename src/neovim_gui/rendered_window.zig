//! Rendered Window - Per-window state for Neovim GUI
//!
//! This is a port of Neovide's RenderedWindow concept. Each Neovim window
//! (grid) has its own:
//! - Grid of cells with text and highlight IDs
//! - scroll_animation: Critically damped spring for smooth pixel scrolling
//! - viewport_margins: Fixed rows at top/bottom (tabline, statusline, etc.)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Animation = @import("animation.zig");

const log = std.log.scoped(.rendered_window);

/// Scroll command parameters
pub const ScrollCommand = struct {
    top: u64,
    bottom: u64,
    left: u64,
    right: u64,
    rows: i64,
    cols: i64,
};

/// A cell in the grid
pub const GridCell = struct {
    /// UTF-8 text content (can be empty, single char, or multi-byte grapheme)
    text: [16]u8 = .{0} ** 16,
    text_len: u8 = 0,
    /// Highlight group ID
    hl_id: u64 = 0,
    /// Double-width flag
    double_width: bool = false,

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
    }
};

pub const WindowType = enum {
    editor,
    message,
    floating,
};

/// Viewport margins - fixed rows that don't scroll
pub const ViewportMargins = struct {
    top: u64 = 0,
    bottom: u64 = 0,
};

/// Per-window rendering state (ported from Neovide's RenderedWindow)
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

    /// The actual grid of cells
    cells: []GridCell = &.{},

    /// Pending scroll delta from Neovim
    scroll_delta: i32 = 0,

    /// Fixed rows at top/bottom (tabline, statusline, etc.)
    viewport_margins: ViewportMargins = .{},

    /// Scroll animation using critically damped spring
    scroll_animation: Animation.CriticallyDampedSpring = .{},

    /// Animation settings
    scroll_animation_length: f32 = 0.3,
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
        if (self.cells.len > 0) {
            self.alloc.free(self.cells);
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

        // Free old cells
        if (self.cells.len > 0) {
            self.alloc.free(self.cells);
        }

        // Allocate new grid
        const cell_count = @as(usize, width) * @as(usize, height);
        self.cells = try self.alloc.alloc(GridCell, cell_count);

        // Initialize all cells
        for (self.cells) |*cell| {
            cell.* = GridCell{};
        }

        self.grid_width = width;
        self.grid_height = height;
        self.scroll_delta = 0;
        self.scroll_animation.reset();
        self.valid = true;
        self.dirty = true;
    }

    pub fn clear(self: *Self) void {
        for (self.cells) |*cell| {
            cell.clear();
        }
        self.dirty = true;
    }

    /// Set a single cell's content
    pub fn setCell(self: *Self, row: u32, col: u32, text: []const u8, hl_id: u64) void {
        if (row >= self.grid_height or col >= self.grid_width) return;
        const idx = row * self.grid_width + col;
        if (idx >= self.cells.len) return;

        self.cells[idx].setText(text);
        self.cells[idx].hl_id = hl_id;
        self.dirty = true;
    }

    pub fn setPosition(self: *Self, row: u64, col: u64, _: u64, _: u64) void {
        // Use position exactly as Neovim specifies
        self.grid_position = .{ @floatFromInt(col), @floatFromInt(row) };
        self.target_position = self.grid_position;
        self.position_spring_x.position = 0;
        self.position_spring_y.position = 0;

        self.valid = true;
        self.hidden = false;
        self.zindex = 0; // Normal windows at base z-index
    }

    pub fn setFloatPosition(self: *Self, row: u64, col: u64, zindex: u64) void {
        const new_x: f32 = @floatFromInt(col);
        const new_y: f32 = @floatFromInt(row);

        // Always set position - snap immediately
        self.grid_position = .{ new_x, new_y };
        self.target_position = .{ new_x, new_y };
        self.position_spring_x.position = 0;
        self.position_spring_y.position = 0;

        self.valid = true;
        self.hidden = false;
        self.zindex = zindex;
    }

    pub fn setViewport(self: *Self, topline: u64, botline: u64, scroll_delta: i64) void {
        _ = topline;
        _ = botline;
        self.scroll_delta = @intCast(scroll_delta);
    }

    pub fn handleScroll(self: *Self, cmd: ScrollCommand) void {
        const top = @as(u32, @intCast(cmd.top));
        const bot = @as(u32, @intCast(cmd.bottom));
        const left = @as(u32, @intCast(cmd.left));
        const right = @as(u32, @intCast(cmd.right));
        const rows = cmd.rows;

        if (rows == 0) return;
        if (self.grid_width == 0 or self.grid_height == 0) return;

        // Scroll the cells in the specified region
        if (rows > 0) {
            // Scrolling up - move rows up
            const scroll_amount: u32 = @intCast(rows);
            var y: u32 = top;
            while (y + scroll_amount < bot) : (y += 1) {
                const dest_row = y;
                const src_row = y + scroll_amount;
                var x: u32 = left;
                while (x < right) : (x += 1) {
                    const dest_idx = dest_row * self.grid_width + x;
                    const src_idx = src_row * self.grid_width + x;
                    if (dest_idx < self.cells.len and src_idx < self.cells.len) {
                        self.cells[dest_idx] = self.cells[src_idx];
                    }
                }
            }
            // Clear the newly exposed rows at the bottom
            y = bot - scroll_amount;
            while (y < bot) : (y += 1) {
                var x: u32 = left;
                while (x < right) : (x += 1) {
                    const idx = y * self.grid_width + x;
                    if (idx < self.cells.len) {
                        self.cells[idx].clear();
                    }
                }
            }
        } else {
            // Scrolling down - move rows down
            const scroll_amount: u32 = @intCast(-rows);
            var y: u32 = bot;
            while (y > top + scroll_amount) {
                y -= 1;
                const dest_row = y;
                const src_row = y - scroll_amount;
                var x: u32 = left;
                while (x < right) : (x += 1) {
                    const dest_idx = dest_row * self.grid_width + x;
                    const src_idx = src_row * self.grid_width + x;
                    if (dest_idx < self.cells.len and src_idx < self.cells.len) {
                        self.cells[dest_idx] = self.cells[src_idx];
                    }
                }
            }
            // Clear the newly exposed rows at the top
            y = top;
            while (y < top + scroll_amount) : (y += 1) {
                var x: u32 = left;
                while (x < right) : (x += 1) {
                    const idx = y * self.grid_width + x;
                    if (idx < self.cells.len) {
                        self.cells[idx].clear();
                    }
                }
            }
        }

        // Queue the scroll for animation
        self.scroll_delta += @intCast(rows);
        self.dirty = true;
    }

    /// Draw a line of cells from grid_line event
    pub fn drawLine(self: *Self, row: u64, col_start: u64, cells: anytype) void {
        if (row >= self.grid_height) return;

        var col: u64 = col_start;
        for (cells) |cell| {
            // Handle repeat
            const repeat = if (@hasField(@TypeOf(cell), "repeat")) cell.repeat else 1;

            var i: u64 = 0;
            while (i < repeat) : (i += 1) {
                if (col >= self.grid_width) break;

                const idx = row * self.grid_width + col;
                if (idx < self.cells.len) {
                    self.cells[idx].setText(cell.text);
                    self.cells[idx].hl_id = cell.hl_id;
                }
                col += 1;
            }
        }
        self.dirty = true;
    }

    /// Get cell at position
    pub fn getCell(self: *const Self, row: u32, col: u32) ?*const GridCell {
        if (row >= self.grid_height or col >= self.grid_width) return null;
        const idx = row * self.grid_width + col;
        if (idx >= self.cells.len) return null;
        return &self.cells[idx];
    }

    /// Get mutable cell at position
    pub fn getCellMut(self: *Self, row: u32, col: u32) ?*GridCell {
        if (row >= self.grid_height or col >= self.grid_width) return null;
        const idx = row * self.grid_width + col;
        if (idx >= self.cells.len) return null;
        return &self.cells[idx];
    }

    /// Flush pending updates (called after Neovim's "flush" event)
    pub fn flush(self: *Self, cell_height: f32) void {
        _ = cell_height;
        if (!self.valid) return;

        const scroll_delta = self.scroll_delta;
        self.scroll_delta = 0;

        // Update animation
        if (scroll_delta != 0) {
            const delta_f: f32 = @floatFromInt(scroll_delta);
            self.scroll_animation.position -= delta_f;
            log.debug("Window {} scroll: delta={} pos={d:.2}", .{
                self.id,
                scroll_delta,
                self.scroll_animation.position,
            });
        }
    }

    /// Animate the window, returns true if still animating
    pub fn animate(self: *Self, dt: f32) bool {
        var animating = false;

        // Animate scroll
        if (self.scroll_animation.update(dt, self.scroll_animation_length, 0)) {
            animating = true;
        }

        // Animate position (window movement)
        if (self.position_spring_x.update(dt, self.position_animation_length, 0)) {
            animating = true;
        }
        if (self.position_spring_y.update(dt, self.position_animation_length, 0)) {
            animating = true;
        }

        // Update grid_position from springs
        self.grid_position[0] = self.target_position[0] + self.position_spring_x.position;
        self.grid_position[1] = self.target_position[1] + self.position_spring_y.position;

        return animating;
    }

    /// Get scroll offset in whole lines
    pub fn getScrollOffsetLines(self: *const Self) i32 {
        return @intFromFloat(@floor(self.scroll_animation.position));
    }

    /// Get sub-line pixel offset for smooth rendering
    pub fn getSubLineOffset(self: *const Self, cell_height: f32) f32 {
        const floor_pos = @floor(self.scroll_animation.position);
        return (floor_pos - self.scroll_animation.position) * cell_height;
    }

    /// Check if window is currently animating
    pub fn isAnimating(self: *const Self) bool {
        return self.scroll_animation.position != 0.0 or
            self.position_spring_x.position != 0.0 or
            self.position_spring_y.position != 0.0;
    }
};
