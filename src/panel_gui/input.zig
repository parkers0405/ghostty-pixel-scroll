//! Panel Input Converter
//!
//! Converts Ghostty key events to VT escape sequences for the panel's PTY.
//! Unlike the neovim_gui input module (which converts to Neovim's <C-a> notation),
//! this produces standard terminal escape sequences since the panel programs
//! (lazygit, lazydocker) are standard TUI applications running in a PTY.

const std = @import("std");
const input = @import("../input.zig");

/// Convert a Ghostty key event to a VT escape sequence for the panel PTY.
/// Returns a slice into a thread-local buffer, or null if the key shouldn't be sent.
pub fn toVtSequence(event: input.KeyEvent) ?[]const u8 {
    // Only handle press and repeat events
    if (event.action == .release) return null;

    // If we have UTF-8 text and no Ctrl/Alt, send it directly
    if (event.utf8.len > 0 and !event.mods.ctrl and !event.mods.alt) {
        return event.utf8;
    }

    // Ctrl+letter sends control code (0x01-0x1A)
    if (event.mods.ctrl and !event.mods.alt) {
        if (getLetterIndex(event.key)) |idx| {
            const State = struct {
                threadlocal var buf: [1]u8 = undefined;
            };
            State.buf[0] = @as(u8, @intCast(idx)) + 1; // Ctrl+A = 0x01
            return &State.buf;
        }
    }

    // Alt+key sends ESC prefix
    if (event.mods.alt and !event.mods.ctrl) {
        if (event.utf8.len > 0) {
            const State = struct {
                threadlocal var buf: [8]u8 = undefined;
            };
            State.buf[0] = 0x1b; // ESC
            const len = @min(event.utf8.len, 7);
            @memcpy(State.buf[1..][0..len], event.utf8[0..len]);
            return State.buf[0 .. len + 1];
        }
    }

    // Map special keys to their VT sequences
    return mapSpecialKey(event);
}

fn getLetterIndex(key: input.Key) ?u5 {
    return switch (key) {
        .key_a => 0,
        .key_b => 1,
        .key_c => 2,
        .key_d => 3,
        .key_e => 4,
        .key_f => 5,
        .key_g => 6,
        .key_h => 7,
        .key_i => 8,
        .key_j => 9,
        .key_k => 10,
        .key_l => 11,
        .key_m => 12,
        .key_n => 13,
        .key_o => 14,
        .key_p => 15,
        .key_q => 16,
        .key_r => 17,
        .key_s => 18,
        .key_t => 19,
        .key_u => 20,
        .key_v => 21,
        .key_w => 22,
        .key_x => 23,
        .key_y => 24,
        .key_z => 25,
        else => null,
    };
}

fn mapSpecialKey(event: input.KeyEvent) ?[]const u8 {
    // Shift modifier for cursor keys uses CSI 1;2X format
    const shift = event.mods.shift;
    const ctrl = event.mods.ctrl;

    // Base sequences (no modifiers)
    return switch (event.key) {
        .enter => "\r",
        .tab => if (shift) "\x1b[Z" else "\t",
        .backspace => "\x7f",
        .escape => "\x1b",
        .space => if (ctrl) &[_]u8{0} else " ",

        // Arrow keys
        .arrow_up => if (shift) "\x1b[1;2A" else if (ctrl) "\x1b[1;5A" else "\x1b[A",
        .arrow_down => if (shift) "\x1b[1;2B" else if (ctrl) "\x1b[1;5B" else "\x1b[B",
        .arrow_right => if (shift) "\x1b[1;2C" else if (ctrl) "\x1b[1;5C" else "\x1b[C",
        .arrow_left => if (shift) "\x1b[1;2D" else if (ctrl) "\x1b[1;5D" else "\x1b[D",

        // Navigation
        .home => "\x1b[H",
        .end => "\x1b[F",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
        .insert => "\x1b[2~",
        .delete => "\x1b[3~",

        // Function keys
        .f1 => "\x1bOP",
        .f2 => "\x1bOQ",
        .f3 => "\x1bOR",
        .f4 => "\x1bOS",
        .f5 => "\x1b[15~",
        .f6 => "\x1b[17~",
        .f7 => "\x1b[18~",
        .f8 => "\x1b[19~",
        .f9 => "\x1b[20~",
        .f10 => "\x1b[21~",
        .f11 => "\x1b[23~",
        .f12 => "\x1b[24~",

        else => null,
    };
}

/// Convert a mouse scroll to the panel's scroll input.
/// Returns the VT sequence for scroll up/down.
pub fn scrollSequence(direction: enum { up, down }, count: u32) ?[]const u8 {
    _ = count;
    return switch (direction) {
        .up => "\x1b[A", // Many TUIs use arrow keys for scroll
        .down => "\x1b[B",
    };
}

test "basic VT sequence conversion" {
    const testing = std.testing;

    // Enter key
    {
        const event = input.KeyEvent{
            .key = .enter,
        };
        try testing.expectEqualStrings("\r", toVtSequence(event).?);
    }

    // Escape
    {
        const event = input.KeyEvent{
            .key = .escape,
        };
        try testing.expectEqualStrings("\x1b", toVtSequence(event).?);
    }

    // Arrow up
    {
        const event = input.KeyEvent{
            .key = .arrow_up,
        };
        try testing.expectEqualStrings("\x1b[A", toVtSequence(event).?);
    }
}
