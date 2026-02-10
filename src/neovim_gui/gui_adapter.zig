//! Neovim → GuiState adapter.
//!
//! Translates NeovimGui's internal state into the generic GuiState that the
//! renderer consumes. All neovim-specific edge cases (scrollback validation,
//! margin handling, hl_attr resolution, window partitioning, message window
//! content checks) are resolved HERE — the renderer never sees them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("../gui_protocol.zig");
const markdown = @import("markdown.zig");
const neovim_gui = @import("main.zig");
const NeovimGui = neovim_gui.NeovimGui;
const RenderedWindow = neovim_gui.RenderedWindow;
const HlAttr = neovim_gui.HlAttr;
const GridCell = neovim_gui.GridCell;

const log = std.log.scoped(.neovim_adapter);

/// Scratch space reused across frames to avoid per-frame allocations.
/// Owned by the renderer, passed in each frame.
pub const AdapterState = struct {
    windows_buf: std.ArrayListUnmanaged(gui.GuiWindow) = .empty,
    root_buf: std.ArrayListUnmanaged(*RenderedWindow) = .empty,
    float_buf: std.ArrayListUnmanaged(*RenderedWindow) = .empty,

    pub fn deinit(self: *AdapterState, alloc: Allocator) void {
        self.windows_buf.deinit(alloc);
        self.root_buf.deinit(alloc);
        self.float_buf.deinit(alloc);
    }
};

/// Build a GuiState from the current NeovimGui. The returned state borrows
/// from `nvim` and `scratch` — valid until the next call or nvim mutation.
pub fn buildGuiState(
    nvim: *NeovimGui,
    scratch: *AdapterState,
    alloc: Allocator,
    cell_height: f32,
    corner_radius: f32,
    gap_color: [3]u8,
    bg_opacity: f32,
) !gui.GuiState {
    scratch.windows_buf.clearRetainingCapacity();
    scratch.root_buf.clearRetainingCapacity();
    scratch.float_buf.clearRetainingCapacity();

    // Partition and filter windows — same rules as the old rebuildCellsFromNeovim.
    var win_iter = nvim.windows.valueIterator();
    while (win_iter.next()) |wp| {
        const w = wp.*;
        if (w.hidden or !w.valid) continue;
        if (w.opacity <= 0.0) continue;
        if (w.grid_width == 0 or w.grid_height == 0) continue;
        if (!w.has_position and w.id != 1) continue;
        if (w.needs_content) continue;
        if (w.actual_lines == null) continue;

        const is_float = w.zindex > 0 or w.window_type == .floating or w.window_type == .message;
        if (is_float) {
            try scratch.float_buf.append(alloc, w);
        } else {
            try scratch.root_buf.append(alloc, w);
        }
    }

    // Sort: roots by id (stable), floats by zindex → composition_order → id.
    std.mem.sort(*RenderedWindow, scratch.root_buf.items, {}, struct {
        fn lt(_: void, a: *RenderedWindow, b: *RenderedWindow) bool {
            return a.id < b.id;
        }
    }.lt);
    std.mem.sort(*RenderedWindow, scratch.float_buf.items, {}, struct {
        fn lt(_: void, a: *RenderedWindow, b: *RenderedWindow) bool {
            if (a.zindex != b.zindex) return a.zindex < b.zindex;
            if (a.composition_order != b.composition_order) return a.composition_order < b.composition_order;
            return a.id < b.id;
        }
    }.lt);

    // Build GuiWindows: roots then floats.
    var any_scroll = false;
    for (scratch.root_buf.items) |w| {
        const gw = windowToGui(w, false, cell_height);
        if (gw.has_scroll_animation) any_scroll = true;
        try scratch.windows_buf.append(alloc, gw);
    }
    for (scratch.float_buf.items) |w| {
        const gw = windowToGui(w, true, cell_height);
        try scratch.windows_buf.append(alloc, gw);
    }

    // Build cursor state.
    const cursor = buildCursor(nvim);

    return .{
        .windows = scratch.windows_buf.items,
        .cursor = cursor,
        .config = .{
            .default_bg = nvim.default_background,
            .default_fg = nvim.default_foreground,
            .corner_radius = corner_radius,
            .gap_color = gap_color,
            .bg_opacity = bg_opacity,
        },
        .scroll_animating = any_scroll,
    };
}

// ---------------------------------------------------------------------------
// Window conversion
// ---------------------------------------------------------------------------

fn windowToGui(w: *RenderedWindow, is_float: bool, cell_h: f32) gui.GuiWindow {
    const has_valid_scroll = if (!is_float) w.hasValidScrollbackData() else false;

    // Sub-pixel offset from the spring, rounded to whole pixels for crisp text.
    const raw = if (has_valid_scroll) w.getSubLineOffset(cell_h) else @as(f32, 0);
    const rounded = @round(raw);

    return .{
        .id = w.id,
        .window_type = if (w.window_type == .message)
            gui.WindowType.message
        else if (is_float)
            gui.WindowType.floating
        else
            gui.WindowType.root,

        .grid_col = w.grid_position[0],
        .grid_row = w.grid_position[1],
        .render_width = w.getRenderWidth(),
        .render_height = w.getRenderHeight(),
        .opacity = w.opacity,
        .zindex = w.zindex,

        .has_scroll_animation = has_valid_scroll,
        .scroll_pixel_offset = rounded,
        .scroll_raw_offset = raw,

        .margin_top = w.viewport_margins.top,
        .margin_bottom = w.viewport_margins.bottom,

        .getCell = &getCellWrapper,
        .getScrollCell = &getScrollCellWrapper,
        .ctx = @ptrCast(w),
    };
}

// ---------------------------------------------------------------------------
// Cell access wrappers — these close over a RenderedWindow via the ctx pointer
// and resolve hl_id → CellStyle using the NeovimGui stored in the window's
// io thread backpointer. To avoid that coupling, we stash NeovimGui* in a
// thread-local. It's set once per frame in buildGuiState before any cell
// reads happen. This is safe because rendering is single-threaded.
// ---------------------------------------------------------------------------

/// Per-frame state. Set before cell reads, used by cell wrappers.
/// Single-threaded render loop — no races.
var frame_nvim: ?*NeovimGui = null;
var frame_markdown: bool = false;
var frame_cursor_row: u32 = 0;
var frame_default_bg: u32 = 0;

pub fn isMarkdownActive() bool {
    return frame_markdown;
}

pub fn setFrameNvim(nvim: *NeovimGui) void {
    frame_nvim = nvim;
    frame_cursor_row = @intCast(nvim.cursor_row);
    frame_default_bg = nvim.default_background;
    cached_row_valid = false;

    frame_markdown = false;
    if (nvim.current_filetype) |ft| {
        frame_markdown = std.mem.eql(u8, ft, "markdown") or std.mem.eql(u8, ft, "md");
    }
}

// Row cache for markdown restyling. We cache one row at a time since
// the renderer reads left-to-right, row-by-row. When the row changes,
// we restyle the new row and cache it.
var cached_row_id: u64 = std.math.maxInt(u64); // window id
var cached_row_num: u32 = std.math.maxInt(u32);
var cached_row_is_scroll: bool = false;
var cached_row: [512]gui.GuiCell = undefined;
var cached_row_len: u32 = 0;
var cached_row_valid: bool = false;

fn fillAndRestyleRow(w: *const RenderedWindow, nvim: *const NeovimGui, row: u32, is_scroll: bool) void {
    if (cached_row_valid and cached_row_id == w.id and cached_row_num == row and cached_row_is_scroll == is_scroll) return;

    const width = w.getRenderWidth();
    const limit = @min(width, 512);
    var i: u32 = 0;
    while (i < limit) : (i += 1) {
        const gc = if (is_scroll) w.getScrollbackCellByInnerRow(row, i) else w.getCell(row, i);
        if (gc) |c| {
            cached_row[i] = gridCellToGui(c, nvim);
        } else {
            cached_row[i] = .{ .style = .{ .fg = nvim.default_foreground, .bg = nvim.default_background } };
        }
    }
    cached_row_len = limit;
    cached_row_id = w.id;
    cached_row_num = row;
    cached_row_is_scroll = is_scroll;
    cached_row_valid = true;

    if (frame_markdown) {
        // For scroll cells, inner_row is relative to the scrollable region.
        // cursor_row is grid-local (includes margins). Adjust to match.
        const cursor_for_row = if (is_scroll)
            frame_cursor_row -| w.viewport_margins.top
        else
            frame_cursor_row;
        markdown.restyleLine(cached_row[0..limit], limit, row, cursor_for_row, frame_default_bg);
    }
}

fn getCellWrapper(ctx: *const anyopaque, row: u32, col: u32) ?gui.GuiCell {
    const w: *const RenderedWindow = @ptrCast(@alignCast(ctx));
    const nvim = frame_nvim orelse return null;
    fillAndRestyleRow(w, nvim, row, false);
    if (col >= cached_row_len) return null;
    return cached_row[col];
}

fn getScrollCellWrapper(ctx: *const anyopaque, inner_row: u32, col: u32) ?gui.GuiCell {
    const w: *const RenderedWindow = @ptrCast(@alignCast(ctx));
    const nvim = frame_nvim orelse return null;
    fillAndRestyleRow(w, nvim, inner_row, true);
    if (col >= cached_row_len) return null;
    return cached_row[col];
}

/// Convert a neovim GridCell + hl_id into a backend-agnostic GuiCell.
fn gridCellToGui(gc: *const GridCell, nvim: *const NeovimGui) gui.GuiCell {
    const attr = nvim.getHlAttr(gc.hl_id);
    var cell: gui.GuiCell = .{
        .style = .{
            .fg = attr.foreground.?,
            .bg = attr.background.?,
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
        },
    };
    const text = gc.getText();
    const len = @min(text.len, 16);
    @memcpy(cell.text[0..len], text[0..len]);
    cell.text_len = @intCast(len);
    return cell;
}

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

fn buildCursor(nvim: *const NeovimGui) gui.GuiCursor {
    const cursor_window = nvim.windows.get(nvim.cursor_grid) orelse return .{ .visible = false };
    if (!cursor_window.valid or cursor_window.hidden) return .{ .visible = false };

    const scroll_pos = cursor_window.scroll_animation.position;
    const local_col: f32 = @floatFromInt(nvim.cursor_col);
    const local_row: f32 = @floatFromInt(nvim.cursor_row);

    const grid_x = local_col + cursor_window.grid_position[0];
    const grid_y = local_row + cursor_window.grid_position[1] - scroll_pos;

    const screen_col: u16 = @intFromFloat(@max(0, grid_x));
    const screen_row: u16 = @intFromFloat(@max(0, local_row + cursor_window.grid_position[1]));

    const mode = nvim.getCurrentCursorMode();
    const shape: gui.CursorShape = if (mode) |m| switch (m.shape orelse .block) {
        .block => .block,
        .vertical => .vertical,
        .horizontal => .horizontal,
    } else .block;

    return .{
        .visible = true,
        .grid_x = grid_x,
        .grid_y = grid_y,
        .screen_col = screen_col,
        .screen_row = screen_row,
        .shape = shape,
        .cell_percentage = if (mode) |m| m.cell_percentage orelse 0.25 else 0.25,
        .blink = if (mode) |m| (m.blinkon orelse 0) > 0 else false,
        .color = nvim.default_foreground,
        .scroll_pos = scroll_pos,
    };
}
