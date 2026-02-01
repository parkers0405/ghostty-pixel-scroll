const std = @import("std");
const Allocator = std.mem.Allocator;
const animation = @import("../animation.zig");
const renderer = @import("../renderer.zig");
const shaderpkg = renderer.Renderer.API.shaders;

const log = std.log.scoped(.tui_scroll);

/// Ring buffer for TUI smooth scrolling (Neovide-style).
/// Supports negative indexing and rotation for scroll animation.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: []T,
        /// Rotation offset - added to logical index to get array index
        rotation: isize = 0,
        alloc: Allocator,
        capacity: usize,

        pub fn init(alloc: Allocator, size: usize, default_value: T) !Self {
            const elements = try alloc.alloc(T, size);
            @memset(elements, default_value);
            return Self{
                .elements = elements,
                .rotation = 0,
                .alloc = alloc,
                .capacity = size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.elements);
        }

        pub fn len(self: *const Self) usize {
            return self.elements.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.elements.len == 0;
        }

        /// Rotate the buffer by num positions.
        /// Positive num = rotate forward (scroll down), negative = backward (scroll up).
        /// This changes which logical index maps to which array position.
        pub fn rotate(self: *Self, num: isize) void {
            self.rotation += num;
        }

        /// Get the actual array index for a logical index.
        /// Supports negative logical indices.
        fn getArrayIndex(self: *const Self, logical_index: isize) usize {
            const n: isize = @intCast(self.elements.len);
            if (n == 0) return 0;
            // Apply rotation and wrap to valid range using rem_euclid behavior
            const adjusted = self.rotation + logical_index;
            return @intCast(@mod(adjusted, n));
        }

        /// Get element at logical index (supports negative indexing).
        pub fn get(self: *const Self, index: isize) T {
            return self.elements[self.getArrayIndex(index)];
        }

        /// Get pointer to element at logical index.
        pub fn getPtr(self: *Self, index: isize) *T {
            return &self.elements[self.getArrayIndex(index)];
        }

        /// Set element at logical index.
        pub fn set(self: *Self, index: isize, value: T) void {
            self.elements[self.getArrayIndex(index)] = value;
        }

        /// Resize the buffer. Resets rotation.
        pub fn resize(self: *Self, new_size: usize, default_value: T) !void {
            if (new_size == self.elements.len) return;

            self.alloc.free(self.elements);
            self.elements = try self.alloc.alloc(T, new_size);
            @memset(self.elements, default_value);
            self.rotation = 0;
            self.capacity = new_size;
        }

        /// Reset rotation without reallocating
        pub fn resetRotation(self: *Self) void {
            self.rotation = 0;
        }
    };
}

/// A single row of rendered content stored in the scrollback buffer.
/// This stores GPU-ready cell data for a single row.
pub const ScrollbackRow = struct {
    /// Foreground cells (text glyphs, underlines, etc.) for this row.
    fg_cells: std.ArrayListUnmanaged(shaderpkg.CellText),
    /// Background colors for this row (one per column).
    bg_cells: []shaderpkg.CellBg,
    /// Number of columns
    columns: usize,
    /// Whether this row has valid content
    valid: bool = false,
    /// Allocator for this row
    alloc: Allocator,

    pub fn init(alloc: Allocator, columns: usize) !ScrollbackRow {
        return ScrollbackRow{
            .fg_cells = .{},
            .bg_cells = try alloc.alloc(shaderpkg.CellBg, columns),
            .columns = columns,
            .valid = false,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ScrollbackRow) void {
        self.fg_cells.deinit(self.alloc);
        self.alloc.free(self.bg_cells);
    }

    pub fn clear(self: *ScrollbackRow) void {
        self.fg_cells.clearRetainingCapacity();
        @memset(self.bg_cells, .{ 0, 0, 0, 0 });
        self.valid = false;
    }

    /// Copy content from the main cell buffer for a specific row.
    pub fn copyFromCells(
        self: *ScrollbackRow,
        cells: anytype, // *cell.Contents
        row: usize,
    ) !void {
        self.clear();

        // Copy background cells for this row
        const bg_start = row * cells.size.columns;
        const bg_end = bg_start + cells.size.columns;
        if (bg_end <= cells.bg_cells.len) {
            @memcpy(self.bg_cells, cells.bg_cells[bg_start..bg_end]);
        }

        // Copy foreground cells for this row
        // fg_rows is indexed as [row + 1] because index 0 is reserved for cursor
        const fg_row_index = row + 1;
        if (fg_row_index < cells.fg_rows.lists.len) {
            const src_list = &cells.fg_rows.lists[fg_row_index];
            try self.fg_cells.ensureTotalCapacity(self.alloc, src_list.items.len);
            self.fg_cells.appendSliceAssumeCapacity(src_list.items);
        }

        self.valid = true;
    }

    /// Resize for new column count
    pub fn resizeColumns(self: *ScrollbackRow, columns: usize) !void {
        if (columns == self.columns) return;

        self.alloc.free(self.bg_cells);
        self.bg_cells = try self.alloc.alloc(shaderpkg.CellBg, columns);
        self.columns = columns;
        self.clear();
    }
};

/// TUI Scrollback manager for Neovide-style smooth scrolling.
///
/// NEOVIDE ARCHITECTURE (we match this exactly):
///
/// Neovide has TWO buffers:
/// 1. actual_lines (size = grid_height) - Current grid state from Neovim
/// 2. scrollback_lines (size = 2 * grid_height) - Animation buffer
///
/// Flow:
/// 1. Neovim sends scroll command -> actual_lines is rotated
/// 2. Neovim redraws the grid -> actual_lines has NEW content
/// 3. On flush:
///    a. Rotate scrollback_lines by scroll_delta
///    b. Copy actual_lines INTO scrollback_lines at index 0..height
///    c. Set animation position to -scroll_delta
/// 4. On render:
///    a. Read from scrollback_lines[scroll_offset_lines + screen_row]
///    b. Draw at screen position: screen_row * line_height + pixel_offset
///    c. NEVER write back to actual_lines during animation!
///
/// The key insight: scrollback_lines[0+] has NEW content, negative indices have OLD content.
/// By reading at (offset + row) where offset starts negative, we initially show old content
/// and smoothly transition to new content as offset approaches 0.
pub const TuiScrollback = struct {
    const Self = @This();

    alloc: Allocator,

    /// Ring buffer of scrollback rows. Size = 2 * grid_height for animation headroom.
    /// Index 0+ = NEW content (current frame), negative indices = OLD content (previous frames).
    scrollback_lines: RingBuffer(*ScrollbackRow),

    /// Current grid dimensions.
    grid_rows: usize = 0,
    grid_columns: usize = 0,

    /// Scroll region from OSC 9999 (in grid row indices).
    /// top = first scrollable row (rows before are fixed header like tabline)
    /// bot = first non-scrollable row at bottom (like statusline)
    scroll_region_top: usize = 0,
    scroll_region_bot: usize = 0,
    scroll_region_left: usize = 0,
    scroll_region_right: usize = 0,

    /// Scroll animation using critically damped spring.
    /// Position is in LINES. Negative = showing old content (scrolling up).
    scroll_animation: animation.Spring = .{},

    /// Whether scroll animation is currently active.
    is_animating: bool = false,

    /// Pending scroll delta (in lines) to be processed on next flush.
    pending_scroll_delta: isize = 0,

    pub fn init(alloc: Allocator) !Self {
        // Start with empty buffer, will be resized on first use
        const scrollback_lines = try RingBuffer(*ScrollbackRow).init(alloc, 0, undefined);
        return Self{
            .alloc = alloc,
            .scrollback_lines = scrollback_lines,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all scrollback rows
        for (self.scrollback_lines.elements) |row_ptr| {
            const ptr_val = @intFromPtr(row_ptr);
            if (ptr_val != 0 and ptr_val != std.math.maxInt(usize)) {
                row_ptr.deinit();
                self.alloc.destroy(row_ptr);
            }
        }
        self.scrollback_lines.deinit();
    }

    /// Resize for new grid dimensions. Resets scrollback and animation.
    pub fn resize(self: *Self, rows: usize, columns: usize) !void {
        if (rows == self.grid_rows and columns == self.grid_columns) return;

        log.debug("TuiScrollback resize: {}x{} -> {}x{}", .{ self.grid_columns, self.grid_rows, columns, rows });

        // Free old scrollback rows
        for (self.scrollback_lines.elements) |row_ptr| {
            const ptr_val = @intFromPtr(row_ptr);
            if (ptr_val != 0 and ptr_val != std.math.maxInt(usize)) {
                row_ptr.deinit();
                self.alloc.destroy(row_ptr);
            }
        }

        self.grid_rows = rows;
        self.grid_columns = columns;

        // Scrollback is 2x rows for animation headroom (like Neovide)
        const scrollback_size = rows * 2;
        try self.scrollback_lines.resize(scrollback_size, undefined);

        // Initialize all scrollback rows
        for (self.scrollback_lines.elements, 0..) |_, idx| {
            const row = try self.alloc.create(ScrollbackRow);
            row.* = try ScrollbackRow.init(self.alloc, columns);
            self.scrollback_lines.elements[idx] = row;
        }

        // Reset scroll region to full grid
        self.scroll_region_top = 0;
        self.scroll_region_bot = rows;

        // Reset animation on resize
        self.scroll_animation.reset();
        self.is_animating = false;
        self.pending_scroll_delta = 0;
    }

    /// Set scroll region from OSC 9999.
    pub fn setScrollRegion(self: *Self, top: u32, bot: u32, left: u32, right: u32) void {
        self.scroll_region_top = @intCast(top);
        // bot=0 means "until end of grid"
        self.scroll_region_bot = if (bot == 0) self.grid_rows else @intCast(bot);
        self.scroll_region_left = @intCast(left);
        self.scroll_region_right = if (right == 0) self.grid_columns else @intCast(right);
    }

    /// Queue a scroll event. Will be processed on next flush().
    pub fn queueScroll(self: *Self, delta: i32, top: u32, bot: u32, left: u32, right: u32) void {
        self.pending_scroll_delta += delta;
        self.setScrollRegion(top, bot, left, right);
        log.debug("TuiScrollback queueScroll: delta={} top={} bot={} left={} right={} pending={}", .{ delta, top, bot, left, right, self.pending_scroll_delta });
    }

    /// Get the number of scrollable rows (excluding margins/fixed rows).
    fn getScrollableRowCount(self: *const Self) usize {
        if (self.scroll_region_bot <= self.scroll_region_top) return 0;
        return self.scroll_region_bot - self.scroll_region_top;
    }

    /// Flush pending scrolls and update scrollback.
    /// This should be called each frame AFTER rebuildCells but BEFORE syncing to GPU.
    ///
    /// NEOVIDE ALGORITHM (we match this exactly):
    /// 1. If scroll happened: Rotate scrollback_lines by scroll_delta
    /// 2. Copy current cells INTO scrollback_lines at index 0..inner_size
    /// 3. Set animation position to -scroll_delta (negative!)
    /// 4. As animation runs, position approaches 0
    ///
    /// CRITICAL: We copy cells to scrollback EVERY frame, but we only rotate on scroll.
    /// This means:
    /// - scrollback[0..inner_size] always has current frame's content
    /// - On scroll, old content is preserved at negative indices BEFORE we copy new content
    pub fn flush(self: *Self, cells: anytype, cell_height: f32, animation_length: f32) !void {
        _ = cell_height;
        if (self.grid_rows == 0 or self.scrollback_lines.isEmpty()) return;

        const scroll_delta = self.pending_scroll_delta;
        self.pending_scroll_delta = 0;

        const inner_start = self.scroll_region_top;
        const inner_size = self.getScrollableRowCount();

        if (inner_size == 0) return;

        // Check if scrollback needs resize (when scroll region changes)
        const expected_scrollback_size = inner_size * 2;
        if (self.scrollback_lines.len() != expected_scrollback_size) {
            for (self.scrollback_lines.elements) |row_ptr| {
                const ptr_val = @intFromPtr(row_ptr);
                if (ptr_val != 0 and ptr_val != std.math.maxInt(usize)) {
                    row_ptr.deinit();
                    self.alloc.destroy(row_ptr);
                }
            }
            try self.scrollback_lines.resize(expected_scrollback_size, undefined);
            for (self.scrollback_lines.elements, 0..) |_, i| {
                const row = try self.alloc.create(ScrollbackRow);
                row.* = try ScrollbackRow.init(self.alloc, self.grid_columns);
                self.scrollback_lines.elements[i] = row;
            }
            self.scroll_animation.reset();
            self.is_animating = false;
        }

        // STEP 1: If scrolling, rotate the buffer FIRST (BEFORE copying new content)
        // This preserves old content at negative indices
        if (scroll_delta != 0) {
            self.scrollback_lines.rotate(scroll_delta);
            log.debug("TuiScrollback rotated by {}", .{scroll_delta});
        }

        // STEP 2: Copy current cells INTO scrollback at index 0..inner_size
        // This happens EVERY frame. After rotation, this overwrites indices 0+
        // with NEW content, but old content is preserved at negative indices.
        for (0..inner_size) |i| {
            const grid_row = inner_start + i;
            const scrollback_row = self.scrollback_lines.getPtr(@intCast(i));
            try scrollback_row.*.copyFromCells(cells, grid_row);
        }

        // STEP 3: Update animation
        if (scroll_delta != 0) {
            // Position is NEGATIVE of scroll_delta
            // When scrolling DOWN (delta > 0), position starts negative and animates to 0
            const delta_f: f32 = @floatFromInt(scroll_delta);

            if (self.is_animating) {
                // Accumulate with existing animation
                self.scroll_animation.position -= delta_f;
            } else {
                self.scroll_animation.position = -delta_f;
                self.scroll_animation.velocity = 0;
            }

            self.is_animating = true;
            log.debug("TuiScrollback animation started: position={d:.2} lines", .{self.scroll_animation.position});
        }

        // STEP 4: Update the spring animation
        if (self.is_animating) {
            const still_animating = self.scroll_animation.update(1.0 / 60.0, animation_length, 1.0);
            if (!still_animating) {
                self.is_animating = false;
                self.scroll_animation.reset();
                log.debug("TuiScrollback animation complete", .{});
            }
        }
    }

    /// Get the scroll offset in whole lines (floored toward negative infinity).
    pub fn getScrollOffsetLines(self: *const Self) isize {
        return @intFromFloat(@floor(self.scroll_animation.position));
    }

    /// Get the sub-line pixel offset for smooth rendering.
    /// Neovide formula: (floor(position) - position) * cell_height
    pub fn getSubLineOffset(self: *const Self, cell_height: f32) f32 {
        const floor_pos = @floor(self.scroll_animation.position);

        // Always use (floor - pos) which gives the negative fractional part.
        // This is correct because we render the NEW content (at destination)
        // and shift it "backwards" to the start position.
        // - Scroll DOWN (pos < 0): Content moves UP. We render at New, shift DOWN?
        //   Wait. If pos=-0.9. floor=-1. diff=-0.1. Shift UP.
        //   Render at Row 0. Shift UP to -0.1. Moves -0.1 -> 0. (Down).
        //   Wait. Scroll DOWN -> Content moves UP.
        //   Old Row 1 moves to Row 0.
        //   New Row 0 moves to Row -1.

        // Let's stick to Neovide's formula which is proven.
        return (floor_pos - self.scroll_animation.position) * cell_height;
    }

    /// Get a scrollback row at the given logical index.
    pub fn getRow(self: *Self, logical_index: isize) ?*ScrollbackRow {
        if (self.scrollback_lines.isEmpty()) return null;

        // Clamp to valid range
        const max_index: isize = @intCast(self.scrollback_lines.len());
        if (logical_index >= max_index or logical_index < -max_index) return null;

        const row = self.scrollback_lines.get(logical_index);
        if (!row.valid) return null;
        return row;
    }

    /// Populate cells buffer from scrollback for rendering during animation.
    ///
    /// NEOVIDE APPROACH (we match this exactly):
    /// - For each screen row i (0..inner_size):
    ///   - Read from scrollback_lines[scroll_offset_lines + i]
    ///   - The content goes to screen row i
    /// - scroll_offset_lines starts negative, so we read old content
    /// - As animation progresses, offset approaches 0, transitioning to new content
    ///
    /// CRITICAL: We're populating cells for GPU sync, NOT modifying the source data.
    /// The scrollback buffer is our source of truth during animation.
    pub fn populateCellsForRender(
        self: *Self,
        cells: anytype,
    ) !void {
        if (!self.is_animating or self.scrollback_lines.isEmpty()) return;

        const scroll_offset_lines = self.getScrollOffsetLines();
        const inner_size = self.getScrollableRowCount();

        const scroll_left = self.scroll_region_left;
        const scroll_right = self.scroll_region_right;
        const full_width = scroll_left == 0 and scroll_right == self.grid_columns;

        // Calculate extended range to cover content sliding in from edges
        const start_i: isize = @min(0, -scroll_offset_lines);
        const end_i: isize = @max(@as(isize, @intCast(inner_size)), @as(isize, @intCast(inner_size)) - scroll_offset_lines);

        // Iterate over the extended range
        for (0..@intCast(end_i - start_i)) |k| {
            const i = start_i + @as(isize, @intCast(k));

            // Buffer index = offset + screen_row (relative to top of scroll region)
            const buffer_index = scroll_offset_lines + i;
            const scrollback_row = self.getRow(buffer_index) orelse continue;

            // Determine target logical grid row (visual position)
            const grid_row_signed = @as(isize, @intCast(self.scroll_region_top)) + i;

            // Is this an "extra" row (outside the normal scroll region)?
            // i.e., sliding in from header or footer area
            const is_extra = i < 0 or i >= inner_size;

            if (!is_extra) {
                // Determine actual row index in cells buffer
                if (grid_row_signed < 0 or grid_row_signed >= self.grid_rows) continue;
                const grid_row: usize = @intCast(grid_row_signed);

                // For inner rows, overwrite scroll region only for partial-width scrolls
                const bg_start = grid_row * cells.size.columns;
                const bg_end = bg_start + cells.size.columns;
                if (bg_end <= cells.bg_cells.len and scrollback_row.columns == cells.size.columns) {
                    if (full_width) {
                        @memcpy(cells.bg_cells[bg_start..bg_end], scrollback_row.bg_cells);
                    } else if (scroll_left < scroll_right and scroll_right <= cells.size.columns) {
                        const row_start = bg_start + scroll_left;
                        const row_end = bg_start + scroll_right;
                        @memcpy(cells.bg_cells[row_start..row_end], scrollback_row.bg_cells[scroll_left..scroll_right]);
                    }
                }

                // Foreground
                const fg_row_index = grid_row + 1;
                if (fg_row_index < cells.fg_rows.lists.len) {
                    const dest_list = &cells.fg_rows.lists[fg_row_index];
                    dest_list.clearRetainingCapacity();

                    if (full_width) {
                        for (scrollback_row.fg_cells.items) |cell_text| {
                            var adjusted = cell_text;
                            adjusted.grid_pos[1] = @intCast(grid_row);
                            try dest_list.append(self.alloc, adjusted);
                        }
                    } else {
                        const current_row = self.getRow(@intCast(i));
                        if (current_row) |row_ptr| {
                            for (row_ptr.fg_cells.items) |cell_text| {
                                if (cell_text.grid_pos[0] < scroll_left or cell_text.grid_pos[0] >= scroll_right) {
                                    var adjusted = cell_text;
                                    adjusted.grid_pos[1] = @intCast(grid_row);
                                    try dest_list.append(self.alloc, adjusted);
                                }
                            }
                        }
                        for (scrollback_row.fg_cells.items) |cell_text| {
                            if (cell_text.grid_pos[0] >= scroll_left and cell_text.grid_pos[0] < scroll_right) {
                                var adjusted = cell_text;
                                adjusted.grid_pos[1] = @intCast(grid_row);
                                try dest_list.append(self.alloc, adjusted);
                            }
                        }
                    }
                }
            } else {
                // For EXTRA rows (ghost rows), we inject them into the nearest valid scrollable row list.
                // We do NOT touch the background or clear the list, so header/footer stays intact.
                // We rely on IS_SCROLL_GLYPH + vertex shader to shift them, and fragment shader to clip.

                // Clamp destination row to stay inside the scroll region.
                var dest_row_idx = grid_row_signed;
                const scroll_top: isize = @intCast(self.scroll_region_top);
                const scroll_bot: isize = @intCast(self.scroll_region_bot);
                if (dest_row_idx < scroll_top) {
                    dest_row_idx = scroll_top;
                } else if (dest_row_idx >= scroll_bot) {
                    dest_row_idx = scroll_bot - 1;
                }

                if (dest_row_idx < 0 or dest_row_idx >= self.grid_rows) continue;
                const fg_row_index = @as(usize, @intCast(dest_row_idx)) + 1;

                if (fg_row_index < cells.fg_rows.lists.len) {
                    const dest_list = &cells.fg_rows.lists[fg_row_index];
                    // Append to existing content

                    for (scrollback_row.fg_cells.items) |cell_text| {
                        if (!full_width and (cell_text.grid_pos[0] < scroll_left or cell_text.grid_pos[0] >= scroll_right)) {
                            continue;
                        }
                        var adjusted = cell_text;
                        // Use REAL logical position (e.g. inside header) so shift calculation is correct relative to start
                        // But wait, if grid_pos is outside region, in_scroll check fails unless we set flag.
                        // We assume grid_row_signed is correct logic position.
                        // However, grid_pos is u16. If grid_row_signed is negative, we can't represent it!

                        // If row -1, we can't set grid_pos.y = -1.
                        // Vertex shader uses grid_pos to compute cell_pos.
                        // If we can't represent -1, we can't place it correctly.

                        // Trick: Set grid_pos to NEAREST valid, and rely on shader offset?
                        // No, shader offset is uniform `tui_scroll_offset_y`.

                        // We need to render at `header - shift`.
                        // If we can't express `header - 1`, we have a problem.

                        // Wait, if scrolling UP (content moves DOWN).
                        // Ghost row is at `header`. Shifted DOWN into view.
                        // `grid_row` = header (0). Valid u16!
                        // Shift = +offset.
                        // Result: 0 + offset. Visible.

                        // If scrolling DOWN (content moves UP).
                        // Ghost row is at `footer`. Shifted UP into view.
                        // `grid_row` = footer. Valid u16!
                        // Shift = -offset.
                        // Result: footer - offset. Visible.

                        // So grid_row IS always valid u16, because it's the SOURCE position.
                        // The "ghost" comes from the header row or footer row.

                        if (dest_row_idx >= 0 and dest_row_idx < self.grid_rows) {
                            adjusted.grid_pos[1] = @intCast(dest_row_idx);
                            adjusted.bools.is_scroll_glyph = true;
                            try dest_list.append(self.alloc, adjusted);
                        }
                    }
                }
            }
        }
    }

    /// Restore the cells buffer to its clean state after rendering.
    ///
    /// Since populateCellsForRender() modifies self.cells in-place to show the animation,
    /// we must restore the clean content before the next frame's flush() reads it.
    ///
    /// Fortunately, scrollback[0..inner_size] contains exactly the clean content
    /// (it was copied from self.cells during flush() just before we modified it).
    pub fn restoreCells(
        self: *Self,
        cells: anytype,
    ) !void {
        if (!self.is_animating or self.scrollback_lines.isEmpty()) return;

        const inner_size = self.getScrollableRowCount();

        // Restore each row in the scroll region
        for (0..inner_size) |i| {
            // scrollback[i] (index 0+) holds the clean NEW content
            // getPtr returns a pointer to the element in the buffer (which is itself a *ScrollbackRow)
            const scrollback_row_ptr = self.scrollback_lines.getPtr(@intCast(i));
            const scrollback_row = scrollback_row_ptr.*;

            const grid_row = self.scroll_region_top + i;

            // Restore background cells
            const bg_start = grid_row * cells.size.columns;
            const bg_end = bg_start + cells.size.columns;
            if (bg_end <= cells.bg_cells.len and scrollback_row.columns == cells.size.columns) {
                @memcpy(cells.bg_cells[bg_start..bg_end], scrollback_row.bg_cells);
            }

            // Restore foreground cells
            const fg_row_index = grid_row + 1;
            if (fg_row_index < cells.fg_rows.lists.len) {
                const dest_list = &cells.fg_rows.lists[fg_row_index];
                dest_list.clearRetainingCapacity();

                for (scrollback_row.fg_cells.items) |cell_text| {
                    var adjusted = cell_text;
                    // Restore original grid_pos (should match grid_row)
                    adjusted.grid_pos[1] = @intCast(grid_row);
                    try dest_list.append(self.alloc, adjusted);
                }
            }
        }
    }
};

test "RingBuffer basic operations" {
    const alloc = std.testing.allocator;
    var buf = try RingBuffer(i32).init(alloc, 5, 0);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 5), buf.len());
    try std.testing.expectEqual(@as(i32, 0), buf.get(0));

    buf.set(0, 10);
    buf.set(1, 20);
    buf.set(2, 30);
    try std.testing.expectEqual(@as(i32, 10), buf.get(0));
    try std.testing.expectEqual(@as(i32, 20), buf.get(1));
    try std.testing.expectEqual(@as(i32, 30), buf.get(2));

    buf.rotate(1);
    try std.testing.expectEqual(@as(i32, 20), buf.get(0));
    try std.testing.expectEqual(@as(i32, 10), buf.get(-1));
    try std.testing.expectEqual(@as(i32, 30), buf.get(1));
}

test "RingBuffer scroll simulation" {
    const alloc = std.testing.allocator;
    var buf = try RingBuffer(i32).init(alloc, 10, 0);
    defer buf.deinit();

    // Initial content
    for (0..5) |i| {
        buf.set(@intCast(i), @intCast(i * 10));
    }

    // Scroll down by 1
    buf.rotate(1);

    // After rotation: index -1 has old index 0's value
    try std.testing.expectEqual(@as(i32, 10), buf.get(0)); // was at index 1
    try std.testing.expectEqual(@as(i32, 0), buf.get(-1)); // was at index 0

    // Overwrite index 0 with new content (simulating Neovim redraw)
    buf.set(0, 100);

    // Old content at -1 is preserved, new content at 0
    try std.testing.expectEqual(@as(i32, 0), buf.get(-1)); // old
    try std.testing.expectEqual(@as(i32, 100), buf.get(0)); // new
}
