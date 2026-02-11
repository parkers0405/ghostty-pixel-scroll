const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const math = @import("../../math.zig");

const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.opengl);

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/bg_color.f.glsl"),
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/cell_bg.f.glsl"),
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = loadShaderCode("../shaders/glsl/cell_text.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/cell_text.f.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = loadShaderCode("../shaders/glsl/image.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/image.f.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = loadShaderCode("../shaders/glsl/bg_image.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/bg_image.f.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    blending_enabled: bool = true,

    fn initPipeline(self: PipelineDescription) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .step_fn = self.step_fn,
            .blending_enabled = self.blending_enabled,
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    var fields: [pipeline_descs.len]std.builtin.Type.StructField = undefined;
    for (pipeline_descs, 0..) |pipeline, i| {
        fields[i] = .{
            .name = pipeline[0],
            .type = Pipeline,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Pipeline),
        };
    }
    break :t @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

/// This contains the state for the shaders used by the Metal renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    post_pipelines: []const Pipeline,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    pub fn init(
        alloc: Allocator,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline();
            initialized_pipelines += 1;
        }

        const post_pipelines: []const Pipeline = initPostPipelines(
            alloc,
            post_shaders,
        ) catch |err| err: {
            // If an error happens while building postprocess shaders we
            // want to just not use any postprocess shaders since we don't
            // want to block Ghostty from working.
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };

        return .{
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        // Release our primary shaders
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }

        // Release our postprocess shaders
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.deinit();
            }
            alloc.free(self.post_pipelines);
        }
    }
};

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(4),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans, in a packed struct for space efficiency.
    bools: Bools align(4),

    /// Sub-line pixel scroll offset for smooth scrolling.
    /// Positive values scroll content up (user scrolled into history).
    pixel_scroll_offset_y: f32 align(4) = 0,

    /// Cursor position offset in pixels for smooth cursor animation.
    /// These offsets are applied to the cursor glyph position.
    cursor_offset_x: f32 align(4) = 0,
    cursor_offset_y: f32 align(4) = 0,

    /// Neovide-style stretchy cursor - 4 corner positions in pixels
    /// Order: top-left, top-right, bottom-right, bottom-left
    cursor_corner_tl: [2]f32 align(8) = .{ 0, 0 },
    cursor_corner_tr: [2]f32 align(8) = .{ 0, 0 },
    cursor_corner_br: [2]f32 align(8) = .{ 0, 0 },
    cursor_corner_bl: [2]f32 align(8) = .{ 0, 0 },
    /// Whether to use corner-based cursor rendering (as u32 for GLSL std140 alignment)
    cursor_use_corners: u32 align(4) = 0,

    /// Smooth blink opacity for cursor (0.0 = fully hidden, 1.0 = fully visible).
    cursor_blink_opacity: f32 align(4) = 1.0,

    /// Sonicboom VFX: expanding ring effect on cursor arrival
    sonicboom_center: [2]f32 align(8) = .{ -100, -100 },
    sonicboom_radius: f32 align(4) = 0,
    sonicboom_thickness: f32 align(4) = 3.0,
    sonicboom_color: [4]u8 align(4) = .{ 255, 255, 255, 0 },

    /// TUI smooth scrolling: pixel offset for cells within the scroll region.
    tui_scroll_offset_y: f32 align(4) = 0,
    tui_scroll_region_top: u16 align(2) = 0,
    tui_scroll_region_bottom: u16 align(2) = 0,

    /// SDF rounded corner radius in pixels (0 = disabled)
    corner_radius: f32 align(4) = 0,

    /// Gap color for SDF rounding (what shows between rounded windows)
    gap_color: [4]u8 align(4) = .{ 0x0a, 0x0a, 0x0a, 0xFF },

    /// Matte/ink color post-processing intensity (0.0 = off, 1.0 = full)
    matte_intensity: f32 align(4) = 0,

    /// Text gamma adjustment. 0.0 = standard sRGB (gamma 2.2).
    text_gamma: f32 align(4) = 0,

    /// Text contrast adjustment. 0.0 = no change, 1.0 = maximum contrast.
    text_contrast: f32 align(4) = 0,

    /// Number of active window rects for SDF rounding (packed as u32 for std140)
    window_rect_count: u32 align(4) = 0,

    /// Window rectangles for SDF rounding: {x, y, w, h} in pixel coords
    /// Max 16 windows. Stored as vec4 array for std140 layout.
    window_rects: [16][4]f32 align(16) = [_][4]f32{.{ 0, 0, 0, 0 }} ** 16,

    const Bools = packed struct(u32) {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool,

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool,

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors,
        /// since blending will be performed in linear space and then
        /// Metal itself will re-encode the colors for storage.
        use_linear_blending: bool,

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool = false,

        /// Whether to exclude cursor glyphs from rendering (used for scroll animation)
        exclude_cursor: bool = false,
        _padding: u27 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},
    /// Per-cell pixel Y offset for smooth scrolling (sub-pixel precision)
    /// Uses 8.8 fixed-point format: upper 8 bits = integer, lower 8 bits = fraction
    /// Range: -128.0 to +127.996 pixels
    pixel_offset_y: i16 align(2) = 0,

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    // test {
    //     // Minimizing the size of this struct is important,
    //     // so we test it in order to be aware of any changes.
    //     try std.testing.expectEqual(32, @sizeOf(CellText));
    // }
};

/// This is a single parameter for the cell bg shader.
/// Includes per-cell Y offset for smooth background scrolling (Neovim cursorline, etc.)
pub const CellBg = extern struct {
    color: [4]u8,
    /// Per-cell Y offset in pixels for smooth scrolling
    /// Stored as 8.8 fixed point (i16): value = pixels * 256
    offset_y_fixed: i16 = 0,
    /// Window index for SDF rounding (0 = no window/default, 1-16 = window rect index)
    window_id: u8 = 0,
    _padding: [1]u8 = .{0}, // Align to 8 bytes for GPU buffer
};

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};

/// Uniforms for the scroll blend shader (for smooth TUI scrolling).
/// Implements Neovide-style scrolling where border rows stay fixed.
pub const ScrollBlendUniforms = extern struct {
    /// Blend factor: 0.0 = all previous frame, 1.0 = all current frame
    blend_factor: f32 align(4),
    /// Vertical scroll offset in pixels (animates toward 0)
    scroll_offset_y: f32 align(4),
    /// Total screen height for UV calculations
    screen_height: f32 align(4),
    /// Total screen width for UV calculations
    screen_width: f32 align(4),
    /// Height of one cell in pixels
    cell_height: f32 align(4),
    /// Top of scroll region in pixels (rows above this are fixed)
    scroll_region_top: f32 align(4),
    /// Bottom of scroll region in pixels (rows at/below this are fixed)
    scroll_region_bot: f32 align(4),
    /// Top padding in pixels
    padding_top: f32 align(4),
};

/// Initialize our custom shader pipelines. The shaders argument is a
/// set of shader source code, not file paths.
fn initPostPipelines(
    alloc: Allocator,
    shaders: []const [:0]const u8,
) ![]const Pipeline {
    // If we have no shaders, do nothing.
    if (shaders.len == 0) return &.{};

    // Keeps track of how many shaders we successfully wrote.
    var i: usize = 0;

    // Initialize our result set. If any error happens, we undo everything.
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| {
            pipeline.deinit();
        }
        alloc.free(pipelines);
    }

    // Build each shader. Note we don't use "0.." to build our index
    // because we need to keep track of our length to clean up above.
    for (shaders) |source| {
        pipelines[i] = try initPostPipeline(source);
        i += 1;
    }

    return pipelines;
}

/// Initialize a single custom shader pipeline from shader source.
fn initPostPipeline(data: [:0]const u8) !Pipeline {
    return try Pipeline.init(null, .{
        .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
        .fragment_fn = data,
    });
}

/// Load shader code from the target path, processing `#include` directives.
///
/// Comptime only for now, this code is really sloppy and makes a bunch of
/// assumptions about things being well formed and file names not containing
/// quote marks. If we ever want to process `#include`s for custom shaders
/// then we need to write something better than this for it.
fn loadShaderCode(comptime path: []const u8) [:0]const u8 {
    return comptime processIncludes(@embedFile(path), std.fs.path.dirname(path).?);
}

/// Used by loadShaderCode
fn processIncludes(contents: [:0]const u8, basedir: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    var i: usize = 0;
    while (i < contents.len) {
        if (std.mem.startsWith(u8, contents[i..], "#include")) {
            assert(std.mem.startsWith(u8, contents[i..], "#include \""));
            const start = i + "#include \"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"').?;
            return std.fmt.comptimePrint(
                "{s}{s}{s}",
                .{
                    contents[0..i],
                    @embedFile(basedir ++ "/" ++ contents[start..end]),
                    processIncludes(contents[end + 1 ..], basedir),
                },
            );
        }
        if (std.mem.indexOfPos(u8, contents, i, "\n#")) |j| {
            i = (j + 1);
        } else {
            break;
        }
    }
    return contents;
}
