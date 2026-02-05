const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const wuffs = @import("wuffs");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const inputpkg = @import("../input.zig");
const os = @import("../os/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const Surface = @import("../Surface.zig");
const link = @import("link.zig");
const cellpkg = @import("cell.zig");
const noMinContrast = cellpkg.noMinContrast;
const constraintWidth = cellpkg.constraintWidth;
const isCovering = cellpkg.isCovering;
const rowNeverExtendBg = @import("row.zig").neverExtendBg;
const Overlay = @import("Overlay.zig");
const imagepkg = @import("image.zig");
const ImageState = imagepkg.State;
const shadertoy = @import("shadertoy.zig");
const animation = @import("../animation.zig");
const neovim_gui = @import("../neovim_gui/main.zig");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Terminal = terminal.Terminal;
const Health = renderer.Health;

const getConstraint = @import("../font/nerd_font_attributes.zig").getConstraint;

const FileType = @import("../file_type.zig").FileType;

const macos = switch (builtin.os.tag) {
    .macos => @import("macos"),
    else => void,
};

const DisplayLink = switch (builtin.os.tag) {
    .macos => *macos.video.DisplayLink,
    else => void,
};

const log = std.log.scoped(.generic_renderer);

/// Create a renderer type with the provided graphics API wrapper.
///
/// The graphics API wrapper must provide the interface outlined below.
/// Specific details for the interfaces are documented on the existing
/// implementations (`Metal` and `OpenGL`).
///
/// Hierarchy of graphics abstractions:
///
/// [ GraphicsAPI ] - Responsible for configuring the runtime surface
///    |     |        and providing render `Target`s that draw to it,
///    |     |        as well as `Frame`s and `Pipeline`s.
///    |     V
///    | [ Target ] - Represents an abstract target for rendering, which
///    |              could be a surface directly but is also used as an
///    |              abstraction for off-screen frame buffers.
///    V
/// [ Frame ] - Represents the context for drawing a given frame,
///    |        provides `RenderPass`es for issuing draw commands
///    |        to, and reports the frame health when complete.
///    V
/// [ RenderPass ] - Represents a render pass in a frame, consisting of
///   :              one or more `Step`s applied to the same target(s),
/// [ Step ] - - - - each describing the input buffers and textures and
///   :              the vertex/fragment functions and geometry to use.
///   :_ _ _ _ _ _ _ _ _ _/
///   v
/// [ Pipeline ] - Describes a vertex and fragment function to be used
///                for a `Step`; the `GraphicsAPI` is responsible for
///                these and they should be constructed and cached
///                ahead of time.
///
/// [ Buffer ] - An abstraction over a GPU buffer.
///
/// [ Texture ] - An abstraction over a GPU texture.
///
pub fn Renderer(comptime GraphicsAPI: type) type {
    return struct {
        const Self = @This();

        pub const API = GraphicsAPI;

        const Target = GraphicsAPI.Target;
        const Buffer = GraphicsAPI.Buffer;
        const Sampler = GraphicsAPI.Sampler;
        const Texture = GraphicsAPI.Texture;
        const RenderPass = GraphicsAPI.RenderPass;

        const shaderpkg = GraphicsAPI.shaders;
        const Shaders = shaderpkg.Shaders;

        /// Allocator that can be used
        alloc: std.mem.Allocator,

        /// This mutex must be held whenever any state used in `drawFrame` is
        /// being modified, and also when it's being accessed in `drawFrame`.
        draw_mutex: std.Thread.Mutex = .{},

        /// The configuration we need derived from the main config.
        config: DerivedConfig,

        /// The mailbox for communicating with the window.
        surface_mailbox: apprt.surface.Mailbox,

        /// Current font metrics defining our grid.
        grid_metrics: font.Metrics,

        /// The size of everything.
        size: renderer.Size,

        /// True if the window is focused
        focused: bool,

        /// Flag to indicate that our focus state changed for custom
        /// shaders to update their state.
        custom_shader_focused_changed: bool = false,

        /// The most recent scrollbar state. We use this as a cache to
        /// determine if we need to notify the apprt that there was a
        /// scrollbar change.
        scrollbar: terminal.Scrollbar,
        scrollbar_dirty: bool,

        /// The most recent viewport matches so that we can render search
        /// matches in the visible frame. This is provided asynchronously
        /// from the search thread so we have the dirty flag to also note
        /// if we need to rebuild our cells to include search highlights.
        ///
        /// Note that the selections MAY BE INVALID (point to PageList nodes
        /// that do not exist anymore). These must be validated prior to use.
        search_matches: ?renderer.Message.SearchMatches,
        search_selected_match: ?renderer.Message.SearchMatch,
        search_matches_dirty: bool,

        /// The current set of cells to render. This is rebuilt on every frame
        /// but we keep this around so that we don't reallocate. Each set of
        /// cells goes into a separate shader.
        cells: cellpkg.Contents,

        /// Set to true after rebuildCells is called. This can be used
        /// to determine if any possible changes have been made to the
        /// cells for the draw call.
        cells_rebuilt: bool = false,

        /// The current GPU uniform values.
        uniforms: shaderpkg.Uniforms,

        /// Custom shader uniform values.
        custom_shader_uniforms: shadertoy.Uniforms,

        /// Timestamp we rendered out first frame.
        ///
        /// This is used when updating custom shader uniforms.
        first_frame_time: ?std.time.Instant = null,

        /// Timestamp when we rendered out more recent frame.
        ///
        /// This is used when updating custom shader uniforms.
        last_frame_time: ?std.time.Instant = null,

        /// The font structures.
        font_grid: *font.SharedGrid,
        font_shaper: font.Shaper,
        font_shaper_cache: font.ShaperCache,

        /// The images that we may render.
        images: ImageState = .empty,

        /// Background image, if we have one.
        bg_image: ?imagepkg.Image = null,
        /// Set whenever the background image changes, signalling
        /// that the new background image needs to be uploaded to
        /// the GPU.
        ///
        /// This is initialized as true so that we load the image
        /// on renderer initialization, not just on config change.
        bg_image_changed: bool = true,
        /// Background image vertex buffer.
        bg_image_buffer: shaderpkg.BgImage,
        /// This value is used to force-update the swap chain copy
        /// of the background image buffer whenever we change it.
        bg_image_buffer_modified: usize = 0,

        /// Graphics API state.
        api: GraphicsAPI,

        /// The CVDisplayLink used to drive the rendering loop in
        /// sync with the display. This is void on platforms that
        /// don't support a display link.
        display_link: ?DisplayLink = null,

        /// Health of the most recently completed frame.
        health: std.atomic.Value(Health) = .{ .raw = .healthy },

        /// Our swap chain (multiple buffering)
        swap_chain: SwapChain,

        /// Cursor animation state for smooth cursor movement.
        cursor_animation: animation.CursorAnimation = .{},

        /// Corner-based cursor animation (Neovide-style stretchy cursor)
        corner_cursor: animation.CornerCursorAnimation = animation.CornerCursorAnimation.init(),

        /// Last known cursor grid position (for detecting cursor movement)
        /// Initialize to maxInt so first real position triggers a snap
        last_cursor_grid_pos: [2]u16 = .{ std.math.maxInt(u16), std.math.maxInt(u16) },

        /// Last known scroll position (for detecting scroll changes)
        last_cursor_scroll_pos: f32 = 0,

        /// Last cursor shape (for detecting shape changes)
        last_cursor_shape: ?neovim_gui.CursorShape = null,

        /// Whether cursor animation is currently active (needs continuous render)
        cursor_animating: bool = false,

        /// Scroll animation spring for smooth scrolling (position = offset in pixels from target)
        scroll_spring: animation.Spring = .{},

        /// Whether scroll animation is currently active
        scroll_animating: bool = false,

        /// Accumulated scroll offset in pixels (for sub-line input)
        scroll_pixel_offset: f32 = 0,

        /// Whether we're currently in the alternate screen (TUI apps like Neovim).
        in_alternate_screen: bool = false,

        /// This value is used to force-update swap chain targets in the
        /// event of a config change that requires it (such as blending mode).
        target_config_modified: usize = 0,

        /// If something happened that requires us to reinitialize our shaders,
        /// this is set to true so that we can do that whenever possible.
        reinitialize_shaders: bool = false,

        /// Whether or not we have custom shaders.
        has_custom_shaders: bool = false,

        /// Our shader pipelines.
        shaders: Shaders,

        /// The render state we update per loop.
        terminal_state: terminal.RenderState = .empty,

        /// Neovim GUI mode state. When set, the renderer reads from Neovim
        /// windows instead of terminal_state.
        nvim_gui: ?*neovim_gui.NeovimGui = null,

        /// The number of frames since the last terminal state reset.
        /// We reset the terminal state after ~100,000 frames (about 10 to
        /// 15 minutes at 120Hz) to prevent wasted memory buildup from
        /// a large screen.
        terminal_state_frame_count: usize = 0,

        /// Our overlay state, if any.
        overlay: ?Overlay = null,

        const HighlightTag = enum(u8) {
            search_match,
            search_match_selected,
        };
        /// Swap chain which maintains multiple copies of the state needed to
        /// render a frame, so that we can start building the next frame while
        /// the previous frame is still being processed on the GPU.
        const SwapChain = struct {
            // The count of buffers we use for double/triple buffering.
            // If this is one then we don't do any double+ buffering at all.
            // This is comptime because there isn't a good reason to change
            // this at runtime and there is a lot of complexity to support it.
            const buf_count = GraphicsAPI.swap_chain_count;

            /// `buf_count` structs that can hold the
            /// data needed by the GPU to draw a frame.
            frames: [buf_count]FrameState,
            /// Index of the most recently used frame state struct.
            frame_index: std.math.IntFittingRange(0, buf_count) = 0,
            /// Semaphore that we wait on to make sure we have an available
            /// frame state struct so we can start working on a new frame.
            frame_sema: std.Thread.Semaphore = .{ .permits = buf_count },

            /// Set to true when deinited, if you try to deinit a defunct
            /// swap chain it will just be ignored, to prevent double-free.
            ///
            /// This is required because of `displayUnrealized`, since it
            /// `deinits` the swapchain, which leads to a double-free if
            /// the renderer is deinited after that.
            defunct: bool = false,

            pub fn init(api: GraphicsAPI, custom_shaders: bool) !SwapChain {
                var result: SwapChain = .{ .frames = undefined };

                // Initialize all of our frame state.
                for (&result.frames) |*frame| {
                    frame.* = try FrameState.init(api, custom_shaders);
                }

                return result;
            }

            pub fn deinit(self: *SwapChain) void {
                if (self.defunct) return;
                self.defunct = true;

                // Wait for all of our inflight draws to complete
                // so that we can cleanly deinit our GPU state.
                for (0..buf_count) |_| self.frame_sema.wait();
                for (&self.frames) |*frame| frame.deinit();
            }

            /// Get the next frame state to draw to. This will wait on the
            /// semaphore to ensure that the frame is available. This must
            /// always be paired with a call to releaseFrame.
            pub fn nextFrame(self: *SwapChain) error{Defunct}!*FrameState {
                if (self.defunct) return error.Defunct;

                self.frame_sema.wait();
                errdefer self.frame_sema.post();
                self.frame_index = (self.frame_index + 1) % buf_count;
                return &self.frames[self.frame_index];
            }

            /// This should be called when the frame has completed drawing.
            pub fn releaseFrame(self: *SwapChain) void {
                self.frame_sema.post();
            }
        };

        /// State we need duplicated for every frame. Any state that could be
        /// in a data race between the GPU and CPU while a frame is being drawn
        /// should be in this struct.
        ///
        /// While a draw is in-process, we "lock" the state (via a semaphore)
        /// and prevent the CPU from updating the state until our graphics API
        /// reports that the frame is complete.
        ///
        /// This is used to implement double/triple buffering.
        const FrameState = struct {
            uniforms: UniformBuffer,
            uniforms_cursor: UniformBuffer,
            cells: CellTextBuffer,
            cells_bg: CellBgBuffer,

            grayscale: Texture,
            grayscale_modified: usize = 0,
            color: Texture,
            color_modified: usize = 0,

            target: Target,
            /// See property of same name on Renderer for explanation.
            target_config_modified: usize = 0,

            /// Buffer with the vertex data for our background image.
            ///
            /// TODO: Make this an optional and only create it
            ///       if we actually have a background image.
            bg_image_buffer: BgImageBuffer,
            /// See property of same name on Renderer for explanation.
            bg_image_buffer_modified: usize = 0,

            /// Custom shader state, this is null if we have no custom shaders.
            custom_shader_state: ?CustomShaderState = null,

            const UniformBuffer = Buffer(shaderpkg.Uniforms);
            const CellBgBuffer = Buffer(shaderpkg.CellBg);
            const CellTextBuffer = Buffer(shaderpkg.CellText);
            const BgImageBuffer = Buffer(shaderpkg.BgImage);

            pub fn init(api: GraphicsAPI, custom_shaders: bool) !FrameState {
                // Uniform buffer contains exactly 1 uniform struct. The
                // uniform data will be undefined so this must be set before
                // a frame is drawn.
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();

                // Second uniform buffer for cursor pass (with different flags)
                var uniforms_cursor = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms_cursor.deinit();

                // Create GPU buffers for our cells.
                //
                // We start them off with a size of 1, which will of course be
                // too small, but they will be resized as needed. This is a bit
                // wasteful but since it's a one-time thing it's not really a
                // huge concern.
                var cells = try CellTextBuffer.init(api.fgBufferOptions(), 1);
                errdefer cells.deinit();
                var cells_bg = try CellBgBuffer.init(api.bgBufferOptions(), 1);
                errdefer cells_bg.deinit();

                // Create a GPU buffer for our background image info.
                var bg_image_buffer = try BgImageBuffer.init(
                    api.bgImageBufferOptions(),
                    1,
                );
                errdefer bg_image_buffer.deinit();

                // Initialize our textures for our font atlas.
                //
                // As with the buffers above, we start these off as small
                // as possible since they'll inevitably be resized anyway.
                const grayscale = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .grayscale,
                });
                errdefer grayscale.deinit();
                const color = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .bgra,
                });
                errdefer color.deinit();

                var custom_shader_state =
                    if (custom_shaders)
                        try CustomShaderState.init(api)
                    else
                        null;
                errdefer if (custom_shader_state) |*state| state.deinit();

                // Initialize the target. Just as with the other resources,
                // start it off as small as we can since it'll be resized.
                const target = try api.initTarget(1, 1);

                return .{
                    .uniforms = uniforms,
                    .uniforms_cursor = uniforms_cursor,
                    .cells = cells,
                    .cells_bg = cells_bg,
                    .bg_image_buffer = bg_image_buffer,
                    .grayscale = grayscale,
                    .color = color,
                    .target = target,
                    .custom_shader_state = custom_shader_state,
                };
            }

            pub fn deinit(self: *FrameState) void {
                self.uniforms.deinit();
                self.uniforms_cursor.deinit();
                self.cells.deinit();
                self.cells_bg.deinit();
                self.grayscale.deinit();
                self.color.deinit();
                self.bg_image_buffer.deinit();
                if (self.custom_shader_state) |*state| state.deinit();
            }

            pub fn resize(
                self: *FrameState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                if (self.custom_shader_state) |*state| {
                    try state.resize(api, width, height);
                }
                const target = try api.initTarget(width, height);
                self.target.deinit();
                self.target = target;
            }
        };

        /// State relevant to our custom shaders if we have any.
        const CustomShaderState = struct {
            /// When we have a custom shader state, we maintain a front
            /// and back texture which we use as a swap chain to render
            /// between when multiple custom shaders are defined.
            front_texture: Texture,
            back_texture: Texture,

            /// Shadertoy uses a sampler for accessing the various channel
            /// textures. In Metal, we need to explicitly create these since
            /// the glslang-to-msl compiler doesn't do it for us (as we
            /// normally would in hand-written MSL). To keep it clean and
            /// consistent, we just force all rendering APIs to provide an
            /// explicit sampler.
            ///
            /// Samplers are immutable and describe sampling properties so
            /// we can share the sampler across front/back textures (although
            /// we only need it for the source texture at a time, we don't
            /// need to "swap" it).
            sampler: Sampler,

            uniforms: UniformBuffer,

            const UniformBuffer = Buffer(shadertoy.Uniforms);

            /// Swap the front and back textures.
            pub fn swap(self: *CustomShaderState) void {
                std.mem.swap(Texture, &self.front_texture, &self.back_texture);
            }

            pub fn init(api: GraphicsAPI) !CustomShaderState {
                // Create a GPU buffer to hold our uniforms.
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();

                // Initialize the front and back textures at 1x1 px, this
                // is slightly wasteful but it's only done once so whatever.
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer back_texture.deinit();

                const sampler = try Sampler.init(api.samplerOptions());
                errdefer sampler.deinit();

                return .{
                    .front_texture = front_texture,
                    .back_texture = back_texture,
                    .sampler = sampler,
                    .uniforms = uniforms,
                };
            }

            pub fn deinit(self: *CustomShaderState) void {
                self.front_texture.deinit();
                self.back_texture.deinit();
                self.sampler.deinit();
                self.uniforms.deinit();
            }

            pub fn resize(
                self: *CustomShaderState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer back_texture.deinit();

                self.front_texture.deinit();
                self.back_texture.deinit();

                self.front_texture = front_texture;
                self.back_texture = back_texture;
            }
        };

        /// The configuration for this renderer that is derived from the main
        /// configuration. This must be exported so that we don't need to
        /// pass around Config pointers which makes memory management a pain.
        pub const DerivedConfig = struct {
            arena: ArenaAllocator,

            font_thicken: bool,
            pixel_scroll: bool,
            cursor_animation_duration: f32,
            cursor_animation_bounciness: f32,
            scroll_animation_duration: f32,
            scroll_animation_bounciness: f32,
            font_thicken_strength: u8,
            font_features: std.ArrayListUnmanaged([:0]const u8),
            font_styles: font.CodepointResolver.StyleStatus,
            font_shaping_break: configpkg.FontShapingBreak,
            cursor_color: ?configpkg.Config.TerminalColor,
            cursor_opacity: f64,
            cursor_text: ?configpkg.Config.TerminalColor,
            background: terminal.color.RGB,
            background_opacity: f64,
            background_opacity_cells: bool,
            foreground: terminal.color.RGB,
            selection_background: ?configpkg.Config.TerminalColor,
            selection_foreground: ?configpkg.Config.TerminalColor,
            search_background: configpkg.Config.TerminalColor,
            search_foreground: configpkg.Config.TerminalColor,
            search_selected_background: configpkg.Config.TerminalColor,
            search_selected_foreground: configpkg.Config.TerminalColor,
            bold_color: ?configpkg.BoldColor,
            faint_opacity: u8,
            min_contrast: f32,
            padding_color: configpkg.WindowPaddingColor,
            custom_shaders: configpkg.RepeatablePath,
            bg_image: ?configpkg.Path,
            bg_image_opacity: f32,
            bg_image_position: configpkg.BackgroundImagePosition,
            bg_image_fit: configpkg.BackgroundImageFit,
            bg_image_repeat: bool,
            links: link.Set,
            vsync: bool,
            colorspace: configpkg.Config.WindowColorspace,
            blending: configpkg.Config.AlphaBlending,
            background_blur: configpkg.Config.BackgroundBlur,

            pub fn init(
                alloc_gpa: Allocator,
                config: *const configpkg.Config,
            ) !DerivedConfig {
                var arena = ArenaAllocator.init(alloc_gpa);
                errdefer arena.deinit();
                const alloc = arena.allocator();

                // Copy our shaders
                const custom_shaders = try config.@"custom-shader".clone(alloc);

                // Copy our background image
                const bg_image =
                    if (config.@"background-image") |bg|
                        try bg.clone(alloc)
                    else
                        null;

                // Copy our font features
                const font_features = try config.@"font-feature".clone(alloc);

                // Get our font styles
                var font_styles = font.CodepointResolver.StyleStatus.initFill(true);
                font_styles.set(.bold, config.@"font-style-bold" != .false);
                font_styles.set(.italic, config.@"font-style-italic" != .false);
                font_styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

                // Our link configs
                const links = try link.Set.fromConfig(
                    alloc,
                    config.link.links.items,
                );

                return .{
                    .background_opacity = @max(0, @min(1, config.@"background-opacity")),
                    .background_opacity_cells = config.@"background-opacity-cells",
                    .font_thicken = config.@"font-thicken",
                    .pixel_scroll = config.@"pixel-scroll",
                    .cursor_animation_duration = config.@"cursor-animation-duration",
                    .cursor_animation_bounciness = config.@"cursor-animation-bounciness",
                    .scroll_animation_duration = config.@"scroll-animation-duration",
                    .scroll_animation_bounciness = config.@"scroll-animation-bounciness",
                    .font_thicken_strength = config.@"font-thicken-strength",
                    .font_features = font_features.list,
                    .font_styles = font_styles,
                    .font_shaping_break = config.@"font-shaping-break",

                    .cursor_color = config.@"cursor-color",
                    .cursor_text = config.@"cursor-text",
                    .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),

                    .background = config.background.toTerminalRGB(),
                    .foreground = config.foreground.toTerminalRGB(),
                    .bold_color = config.@"bold-color",
                    .faint_opacity = @intFromFloat(@ceil(config.@"faint-opacity" * 255)),

                    .min_contrast = @floatCast(config.@"minimum-contrast"),
                    .padding_color = config.@"window-padding-color",

                    .selection_background = config.@"selection-background",
                    .selection_foreground = config.@"selection-foreground",
                    .search_background = config.@"search-background",
                    .search_foreground = config.@"search-foreground",
                    .search_selected_background = config.@"search-selected-background",
                    .search_selected_foreground = config.@"search-selected-foreground",

                    .custom_shaders = custom_shaders,
                    .bg_image = bg_image,
                    .bg_image_opacity = config.@"background-image-opacity",
                    .bg_image_position = config.@"background-image-position",
                    .bg_image_fit = config.@"background-image-fit",
                    .bg_image_repeat = config.@"background-image-repeat",
                    .links = links,
                    .vsync = config.@"window-vsync",
                    .colorspace = config.@"window-colorspace",
                    .blending = config.@"alpha-blending",
                    .background_blur = config.@"background-blur",
                    .arena = arena,
                };
            }

            pub fn deinit(self: *DerivedConfig) void {
                const alloc = self.arena.allocator();
                self.links.deinit(alloc);
                self.arena.deinit();
            }
        };

        pub fn init(alloc: Allocator, options: renderer.Options) !Self {
            // Initialize our graphics API wrapper, this will prepare the
            // surface provided by the apprt and set up any API-specific
            // GPU resources.
            var api = try GraphicsAPI.init(alloc, options);
            errdefer api.deinit();

            const has_custom_shaders = options.config.custom_shaders.value.items.len > 0;

            // Prepare our swap chain
            var swap_chain = try SwapChain.init(
                api,
                has_custom_shaders,
            );
            errdefer swap_chain.deinit();

            // Create the font shaper.
            var font_shaper = try font.Shaper.init(alloc, .{
                .features = options.config.font_features.items,
            });
            errdefer font_shaper.deinit();

            // Initialize all the data that requires a critical font section.
            const font_critical: struct {
                metrics: font.Metrics,
            } = font_critical: {
                const grid: *font.SharedGrid = options.font_grid;
                grid.lock.lockShared();
                defer grid.lock.unlockShared();
                break :font_critical .{
                    .metrics = grid.metrics,
                };
            };

            const display_link: ?DisplayLink = switch (builtin.os.tag) {
                .macos => if (options.config.vsync)
                    try macos.video.DisplayLink.createWithActiveCGDisplays()
                else
                    null,
                else => null,
            };
            errdefer if (display_link) |v| v.release();

            var result: Self = .{
                .alloc = alloc,
                .config = options.config,
                .surface_mailbox = options.surface_mailbox,
                .grid_metrics = font_critical.metrics,
                .size = options.size,
                .focused = true,
                .scrollbar = .zero,
                .scrollbar_dirty = false,
                .search_matches = null,
                .search_selected_match = null,
                .search_matches_dirty = false,

                // Render state
                .cells = .{},
                .uniforms = .{
                    .projection_matrix = undefined,
                    .cell_size = undefined,
                    .grid_size = undefined,
                    .grid_padding = undefined,
                    .screen_size = undefined,
                    .padding_extend = .{},
                    .min_contrast = options.config.min_contrast,
                    .cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) },
                    .cursor_color = undefined,
                    .bg_color = .{
                        options.config.background.r,
                        options.config.background.g,
                        options.config.background.b,
                        // Note that if we're on macOS with glass effects
                        // we'll disable background opacity but we handle
                        // that in updateFrame.
                        @intFromFloat(@round(options.config.background_opacity * 255.0)),
                    },
                    .bools = .{
                        .cursor_wide = false,
                        .use_display_p3 = options.config.colorspace == .@"display-p3",
                        .use_linear_blending = options.config.blending.isLinear(),
                        .use_linear_correction = options.config.blending == .@"linear-corrected",
                    },
                },
                .custom_shader_uniforms = .{
                    .resolution = .{ 0, 0, 1 },
                    .time = 0,
                    .time_delta = 0,
                    .frame_rate = 60, // not currently updated
                    .frame = 0,
                    .channel_time = @splat(@splat(0)), // not currently updated
                    .channel_resolution = @splat(@splat(0)),
                    .mouse = @splat(0), // not currently updated
                    .date = @splat(0), // not currently updated
                    .sample_rate = 0, // N/A, we don't have any audio
                    .current_cursor = @splat(0),
                    .previous_cursor = @splat(0),
                    .current_cursor_color = @splat(0),
                    .previous_cursor_color = @splat(0),
                    .cursor_change_time = 0,
                    .time_focus = 0,
                    .focus = 1, // assume focused initially
                    .palette = @splat(@splat(0)),
                    .background_color = @splat(0),
                    .foreground_color = @splat(0),
                    .cursor_color = @splat(0),
                    .cursor_text = @splat(0),
                    .selection_background_color = @splat(0),
                    .selection_foreground_color = @splat(0),
                },
                .bg_image_buffer = undefined,

                // Fonts
                .font_grid = options.font_grid,
                .font_shaper = font_shaper,
                .font_shaper_cache = font.ShaperCache.init(),

                // Shaders (initialized below)
                .shaders = undefined,

                // Graphics API stuff
                .api = api,
                .swap_chain = swap_chain,
                .display_link = display_link,
            };

            try result.initShaders();

            // Ensure our undefined values above are correctly initialized.
            result.updateFontGridUniforms();
            result.updateScreenSizeUniforms();
            result.updateBgImageBuffer();
            try result.prepBackgroundImage();

            return result;
        }

        pub fn deinit(self: *Self) void {
            if (self.overlay) |*overlay| overlay.deinit(self.alloc);
            self.terminal_state.deinit(self.alloc);
            if (self.search_selected_match) |*m| m.arena.deinit();
            if (self.search_matches) |*m| m.arena.deinit();
            self.swap_chain.deinit();

            if (DisplayLink != void) {
                if (self.display_link) |display_link| {
                    display_link.stop() catch {};
                    display_link.release();
                }
            }

            self.cells.deinit(self.alloc);

            self.font_shaper.deinit();
            self.font_shaper_cache.deinit(self.alloc);

            self.config.deinit();

            self.images.deinit(self.alloc);

            if (self.bg_image) |img| img.deinit(self.alloc);

            self.deinitShaders();

            self.api.deinit();

            self.* = undefined;
        }

        fn deinitShaders(self: *Self) void {
            self.shaders.deinit(self.alloc);
        }

        fn initShaders(self: *Self) !void {
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Load our custom shaders
            const custom_shaders: []const [:0]const u8 = shadertoy.loadFromFiles(
                arena_alloc,
                self.config.custom_shaders,
                GraphicsAPI.custom_shader_target,
            ) catch |err| err: {
                log.warn("error loading custom shaders err={}", .{err});
                break :err &.{};
            };

            const has_custom_shaders = custom_shaders.len > 0;

            var shaders = try self.api.initShaders(
                self.alloc,
                custom_shaders,
            );
            errdefer shaders.deinit(self.alloc);

            self.shaders = shaders;
            self.has_custom_shaders = has_custom_shaders;
        }

        /// This is called early right after surface creation.
        pub fn surfaceInit(surface: *apprt.Surface) !void {
            // If our API has to do things here, let it.
            if (@hasDecl(GraphicsAPI, "surfaceInit")) {
                try GraphicsAPI.surfaceInit(surface);
            }
        }

        /// This is called just prior to spinning up the renderer thread for
        /// final main thread setup requirements.
        pub fn finalizeSurfaceInit(self: *Self, surface: *apprt.Surface) !void {
            // If our API has to do things to finalize surface init, let it.
            if (@hasDecl(GraphicsAPI, "finalizeSurfaceInit")) {
                try self.api.finalizeSurfaceInit(surface);
            }
        }

        /// Callback called by renderer.Thread when it begins.
        pub fn threadEnter(self: *const Self, surface: *apprt.Surface) !void {
            // If our API has to do things on thread enter, let it.
            if (@hasDecl(GraphicsAPI, "threadEnter")) {
                try self.api.threadEnter(surface);
            }
        }

        /// Callback called by renderer.Thread when it exits.
        pub fn threadExit(self: *const Self) void {
            // If our API has to do things on thread exit, let it.
            if (@hasDecl(GraphicsAPI, "threadExit")) {
                self.api.threadExit();
            }
        }

        /// Called by renderer.Thread when it starts the main loop.
        pub fn loopEnter(self: *Self, thr: *renderer.Thread) !void {
            // If our API has to do things on loop enter, let it.
            if (@hasDecl(GraphicsAPI, "loopEnter")) {
                self.api.loopEnter();
            }

            // If we don't support a display link we have no work to do.
            if (comptime DisplayLink == void) return;

            // This is when we know our "self" pointer is stable so we can
            // setup the display link. To setup the display link we set our
            // callback and we can start it immediately.
            const display_link = self.display_link orelse return;
            try display_link.setOutputCallback(
                xev.Async,
                &displayLinkCallback,
                &thr.draw_now,
            );
            display_link.start() catch {};
        }

        /// Called by renderer.Thread when it exits the main loop.
        pub fn loopExit(self: *Self) void {
            // If our API has to do things on loop exit, let it.
            if (@hasDecl(GraphicsAPI, "loopExit")) {
                self.api.loopExit();
            }

            // If we don't support a display link we have no work to do.
            if (comptime DisplayLink == void) return;

            // Stop our display link. If this fails its okay it just means
            // that we either never started it or the view its attached to
            // is gone which is fine.
            const display_link = self.display_link orelse return;
            display_link.stop() catch {};
        }

        /// This is called by the GTK apprt after the surface is
        /// reinitialized due to any of the events mentioned in
        /// the doc comment for `displayUnrealized`.
        pub fn displayRealized(self: *Self) !void {
            log.debug("displayRealized called - reinitializing GPU resources", .{});

            // If our API has to do things on realize, let it.
            if (@hasDecl(GraphicsAPI, "displayRealized")) {
                self.api.displayRealized();
            }

            // Lock the draw mutex so that we can
            // safely reinitialize our GPU resources.
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // We assume that the swap chain was deinited in
            // `displayUnrealized`, in which case it should be
            // marked defunct. If not, we have a problem.
            assert(self.swap_chain.defunct);

            // We reinitialize our shaders and our swap chain.
            try self.initShaders();
            self.swap_chain = try SwapChain.init(
                self.api,
                self.has_custom_shaders,
            );
            self.reinitialize_shaders = false;
            self.target_config_modified = 1;

            // Force a full redraw after realize. This is critical for Wayland/Hyprland
            // where window moves (e.g., hy3 layout changes) cause unrealize/realize cycles.
            // Without this, we might try to presentLastTarget with an invalid framebuffer
            // or skip drawing because needs_redraw is false.
            self.markDirty();
            self.cells_rebuilt = true;
            log.debug("displayRealized complete - marked dirty for full redraw", .{});
        }

        /// This is called by the GTK apprt when the surface is being destroyed.
        /// This can happen because the surface is being closed but also when
        /// moving the window between displays or splitting.
        pub fn displayUnrealized(self: *Self) void {
            log.debug("displayUnrealized called - cleaning up GPU resources", .{});

            // If our API has to do things on unrealize, let it.
            if (@hasDecl(GraphicsAPI, "displayUnrealized")) {
                self.api.displayUnrealized();
            }

            // Lock the draw mutex so that we can
            // safely deinitialize our GPU resources.
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // We deinit our swap chain and shaders.
            //
            // This will mark them as defunct so that they
            // can't be double-freed or used in draw calls.
            self.swap_chain.deinit();
            self.shaders.deinit(self.alloc);
        }

        fn displayLinkCallback(
            _: *macos.video.DisplayLink,
            ud: ?*xev.Async,
        ) void {
            const draw_now = ud orelse return;
            draw_now.notify() catch |err| {
                log.err("error notifying draw_now err={}", .{err});
            };
        }

        /// Mark the full screen as dirty so that we redraw everything.
        pub inline fn markDirty(self: *Self) void {
            self.terminal_state.dirty = .full;
        }

        /// Called when we get an updated display ID for our display link.
        pub fn setMacOSDisplayID(self: *Self, id: u32) !void {
            if (comptime DisplayLink == void) return;
            const display_link = self.display_link orelse return;
            log.info("updating display link display id={}", .{id});
            display_link.setCurrentCGDisplay(id) catch |err| {
                log.warn("error setting display link display id err={}", .{err});
            };
        }

        /// True if our renderer has animations so that a higher frequency
        /// timer is used.
        pub fn hasAnimations(self: *const Self) bool {
            // In Neovim GUI mode, always run at high refresh rate for
            // smooth cursor, scrolling, and instant visual feedback
            if (self.nvim_gui != null) return true;
            return self.has_custom_shaders or self.cursor_animating or self.scroll_animating;
        }

        /// True if our renderer is using vsync. If true, the renderer or apprt
        /// is responsible for triggering draw_now calls to the render thread.
        /// That is the only way to trigger a drawFrame.
        pub fn hasVsync(self: *const Self) bool {
            if (comptime DisplayLink == void) return false;
            const display_link = self.display_link orelse return false;
            return display_link.isRunning();
        }

        /// Callback when the focus changes for the terminal this is rendering.
        ///
        /// Must be called on the render thread.
        pub fn setFocus(self: *Self, focus: bool) !void {
            assert(self.focused != focus);

            self.focused = focus;

            // Flag that we need to update our custom shaders
            self.custom_shader_focused_changed = true;

            // When regaining focus, force a full redraw.
            // This fixes black screen issues on Wayland/Hyprland when moving windows
            // or switching tabs, where the compositor may invalidate the surface
            // without triggering a proper resize event.
            if (focus) {
                self.markDirty();
                self.cells_rebuilt = true;
            }

            // If we're not focused, then we want to stop the display link
            // because it is a waste of resources and we can move to pure
            // change-driven updates.
            if (comptime DisplayLink != void) link: {
                const display_link = self.display_link orelse break :link;
                if (focus) {
                    display_link.start() catch {};
                } else {
                    display_link.stop() catch {};
                }
            }
        }

        /// Callback when the window is visible or occluded.
        ///
        /// Must be called on the render thread.
        pub fn setVisible(self: *Self, visible: bool) void {
            // When becoming visible, force a full redraw.
            // This fixes black screen issues on Wayland/Hyprland when the window
            // was occluded and becomes visible again.
            if (visible) {
                self.markDirty();
                self.cells_rebuilt = true;
            }

            // If we're not visible, then we want to stop the display link
            // because it is a waste of resources and we can move to pure
            // change-driven updates.
            if (comptime DisplayLink != void) link: {
                const display_link = self.display_link orelse break :link;
                if (visible and self.focused) {
                    display_link.start() catch {};
                } else {
                    display_link.stop() catch {};
                }
            }
        }

        /// Set the new font grid.
        ///
        /// Must be called on the render thread.
        pub fn setFontGrid(self: *Self, grid: *font.SharedGrid) void {
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // Update our grid
            self.font_grid = grid;

            // Update all our textures so that they sync on the next frame.
            // We can modify this without a lock because the GPU does not
            // touch this data.
            for (&self.swap_chain.frames) |*frame| {
                frame.grayscale_modified = 0;
                frame.color_modified = 0;
            }

            // Get our metrics from the grid. This doesn't require a lock because
            // the metrics are never recalculated.
            const metrics = grid.metrics;
            self.grid_metrics = metrics;

            // Reset our shaper cache. If our font changed (not just the size) then
            // the data in the shaper cache may be invalid and cannot be used, so we
            // always clear the cache just in case.
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;

            // Update cell size.
            self.size.cell = .{
                .width = metrics.cell_width,
                .height = metrics.cell_height,
            };

            // Update relevant uniforms
            self.updateFontGridUniforms();

            // Force a full rebuild, because cached rows may still reference
            // an outdated atlas from the old grid and this can cause garbage
            // to be rendered.
            self.markDirty();
        }

        /// Update uniforms that are based on the font grid.
        ///
        /// Caller must hold the draw mutex.
        fn updateFontGridUniforms(self: *Self) void {
            self.uniforms.cell_size = .{
                @floatFromInt(self.grid_metrics.cell_width),
                @floatFromInt(self.grid_metrics.cell_height),
            };
        }

        /// Update the frame data.
        pub fn updateFrame(
            self: *Self,
            state: *renderer.State,
            cursor_blink_visible: bool,
        ) Allocator.Error!void {
            // const start = std.time.Instant.now() catch unreachable;
            // const start_micro = std.time.microTimestamp();
            // defer {
            //     const end = std.time.Instant.now() catch unreachable;
            //     log.warn(
            //         "[updateFrame time] start_micro={} duration={}ns",
            //         .{ start_micro, end.since(start) / std.time.ns_per_us },
            //     );
            // }

            // Update nvim_gui pointer from state
            self.nvim_gui = state.nvim_gui;

            // If in Neovim GUI mode, use a separate update path
            if (self.nvim_gui) |nvim| {
                // Check if Neovim exited (:q, :qall, etc.) - if so, fall back to terminal
                if (nvim.exited) {
                    log.info("Neovim exited - falling back to regular terminal mode", .{});
                    self.nvim_gui = null;
                    state.nvim_gui = null; // Clear state too so we don't re-enter
                    // Force full terminal state rebuild - cursor position is stale
                    self.terminal_state.deinit(self.alloc);
                    self.terminal_state = .empty;
                    // Reset last cursor position to force animation target update
                    self.last_cursor_grid_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) };
                    // Continue to regular terminal rendering below
                } else {
                    try self.updateFrameNeovim(nvim);
                    return;
                }
            }

            // We fully deinit and reset the terminal state every so often
            // so that a particularly large terminal state doesn't cause
            // the renderer to hold on to retained memory.
            //
            // Frame count is ~12 minutes at 120Hz.
            const max_terminal_state_frame_count = 100_000;
            if (self.terminal_state_frame_count >= max_terminal_state_frame_count) {
                self.terminal_state.deinit(self.alloc);
                self.terminal_state = .empty;
            }
            self.terminal_state_frame_count += 1;

            // Create an arena for all our temporary allocations while rebuilding
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Data we extract out of the critical area.
            const Critical = struct {
                links: terminal.RenderState.CellSet,
                mouse: renderer.State.Mouse,
                preedit: ?renderer.State.Preedit,
                scrollbar: terminal.Scrollbar,
                overlay_features: []const Overlay.Feature,
                tui_in_alternate: bool,
            };

            // Update all our data as tightly as possible within the mutex.
            var critical: Critical = critical: {
                // const start = try std.time.Instant.now();
                // const start_micro = std.time.microTimestamp();
                // defer {
                //     const end = std.time.Instant.now() catch unreachable;
                //     std.log.err("[updateFrame critical time] start={}\tduration={} us", .{ start_micro, end.since(start) / std.time.ns_per_us });
                // }

                state.mutex.lock();
                defer state.mutex.unlock();

                // If we're in a synchronized output state, we pause all rendering.
                if (state.terminal.modes.get(.synchronized_output)) {
                    log.debug("synchronized output started, skipping render", .{});
                    return;
                }

                // Update our terminal state
                try self.terminal_state.update(self.alloc, state.terminal);

                // If our terminal state is dirty at all we need to redo
                // the viewport search.
                if (self.terminal_state.dirty != .false) {
                    state.terminal.flags.search_viewport_dirty = true;
                }

                // Get our scrollbar out of the terminal. We synchronize
                // the scrollbar read with frame data updates because this
                // naturally limits the number of calls to this method (it
                // can be expensive) and also makes it so we don't need another
                // cross-thread mailbox message within the IO path.
                const scrollbar = state.terminal.screens.active.pages.scrollbar();

                // Get our preedit state
                const preedit: ?renderer.State.Preedit = preedit: {
                    const p = state.preedit orelse break :preedit null;
                    break :preedit try p.clone(arena_alloc);
                };

                // If we have Kitty graphics data, we enter a SLOW SLOW SLOW path.
                // We only do this if the Kitty image state is dirty meaning only if
                // it changes.
                //
                // If we have any virtual references, we must also rebuild our
                // kitty state on every frame because any cell change can move
                // an image.
                if (self.images.kittyRequiresUpdate(state.terminal)) {
                    self.images.kittyUpdate(
                        self.alloc,
                        state.terminal,
                        .{
                            .width = self.grid_metrics.cell_width,
                            .height = self.grid_metrics.cell_height,
                        },
                    );
                }

                // Get our OSC8 links we're hovering if we have a mouse.
                // This requires terminal state because of URLs.
                const links: terminal.RenderState.CellSet = osc8: {
                    // If our mouse isn't hovering, we have no links.
                    const vp = state.mouse.point orelse break :osc8 .empty;

                    // If the right mods aren't pressed, then we can't match.
                    if (!state.mouse.mods.equal(inputpkg.ctrlOrSuper(.{})))
                        break :osc8 .empty;

                    break :osc8 self.terminal_state.linkCells(
                        arena_alloc,
                        vp,
                    ) catch |err| {
                        log.warn("error searching for OSC8 links err={}", .{err});
                        break :osc8 .empty;
                    };
                };

                const overlay_features: []const Overlay.Feature = overlay: {
                    const insp = state.inspector orelse break :overlay &.{};
                    const renderer_info = insp.rendererInfo();
                    break :overlay renderer_info.overlayFeatures(
                        arena_alloc,
                    ) catch &.{};
                };

                // Copy mouse state first
                const mouse_copy = state.mouse;
                // Reset scroll delta (we're consuming it)
                state.mouse.scroll_delta_lines = 0;

                const tui_in_alternate = state.terminal.screens.active_key == .alternate;

                break :critical .{
                    .links = links,
                    .mouse = mouse_copy,
                    .preedit = preedit,
                    .scrollbar = scrollbar,
                    .overlay_features = overlay_features,
                    .tui_in_alternate = tui_in_alternate,
                };
            };

            // Outside the critical area we can update our links to contain
            // our regex results.
            self.config.links.renderCellMap(
                arena_alloc,
                &critical.links,
                &self.terminal_state,
                state.mouse.point,
                state.mouse.mods,
            ) catch |err| {
                log.warn("error searching for regex links err={}", .{err});
            };

            // Clear our highlight state and update.
            if (self.search_matches_dirty or self.terminal_state.dirty != .false) {
                self.search_matches_dirty = false;

                // Clear the prior highlights
                const row_data = self.terminal_state.row_data.slice();
                var any_dirty: bool = false;
                for (
                    row_data.items(.highlights),
                    row_data.items(.dirty),
                ) |*highlights, *dirty| {
                    if (highlights.items.len > 0) {
                        highlights.clearRetainingCapacity();
                        dirty.* = true;
                        any_dirty = true;
                    }
                }
                if (any_dirty and self.terminal_state.dirty == .false) {
                    self.terminal_state.dirty = .partial;
                }

                // NOTE: The order below matters. Highlights added earlier
                // will take priority.

                if (self.search_selected_match) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match_selected),
                        &.{m.match},
                    ) catch |err| {
                        // Not a critical error, we just won't show highlights.
                        log.warn("error updating search selected highlight err={}", .{err});
                    };
                }

                if (self.search_matches) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match),
                        m.matches,
                    ) catch |err| {
                        // Not a critical error, we just won't show highlights.
                        log.warn("error updating search highlights err={}", .{err});
                    };
                }
            }

            // From this point forward no more errors.
            errdefer comptime unreachable;

            // Reset our dirty state after updating.
            defer self.terminal_state.dirty = .false;

            // Rebuild the overlay image if we have one. We can do this
            // outside of any critical areas.
            self.rebuildOverlay(
                critical.overlay_features,
            ) catch |err| {
                log.warn(
                    "error rebuilding overlay surface err={}",
                    .{err},
                );
            };

            // Acquire the draw mutex for all remaining state updates.
            {
                self.draw_mutex.lock();
                defer self.draw_mutex.unlock();

                // Build our GPU cells
                self.rebuildCells(
                    critical.preedit,
                    renderer.cursorStyle(&self.terminal_state, .{
                        .preedit = critical.preedit != null,
                        .focused = self.focused,
                        .blink_visible = cursor_blink_visible,
                    }),
                    &critical.links,
                ) catch |err| {
                    // This means we weren't able to allocate our buffer
                    // to update the cells. In this case, we continue with
                    // our old buffer (frozen contents) and log it.
                    comptime assert(@TypeOf(err) == error{OutOfMemory});
                    log.warn("error rebuilding GPU cells err={}", .{err});
                };

                // The scrollbar is only emitted during draws so we also
                // check the scrollbar cache here and update if needed.
                // This is pretty fast.
                if (!self.scrollbar.eql(critical.scrollbar)) {
                    self.scrollbar = critical.scrollbar;
                    self.scrollbar_dirty = true;
                }

                // Update scroll animation state
                // When terminal viewport scrolls by N lines, we get scroll_delta_lines
                // We set the spring to animate from that offset back to 0

                // Scroll jumps (keyboard scrolling in terminal)
                // NOTE: We currently disable spring animation for scroll jumps
                // because it causes edge bounce. The content has already jumped
                // to the new position, and trying to animate the visual offset
                // makes the top/bottom edges move, which looks bad.
                //
                // For proper smooth scroll we'd need frame capture + crossfade.
                // For now, scroll_jump is ignored for animation purposes.
                // (Terminal scrollback with mouse/trackpad still works smoothly)

                // Store the sub-line pixel offset
                self.scroll_pixel_offset = critical.mouse.pixel_scroll_offset_y;

                // Track alternate screen state - this determines whether to apply
                // terminal scrollback offset (alternate screen = no scrollback = no offset)
                self.in_alternate_screen = critical.tui_in_alternate;

                // Update our background color
                self.uniforms.bg_color = .{
                    self.terminal_state.colors.background.r,
                    self.terminal_state.colors.background.g,
                    self.terminal_state.colors.background.b,
                    @intFromFloat(@round(self.config.background_opacity * 255.0)),
                };

                // If we're on macOS and have glass styles, we remove
                // the background opacity because the glass effect handles
                // it.
                if (comptime builtin.os.tag == .macos) switch (self.config.background_blur) {
                    .@"macos-glass-regular",
                    .@"macos-glass-clear",
                    => self.uniforms.bg_color[3] = 0,

                    else => {},
                };

                // Prepare our overlay image for upload (or unload). This
                // has to use our general allocator since it modifies
                // state that survives frames.
                self.images.overlayUpdate(
                    self.alloc,
                    self.overlay,
                ) catch |err| {
                    log.warn("error updating overlay images err={}", .{err});
                };

                // Update custom shader uniforms that depend on terminal state.
                self.updateCustomShaderUniformsFromState();
            }

            // Notify our shaper we're done for the frame. For some shapers,
            // such as CoreText, this triggers off-thread cleanup logic.
            self.font_shaper.endFrame();
        }

        /// Update frame for Neovim GUI mode.
        /// This is a separate code path that reads from Neovim windows instead of terminal state.
        /// Neovide order (from application.rs):
        /// 1. Events arrive → handle_draw_commands() → flush()
        /// 2. prepare_and_animate() → animate()
        /// 3. redraw_requested() → render()
        fn updateFrameNeovim(self: *Self, nvim: *neovim_gui.NeovimGui) !void {
            // Calculate time delta for smooth scroll animation
            const now = std.time.Instant.now() catch {
                self.last_frame_time = null;
                return;
            };
            // Calculate frame delta time
            const frame_dt: f32 = if (self.last_frame_time) |last| blk: {
                if (now.order(last) == .lt) {
                    break :blk 1.0 / 60.0;
                }
                const ns: f32 = @floatFromInt(now.since(last));
                break :blk ns / std.time.ns_per_s;
            } else 1.0 / 60.0;
            self.last_frame_time = now;

            // Step 1: Process events FIRST (includes flush which updates scrollback and position)
            nvim.processEvents() catch {};

            // Step 2: Animate with Neovide's subdivision approach
            // Subdivide large dt values to prevent animation jumps from inconsistent frame timing
            const MAX_ANIMATION_DT: f32 = 1.0 / 120.0; // 8.33ms max per animation step
            const num_steps: u32 = @max(1, @as(u32, @intFromFloat(@ceil(frame_dt / MAX_ANIMATION_DT))));
            const dt: f32 = frame_dt / @as(f32, @floatFromInt(num_steps));

            // Run animation steps
            var step: u32 = 0;
            while (step < num_steps) : (step += 1) {
                var any_animating = false;
                {
                    var window_iter = nvim.windows.valueIterator();
                    while (window_iter.next()) |window_ptr| {
                        if (window_ptr.*.animate(dt)) {
                            any_animating = true;
                        }
                    }
                }
                self.scroll_animating = any_animating;

                // Update cursor animations (Neovide-style)
                // MUST be in same timing as scroll to stay in sync
                // Always call update() unconditionally - it's cheap and ensures animations
                // continue even if cursor_animating flag gets out of sync
                {
                    const cell_width: f32 = @floatFromInt(self.grid_metrics.cell_width);
                    const cell_height: f32 = @floatFromInt(self.grid_metrics.cell_height);

                    // 1. Update the floaty spring animation (smooth cursor center movement)
                    const floaty_animating = self.cursor_animation.update(dt, 0.13, 1.0);

                    // 2. Update the stretchy corner animation
                    const corner_animating = self.corner_cursor.update(dt, cell_width, cell_height);

                    self.cursor_animating = floaty_animating or corner_animating;
                }
            }

            // Step 3: Render with current position and updated scrollback
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // Don't use global pixel_scroll_offset_y for Neovim mode
            // Each window has its own scroll animation handled via per-cell offsets
            self.uniforms.pixel_scroll_offset_y = 0;

            // Force cells_rebuilt if Neovim has changes
            // This ensures we render when floating windows appear/disappear
            // Keep dirty flag set to ensure continuous rendering until content stabilizes
            if (nvim.dirty) {
                self.cells_rebuilt = true;
            }

            try self.rebuildCellsFromNeovim(nvim);

            const bg = nvim.default_background;
            self.uniforms.bg_color = .{
                @intCast((bg >> 16) & 0xFF),
                @intCast((bg >> 8) & 0xFF),
                @intCast(bg & 0xFF),
                @intFromFloat(@round(self.config.background_opacity * 255.0)),
            };

            self.cells_rebuilt = true;
            self.font_shaper.endFrame();
        }

        /// Rebuild GPU cells from Neovim window content.
        fn rebuildCellsFromNeovim(self: *Self, nvim: *neovim_gui.NeovimGui) !void {
            // Reset all cells
            self.cells.reset();

            // Use grid 1's actual size (what Neovim has responded with), not the requested size.
            // During rapid resize (e.g., hy3 animations), the requested size may differ from
            // what Neovim has actually configured, causing rendering mismatches.
            const grid1 = nvim.windows.get(1) orelse {
                // Fall back to requested size if grid 1 doesn't exist yet
                const rows: u16 = @intCast(nvim.grid_height);
                const cols: u16 = @intCast(nvim.grid_width);
                log.debug("rebuildCellsFromNeovim: no grid1, using requested size {}x{}", .{ cols, rows });
                if (rows == 0 or cols == 0) return;
                if (self.cells.size.rows != rows or self.cells.size.columns != cols) {
                    try self.cells.resize(self.alloc, .{ .rows = rows, .columns = cols });
                    self.uniforms.grid_size = .{ cols, rows + 2 };
                }
                return; // No windows to render yet
            };

            const rows: u16 = @intCast(grid1.grid_height);
            const cols: u16 = @intCast(grid1.grid_width);

            log.debug("rebuildCellsFromNeovim: grid1 size={}x{}, needs_content={}", .{ cols, rows, grid1.needs_content });

            if (rows == 0 or cols == 0) return;

            if (self.cells.size.rows != rows or self.cells.size.columns != cols) {
                try self.cells.resize(self.alloc, .{ .rows = rows, .columns = cols });
                // Add 2 to rows for shader uniform because the Metal shader clips grid_size.y - 2
                self.uniforms.grid_size = .{ cols, rows + 2 };
            }

            // Get default colors from Neovim
            const default_fg = nvim.default_foreground;
            const default_bg = nvim.default_background;

            // Fill entire grid with default background color first
            // This ensures no gaps even if Neovim windows don't cover everything
            const bg_r: u8 = @intCast((default_bg >> 16) & 0xFF);
            const bg_g: u8 = @intCast((default_bg >> 8) & 0xFF);
            const bg_b: u8 = @intCast(default_bg & 0xFF);
            for (0..rows) |y| {
                for (0..cols) |x| {
                    self.cells.bgCell(y, x).* = .{
                        .color = .{ bg_r, bg_g, bg_b, 255 },
                        .offset_y_fixed = 0,
                    };
                }
            }

            // Partition windows into root (non-floating) and floating, like Neovide does
            // Root windows render first, then floating windows sorted by z-index on top
            var root_windows = std.ArrayListUnmanaged(*neovim_gui.RenderedWindow){};
            defer root_windows.deinit(self.alloc);
            var floating_windows = std.ArrayListUnmanaged(*neovim_gui.RenderedWindow){};
            defer floating_windows.deinit(self.alloc);

            var skipped_needs_content: u32 = 0;
            var window_iter = nvim.windows.valueIterator();
            while (window_iter.next()) |window_ptr| {
                const window = window_ptr.*;
                if (window.hidden or !window.valid) continue;
                if (window.grid_height == 0 or window.grid_width == 0) continue;
                // Skip windows that haven't received a win_pos yet (except grid 1 which is the outer container)
                // This prevents rendering grids like the cmdline grid at wrong positions
                if (!window.has_position and window.id != 1) continue;
                // Skip windows that were just resized and haven't received content yet
                // This prevents black flashes during rapid resize (e.g., hy3 animations)
                if (window.needs_content) {
                    skipped_needs_content += 1;
                    continue;
                }

                // Determine if this is a floating/message window
                const is_message_or_float = window.zindex > 0 or window.window_type == .floating or window.window_type == .message;

                // Skip windows that have no content buffer (actual_lines not initialized)
                // This happens when win_float_pos arrives before grid_resize
                // Previously we allowed floating windows through, but they render empty without actual_lines
                if (window.actual_lines == null) continue;

                // Skip windows that have no size yet (grid_resize hasn't arrived or set 0 size)
                // This prevents rendering 0x0 windows
                if (window.grid_width == 0 or window.grid_height == 0) {
                    continue;
                }

                // Partition: floating windows have zindex > 0 or are explicitly floating/message type
                const is_floating = is_message_or_float;
                if (is_floating) {
                    floating_windows.append(self.alloc, window) catch continue;
                } else {
                    root_windows.append(self.alloc, window) catch continue;
                }
            }

            // Sort floating windows by z-index (lower first, so higher z-index renders on top)
            std.mem.sort(*neovim_gui.RenderedWindow, floating_windows.items, {}, struct {
                fn lessThan(_: void, a: *neovim_gui.RenderedWindow, b: *neovim_gui.RenderedWindow) bool {
                    return a.zindex < b.zindex;
                }
            }.lessThan);

            // Get cell height for scroll offset calculation
            const cell_h: f32 = @floatFromInt(self.grid_metrics.cell_height);

            // Build final render order: root windows first (by grid id), then floating windows (by zindex)
            var windows_to_render = std.ArrayListUnmanaged(*neovim_gui.RenderedWindow){};
            defer windows_to_render.deinit(self.alloc);

            // Add root windows first (sorted by grid id for stability)
            std.mem.sort(*neovim_gui.RenderedWindow, root_windows.items, {}, struct {
                fn lessThan(_: void, a: *neovim_gui.RenderedWindow, b: *neovim_gui.RenderedWindow) bool {
                    return a.id < b.id;
                }
            }.lessThan);
            for (root_windows.items) |w| {
                windows_to_render.append(self.alloc, w) catch continue;
            }

            // Add floating windows on top (already sorted by zindex)
            for (floating_windows.items) |w| {
                windows_to_render.append(self.alloc, w) catch continue;
            }

            log.err("rebuildCellsFromNeovim: rendering {} root + {} floating = {} total (skipped {} needs_content)", .{
                root_windows.items.len,
                floating_windows.items.len,
                windows_to_render.items.len,
                skipped_needs_content,
            });
            // Debug: log which windows are being rendered
            for (root_windows.items) |w| {
                log.debug("  root window: grid={} pos=({},{}) size={}x{} display={}x{} margins=({},{},{},{})", .{
                    w.id,
                    @as(i32, @intFromFloat(w.grid_position[0])),
                    @as(i32, @intFromFloat(w.grid_position[1])),
                    w.grid_width,
                    w.grid_height,
                    w.display_width,
                    w.display_height,
                    w.viewport_margins.top,
                    w.viewport_margins.bottom,
                    w.viewport_margins.left,
                    w.viewport_margins.right,
                });
            }
            for (floating_windows.items) |w| {
                log.debug("  floating window: grid={} pos=({},{}) size={}x{} zindex={} type={s} has_lines={}", .{
                    w.id,
                    @as(i32, @intFromFloat(w.grid_position[0])),
                    @as(i32, @intFromFloat(w.grid_position[1])),
                    w.grid_width,
                    w.grid_height,
                    w.zindex,
                    @tagName(w.window_type),
                    w.actual_lines != null,
                });
            }

            // RENDERING STRATEGY:
            //
            // We use painter's algorithm (back to front) for BACKGROUNDS but need occlusion for TEXT.
            //
            // Why? Backgrounds can be overwritten by later windows (floating paints over root).
            // But TEXT is added to a vertex buffer - if we add root window text first, it stays
            // in the buffer even after floating window backgrounds are drawn, causing bleed-through.
            //
            // So:
            // - BACKGROUNDS: Always render (painter's algorithm - later windows overwrite)
            // - TEXT: Use occlusion map to prevent root window text under floating windows
            //
            // For message windows (noice.nvim), skip empty cells entirely to let statusline show.

            // Build occlusion map for TEXT rendering only
            // This prevents root window text from appearing under floating windows
            var occlusion_map = try self.alloc.alloc(u64, rows * cols);
            defer self.alloc.free(occlusion_map);
            @memset(occlusion_map, 0);

            // Claim cells from highest z-index to lowest
            // For text rendering, we need to account for viewport margins
            // Margins (borders, winbar, statusline) only have backgrounds, not text content
            // So they shouldn't block text from windows below them
            var i: usize = windows_to_render.items.len;
            while (i > 0) {
                i -= 1;
                const window = windows_to_render.items[i];
                const win_col: u16 = @intFromFloat(window.grid_position[0]);
                const win_row: u16 = @intFromFloat(window.grid_position[1]);
                const is_message = window.window_type == .message;

                // Use render dimensions (from win_pos) to avoid artifacts during resize
                const render_width = window.getRenderWidth();
                const render_height = window.getRenderHeight();

                // Get margins for this window to skip border/margin cells in occlusion
                const margin_top = window.viewport_margins.top;
                const margin_bottom = window.viewport_margins.bottom;

                var py: u32 = 0;
                while (py < render_height) : (py += 1) {
                    var px: u32 = 0;
                    while (px < render_width) : (px += 1) {
                        const sy = @as(u16, @intCast(py)) + win_row;
                        const sx = @as(u16, @intCast(px)) + win_col;
                        if (sy < rows and sx < cols) {
                            if (occlusion_map[sy * cols + sx] == 0) {
                                // Skip margin rows - they only have backgrounds, no text
                                // This prevents floating window borders from blocking text below
                                const is_margin_row = py < margin_top or py >= (render_height -| margin_bottom);
                                if (is_margin_row) continue;

                                // Message windows only claim cells with actual content
                                if (is_message) {
                                    const cell = window.getCell(py, px);
                                    if (cell) |c| {
                                        const text = c.getText();
                                        if (text.len > 0 and text[0] != ' ' and text[0] != 0) {
                                            occlusion_map[sy * cols + sx] = window.id;
                                        }
                                    }
                                } else {
                                    occlusion_map[sy * cols + sx] = window.id;
                                }
                            }
                        }
                    }
                }
            }

            // Process each Neovim window in z-order (root windows first, then floating)
            for (windows_to_render.items) |window| {
                // Get window position offset
                const win_col: u16 = @intFromFloat(window.grid_position[0]);
                const win_row: u16 = @intFromFloat(window.grid_position[1]);

                // Use render dimensions (from win_pos) to avoid artifacts during resize
                // win_pos arrives before grid_resize, so these may be smaller than grid dimensions
                const render_width = window.getRenderWidth();
                const render_height = window.getRenderHeight();

                // Check if this is a floating window (includes message windows like NOICE command bar)
                const is_floating = window.zindex > 0 or window.window_type == .floating or window.window_type == .message;
                const is_message_window = window.window_type == .message;

                // Get per-window scroll offset in pixels for smooth scrolling
                // Only editor windows scroll - floating windows and messages don't
                // Also skip scroll animation if scrollback doesn't have valid data
                const has_valid_scrollback = if (!is_floating) window.hasValidScrollbackData() else false;
                const scroll_pixel_offset: f32 = if (has_valid_scrollback)
                    window.getSubLineOffset(cell_h)
                else
                    0;

                const margin_top = window.viewport_margins.top;
                const margin_bottom = window.viewport_margins.bottom;
                const inner_size = render_height -| margin_top -| margin_bottom;

                // Render top margin rows (winbar etc) - no scroll
                var row: u32 = 0;
                while (row < margin_top) : (row += 1) {
                    var col: u32 = 0;
                    while (col < render_width) : (col += 1) {
                        const screen_y = @as(u16, @intCast(row)) + win_row;
                        const screen_x = @as(u16, @intCast(col)) + win_col;
                        if (screen_y >= self.cells.size.rows or screen_x >= self.cells.size.columns) continue;

                        // Check if this window owns this cell for TEXT rendering
                        const owns_cell = occlusion_map[screen_y * cols + screen_x] == window.id;

                        // For message windows, skip cells we don't own (empty cells)
                        if (is_message_window and !owns_cell) continue;

                        const grid_cell = window.getCell(row, col);
                        // Get highlight attributes - use getHlAttrForFloat for floating windows
                        const hl_id: u64 = if (grid_cell) |c| c.hl_id else 0;
                        const hl_attr = if (is_floating) nvim.getHlAttrForFloat(hl_id) else nvim.getHlAttr(hl_id);

                        // getHlAttr always returns non-null colors
                        var fg_color = hl_attr.foreground.?;
                        var bg_color = hl_attr.background.?;
                        if (hl_attr.reverse) {
                            const tmp = fg_color;
                            fg_color = bg_color;
                            bg_color = tmp;
                        }

                        // ALWAYS render backgrounds (painter's algorithm - later windows overwrite)
                        if (is_floating) {
                            // Floating windows: solid background, no scroll offset
                            self.cells.bgCell(screen_y, screen_x).* = .{
                                .color = .{
                                    @intCast((bg_color >> 16) & 0xFF),
                                    @intCast((bg_color >> 8) & 0xFF),
                                    @intCast(bg_color & 0xFF),
                                    255,
                                },
                                .offset_y_fixed = 0,
                            };
                        } else if (hl_attr.blend > 0) {
                            const blend_alpha = 255 - (@as(u16, hl_attr.blend) * 255 / 100);
                            const inv_alpha = 255 - blend_alpha;

                            const cell_r: u16 = @intCast((bg_color >> 16) & 0xFF);
                            const cell_g: u16 = @intCast((bg_color >> 8) & 0xFF);
                            const cell_b: u16 = @intCast(bg_color & 0xFF);
                            const def_r: u16 = @intCast((default_bg >> 16) & 0xFF);
                            const def_g: u16 = @intCast((default_bg >> 8) & 0xFF);
                            const def_b: u16 = @intCast(default_bg & 0xFF);

                            const final_r: u8 = @intCast((cell_r * blend_alpha + def_r * inv_alpha) / 255);
                            const final_g: u8 = @intCast((cell_g * blend_alpha + def_g * inv_alpha) / 255);
                            const final_b: u8 = @intCast((cell_b * blend_alpha + def_b * inv_alpha) / 255);

                            self.cells.bgCell(screen_y, screen_x).* = .{
                                .color = .{ final_r, final_g, final_b, 255 },
                                .offset_y_fixed = 0, // Margins don't scroll
                            };
                        } else {
                            // Solid background
                            self.cells.bgCell(screen_y, screen_x).* = .{
                                .color = .{
                                    @intCast((bg_color >> 16) & 0xFF),
                                    @intCast((bg_color >> 8) & 0xFF),
                                    @intCast(bg_color & 0xFF),
                                    255,
                                },
                                .offset_y_fixed = 0, // Margins don't scroll
                            };
                        }

                        // Only render TEXT if this window owns this cell (occlusion check)
                        if (owns_cell) {
                            if (grid_cell) |cell| {
                                const text = cell.getText();
                                if (text.len > 0) self.addNeovimGlyph(screen_x, screen_y, text, fg_color, hl_attr, 0) catch {};
                            }
                        } else if (is_floating and grid_cell != null) {
                            // Debug: log when floating window text is blocked by occlusion
                            const text = grid_cell.?.getText();
                            if (text.len > 0 and text[0] != ' ') {
                                const blocker = occlusion_map[screen_y * cols + screen_x];
                                log.err("OCCLUSION BLOCKED: grid={} pos=({},{}) text='{s}' blocked_by_grid={}", .{
                                    window.id, screen_x, screen_y, text, blocker,
                                });
                            }
                        }
                    }
                }

                // Render scrollable region
                // Render extra row during scroll so content can scroll into view from below
                const bg_offset_fixed: i16 = @intFromFloat(scroll_pixel_offset * 256.0);
                const render_extra_row = (!is_floating and has_valid_scrollback and scroll_pixel_offset != 0);
                const render_rows = if (render_extra_row) inner_size + 1 else inner_size;
                var inner_row: u32 = 0;
                while (inner_row < render_rows) : (inner_row += 1) {
                    var col: u32 = 0;
                    while (col < render_width) : (col += 1) {
                        // Screen position: margin_top + inner_row
                        const screen_row = margin_top + inner_row;
                        const screen_y = @as(u16, @intCast(screen_row)) + win_row;
                        const screen_x = @as(u16, @intCast(col)) + win_col;

                        if (screen_y >= self.cells.size.rows or screen_x >= self.cells.size.columns) continue;

                        // Check if this window owns this cell for TEXT rendering
                        const owns_cell = occlusion_map[screen_y * cols + screen_x] == window.id;

                        // For extra animation row: only draw if we own the cell OR no one owns it (unclaimed)
                        // This prevents drawing over statusline which is a separate window
                        const is_extra_anim_row = (render_extra_row and inner_row == inner_size);
                        const cell_unclaimed = occlusion_map[screen_y * cols + screen_x] == 0;
                        const can_draw_extra = is_extra_anim_row and (owns_cell or cell_unclaimed);

                        // For message windows, skip cells we don't own (empty cells)
                        if (is_message_window and !owns_cell and !can_draw_extra) continue;

                        // Skip extra animation row if another window owns that cell (e.g. statusline)
                        if (is_extra_anim_row and !owns_cell and !cell_unclaimed) continue;

                        // Read from scrollback or actual_lines
                        const grid_cell = if (!is_floating and has_valid_scrollback)
                            window.getScrollbackCellByInnerRow(inner_row, col)
                        else
                            window.getCell(margin_top + inner_row, col);

                        // Get highlight attributes - use getHlAttrForFloat for floating windows
                        const hl_id: u64 = if (grid_cell) |c| c.hl_id else 0;
                        const hl_attr = if (is_floating) nvim.getHlAttrForFloat(hl_id) else nvim.getHlAttr(hl_id);

                        // getHlAttr always returns non-null colors (defaults filled in)
                        var fg_color = hl_attr.foreground.?;
                        var bg_color = hl_attr.background.?;

                        if (hl_attr.reverse) {
                            const tmp = fg_color;
                            fg_color = bg_color;
                            bg_color = tmp;
                        }

                        // Floating windows: no scroll offset, solid background.
                        if (is_floating) {
                            self.cells.bgCell(screen_y, screen_x).* = .{
                                .color = .{
                                    @intCast((bg_color >> 16) & 0xFF),
                                    @intCast((bg_color >> 8) & 0xFF),
                                    @intCast(bg_color & 0xFF),
                                    255,
                                },
                                .offset_y_fixed = 0,
                            };
                        } else if (hl_attr.blend > 0) {
                            const blend_alpha = 255 - (@as(u16, hl_attr.blend) * 255 / 100);
                            const inv_alpha = 255 - blend_alpha;

                            const cell_r: u16 = @intCast((bg_color >> 16) & 0xFF);
                            const cell_g: u16 = @intCast((bg_color >> 8) & 0xFF);
                            const cell_b: u16 = @intCast(bg_color & 0xFF);
                            const def_r: u16 = @intCast((default_bg >> 16) & 0xFF);
                            const def_g: u16 = @intCast((default_bg >> 8) & 0xFF);
                            const def_b: u16 = @intCast(default_bg & 0xFF);

                            const final_r: u8 = @intCast((cell_r * blend_alpha + def_r * inv_alpha) / 255);
                            const final_g: u8 = @intCast((cell_g * blend_alpha + def_g * inv_alpha) / 255);
                            const final_b: u8 = @intCast((cell_b * blend_alpha + def_b * inv_alpha) / 255);

                            self.cells.bgCell(screen_y, screen_x).* = .{
                                .color = .{ final_r, final_g, final_b, 255 },
                                .offset_y_fixed = bg_offset_fixed,
                            };
                        } else {
                            self.cells.bgCell(screen_y, screen_x).* = .{
                                .color = .{
                                    @intCast((bg_color >> 16) & 0xFF),
                                    @intCast((bg_color >> 8) & 0xFF),
                                    @intCast(bg_color & 0xFF),
                                    255,
                                },
                                .offset_y_fixed = bg_offset_fixed,
                            };
                        }

                        // Only render TEXT if this window owns this cell or can draw extra animation row
                        if (owns_cell or can_draw_extra) {
                            if (grid_cell) |cell| {
                                const text = cell.getText();
                                if (text.len > 0) {
                                    const effective_offset: f32 = if (is_floating) 0 else scroll_pixel_offset;
                                    self.addNeovimGlyph(screen_x, screen_y, text, fg_color, hl_attr, effective_offset) catch {};
                                }
                            }
                        }
                    }
                }

                // Render bottom margin rows (statusline etc) - no scroll, solid like floating
                row = render_height -| margin_bottom;
                while (row < render_height) : (row += 1) {
                    var col: u32 = 0;
                    while (col < render_width) : (col += 1) {
                        const screen_y = @as(u16, @intCast(row)) + win_row;
                        const screen_x = @as(u16, @intCast(col)) + win_col;
                        if (screen_y >= self.cells.size.rows or screen_x >= self.cells.size.columns) continue;

                        // Check if this window owns this cell for TEXT rendering
                        const owns_cell = occlusion_map[screen_y * cols + screen_x] == window.id;

                        // For message windows, skip cells we don't own (empty cells)
                        if (is_message_window and !owns_cell) continue;

                        const grid_cell = window.getCell(row, col);
                        // Get highlight attributes - use getHlAttrForFloat for floating windows
                        const hl_id: u64 = if (grid_cell) |c| c.hl_id else 0;
                        const hl_attr = if (is_floating) nvim.getHlAttrForFloat(hl_id) else nvim.getHlAttr(hl_id);

                        // getHlAttr always returns non-null colors
                        var fg_color = hl_attr.foreground.?;
                        var bg_color = hl_attr.background.?;
                        if (hl_attr.reverse) {
                            const tmp = fg_color;
                            fg_color = bg_color;
                            bg_color = tmp;
                        }

                        // Bottom margin is always statusline - use solid background, no blend
                        // This prevents transparency issues where scrolling content shows through
                        self.cells.bgCell(screen_y, screen_x).* = .{
                            .color = .{
                                @intCast((bg_color >> 16) & 0xFF),
                                @intCast((bg_color >> 8) & 0xFF),
                                @intCast(bg_color & 0xFF),
                                255,
                            },
                            .offset_y_fixed = 0,
                        };

                        // Only render TEXT if this window owns this cell (occlusion check)
                        if (owns_cell) {
                            if (grid_cell) |cell| {
                                const text = cell.getText();
                                if (text.len > 0) {
                                    self.addNeovimGlyph(screen_x, screen_y, text, fg_color, hl_attr, 0) catch {};
                                }
                            }
                        }
                    }
                }
            }

            // Render cursor
            self.renderNeovimCursor(nvim, default_fg, default_bg);
        }

        /// Render the Neovim cursor using Ghostty's cursor animation system
        fn renderNeovimCursor(self: *Self, nvim: *neovim_gui.NeovimGui, default_fg: u32, default_bg: u32) void {
            _ = default_bg;

            // Get the cursor's window to find screen position
            const cursor_window = nvim.windows.get(nvim.cursor_grid) orelse return;
            if (!cursor_window.valid or cursor_window.hidden) return;

            const cell_width: f32 = @floatFromInt(self.grid_metrics.cell_width);
            const cell_height: f32 = @floatFromInt(self.grid_metrics.cell_height);

            // Get scroll animation position (like Neovide: grid.y -= window.scroll_animation.position)
            const scroll_pos = cursor_window.scroll_animation.position;

            // Calculate grid position
            const local_col_f: f32 = @floatFromInt(nvim.cursor_col);
            const local_row_f: f32 = @floatFromInt(nvim.cursor_row);
            const grid_x = local_col_f + cursor_window.grid_position[0];
            // Neovide subtracts scroll position from grid Y so cursor moves with content
            const grid_y = local_row_f + cursor_window.grid_position[1] - scroll_pos;

            // Screen position (integer grid cell) - for uniforms/cell lookup only
            const screen_col: u16 = @intFromFloat(@max(0, grid_x));
            const screen_row: u16 = @intFromFloat(@max(0, local_row_f + cursor_window.grid_position[1]));

            if (screen_row >= self.cells.size.rows or screen_col >= self.cells.size.columns) return;

            // Don't set cursor_pos for Neovim mode - we use animated cursor rendering instead
            // Setting cursor_pos would cause the shader to draw a non-animated cursor at the actual position
            // which creates a "black thing" that lags behind the animated cursor
            self.uniforms.cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) };

            // Pixel positions (top-left of cursor cell) - includes scroll offset
            // This is the cursor's TARGET position that it animates toward
            const target_pixel_x: f32 = grid_x * cell_width;
            const target_pixel_y: f32 = grid_y * cell_height;

            // Neovide-style cursor animation
            // The cursor should animate smoothly when either:
            // 1. Cursor grid position changes (normal movement)
            // 2. Scroll position changes (cursor follows content)

            const last_x = self.last_cursor_grid_pos[0];
            const last_y = self.last_cursor_grid_pos[1];
            const scroll_changed = scroll_pos != self.last_cursor_scroll_pos;
            const pos_changed = screen_col != last_x or screen_row != last_y;

            if (pos_changed or scroll_changed) {
                // Set new target - target_pixel_y already includes scroll offset
                self.cursor_animation.setTarget(target_pixel_x, target_pixel_y, cell_width);
                self.corner_cursor.setTarget(target_pixel_x, target_pixel_y, cell_width, cell_height);

                self.last_cursor_grid_pos = .{ screen_col, screen_row };
                self.last_cursor_scroll_pos = scroll_pos;
                self.cursor_animating = true;
            }

            // Get the floaty animated position (smooth spring movement)
            const floaty_pos = self.cursor_animation.getPosition();

            // Update corner cursor destination to track the floaty position
            // This makes corners stretch relative to the smoothly moving center
            self.corner_cursor.destination = .{
                floaty_pos.x + cell_width * 0.5,
                floaty_pos.y + cell_height * 0.5,
            };

            // Get animated corner positions
            const corners = self.corner_cursor.getCorners();

            self.uniforms.cursor_corner_tl = corners[0];
            self.uniforms.cursor_corner_tr = corners[1];
            self.uniforms.cursor_corner_br = corners[2];
            self.uniforms.cursor_corner_bl = corners[3];
            // Set cursor_use_corners - type depends on backend (bool for Metal, u32 for OpenGL)
            self.uniforms.cursor_use_corners = if (@TypeOf(self.uniforms.cursor_use_corners) == bool) true else 1;
            self.uniforms.cursor_offset_x = 0;
            self.uniforms.cursor_offset_y = 0;

            const alpha: u8 = 255;

            // Render cursor glyph
            const cursor_color_rgb = terminal.color.RGB{
                .r = @intCast((default_fg >> 16) & 0xFF),
                .g = @intCast((default_fg >> 8) & 0xFF),
                .b = @intCast(default_fg & 0xFF),
            };

            // Get cursor shape from current mode
            const cursor_mode = nvim.getCurrentCursorMode();
            const cursor_shape = if (cursor_mode) |mode| mode.shape orelse .block else .block;
            const cell_percentage = if (cursor_mode) |mode| mode.cell_percentage orelse 0.25 else 0.25;

            // Update corner positions if cursor shape changed
            if (self.last_cursor_shape == null or self.last_cursor_shape.? != cursor_shape) {
                const corner_shape: animation.CornerCursorAnimation.CursorShape = switch (cursor_shape) {
                    .block => .block,
                    .vertical => .vertical,
                    .horizontal => .horizontal,
                };
                self.corner_cursor.setCursorShape(corner_shape, cell_percentage);
                self.last_cursor_shape = cursor_shape;
            }

            // Select the appropriate sprite based on cursor shape
            const cursor_sprite: font.Sprite = switch (cursor_shape) {
                .block => .cursor_rect,
                .vertical => .cursor_bar,
                .horizontal => .cursor_underline,
            };

            // Render cursor sprite
            const render = self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(cursor_sprite),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            ) catch {
                return;
            };

            // Map Neovim cursor shape to Ghostty cursor style for setCursor
            const ghostty_cursor_style: renderer.CursorStyle = switch (cursor_shape) {
                .block => .block,
                .vertical => .bar,
                .horizontal => .underline,
            };

            // Add cursor using setCursor - this marks it with is_cursor_glyph
            // so the shader applies cursor_offset_x/y for animation
            // NOTE: Don't apply pixel_offset_y here - cursor animation already accounts for scroll
            // via dest_pixel_y adjustment above. Double-applying causes bounce.
            self.cells.setCursor(.{
                .atlas = .grayscale,
                .bools = .{ .is_cursor_glyph = true },
                .grid_pos = .{ screen_col, screen_row },
                .color = .{ cursor_color_rgb.r, cursor_color_rgb.g, cursor_color_rgb.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
                .pixel_offset_y = 0, // Scroll handled by cursor_offset_y
            }, ghostty_cursor_style);
        }

        /// Add a glyph from Neovim cell content
        /// pixel_offset_y: Per-cell pixel offset for smooth scrolling (in pixels, can be fractional)
        fn addNeovimGlyph(
            self: *Self,
            x: u16,
            y: u16,
            text: []const u8,
            fg_color: u32,
            hl_attr: neovim_gui.HlAttr,
            pixel_offset_y: f32,
        ) !void {
            // Decode the first codepoint from text
            // Handle invalid UTF-8 gracefully instead of panicking
            if (text.len == 0) return;

            // Get the byte length of the first UTF-8 sequence
            const seq_len = std.unicode.utf8ByteSequenceLength(text[0]) catch {
                // Invalid UTF-8 lead byte - skip this cell
                return;
            };

            // Check if we have enough bytes
            if (text.len < seq_len) return;

            // Decode the codepoint
            const codepoint = std.unicode.utf8Decode(text[0..seq_len]) catch {
                // Invalid UTF-8 sequence - skip this cell
                return;
            };

            // Skip spaces and null
            if (codepoint == ' ' or codepoint == 0) return;

            // Determine font style based on highlight attributes
            const font_style: font.Style = if (hl_attr.bold and hl_attr.italic)
                .bold_italic
            else if (hl_attr.bold)
                .bold
            else if (hl_attr.italic)
                .italic
            else
                .regular;

            // Try to render the codepoint using the font grid
            const render_result = self.font_grid.renderCodepoint(
                self.alloc,
                codepoint,
                font_style,
                .text,
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            ) catch return;

            const render = render_result orelse return;

            // Convert pixel offset to 8.8 fixed-point format for GPU
            // Range: -128.0 to +127.996 pixels (sufficient for smooth scrolling)
            const fixed_offset: i16 = @intFromFloat(std.math.clamp(pixel_offset_y * 256.0, -32768.0, 32767.0));

            try self.cells.add(self.alloc, .text, .{
                .atlas = .grayscale,
                .grid_pos = .{ x, y },
                .color = .{
                    @intCast((fg_color >> 16) & 0xFF),
                    @intCast((fg_color >> 8) & 0xFF),
                    @intCast(fg_color & 0xFF),
                    255,
                },
                .glyph_pos = .{
                    render.glyph.atlas_x,
                    render.glyph.atlas_y,
                },
                .glyph_size = .{
                    render.glyph.width,
                    render.glyph.height,
                },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
                .pixel_offset_y = fixed_offset,
            });

            // Handle underline
            if (hl_attr.underline or hl_attr.undercurl) {
                const underline_style: terminal.Attribute.Underline = if (hl_attr.undercurl)
                    .curly
                else
                    .single;

                const underline_color = terminal.color.RGB{
                    .r = @intCast((fg_color >> 16) & 0xFF),
                    .g = @intCast((fg_color >> 8) & 0xFF),
                    .b = @intCast(fg_color & 0xFF),
                };

                self.addUnderline(x, y, underline_style, underline_color, 255, pixel_offset_y) catch {};
            }

            // Handle strikethrough
            if (hl_attr.strikethrough) {
                const strike_color = terminal.color.RGB{
                    .r = @intCast((fg_color >> 16) & 0xFF),
                    .g = @intCast((fg_color >> 8) & 0xFF),
                    .b = @intCast(fg_color & 0xFF),
                };

                self.addStrikethrough(x, y, strike_color, 255, pixel_offset_y) catch {};
            }
        }

        /// Draw the frame to the screen.
        ///
        /// If `sync` is true, this will synchronously block until
        /// the frame is finished drawing and has been presented.
        pub fn drawFrame(
            self: *Self,
            sync: bool,
        ) !void {
            // const start = std.time.Instant.now() catch unreachable;
            // const start_micro = std.time.microTimestamp();
            // defer {
            //     const end = std.time.Instant.now() catch unreachable;
            //     log.warn(
            //         "[drawFrame time] start_micro={} duration={}ns",
            //         .{ start_micro, end.since(start) / std.time.ns_per_us },
            //     );
            // }

            // We hold a the draw mutex to prevent changes to any
            // data we access while we're in the middle of drawing.
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // If our swap chain is defunct (e.g., after displayUnrealized but before
            // displayRealized), we can't draw. This can happen during window moves
            // on Wayland/Hyprland where GTK unrealizes but doesn't immediately re-realize.
            // In this case, try to reinitialize the rendering resources.
            if (self.swap_chain.defunct or self.shaders.defunct) {
                log.debug("drawFrame: swap_chain or shaders defunct, attempting reinit", .{});
                // Try to reinitialize - this is what displayRealized would do
                self.shaders.deinit(self.alloc);
                try self.initShaders();
                self.swap_chain = try SwapChain.init(
                    self.api,
                    self.has_custom_shaders,
                );
                self.reinitialize_shaders = false;
                self.target_config_modified = 1;
                self.markDirty();
                self.cells_rebuilt = true;
                log.debug("drawFrame: reinit complete, continuing with frame", .{});
            }

            // Unified timing
            const now = std.time.Instant.now() catch return;
            const last = self.last_frame_time orelse now;
            // Safety: Check if time went backwards (can happen with system clock adjustments)
            const dt: f32 = if (now.order(last) == .lt) blk: {
                break :blk 1.0 / 60.0; // Default to 60fps if time went backwards
            } else blk: {
                const dt_ns: f32 = @floatFromInt(now.since(last));
                break :blk @min(dt_ns / std.time.ns_per_s, 0.1);
            };

            if (self.cursor_animating or self.scroll_animating) {
                self.last_frame_time = now;
            } else {
                self.last_frame_time = null;
            }

            // Update cursor animation if active
            if (self.cursor_animating) {
                const cell_w: f32 = @floatFromInt(self.grid_metrics.cell_width);
                const cell_h: f32 = @floatFromInt(self.grid_metrics.cell_height);
                const cursor_len = self.config.cursor_animation_duration;
                const cursor_zeta = 1.0 - (self.config.cursor_animation_bounciness * 0.6);
                const floaty_animating = self.cursor_animation.update(dt, cursor_len, cursor_zeta);

                if (self.nvim_gui != null) {
                    // Neovim mode: also update corner animations
                    const corner_animating = self.corner_cursor.update(dt, cell_w, cell_h);
                    self.cursor_animating = floaty_animating or corner_animating;
                } else {
                    // Terminal mode: only floaty animation
                    self.cursor_animating = floaty_animating;

                    const pos = self.cursor_animation.getPosition();
                    const cursor_x = self.uniforms.cursor_pos[0];
                    const cursor_y = self.uniforms.cursor_pos[1];
                    if (cursor_x != std.math.maxInt(u16) and cursor_y != std.math.maxInt(u16)) {
                        const target_x: f32 = @as(f32, @floatFromInt(cursor_x)) * cell_w;
                        const target_y: f32 = @as(f32, @floatFromInt(cursor_y)) * cell_h;
                        self.uniforms.cursor_offset_x = pos.x - target_x;
                        self.uniforms.cursor_offset_y = pos.y - target_y;
                    }
                }
            }

            // NOTE: For Neovim GUI mode, scroll animations are updated in updateFrameNeovim
            // along with event processing, so they stay perfectly in sync (like Neovide).
            // We don't duplicate animation updates here to avoid race conditions.

            // Pixel scroll offset for smooth scrolling
            //
            // For terminal scrollback (mouse/trackpad): Use sub-cell pixel offset
            // For TUI apps (Neovim via OSC 9999): Use spring animation with scroll regions
            //
            // The key insight (from Neovide): Only shift cells WITHIN the scroll region.
            // Status bar, command line, etc. stay fixed because they're outside the region.

            const cell_h: f32 = @floatFromInt(self.grid_metrics.cell_height);

            // For Neovim GUI mode, pixel_scroll_offset_y is set in updateFrameNeovim
            // Don't override it here
            if (self.nvim_gui == null) {
                // Terminal scrollback (mouse/trackpad): uses scroll_pixel_offset for sub-cell positioning.
                // Ghostty always renders with an extra row above the viewport for smooth scrollback,
                // so we need to shift content UP by cell_h to hide it and align the grid properly.
                //
                // For alternate screen (TUI apps like Neovim), there's no mouse-driven scrollback,
                // but we STILL need the cell_h shift to align content correctly with the viewport.
                // The difference is we don't apply scroll_pixel_offset (mouse scroll) in alternate screen.
                const base_offset: f32 = if (self.in_alternate_screen)
                    // Alternate screen: fixed cell_h shift for grid alignment (no mouse scroll offset)
                    cell_h
                else
                    // Primary screen: cell_h shift minus mouse scroll offset for smooth scrollback
                    cell_h - self.scroll_pixel_offset;
                self.uniforms.pixel_scroll_offset_y = base_offset;
            }

            // After the graphics API is complete (so we defer) we want to
            // update our scrollbar state.
            defer if (self.scrollbar_dirty) {
                // Fail instantly if the surface mailbox if full, we'll just
                // get it on the next frame.
                if (self.surface_mailbox.push(.{
                    .scrollbar = self.scrollbar,
                }, .instant) > 0) self.scrollbar_dirty = false;
            };

            // Let our graphics API do any bookkeeping, etc.
            // that it needs to do before / after `drawFrame`.
            self.api.drawFrameStart();
            defer self.api.drawFrameEnd();

            // Retrieve the most up-to-date surface size from the Graphics API
            const surface_size = try self.api.surfaceSize();

            // If either of our surface dimensions is zero
            // then drawing is absurd, so we just return.
            if (surface_size.width == 0 or surface_size.height == 0) return;

            const size_changed =
                self.size.screen.width != surface_size.width or
                self.size.screen.height != surface_size.height;

            // When size changes, force a full cell rebuild to ensure proper rendering
            // This is especially important on Wayland/Hyprland where surface invalidation
            // during window moves or resizes can cause stale framebuffer content
            if (size_changed) {
                self.markDirty();
                self.cells_rebuilt = true;
                // Clear the cached last target to prevent stale buffer blits
                self.api.clearLastTarget();
            }

            // Conditions under which we need to draw the frame, otherwise we
            // don't need to since the previous frame should be identical.
            const needs_redraw =
                size_changed or
                self.cells_rebuilt or
                self.hasAnimations() or
                sync;

            if (!needs_redraw) {
                // We still need to present the last target again, because the
                // apprt may be swapping buffers and display an outdated frame
                // if we don't draw something new.
                log.err("SKIPPING RENDER: presenting last target (cells_rebuilt={} hasAnim={})", .{
                    self.cells_rebuilt, self.hasAnimations(),
                });
                try self.api.presentLastTarget();
                return;
            }
            log.err("RENDERING FRAME: cells_rebuilt={} hasAnim={}", .{
                self.cells_rebuilt, self.hasAnimations(),
            });
            self.cells_rebuilt = false;

            // Wait for a frame to be available.
            const frame = try self.swap_chain.nextFrame();
            errdefer self.swap_chain.releaseFrame();
            // log.debug("drawing frame index={}", .{self.swap_chain.frame_index});

            // If we need to reinitialize our shaders, do so.
            if (self.reinitialize_shaders) {
                self.reinitialize_shaders = false;
                self.shaders.deinit(self.alloc);
                try self.initShaders();
            }

            // Our shaders should not be defunct at this point.
            assert(!self.shaders.defunct);

            // If we have custom shaders, make sure we have the
            // custom shader state in our frame state, otherwise
            // if we have a state but don't need it we remove it.
            if (self.has_custom_shaders) {
                if (frame.custom_shader_state == null) {
                    frame.custom_shader_state = try .init(self.api);
                    try frame.custom_shader_state.?.resize(
                        self.api,
                        surface_size.width,
                        surface_size.height,
                    );
                }
            } else if (frame.custom_shader_state) |*state| {
                state.deinit();
                frame.custom_shader_state = null;
            }

            // If our stored size doesn't match the
            // surface size we need to update it.
            if (size_changed) {
                self.size.screen = .{
                    .width = surface_size.width,
                    .height = surface_size.height,
                };
                self.updateScreenSizeUniforms();
            }

            // If this frame's target isn't the correct size, or the target
            // config has changed (such as when the blending mode changes),
            // remove it and replace it with a new one with the right values.
            if (frame.target.width != self.size.screen.width or
                frame.target.height != self.size.screen.height or
                frame.target_config_modified != self.target_config_modified)
            {
                try frame.resize(
                    self.api,
                    self.size.screen.width,
                    self.size.screen.height,
                );
                frame.target_config_modified = self.target_config_modified;
            }

            // Upload images to the GPU as necessary.
            _ = self.images.upload(self.alloc, &self.api);

            // Upload the background image to the GPU as necessary.
            try self.uploadBackgroundImage();

            // Update per-frame custom shader uniforms.
            try self.updateCustomShaderUniformsForFrame();

            // Setup our frame data
            // Normal render: Include cursor
            self.uniforms.bools.exclude_cursor = false;
            try frame.uniforms.sync(&.{self.uniforms});

            try frame.cells_bg.sync(self.cells.bg_cells);
            const fg_count = try frame.cells.syncFromArrayLists(self.cells.fg_rows.lists);

            // If our background image buffer has changed, sync it.
            if (frame.bg_image_buffer_modified != self.bg_image_buffer_modified) {
                try frame.bg_image_buffer.sync(&.{self.bg_image_buffer});

                frame.bg_image_buffer_modified = self.bg_image_buffer_modified;
            }

            // If our font atlas changed, sync the texture data
            texture: {
                const modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                if (modified <= frame.grayscale_modified) break :texture;
                self.font_grid.lock.lockShared();
                defer self.font_grid.lock.unlockShared();
                frame.grayscale_modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_grayscale, &frame.grayscale);
            }
            texture: {
                const modified = self.font_grid.atlas_color.modified.load(.monotonic);
                if (modified <= frame.color_modified) break :texture;
                self.font_grid.lock.lockShared();
                defer self.font_grid.lock.unlockShared();
                frame.color_modified = self.font_grid.atlas_color.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_color, &frame.color);
            }

            // Get a frame context from the graphics API.
            var frame_ctx = try self.api.beginFrame(self, &frame.target);
            defer frame_ctx.complete(sync);

            // Determine the render target for main content:
            // - If custom shaders: render to custom shader back_texture
            // - Else: render directly to frame target
            {
                var pass = frame_ctx.renderPass(&.{.{
                    .target = if (frame.custom_shader_state) |state|
                        .{ .texture = state.back_texture }
                    else
                        .{ .target = frame.target },
                    .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                }});
                defer pass.complete();

                // First we draw our background image, if we have one.
                // The bg image shader also draws the main bg color.
                //
                // Otherwise, if we don't have a background image, we
                // draw the background color by itself in its own step.
                //
                // NOTE: We don't use the clear_color for this because that
                //       would require us to do color space conversion on the
                //       CPU-side. In the future when we have utilities for
                //       that we should remove this step and use clear_color.
                if (self.bg_image) |img| switch (img) {
                    .ready => |texture| pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_image,
                        .uniforms = frame.uniforms.buffer,
                        .buffers = &.{frame.bg_image_buffer.buffer},
                        .textures = &.{texture},
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    }),
                    else => {},
                } else {
                    pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_color,
                        .uniforms = frame.uniforms.buffer,
                        .buffers = &.{ null, frame.cells_bg.buffer },
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    });
                }

                // Then we draw any kitty images that need
                // to be behind text AND cell backgrounds.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_bg,
                );

                // Then we draw any opaque cell backgrounds.
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_bg,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{ null, frame.cells_bg.buffer },
                    .draw = .{ .type = .triangle, .vertex_count = 3 },
                });

                // Kitty images between cell backgrounds and text.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_text,
                );

                // Text.
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_text,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{
                        frame.cells.buffer,
                        frame.cells_bg.buffer,
                    },
                    .textures = &.{
                        frame.grayscale,
                        frame.color,
                    },
                    .draw = .{
                        .type = .triangle_strip,
                        .vertex_count = 4,
                        .instance_count = fg_count,
                    },
                });

                // Kitty images in front of text.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_above_text,
                );

                // Debug overlay. We do this before any custom shader state
                // because our debug overlay is aligned with the grid.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .overlay,
                );
            }

            // If we have custom shaders, then we render them.
            if (frame.custom_shader_state) |*state| {
                // Sync our uniforms.
                try state.uniforms.sync(&.{self.custom_shader_uniforms});

                for (self.shaders.post_pipelines, 0..) |pipeline, i| {
                    defer state.swap();

                    var pass = frame_ctx.renderPass(&.{.{
                        .target = if (i < self.shaders.post_pipelines.len - 1)
                            .{ .texture = state.front_texture }
                        else
                            .{ .target = frame.target },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                    }});
                    defer pass.complete();

                    pass.step(.{
                        .pipeline = pipeline,
                        .uniforms = state.uniforms.buffer,
                        .textures = &.{state.back_texture},
                        .samplers = &.{state.sampler},
                        .draw = .{
                            .type = .triangle,
                            .vertex_count = 3,
                        },
                    });
                }
            }
        }

        // Callback from the graphics API when a frame is completed.
        pub fn frameCompleted(
            self: *Self,
            health: Health,
        ) void {
            // If our health value hasn't changed, then we do nothing. We don't
            // do a cmpxchg here because strict atomicity isn't important.
            if (self.health.load(.seq_cst) != health) {
                self.health.store(health, .seq_cst);

                // Our health value changed, so we notify the surface so that it
                // can do something about it.
                _ = self.surface_mailbox.push(.{
                    .renderer_health = health,
                }, .{ .forever = {} });
            }

            // Always release our semaphore
            self.swap_chain.releaseFrame();
        }

        fn drawImagePlacements(
            self: *Self,
            pass: *RenderPass,
            placements: []const imagepkg.Placement,
        ) !void {
            if (placements.len == 0) return;

            for (placements) |p| {

                // Look up the image
                const image = self.images.get(p.image_id) orelse {
                    log.warn("image not found for placement image_id={}", .{p.image_id});
                    continue;
                };

                // Get the texture
                const texture = switch (image.image) {
                    .ready,
                    .unload_ready,
                    => |t| t,
                    else => {
                        log.warn("image not ready for placement image_id={}", .{p.image_id});
                        continue;
                    },
                };

                // Create our vertex buffer, which is always exactly one item.
                // future(mitchellh): we can group rendering multiple instances of a single image
                var buf = try Buffer(shaderpkg.Image).initFill(
                    self.api.imageBufferOptions(),
                    &.{.{
                        .grid_pos = .{
                            @as(f32, @floatFromInt(p.x)),
                            @as(f32, @floatFromInt(p.y)),
                        },

                        .cell_offset = .{
                            @as(f32, @floatFromInt(p.cell_offset_x)),
                            @as(f32, @floatFromInt(p.cell_offset_y)),
                        },

                        .source_rect = .{
                            @as(f32, @floatFromInt(p.source_x)),
                            @as(f32, @floatFromInt(p.source_y)),
                            @as(f32, @floatFromInt(p.source_width)),
                            @as(f32, @floatFromInt(p.source_height)),
                        },

                        .dest_size = .{
                            @as(f32, @floatFromInt(p.width)),
                            @as(f32, @floatFromInt(p.height)),
                        },
                    }},
                );
                defer buf.deinit();

                pass.step(.{
                    .pipeline = self.shaders.pipelines.image,
                    .buffers = &.{buf.buffer},
                    .textures = &.{texture},
                    .draw = .{
                        .type = .triangle_strip,
                        .vertex_count = 4,
                    },
                });
            }
        }

        /// Call this any time the background image path changes.
        ///
        /// Caller must hold the draw mutex.
        fn prepBackgroundImage(self: *Self) !void {
            // Then we try to load the background image if we have a path.
            if (self.config.bg_image) |p| load_background: {
                const path = switch (p) {
                    .required, .optional => |slice| slice,
                };

                // Open the file
                var file = std.fs.openFileAbsolute(path, .{}) catch |err| {
                    log.warn(
                        "error opening background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer file.close();

                // Read it
                const contents = file.readToEndAlloc(
                    self.alloc,
                    std.math.maxInt(u32), // Max size of 4 GiB, for now.
                ) catch |err| {
                    log.warn(
                        "error reading background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer self.alloc.free(contents);

                // Figure out what type it probably is.
                const file_type = switch (FileType.detect(contents)) {
                    .unknown => FileType.guessFromExtension(
                        std.fs.path.extension(path),
                    ),
                    else => |t| t,
                };

                // Decode it if we know how.
                const image_data = switch (file_type) {
                    .png => try wuffs.png.decode(self.alloc, contents),
                    .jpeg => try wuffs.jpeg.decode(self.alloc, contents),
                    .unknown => {
                        log.warn(
                            "Cannot determine file type for background image file \"{s}\"!",
                            .{path},
                        );
                        break :load_background;
                    },
                    else => |f| {
                        log.warn(
                            "Unsupported file type {} for background image file \"{s}\"!",
                            .{ f, path },
                        );
                        break :load_background;
                    },
                };

                const image: imagepkg.Image = .{
                    .pending = .{
                        .width = image_data.width,
                        .height = image_data.height,
                        .pixel_format = .rgba,
                        .data = image_data.data.ptr,
                    },
                };

                // If we have an existing background image, replace it.
                // Otherwise, set this as our background image directly.
                if (self.bg_image) |*img| {
                    img.markForReplace(self.alloc, image);
                } else {
                    self.bg_image = image;
                }
            } else {
                // If we don't have a background image path, mark our
                // background image for unload if we currently have one.
                if (self.bg_image) |*img| img.markForUnload();
            }
        }

        fn uploadBackgroundImage(self: *Self) !void {
            // Make sure our bg image is uploaded if it needs to be.
            if (self.bg_image) |*bg| {
                if (bg.isUnloading()) {
                    bg.deinit(self.alloc);
                    self.bg_image = null;
                    return;
                }
                if (bg.isPending()) try bg.upload(self.alloc, &self.api);
            }
        }

        /// Update the configuration.
        pub fn changeConfig(self: *Self, config: *DerivedConfig) !void {
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // We always redo the font shaper in case font features changed. We
            // could check to see if there was an actual config change but this is
            // easier and rare enough to not cause performance issues.
            {
                var font_shaper = try font.Shaper.init(self.alloc, .{
                    .features = config.font_features.items,
                });
                errdefer font_shaper.deinit();
                self.font_shaper.deinit();
                self.font_shaper = font_shaper;
            }

            // We also need to reset the shaper cache so shaper info
            // from the previous font isn't reused for the new font.
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;

            // Set our new minimum contrast
            self.uniforms.min_contrast = config.min_contrast;

            // Set our new color space and blending
            self.uniforms.bools.use_display_p3 = config.colorspace == .@"display-p3";
            self.uniforms.bools.use_linear_blending = config.blending.isLinear();
            self.uniforms.bools.use_linear_correction = config.blending == .@"linear-corrected";

            const bg_image_config_changed =
                self.config.bg_image_fit != config.bg_image_fit or
                self.config.bg_image_position != config.bg_image_position or
                self.config.bg_image_repeat != config.bg_image_repeat or
                self.config.bg_image_opacity != config.bg_image_opacity;

            const bg_image_changed =
                if (self.config.bg_image) |old|
                    if (config.bg_image) |new|
                        !old.equal(new)
                    else
                        true
                else
                    config.bg_image != null;

            const old_blending = self.config.blending;
            const custom_shaders_changed = !self.config.custom_shaders.equal(config.custom_shaders);

            self.config.deinit();
            self.config = config.*;

            // If our background image path changed, prepare the new bg image.
            if (bg_image_changed) try self.prepBackgroundImage();

            // If our background image config changed, update the vertex buffer.
            if (bg_image_config_changed) self.updateBgImageBuffer();

            // Reset our viewport to force a rebuild, in case of a font change.
            self.markDirty();

            const blending_changed = old_blending != config.blending;

            if (blending_changed) {
                // We update our API's blending mode.
                self.api.blending = config.blending;
                // And indicate that we need to reinitialize our shaders.
                self.reinitialize_shaders = true;
                // And indicate that our swap chain targets need to
                // be re-created to account for the new blending mode.
                self.target_config_modified +%= 1;
            }

            if (custom_shaders_changed) {
                self.reinitialize_shaders = true;
            }
        }

        /// Resize the screen.
        pub fn setScreenSize(
            self: *Self,
            size: renderer.Size,
        ) void {
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // We only actually need the padding from this,
            // everything else is derived elsewhere.
            self.size.padding = size.padding;

            self.updateScreenSizeUniforms();

            // Mark terminal as dirty to force full redraw on resize.
            // This ensures content is properly re-rendered after size changes.
            self.terminal_state.dirty = .full;
            self.cells_rebuilt = true;

            log.debug("screen size size={}", .{size});
        }

        /// Update uniforms that are based on the screen size.
        ///
        /// Caller must hold the draw mutex.
        fn updateScreenSizeUniforms(self: *Self) void {
            const terminal_size = self.size.terminal();

            // Blank space around the grid.
            const blank: renderer.Padding = self.size.screen.blankPadding(
                self.size.padding,
                .{
                    .columns = self.cells.size.columns,
                    .rows = self.cells.size.rows,
                },
                .{
                    .width = self.grid_metrics.cell_width,
                    .height = self.grid_metrics.cell_height,
                },
            ).add(self.size.padding);

            // Setup our uniforms
            self.uniforms.projection_matrix = math.ortho2d(
                -1 * @as(f32, @floatFromInt(self.size.padding.left)),
                @floatFromInt(terminal_size.width + self.size.padding.right),
                @floatFromInt(terminal_size.height + self.size.padding.bottom),
                -1 * @as(f32, @floatFromInt(self.size.padding.top)),
            );
            self.uniforms.grid_padding = .{
                @floatFromInt(blank.top),
                @floatFromInt(blank.right),
                @floatFromInt(blank.bottom),
                @floatFromInt(blank.left),
            };
            self.uniforms.screen_size = .{
                @floatFromInt(self.size.screen.width),
                @floatFromInt(self.size.screen.height),
            };
        }

        /// Update the background image vertex buffer (CPU-side).
        ///
        /// This should be called if and when configs change that
        /// could affect the background image.
        ///
        /// Caller must hold the draw mutex.
        fn updateBgImageBuffer(self: *Self) void {
            self.bg_image_buffer = .{
                .opacity = self.config.bg_image_opacity,
                .info = .{
                    .position = switch (self.config.bg_image_position) {
                        .@"top-left" => .tl,
                        .@"top-center" => .tc,
                        .@"top-right" => .tr,
                        .@"center-left" => .ml,
                        .@"center-center", .center => .mc,
                        .@"center-right" => .mr,
                        .@"bottom-left" => .bl,
                        .@"bottom-center" => .bc,
                        .@"bottom-right" => .br,
                    },
                    .fit = switch (self.config.bg_image_fit) {
                        .contain => .contain,
                        .cover => .cover,
                        .stretch => .stretch,
                        .none => .none,
                    },
                    .repeat = self.config.bg_image_repeat,
                },
            };
            // Signal that the buffer was modified.
            self.bg_image_buffer_modified +%= 1;
        }

        /// Update custom shader uniforms that depend on terminal state.
        ///
        /// This should be called in `updateFrame` when terminal state changes.
        fn updateCustomShaderUniformsFromState(self: *Self) void {
            // We only need to do this if we have custom shaders.
            if (!self.has_custom_shaders) return;

            // Only update when terminal state is dirty.
            if (self.terminal_state.dirty == .false) return;

            const colors: *const terminal.RenderState.Colors = &self.terminal_state.colors;

            // 256-color palette
            for (colors.palette, 0..) |color, i| {
                self.custom_shader_uniforms.palette[i] = .{
                    @as(f32, @floatFromInt(color.r)) / 255.0,
                    @as(f32, @floatFromInt(color.g)) / 255.0,
                    @as(f32, @floatFromInt(color.b)) / 255.0,
                    1.0,
                };
            }

            // Background color
            self.custom_shader_uniforms.background_color = .{
                @as(f32, @floatFromInt(colors.background.r)) / 255.0,
                @as(f32, @floatFromInt(colors.background.g)) / 255.0,
                @as(f32, @floatFromInt(colors.background.b)) / 255.0,
                1.0,
            };

            // Foreground color
            self.custom_shader_uniforms.foreground_color = .{
                @as(f32, @floatFromInt(colors.foreground.r)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.g)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.b)) / 255.0,
                1.0,
            };

            // Cursor color
            if (colors.cursor) |cursor_color| {
                self.custom_shader_uniforms.cursor_color = .{
                    @as(f32, @floatFromInt(cursor_color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.b)) / 255.0,
                    1.0,
                };
            }

            // NOTE: the following could be optimized to follow a change in
            // config for a slight optimization however this is only 12 bytes
            // each being updated and likely isn't a cause for concern

            // Cursor text color
            if (self.config.cursor_text) |cursor_text| {
                self.custom_shader_uniforms.cursor_text = .{
                    @as(f32, @floatFromInt(cursor_text.color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.b)) / 255.0,
                    1.0,
                };
            }

            // Selection background color
            if (self.config.selection_background) |selection_bg| {
                self.custom_shader_uniforms.selection_background_color = .{
                    @as(f32, @floatFromInt(selection_bg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.b)) / 255.0,
                    1.0,
                };
            }

            // Selection foreground color
            if (self.config.selection_foreground) |selection_fg| {
                self.custom_shader_uniforms.selection_foreground_color = .{
                    @as(f32, @floatFromInt(selection_fg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.b)) / 255.0,
                    1.0,
                };
            }
        }

        /// Update per-frame custom shader uniforms.
        ///
        /// This should be called exactly once per frame, inside `drawFrame`.
        fn updateCustomShaderUniformsForFrame(self: *Self) !void {
            // We only need to do this if we have custom shaders.
            if (!self.has_custom_shaders) return;

            const uniforms = &self.custom_shader_uniforms;

            const now = try std.time.Instant.now();
            defer self.last_frame_time = now;
            const first_frame_time = self.first_frame_time orelse t: {
                self.first_frame_time = now;
                break :t now;
            };
            const last_frame_time = self.last_frame_time orelse now;

            const since_ns: f32 = @floatFromInt(now.since(first_frame_time));
            uniforms.time = since_ns / std.time.ns_per_s;

            const delta_ns: f32 = @floatFromInt(now.since(last_frame_time));
            uniforms.time_delta = delta_ns / std.time.ns_per_s;

            uniforms.frame += 1;

            const screen = self.size.screen;
            const padding = self.size.padding;
            const cell = self.size.cell;

            uniforms.resolution = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
            };
            uniforms.channel_resolution[0] = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
                0,
            };

            // Update custom cursor uniforms, if we have a cursor.
            if (self.cells.getCursorGlyph()) |cursor| {
                const cursor_width: f32 = @floatFromInt(cursor.glyph_size[0]);
                const cursor_height: f32 = @floatFromInt(cursor.glyph_size[1]);

                // Left edge of the cell the cursor is in.
                var pixel_x: f32 = @floatFromInt(
                    cursor.grid_pos[0] * cell.width + padding.left,
                );
                // Top edge, relative to the top of the
                // screen, of the cell the cursor is in.
                var pixel_y: f32 = @floatFromInt(
                    cursor.grid_pos[1] * cell.height + padding.top,
                );

                // If +Y is up in our shaders, we need to flip the coordinate
                // so that it's instead the top edge of the cell relative to
                // the *bottom* of the screen.
                if (!GraphicsAPI.custom_shader_y_is_down) {
                    pixel_y = @as(f32, @floatFromInt(screen.height)) - pixel_y;
                }

                // Add the X bearing to get the -X (left) edge of the cursor.
                pixel_x += @floatFromInt(cursor.bearings[0]);

                // How we deal with the Y bearing depends on which direction
                // is "up", since we want our final `pixel_y` value to be the
                // +Y edge of the cursor.
                if (GraphicsAPI.custom_shader_y_is_down) {
                    // As a reminder, the Y bearing is the distance from the
                    // bottom of the cell to the top of the glyph, so to get
                    // the +Y edge we need to add the cell height, subtract
                    // the Y bearing, and add the glyph height to get the +Y
                    // (bottom) edge of the cursor.
                    pixel_y += @floatFromInt(cell.height);
                    pixel_y -= @floatFromInt(cursor.bearings[1]);
                    pixel_y += @floatFromInt(cursor.glyph_size[1]);
                } else {
                    // If the Y direction is reversed though, we instead want
                    // the *top* edge of the cursor, which means we just need
                    // to subtract the cell height and add the Y bearing.
                    pixel_y -= @floatFromInt(cell.height);
                    pixel_y += @floatFromInt(cursor.bearings[1]);
                }

                const new_cursor: [4]f32 = .{
                    pixel_x,
                    pixel_y,
                    cursor_width,
                    cursor_height,
                };
                const cursor_color: [4]f32 = .{
                    @as(f32, @floatFromInt(cursor.color[0])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[1])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[2])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[3])) / 255.0,
                };

                const cursor_changed: bool =
                    !std.meta.eql(new_cursor, uniforms.current_cursor) or
                    !std.meta.eql(cursor_color, uniforms.current_cursor_color);

                if (cursor_changed) {
                    uniforms.previous_cursor = uniforms.current_cursor;
                    uniforms.previous_cursor_color = uniforms.current_cursor_color;
                    uniforms.current_cursor = new_cursor;
                    uniforms.current_cursor_color = cursor_color;
                    uniforms.cursor_change_time = uniforms.time;
                }
            }

            // Update focus uniforms
            uniforms.focus = @intFromBool(self.focused);

            // If we need to update the time our focus state changed
            // then update it to our current frame time. This may not be
            // exactly correct since it is frame time, not exact focus
            // time, but focus time on its own isn't exactly correct anyways
            // since it comes async from a message.
            if (self.custom_shader_focused_changed and self.focused) {
                uniforms.time_focus = uniforms.time;
                self.custom_shader_focused_changed = false;
            }
        }

        /// Build the overlay as configured. Returns null if there is no
        /// overlay currently configured.
        fn rebuildOverlay(
            self: *Self,
            features: []const Overlay.Feature,
        ) Overlay.InitError!void {
            // const start = std.time.Instant.now() catch unreachable;
            // const start_micro = std.time.microTimestamp();
            // defer {
            //     const end = std.time.Instant.now() catch unreachable;
            //     log.warn(
            //         "[rebuildOverlay time] start_micro={} duration={}ns",
            //         .{ start_micro, end.since(start) / std.time.ns_per_us },
            //     );
            // }

            const alloc = self.alloc;

            // If we have no features enabled, don't build an overlay.
            // If we had a previous overlay, deallocate it.
            if (features.len == 0) {
                if (self.overlay) |*old| {
                    old.deinit(alloc);
                    self.overlay = null;
                }

                return;
            }

            // If we had a previous overlay, clear it. Otherwise, init.
            const overlay: *Overlay = if (self.overlay) |*v| overlay: {
                v.reset();
                break :overlay v;
            } else overlay: {
                const new: Overlay = try .init(alloc, self.size);
                self.overlay = new;
                break :overlay &self.overlay.?;
            };
            overlay.applyFeatures(
                alloc,
                &self.terminal_state,
                features,
            );
        }

        const PreeditRange = struct {
            y: terminal.size.CellCountInt,
            x: [2]terminal.size.CellCountInt,
            cp_offset: usize,
        };

        /// Convert the terminal state to GPU cells stored in CPU memory. These
        /// are then synced to the GPU in the next frame. This only updates CPU
        /// memory and doesn't touch the GPU.
        ///
        /// This requires the draw mutex.
        ///
        /// Dirty state on terminal state won't be reset by this.
        fn rebuildCells(
            self: *Self,
            preedit: ?renderer.State.Preedit,
            cursor_style_: ?renderer.CursorStyle,
            links: *const terminal.RenderState.CellSet,
        ) Allocator.Error!void {
            const state: *terminal.RenderState = &self.terminal_state;

            // const start = try std.time.Instant.now();
            // const start_micro = std.time.microTimestamp();
            // defer {
            //     const end = std.time.Instant.now() catch unreachable;
            //     // "[rebuildCells time] <START us>\t<TIME_TAKEN us>"
            //     std.log.warn("[rebuildCells time] {}\t{}", .{start_micro, end.since(start) / std.time.ns_per_us});
            // }

            // Determine our x/y range for preedit. We don't want to render anything
            // here because we will render the preedit separately.
            const preedit_range: ?PreeditRange = if (preedit) |preedit_v| preedit: {
                // We base the preedit on the position of the cursor in the
                // viewport. If the cursor isn't visible in the viewport we
                // don't show it.
                const cursor_vp = state.cursor.viewport orelse
                    break :preedit null;

                const range = preedit_v.range(
                    cursor_vp.x,
                    state.cols - 1,
                );
                break :preedit .{
                    .y = @intCast(cursor_vp.y),
                    .x = .{ range.start, range.end },
                    .cp_offset = range.cp_offset,
                };
            } else null;

            const grid_size_diff =
                self.cells.size.rows != state.rows or
                self.cells.size.columns != state.cols;

            if (grid_size_diff) {
                var new_size = self.cells.size;
                new_size.rows = state.rows;
                new_size.columns = state.cols;
                try self.cells.resize(self.alloc, new_size);

                // Update our uniforms accordingly, otherwise
                // our background cells will be out of place.
                self.uniforms.grid_size = .{ new_size.columns, new_size.rows };
            }

            const rebuild = state.dirty == .full or grid_size_diff;
            if (rebuild) {
                // If we are doing a full rebuild, then we clear the entire cell buffer.
                self.cells.reset();

                // We also reset our padding extension depending on the screen type
                switch (self.config.padding_color) {
                    .background => {},

                    // For extension, assume we are extending in all directions.
                    // For "extend" this may be disabled due to heuristics below.
                    .extend, .@"extend-always" => {
                        self.uniforms.padding_extend = .{
                            .up = true,
                            .down = true,
                            .left = true,
                            .right = true,
                        };
                    },
                }
            }

            // From this point on we never fail. We produce some kind of
            // working terminal state, even if incorrect.
            errdefer comptime unreachable;

            // Get our row data from our state
            const row_data = state.row_data.slice();
            const row_raws = row_data.items(.raw);
            const row_cells = row_data.items(.cells);
            const row_dirty = row_data.items(.dirty);
            const row_selection = row_data.items(.selection);
            const row_highlights = row_data.items(.highlights);

            // If our cell contents buffer is shorter than the screen viewport,
            // we render the rows that fit, starting from the bottom. If instead
            // the viewport is shorter than the cell contents buffer, we align
            // the top of the viewport with the top of the contents buffer.
            const row_len: usize = @min(
                state.rows,
                self.cells.size.rows,
            );
            for (
                0..,
                row_raws[0..row_len],
                row_cells[0..row_len],
                row_dirty[0..row_len],
                row_selection[0..row_len],
                row_highlights[0..row_len],
            ) |y_usize, row, *cells, *dirty, selection, *highlights| {
                const y: terminal.size.CellCountInt = @intCast(y_usize);

                if (!rebuild) {
                    // Only rebuild if we are doing a full rebuild or this row is dirty.
                    if (!dirty.*) continue;

                    // Clear the cells if the row is dirty
                    self.cells.clear(y);
                }

                // Unmark the dirty state in our render state.
                dirty.* = false;

                self.rebuildRow(
                    y,
                    row,
                    cells,
                    preedit_range,
                    selection,
                    highlights,
                    links,
                ) catch |err| {
                    // This should never happen except under exceptional
                    // scenarios. In this case, we don't want to corrupt
                    // our render state so just clear this row and keep
                    // trying to finish it out.
                    log.warn("error building row y={} err={}", .{ y, err });
                    self.cells.clear(y);
                };
            }

            // Setup our cursor rendering information.
            cursor: {
                // Clear our cursor by default.
                self.cells.setCursor(null, null);
                self.uniforms.cursor_pos = .{
                    std.math.maxInt(u16),
                    std.math.maxInt(u16),
                };

                // If the cursor isn't visible on the viewport, don't show
                // a cursor. Otherwise, get our cursor cell, because we may
                // need it for styling.
                const cursor_vp = state.cursor.viewport orelse break :cursor;
                const cursor_style: terminal.Style = cursor_style: {
                    const cells = state.row_data.items(.cells);
                    const cell = cells[cursor_vp.y].get(cursor_vp.x);
                    break :cursor_style if (cell.raw.hasStyling())
                        cell.style
                    else
                        .{};
                };

                // If we have preedit text, we don't setup a cursor
                if (preedit != null) break :cursor;

                // If there isn't a cursor visual style requested then
                // we don't render a cursor.
                const style = cursor_style_ orelse break :cursor;

                // Determine the cursor color.
                const cursor_color = cursor_color: {
                    // If an explicit cursor color was set by OSC 12, use that.
                    if (state.colors.cursor) |v| break :cursor_color v;

                    // Use our configured color if specified
                    if (self.config.cursor_color) |v| switch (v) {
                        .color => |color| break :cursor_color color.toTerminalRGB(),

                        inline .@"cell-foreground",
                        .@"cell-background",
                        => |_, tag| {
                            const fg_style = cursor_style.fg(.{
                                .default = state.colors.foreground,
                                .palette = &state.colors.palette,
                                .bold = self.config.bold_color,
                            });
                            const bg_style = cursor_style.bg(
                                &state.cursor.cell,
                                &state.colors.palette,
                            ) orelse state.colors.background;

                            break :cursor_color switch (tag) {
                                .color => unreachable,
                                .@"cell-foreground" => if (cursor_style.flags.inverse)
                                    bg_style
                                else
                                    fg_style,
                                .@"cell-background" => if (cursor_style.flags.inverse)
                                    fg_style
                                else
                                    bg_style,
                            };
                        },
                    };

                    break :cursor_color state.colors.foreground;
                };

                self.addCursor(
                    &state.cursor,
                    style,
                    cursor_color,
                );

                // If the cursor is visible then we set our uniforms.
                if (style == .block) {
                    const wide = state.cursor.cell.wide;

                    self.uniforms.cursor_pos = .{
                        // If we are a spacer tail of a wide cell, our cursor needs
                        // to move back one cell. The saturate is to ensure we don't
                        // overflow but this shouldn't happen with well-formed input.
                        switch (wide) {
                            .narrow, .spacer_head, .wide => cursor_vp.x,
                            .spacer_tail => cursor_vp.x -| 1,
                        },
                        @intCast(cursor_vp.y),
                    };

                    self.uniforms.bools.cursor_wide = switch (wide) {
                        .narrow, .spacer_head => false,
                        .wide, .spacer_tail => true,
                    };

                    const uniform_color = if (self.config.cursor_text) |txt| blk: {
                        // If cursor-text is set, then compute the correct color.
                        // Otherwise, use the background color.
                        if (txt == .color) {
                            // Use the color set by cursor-text, if any.
                            break :blk txt.color.toTerminalRGB();
                        }

                        const fg_style = cursor_style.fg(.{
                            .default = state.colors.foreground,
                            .palette = &state.colors.palette,
                            .bold = self.config.bold_color,
                        });
                        const bg_style = cursor_style.bg(
                            &state.cursor.cell,
                            &state.colors.palette,
                        ) orelse state.colors.background;

                        break :blk switch (txt) {
                            // If the cell is reversed, use the opposite cell color instead.
                            .@"cell-foreground" => if (cursor_style.flags.inverse)
                                bg_style
                            else
                                fg_style,
                            .@"cell-background" => if (cursor_style.flags.inverse)
                                fg_style
                            else
                                bg_style,
                            else => unreachable,
                        };
                    } else state.colors.background;

                    self.uniforms.cursor_color = .{
                        uniform_color.r,
                        uniform_color.g,
                        uniform_color.b,
                        255,
                    };
                }
            }

            // Update cursor animation state (simple offset-based for terminal mode)
            cursor_anim: {
                const cursor_x = self.uniforms.cursor_pos[0];
                const cursor_y = self.uniforms.cursor_pos[1];

                if (cursor_x == std.math.maxInt(u16) or cursor_y == std.math.maxInt(u16)) {
                    self.cursor_animation.snap();
                    self.uniforms.cursor_offset_x = 0;
                    self.uniforms.cursor_offset_y = 0;
                    self.uniforms.cursor_use_corners = if (@TypeOf(self.uniforms.cursor_use_corners) == bool) false else 0;
                    self.cursor_animating = false;
                    break :cursor_anim;
                }

                const cell_width: f32 = @floatFromInt(self.grid_metrics.cell_width);
                const cell_height: f32 = @floatFromInt(self.grid_metrics.cell_height);
                const target_pixel_x: f32 = @as(f32, @floatFromInt(cursor_x)) * cell_width;
                const target_pixel_y: f32 = @as(f32, @floatFromInt(cursor_y)) * cell_height;

                const last_x = self.last_cursor_grid_pos[0];
                const last_y = self.last_cursor_grid_pos[1];

                if (cursor_x != last_x or cursor_y != last_y) {
                    self.cursor_animation.setTarget(target_pixel_x, target_pixel_y, cell_width);
                    self.last_cursor_grid_pos = .{ cursor_x, cursor_y };
                    self.cursor_animating = true;
                }

                // Simple offset-based animation for terminal mode
                self.uniforms.cursor_use_corners = if (@TypeOf(self.uniforms.cursor_use_corners) == bool) false else 0;

                const pos = self.cursor_animation.getPosition();
                self.uniforms.cursor_offset_x = pos.x - target_pixel_x;
                self.uniforms.cursor_offset_y = pos.y - target_pixel_y;
            }

            // Setup our preedit text.
            if (preedit) |preedit_v| {
                const range = preedit_range.?;
                var x = range.x[0];
                for (preedit_v.codepoints[range.cp_offset..]) |cp| {
                    self.addPreeditCell(
                        cp,
                        .{ .x = x, .y = range.y },
                        state.colors.background,
                        state.colors.foreground,
                    ) catch |err| {
                        log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
                            x,
                            range.y,
                            err,
                        });
                    };

                    x += if (cp.wide) 2 else 1;
                }
            }

            // Update that our cells rebuilt
            self.cells_rebuilt = true;

            // Log some things
            // log.debug("rebuildCells complete cached_runs={}", .{
            //     self.font_shaper_cache.count(),
            // });
        }

        fn rebuildRow(
            self: *Self,
            y: terminal.size.CellCountInt,
            row: terminal.page.Row,
            cells: *std.MultiArrayList(terminal.RenderState.Cell),
            preedit_range: ?PreeditRange,
            selection: ?[2]terminal.size.CellCountInt,
            highlights: *const std.ArrayList(terminal.RenderState.Highlight),
            links: *const terminal.RenderState.CellSet,
        ) !void {
            const state = &self.terminal_state;

            // If our viewport is wider than our cell contents buffer,
            // we still only process cells up to the width of the buffer.
            const cells_slice = cells.slice();
            const cells_len = @min(cells_slice.len, self.cells.size.columns);
            const cells_raw = cells_slice.items(.raw);
            const cells_style = cells_slice.items(.style);

            // On primary screen, we still apply vertical padding
            // extension under certain conditions we feel are safe.
            //
            // This helps make some scenarios look better while
            // avoiding scenarios we know do NOT look good.
            switch (self.config.padding_color) {
                // These already have the correct values set above.
                .background, .@"extend-always" => {},

                // Apply heuristics for padding extension.
                .extend => if (y == 0) {
                    self.uniforms.padding_extend.up = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                } else if (y == self.cells.size.rows - 1) {
                    self.uniforms.padding_extend.down = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                },
            }

            // Iterator of runs for shaping.
            var run_iter_opts: font.shape.RunOptions = .{
                .grid = self.font_grid,
                .cells = cells_slice,
                .selection = if (selection) |s| s else null,

                // We want to do font shaping as long as the cursor is
                // visible on this viewport.
                .cursor_x = cursor_x: {
                    const vp = state.cursor.viewport orelse break :cursor_x null;
                    if (vp.y != y) break :cursor_x null;
                    break :cursor_x vp.x;
                },
            };
            run_iter_opts.applyBreakConfig(self.config.font_shaping_break);
            var run_iter = self.font_shaper.runIterator(run_iter_opts);
            var shaper_run: ?font.shape.TextRun = try run_iter.next(self.alloc);
            var shaper_cells: ?[]const font.shape.Cell = null;
            var shaper_cells_i: usize = 0;

            for (
                0..,
                cells_raw[0..cells_len],
                cells_style[0..cells_len],
            ) |x, *cell, *managed_style| {
                // If this cell falls within our preedit range then we
                // skip this because preedits are setup separately.
                if (preedit_range) |range| preedit: {
                    // We're not on the preedit line, no actions necessary.
                    if (range.y != y) break :preedit;
                    // We're before the preedit range, no actions necessary.
                    if (x < range.x[0]) break :preedit;
                    // We're in the preedit range, skip this cell.
                    if (x <= range.x[1]) continue;
                    // After exiting the preedit range we need to catch
                    // the run position up because of the missed cells.
                    // In all other cases, no action is necessary.
                    if (x != range.x[1] + 1) break :preedit;

                    // Step the run iterator until we find a run that ends
                    // after the current cell, which will be the soonest run
                    // that might contain glyphs for our cell.
                    while (shaper_run) |run| {
                        if (run.offset + run.cells > x) break;
                        shaper_run = try run_iter.next(self.alloc);
                        shaper_cells = null;
                        shaper_cells_i = 0;
                    }

                    const run = shaper_run orelse break :preedit;

                    // If we haven't shaped this run, do so now.
                    shaper_cells = shaper_cells orelse
                        // Try to read the cells from the shaping cache if we can.
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            // Otherwise we have to shape them.
                            const new_cells = try self.font_shaper.shape(run);

                            // Try to cache them. If caching fails for any reason we
                            // continue because it is just a performance optimization,
                            // not a correctness issue.
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };

                            // The cells we get from direct shaping are always owned
                            // by the shaper and valid until the next shaping call so
                            // we can safely use them.
                            break :cache new_cells;
                        };

                    // Advance our index until we reach or pass
                    // our current x position in the shaper cells.
                    const shaper_cells_unwrapped = shaper_cells.?;
                    while (run.offset + shaper_cells_unwrapped[shaper_cells_i].x < x) {
                        shaper_cells_i += 1;
                    }
                }

                const wide = cell.wide;
                const style: terminal.Style = if (cell.hasStyling())
                    managed_style.*
                else
                    .{};

                // True if this cell is selected
                const selected: enum {
                    false,
                    selection,
                    search,
                    search_selected,
                } = selected: {
                    // Order below matters for precedence.

                    // Selection should take the highest precedence.
                    const x_compare = if (wide == .spacer_tail)
                        x -| 1
                    else
                        x;
                    if (selection) |sel| {
                        if (x_compare >= sel[0] and
                            x_compare <= sel[1]) break :selected .selection;
                    }

                    // If we're highlighted, then we're selected. In the
                    // future we want to use a different style for this
                    // but this to get started.
                    for (highlights.items) |hl| {
                        if (x_compare >= hl.range[0] and
                            x_compare <= hl.range[1])
                        {
                            const tag: HighlightTag = @enumFromInt(hl.tag);
                            break :selected switch (tag) {
                                .search_match => .search,
                                .search_match_selected => .search_selected,
                            };
                        }
                    }

                    break :selected .false;
                };

                // The `_style` suffixed values are the colors based on
                // the cell style (SGR), before applying any additional
                // configuration, inversions, selections, etc.
                const bg_style = style.bg(
                    cell,
                    &state.colors.palette,
                );
                const fg_style = style.fg(.{
                    .default = state.colors.foreground,
                    .palette = &state.colors.palette,
                    .bold = self.config.bold_color,
                });

                // The final background color for the cell.
                const bg = switch (selected) {
                    // If we have an explicit selection background color
                    // specified in the config, use that.
                    //
                    // If no configuration, then our selection background
                    // is our foreground color.
                    .selection => if (self.config.selection_background) |v| switch (v) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    } else state.colors.foreground,

                    .search => switch (self.config.search_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },

                    .search_selected => switch (self.config.search_selected_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },

                    // Not selected
                    .false => if (style.flags.inverse != isCovering(cell.codepoint()))
                        // Two cases cause us to invert (use the fg color as the bg)
                        // - The "inverse" style flag.
                        // - A "covering" glyph; we use fg for bg in that
                        //   case to help make sure that padding extension
                        //   works correctly.
                        //
                        // If one of these is true (but not the other)
                        // then we use the fg style color for the bg.
                        fg_style
                    else
                        // Otherwise they cancel out.
                        bg_style,
                };

                const fg = fg: {
                    // Our happy-path non-selection background color
                    // is our style or our configured defaults.
                    const final_bg = bg_style orelse state.colors.background;

                    // Whether we need to use the bg color as our fg color:
                    // - Cell is selected, inverted, and set to cell-foreground
                    // - Cell is selected, not inverted, and set to cell-background
                    // - Cell is inverted and not selected
                    break :fg switch (selected) {
                        .selection => if (self.config.selection_foreground) |v| switch (v) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        } else state.colors.background,

                        .search => switch (self.config.search_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },

                        .search_selected => switch (self.config.search_selected_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },

                        .false => if (style.flags.inverse)
                            final_bg
                        else
                            fg_style,
                    };
                };

                // Foreground alpha for this cell.
                const alpha: u8 = if (style.flags.faint) self.config.faint_opacity else 255;

                // Set the cell's background color.
                {
                    const rgb = bg orelse state.colors.background;

                    // Determine our background alpha. If we have transparency configured
                    // then this is dynamic depending on some situations. This is all
                    // in an attempt to make transparency look the best for various
                    // situations. See inline comments.
                    const bg_alpha: u8 = bg_alpha: {
                        const default: u8 = 255;

                        // Cells that are selected should be fully opaque.
                        if (selected != .false) break :bg_alpha default;

                        // Cells that are reversed should be fully opaque.
                        if (style.flags.inverse) break :bg_alpha default;

                        // If the user requested to have opacity on all cells, apply it.
                        if (self.config.background_opacity_cells and bg_style != null) {
                            var opacity: f64 = @floatFromInt(default);
                            opacity *= self.config.background_opacity;
                            break :bg_alpha @intFromFloat(opacity);
                        }

                        // Cells that have an explicit bg color should be fully opaque.
                        if (bg_style != null) break :bg_alpha default;

                        // Otherwise, we won't draw the bg for this cell,
                        // we'll let the already-drawn background color
                        // show through.
                        break :bg_alpha 0;
                    };

                    self.cells.bgCell(y, x).* = .{
                        .color = .{ rgb.r, rgb.g, rgb.b, bg_alpha },
                        .offset_y_fixed = 0,
                    };
                }

                // If the invisible flag is set on this cell then we
                // don't need to render any foreground elements, so
                // we just skip all glyphs with this x coordinate.
                //
                // NOTE: This behavior matches xterm. Some other terminal
                // emulators, e.g. Alacritty, still render text decorations
                // and only make the text itself invisible. The decision
                // has been made here to match xterm's behavior for this.
                if (style.flags.invisible) {
                    continue;
                }

                // Give links a single underline, unless they already have
                // an underline, in which case use a double underline to
                // distinguish them.
                const underline: terminal.Attribute.Underline = underline: {
                    if (links.contains(.{
                        .x = @intCast(x),
                        .y = @intCast(y),
                    })) {
                        break :underline if (style.flags.underline == .single)
                            .double
                        else
                            .single;
                    }
                    break :underline style.flags.underline;
                };

                // We draw underlines first so that they layer underneath text.
                // This improves readability when a colored underline is used
                // which intersects parts of the text (descenders).
                if (underline != .none) self.addUnderline(
                    @intCast(x),
                    @intCast(y),
                    underline,
                    style.underlineColor(&state.colors.palette) orelse fg,
                    alpha,
                    0, // No scroll offset in terminal mode
                ) catch |err| {
                    log.warn(
                        "error adding underline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };

                if (style.flags.overline) self.addOverline(@intCast(x), @intCast(y), fg, alpha) catch |err| {
                    log.warn(
                        "error adding overline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };

                // If we're at or past the end of our shaper run then
                // we need to get the next run from the run iterator.
                if (shaper_cells != null and shaper_cells_i >= shaper_cells.?.len) {
                    shaper_run = try run_iter.next(self.alloc);
                    shaper_cells = null;
                    shaper_cells_i = 0;
                }

                if (shaper_run) |run| glyphs: {
                    // If we haven't shaped this run yet, do so.
                    shaper_cells = shaper_cells orelse
                        // Try to read the cells from the shaping cache if we can.
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            // Otherwise we have to shape them.
                            const new_cells = try self.font_shaper.shape(run);

                            // Try to cache them. If caching fails for any reason we
                            // continue because it is just a performance optimization,
                            // not a correctness issue.
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };

                            // The cells we get from direct shaping are always owned
                            // by the shaper and valid until the next shaping call so
                            // we can safely use them.
                            break :cache new_cells;
                        };

                    const shaped_cells = shaper_cells orelse break :glyphs;

                    // If there are no shaper cells for this run, ignore it.
                    // This can occur for runs of empty cells, and is fine.
                    if (shaped_cells.len == 0) break :glyphs;

                    // If we encounter a shaper cell to the left of the current
                    // cell then we have some problems. This logic relies on x
                    // position monotonically increasing.
                    assert(run.offset + shaped_cells[shaper_cells_i].x >= x);

                    // NOTE: An assumption is made here that a single cell will never
                    // be present in more than one shaper run. If that assumption is
                    // violated, this logic breaks.

                    while (shaper_cells_i < shaped_cells.len and
                        run.offset + shaped_cells[shaper_cells_i].x == x) : ({
                        shaper_cells_i += 1;
                    }) {
                        self.addGlyph(
                            @intCast(x),
                            @intCast(y),
                            state.cols,
                            cells_raw,
                            shaped_cells[shaper_cells_i],
                            shaper_run.?,
                            fg,
                            alpha,
                        ) catch |err| {
                            log.warn(
                                "error adding glyph to cell, will be invalid x={} y={}, err={}",
                                .{ x, y, err },
                            );
                        };
                    }
                }

                // Finally, draw a strikethrough if necessary.
                if (style.flags.strikethrough) self.addStrikethrough(
                    @intCast(x),
                    @intCast(y),
                    fg,
                    alpha,
                    0, // No scroll offset in terminal mode
                ) catch |err| {
                    log.warn(
                        "error adding strikethrough to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };
            }
        }

        /// Add an underline decoration to the specified cell
        fn addUnderline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            style: terminal.Attribute.Underline,
            color: terminal.color.RGB,
            alpha: u8,
            pixel_offset_y: f32,
        ) !void {
            const sprite: font.Sprite = switch (style) {
                .none => unreachable,
                .single => .underline,
                .double => .underline_double,
                .dotted => .underline_dotted,
                .dashed => .underline_dashed,
                .curly => .underline_curly,
            };

            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(sprite),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            const fixed_offset: i16 = @intFromFloat(std.math.clamp(pixel_offset_y * 256.0, -32768.0, 32767.0));

            try self.cells.add(self.alloc, .underline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
                .pixel_offset_y = fixed_offset,
            });
        }

        /// Add a overline decoration to the specified cell
        fn addOverline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.overline),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .overline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
                .pixel_offset_y = 0, // Overline is terminal-only, no scroll offset
            });
        }

        /// Add a strikethrough decoration to the specified cell
        fn addStrikethrough(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
            pixel_offset_y: f32,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.strikethrough),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            const fixed_offset: i16 = @intFromFloat(std.math.clamp(pixel_offset_y * 256.0, -32768.0, 32767.0));

            try self.cells.add(self.alloc, .strikethrough, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
                .pixel_offset_y = fixed_offset,
            });
        }

        // Add a glyph to the specified cell.
        fn addGlyph(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            cols: usize,
            cell_raws: []const terminal.page.Cell,
            shaper_cell: font.shape.Cell,
            shaper_run: font.shape.TextRun,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const cell = cell_raws[x];
            const cp = cell.codepoint();

            // Render
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                shaper_run.font_index,
                shaper_cell.glyph_index,
                .{
                    .grid_metrics = self.grid_metrics,
                    .thicken = self.config.font_thicken,
                    .thicken_strength = self.config.font_thicken_strength,
                    .cell_width = cell.gridWidth(),
                    // If there's no Nerd Font constraint for this codepoint
                    // then, if it's a symbol, we constrain it to fit inside
                    // its cell(s), we don't modify the alignment at all.
                    .constraint = getConstraint(cp) orelse
                        if (cellpkg.isSymbol(cp)) .{
                            .size = .fit,
                        } else .none,
                    .constraint_width = constraintWidth(
                        cell_raws,
                        x,
                        cols,
                    ),
                },
            );

            // If the glyph is 0 width or height, it will be invisible
            // when drawn, so don't bother adding it to the buffer.
            if (render.glyph.width == 0 or render.glyph.height == 0) {
                return;
            }

            try self.cells.add(self.alloc, .text, .{
                .atlas = switch (render.presentation) {
                    .emoji => .color,
                    .text => .grayscale,
                },
                .bools = .{ .no_min_contrast = noMinContrast(cp) },
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x + shaper_cell.x_offset),
                    @intCast(render.glyph.offset_y + shaper_cell.y_offset),
                },
                .pixel_offset_y = 0, // Terminal mode doesn't use per-cell scroll offset
            });
        }

        fn addCursor(
            self: *Self,
            cursor_state: *const terminal.RenderState.Cursor,
            cursor_style: renderer.CursorStyle,
            cursor_color: terminal.color.RGB,
        ) void {
            const cursor_vp = cursor_state.viewport orelse return;

            // Add the cursor. We render the cursor over the wide character if
            // we're on the wide character tail.
            const wide, const x = cell: {
                // The cursor goes over the screen cursor position.
                if (!cursor_vp.wide_tail) break :cell .{
                    cursor_state.cell.wide == .wide,
                    cursor_vp.x,
                };

                // If we're part of a wide character, we move the cursor back
                // to the actual character.
                break :cell .{ true, cursor_vp.x - 1 };
            };

            const alpha: u8 = if (!self.focused) 255 else alpha: {
                const alpha = 255 * self.config.cursor_opacity;
                break :alpha @intFromFloat(@ceil(alpha));
            };

            const render = switch (cursor_style) {
                .block,
                .block_hollow,
                .bar,
                .underline,
                => render: {
                    const sprite: font.Sprite = switch (cursor_style) {
                        .block => .cursor_rect,
                        .block_hollow => .cursor_hollow_rect,
                        .bar => .cursor_bar,
                        .underline => .cursor_underline,
                        .lock => unreachable,
                    };

                    break :render self.font_grid.renderGlyph(
                        self.alloc,
                        font.sprite_index,
                        @intFromEnum(sprite),
                        .{
                            .cell_width = if (wide) 2 else 1,
                            .grid_metrics = self.grid_metrics,
                        },
                    ) catch |err| {
                        log.warn("error rendering cursor glyph err={}", .{err});
                        return;
                    };
                },

                .lock => self.font_grid.renderCodepoint(
                    self.alloc,
                    0xF023, // lock symbol
                    .regular,
                    .text,
                    .{
                        .cell_width = if (wide) 2 else 1,
                        .grid_metrics = self.grid_metrics,
                    },
                ) catch |err| {
                    log.warn("error rendering cursor glyph err={}", .{err});
                    return;
                } orelse {
                    // This should never happen because we embed nerd
                    // fonts so we just log and return instead of fallback.
                    log.warn("failed to find lock symbol for cursor codepoint=0xF023", .{});
                    return;
                },
            };

            self.cells.setCursor(.{
                .atlas = .grayscale,
                .bools = .{ .is_cursor_glyph = true },
                .grid_pos = .{ x, cursor_vp.y },
                .color = .{ cursor_color.r, cursor_color.g, cursor_color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
                .pixel_offset_y = 0, // Terminal mode cursor doesn't have per-cell scroll
            }, cursor_style);
        }

        fn addPreeditCell(
            self: *Self,
            cp: renderer.State.Preedit.Codepoint,
            coord: terminal.Coordinate,
            screen_bg: terminal.color.RGB,
            screen_fg: terminal.color.RGB,
        ) !void {
            // Render the glyph for our preedit text
            const render_ = self.font_grid.renderCodepoint(
                self.alloc,
                @intCast(cp.codepoint),
                .regular,
                .text,
                .{ .grid_metrics = self.grid_metrics },
            ) catch |err| {
                log.warn("error rendering preedit glyph err={}", .{err});
                return;
            };
            const render = render_ orelse {
                log.warn("failed to find font for preedit codepoint={X}", .{cp.codepoint});
                return;
            };

            // Add our opaque background cell
            self.cells.bgCell(coord.y, coord.x).* = .{
                .color = .{ screen_bg.r, screen_bg.g, screen_bg.b, 255 },
                .offset_y_fixed = 0,
            };
            if (cp.wide and coord.x < self.cells.size.columns - 1) {
                self.cells.bgCell(coord.y, coord.x + 1).* = .{
                    .color = .{ screen_bg.r, screen_bg.g, screen_bg.b, 255 },
                    .offset_y_fixed = 0,
                };
            }

            // Add our text
            try self.cells.add(self.alloc, .text, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
                .color = .{ screen_fg.r, screen_fg.g, screen_fg.b, 255 },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
                .pixel_offset_y = 0, // Preedit text doesn't scroll
            });

            // Add underline
            try self.addUnderline(@intCast(coord.x), @intCast(coord.y), .single, screen_fg, 255, 0);
            if (cp.wide and coord.x < self.cells.size.columns - 1) {
                try self.addUnderline(@intCast(coord.x + 1), @intCast(coord.y), .single, screen_fg, 255, 0);
            }
        }

        /// Sync the atlas data to the given texture. This copies the bytes
        /// associated with the atlas to the given texture. If the atlas no
        /// longer fits into the texture, the texture will be resized.
        fn syncAtlasTexture(
            self: *const Self,
            atlas: *const font.Atlas,
            texture: *Texture,
        ) !void {
            if (atlas.size > texture.width) {
                // Free our old texture
                texture.*.deinit();

                // Reallocate
                texture.* = try self.api.initAtlasTexture(atlas);
            }

            try texture.replaceRegion(0, 0, atlas.size, atlas.size, atlas.data);
        }
    };
}
