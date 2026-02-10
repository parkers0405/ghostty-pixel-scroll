//! Markdown cell restyler.
//!
//! Operates on a row of GuiCells after hl_attr resolution. Detects markdown
//! syntax and modifies cell styles to produce rendered output. Never touches
//! the neovim buffer — purely visual.
//!
//! Called from gui_adapter.zig when the buffer filetype is "markdown".

const std = @import("std");
const gui = @import("../gui_protocol.zig");

// Catppuccin Mocha palette.
const colors = struct {
    const h1: u32 = 0xcba6f7; // mauve
    const h1_bg: u32 = 0x2a2040; // dark mauve tint
    const h2: u32 = 0x89b4fa; // blue
    const h2_bg: u32 = 0x1e2740; // dark blue tint
    const h3: u32 = 0x94e2d5; // teal
    const h3_bg: u32 = 0x1e3535; // dark teal tint
    const h4: u32 = 0xa6e3a1; // green
    const h5: u32 = 0xf9e2af; // yellow
    const h6: u32 = 0xfab387; // peach
    const checkbox_done: u32 = 0xa6e3a1; // green
    const checkbox_todo: u32 = 0x6c7086; // overlay0
    const blockquote_bar: u32 = 0x585b70; // surface2
    const blockquote_text: u32 = 0xa6adc8; // subtext0
    const code_bg: u32 = 0x313244; // surface0
    const code_fg: u32 = 0xcdd6f4; // text
    const hr_color: u32 = 0x585b70; // surface2
    const link_color: u32 = 0x89b4fa; // blue
    const table_border: u32 = 0x45475a; // surface1
    const table_header_bg: u32 = 0x313244; // surface0
    const table_header_fg: u32 = 0xcdd6f4; // text, bold
    const table_row_even_bg: u32 = 0x1e1e2e; // base (transparent feel)
    const table_row_odd_bg: u32 = 0x262637; // slightly lighter
    const table_cell_fg: u32 = 0xbac2de; // subtext1
};

/// Nerd font icons for checkboxes.
const icons = struct {
    const checkbox_empty = "\u{f096}"; // nf-fa-square_o
    const checkbox_checked = "\u{f046}"; // nf-fa-check_square_o
    const blockquote_bar_char = "\u{2502}"; // box drawing vertical │
};

/// Track table context across rows. The adapter calls us row-by-row, so we
/// need minimal state to know if the current row is a header, separator, or
/// body row (and which body row index for alternating colors).
var table_row_index: u32 = 0;
var table_active: bool = false;

/// Restyle a single row of cells in-place. `cursor_row` is the grid-local row
/// where the cursor sits — that row gets passed through unstyled so the user
/// sees raw markdown while editing.
pub fn restyleLine(
    cells: []gui.GuiCell,
    width: u32,
    row: u32,
    cursor_row: u32,
    default_bg: u32,
) void {
    if (width == 0 or cells.len == 0) return;

    // Reveal raw markdown on the cursor line.
    if (row == cursor_row) return;

    // Find where the gutter ends and content starts. Neovim's signcolumn
    // and number column produce leading cells with digits, spaces, and
    // sign characters before the actual buffer text.
    const limit = @min(width, @as(u32, @intCast(cells.len)));
    var content_start: u32 = 0;
    while (content_start < limit) : (content_start += 1) {
        const t = cells[content_start].getText();
        if (t.len == 0) continue;
        const ch = t[0];
        // Gutter: digits, spaces, sign chars (│, ▎, etc are multi-byte).
        if (ch >= '0' and ch <= '9') continue;
        if (ch == ' ') continue;
        // Multi-byte gutter characters (box drawing, sign column icons).
        if (t.len >= 3 and t[0] == 0xe2) continue;
        break;
    }

    // Extract text content from content cells only.
    var line_buf: [512]u8 = undefined;
    var line_len: usize = 0;
    for (cells[content_start..limit]) |cell| {
        const t = cell.getText();
        if (t.len > 0 and line_len + t.len <= line_buf.len) {
            @memcpy(line_buf[line_len..][0..t.len], t);
            line_len += t.len;
        } else if (t.len == 0 and line_len < line_buf.len) {
            line_buf[line_len] = ' ';
            line_len += 1;
        }
    }
    const line = line_buf[0..line_len];
    const trimmed = std.mem.trimLeft(u8, line, " ");

    // Empty lines become compact spacers (Notion-style paragraph gaps).
    if (trimmed.len == 0) {
        for (cells[0..limit]) |*cell| {
            cell.style.row_height = 0.4;
        }
        return;
    }

    // All restylers operate on the content portion (after gutter).
    const content_cells = cells[content_start..limit];
    const content_width = limit - content_start;

    // Reset table tracking if this isn't a table row.
    if (trimmed.len < 3 or trimmed[0] != '|') {
        table_active = false;
        table_row_index = 0;
    }

    if (tryRestyleHeading(content_cells, content_width, trimmed)) return;
    if (tryRestyleCheckbox(content_cells, content_width, trimmed, default_bg)) return;
    if (tryRestyleBlockquote(content_cells, content_width, trimmed)) return;
    if (tryRestyleTable(content_cells, content_width, trimmed)) return;
    if (tryRestyleHorizontalRule(content_cells, content_width, trimmed)) return;
    restyleInline(content_cells, content_width, line);
    restyleEmojiShortcodes(content_cells, content_width, line);
}

// ---------------------------------------------------------------------------
// Headings
// ---------------------------------------------------------------------------

fn tryRestyleHeading(cells: []gui.GuiCell, width: u32, trimmed: []const u8) bool {
    if (trimmed.len == 0 or trimmed[0] != '#') return false;

    var level: u8 = 0;
    for (trimmed) |ch| {
        if (ch == '#') level += 1 else break;
    }
    if (level == 0 or level > 6) return false;
    if (level >= trimmed.len or trimmed[level] != ' ') return false;

    const color = switch (level) {
        1 => colors.h1,
        2 => colors.h2,
        3 => colors.h3,
        4 => colors.h4,
        5 => colors.h5,
        6 => colors.h6,
        else => colors.h1,
    };

    // Row height multiplier — the renderer gives heading rows more vertical
    // space and rasterizes glyphs at the larger size to fill it.
    const row_h: f32 = switch (level) {
        1 => 2.2, // H1: big title
        2 => 1.7, // H2: section header
        3 => 1.3, // H3: subsection
        else => 1.0,
    };

    // Hide # markers and the trailing space.
    const limit = @min(width, @as(u32, @intCast(cells.len)));
    var seen_hashes: u8 = 0;
    var past_markers = false;
    for (cells[0..limit]) |*cell| {
        const t = cell.getText();
        if (!past_markers and t.len > 0) {
            if (seen_hashes < level and t[0] == '#') {
                seen_hashes += 1;
                cell.text_len = 0;
                continue;
            }
            if (seen_hashes == level and t[0] == ' ') {
                cell.text_len = 0;
                past_markers = true;
                continue;
            }
            past_markers = true;
        }
    }

    // Style content cells.
    for (cells[0..limit]) |*cell| {
        cell.style.fg = color;
        cell.style.bold = true;
        cell.style.row_height = row_h;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Checkboxes
// ---------------------------------------------------------------------------

fn tryRestyleCheckbox(cells: []gui.GuiCell, width: u32, trimmed: []const u8, default_bg: u32) bool {
    _ = default_bg;
    // Match "- [ ] " or "- [x] " or "- [X] " with optional leading whitespace.
    if (trimmed.len < 5) return false;
    if (trimmed[0] != '-' or trimmed[1] != ' ' or trimmed[2] != '[') return false;
    if (trimmed[4] != ']') return false;

    const is_checked = trimmed[3] == 'x' or trimmed[3] == 'X';
    const icon = if (is_checked) icons.checkbox_checked else icons.checkbox_empty;
    const icon_color = if (is_checked) colors.checkbox_done else colors.checkbox_todo;

    // Find the "- [ ]" cells and replace them.
    var col: u32 = 0;
    var state: enum { dash, space1, bracket_open, check_char, bracket_close, space2, done } = .dash;
    const limit = @min(width, @as(u32, @intCast(cells.len)));
    while (col < limit) : (col += 1) {
        const t = cells[col].getText();
        if (t.len == 0) continue;
        switch (state) {
            .dash => if (t[0] == '-') {
                // Replace "- [ ] " with the icon in the dash cell.
                const icon_bytes = icon;
                @memcpy(cells[col].text[0..icon_bytes.len], icon_bytes);
                cells[col].text_len = @intCast(icon_bytes.len);
                cells[col].style.fg = icon_color;
                state = .space1;
            },
            .space1 => if (t[0] == ' ') {
                cells[col].text_len = 0; // hide
                state = .bracket_open;
            },
            .bracket_open => if (t[0] == '[') {
                cells[col].text_len = 0;
                state = .check_char;
            },
            .check_char => {
                cells[col].text_len = 0;
                state = .bracket_close;
            },
            .bracket_close => if (t[0] == ']') {
                cells[col].text_len = 0;
                state = .space2;
            },
            .space2 => {
                if (t[0] == ' ') cells[col].text_len = 0;
                state = .done;
            },
            .done => break,
        }
    }

    // Strikethrough text if checked.
    if (is_checked) {
        while (col < limit) : (col += 1) {
            cells[col].style.strikethrough = true;
            cells[col].style.fg = colors.checkbox_todo; // dim
        }
    }

    return state == .done or state == .space2;
}

// ---------------------------------------------------------------------------
// Blockquotes
// ---------------------------------------------------------------------------

fn tryRestyleBlockquote(cells: []gui.GuiCell, width: u32, trimmed: []const u8) bool {
    if (trimmed.len == 0 or trimmed[0] != '>') return false;

    const limit = @min(width, @as(u32, @intCast(cells.len)));
    var found_gt = false;
    for (cells[0..limit]) |*cell| {
        const t = cell.getText();
        if (!found_gt) {
            if (t.len > 0 and t[0] == '>') {
                // Replace > with vertical bar.
                const bar = icons.blockquote_bar_char;
                @memcpy(cell.text[0..bar.len], bar);
                cell.text_len = @intCast(bar.len);
                cell.style.fg = colors.blockquote_bar;
                found_gt = true;
            }
        } else {
            cell.style.fg = colors.blockquote_text;
        }
    }
    return found_gt;
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

fn tryRestyleTable(cells: []gui.GuiCell, width: u32, trimmed: []const u8) bool {
    if (trimmed.len < 3 or trimmed[0] != '|') return false;
    const end = std.mem.trimRight(u8, trimmed, " ");
    if (end.len == 0 or end[end.len - 1] != '|') return false;

    const is_sep = isSeparatorRow(trimmed);
    const limit = @min(width, @as(u32, @intCast(cells.len)));

    // Track table state across rows.
    if (!table_active) {
        // First row of a new table — this is the header.
        table_active = true;
        table_row_index = 0;
    }

    if (is_sep) {
        // Separator row: replace all content with thin horizontal lines.
        // Pipes become intersection characters ┼, dashes become ─.
        for (cells[0..limit]) |*cell| {
            const t = cell.getText();
            if (t.len == 0) {
                // Fill empty cells in separator with ─ for a continuous line.
                cell.text[0] = 0xe2;
                cell.text[1] = 0x94;
                cell.text[2] = 0x80;
                cell.text_len = 3;
                cell.style.fg = colors.table_border;
                cell.style.bg = colors.table_header_bg;
                continue;
            }
            if (t[0] == '|') {
                // Pipe → ┼ (cross) for a clean grid look.
                cell.text[0] = 0xe2;
                cell.text[1] = 0x94;
                cell.text[2] = 0xbc; // ┼ U+253C
                cell.text_len = 3;
                cell.style.fg = colors.table_border;
            } else {
                cell.text[0] = 0xe2;
                cell.text[1] = 0x94;
                cell.text[2] = 0x80; // ─
                cell.text_len = 3;
                cell.style.fg = colors.table_border;
            }
            cell.style.bg = colors.table_header_bg;
        }
        return true;
    }

    // Content row. Row 0 = header, 1+ = body.
    const is_header = table_row_index == 0;
    const row_bg = if (is_header)
        colors.table_header_bg
    else if (table_row_index % 2 == 1)
        colors.table_row_odd_bg
    else
        colors.table_row_even_bg;

    for (cells[0..limit]) |*cell| {
        const t = cell.getText();
        cell.style.bg = row_bg;

        if (t.len > 0 and t[0] == '|') {
            // Pipe → thin vertical │ with border color.
            cell.text[0] = 0xe2;
            cell.text[1] = 0x94;
            cell.text[2] = 0x82; // │
            cell.text_len = 3;
            cell.style.fg = colors.table_border;
        } else if (is_header) {
            cell.style.fg = colors.table_header_fg;
            cell.style.bold = true;
        } else {
            cell.style.fg = colors.table_cell_fg;
        }
    }

    table_row_index += 1;
    return true;
}

fn isSeparatorRow(line: []const u8) bool {
    for (line) |ch| {
        if (ch != '|' and ch != '-' and ch != ':' and ch != ' ') return false;
    }
    for (line) |ch| {
        if (ch == '-') return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Horizontal rules
// ---------------------------------------------------------------------------

fn tryRestyleHorizontalRule(cells: []gui.GuiCell, width: u32, trimmed: []const u8) bool {
    // Must be 3+ of the same char (---, ***, ___) with nothing else.
    if (trimmed.len < 3) return false;
    const ch = trimmed[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (trimmed) |c| {
        if (c != ch and c != ' ') return false;
    }

    const limit = @min(width, @as(u32, @intCast(cells.len)));
    for (cells[0..limit]) |*cell| {
        cell.text[0] = 0xe2; // UTF-8 for ─ (U+2500)
        cell.text[1] = 0x94;
        cell.text[2] = 0x80;
        cell.text_len = 3;
        cell.style.fg = colors.hr_color;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Inline styles (bold, italic, inline code, links)
// ---------------------------------------------------------------------------

fn restyleInline(cells: []gui.GuiCell, width: u32, line: []const u8) void {
    const limit = @min(width, @as(u32, @intCast(cells.len)));

    // Inline code: `text`
    var in_code = false;
    var col: u32 = 0;
    // Map byte offset to cell index (1 byte = 1 cell for ASCII).
    // This is approximate — multi-byte chars may misalign, but for
    // markdown syntax markers (all ASCII) it's accurate.
    var byte_idx: usize = 0;
    while (col < limit and byte_idx < line.len) {
        const t = cells[col].getText();
        if (byte_idx < line.len and line[byte_idx] == '`') {
            if (!in_code) {
                // Opening backtick — hide it.
                cells[col].text_len = 0;
                in_code = true;
            } else {
                // Closing backtick — hide it.
                cells[col].text_len = 0;
                in_code = false;
            }
        } else if (in_code) {
            cells[col].style.bg = colors.code_bg;
            cells[col].style.fg = colors.code_fg;
        }
        byte_idx += if (t.len > 0) t.len else 1;
        col += 1;
    }

    // Bold: **text** — scan for double asterisks.
    // Only process if not inside inline code.
    col = 0;
    byte_idx = 0;
    var in_bold = false;
    while (col < limit and byte_idx + 1 < line.len) {
        if (line[byte_idx] == '*' and line[byte_idx + 1] == '*') {
            if (!in_bold) {
                // Hide opening **.
                if (col < limit) cells[col].text_len = 0;
                if (col + 1 < limit) cells[col + 1].text_len = 0;
                in_bold = true;
                col += 2;
                byte_idx += 2;
                continue;
            } else {
                // Hide closing **.
                if (col < limit) cells[col].text_len = 0;
                if (col + 1 < limit) cells[col + 1].text_len = 0;
                in_bold = false;
                col += 2;
                byte_idx += 2;
                continue;
            }
        }
        if (in_bold) {
            cells[col].style.bold = true;
        }
        const t = cells[col].getText();
        byte_idx += if (t.len > 0) t.len else 1;
        col += 1;
    }

    // Italic: *text* (single asterisk, not preceded by another *).
    col = 0;
    byte_idx = 0;
    var in_italic = false;
    while (col < limit and byte_idx < line.len) {
        if (line[byte_idx] == '*') {
            // Skip if part of ** (bold).
            const next_star = byte_idx + 1 < line.len and line[byte_idx + 1] == '*';
            const prev_star = byte_idx > 0 and line[byte_idx - 1] == '*';
            if (!next_star and !prev_star) {
                cells[col].text_len = 0; // hide marker
                in_italic = !in_italic;
            }
        } else if (in_italic) {
            cells[col].style.italic = true;
        }
        const t = cells[col].getText();
        byte_idx += if (t.len > 0) t.len else 1;
        col += 1;
    }

    // Links: [text](url) — show text underlined, hide []() and url.
    col = 0;
    byte_idx = 0;
    var link_state: enum { none, text, between, url } = .none;
    while (col < limit and byte_idx < line.len) {
        switch (link_state) {
            .none => {
                if (line[byte_idx] == '[') {
                    cells[col].text_len = 0; // hide [
                    link_state = .text;
                }
            },
            .text => {
                if (line[byte_idx] == ']') {
                    cells[col].text_len = 0; // hide ]
                    link_state = .between;
                } else {
                    cells[col].style.fg = colors.link_color;
                    cells[col].style.underline = true;
                }
            },
            .between => {
                if (line[byte_idx] == '(') {
                    cells[col].text_len = 0; // hide (
                    link_state = .url;
                } else {
                    // Not a link, just [text] without (url).
                    link_state = .none;
                }
            },
            .url => {
                if (line[byte_idx] == ')') {
                    cells[col].text_len = 0; // hide )
                    link_state = .none;
                } else {
                    cells[col].text_len = 0; // hide url characters
                }
            },
        }
        const t = cells[col].getText();
        byte_idx += if (t.len > 0) t.len else 1;
        col += 1;
    }
}

// ---------------------------------------------------------------------------
// Emoji shortcodes (:smile: → 😄)
// ---------------------------------------------------------------------------

const EmojiEntry = struct { []const u8, []const u8 };

const emoji_table = [_]EmojiEntry{
    .{ "smile", "\u{1F604}" },
    .{ "laughing", "\u{1F606}" },
    .{ "joy", "\u{1F602}" },
    .{ "heart", "\u{2764}\u{FE0F}" },
    .{ "fire", "\u{1F525}" },
    .{ "thumbsup", "\u{1F44D}" },
    .{ "thumbsdown", "\u{1F44E}" },
    .{ "star", "\u{2B50}" },
    .{ "sparkles", "\u{2728}" },
    .{ "check", "\u{2705}" },
    .{ "x", "\u{274C}" },
    .{ "warning", "\u{26A0}\u{FE0F}" },
    .{ "rocket", "\u{1F680}" },
    .{ "eyes", "\u{1F440}" },
    .{ "tada", "\u{1F389}" },
    .{ "wave", "\u{1F44B}" },
    .{ "clap", "\u{1F44F}" },
    .{ "thinking", "\u{1F914}" },
    .{ "bulb", "\u{1F4A1}" },
    .{ "memo", "\u{1F4DD}" },
    .{ "book", "\u{1F4D6}" },
    .{ "pin", "\u{1F4CC}" },
    .{ "link", "\u{1F517}" },
    .{ "calendar", "\u{1F4C5}" },
    .{ "clock", "\u{1F552}" },
    .{ "gear", "\u{2699}\u{FE0F}" },
    .{ "lock", "\u{1F512}" },
    .{ "key", "\u{1F511}" },
    .{ "bug", "\u{1F41B}" },
    .{ "hammer", "\u{1F528}" },
    .{ "zap", "\u{26A1}" },
    .{ "100", "\u{1F4AF}" },
    .{ "question", "\u{2753}" },
    .{ "exclamation", "\u{2757}" },
    .{ "arrow_right", "\u{27A1}\u{FE0F}" },
    .{ "arrow_left", "\u{2B05}\u{FE0F}" },
    .{ "arrow_up", "\u{2B06}\u{FE0F}" },
    .{ "arrow_down", "\u{2B07}\u{FE0F}" },
    .{ "white_check_mark", "\u{2705}" },
    .{ "heavy_check_mark", "\u{2714}\u{FE0F}" },
    .{ "red_circle", "\u{1F534}" },
    .{ "green_circle", "\u{1F7E2}" },
    .{ "blue_circle", "\u{1F535}" },
    .{ "folder", "\u{1F4C1}" },
    .{ "file", "\u{1F4C4}" },
    .{ "computer", "\u{1F4BB}" },
    .{ "phone", "\u{1F4F1}" },
    .{ "email", "\u{1F4E7}" },
    .{ "mag", "\u{1F50D}" },
    .{ "chart", "\u{1F4C8}" },
    .{ "trophy", "\u{1F3C6}" },
    .{ "party", "\u{1F389}" },
    .{ "gift", "\u{1F381}" },
    .{ "coffee", "\u{2615}" },
    .{ "pizza", "\u{1F355}" },
};

fn lookupEmoji(name: []const u8) ?[]const u8 {
    for (&emoji_table) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

fn restyleEmojiShortcodes(cells: []gui.GuiCell, width: u32, line: []const u8) void {
    const limit = @min(width, @as(u32, @intCast(cells.len)));
    // Scan line for :shortcode: patterns.
    var byte_idx: usize = 0;
    var col: u32 = 0;
    while (byte_idx < line.len and col < limit) {
        if (line[byte_idx] == ':') {
            const start_col = col;
            byte_idx += 1;
            col += 1;
            const name_start = byte_idx;
            while (byte_idx < line.len and col < limit and line[byte_idx] != ':' and line[byte_idx] != ' ') {
                const t = if (col < limit) cells[col].getText() else &[_]u8{};
                byte_idx += if (t.len > 0) t.len else 1;
                col += 1;
            }
            if (byte_idx < line.len and line[byte_idx] == ':') {
                const name = line[name_start..byte_idx];
                if (lookupEmoji(name)) |emoji| {
                    // Replace the first cell with the emoji, hide the rest.
                    const emoji_len = @min(emoji.len, 16);
                    @memcpy(cells[start_col].text[0..emoji_len], emoji[0..emoji_len]);
                    cells[start_col].text_len = @intCast(emoji_len);
                    // Hide cells from start_col+1 through col (inclusive of closing :).
                    var hide = start_col + 1;
                    while (hide <= col and hide < limit) : (hide += 1) {
                        cells[hide].text_len = 0;
                    }
                }
                byte_idx += 1; // skip closing :
                col += 1;
            }
        } else {
            const t = if (col < limit) cells[col].getText() else &[_]u8{};
            byte_idx += if (t.len > 0) t.len else 1;
            col += 1;
        }
    }
}
