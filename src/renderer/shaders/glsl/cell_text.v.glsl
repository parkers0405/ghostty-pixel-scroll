#include "common.glsl"

// The position of the glyph in the texture (x, y)
layout(location = 0) in uvec2 glyph_pos;

// The size of the glyph in the texture (w, h)
layout(location = 1) in uvec2 glyph_size;

// The left and top bearings for the glyph (x, y)
layout(location = 2) in ivec2 bearings;

// The grid coordinates (x, y) where x < columns and y < rows
layout(location = 3) in uvec2 grid_pos;

// The color of the rendered text glyph.
layout(location = 4) in uvec4 color;

// Which atlas this glyph is in.
layout(location = 5) in uint atlas;

// Misc glyph properties.
layout(location = 6) in uint glyph_bools;

// Per-cell pixel Y offset for smooth scrolling (8.8 fixed-point format)
// Used for Neovide-style per-window smooth scrolling
layout(location = 7) in int pixel_offset_y_fixed;

// Values `atlas` can take.
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;

// Masks for the `glyph_bools` attribute
const uint NO_MIN_CONTRAST = 1u;
const uint IS_CURSOR_GLYPH = 2u;

out CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat vec4 bg_color;
    flat int pixel_offset_y;  // Pass to fragment shader for clipping check
    flat uvec2 cell_grid_pos;  // Original grid position for TUI scroll clipping
    vec2 tex_coord;
} out_data;

struct CellBgData {
    uint color;
    int offset_and_winid;
};

layout(binding = 1, std430) readonly buffer bg_cells {
    CellBgData cells[];
};

void main() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    uvec2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Convert the grid x, y into world space x, y by accounting for cell size
    vec2 cell_pos = cell_size * vec2(grid_pos);

    int vid = gl_VertexID;

    // We use a triangle strip with 4 vertices to render quads,
    // so we determine which corner of the cell this vertex is in
    // based on the vertex ID.
    vec2 corner = vec2(vid & 1, vid >> 1);

    // Calculate the position of the cell in the texture atlas
    // accounting for the corner we are currently processing.
    //
    // The Y bearing is the distance from the baseline to the top of the glyph,
    // so we subtract it from the cell height to get the y offset.
    // However, our coordinate system is top-left, so we need to flip
    // the y offset. The X bearing is the distance from the left of the cell
    // to the left of the glyph, so it works as the x offset directly.

    vec2 size = vec2(glyph_size);
    vec2 offset = vec2(bearings);

    offset.y = cell_size.y - offset.y;

    // Calculate the final position of the cell which uses our glyph size
    // and glyph offset to create the correct bounding box for the glyph.
    cell_pos = cell_pos + size * corner + offset;
    
    // Apply per-cell pixel scroll offset (8.8 fixed-point -> float)
    // Round to whole pixels to keep text crisp.
    float per_cell_offset_y = round(float(pixel_offset_y_fixed) / 256.0);
    cell_pos.y += per_cell_offset_y;

    // Apply TUI scroll offset for cells within the scroll region
    if (tui_scroll_offset_y != 0.0) {
        uvec2 tui_region = unpack2u16(tui_scroll_region_packed);
        if (grid_pos.y >= tui_region.x && grid_pos.y <= tui_region.y) {
            cell_pos.y += tui_scroll_offset_y;
        }
    }
    
    // Apply global pixel scroll offset (base grid alignment)
    // In terminal mode: shifts content up to hide an extra row for smooth scrollback.
    cell_pos.y -= pixel_scroll_offset_y;

    // Snap text glyph Y position to nearest integer pixel.
    cell_pos.y = round(cell_pos.y);
    
    // Apply cursor animation offset if this is the cursor glyph
    if ((glyph_bools & IS_CURSOR_GLYPH) != 0u) {
        // If we are asked to exclude cursor (e.g. for scroll animation frame capture),
        // discard this vertex by moving it off-screen
        if ((bools & EXCLUDE_CURSOR) != 0u) {
            gl_Position = vec4(-2.0, -2.0, 0.0, 1.0);
            return;
        }
        
        if (cursor_use_corners != 0u) {
            // Neovide-style stretchy cursor: each vertex uses its animated corner position
            // Vertex order in quad: vid 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right
            // corner.x: 0=left, 1=right; corner.y: 0=top, 1=bottom
            vec2 corner_pos;
            if (corner.x < 0.5 && corner.y < 0.5) {
                corner_pos = cursor_corner_tl;
            } else if (corner.x >= 0.5 && corner.y < 0.5) {
                corner_pos = cursor_corner_tr;
            } else if (corner.x < 0.5 && corner.y >= 0.5) {
                corner_pos = cursor_corner_bl;
            } else {
                corner_pos = cursor_corner_br;
            }
            cell_pos = corner_pos;
        } else {
            // Simple offset-based animation (fallback)
            cell_pos.x += cursor_offset_x;
            cell_pos.y += cursor_offset_y;
        }
    }
    gl_Position = projection_matrix * vec4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);

    // Calculate the texture coordinate in pixels. This is NOT normalized
    // (between 0.0 and 1.0), and does not need to be, since the texture will
    // be sampled with pixel coordinate mode.
    out_data.tex_coord = vec2(glyph_pos) + vec2(glyph_size) * corner;

    // Pass the pixel offset to fragment shader for clipping check
    out_data.pixel_offset_y = pixel_offset_y_fixed;
    out_data.cell_grid_pos = grid_pos;

    // Get our color. We always fetch a linearized version to
    // make it easier to handle minimum contrast calculations.
    out_data.color = load_color(color, true);
    // Get the BG color
    out_data.bg_color = load_color(
            unpack4u8(cells[grid_pos.y * grid_size.x + grid_pos.x].color),
            true
        );
    // Blend it with the global bg color
    vec4 global_bg = load_color(
            unpack4u8(bg_color_packed_4u8),
            true
        );
    out_data.bg_color += global_bg * vec4(1.0 - out_data.bg_color.a);

    // If we have a minimum contrast, we need to check if we need to
    // change the color of the text to ensure it has enough contrast
    // with the background.
    if (min_contrast > 1.0f && (glyph_bools & NO_MIN_CONTRAST) == 0) {
        // Ensure our minimum contrast
        out_data.color = contrasted_color(min_contrast, out_data.color, out_data.bg_color);
    }

    // Check if current position is under cursor (including wide cursor)
    bool is_cursor_pos = ((grid_pos.x == cursor_pos.x) || (cursor_wide && (grid_pos.x == (cursor_pos.x + 1)))) && (grid_pos.y == cursor_pos.y);

    // If this cell is the cursor cell, but we're not processing
    // the cursor glyph itself, then we need to change the color.
    if ((glyph_bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos) {
        out_data.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }
}
