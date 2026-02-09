//! Panel Menu - Interactive menu with fixed-area panes and independent scrolling
//!
//! Renders a navigable menu into the panel's cell grid. The panel is divided
//! into three fixed regions (Favorites, Recent Commands, Files), each with
//! its own pinned header, scroll state, and selection. Vim-style keyboard
//! navigation (j/k/h/l/enter/esc) moves within the active section; Tab or
//! reaching a section boundary moves focus to the next section.
//!
//! The menu writes directly to RenderedPanel cells -- no PTY needed.
//! The Files section provides a tree-view file explorer (like nvim-tree)
//! rooted at the terminal's working directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const RenderedPanel = @import("rendered_panel.zig").RenderedPanel;
const Cell = @import("rendered_panel.zig").Cell;
const Animation = @import("animation.zig");
const CriticallyDampedSpring = Animation.CriticallyDampedSpring;

const log = std.log.scoped(.panel_menu);

// ── Nerd Font Icons ──────────────────────────────────────────────────────
// These are standard Nerd Font codepoints that Ghostty already has embedded
// via the Symbols Nerd Font. They render as colored glyphs in the terminal.

/// Icon codepoints (UTF-8 encoded as comptime string literals)
pub const icons = struct {
    // Section headers
    pub const favorites = "\u{f005}"; // nf-fa-star
    pub const recent = "\u{f017}"; // nf-fa-clock_o
    pub const files = "\u{f07c}"; // nf-fa-folder_open

    // Action icons
    pub const star_filled = "\u{f005}"; // nf-fa-star (filled)
    pub const star_empty = "\u{f006}"; // nf-fa-star_o (outline)
    pub const chevron_right = "\u{eab6}"; // nf-cod-chevron_right
    pub const chevron_down = "\u{eab4}"; // nf-cod-chevron_down
    pub const command = "\u{ebc4}"; // nf-cod-terminal_cmd

    // File tree icons
    pub const folder_closed = "\u{f07b}"; // nf-fa-folder
    pub const folder_open = "\u{f07c}"; // nf-fa-folder_open
    pub const file_default = "\u{f15b}"; // nf-fa-file
    pub const file_text = "\u{f15c}"; // nf-fa-file_text
    pub const file_code = "\u{f1c9}"; // nf-fa-file_code_o
    pub const file_image = "\u{f1c5}"; // nf-fa-file_image_o
    pub const file_git = "\u{f1d3}"; // nf-fa-git
    pub const tree_branch = "\u{e621}"; // nf-seti-folder (tree branch connector)
    pub const dot_git = "\u{e5fb}"; // nf-custom-folder_git
    pub const parent_dir = "\u{f112}"; // nf-fa-reply (back/up arrow)
};

// ── Theme Colors ─────────────────────────────────────────────────────────
// Derived at runtime from the terminal's configured theme palette.

pub const Theme = struct {
    bg: u32,
    bg_surface: u32,
    bg_selected: u32,
    bg_hover: u32,

    fg: u32,
    fg_dim: u32,
    fg_muted: u32,
    fg_faint: u32,

    accent: u32, // ANSI blue (4/12)
    green: u32, // ANSI green (2/10)
    yellow: u32, // ANSI yellow (3/11)
    red: u32, // ANSI red (1/9)
    mauve: u32, // ANSI magenta (5/13)
    peach: u32, // ANSI bright red (9)
    teal: u32, // ANSI cyan (6/14)
    pink: u32, // ANSI bright magenta (13)

    border: u32,
    separator: u32,
    section_active_bg: u32,
    section_inactive_bg: u32,

    /// Build a theme from terminal bg, fg, and the 16-color ANSI palette.
    /// `palette` is indexed 0-15 as u32 RGB values.
    pub fn fromPalette(bg_rgb: u32, fg_rgb: u32, palette: [16]u32) Theme {
        return .{
            .bg = bg_rgb,
            .bg_surface = blend(bg_rgb, fg_rgb, 10),
            .bg_selected = blend(bg_rgb, fg_rgb, 18),
            .bg_hover = blend(bg_rgb, fg_rgb, 25),

            .fg = fg_rgb,
            .fg_dim = blend(fg_rgb, bg_rgb, 20),
            .fg_muted = blend(fg_rgb, bg_rgb, 40),
            .fg_faint = blend(fg_rgb, bg_rgb, 55),

            .accent = palette[12], // bright blue
            .green = palette[10], // bright green
            .yellow = palette[11], // bright yellow
            .red = palette[9], // bright red
            .mauve = palette[13], // bright magenta
            .peach = palette[1], // red
            .teal = palette[14], // bright cyan
            .pink = palette[5], // magenta

            .border = blend(bg_rgb, fg_rgb, 18),
            .separator = blend(bg_rgb, fg_rgb, 10),
            .section_active_bg = blend(bg_rgb, fg_rgb, 10),
            .section_inactive_bg = bg_rgb,
        };
    }

    /// Fallback theme when no terminal colors are available.
    pub fn default() Theme {
        return fromPalette(
            0x1e1e2e, // Catppuccin Mocha Base
            0xcdd6f4, // Catppuccin Mocha Text
            .{
                0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, // black, red, green, yellow
                0x89b4fa, 0xcba6f7, 0x94e2d5, 0xbac2de, // blue, magenta, cyan, white
                0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, // bright: black, red, green, yellow
                0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xcdd6f4, // bright: blue, magenta, cyan, white
            },
        );
    }

    /// Blend color `a` toward `b` by `pct` percent (0-100).
    pub fn blend(a: u32, b: u32, pct: u8) u32 {
        const ar: u32 = (a >> 16) & 0xff;
        const ag: u32 = (a >> 8) & 0xff;
        const ab: u32 = a & 0xff;
        const br: u32 = (b >> 16) & 0xff;
        const bg: u32 = (b >> 8) & 0xff;
        const bb: u32 = b & 0xff;
        const p: u32 = pct;
        const rr = (ar * (100 - p) + br * p) / 100;
        const rg = (ag * (100 - p) + bg * p) / 100;
        const rb = (ab * (100 - p) + bb * p) / 100;
        return (rr << 16) | (rg << 8) | rb;
    }
};

// ── Menu Item Types ──────────────────────────────────────────────────────

pub const ItemKind = enum {
    /// A favorited command
    favorite_command,
    /// A recent command from history
    recent_command,
    /// A file or directory entry in the tree explorer
    file_entry,
};

/// Git status for a file in the working tree
pub const GitStatus = enum {
    none,
    modified, // M (modified in worktree or index)
    added, // A (new file staged)
    untracked, // ? (untracked)
    deleted, // D (deleted)
    renamed, // R (renamed)
    conflicted, // U (unmerged/conflict)
};

pub const MenuItem = struct {
    kind: ItemKind,

    /// Display label (e.g. "src/", "main.zig", "docker compose up")
    label: []const u8 = "",

    /// Nerd Font icon (UTF-8 encoded codepoint string)
    icon: []const u8 = "",

    /// Icon color (RGB)
    icon_color: u32 = 0xcdd6f4,

    /// For commands: the full command string
    command: []const u8 = "",

    /// Whether this item is favorited (shows star)
    favorited: bool = false,

    /// For file_entry: is this a directory?
    is_dir: bool = false,

    /// For file_entry: is this directory expanded in the tree?
    expanded: bool = false,

    /// For file_entry: nesting depth (0 = root level)
    depth: u16 = 0,

    /// For file_entry: full path (relative to tree root)
    path: []const u8 = "",

    /// Git status of this file/directory
    git_status: GitStatus = .none,
};

// ── Section IDs ──────────────────────────────────────────────────────────

pub const Section = enum(u2) {
    favorites = 0,
    recent = 1,
    files = 2,
};

/// Purpose of the inline text input box
pub const InputPurpose = enum {
    add_favorite,
    edit_favorite,
};

// ── Per-Section State ────────────────────────────────────────────────────

const SectionState = struct {
    /// Items belonging to this section
    items: std.ArrayList(MenuItem) = .{},

    /// Currently selected item index within this section
    selected: usize = 0,

    /// Scroll target (integer row offset, drives spring)
    scroll_target: f32 = 0,
    /// Spring for smooth scrolling
    scroll_spring: CriticallyDampedSpring = .{},
    /// Current smooth scroll offset (fractional rows)
    scroll_offset: f32 = 0,

    /// Number of visible content rows (set during render, excludes header)
    visible_rows: u32 = 0,

    /// Whether this section has items that need re-render
    dirty: bool = true,

    /// Hint text to show when empty
    empty_hint: []const u8 = "",

    fn animateScroll(self: *SectionState, dt: f32) bool {
        const animating = self.scroll_spring.update(dt, 0.15);
        self.scroll_offset = self.scroll_target + self.scroll_spring.position;
        if (animating) self.dirty = true;
        return animating;
    }

    fn updateScroll(self: *SectionState) void {
        const sel_f: f32 = @floatFromInt(self.selected);
        const visible: f32 = @floatFromInt(self.visible_rows);
        // If visible_rows hasn't been computed yet, use a safe default
        const eff_visible: f32 = if (visible <= 0) 5.0 else visible;

        const item_count: f32 = @floatFromInt(self.items.items.len);
        const max_scroll: f32 = @max(0.0, item_count - eff_visible);

        // Ensure selected item is visible within the scroll window.
        // Use padding=0 for small sections to avoid overshooting.
        const padding: f32 = if (eff_visible > 3) 1.0 else 0.0;

        var new_target = self.scroll_target;

        if (sel_f < new_target + padding) {
            new_target = @max(0.0, sel_f - padding);
        } else if (sel_f >= new_target + eff_visible - padding - 1.0) {
            new_target = sel_f - eff_visible + padding + 1.0;
        }

        // Hard-clamp scroll target to valid range
        new_target = @max(0.0, @min(new_target, max_scroll));

        if (new_target != self.scroll_target) {
            // Use spring for smooth animation: spring starts displaced
            // and animates toward 0, making scroll_offset converge on new_target.
            const delta = self.scroll_target - new_target;
            self.scroll_spring.position += delta;
            self.scroll_target = new_target;
            // IMPORTANT: Also snap scroll_offset immediately so the
            // selected item is visible on the very next render frame,
            // before the spring animation has a chance to tick.
            self.scroll_offset = new_target;
        }
    }
};

// ── Menu State ───────────────────────────────────────────────────────────

pub const Menu = struct {
    const Self = @This();

    alloc: Allocator,

    /// Theme colors derived from terminal palette
    theme: Theme = Theme.default(),

    /// Per-section state
    sections: [3]SectionState = .{
        .{ .empty_hint = "  Press 'f' on a command to favorite it" },
        .{ .empty_hint = "  No recent commands yet" },
        .{ .empty_hint = "  No working directory" },
    },

    /// Which section currently has focus
    active_section: Section = .favorites,

    /// Whether the cursor is on the section header (true) or on items (false)
    focused_on_header: bool = true,

    /// When set, this section is expanded to fill the full panel
    expanded_section: ?Section = null,

    /// Whether the menu content has changed and needs re-render
    dirty: bool = true,

    /// ── Search / filter mode ────────────────────────────────────────
    search_active: bool = false,
    search_buf: [128]u8 = [_]u8{0} ** 128,
    search_len: u8 = 0,
    /// Filtered view: indices into the active section's items list
    filtered_indices: std.ArrayList(usize) = .{},

    /// ── Text input mode (add/edit favorites) ─────────────────────────
    input_active: bool = false,
    input_buf: [256]u8 = [_]u8{0} ** 256,
    input_len: u16 = 0,
    input_purpose: InputPurpose = .add_favorite,
    /// Index of the favorite being edited (for .edit_favorite)
    input_edit_idx: usize = 0,

    /// Favorite commands (persisted)
    favorites: std.ArrayList([]const u8),

    /// Recent commands
    recent_commands: std.ArrayList([]const u8),

    /// Action requested by the menu (checked by PanelGui after key handling)
    pending_action: ?Action = null,

    /// File explorer state
    file_tree_root: []const u8 = "",
    /// Expanded directory paths (tracks which dirs are open in the tree)
    expanded_dirs: std.ArrayList([]const u8),
    /// Cached directory entries: path -> list of DirEntry
    dir_cache: std.StringHashMap([]DirEntry),
    /// Git status cache: relative path -> GitStatus (populated per buildFilesSection)
    git_statuses: std.StringHashMap(GitStatus),
    /// Whether current file_tree_root is inside a git repo
    git_repo_root: []const u8 = "",

    /// Total panel rows (set on render)
    total_rows: u32 = 0,
    /// Total panel cols (set on render)
    total_cols: u32 = 0,

    pub const DirEntry = struct {
        name: []const u8,
        is_dir: bool,
    };

    pub const OpenFileInfo = struct {
        path: []const u8,
        /// Parent directory of the file (for nvim-gui cwd)
        dir: []const u8,
    };

    pub const Action = union(enum) {
        /// Run a command in the terminal
        run_command: []const u8,
        /// Toggle favorite on the selected item
        toggle_favorite,
        /// Close the panel
        close,
        /// Toggle expand/collapse of a directory in the file tree
        toggle_dir: []const u8,
        /// Open a file in nvim-gui (includes parent dir for cwd)
        open_file: OpenFileInfo,
    };

    pub fn init(alloc: Allocator) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .favorites = .{},
            .recent_commands = .{},
            .expanded_dirs = .{},
            .filtered_indices = .{},
            .dir_cache = std.StringHashMap([]DirEntry).init(alloc),
            .git_statuses = std.StringHashMap(GitStatus).init(alloc),
        };

        // Set initial tree root to cwd
        self.file_tree_root = getCwdAlloc(alloc);

        // Load persisted favorites
        self.loadFavorites();

        // Load shell history
        self.loadShellHistory();

        // Populate menu sections
        try self.buildAllSections();

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.favorites.items) |f| self.alloc.free(f);
        self.favorites.deinit(self.alloc);
        for (self.recent_commands.items) |c| self.alloc.free(c);
        self.recent_commands.deinit(self.alloc);
        for (self.expanded_dirs.items) |d| self.alloc.free(d);
        self.expanded_dirs.deinit(self.alloc);
        self.filtered_indices.deinit(self.alloc);
        self.freeDirCache();
        self.dir_cache.deinit();
        self.freeGitStatuses();
        self.git_statuses.deinit();
        if (self.git_repo_root.len > 0) self.alloc.free(self.git_repo_root);
        if (self.file_tree_root.len > 0) self.alloc.free(self.file_tree_root);
        self.freeAllSectionItems();
        self.alloc.destroy(self);
    }

    fn freeAllSectionItems(self: *Self) void {
        // Free file_entry paths in the files section
        for (self.sections[@intFromEnum(Section.files)].items.items) |item| {
            if (item.kind == .file_entry and item.path.len > 0) {
                self.alloc.free(item.path);
            }
        }
        for (&self.sections) |*sec| {
            sec.items.deinit(self.alloc);
        }
    }

    fn freeDirCache(self: *Self) void {
        var it = self.dir_cache.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*) |de| {
                self.alloc.free(de.name);
            }
            self.alloc.free(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.dir_cache.clearRetainingCapacity();
    }

    fn getCwdAlloc(alloc: Allocator) []const u8 {
        var buf: [4096]u8 = undefined;
        const cwd = std.posix.getcwd(&buf) catch return "";
        return alloc.dupe(u8, cwd) catch "";
    }

    // ── Favorites Persistence ───────────────────────────────────────────

    const favorites_filename = "panel-favorites";

    /// Get the path to the favorites file: ~/.config/ghostty/panel-favorites
    fn getFavoritesPath(buf: []u8) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/.config/ghostty/{s}", .{ home, favorites_filename }) catch null;
    }

    /// Load favorites from disk into self.favorites
    fn loadFavorites(self: *Self) void {
        var path_buf: [4096]u8 = undefined;
        const path = getFavoritesPath(&path_buf) orelse return;

        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();

        var buf: [32768]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return;
        const content = buf[0..bytes_read];

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Deduplicate
            var exists = false;
            for (self.favorites.items) |f| {
                if (std.mem.eql(u8, f, trimmed)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                const duped = self.alloc.dupe(u8, trimmed) catch continue;
                self.favorites.append(self.alloc, duped) catch {
                    self.alloc.free(duped);
                    continue;
                };
            }
        }
    }

    /// Save current favorites to disk
    fn saveFavorites(self: *Self) void {
        var path_buf: [4096]u8 = undefined;
        const path = getFavoritesPath(&path_buf) orelse return;

        // Ensure the directory exists (~/.config/ghostty/)
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch return;
        }

        const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
        defer file.close();

        for (self.favorites.items) |fav| {
            file.writeAll(fav) catch return;
            file.writeAll("\n") catch return;
        }
    }

    /// Load recent commands from shell history files.
    /// Supports zsh extended history (`: timestamp:0;command`) and
    /// plain formats (bash/zsh basic). Reads the last N unique commands.
    fn loadShellHistory(self: *Self) void {
        // Try zsh history first, then bash
        const home = std.posix.getenv("HOME") orelse return;
        const history_paths = [_][]const u8{
            "/.zsh_history",
            "/.bash_history",
        };

        for (history_paths) |suffix| {
            var path_buf: [4096]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, suffix }) catch continue;

            if (self.loadHistoryFile(path)) return;
        }
    }

    fn loadHistoryFile(self: *Self, path: []const u8) bool {
        const file = std.fs.openFileAbsolute(path, .{}) catch return false;
        defer file.close();

        // Read the last 128KB of the file
        const stat = file.stat() catch return false;
        const file_size = stat.size;
        const read_size: u64 = @min(file_size, 128 * 1024);
        const offset: u64 = file_size - read_size;

        if (offset > 0) {
            file.seekTo(offset) catch return false;
        }

        var read_buf: [128 * 1024]u8 = undefined;
        const bytes_read = file.readAll(&read_buf) catch return false;
        if (bytes_read == 0) return false;

        const content = read_buf[0..bytes_read];

        // Parse lines in reverse to get most recent first
        var commands: [200][]const u8 = undefined;
        var cmd_count: usize = 0;
        const max_commands = 200;

        // Split into lines and process from the end
        var line_it = std.mem.splitBackwardsScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            if (cmd_count >= max_commands) break;
            if (line.len == 0) continue;

            const cmd = parseHistoryLine(line);
            if (cmd.len == 0) continue;
            // Skip very short commands (likely just 'ls', 'cd', etc.)
            // Actually, keep them - they're useful in the menu
            // Skip if duplicate of something we already have
            var is_dup = false;
            for (commands[0..cmd_count]) |existing| {
                if (std.mem.eql(u8, existing, cmd)) {
                    is_dup = true;
                    break;
                }
            }
            if (is_dup) continue;

            commands[cmd_count] = cmd;
            cmd_count += 1;
        }

        // Add to recent_commands in chronological order (reverse of what we collected)
        var i: usize = cmd_count;
        while (i > 0) {
            i -= 1;
            const duped = self.alloc.dupe(u8, commands[i]) catch continue;
            self.recent_commands.append(self.alloc, duped) catch {
                self.alloc.free(duped);
                continue;
            };
        }

        return cmd_count > 0;
    }

    /// Parse a single history line. Handles:
    /// - zsh extended format: `: timestamp:0;command`
    /// - plain format: `command`
    fn parseHistoryLine(line: []const u8) []const u8 {
        // zsh extended history format: `: 1234567890:0;actual command`
        if (line.len > 2 and line[0] == ':' and line[1] == ' ') {
            // Find the semicolon that separates metadata from command
            if (std.mem.indexOfScalar(u8, line[2..], ';')) |semi_pos| {
                const cmd_start = 2 + semi_pos + 1;
                if (cmd_start < line.len) {
                    const cmd = std.mem.trim(u8, line[cmd_start..], " \t\r");
                    return cmd;
                }
            }
            return "";
        }

        // Plain format: just the command
        return std.mem.trim(u8, line, " \t\r");
    }

    // ── Section Building ─────────────────────────────────────────────────

    /// Build/rebuild all section item lists from current state
    pub fn buildAllSections(self: *Self) !void {
        try self.buildFavoritesSection();
        try self.buildRecentSection();
        try self.buildFilesSection();
        self.dirty = true;
    }

    fn buildFavoritesSection(self: *Self) !void {
        var sec = &self.sections[@intFromEnum(Section.favorites)];
        sec.items.clearRetainingCapacity();

        for (self.favorites.items) |fav| {
            try sec.items.append(self.alloc, .{
                .kind = .favorite_command,
                .label = fav,
                .icon = icons.star_filled,
                .icon_color = self.theme.yellow,
                .command = fav,
                .favorited = true,
            });
        }

        sec.selected = @min(sec.selected, if (sec.items.items.len > 0) sec.items.items.len - 1 else 0);
        sec.dirty = true;
        self.dirty = true;
    }

    fn buildRecentSection(self: *Self) !void {
        var sec = &self.sections[@intFromEnum(Section.recent)];
        sec.items.clearRetainingCapacity();

        // Show most recent first, excluding favorited commands
        // (favorites have their own section)
        var i: usize = self.recent_commands.items.len;
        while (i > 0) {
            i -= 1;
            const cmd = self.recent_commands.items[i];
            if (self.isFavorited(cmd)) continue; // skip — shown in Favorites
            try sec.items.append(self.alloc, .{
                .kind = .recent_command,
                .label = cmd,
                .icon = icons.command,
                .icon_color = self.theme.fg_dim,
                .command = cmd,
                .favorited = false,
            });
        }

        sec.selected = @min(sec.selected, if (sec.items.items.len > 0) sec.items.items.len - 1 else 0);
        sec.dirty = true;
        self.dirty = true;
    }

    fn buildFilesSection(self: *Self) !void {
        var sec = &self.sections[@intFromEnum(Section.files)];

        // Free old file_entry paths
        for (sec.items.items) |item| {
            if (item.kind == .file_entry and item.path.len > 0) {
                self.alloc.free(item.path);
            }
        }
        sec.items.clearRetainingCapacity();

        // Refresh git status
        self.freeGitStatuses();
        self.loadGitStatus();

        if (self.file_tree_root.len > 0) {
            self.buildFileTree(sec, self.file_tree_root, 0) catch |err| {
                log.warn("failed to read directory for file tree: {}", .{err});
            };
        }

        sec.selected = @min(sec.selected, if (sec.items.items.len > 0) sec.items.items.len - 1 else 0);
        sec.dirty = true;
        self.dirty = true;
    }

    /// Recursively build file tree items for a directory
    fn buildFileTree(self: *Self, sec: *SectionState, dir_path: []const u8, depth: u16) !void {
        const entries = try self.readDir(dir_path);

        for (entries) |entry| {
            const is_expanded = self.isDirExpanded(dir_path, entry.name);
            const icon = if (entry.is_dir)
                (if (is_expanded) icons.folder_open else icons.folder_closed)
            else
                fileIcon(entry.name);

            const icon_color: u32 = if (entry.is_dir) self.theme.accent else self.fileColor(entry.name);

            // Build the full path for this entry
            const full_path = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir_path, entry.name });
            defer self.alloc.free(full_path);

            // Look up git status for this path
            const git_st = self.git_statuses.get(full_path) orelse .none;

            try sec.items.append(self.alloc, .{
                .kind = .file_entry,
                .label = entry.name,
                .icon = icon,
                .icon_color = icon_color,
                .is_dir = entry.is_dir,
                .expanded = if (entry.is_dir) is_expanded else false,
                .depth = depth,
                .path = try self.alloc.dupe(u8, full_path),
                .git_status = git_st,
            });

            // If directory is expanded, recurse (limit depth to 5)
            if (entry.is_dir and is_expanded and depth < 5) {
                self.buildFileTree(sec, full_path, depth + 1) catch {};
            }
        }
    }

    /// Read directory entries (cached)
    fn readDir(self: *Self, dir_path: []const u8) ![]DirEntry {
        if (self.dir_cache.get(dir_path)) |cached| {
            return cached;
        }

        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
            log.warn("failed to open dir '{s}': {}", .{ dir_path, err });
            return &[_]DirEntry{};
        };
        defer dir.close();

        var entries_list: std.ArrayList(DirEntry) = .{};
        defer entries_list.deinit(self.alloc);

        var it = dir.iterate();
        var count: usize = 0;
        while (it.next() catch null) |entry| {
            // Skip .git (too large), build artifacts, and caches
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (std.mem.eql(u8, entry.name, "node_modules")) continue;
            if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
            if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
            if (std.mem.eql(u8, entry.name, "zig-out")) continue;
            if (std.mem.eql(u8, entry.name, "__pycache__")) continue;
            if (std.mem.eql(u8, entry.name, ".DS_Store")) continue;

            const is_dir = entry.kind == .directory;

            try entries_list.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, entry.name),
                .is_dir = is_dir,
            });

            count += 1;
            if (count >= 200) break;
        }

        const items = try entries_list.toOwnedSlice(self.alloc);
        std.mem.sort(DirEntry, items, {}, struct {
            fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
                if (a.is_dir and !b.is_dir) return true;
                if (!a.is_dir and b.is_dir) return false;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lessThan);

        const key = try self.alloc.dupe(u8, dir_path);
        try self.dir_cache.put(key, items);

        return items;
    }

    fn isDirExpanded(self: *const Self, parent: []const u8, name: []const u8) bool {
        for (self.expanded_dirs.items) |expanded| {
            if (expanded.len == parent.len + 1 + name.len) {
                if (std.mem.startsWith(u8, expanded, parent) and
                    expanded[parent.len] == '/' and
                    std.mem.eql(u8, expanded[parent.len + 1 ..], name))
                {
                    return true;
                }
            }
        }
        return false;
    }

    fn toggleDirExpand(self: *Self, full_path: []const u8) !void {
        for (self.expanded_dirs.items, 0..) |expanded, idx| {
            if (std.mem.eql(u8, expanded, full_path)) {
                self.alloc.free(self.expanded_dirs.items[idx]);
                _ = self.expanded_dirs.orderedRemove(idx);
                self.collapseChildren(full_path);
                self.invalidateDirCache(full_path);
                try self.buildFilesSection();
                return;
            }
        }
        try self.expanded_dirs.append(self.alloc, try self.alloc.dupe(u8, full_path));
        self.invalidateDirCache(full_path);
        try self.buildFilesSection();
    }

    fn collapseChildren(self: *Self, parent_path: []const u8) void {
        var i: usize = 0;
        while (i < self.expanded_dirs.items.len) {
            const p = self.expanded_dirs.items[i];
            if (p.len > parent_path.len and
                std.mem.startsWith(u8, p, parent_path) and
                p[parent_path.len] == '/')
            {
                self.alloc.free(p);
                _ = self.expanded_dirs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn invalidateDirCache(self: *Self, dir_path: []const u8) void {
        if (self.dir_cache.fetchRemove(dir_path)) |kv| {
            for (kv.value) |de| {
                self.alloc.free(de.name);
            }
            self.alloc.free(kv.value);
            self.alloc.free(kv.key);
        }
    }

    pub fn refreshFileTree(self: *Self) !void {
        self.freeDirCache();
        self.freeGitStatuses();
        try self.buildFilesSection();
    }

    fn freeGitStatuses(self: *Self) void {
        var it = self.git_statuses.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.git_statuses.clearRetainingCapacity();
    }

    /// Run `git status --porcelain` in the file tree root and populate git_statuses map.
    fn loadGitStatus(self: *Self) void {
        if (self.file_tree_root.len == 0) return;

        // Run git status --porcelain=v1 -uall
        const argv = [_][]const u8{
            "git", "-C", self.file_tree_root, "status", "--porcelain=v1", "-uall",
        };
        var child = std.process.Child.init(&argv, self.alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return;

        const stdout = child.stdout orelse {
            _ = child.wait() catch {};
            return;
        };

        // Read up to 64KB of output
        const output = stdout.readToEndAlloc(self.alloc, 64 * 1024) catch {
            _ = child.wait() catch {};
            return;
        };
        defer self.alloc.free(output);

        _ = child.wait() catch {};

        // Parse porcelain output: "XY path\n"
        // X = index status, Y = worktree status
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (line.len < 4) continue; // "XY " + at least 1 char

            const xy_x = line[0];
            const xy_y = line[1];
            // line[2] == ' '
            var file_path = line[3..];

            // Handle renames: "R  old -> new"
            if (std.mem.indexOf(u8, file_path, " -> ")) |arrow| {
                file_path = file_path[arrow + 4 ..];
            }

            const status: GitStatus = blk: {
                if (xy_x == '?' and xy_y == '?') break :blk .untracked;
                if (xy_x == 'U' or xy_y == 'U' or (xy_x == 'A' and xy_y == 'A') or (xy_x == 'D' and xy_y == 'D')) break :blk .conflicted;
                if (xy_x == 'A' or xy_y == 'A') break :blk .added;
                if (xy_x == 'D' or xy_y == 'D') break :blk .deleted;
                if (xy_x == 'R' or xy_y == 'R') break :blk .renamed;
                if (xy_x == 'M' or xy_y == 'M') break :blk .modified;
                break :blk .modified; // catch-all for C, etc.
            };

            // Build full path from tree root
            const full_path = std.fs.path.resolve(self.alloc, &.{ self.file_tree_root, file_path }) catch continue;

            // Put in map (key is owned)
            self.git_statuses.put(full_path, status) catch {
                self.alloc.free(full_path);
                continue;
            };

            // Also mark parent directories as modified (propagate up)
            self.propagateGitStatusToParents(full_path, status);
        }
    }

    /// Mark parent directories with git status (dirs show as modified if any child is modified)
    fn propagateGitStatusToParents(self: *Self, file_path: []const u8, status: GitStatus) void {
        var dir = std.fs.path.dirname(file_path);
        while (dir) |d| {
            if (d.len < self.file_tree_root.len) break;
            if (!self.git_statuses.contains(d)) {
                const dir_key = self.alloc.dupe(u8, d) catch return;
                self.git_statuses.put(dir_key, status) catch {
                    self.alloc.free(dir_key);
                    return;
                };
            }
            dir = std.fs.path.dirname(d);
        }
    }

    fn fileIcon(name: []const u8) []const u8 {
        const ext = std.fs.path.extension(name);
        if (ext.len == 0) return icons.file_default;

        if (std.mem.eql(u8, ext, ".zig") or
            std.mem.eql(u8, ext, ".rs") or
            std.mem.eql(u8, ext, ".go") or
            std.mem.eql(u8, ext, ".c") or
            std.mem.eql(u8, ext, ".h") or
            std.mem.eql(u8, ext, ".cpp") or
            std.mem.eql(u8, ext, ".py") or
            std.mem.eql(u8, ext, ".js") or
            std.mem.eql(u8, ext, ".ts") or
            std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".jsx") or
            std.mem.eql(u8, ext, ".lua") or
            std.mem.eql(u8, ext, ".sh") or
            std.mem.eql(u8, ext, ".nix") or
            std.mem.eql(u8, ext, ".toml") or
            std.mem.eql(u8, ext, ".json") or
            std.mem.eql(u8, ext, ".yaml") or
            std.mem.eql(u8, ext, ".yml") or
            std.mem.eql(u8, ext, ".html") or
            std.mem.eql(u8, ext, ".css") or
            std.mem.eql(u8, ext, ".glsl") or
            std.mem.eql(u8, ext, ".metal"))
            return icons.file_code;

        if (std.mem.eql(u8, ext, ".png") or
            std.mem.eql(u8, ext, ".jpg") or
            std.mem.eql(u8, ext, ".svg") or
            std.mem.eql(u8, ext, ".ico") or
            std.mem.eql(u8, ext, ".gif") or
            std.mem.eql(u8, ext, ".webp"))
            return icons.file_image;

        if (std.mem.eql(u8, ext, ".md") or
            std.mem.eql(u8, ext, ".txt") or
            std.mem.eql(u8, ext, ".log") or
            std.mem.eql(u8, ext, ".csv"))
            return icons.file_text;

        return icons.file_default;
    }

    fn fileColor(self: *const Self, name: []const u8) u32 {
        const t = &self.theme;
        const ext = std.fs.path.extension(name);
        if (ext.len == 0) return t.fg_dim;

        if (std.mem.eql(u8, ext, ".zig")) return t.peach;
        if (std.mem.eql(u8, ext, ".rs")) return t.peach;
        if (std.mem.eql(u8, ext, ".go")) return t.teal;
        if (std.mem.eql(u8, ext, ".py")) return t.yellow;
        if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".ts") or
            std.mem.eql(u8, ext, ".tsx") or std.mem.eql(u8, ext, ".jsx"))
            return t.yellow;
        if (std.mem.eql(u8, ext, ".lua")) return t.accent;
        if (std.mem.eql(u8, ext, ".nix")) return t.accent;
        if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or
            std.mem.eql(u8, ext, ".cpp"))
            return t.accent;
        if (std.mem.eql(u8, ext, ".sh")) return t.green;
        if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".txt"))
            return t.fg_dim;
        if (std.mem.eql(u8, ext, ".toml") or std.mem.eql(u8, ext, ".json") or
            std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml"))
            return t.teal;
        if (std.mem.eql(u8, ext, ".glsl") or std.mem.eql(u8, ext, ".metal"))
            return t.mauve;

        return t.fg_dim;
    }

    fn isFavorited(self: *const Self, cmd: []const u8) bool {
        for (self.favorites.items) |f| {
            if (std.mem.eql(u8, f, cmd)) return true;
        }
        return false;
    }

    /// Add a command to recent history
    pub fn addRecentCommand(self: *Self, cmd: []const u8) !void {
        // Don't add duplicates (remove old occurrence first)
        var i: usize = 0;
        while (i < self.recent_commands.items.len) {
            if (std.mem.eql(u8, self.recent_commands.items[i], cmd)) {
                self.alloc.free(self.recent_commands.items[i]);
                _ = self.recent_commands.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        while (self.recent_commands.items.len >= 100) {
            self.alloc.free(self.recent_commands.items[0]);
            _ = self.recent_commands.orderedRemove(0);
        }

        try self.recent_commands.append(self.alloc, try self.alloc.dupe(u8, cmd));
        try self.buildRecentSection();
    }

    /// Toggle favorite on the currently selected item
    pub fn toggleFavorite(self: *Self) !void {
        const sec = &self.sections[@intFromEnum(self.active_section)];
        if (sec.items.items.len == 0) return;
        if (sec.selected >= sec.items.items.len) return;
        const item = &sec.items.items[sec.selected];

        const cmd = if (item.command.len > 0) item.command else "";
        if (cmd.len == 0) return;

        var found: ?usize = null;
        for (self.favorites.items, 0..) |f, idx| {
            if (std.mem.eql(u8, f, cmd)) {
                found = idx;
                break;
            }
        }

        if (found) |idx| {
            self.alloc.free(self.favorites.items[idx]);
            _ = self.favorites.orderedRemove(idx);
        } else {
            try self.favorites.append(self.alloc, try self.alloc.dupe(u8, cmd));
        }

        try self.buildFavoritesSection();
        // Also refresh recent section to update star indicators
        try self.buildRecentSection();

        // Persist to disk
        self.saveFavorites();
    }

    // ── Search / Filter ─────────────────────────────────────────────────

    fn searchQuery(self: *const Self) []const u8 {
        return self.search_buf[0..self.search_len];
    }

    /// Substring match (case-insensitive). Returns true if `query` is a
    /// subsequence of `haystack` with characters in order (fuzzy match).
    fn fuzzyMatch(haystack: []const u8, query: []const u8) bool {
        if (query.len == 0) return true;
        var qi: usize = 0;
        for (haystack) |ch| {
            const lc_h = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            const lc_q = if (query[qi] >= 'A' and query[qi] <= 'Z') query[qi] + 32 else query[qi];
            if (lc_h == lc_q) {
                qi += 1;
                if (qi >= query.len) return true;
            }
        }
        return false;
    }

    /// Rebuild filtered_indices for the active section based on current query.
    fn updateFilter(self: *Self) void {
        self.filtered_indices.clearRetainingCapacity();
        const query = self.searchQuery();
        const sec = &self.sections[@intFromEnum(self.active_section)];

        for (sec.items.items, 0..) |item, idx| {
            const text = if (item.command.len > 0) item.command else item.label;
            if (fuzzyMatch(text, query)) {
                self.filtered_indices.append(self.alloc, idx) catch continue;
            }
        }

        // Reset selection to first match
        sec.selected = if (self.filtered_indices.items.len > 0) self.filtered_indices.items[0] else 0;
        sec.updateScroll();
        sec.dirty = true;
        self.dirty = true;
    }

    /// Enter search mode: expand current section + start filtering
    fn enterSearch(self: *Self) void {
        self.search_active = true;
        self.search_len = 0;
        self.search_buf = [_]u8{0} ** 128;
        // Auto-expand the current section so the user sees filtered results
        self.expanded_section = self.active_section;
        self.focused_on_header = false;
        self.updateFilter();
    }

    /// Exit search mode and restore normal view
    fn exitSearch(self: *Self) void {
        self.search_active = false;
        self.search_len = 0;
        self.filtered_indices.clearRetainingCapacity();
        self.dirty = true;
    }

    // ── Text Input Mode (add/edit favorites) ────────────────────────────

    fn inputQuery(self: *const Self) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    /// Start text input mode, optionally pre-filled with existing text.
    fn beginInput(self: *Self, purpose: InputPurpose, prefill: []const u8) void {
        self.input_active = true;
        self.input_purpose = purpose;
        self.input_buf = [_]u8{0} ** 256;
        self.input_len = 0;

        // Pre-fill the buffer (for edit mode)
        const copy_len = @min(prefill.len, self.input_buf.len - 1);
        for (0..copy_len) |i| {
            self.input_buf[i] = prefill[i];
        }
        self.input_len = @intCast(copy_len);

        // Expand favorites section so user sees the input box
        self.expanded_section = .favorites;
        self.active_section = .favorites;
        self.focused_on_header = false;
        self.dirty = true;
    }

    /// Handle keys in text input mode.
    fn handleInputKey(self: *Self, key: []const u8) bool {
        if (key.len == 0) return false;

        const is_esc = (key.len == 1 and key[0] == 0x1b);
        const is_enter = (key.len == 1 and key[0] == '\r');
        const is_backspace = (key.len == 1 and (key[0] == 0x7f or key[0] == 0x08));
        const is_ctrl_w = (key.len == 1 and key[0] == 0x17);
        const is_ctrl_u = (key.len == 1 and key[0] == 0x15);

        if (is_esc) {
            self.cancelInput();
            return true;
        }

        if (is_enter) {
            self.commitInput();
            return true;
        }

        if (is_backspace) {
            if (self.input_len > 0) {
                self.input_len -= 1;
                self.input_buf[self.input_len] = 0;
                self.dirty = true;
            }
            return true;
        }

        if (is_ctrl_w) {
            while (self.input_len > 0 and self.input_buf[self.input_len - 1] == ' ') {
                self.input_len -= 1;
            }
            while (self.input_len > 0 and self.input_buf[self.input_len - 1] != ' ') {
                self.input_len -= 1;
            }
            self.dirty = true;
            return true;
        }

        if (is_ctrl_u) {
            self.input_len = 0;
            self.dirty = true;
            return true;
        }

        // Printable ASCII
        if (key.len == 1 and key[0] >= 0x20 and key[0] < 0x7f) {
            if (self.input_len < self.input_buf.len - 1) {
                self.input_buf[self.input_len] = key[0];
                self.input_len += 1;
                self.dirty = true;
            }
            return true;
        }

        return true; // consume all keys in input mode
    }

    /// Save the input and exit input mode.
    fn commitInput(self: *Self) void {
        const text = std.mem.trim(u8, self.inputQuery(), " \t");
        if (text.len == 0) {
            self.cancelInput();
            return;
        }

        switch (self.input_purpose) {
            .add_favorite => {
                // Check for duplicates
                for (self.favorites.items) |f| {
                    if (std.mem.eql(u8, f, text)) {
                        // Already exists, just cancel
                        self.cancelInput();
                        return;
                    }
                }
                const duped = self.alloc.dupe(u8, text) catch {
                    self.cancelInput();
                    return;
                };
                self.favorites.append(self.alloc, duped) catch {
                    self.alloc.free(duped);
                    self.cancelInput();
                    return;
                };
            },
            .edit_favorite => {
                if (self.input_edit_idx < self.favorites.items.len) {
                    // Free old string, replace with new
                    self.alloc.free(self.favorites.items[self.input_edit_idx]);
                    self.favorites.items[self.input_edit_idx] = self.alloc.dupe(u8, text) catch {
                        // Failed to dupe — remove the entry to avoid dangling
                        _ = self.favorites.orderedRemove(self.input_edit_idx);
                        self.cancelInput();
                        return;
                    };
                }
            },
        }

        // Persist and rebuild
        self.saveFavorites();
        self.buildFavoritesSection() catch {};
        self.buildRecentSection() catch {};
        self.cancelInput();
    }

    /// Cancel input mode without saving.
    fn cancelInput(self: *Self) void {
        self.input_active = false;
        self.input_len = 0;
        self.dirty = true;
    }

    /// Delete the currently selected favorite.
    fn deleteSelectedFavorite(self: *Self) !void {
        const sec = &self.sections[@intFromEnum(Section.favorites)];
        if (sec.selected >= sec.items.items.len) return;
        const item = &sec.items.items[sec.selected];
        if (item.kind != .favorite_command) return;

        // Find and remove from favorites list
        for (self.favorites.items, 0..) |f, i| {
            if (std.mem.eql(u8, f, item.command)) {
                self.alloc.free(f);
                _ = self.favorites.orderedRemove(i);
                break;
            }
        }

        self.saveFavorites();
        try self.buildFavoritesSection();
        try self.buildRecentSection();
    }

    // ── Keyboard Navigation ──────────────────────────────────────────────

    /// Handle a key input. Returns true if the key was consumed.
    pub fn handleKey(self: *Self, key: []const u8) bool {
        if (key.len == 0) return false;

        // ── Text input mode (add/edit favorite) ──────────────────────
        if (self.input_active) {
            return self.handleInputKey(key);
        }

        // ── Search mode input ─────────────────────────────────────────
        if (self.search_active) {
            return self.handleSearchKey(key);
        }

        const is_down = (key.len == 1 and key[0] == 'j') or
            (key.len == 3 and key[0] == 0x1b and key[1] == '[' and key[2] == 'B');
        const is_up = (key.len == 1 and key[0] == 'k') or
            (key.len == 3 and key[0] == 0x1b and key[1] == '[' and key[2] == 'A');
        const is_right = (key.len == 1 and key[0] == 'l') or
            (key.len == 3 and key[0] == 0x1b and key[1] == '[' and key[2] == 'C');
        const is_left = (key.len == 1 and key[0] == 'h') or
            (key.len == 3 and key[0] == 0x1b and key[1] == '[' and key[2] == 'D');
        const is_enter = (key.len == 1 and key[0] == '\r');
        const is_esc = (key.len == 1 and key[0] == 0x1b);

        // ── Left arrow / h: go back ─────────────────────────────────
        if (is_left) {
            if (self.focused_on_header) {
                if (self.expanded_section != null) {
                    // Files section: left on header = cd to parent dir
                    if (self.active_section == .files) {
                        self.cdParentDir();
                        return true;
                    }
                    // Other sections: collapse expanded section back to 3-pane view
                    self.expanded_section = null;
                    self.dirty = true;
                    return true;
                }
                // Normal mode on Files header: also go up a dir
                if (self.active_section == .files) {
                    self.cdParentDir();
                    return true;
                }
                return true;
            }
            // In items: try collapse/parent in file tree, else go to header
            if (self.active_section == .files) {
                const sec = &self.sections[@intFromEnum(Section.files)];
                if (sec.items.items.len > 0 and sec.selected < sec.items.items.len) {
                    const item = &sec.items.items[sec.selected];
                    if (item.kind == .file_entry) {
                        // If on expanded dir, collapse it
                        if (item.is_dir and item.expanded) {
                            if (item.path.len > 0) {
                                self.toggleDirExpand(item.path) catch {};
                            }
                            return true;
                        }
                        // If nested, walk up to parent directory entry
                        if (item.depth > 0) {
                            const target_depth = item.depth - 1;
                            var idx = sec.selected;
                            while (idx > 0) {
                                idx -= 1;
                                const candidate = &sec.items.items[idx];
                                if (candidate.kind == .file_entry and
                                    candidate.is_dir and
                                    candidate.depth == target_depth)
                                {
                                    sec.selected = idx;
                                    sec.updateScroll();
                                    sec.dirty = true;
                                    self.dirty = true;
                                    return true;
                                }
                            }
                        }
                        // At root depth (depth==0): go up a directory (cd ..)
                        if (item.depth == 0) {
                            self.cdParentDir();
                            return true;
                        }
                    }
                }
            }
            // Default: go back to header
            self.focused_on_header = true;
            self.dirty = true;
            return true;
        }

        // ── Right arrow / l / Enter: drill in ───────────────────────
        if (is_right or is_enter) {
            if (self.focused_on_header) {
                // Expand this section to full page and enter items
                self.expanded_section = self.active_section;
                self.focused_on_header = false;
                const sec = &self.sections[@intFromEnum(self.active_section)];
                if (sec.items.items.len > 0) {
                    sec.updateScroll();
                }
                self.dirty = true;
                return true;
            }
            // In items: do the normal select action
            self.selectItem();
            return true;
        }

        // ── Down / j ─────────────────────────────────────────────────
        if (is_down) {
            if (self.focused_on_header) {
                // Move from header into section items (if expanded)
                if (self.expanded_section != null) {
                    self.focused_on_header = false;
                    const sec = &self.sections[@intFromEnum(self.active_section)];
                    sec.selected = 0;
                    sec.updateScroll();
                    sec.dirty = true;
                    self.dirty = true;
                } else {
                    // Normal mode: move to next section header
                    self.nextSectionHeader();
                }
                return true;
            }
            self.moveDown();
            return true;
        }

        // ── Up / k ───────────────────────────────────────────────────
        if (is_up) {
            if (self.focused_on_header) {
                // Move to previous section header
                if (self.expanded_section != null) {
                    // In expanded mode, up on header does nothing
                    return true;
                }
                self.prevSectionHeader();
                return true;
            }
            // If on first item, go back to header
            const sec = &self.sections[@intFromEnum(self.active_section)];
            if (sec.selected == 0) {
                self.focused_on_header = true;
                self.dirty = true;
                return true;
            }
            self.moveUp();
            return true;
        }

        // ── Escape / q ──────────────────────────────────────────────
        if (is_esc or (key.len == 1 and key[0] == 'q')) {
            if (self.expanded_section != null) {
                // Collapse back to 3-pane view
                self.expanded_section = null;
                self.focused_on_header = true;
                self.dirty = true;
                return true;
            }
            self.pending_action = .close;
            return true;
        }

        // ── o = open file / cd into directory ─────────────────────────
        if (key.len == 1 and key[0] == 'o') {
            if (!self.focused_on_header and self.active_section == .files) {
                const sec = &self.sections[@intFromEnum(Section.files)];
                if (sec.selected < sec.items.items.len) {
                    const item = &sec.items.items[sec.selected];
                    if (item.kind == .file_entry) {
                        if (item.is_dir) {
                            // cd into the directory (change file tree root)
                            self.cdIntoDir();
                        } else if (item.path.len > 0) {
                            // Open file in nvim-gui with parent dir as cwd
                            const dir = std.fs.path.dirname(item.path) orelse self.file_tree_root;
                            self.pending_action = .{ .open_file = .{
                                .path = item.path,
                                .dir = dir,
                            } };
                        }
                    }
                }
            }
            return true;
        }

        // ── Tab = next section ───────────────────────────────────────
        if (key.len == 1 and key[0] == '\t') {
            if (self.expanded_section != null) return true; // no tab in expanded
            self.nextSectionHeader();
            return true;
        }

        // ── Shift-Tab = prev section ─────────────────────────────────
        if (key.len == 3 and key[0] == 0x1b and key[1] == '[' and key[2] == 'Z') {
            if (self.expanded_section != null) return true;
            self.prevSectionHeader();
            return true;
        }

        // ── r = refresh file tree ────────────────────────────────────
        if (key.len == 1 and key[0] == 'r') {
            self.refreshFileTree() catch {};
            return true;
        }

        // ── f = toggle favorite ──────────────────────────────────────
        if (key.len == 1 and key[0] == 'f') {
            if (!self.focused_on_header) {
                self.toggleFavorite() catch {};
            }
            return true;
        }

        // ── a = add new favorite (opens text input) ──────────────────
        if (key.len == 1 and key[0] == 'a') {
            if (self.active_section == .favorites or self.active_section == .recent) {
                self.beginInput(.add_favorite, "");
            }
            return true;
        }

        // ── e = edit selected favorite (opens text input pre-filled) ─
        if (key.len == 1 and key[0] == 'e') {
            if (self.active_section == .favorites and !self.focused_on_header) {
                const sec = &self.sections[@intFromEnum(Section.favorites)];
                if (sec.selected < sec.items.items.len) {
                    const item = &sec.items.items[sec.selected];
                    if (item.kind == .favorite_command) {
                        self.beginInput(.edit_favorite, item.command);
                        self.input_edit_idx = sec.selected;
                    }
                }
            }
            return true;
        }

        // ── d/x = delete selected favorite ───────────────────────────
        if (key.len == 1 and (key[0] == 'd' or key[0] == 'x')) {
            if (self.active_section == .favorites and !self.focused_on_header) {
                self.deleteSelectedFavorite() catch {};
            }
            return true;
        }

        // ── g = top of section ───────────────────────────────────────
        if (key.len == 1 and key[0] == 'g') {
            if (!self.focused_on_header) {
                const sec = &self.sections[@intFromEnum(self.active_section)];
                sec.selected = 0;
                sec.updateScroll();
                sec.dirty = true;
                self.dirty = true;
            }
            return true;
        }

        // ── G = bottom of section ────────────────────────────────────
        if (key.len == 1 and key[0] == 'G') {
            if (!self.focused_on_header) {
                const sec = &self.sections[@intFromEnum(self.active_section)];
                if (sec.items.items.len > 0) {
                    sec.selected = sec.items.items.len - 1;
                    sec.updateScroll();
                    sec.dirty = true;
                    self.dirty = true;
                }
            }
            return true;
        }

        // ── 1/2/3 = jump to section ─────────────────────────────────
        if (key.len == 1 and key[0] >= '1' and key[0] <= '3') {
            if (self.expanded_section != null) return true;
            const idx = key[0] - '1';
            self.active_section = @enumFromInt(@as(u2, @intCast(idx)));
            self.focused_on_header = true;
            self.dirty = true;
            return true;
        }

        // ── / = search/filter ─────────────────────────────────────────
        if (key.len == 1 and key[0] == '/') {
            self.enterSearch();
            return true;
        }

        return false;
    }

    /// Handle keys while in search mode. Typing appends to the query,
    /// Backspace deletes, Esc exits, Enter selects, j/k or arrows navigate.
    fn handleSearchKey(self: *Self, key: []const u8) bool {
        if (key.len == 0) return false;

        const is_esc = (key.len == 1 and key[0] == 0x1b);
        const is_enter = (key.len == 1 and key[0] == '\r');
        const is_backspace = (key.len == 1 and (key[0] == 0x7f or key[0] == 0x08));
        const is_down = (key.len == 1 and key[0] == 'j') or
            (key.len == 3 and key[0] == 0x1b and key[1] == '[' and key[2] == 'B') or
            (key.len == 1 and key[0] == '\t');
        const is_up = (key.len == 1 and key[0] == 'k') or
            (key.len == 3 and key[0] == 0x1b and key[1] == '[' and key[2] == 'A');

        // Ctrl+W = delete word
        const is_ctrl_w = (key.len == 1 and key[0] == 0x17);
        // Ctrl+U = clear line
        const is_ctrl_u = (key.len == 1 and key[0] == 0x15);

        if (is_esc) {
            self.exitSearch();
            // Also collapse back to 3-pane
            self.expanded_section = null;
            self.focused_on_header = true;
            return true;
        }

        if (is_enter) {
            // Select the currently highlighted item then exit search
            self.selectItem();
            self.exitSearch();
            return true;
        }

        if (is_backspace) {
            if (self.search_len > 0) {
                self.search_len -= 1;
                self.search_buf[self.search_len] = 0;
                self.updateFilter();
            } else {
                // Backspace on empty query exits search
                self.exitSearch();
                self.expanded_section = null;
                self.focused_on_header = true;
            }
            return true;
        }

        if (is_ctrl_w) {
            // Delete last word
            while (self.search_len > 0 and self.search_buf[self.search_len - 1] == ' ') {
                self.search_len -= 1;
            }
            while (self.search_len > 0 and self.search_buf[self.search_len - 1] != ' ') {
                self.search_len -= 1;
            }
            self.updateFilter();
            return true;
        }

        if (is_ctrl_u) {
            self.search_len = 0;
            self.updateFilter();
            return true;
        }

        if (is_down) {
            self.searchMoveDown();
            return true;
        }

        if (is_up) {
            self.searchMoveUp();
            return true;
        }

        // Printable ASCII character — append to search buffer
        if (key.len == 1 and key[0] >= 0x20 and key[0] < 0x7f) {
            if (self.search_len < self.search_buf.len - 1) {
                self.search_buf[self.search_len] = key[0];
                self.search_len += 1;
                self.updateFilter();
            }
            return true;
        }

        return true; // consume all keys in search mode
    }

    /// Move to next filtered item
    fn searchMoveDown(self: *Self) void {
        if (self.filtered_indices.items.len == 0) return;
        const sec = &self.sections[@intFromEnum(self.active_section)];
        // Find current position in filtered list
        for (self.filtered_indices.items, 0..) |idx, fi| {
            if (idx == sec.selected) {
                if (fi + 1 < self.filtered_indices.items.len) {
                    sec.selected = self.filtered_indices.items[fi + 1];
                    sec.updateScroll();
                    sec.dirty = true;
                    self.dirty = true;
                }
                return;
            }
        }
        // Not found, jump to first
        sec.selected = self.filtered_indices.items[0];
        sec.updateScroll();
        sec.dirty = true;
        self.dirty = true;
    }

    /// Move to previous filtered item
    fn searchMoveUp(self: *Self) void {
        if (self.filtered_indices.items.len == 0) return;
        const sec = &self.sections[@intFromEnum(self.active_section)];
        for (self.filtered_indices.items, 0..) |idx, fi| {
            if (idx == sec.selected) {
                if (fi > 0) {
                    sec.selected = self.filtered_indices.items[fi - 1];
                    sec.updateScroll();
                    sec.dirty = true;
                    self.dirty = true;
                }
                return;
            }
        }
        sec.selected = self.filtered_indices.items[self.filtered_indices.items.len - 1];
        sec.updateScroll();
        sec.dirty = true;
        self.dirty = true;
    }

    fn moveDown(self: *Self) void {
        const sec = &self.sections[@intFromEnum(self.active_section)];
        if (sec.items.items.len == 0) return;
        if (sec.selected < sec.items.items.len - 1) {
            sec.selected += 1;
            sec.updateScroll();
            sec.dirty = true;
            self.dirty = true;
        }
        // At bottom: stay (user must press left to go back to header)
    }

    fn moveUp(self: *Self) void {
        const sec = &self.sections[@intFromEnum(self.active_section)];
        if (sec.items.items.len == 0) return;
        if (sec.selected > 0) {
            sec.selected -= 1;
            sec.updateScroll();
            sec.dirty = true;
            self.dirty = true;
        }
        // At top (selected==0): handled in handleKey (goes to header)
    }

    fn nextSectionHeader(self: *Self) void {
        const current: u8 = @intFromEnum(self.active_section);
        const next_idx: u8 = (current + 1) % 3;
        self.active_section = @enumFromInt(@as(u2, @intCast(next_idx)));
        self.focused_on_header = true;
        self.dirty = true;
    }

    fn prevSectionHeader(self: *Self) void {
        const current: u8 = @intFromEnum(self.active_section);
        const prev_idx: u8 = (current + 2) % 3; // +2 mod 3 == -1 mod 3
        self.active_section = @enumFromInt(@as(u2, @intCast(prev_idx)));
        self.focused_on_header = true;
        self.dirty = true;
    }

    fn selectItem(self: *Self) void {
        const sec = &self.sections[@intFromEnum(self.active_section)];
        if (sec.items.items.len == 0) return;
        if (sec.selected >= sec.items.items.len) return;
        const item = &sec.items.items[sec.selected];

        switch (item.kind) {
            .favorite_command, .recent_command => {
                if (item.command.len > 0) {
                    self.pending_action = .{ .run_command = item.command };
                }
            },
            .file_entry => {
                if (item.is_dir) {
                    if (item.path.len > 0) {
                        self.toggleDirExpand(item.path) catch {};
                    }
                } else {
                    if (item.path.len > 0) {
                        // Get the parent directory of this file for nvim-gui cwd
                        const dir = std.fs.path.dirname(item.path) orelse self.file_tree_root;
                        self.pending_action = .{ .open_file = .{
                            .path = item.path,
                            .dir = dir,
                        } };
                    }
                }
            },
        }
    }

    /// Change the file tree root to the selected directory (like cd)
    fn cdIntoDir(self: *Self) void {
        if (self.active_section != .files) return;
        const sec = &self.sections[@intFromEnum(Section.files)];
        if (sec.items.items.len == 0) return;
        if (sec.selected >= sec.items.items.len) return;
        const item = &sec.items.items[sec.selected];

        if (item.kind != .file_entry) return;

        // Get the directory path to cd into
        const new_root = if (item.is_dir)
            item.path
        else
            std.fs.path.dirname(item.path) orelse return;

        if (new_root.len == 0) return;

        // Update the file tree root
        if (self.file_tree_root.len > 0) self.alloc.free(self.file_tree_root);
        self.file_tree_root = self.alloc.dupe(u8, new_root) catch return;

        // Clear expanded dirs and cache since we changed root
        for (self.expanded_dirs.items) |d| self.alloc.free(d);
        self.expanded_dirs.clearRetainingCapacity();
        self.freeDirCache();

        // Rebuild files section
        self.buildFilesSection() catch {};
    }

    /// Navigate to the parent directory of the current file tree root (cd ..)
    fn cdParentDir(self: *Self) void {
        if (self.file_tree_root.len == 0) return;
        const parent = std.fs.path.dirname(self.file_tree_root) orelse return;
        if (parent.len == 0) return;
        // Don't go above /
        if (std.mem.eql(u8, parent, self.file_tree_root)) return;
        // Must be absolute path
        if (!std.fs.path.isAbsolute(parent)) return;

        // Dupe BEFORE freeing old root (parent is a slice into file_tree_root)
        const new_root = self.alloc.dupe(u8, parent) catch return;
        self.alloc.free(self.file_tree_root);
        self.file_tree_root = new_root;

        // Clear expanded dirs and cache since we changed root
        for (self.expanded_dirs.items) |d| self.alloc.free(d);
        self.expanded_dirs.clearRetainingCapacity();
        self.freeDirCache();

        // Rebuild files section
        self.buildFilesSection() catch {};
    }

    /// Animate all section scroll springs. Returns true if still animating.
    pub fn animate(self: *Self, dt: f32) bool {
        var animating = false;
        for (&self.sections) |*sec| {
            if (sec.animateScroll(dt)) {
                animating = true;
                self.dirty = true;
            }
        }
        return animating;
    }

    // ── Section Layout ───────────────────────────────────────────────────

    const SectionLayout = struct {
        start_row: u32, // First row of this section (header row)
        header_row: u32, // Same as start_row (header is pinned here)
        content_start: u32, // First row for actual content (after header)
        content_rows: u32, // Number of rows available for items
        end_row: u32, // One past the last row
    };

    /// Compute the row layout for all 3 sections.
    /// Returns [3]SectionLayout.
    /// Row 0 is the title bar. Sections start at row 1.
    /// When a section is expanded, it gets all usable rows; others get 0.
    fn computeLayout(self: *const Self, total_rows: u32) [3]SectionLayout {
        // Row 0 = title bar (or search bar)
        // Last row = hint bar
        // Remaining rows divided among sections
        const reserved = @as(u32, 2); // title + hints
        const usable = if (total_rows > reserved) total_rows - reserved else 0;

        if (self.expanded_section) |expanded| {
            // Expanded mode: the expanded section gets all rows,
            // collapsed sections get header-only (1 row each)
            const collapsed_header_rows: u32 = 1;
            const collapsed_total: u32 = collapsed_header_rows * 2; // 2 collapsed sections
            const expanded_rows: u32 = if (usable > collapsed_total) usable - collapsed_total else 1;

            var section_rows = [3]u32{ collapsed_header_rows, collapsed_header_rows, collapsed_header_rows };
            section_rows[@intFromEnum(expanded)] = expanded_rows;

            var start: u32 = 1; // after title bar
            var result: [3]SectionLayout = undefined;
            for (0..3) |si| {
                const rows_for = section_rows[si];
                result[si] = .{
                    .start_row = start,
                    .header_row = start,
                    .content_start = start + 1,
                    .content_rows = if (rows_for > 1) rows_for - 1 else 0,
                    .end_row = start + rows_for,
                };
                start += rows_for;
            }
            return result;
        }

        // Normal mode: Favorites ~25%, Recent ~25%, Files ~50%
        // Each section needs at least 3 rows (header + separator line + 1 content row)
        const min_section_rows: u32 = 3;

        var fav_rows: u32 = @max(min_section_rows, usable * 25 / 100);
        var recent_rows: u32 = @max(min_section_rows, usable * 25 / 100);
        var files_rows: u32 = if (usable > fav_rows + recent_rows) usable - fav_rows - recent_rows else min_section_rows;

        // Ensure total doesn't exceed usable
        const total_section = fav_rows + recent_rows + files_rows;
        if (total_section > usable and usable >= min_section_rows * 3) {
            files_rows = usable - fav_rows - recent_rows;
        } else if (usable < min_section_rows * 3) {
            // Very small panel, give equal share
            const per = usable / 3;
            fav_rows = per;
            recent_rows = per;
            files_rows = usable - per * 2;
        }

        const fav_start: u32 = 1; // after title
        const recent_start: u32 = fav_start + fav_rows;
        const files_start: u32 = recent_start + recent_rows;

        return .{
            .{
                .start_row = fav_start,
                .header_row = fav_start,
                .content_start = fav_start + 1, // 1 row for header
                .content_rows = if (fav_rows > 1) fav_rows - 1 else 0,
                .end_row = recent_start,
            },
            .{
                .start_row = recent_start,
                .header_row = recent_start,
                .content_start = recent_start + 1,
                .content_rows = if (recent_rows > 1) recent_rows - 1 else 0,
                .end_row = files_start,
            },
            .{
                .start_row = files_start,
                .header_row = files_start,
                .content_start = files_start + 1,
                .content_rows = if (files_rows > 1) files_rows - 1 else 0,
                .end_row = files_start + files_rows,
            },
        };
    }

    // ── Rendering ────────────────────────────────────────────────────────

    /// Render the menu into a RenderedPanel's cell grid.
    pub fn render(self: *Self, panel: *RenderedPanel) void {
        const cols = panel.cols;
        const rows = panel.rows;
        self.total_rows = rows;
        self.total_cols = cols;

        const t = &self.theme;

        // Clear all cells to background color
        for (panel.cells) |*cell| {
            cell.* = Cell{};
            cell.bg = t.bg;
            cell.fg = t.fg;
        }

        // Title bar at row 0 (always shown)
        self.renderTitleBar(panel, cols);

        // Compute fixed-area layout
        const layout = self.computeLayout(rows);

        // Update visible_rows in each section state
        self.sections[0].visible_rows = layout[0].content_rows;
        self.sections[1].visible_rows = layout[1].content_rows;
        self.sections[2].visible_rows = layout[2].content_rows;

        // Render each section
        const section_info = [3]struct {
            section: Section,
            title: []const u8,
            icon: []const u8,
            icon_color: u32,
        }{
            .{ .section = .favorites, .title = "Favorites", .icon = icons.favorites, .icon_color = t.yellow },
            .{ .section = .recent, .title = "Recent Commands", .icon = icons.recent, .icon_color = t.mauve },
            .{ .section = .files, .title = "Files", .icon = icons.files, .icon_color = t.accent },
        };

        for (section_info, 0..) |info, si| {
            const sec = &self.sections[si];
            const lay = layout[si];
            const is_active = (self.active_section == info.section);
            const header_selected = is_active and self.focused_on_header;
            const items_active = is_active and !self.focused_on_header;

            // Render pinned section header (with selection highlight if focused)
            self.renderSectionHeader(panel, lay.header_row, cols, info.title, info.icon, info.icon_color, is_active, header_selected);

            // When search is active, draw the search bar right under this
            // section's header and shift content down by 1 row.
            var eff_content_start = lay.content_start;
            var eff_content_rows = lay.content_rows;
            if (self.search_active and is_active and eff_content_rows > 1) {
                self.renderSearchBar(panel, eff_content_start, cols);
                eff_content_start += 1;
                eff_content_rows -= 1;
            }

            // Render section content (only if there are content rows)
            if (eff_content_rows > 0) {
                if (sec.items.items.len == 0) {
                    self.renderEmptyHint(panel, eff_content_start, cols, sec.empty_hint);
                } else {
                    self.renderSectionContent(panel, sec, eff_content_start, eff_content_rows, cols, items_active);
                }
            }

            // Draw a subtle bottom border for this section (except the last)
            if (si < 2 and lay.content_rows > 0) {
                self.renderSectionBorder(panel, lay.end_row -| 1, cols);
            }
        }

        // Hint bar at bottom row
        if (rows > 2) {
            self.renderHintBar(panel, rows - 1, cols);
        }

        panel.dirty = true;
        self.dirty = false;
        for (&self.sections) |*sec| {
            sec.dirty = false;
        }
    }

    fn renderTitleBar(self: *const Self, panel: *RenderedPanel, cols: u32) void {
        const t = &self.theme;
        const title = "  Panel";
        var col: u32 = 0;
        for (title) |ch| {
            if (col >= cols) break;
            if (panel.getCellMut(0, col)) |cell| {
                cell.text[0] = ch;
                cell.text_len = 1;
                cell.fg = t.fg;
                cell.bg = t.bg_surface;
                cell.bold = true;
            }
            col += 1;
        }
        while (col < cols) : (col += 1) {
            if (panel.getCellMut(0, col)) |cell| {
                cell.bg = t.bg_surface;
            }
        }
    }

    /// Render context-sensitive keybinding hints at the bottom of the panel.
    fn renderHintBar(self: *const Self, panel: *RenderedPanel, row: u32, cols: u32) void {
        const t = &self.theme;
        const bar_bg = t.bg_surface;

        // Build hint text based on current mode
        const hints: []const u8 = if (self.search_active)
            " esc:close  enter:select  j/k:move"
        else if (self.focused_on_header)
            " j/k:nav  enter:expand  /:search  q:close"
        else switch (self.active_section) {
            .favorites => " j/k:nav  enter:run  f:unfav  h:back  /:search",
            .recent => " j/k:nav  enter:run  f:fav  h:back  /:search",
            .files => " j/k:nav  o:open  h:back/up  r:refresh  /:search",
        };

        var col: u32 = 0;
        for (hints) |ch| {
            if (col >= cols) break;
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = ch;
                cell.text_len = 1;
                cell.fg = t.fg_faint;
                cell.bg = bar_bg;
            }
            col += 1;
        }
        while (col < cols) : (col += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = bar_bg;
            }
        }
    }

    /// Render the search input bar (replaces title bar row when search is active)
    fn renderSearchBar(self: *const Self, panel: *RenderedPanel, row: u32, cols: u32) void {
        const t = &self.theme;
        const bar_bg = t.bg_surface;
        var col: u32 = 0;

        // Prompt: "/ "
        const prompt = " /";
        for (prompt) |ch| {
            if (col >= cols) break;
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = ch;
                cell.text_len = 1;
                cell.fg = t.accent;
                cell.bg = bar_bg;
                cell.bold = true;
            }
            col += 1;
        }

        // Space
        if (col < cols) {
            if (panel.getCellMut(row, col)) |cell| cell.bg = bar_bg;
            col += 1;
        }

        // Query text
        const query = self.searchQuery();
        for (query) |ch| {
            if (col >= cols -| 2) break;
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = ch;
                cell.text_len = 1;
                cell.fg = t.fg;
                cell.bg = bar_bg;
            }
            col += 1;
        }

        // Cursor block
        if (col < cols) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = ' ';
                cell.text_len = 1;
                cell.fg = t.bg;
                cell.bg = t.fg;
            }
            col += 1;
        }

        // Match count on the right
        const match_count = self.filtered_indices.items.len;
        var count_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{match_count}) catch "";
        const count_label_len = count_str.len + 1; // "N↵" or just "N"
        if (cols > col + count_label_len + 2) {
            var rc: u32 = cols - @as(u32, @intCast(count_label_len)) - 1;
            for (count_str) |ch| {
                if (panel.getCellMut(row, rc)) |cell| {
                    cell.text[0] = ch;
                    cell.text_len = 1;
                    cell.fg = t.fg_muted;
                    cell.bg = bar_bg;
                }
                rc += 1;
            }
        }

        // Fill rest
        while (col < cols) : (col += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                if (cell.text_len == 0) cell.bg = bar_bg;
            }
        }
    }

    fn renderSectionHeader(
        self: *const Self,
        panel: *RenderedPanel,
        row: u32,
        cols: u32,
        title: []const u8,
        icon: []const u8,
        icon_color: u32,
        is_active: bool,
        header_selected: bool,
    ) void {
        const t = &self.theme;
        const header_bg = if (header_selected) t.bg_selected else if (is_active) t.section_active_bg else t.section_inactive_bg;
        var col: u32 = 0;

        // Selection indicator when header is focused
        if (header_selected) {
            if (panel.getCellMut(row, 0)) |cell| {
                cell.bg = header_bg;
            }
            if (panel.getCellMut(row, 1)) |cell| {
                cell.text[0] = '>';
                cell.text_len = 1;
                cell.fg = t.accent;
                cell.bg = header_bg;
                cell.bold = true;
            }
            col = 2;
        } else {
            // Left padding
            const pad: u32 = 2;
            while (col < pad and col < cols) : (col += 1) {
                if (panel.getCellMut(row, col)) |cell| {
                    cell.bg = header_bg;
                }
            }
        }

        // Space before icon
        if (col < cols) {
            if (panel.getCellMut(row, col)) |cell| cell.bg = header_bg;
            col += 1;
        }

        // Icon (double-width Nerd Font glyph)
        if (icon.len > 0 and col + 1 < cols) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.setText(icon);
                cell.fg = icon_color;
                cell.bg = header_bg;
                cell.bold = true;
            }
            if (panel.getCellMut(row, col + 1)) |cell| {
                cell.bg = header_bg;
            }
            col += 2;

            // Space after icon
            if (col < cols) {
                if (panel.getCellMut(row, col)) |cell| cell.bg = header_bg;
                col += 1;
            }
        }

        // Section label
        const label_fg = if (header_selected) t.fg else if (is_active) t.fg else t.fg_dim;
        for (title) |ch| {
            if (col >= cols) break;
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = ch;
                cell.text_len = 1;
                cell.fg = label_fg;
                cell.bg = header_bg;
                cell.bold = true;
            }
            col += 1;
        }

        // Right side: show expand hint when header is selected
        if (header_selected and cols > 4) {
            if (panel.getCellMut(row, cols - 2)) |cell| {
                cell.text[0] = '>';
                cell.text_len = 1;
                cell.fg = t.accent;
                cell.bg = header_bg;
                cell.bold = true;
            }
        }

        // Fill rest
        while (col < cols) : (col += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = header_bg;
            }
        }
    }

    fn renderEmptyHint(self: *const Self, panel: *RenderedPanel, row: u32, cols: u32, hint: []const u8) void {
        const t = &self.theme;
        var col: u32 = 0;
        for (hint) |ch| {
            if (col >= cols) break;
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = ch;
                cell.text_len = 1;
                cell.fg = t.fg_faint;
                cell.bg = t.bg;
                cell.italic = true;
            }
            col += 1;
        }
        while (col < cols) : (col += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = t.bg;
            }
        }
    }

    fn renderSectionBorder(self: *const Self, panel: *RenderedPanel, row: u32, cols: u32) void {
        const t = &self.theme;
        if (row == 0) return;
        var col: u32 = 0;
        const pad = 2;
        while (col < pad and col < cols) : (col += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = t.bg;
            }
        }
        while (col < cols -| pad) : (col += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = 0xe2;
                cell.text[1] = 0x94;
                cell.text[2] = 0x80;
                cell.text_len = 3;
                cell.fg = t.separator;
                cell.bg = t.bg;
            }
        }
        while (col < cols) : (col += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = t.bg;
            }
        }
    }

    fn renderSectionContent(
        self: *const Self,
        panel: *RenderedPanel,
        sec: *const SectionState,
        start_row: u32,
        max_rows: u32,
        cols: u32,
        is_active: bool,
    ) void {
        const t = &self.theme;
        if (max_rows == 0) return;

        // When search is active for this section, render only filtered items
        if (self.search_active and is_active and self.filtered_indices.items.len > 0) {
            var draw_row: u32 = 0;
            for (self.filtered_indices.items) |item_idx| {
                if (draw_row >= max_rows) break;
                if (item_idx >= sec.items.items.len) continue;
                const item = &sec.items.items[item_idx];
                const is_selected = (item_idx == sec.selected);
                const panel_row = start_row + draw_row;
                switch (item.kind) {
                    .favorite_command, .recent_command => renderCommandItem(panel, panel_row, cols, item, is_selected, t),
                    .file_entry => renderFileEntry(panel, panel_row, cols, item, is_selected, t),
                }
                draw_row += 1;
            }
            // If no matches, show hint
            if (self.filtered_indices.items.len == 0) {
                self.renderEmptyHint(panel, start_row, cols, "  No matches");
            }
            return;
        }

        // Normal (non-filtered) rendering
        // Compute scroll offset
        const scroll_row: i32 = @intFromFloat(@floor(sec.scroll_offset));
        const item_count = sec.items.items.len;

        var draw_idx: usize = 0;
        var draw_row: u32 = 0;

        // Skip items that are scrolled above
        if (scroll_row > 0) {
            draw_idx = @intCast(@min(@as(usize, @intCast(scroll_row)), item_count));
        }

        // Render visible items
        while (draw_idx < item_count and draw_row < max_rows) {
            const item = &sec.items.items[draw_idx];
            const is_selected = is_active and (draw_idx == sec.selected);
            const panel_row = start_row + draw_row;

            switch (item.kind) {
                .favorite_command, .recent_command => {
                    renderCommandItem(panel, panel_row, cols, item, is_selected, t);
                },
                .file_entry => {
                    renderFileEntry(panel, panel_row, cols, item, is_selected, t);
                },
            }

            draw_idx += 1;
            draw_row += 1;
        }
    }

    fn renderFileEntry(panel: *RenderedPanel, row: u32, cols: u32, item: *const MenuItem, selected: bool, t: *const Theme) void {
        const bg = if (selected) t.bg_selected else t.bg;
        var col: u32 = 0;

        // Layout: [sel_indicator 2 cols] [indent] [expand 1 col] [space] [icon 2 cols] [space] [label...]
        // Selection indicator: col 0-1 (use plain ASCII '>' to avoid double-width issues)
        if (selected) {
            if (panel.getCellMut(row, 0)) |cell| {
                cell.bg = bg;
            }
            if (panel.getCellMut(row, 1)) |cell| {
                cell.text[0] = '>';
                cell.text_len = 1;
                cell.fg = t.accent;
                cell.bg = bg;
                cell.bold = true;
            }
        } else {
            if (panel.getCellMut(row, 0)) |cell| cell.bg = bg;
            if (panel.getCellMut(row, 1)) |cell| cell.bg = bg;
        }
        // Gap after selection indicator
        if (panel.getCellMut(row, 2)) |cell| cell.bg = bg;
        col = 3;

        // Tree indentation (2 chars per depth level)
        const indent: u32 = @as(u32, item.depth) * 2;
        var i: u32 = 0;
        while (i < indent and col < cols) : (i += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = bg;
            }
            col += 1;
        }

        // Expand/collapse indicator for directories (plain ASCII to avoid overlap)
        if (item.is_dir and col < cols) {
            if (panel.getCellMut(row, col)) |cell| {
                if (item.expanded) {
                    cell.text[0] = 'v';
                    cell.text_len = 1;
                } else {
                    cell.text[0] = '>';
                    cell.text_len = 1;
                }
                cell.fg = t.fg_muted;
                cell.bg = bg;
            }
            col += 1;
        } else if (col < cols) {
            // Space placeholder for files (aligns with dirs)
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = bg;
            }
            col += 1;
        }

        // Space before icon
        if (col < cols) {
            if (panel.getCellMut(row, col)) |cell| cell.bg = bg;
            col += 1;
        }

        // Icon (Nerd Font glyphs are double-width, reserve 2 columns)
        if (item.icon.len > 0 and col + 1 < cols) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.setText(item.icon);
                cell.fg = item.icon_color;
                cell.bg = bg;
            }
            // Second column consumed by double-width glyph
            if (panel.getCellMut(row, col + 1)) |cell| {
                cell.bg = bg;
            }
            col += 2;

            // Space after icon
            if (col < cols) {
                if (panel.getCellMut(row, col)) |cell| {
                    cell.bg = bg;
                }
                col += 1;
            }
        }

        // Label (leave 3 cols on right for git status indicator)
        const right_margin: u32 = if (item.git_status != .none) 3 else 1;
        const label_fg = if (item.is_dir) t.accent else if (selected) t.fg else t.fg_dim;
        for (item.label) |ch| {
            if (col >= cols -| right_margin) break;
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = ch;
                cell.text_len = 1;
                cell.fg = label_fg;
                cell.bg = bg;
                cell.bold = item.is_dir or selected;
            }
            col += 1;
        }

        // Trailing slash for directories
        if (item.is_dir and col < cols -| right_margin) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = '/';
                cell.text_len = 1;
                cell.fg = t.fg_faint;
                cell.bg = bg;
            }
            col += 1;
        }

        // Fill rest
        while (col < cols) : (col += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = bg;
            }
        }

        // Git status indicator at the right edge (overwrite last 2 cols)
        if (item.git_status != .none and cols >= 3) {
            const git_info = gitStatusDisplay(item.git_status, t);
            if (panel.getCellMut(row, cols - 2)) |cell| {
                cell.text[0] = git_info.char;
                cell.text_len = 1;
                cell.fg = git_info.color;
                cell.bg = bg;
                cell.bold = true;
            }
        }
    }

    const GitDisplay = struct { char: u8, color: u32 };

    fn gitStatusDisplay(status: GitStatus, t: *const Theme) GitDisplay {
        return switch (status) {
            .modified => .{ .char = 'M', .color = t.yellow },
            .added => .{ .char = 'A', .color = t.green },
            .untracked => .{ .char = '?', .color = t.fg_muted },
            .deleted => .{ .char = 'D', .color = t.red },
            .renamed => .{ .char = 'R', .color = t.accent },
            .conflicted => .{ .char = 'U', .color = t.red },
            .none => .{ .char = ' ', .color = t.fg },
        };
    }

    fn renderCommandItem(panel: *RenderedPanel, row: u32, cols: u32, item: *const MenuItem, selected: bool, t: *const Theme) void {
        const bg = if (selected) t.bg_selected else t.bg;
        var col: u32 = 0;

        const pad = 3;
        if (selected) {
            if (panel.getCellMut(row, 0)) |cell| {
                cell.bg = bg;
            }
            if (panel.getCellMut(row, 1)) |cell| {
                cell.setText(icons.chevron_right);
                cell.fg = t.accent;
                cell.bg = bg;
            }
            if (panel.getCellMut(row, 2)) |cell| {
                cell.bg = bg;
            }
            col = pad;
        } else {
            while (col < pad and col < cols) : (col += 1) {
                if (panel.getCellMut(row, col)) |cell| {
                    cell.bg = bg;
                }
            }
        }

        // Favorite star / icon
        if (item.favorited) {
            if (col < cols) {
                if (panel.getCellMut(row, col)) |cell| {
                    cell.setText(icons.star_filled);
                    cell.fg = t.yellow;
                    cell.bg = bg;
                }
                col += 1;
            }
        } else if (item.icon.len > 0) {
            if (col < cols) {
                if (panel.getCellMut(row, col)) |cell| {
                    cell.setText(item.icon);
                    cell.fg = item.icon_color;
                    cell.bg = bg;
                }
                col += 1;
            }
        }

        // Space after icon
        if (col < cols) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = bg;
            }
            col += 1;
        }

        // Command label — favorites get brighter text to stand out
        const label_fg: u32 = if (selected)
            t.fg
        else if (item.favorited or item.kind == .favorite_command)
            t.fg // full brightness for favorites
        else
            t.fg_dim;

        const max_label_cols = cols -| col -| 1;
        var label_written: u32 = 0;
        for (item.label) |ch| {
            if (label_written >= max_label_cols) break;
            if (col >= cols) break;
            if (panel.getCellMut(row, col)) |cell| {
                cell.text[0] = ch;
                cell.text_len = 1;
                cell.fg = label_fg;
                cell.bg = bg;
            }
            col += 1;
            label_written += 1;
        }

        // Fill rest
        while (col < cols) : (col += 1) {
            if (panel.getCellMut(row, col)) |cell| {
                cell.bg = bg;
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "Menu init and deinit" {
    const alloc = std.testing.allocator;
    const menu = try Menu.init(alloc);
    defer menu.deinit();

    // Should have the files section populated (if CWD exists)
    // At minimum, the sections array should exist
    try std.testing.expect(menu.sections.len == 3);
}

test "Menu navigation" {
    const alloc = std.testing.allocator;
    const menu = try Menu.init(alloc);
    defer menu.deinit();

    // Move down (may switch sections if current is empty)
    _ = menu.handleKey("j");
    // Should not crash
    _ = menu.handleKey("k");
    _ = menu.handleKey("\t");
}

test "Menu render" {
    const alloc = std.testing.allocator;
    const menu = try Menu.init(alloc);
    defer menu.deinit();

    const panel = try RenderedPanel.init(alloc, 40, 20);
    defer panel.deinit();

    menu.render(panel);

    // Title bar should have content
    const title_cell = panel.getCell(0, 2);
    try std.testing.expect(title_cell.text_len > 0);
}
