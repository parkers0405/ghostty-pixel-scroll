//! Shared types for the GUI rendering pipeline.
//!
//! Backends (neovim, notes app, external processes) produce a GuiState each
//! frame. The renderer in generic.zig consumes it to fill GPU buffers.
//! Backend-specific logic (hl_attrs, scrollback rings, msgpack) never leaks
//! past the adapter boundary.

const std = @import("std");

/// One complete frame of GUI state, ready for the renderer.
pub const GuiState = struct {
    /// Pre-sorted render order: roots first (by id), then floats (by zindex).
    windows: []const GuiWindow,
    cursor: GuiCursor,
    config: GuiConfig,
    scroll_animating: bool,
};

/// Frame-level config the renderer needs from the backend.
pub const GuiConfig = struct {
    default_bg: u32,
    default_fg: u32,
    corner_radius: f32,
    gap_color: [3]u8,
    bg_opacity: f32,
};

/// Resolved cell style. Backends do their own hl_id lookups, reverse
/// swaps, default color fills, etc. before producing this.
pub const CellStyle = struct {
    fg: u32,
    bg: u32,
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
    /// Row height multiplier. 1.0 = normal row, 2.0 = double height.
    /// The renderer uses this to compute per-row Y offsets in the
    /// row_y SSBO, giving heading rows more vertical space.
    row_height: f32 = 1.0,
};

/// A cell with text + resolved style. Same 16-byte text buffer as Neovim's
/// GridCell, but everything is pre-resolved so the renderer never touches
/// backend internals.
pub const GuiCell = struct {
    text: [16]u8 = .{0} ** 16,
    text_len: u8 = 0,
    style: CellStyle,

    pub fn getText(self: *const GuiCell) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const WindowType = enum {
    root,
    floating,
    message,
};

/// The renderer's view of one window. All backend-specific state
/// (ring buffers, viewport margins, anchor resolution) is resolved
/// by the adapter before this is built.
pub const GuiWindow = struct {
    id: u64,
    window_type: WindowType,

    /// Position in grid cells (fractional for animated floats).
    grid_col: f32,
    grid_row: f32,

    /// Visible size in cells (already clamped to min(display, grid)).
    render_width: u32,
    render_height: u32,

    opacity: f32,
    zindex: u64,

    // Scroll — pre-computed by the adapter from spring state.
    has_scroll_animation: bool,
    scroll_pixel_offset: f32, // whole-pixel, for GPU
    scroll_raw_offset: f32, // pre-round, for "need extra row?" check

    // Fixed rows that don't participate in scrolling.
    margin_top: u32,
    margin_bottom: u32,

    // Cell access via the adapter. ctx is an opaque pointer the adapter
    // sets to its own window state; the renderer just passes it through.
    getCell: *const fn (ctx: *const anyopaque, row: u32, col: u32) ?GuiCell,
    getScrollCell: *const fn (ctx: *const anyopaque, inner_row: u32, col: u32) ?GuiCell,
    ctx: *const anyopaque,
};

pub const CursorShape = enum {
    block,
    vertical,
    horizontal,
};

pub const GuiCursor = struct {
    visible: bool = true,

    /// Target position for spring animation (includes window offset + scroll).
    grid_x: f32 = 0,
    grid_y: f32 = 0,

    /// Integer cell position (for sprite placement, uniforms).
    screen_col: u16 = 0,
    screen_row: u16 = 0,

    shape: CursorShape = .block,
    cell_percentage: f32 = 0.25,
    blink: bool = false,
    color: u32 = 0xe0e0e0,

    /// Scroll position of the cursor's window. Lets the renderer detect
    /// scroll-induced cursor movement vs actual cursor movement.
    scroll_pos: f32 = 0,
};
