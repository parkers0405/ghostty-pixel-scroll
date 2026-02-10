#version 430 core

// These are common definitions to be shared across shaders, the first
// line of any shader that needs these should be `#include "common.glsl"`.
//
// Included in this file are:
// - The interface block for the global uniforms.
// - Functions for unpacking values.
// - Functions for working with colors.

//----------------------------------------------------------------------------//
// Global Uniforms
//----------------------------------------------------------------------------//
layout(binding = 1, std140) uniform Globals {
    uniform mat4 projection_matrix;
    uniform vec2 screen_size;
    uniform vec2 cell_size;
    uniform uint grid_size_packed_2u16;
    uniform vec4 grid_padding;
    uniform uint padding_extend;
    uniform float min_contrast;
    uniform uint cursor_pos_packed_2u16;
    uniform uint cursor_color_packed_4u8;
    uniform uint bg_color_packed_4u8;
    uniform uint bools;
    uniform float pixel_scroll_offset_y;  // Sub-line scroll offset in pixels (terminal scrollback)
    uniform float cursor_offset_x;  // Cursor animation X offset in pixels
    uniform float cursor_offset_y;  // Cursor animation Y offset in pixels
    // Neovide-style stretchy cursor - 4 corner positions in pixels
    uniform vec2 cursor_corner_tl;  // Top-left corner
    uniform vec2 cursor_corner_tr;  // Top-right corner
    uniform vec2 cursor_corner_br;  // Bottom-right corner
    uniform vec2 cursor_corner_bl;  // Bottom-left corner
    uniform uint cursor_use_corners;  // Whether to use corner-based rendering (as uint for alignment)
    // Sonicboom VFX
    uniform vec2 sonicboom_center;     // Pixel position of ring center
    uniform float sonicboom_radius;    // Current ring radius in pixels
    uniform float sonicboom_thickness; // Ring thickness in pixels
    uniform uint sonicboom_color_packed; // Packed RGBA color
    // TUI smooth scrolling
    uniform float tui_scroll_offset_y;     // Pixel offset for scroll region cells
    uniform uint tui_scroll_region_packed; // Packed 2x u16: top (low 16), bottom (high 16)
    // SDF rounded corners
    uniform float corner_radius;           // Corner radius in pixels (0 = disabled)
    uniform uint gap_color_packed;         // Gap color between rounded windows (packed RGBA)
    uniform float matte_intensity;         // Matte/ink post-processing (0 = off, 1 = full)
    uniform float text_gamma;              // Text gamma adjustment (0 = standard sRGB)
    uniform float text_contrast;           // Text contrast adjustment (0 = no change)
    uniform uint window_rect_count;        // Number of active window rects
    uniform vec4 window_rects[16];         // Window pixel rects: {x, y, w, h}
};

// Variable row heights and per-cell X offsets.
// row_y[i] = pixel Y of row i's top edge.
// row_h[i] = pixel height of row i.
// cell_x[flat_index] = pixel X of cell at flat_index (row * cols + col).
// For uniform grids: row_y[i] = i * cell_size.y, cell_x[i] = col * cell_size.x.
layout(binding = 2, std430) readonly buffer RowLayout { float row_y[]; };
layout(binding = 3, std430) readonly buffer RowHeights { float row_h[]; };
layout(binding = 4, std430) readonly buffer CellXOffsets { float cell_x[]; };

// Bools
const uint CURSOR_WIDE = 1u;
const uint USE_DISPLAY_P3 = 2u;
const uint USE_LINEAR_BLENDING = 4u;
const uint USE_LINEAR_CORRECTION = 8u;
const uint EXCLUDE_CURSOR = 16u;

// Padding extend enum
const uint EXTEND_LEFT = 1u;
const uint EXTEND_RIGHT = 2u;
const uint EXTEND_UP = 4u;
const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//
// NOTE: These unpack functions assume little-endian.
//       If this ever becomes a problem... oh dear!

uvec4 unpack4u8(uint packed_value) {
    return uvec4(
        uint(packed_value >> 0) & uint(0xFF),
        uint(packed_value >> 8) & uint(0xFF),
        uint(packed_value >> 16) & uint(0xFF),
        uint(packed_value >> 24) & uint(0xFF)
    );
}

uvec2 unpack2u16(uint packed_value) {
    return uvec2(
        uint(packed_value >> 0) & uint(0xFFFF),
        uint(packed_value >> 16) & uint(0xFFFF)
    );
}

ivec2 unpack2i16(int packed_value) {
    return ivec2(
        (packed_value << 16) >> 16,
        (packed_value << 0) >> 16
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

// Compute the luminance of the provided color.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float luminance(vec3 color) {
    return dot(color, vec3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float contrast_ratio(vec3 color1, vec3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
vec4 contrasted_color(float min_ratio, vec4 fg, vec4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(vec3(1.0, 1.0, 1.0), bg.rgb);
        float black_ratio = contrast_ratio(vec3(0.0, 0.0, 0.0), bg.rgb);
        if (white_ratio > black_ratio) {
            return vec4(1.0);
        } else {
            return vec4(0.0, 0.0, 0.0, 1.0);
        }
    }

    return fg;
}

// Converts a color from sRGB gamma encoding to linear.
vec4 linearize(vec4 srgb) {
    bvec3 cutoff = lessThanEqual(srgb.rgb, vec3(0.04045));
    vec3 higher = pow((srgb.rgb + vec3(0.055)) / vec3(1.055), vec3(2.4));
    vec3 lower = srgb.rgb / vec3(12.92);

    return vec4(mix(higher, lower, cutoff), srgb.a);
}
float linearize(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
vec4 unlinearize(vec4 linear) {
    bvec3 cutoff = lessThanEqual(linear.rgb, vec3(0.0031308));
    vec3 higher = pow(linear.rgb, vec3(1.0 / 2.4)) * vec3(1.055) - vec3(0.055);
    vec3 lower = linear.rgb * vec3(12.92);

    return vec4(mix(higher, lower, cutoff), linear.a);
}
float unlinearize(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Load a 4 byte RGBA non-premultiplied color and linearize
// and convert it as necessary depending on the provided info.
//
// `linear` controls whether the returned color is linear or gamma encoded.
vec4 load_color(
    uvec4 in_color,
    bool linear
) {
    // 0 .. 255 -> 0.0 .. 1.0
    vec4 color = vec4(in_color) / vec4(255.0f);

    // Linearize if necessary.
    if (linear) color = linearize(color);

    // Premultiply our color by its alpha.
    color.rgb *= color.a;

    return color;
}

//----------------------------------------------------------------------------//
// Variable Row Height Helpers
//----------------------------------------------------------------------------//

int findRow(float pixel_y) {
    uvec2 gs = unpack2u16(grid_size_packed_2u16);
    int rows = int(gs.y);
    if (rows <= 0) return 0;
    int lo = 0, hi = rows - 1;
    while (lo < hi) {
        int mid = (lo + hi + 1) / 2;
        if (row_y[mid] <= pixel_y) lo = mid; else hi = mid - 1;
    }
    return lo;
}

ivec2 gridPosFromPixel(vec2 coord) {
    int col = int(floor(coord.x / cell_size.x));
    int row = findRow(coord.y);
    return ivec2(col, row);
}
