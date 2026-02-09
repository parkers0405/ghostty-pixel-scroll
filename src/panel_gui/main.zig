//! Panel GUI - Dynamic slide-out panel framework
//!
//! Provides a Warp-style side or bottom panel system with smooth spring
//! animations and draggable resize. Panels are **module-based**: each panel
//! is a generic container (position, animation, drag) with a pluggable
//! content module.
//!
//! Current modules:
//!   - `program`: runs an external TUI program (lazygit, lazydocker, htop, etc.)
//!     in a PTY and renders its VT output
//!
//! Future modules (just add a variant to PanelModule):
//!   - `command_history`: browse/search/re-run past commands
//!   - `favorites`: saved command bookmarks
//!   - `file_browser`: navigate files from the panel
//!   - `ai_chat`: inline AI assistant
//!
//! Architecture:
//! - PanelGui is the generic container (position, slide animation, drag, focus)
//! - PanelModule describes the content source (tagged union)
//! - For `program` modules: I/O thread manages PTY, RenderedPanel parses VT output
//! - The renderer composites panel cells onto the surface
//!
//! Config: `panel = position:module:args` (e.g. `right:program:lazygit`)
//! Keybind: `toggle_panel:name` (e.g. `toggle_panel:lazygit`)
//! OSC: `printf '\e]1339;name\a'`

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const IoThread = @import("io_thread.zig").IoThread;
pub const OutputQueue = @import("io_thread.zig").OutputQueue;
pub const RenderedPanel = @import("rendered_panel.zig").RenderedPanel;
pub const Cell = @import("rendered_panel.zig").Cell;
pub const Animation = @import("animation.zig");
pub const SlideAnimation = Animation.SlideAnimation;
pub const CriticallyDampedSpring = Animation.CriticallyDampedSpring;
pub const panel_input = @import("input.zig");
const menu_mod = @import("menu.zig");
pub const Menu = menu_mod.Menu;
pub const Theme = menu_mod.Theme;

const log = std.log.scoped(.panel_gui);

/// Panel position relative to the main terminal content
pub const PanelPosition = enum {
    /// Panel slides in from the right side
    right,
    /// Panel slides in from the left side
    left,
    /// Panel slides up from the bottom
    bottom,
    /// Panel slides down from the top
    top,
};

/// A panel module describes what content a panel shows.
/// This is the extension point for adding new panel types.
pub const PanelModule = union(enum) {
    /// Run an external TUI program in a PTY (lazygit, lazydocker, htop, etc.)
    program: []const u8,

    /// Interactive menu with sections (Apps, Favorites, Recent Commands).
    /// Keyboard navigable with Nerd Font icons. Selecting an app launches it.
    menu: void,

    // Future modules:
    // file_browser: void,
    // ai_chat: void,

    /// Get a human-readable name for this module (used as panel identifier)
    pub fn name(self: PanelModule) []const u8 {
        return switch (self) {
            .program => |prog| prog,
            .menu => "panel",
        };
    }

    /// Parse a module spec string. Format: "module_type:args"
    /// e.g. "program:lazygit", "menu"
    pub fn parse(spec: []const u8) ?PanelModule {
        // "menu" = the interactive menu panel
        if (std.mem.eql(u8, spec, "menu") or std.mem.eql(u8, spec, "panel")) {
            return .menu;
        }

        // Check for "program:xxx" format
        if (std.mem.startsWith(u8, spec, "program:")) {
            const prog = spec["program:".len..];
            if (prog.len > 0) return .{ .program = prog };
            return null;
        }

        // Bare name = treat as program name for convenience
        // e.g. "lazygit" is shorthand for "program:lazygit"
        if (spec.len > 0) return .{ .program = spec };

        return null;
    }
};

/// Main Panel GUI state. One instance per active panel on a Ghostty surface.
pub const PanelGui = struct {
    const Self = @This();

    alloc: Allocator,

    /// The module this panel is running
    module: PanelModule,

    /// Human-readable name (owned copy, used for lookup)
    name: []const u8,

    /// I/O thread managing the PTY process (program module only)
    io: ?*IoThread = null,

    /// Output queue (I/O thread writes PTY output, render thread drains)
    output_queue: OutputQueue,

    /// Rendered cell grid for the panel content
    panel: ?*RenderedPanel = null,

    /// Menu state (menu module only)
    menu: ?*Menu = null,

    /// Panel position (side/bottom)
    position: PanelPosition = .right,

    /// Panel size as a fraction of the surface (0.0 to 1.0)
    /// For side panels: fraction of width. For top/bottom: fraction of height.
    size_fraction: f32 = 0.35,

    /// Minimum size fraction (can't drag smaller than this)
    min_size_fraction: f32 = 0.15,
    /// Maximum size fraction (can't drag larger than this)
    max_size_fraction: f32 = 0.85,

    /// Slide animation state
    slide: SlideAnimation = .{},

    /// Drag resize spring (position = offset from target fraction)
    drag_spring: CriticallyDampedSpring = .{},
    /// Whether the user is currently dragging the resize handle
    dragging: bool = false,
    /// Last drag position (for computing deltas)
    drag_last_x: f32 = 0,
    drag_last_y: f32 = 0,
    /// The drag handle width in pixels
    drag_handle_width: f32 = 6.0,

    /// Scroll animation for content within the panel
    scroll_spring: CriticallyDampedSpring = .{},
    /// Sub-pixel scroll offset for smooth scrolling within the panel
    scroll_pixel_offset: f32 = 0,

    /// Cell dimensions (set from the surface's font metrics)
    cell_width: f32 = 0,
    cell_height: f32 = 0,

    /// Surface dimensions in pixels
    surface_width: f32 = 0,
    surface_height: f32 = 0,

    /// Panel grid dimensions (cols x rows, computed from size + cell dims)
    grid_cols: u32 = 0,
    grid_rows: u32 = 0,

    /// Dirty flag - panel content or animation changed, needs render
    dirty: bool = true,

    /// Panel has been initialized and is ready
    ready: bool = false,

    /// The child process exited
    exited: bool = false,

    /// Whether the panel currently has keyboard focus
    focused: bool = false,

    /// Corner radius for the panel border (pixels) - Apple-style rounded corners
    corner_radius: f32 = 12.0,

    /// Background color for the panel border/gap area
    border_color: u32 = 0x313244,

    /// Cached theme palette for applying to menus created after setThemeColors
    theme_colors: ?struct { bg: u32, fg: u32, palette: [16]u32 } = null,

    /// Opaque pointer to renderer wakeup (same pattern as neovim_gui)
    render_wakeup_ptr: ?*anyopaque = null,
    render_wakeup_notify: ?*const fn (*anyopaque) void = null,

    pub fn init(alloc: Allocator, module: PanelModule, position: PanelPosition) !*Self {
        const self = try alloc.create(Self);
        const owned_name = try alloc.dupe(u8, module.name());
        self.* = .{
            .alloc = alloc,
            .module = switch (module) {
                .program => |prog| .{ .program = try alloc.dupe(u8, prog) },
                .menu => .menu,
            },
            .name = owned_name,
            .output_queue = OutputQueue.init(alloc),
            .position = position,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.io) |io| io.deinit();
        if (self.panel) |p| p.deinit();
        if (self.menu) |m| m.deinit();
        self.output_queue.deinit();
        switch (self.module) {
            .program => |prog| self.alloc.free(prog),
            .menu => {},
        }
        self.alloc.free(self.name);
        self.alloc.destroy(self);
    }

    /// Set theme colors from the terminal's palette. Call before or after spawn.
    pub fn setThemeColors(self: *Self, bg: u32, fg: u32, palette: [16]u32) void {
        const theme = Theme.fromPalette(bg, fg, palette);
        if (self.menu) |m| {
            m.theme = theme;
            m.dirty = true;
        }
        // Update rendered panel default colors
        if (self.panel) |p| {
            p.default_bg = bg;
            p.default_fg = fg;
        }
        // Update border color to match theme
        self.border_color = Theme.blend(bg, fg, 10);
        // Store for menus created later
        self.theme_colors = .{ .bg = bg, .fg = fg, .palette = palette };
    }

    /// Launch the panel module. For program modules, this spawns the PTY process.
    /// Call this after setting cell_width/cell_height/surface dimensions.
    pub fn spawn(self: *Self, cwd: ?[]const u8) !void {
        self.computeGridSize();

        if (self.grid_cols == 0 or self.grid_rows == 0) {
            log.err("panel grid size is 0, cannot spawn", .{});
            return error.InvalidGridSize;
        }

        log.info("spawning panel: name={s} module={s} grid={}x{} position={s}", .{
            self.name,
            @tagName(self.module),
            self.grid_cols,
            self.grid_rows,
            @tagName(self.position),
        });

        // Create the rendered panel (cell grid + VT parser)
        self.panel = try RenderedPanel.init(self.alloc, self.grid_cols, self.grid_rows);

        switch (self.module) {
            .program => |program| {
                // Create and start the I/O thread for external TUI program
                self.io = try IoThread.init(self.alloc, &self.output_queue);
                errdefer {
                    self.io.?.deinit();
                    self.io = null;
                }

                try self.io.?.spawn(program, @intCast(self.grid_cols), @intCast(self.grid_rows), cwd);

                // Wire up render wakeup
                if (self.render_wakeup_ptr) |ptr| {
                    if (self.render_wakeup_notify) |notify_fn| {
                        self.io.?.setRenderWakeup(ptr, notify_fn);
                    }
                }

                try self.io.?.start();
            },
            .menu => {
                // Create the interactive menu (no PTY needed)
                self.menu = try Menu.init(self.alloc);
                // Apply cached theme if available
                if (self.theme_colors) |tc| {
                    self.menu.?.theme = Theme.fromPalette(tc.bg, tc.fg, tc.palette);
                    if (self.panel) |panel_p| {
                        panel_p.default_bg = tc.bg;
                        panel_p.default_fg = tc.fg;
                    }
                }
                // Render initial menu content into the cell grid
                if (self.panel) |p| {
                    self.menu.?.render(p);
                }
            },
        }

        self.ready = true;

        // Start the slide-in animation
        self.slide.open();
    }

    /// Toggle the panel open/closed with animation
    pub fn toggle(self: *Self) void {
        self.slide.toggle();
        self.dirty = true;

        // If closing and fully closed, we could clean up the process
        // But we keep it alive so toggle back is instant
    }

    /// Open the panel (if closed)
    pub fn open(self: *Self) void {
        if (!self.slide.isOpen()) {
            self.slide.open();
            self.dirty = true;
        }
    }

    /// Close the panel (if open)
    pub fn close(self: *Self) void {
        if (self.slide.isOpen()) {
            self.slide.close();
            self.dirty = true;
        }
    }

    /// Process pending output. For program modules, drains the PTY queue.
    /// For menu modules, re-renders if dirty.
    /// Called from render thread, non-blocking.
    pub fn processOutput(self: *Self) !void {
        if (!self.ready) return;

        switch (self.module) {
            .program => {
                // Check if child exited
                if (self.io) |io| {
                    if (io.exited.load(.acquire)) {
                        self.exited = true;
                        self.dirty = true;
                    }
                }

                // Drain output queue and feed to VT parser
                if (try self.output_queue.drain(self.alloc)) |data| {
                    defer self.alloc.free(data);
                    if (self.panel) |panel| {
                        panel.processOutput(data);
                        self.dirty = true;
                    }
                }
            },
            .menu => {
                // Re-render menu into cell grid if dirty
                if (self.menu) |menu| {
                    if (menu.dirty) {
                        if (self.panel) |p| {
                            menu.render(p);
                            self.dirty = true;
                        }
                    }

                    // Check for pending actions from menu
                    if (menu.pending_action) |action| {
                        var clear_action = true;
                        switch (action) {
                            .close => {
                                self.close();
                            },
                            .run_command => {
                                // Surface layer reads this and sends to terminal.
                                // Don't clear here.
                                clear_action = false;
                            },
                            .toggle_favorite => {
                                // Already handled in menu.handleKey
                            },
                            .toggle_dir => {
                                // Already handled in menu.selectItem
                            },
                            .open_file => {
                                // Surface layer reads this and handles it.
                                clear_action = false;
                            },
                        }
                        if (clear_action) {
                            menu.pending_action = null;
                        }
                    }
                }
            },
        }
    }

    /// Animate the panel. Returns true if still animating (needs more frames).
    pub fn animate(self: *Self, dt: f32) bool {
        var animating = false;

        if (self.slide.update(dt)) {
            animating = true;
            self.dirty = true;
        }

        if (self.drag_spring.update(dt, 0.15)) {
            animating = true;
            self.dirty = true;
        }

        if (self.scroll_spring.update(dt, 0.2)) {
            self.scroll_pixel_offset = self.scroll_spring.position * self.cell_height;
            animating = true;
            self.dirty = true;
        }

        // Menu scroll animation
        if (self.menu) |menu| {
            if (menu.animate(dt)) {
                animating = true;
                self.dirty = true;
            }
        }

        return animating;
    }

    /// Send a key event to the panel. Routes to PTY (program) or menu handler.
    pub fn sendKey(self: *Self, key_data: []const u8) !void {
        if (!self.ready) return;

        switch (self.module) {
            .program => {
                const io = self.io orelse return;
                if (self.exited) return;
                try io.writeInput(key_data);
            },
            .menu => {
                if (self.menu) |menu| {
                    _ = menu.handleKey(key_data);
                    self.dirty = true;
                }
            },
        }
    }

    /// Transition from menu mode to running a program.
    /// Tears down the menu, switches the module to .program, and spawns the PTY.
    fn transitionToProgram(self: *Self, program: []const u8) !void {
        log.info("panel transitioning from menu to program: {s}", .{program});

        // Clean up menu
        if (self.menu) |m| {
            m.deinit();
            self.menu = null;
        }

        // Clear the cell grid
        if (self.panel) |p| {
            for (p.cells) |*cell| cell.clear();
        }

        // Switch module to program
        const owned_prog = try self.alloc.dupe(u8, program);
        self.module = .{ .program = owned_prog };

        // Update name
        self.alloc.free(self.name);
        self.name = try self.alloc.dupe(u8, program);

        // Spawn the PTY
        self.io = try IoThread.init(self.alloc, &self.output_queue);
        errdefer {
            self.io.?.deinit();
            self.io = null;
        }

        try self.io.?.spawn(program, @intCast(self.grid_cols), @intCast(self.grid_rows), null);

        if (self.render_wakeup_ptr) |ptr| {
            if (self.render_wakeup_notify) |notify_fn| {
                self.io.?.setRenderWakeup(ptr, notify_fn);
            }
        }

        try self.io.?.start();
        self.exited = false;
        self.dirty = true;
    }

    /// Resize the panel (called when surface size changes or drag resize)
    pub fn updateSurfaceSize(self: *Self, width: f32, height: f32, cell_w: f32, cell_h: f32) !void {
        self.surface_width = width;
        self.surface_height = height;
        self.cell_width = cell_w;
        self.cell_height = cell_h;

        const old_cols = self.grid_cols;
        const old_rows = self.grid_rows;
        self.computeGridSize();

        if (self.grid_cols != old_cols or self.grid_rows != old_rows) {
            if (self.panel) |panel| {
                try panel.resize(self.grid_cols, self.grid_rows);
            }
            if (self.io) |io| {
                try io.resize(@intCast(self.grid_cols), @intCast(self.grid_rows));
            }
            // Re-render menu after resize
            if (self.menu) |menu| {
                if (self.panel) |p| {
                    menu.render(p);
                }
            }
            self.dirty = true;
        }
    }

    /// Compute grid dimensions from surface size, position, and size fraction
    fn computeGridSize(self: *Self) void {
        if (self.cell_width == 0 or self.cell_height == 0) return;

        switch (self.position) {
            .left, .right => {
                const panel_width_px = self.surface_width * self.size_fraction;
                self.grid_cols = @intFromFloat(@max(1, @floor(panel_width_px / self.cell_width)));
                self.grid_rows = @intFromFloat(@max(1, @floor(self.surface_height / self.cell_height)));
            },
            .top, .bottom => {
                const panel_height_px = self.surface_height * self.size_fraction;
                self.grid_cols = @intFromFloat(@max(1, @floor(self.surface_width / self.cell_width)));
                self.grid_rows = @intFromFloat(@max(1, @floor(panel_height_px / self.cell_height)));
            },
        }
    }

    /// Get the panel's pixel rectangle on the surface, accounting for slide animation.
    /// Returns (x, y, width, height) in surface pixels.
    pub fn getPanelRect(self: *const Self) struct { x: f32, y: f32, w: f32, h: f32 } {
        const progress = self.slide.progress;

        return switch (self.position) {
            .right => {
                const panel_w = self.surface_width * self.size_fraction;
                const x = self.surface_width - (panel_w * progress);
                return .{
                    .x = x,
                    .y = 0,
                    .w = panel_w,
                    .h = self.surface_height,
                };
            },
            .left => {
                const panel_w = self.surface_width * self.size_fraction;
                const x = -(panel_w * (1.0 - progress));
                return .{
                    .x = x,
                    .y = 0,
                    .w = panel_w,
                    .h = self.surface_height,
                };
            },
            .bottom => {
                const panel_h = self.surface_height * self.size_fraction;
                const y = self.surface_height - (panel_h * progress);
                return .{
                    .x = 0,
                    .y = y,
                    .w = self.surface_width,
                    .h = panel_h,
                };
            },
            .top => {
                const panel_h = self.surface_height * self.size_fraction;
                const y = -(panel_h * (1.0 - progress));
                return .{
                    .x = 0,
                    .y = y,
                    .w = self.surface_width,
                    .h = panel_h,
                };
            },
        };
    }

    /// Get the terminal's adjusted rectangle (shrinks to make room for the panel).
    /// Returns the fraction of the surface the terminal should occupy (0 to 1).
    pub fn getTerminalFraction(self: *const Self) f32 {
        return 1.0 - (self.size_fraction * self.slide.progress);
    }

    /// Check if a screen position (pixels) is within the panel area
    pub fn hitTest(self: *const Self, screen_x: f32, screen_y: f32) bool {
        const rect = self.getPanelRect();
        return screen_x >= rect.x and screen_x < rect.x + rect.w and
            screen_y >= rect.y and screen_y < rect.y + rect.h;
    }

    /// Check if a screen position is on the drag handle
    pub fn hitTestDragHandle(self: *const Self, screen_x: f32, screen_y: f32) bool {
        const rect = self.getPanelRect();
        const hw = self.drag_handle_width;

        return switch (self.position) {
            .right => screen_x >= rect.x - hw and screen_x < rect.x + hw and
                screen_y >= rect.y and screen_y < rect.y + rect.h,
            .left => {
                const edge = rect.x + rect.w;
                return screen_x >= edge - hw and screen_x < edge + hw and
                    screen_y >= rect.y and screen_y < rect.y + rect.h;
            },
            .bottom => screen_x >= rect.x and screen_x < rect.x + rect.w and
                screen_y >= rect.y - hw and screen_y < rect.y + hw,
            .top => {
                const edge = rect.y + rect.h;
                return screen_x >= rect.x and screen_x < rect.x + rect.w and
                    screen_y >= edge - hw and screen_y < edge + hw;
            },
        };
    }

    /// Handle drag resize. `delta` is in pixels along the relevant axis.
    pub fn handleDragResize(self: *Self, delta_x: f32, delta_y: f32) void {
        const delta_fraction = switch (self.position) {
            .right => -delta_x / self.surface_width,
            .left => delta_x / self.surface_width,
            .bottom => -delta_y / self.surface_height,
            .top => delta_y / self.surface_height,
        };

        self.size_fraction = std.math.clamp(
            self.size_fraction + delta_fraction,
            self.min_size_fraction,
            self.max_size_fraction,
        );
        self.dirty = true;
    }

    pub fn setRenderWakeup(self: *Self, wakeup_ptr: *anyopaque, notify_fn: *const fn (*anyopaque) void) void {
        self.render_wakeup_ptr = wakeup_ptr;
        self.render_wakeup_notify = notify_fn;
        if (self.io) |io| {
            io.setRenderWakeup(wakeup_ptr, notify_fn);
        }
    }

    pub fn triggerRenderWakeup(self: *Self) void {
        if (self.render_wakeup_ptr) |ptr| {
            if (self.render_wakeup_notify) |notify_fn| {
                notify_fn(ptr);
            }
        }
    }

    pub fn isDirty(self: *const Self) bool {
        return self.dirty;
    }

    pub fn clearDirty(self: *Self) void {
        self.dirty = false;
    }

    /// Whether the panel is visible (open or animating)
    pub fn isVisible(self: *const Self) bool {
        return self.slide.progress > 0.01;
    }

    /// Whether the panel is fully open (done animating in)
    pub fn isFullyOpen(self: *const Self) bool {
        return self.slide.isFullyOpen();
    }
};

test "PanelModule parse" {
    const m1 = PanelModule.parse("program:lazygit").?;
    try std.testing.expectEqualStrings("lazygit", m1.name());

    const m2 = PanelModule.parse("lazydocker").?;
    try std.testing.expectEqualStrings("lazydocker", m2.name());

    const m3 = PanelModule.parse("menu").?;
    try std.testing.expectEqualStrings("panel", m3.name());
    try std.testing.expect(m3 == .menu);

    const m4 = PanelModule.parse("panel").?;
    try std.testing.expect(m4 == .menu);

    try std.testing.expect(PanelModule.parse("") == null);
}

test "PanelGui init/deinit" {
    const alloc = std.testing.allocator;
    const p = try PanelGui.init(alloc, .{ .program = "lazygit" }, .right);
    defer p.deinit();

    try std.testing.expectEqualStrings("lazygit", p.name);
    try std.testing.expect(p.position == .right);
}

test "PanelGui panel rect right" {
    const alloc = std.testing.allocator;
    const p = try PanelGui.init(alloc, .{ .program = "lazygit" }, .right);
    defer p.deinit();

    p.surface_width = 1000;
    p.surface_height = 600;
    p.size_fraction = 0.4;
    p.slide.progress = 1.0;
    p.slide.target = 1.0;

    const rect = p.getPanelRect();
    try std.testing.expect(rect.x == 600.0);
    try std.testing.expect(rect.w == 400.0);
    try std.testing.expect(rect.h == 600.0);
}

test "PanelGui panel rect bottom" {
    const alloc = std.testing.allocator;
    const p = try PanelGui.init(alloc, .{ .program = "lazydocker" }, .bottom);
    defer p.deinit();

    p.surface_width = 1000;
    p.surface_height = 600;
    p.size_fraction = 0.3;
    p.slide.progress = 1.0;
    p.slide.target = 1.0;

    const rect = p.getPanelRect();
    try std.testing.expect(rect.y == 420.0);
    try std.testing.expect(rect.w == 1000.0);
    try std.testing.expect(rect.h == 180.0);
}
