//! Rendered Panel - Cell grid for panel TUI output
//!
//! This is a lightweight VT state machine that processes the PTY output from
//! lazygit/lazydocker/etc. into a cell grid that the renderer can composit
//! alongside the main terminal content.
//!
//! Unlike neovim_gui's RenderedWindow (which receives pre-parsed cell data
//! from Neovim's ext_multigrid protocol), this module processes raw VT escape
//! sequences into a grid of colored cells.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.rendered_panel);

/// A single cell in the panel grid
pub const Cell = struct {
    /// UTF-8 text (up to 4 bytes for most cases)
    text: [8]u8 = .{0} ** 8,
    text_len: u8 = 0,

    /// Foreground color (RGB) - Catppuccin Mocha Text
    fg: u32 = 0xcdd6f4,
    /// Background color (RGB) - Catppuccin Mocha Base
    bg: u32 = 0x1e1e2e,

    /// Attributes
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    dim: bool = false,

    /// Whether this cell has been modified since last render
    dirty: bool = true,

    pub fn setText(self: *Cell, str: []const u8) void {
        const len = @min(str.len, 8);
        @memcpy(self.text[0..len], str[0..len]);
        self.text_len = @intCast(len);
        self.dirty = true;
    }

    pub fn getText(self: *const Cell) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn clear(self: *Cell) void {
        self.text_len = 0;
        self.fg = 0xcdd6f4;
        self.bg = 0x1e1e2e;
        self.bold = false;
        self.italic = false;
        self.underline = false;
        self.reverse = false;
        self.dim = false;
        self.dirty = true;
    }

    pub fn setDefaultColors(self: *Cell, fg: u32, bg: u32) void {
        self.fg = fg;
        self.bg = bg;
    }
};

/// SGR (Select Graphic Rendition) state - current text attributes
const SgrState = struct {
    fg: u32 = 0xcdd6f4,
    bg: u32 = 0x1e1e2e,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    dim: bool = false,

    fn applyToCell(self: *const SgrState, cell: *Cell) void {
        cell.fg = self.fg;
        cell.bg = self.bg;
        cell.bold = self.bold;
        cell.italic = self.italic;
        cell.underline = self.underline;
        cell.reverse = self.reverse;
        cell.dim = self.dim;
    }

    fn reset(self: *SgrState) void {
        self.* = .{};
    }
};

/// The rendered panel state. Holds a cell grid and a mini VT parser.
pub const RenderedPanel = struct {
    const Self = @This();

    alloc: Allocator,

    /// Grid dimensions
    cols: u32,
    rows: u32,

    /// Cell grid (rows * cols)
    cells: []Cell,

    /// Cursor position (0-based)
    cursor_row: u32 = 0,
    cursor_col: u32 = 0,
    cursor_visible: bool = true,

    /// Current SGR state
    sgr: SgrState = .{},

    /// Default colors (Catppuccin Mocha)
    default_fg: u32 = 0xcdd6f4, // Text
    default_bg: u32 = 0x1e1e2e, // Base

    /// VT parser state
    parse_state: ParseState = .ground,

    /// Parameter buffer for CSI sequences
    params: [16]u32 = .{0} ** 16,
    param_count: u8 = 0,
    /// Current parameter being accumulated
    current_param: u32 = 0,
    has_current_param: bool = false,

    /// OSC string buffer
    osc_buf: [256]u8 = undefined,
    osc_len: u16 = 0,

    /// Intermediate bytes for CSI sequences
    intermediate: u8 = 0,

    /// Scroll region (top inclusive, bottom inclusive, 0-based)
    scroll_top: u32 = 0,
    scroll_bottom: u32 = 0, // set to rows-1 on init

    /// Whether the grid has been modified
    dirty: bool = true,

    /// Saved cursor position (for DECSC/DECRC)
    saved_cursor_row: u32 = 0,
    saved_cursor_col: u32 = 0,

    /// Application cursor keys mode (DECCKM)
    app_cursor_keys: bool = false,

    /// Alternate screen active
    alt_screen_active: bool = false,
    /// Saved primary screen cells
    saved_cells: ?[]Cell = null,
    saved_cursor_row_alt: u32 = 0,
    saved_cursor_col_alt: u32 = 0,

    const ParseState = enum {
        ground,
        escape,
        escape_intermediate,
        csi_entry,
        csi_param,
        csi_intermediate,
        osc_string,
        dcs_passthrough,
    };

    pub fn init(alloc: Allocator, cols: u32, rows: u32) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const cell_count = cols * rows;
        const cells = try alloc.alloc(Cell, cell_count);
        for (cells) |*cell| {
            cell.* = Cell{};
        }

        self.* = .{
            .alloc = alloc,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .scroll_bottom = rows -| 1,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.alloc.free(self.cells);
        if (self.saved_cells) |sc| self.alloc.free(sc);
        self.alloc.destroy(self);
    }

    /// Resize the panel grid. Clears content.
    pub fn resize(self: *Self, new_cols: u32, new_rows: u32) !void {
        const cell_count = new_cols * new_rows;
        const new_cells = try self.alloc.alloc(Cell, cell_count);
        for (new_cells) |*cell| {
            cell.* = Cell{};
        }
        self.alloc.free(self.cells);
        self.cells = new_cells;
        self.cols = new_cols;
        self.rows = new_rows;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.scroll_top = 0;
        self.scroll_bottom = new_rows -| 1;
        self.dirty = true;
    }

    /// Get a cell at (row, col)
    pub fn getCell(self: *const Self, row: u32, col: u32) *const Cell {
        if (row >= self.rows or col >= self.cols) {
            // Return a default cell for out-of-bounds
            const static_cell = &(Cell{});
            return static_cell;
        }
        return &self.cells[row * self.cols + col];
    }

    /// Get a mutable cell at (row, col)
    pub fn getCellMut(self: *Self, row: u32, col: u32) ?*Cell {
        if (row >= self.rows or col >= self.cols) return null;
        return &self.cells[row * self.cols + col];
    }

    /// Process raw VT output bytes from the PTY
    pub fn processOutput(self: *Self, data: []const u8) void {
        for (data) |byte| {
            self.processByte(byte);
        }
    }

    fn processByte(self: *Self, byte: u8) void {
        switch (self.parse_state) {
            .ground => self.processGround(byte),
            .escape => self.processEscape(byte),
            .escape_intermediate => self.processEscapeIntermediate(byte),
            .csi_entry => self.processCsiEntry(byte),
            .csi_param => self.processCsiParam(byte),
            .csi_intermediate => self.processCsiIntermediate(byte),
            .osc_string => self.processOscString(byte),
            .dcs_passthrough => self.processDcsPassthrough(byte),
        }
    }

    fn processGround(self: *Self, byte: u8) void {
        switch (byte) {
            0x00...0x06, 0x0e...0x1a, 0x1c...0x1f => {
                // C0 control characters (ignore most)
            },
            0x07 => {
                // BEL - ignore in panel
            },
            0x08 => {
                // BS - backspace
                if (self.cursor_col > 0) self.cursor_col -= 1;
            },
            0x09 => {
                // HT - tab
                self.cursor_col = @min(self.cursor_col + (8 - (self.cursor_col % 8)), self.cols - 1);
            },
            0x0a, 0x0b, 0x0c => {
                // LF, VT, FF - line feed
                self.lineFeed();
            },
            0x0d => {
                // CR - carriage return
                self.cursor_col = 0;
            },
            0x1b => {
                // ESC
                self.parse_state = .escape;
            },
            0x20...0x7e => {
                // Printable ASCII
                self.putChar(byte);
            },
            0x7f => {
                // DEL - ignore
            },
            0x80...0xff => {
                // UTF-8 lead/continuation bytes
                self.putChar(byte);
            },
        }
    }

    fn processEscape(self: *Self, byte: u8) void {
        switch (byte) {
            '[' => {
                // CSI
                self.parse_state = .csi_entry;
                self.params = .{0} ** 16;
                self.param_count = 0;
                self.current_param = 0;
                self.has_current_param = false;
                self.intermediate = 0;
            },
            ']' => {
                // OSC
                self.parse_state = .osc_string;
                self.osc_len = 0;
            },
            'P' => {
                // DCS
                self.parse_state = .dcs_passthrough;
            },
            '7' => {
                // DECSC - Save cursor
                self.saved_cursor_row = self.cursor_row;
                self.saved_cursor_col = self.cursor_col;
                self.parse_state = .ground;
            },
            '8' => {
                // DECRC - Restore cursor
                self.cursor_row = self.saved_cursor_row;
                self.cursor_col = self.saved_cursor_col;
                self.parse_state = .ground;
            },
            'D' => {
                // IND - Index (move down, scroll if at bottom)
                self.lineFeed();
                self.parse_state = .ground;
            },
            'M' => {
                // RI - Reverse Index (move up, scroll if at top)
                if (self.cursor_row == self.scroll_top) {
                    self.scrollDown();
                } else if (self.cursor_row > 0) {
                    self.cursor_row -= 1;
                }
                self.parse_state = .ground;
            },
            'c' => {
                // RIS - Full reset
                self.fullReset();
                self.parse_state = .ground;
            },
            '(' => {
                // Designate G0 character set - consume next byte
                self.parse_state = .escape_intermediate;
            },
            ')' => {
                // Designate G1 character set - consume next byte
                self.parse_state = .escape_intermediate;
            },
            '=' => {
                // DECKPAM - Application Keypad
                self.parse_state = .ground;
            },
            '>' => {
                // DECKPNM - Normal Keypad
                self.parse_state = .ground;
            },
            else => {
                self.parse_state = .ground;
            },
        }
    }

    fn processEscapeIntermediate(self: *Self, byte: u8) void {
        // Consume the intermediate byte (e.g., character set designator)
        _ = byte;
        self.parse_state = .ground;
    }

    fn processCsiEntry(self: *Self, byte: u8) void {
        switch (byte) {
            '0'...'9' => {
                self.current_param = byte - '0';
                self.has_current_param = true;
                self.parse_state = .csi_param;
            },
            ';' => {
                // Empty first parameter
                if (self.param_count < 16) {
                    self.params[self.param_count] = 0;
                    self.param_count += 1;
                }
                self.parse_state = .csi_param;
            },
            '?' => {
                self.intermediate = '?';
                self.parse_state = .csi_param;
            },
            '>' => {
                self.intermediate = '>';
                self.parse_state = .csi_param;
            },
            0x40...0x7e => {
                // Final byte with no params
                self.finishParam();
                self.executeCsi(byte);
                self.parse_state = .ground;
            },
            else => {
                self.parse_state = .ground;
            },
        }
    }

    fn processCsiParam(self: *Self, byte: u8) void {
        switch (byte) {
            '0'...'9' => {
                self.current_param = self.current_param * 10 + (byte - '0');
                self.has_current_param = true;
            },
            ';' => {
                self.finishParam();
            },
            0x40...0x7e => {
                self.finishParam();
                self.executeCsi(byte);
                self.parse_state = .ground;
            },
            else => {
                self.parse_state = .ground;
            },
        }
    }

    fn processCsiIntermediate(self: *Self, byte: u8) void {
        if (byte >= 0x40 and byte <= 0x7e) {
            self.executeCsi(byte);
            self.parse_state = .ground;
        }
    }

    fn processOscString(self: *Self, byte: u8) void {
        switch (byte) {
            0x07 => {
                // BEL terminates OSC
                self.parse_state = .ground;
            },
            0x1b => {
                // ESC might start ST (ESC \)
                self.parse_state = .ground;
            },
            else => {
                if (self.osc_len < 256) {
                    self.osc_buf[self.osc_len] = byte;
                    self.osc_len += 1;
                }
            },
        }
    }

    fn processDcsPassthrough(self: *Self, byte: u8) void {
        // Consume DCS until ST
        if (byte == 0x1b) {
            self.parse_state = .escape;
        }
        // Otherwise stay in passthrough
    }

    fn finishParam(self: *Self) void {
        if (self.param_count < 16) {
            if (self.has_current_param) {
                self.params[self.param_count] = self.current_param;
            } else {
                self.params[self.param_count] = 0;
            }
            self.param_count += 1;
        }
        self.current_param = 0;
        self.has_current_param = false;
    }

    fn executeCsi(self: *Self, final: u8) void {
        const is_private = self.intermediate == '?';

        if (is_private) {
            self.executeCsiPrivate(final);
            return;
        }

        switch (final) {
            'A' => {
                // CUU - Cursor Up
                const n = @max(self.getParam(0, 1), 1);
                self.cursor_row -|= n;
            },
            'B' => {
                // CUD - Cursor Down
                const n = @max(self.getParam(0, 1), 1);
                self.cursor_row = @min(self.cursor_row + n, self.rows - 1);
            },
            'C' => {
                // CUF - Cursor Forward
                const n = @max(self.getParam(0, 1), 1);
                self.cursor_col = @min(self.cursor_col + n, self.cols - 1);
            },
            'D' => {
                // CUB - Cursor Back
                const n = @max(self.getParam(0, 1), 1);
                self.cursor_col -|= n;
            },
            'E' => {
                // CNL - Cursor Next Line
                const n = @max(self.getParam(0, 1), 1);
                self.cursor_row = @min(self.cursor_row + n, self.rows - 1);
                self.cursor_col = 0;
            },
            'F' => {
                // CPL - Cursor Previous Line
                const n = @max(self.getParam(0, 1), 1);
                self.cursor_row -|= n;
                self.cursor_col = 0;
            },
            'G' => {
                // CHA - Cursor Character Absolute
                const col = @max(self.getParam(0, 1), 1) - 1;
                self.cursor_col = @min(col, self.cols - 1);
            },
            'H', 'f' => {
                // CUP / HVP - Cursor Position
                const row = @max(self.getParam(0, 1), 1) - 1;
                const col = @max(self.getParam(1, 1), 1) - 1;
                self.cursor_row = @min(row, self.rows - 1);
                self.cursor_col = @min(col, self.cols - 1);
            },
            'J' => {
                // ED - Erase in Display
                self.eraseDisplay(self.getParam(0, 0));
            },
            'K' => {
                // EL - Erase in Line
                self.eraseLine(self.getParam(0, 0));
            },
            'L' => {
                // IL - Insert Lines
                const n = @max(self.getParam(0, 1), 1);
                self.insertLines(n);
            },
            'M' => {
                // DL - Delete Lines
                const n = @max(self.getParam(0, 1), 1);
                self.deleteLines(n);
            },
            'P' => {
                // DCH - Delete Characters
                const n = @max(self.getParam(0, 1), 1);
                self.deleteChars(n);
            },
            'S' => {
                // SU - Scroll Up
                const n = @max(self.getParam(0, 1), 1);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    self.scrollUp();
                }
            },
            'T' => {
                // SD - Scroll Down
                const n = @max(self.getParam(0, 1), 1);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    self.scrollDown();
                }
            },
            'X' => {
                // ECH - Erase Characters
                const n = @max(self.getParam(0, 1), 1);
                self.eraseChars(n);
            },
            'd' => {
                // VPA - Line Position Absolute
                const row = @max(self.getParam(0, 1), 1) - 1;
                self.cursor_row = @min(row, self.rows - 1);
            },
            'm' => {
                // SGR - Select Graphic Rendition
                self.executeSgr();
            },
            'r' => {
                // DECSTBM - Set Scrolling Region
                const top = @max(self.getParam(0, 1), 1) - 1;
                const bottom = @max(self.getParam(1, @as(u32, @intCast(self.rows))), 1) - 1;
                self.scroll_top = @min(top, self.rows - 1);
                self.scroll_bottom = @min(bottom, self.rows - 1);
                self.cursor_row = 0;
                self.cursor_col = 0;
            },
            '@' => {
                // ICH - Insert Characters
                const n = @max(self.getParam(0, 1), 1);
                self.insertChars(n);
            },
            'c' => {
                // DA - Device Attributes (ignore response)
            },
            'n' => {
                // DSR - Device Status Report (ignore)
            },
            't' => {
                // Window manipulation (ignore)
            },
            else => {
                // Unknown CSI - ignore
            },
        }
        self.dirty = true;
    }

    fn executeCsiPrivate(self: *Self, final: u8) void {
        switch (final) {
            'h' => {
                // DECSET
                const mode = self.getParam(0, 0);
                switch (mode) {
                    1 => self.app_cursor_keys = true, // DECCKM
                    25 => self.cursor_visible = true,
                    1049 => self.enterAltScreen(), // Alt screen
                    2004 => {}, // Bracketed paste (ignore)
                    else => {},
                }
            },
            'l' => {
                // DECRST
                const mode = self.getParam(0, 0);
                switch (mode) {
                    1 => self.app_cursor_keys = false, // DECCKM
                    25 => self.cursor_visible = false,
                    1049 => self.leaveAltScreen(), // Alt screen
                    2004 => {}, // Bracketed paste (ignore)
                    else => {},
                }
            },
            else => {},
        }
    }

    fn getParam(self: *const Self, idx: u8, default: u32) u32 {
        if (idx >= self.param_count) return default;
        const val = self.params[idx];
        return if (val == 0) default else val;
    }

    fn putChar(self: *Self, byte: u8) void {
        if (self.cursor_col >= self.cols) {
            // Auto-wrap
            self.cursor_col = 0;
            self.lineFeed();
        }

        if (self.getCellMut(self.cursor_row, self.cursor_col)) |cell| {
            cell.text[0] = byte;
            cell.text_len = 1;
            self.sgr.applyToCell(cell);
            cell.dirty = true;
        }

        self.cursor_col += 1;
        self.dirty = true;
    }

    fn lineFeed(self: *Self) void {
        if (self.cursor_row >= self.scroll_bottom) {
            self.scrollUp();
        } else {
            self.cursor_row += 1;
        }
    }

    fn scrollUp(self: *Self) void {
        // Move lines up within scroll region
        var row = self.scroll_top;
        while (row < self.scroll_bottom) : (row += 1) {
            const dst_start = row * self.cols;
            const src_start = (row + 1) * self.cols;
            const len = self.cols;
            @memcpy(self.cells[dst_start..][0..len], self.cells[src_start..][0..len]);
        }
        // Clear the bottom line
        const bottom_start = self.scroll_bottom * self.cols;
        for (self.cells[bottom_start..][0..self.cols]) |*cell| {
            cell.clear();
        }
        self.dirty = true;
    }

    fn scrollDown(self: *Self) void {
        // Move lines down within scroll region
        var row = self.scroll_bottom;
        while (row > self.scroll_top) : (row -= 1) {
            const dst_start = row * self.cols;
            const src_start = (row - 1) * self.cols;
            const len = self.cols;
            @memcpy(self.cells[dst_start..][0..len], self.cells[src_start..][0..len]);
        }
        // Clear the top line
        const top_start = self.scroll_top * self.cols;
        for (self.cells[top_start..][0..self.cols]) |*cell| {
            cell.clear();
        }
        self.dirty = true;
    }

    fn eraseDisplay(self: *Self, mode: u32) void {
        switch (mode) {
            0 => {
                // Erase from cursor to end of screen
                const start = self.cursor_row * self.cols + self.cursor_col;
                for (self.cells[start..]) |*cell| cell.clear();
            },
            1 => {
                // Erase from start to cursor
                const end = self.cursor_row * self.cols + self.cursor_col + 1;
                for (self.cells[0..@min(end, self.cells.len)]) |*cell| cell.clear();
            },
            2, 3 => {
                // Erase entire screen
                for (self.cells) |*cell| cell.clear();
            },
            else => {},
        }
        self.dirty = true;
    }

    fn eraseLine(self: *Self, mode: u32) void {
        const row_start = self.cursor_row * self.cols;
        switch (mode) {
            0 => {
                // Erase from cursor to end of line
                const start = row_start + self.cursor_col;
                const end = row_start + self.cols;
                for (self.cells[start..end]) |*cell| cell.clear();
            },
            1 => {
                // Erase from start of line to cursor
                const end = row_start + self.cursor_col + 1;
                for (self.cells[row_start..@min(end, row_start + self.cols)]) |*cell| cell.clear();
            },
            2 => {
                // Erase entire line
                for (self.cells[row_start..][0..self.cols]) |*cell| cell.clear();
            },
            else => {},
        }
        self.dirty = true;
    }

    fn insertLines(self: *Self, count: u32) void {
        const n = @min(count, self.scroll_bottom - self.cursor_row + 1);
        // Shift lines down
        var row = self.scroll_bottom;
        while (row >= self.cursor_row + n) : (row -= 1) {
            const dst = row * self.cols;
            const src = (row - n) * self.cols;
            @memcpy(self.cells[dst..][0..self.cols], self.cells[src..][0..self.cols]);
            if (row == self.cursor_row + n) break;
        }
        // Clear inserted lines
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const start = (self.cursor_row + i) * self.cols;
            for (self.cells[start..][0..self.cols]) |*cell| cell.clear();
        }
        self.dirty = true;
    }

    fn deleteLines(self: *Self, count: u32) void {
        const n = @min(count, self.scroll_bottom - self.cursor_row + 1);
        // Shift lines up
        var row = self.cursor_row;
        while (row + n <= self.scroll_bottom) : (row += 1) {
            const dst = row * self.cols;
            const src = (row + n) * self.cols;
            @memcpy(self.cells[dst..][0..self.cols], self.cells[src..][0..self.cols]);
        }
        // Clear vacated lines at the bottom
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const start = (self.scroll_bottom - i) * self.cols;
            for (self.cells[start..][0..self.cols]) |*cell| cell.clear();
        }
        self.dirty = true;
    }

    fn deleteChars(self: *Self, count: u32) void {
        const row_start = self.cursor_row * self.cols;
        const n = @min(count, self.cols - self.cursor_col);
        const start = row_start + self.cursor_col;
        const end = row_start + self.cols;

        // Shift chars left
        var i = start;
        while (i + n < end) : (i += 1) {
            self.cells[i] = self.cells[i + n];
        }
        // Clear remainder
        while (i < end) : (i += 1) {
            self.cells[i].clear();
        }
        self.dirty = true;
    }

    fn insertChars(self: *Self, count: u32) void {
        const row_start = self.cursor_row * self.cols;
        const n = @min(count, self.cols - self.cursor_col);
        const start = row_start + self.cursor_col;
        const end = row_start + self.cols;

        // Shift chars right
        var i = end - 1;
        while (i >= start + n) : (i -= 1) {
            self.cells[i] = self.cells[i - n];
            if (i == start + n) break;
        }
        // Clear inserted positions
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            self.cells[start + j].clear();
        }
        self.dirty = true;
    }

    fn eraseChars(self: *Self, count: u32) void {
        const n = @min(count, self.cols - self.cursor_col);
        const start = self.cursor_row * self.cols + self.cursor_col;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            self.cells[start + i].clear();
        }
        self.dirty = true;
    }

    fn enterAltScreen(self: *Self) void {
        if (self.alt_screen_active) return;
        self.alt_screen_active = true;
        self.saved_cursor_row_alt = self.cursor_row;
        self.saved_cursor_col_alt = self.cursor_col;

        // Save current screen
        self.saved_cells = self.alloc.dupe(Cell, self.cells) catch null;

        // Clear screen
        for (self.cells) |*cell| cell.clear();
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.dirty = true;
    }

    fn leaveAltScreen(self: *Self) void {
        if (!self.alt_screen_active) return;
        self.alt_screen_active = false;

        // Restore saved screen
        if (self.saved_cells) |sc| {
            const len = @min(sc.len, self.cells.len);
            @memcpy(self.cells[0..len], sc[0..len]);
            self.alloc.free(sc);
            self.saved_cells = null;
        }
        self.cursor_row = self.saved_cursor_row_alt;
        self.cursor_col = self.saved_cursor_col_alt;
        self.dirty = true;
    }

    fn fullReset(self: *Self) void {
        for (self.cells) |*cell| cell.clear();
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.cursor_visible = true;
        self.sgr.reset();
        self.scroll_top = 0;
        self.scroll_bottom = self.rows -| 1;
        self.app_cursor_keys = false;
        self.dirty = true;
    }

    fn executeSgr(self: *Self) void {
        if (self.param_count == 0) {
            self.sgr.reset();
            return;
        }

        var i: u8 = 0;
        while (i < self.param_count) : (i += 1) {
            const p = self.params[i];
            switch (p) {
                0 => self.sgr.reset(),
                1 => self.sgr.bold = true,
                2 => self.sgr.dim = true,
                3 => self.sgr.italic = true,
                4 => self.sgr.underline = true,
                7 => self.sgr.reverse = true,
                22 => {
                    self.sgr.bold = false;
                    self.sgr.dim = false;
                },
                23 => self.sgr.italic = false,
                24 => self.sgr.underline = false,
                27 => self.sgr.reverse = false,

                // Standard foreground colors
                30 => self.sgr.fg = 0x000000,
                31 => self.sgr.fg = 0xcc0000,
                32 => self.sgr.fg = 0x00cc00,
                33 => self.sgr.fg = 0xcccc00,
                34 => self.sgr.fg = 0x0000cc,
                35 => self.sgr.fg = 0xcc00cc,
                36 => self.sgr.fg = 0x00cccc,
                37 => self.sgr.fg = 0xcccccc,
                39 => self.sgr.fg = self.default_fg,

                // Standard background colors
                40 => self.sgr.bg = 0x000000,
                41 => self.sgr.bg = 0xcc0000,
                42 => self.sgr.bg = 0x00cc00,
                43 => self.sgr.bg = 0xcccc00,
                44 => self.sgr.bg = 0x0000cc,
                45 => self.sgr.bg = 0xcc00cc,
                46 => self.sgr.bg = 0x00cccc,
                47 => self.sgr.bg = 0xcccccc,
                49 => self.sgr.bg = self.default_bg,

                // Bright foreground colors
                90 => self.sgr.fg = 0x555555,
                91 => self.sgr.fg = 0xff5555,
                92 => self.sgr.fg = 0x55ff55,
                93 => self.sgr.fg = 0xffff55,
                94 => self.sgr.fg = 0x5555ff,
                95 => self.sgr.fg = 0xff55ff,
                96 => self.sgr.fg = 0x55ffff,
                97 => self.sgr.fg = 0xffffff,

                // Bright background colors
                100 => self.sgr.bg = 0x555555,
                101 => self.sgr.bg = 0xff5555,
                102 => self.sgr.bg = 0x55ff55,
                103 => self.sgr.bg = 0xffff55,
                104 => self.sgr.bg = 0x5555ff,
                105 => self.sgr.bg = 0xff55ff,
                106 => self.sgr.bg = 0x55ffff,
                107 => self.sgr.bg = 0xffffff,

                // 256-color and truecolor
                38 => {
                    if (i + 1 < self.param_count and self.params[i + 1] == 5) {
                        // 256-color: ESC[38;5;Nm
                        if (i + 2 < self.param_count) {
                            self.sgr.fg = color256ToRgb(self.params[i + 2]);
                            i += 2;
                        }
                    } else if (i + 1 < self.param_count and self.params[i + 1] == 2) {
                        // Truecolor: ESC[38;2;R;G;Bm
                        if (i + 4 < self.param_count) {
                            const r = @as(u32, @min(self.params[i + 2], 255));
                            const g = @as(u32, @min(self.params[i + 3], 255));
                            const b = @as(u32, @min(self.params[i + 4], 255));
                            self.sgr.fg = (r << 16) | (g << 8) | b;
                            i += 4;
                        }
                    }
                },
                48 => {
                    if (i + 1 < self.param_count and self.params[i + 1] == 5) {
                        // 256-color bg
                        if (i + 2 < self.param_count) {
                            self.sgr.bg = color256ToRgb(self.params[i + 2]);
                            i += 2;
                        }
                    } else if (i + 1 < self.param_count and self.params[i + 1] == 2) {
                        // Truecolor bg
                        if (i + 4 < self.param_count) {
                            const r = @as(u32, @min(self.params[i + 2], 255));
                            const g = @as(u32, @min(self.params[i + 3], 255));
                            const b = @as(u32, @min(self.params[i + 4], 255));
                            self.sgr.bg = (r << 16) | (g << 8) | b;
                            i += 4;
                        }
                    }
                },

                else => {},
            }
        }
    }

    /// Clear dirty flags on all cells
    pub fn clearDirty(self: *Self) void {
        self.dirty = false;
    }
};

/// Convert 256-color index to RGB
fn color256ToRgb(idx: u32) u32 {
    if (idx < 16) {
        // Standard colors
        const table = [16]u32{
            0x000000, 0xcc0000, 0x00cc00, 0xcccc00,
            0x0000cc, 0xcc00cc, 0x00cccc, 0xcccccc,
            0x555555, 0xff5555, 0x55ff55, 0xffff55,
            0x5555ff, 0xff55ff, 0x55ffff, 0xffffff,
        };
        return table[idx];
    } else if (idx < 232) {
        // 216 color cube (6x6x6)
        const n = idx - 16;
        const b_val = n % 6;
        const g_val = (n / 6) % 6;
        const r_val = n / 36;
        const r = if (r_val > 0) @as(u32, @intCast(r_val)) * 40 + 55 else 0;
        const g = if (g_val > 0) @as(u32, @intCast(g_val)) * 40 + 55 else 0;
        const b = if (b_val > 0) @as(u32, @intCast(b_val)) * 40 + 55 else 0;
        return (r << 16) | (g << 8) | b;
    } else {
        // Grayscale ramp (indices 232-255)
        const gray = @as(u32, @intCast(idx - 232)) * 10 + 8;
        return (gray << 16) | (gray << 8) | gray;
    }
}

test "RenderedPanel basic output" {
    const alloc = std.testing.allocator;
    const panel = try RenderedPanel.init(alloc, 80, 24);
    defer panel.deinit();

    // Write "Hello"
    panel.processOutput("Hello");
    try std.testing.expectEqualStrings("H", panel.getCell(0, 0).getText());
    try std.testing.expectEqualStrings("e", panel.getCell(0, 1).getText());
    try std.testing.expect(panel.cursor_col == 5);
}

test "RenderedPanel cursor movement" {
    const alloc = std.testing.allocator;
    const panel = try RenderedPanel.init(alloc, 80, 24);
    defer panel.deinit();

    // Move cursor to row 5, col 10 (1-based in VT)
    panel.processOutput("\x1b[6;11H");
    try std.testing.expect(panel.cursor_row == 5);
    try std.testing.expect(panel.cursor_col == 10);
}

test "RenderedPanel color" {
    const alloc = std.testing.allocator;
    const panel = try RenderedPanel.init(alloc, 80, 24);
    defer panel.deinit();

    // Set red foreground, write a character
    panel.processOutput("\x1b[31mX");
    try std.testing.expect(panel.getCell(0, 0).fg == 0xcc0000);
    try std.testing.expectEqualStrings("X", panel.getCell(0, 0).getText());
}
