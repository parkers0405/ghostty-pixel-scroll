#include "common.glsl"

// Position the origin to the upper left
layout(origin_upper_left) in vec4 gl_FragCoord;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

struct CellBgData {
    uint color;           // Packed RGBA (4 bytes)
    int offset_y_fixed;   // 8.8 fixed point Y offset stored in lower 16 bits
    // Note: GLSL doesn't have short/ushort, so we use int but only read lower 16 bits
};

layout(binding = 1, std430) readonly buffer bg_cells {
    CellBgData cells[];
};

vec4 cell_bg() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    
    // Calculate grid position from fragment coordinates
    vec2 adjusted_coord = gl_FragCoord.xy;
    adjusted_coord.y += pixel_scroll_offset_y; // Global scroll offset (terminal mode)

    // Apply TUI scroll offset: shift pixels within the scroll region
    bool in_tui_scroll_region = false;
    uvec2 tui_region = unpack2u16(tui_scroll_region_packed);
    if (tui_scroll_offset_y != 0.0) {
        ivec2 pre_grid_pos = ivec2(floor((adjusted_coord - grid_padding.wx) / cell_size));
        if (pre_grid_pos.y >= int(tui_region.x) && pre_grid_pos.y <= int(tui_region.y)) {
            adjusted_coord.y += tui_scroll_offset_y;
            in_tui_scroll_region = true;
        }
    }
    
    ivec2 grid_pos = ivec2(floor((adjusted_coord - grid_padding.wx) / cell_size));

    // Clamp grid_pos.y to scroll region for shifted pixels
    if (in_tui_scroll_region) {
        grid_pos.y = clamp(grid_pos.y, int(tui_region.x), int(tui_region.y));
    }
    
    // Apply per-cell offset for per-window smooth scrolling
    if (grid_pos.x >= 0 && grid_pos.x < int(grid_size.x) &&
        grid_pos.y >= 0 && grid_pos.y < int(grid_size.y)) {
        int cell_index = grid_pos.y * int(grid_size.x) + grid_pos.x;
        // Read offset as int, but it's stored as i16 in lower 16 bits - sign extend it
        int offset_raw = cells[cell_index].offset_y_fixed;
        int offset_i16 = (offset_raw << 16) >> 16; // Sign extend from 16-bit to 32-bit
        
        // Only apply offset to cells that have one (non-zero)
        // Cells with offset=0 are statuslines/margins - they stay fixed and opaque
        if (offset_i16 != 0) {
            float per_cell_offset_y = float(offset_i16) / 256.0;
            adjusted_coord.y -= per_cell_offset_y;
            ivec2 new_grid_pos = ivec2(floor((adjusted_coord - grid_padding.wx) / cell_size));
            
            // Check if the new position is a fixed cell (statusline)
            // If so, don't use that cell's color - keep the original scrolling cell's color
            if (new_grid_pos.x >= 0 && new_grid_pos.x < int(grid_size.x) &&
                new_grid_pos.y >= 0 && new_grid_pos.y < int(grid_size.y)) {
                int new_cell_index = new_grid_pos.y * int(grid_size.x) + new_grid_pos.x;
                int new_offset_raw = cells[new_cell_index].offset_y_fixed;
                int new_offset_i16 = (new_offset_raw << 16) >> 16;
                
                // Only use the new position if it's also a scrolling cell (not fixed)
                if (new_offset_i16 != 0) {
                    grid_pos = new_grid_pos;
                }
                // If new cell is fixed (offset=0), keep original grid_pos
                // This prevents statusline color from bleeding into scrolling area
            }
        }
    }

    vec4 bg = vec4(0.0);

    // Clamp x position, extends edge bg colors in to padding on sides.
    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) {
            grid_pos.x = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.x > grid_size.x - 1) {
        if ((padding_extend & EXTEND_RIGHT) != 0) {
            grid_pos.x = int(grid_size.x) - 1;
        } else {
            return bg;
        }
    }

    // Clamp y position if we should extend, otherwise discard if out of bounds.
    if (grid_pos.y < 0) {
        if ((padding_extend & EXTEND_UP) != 0) {
            grid_pos.y = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.y > grid_size.y - 1) {
        if ((padding_extend & EXTEND_DOWN) != 0) {
            grid_pos.y = int(grid_size.y) - 1;
        } else {
            return bg;
        }
    }

    // Load the color for the cell from the struct
    // Force alpha to 255 BEFORE load_color to prevent premultiplied alpha issues
    uvec4 raw_color = unpack4u8(cells[grid_pos.y * grid_size.x + grid_pos.x].color);
    raw_color.a = 255u;  // Force full opacity before premultiplication
    vec4 result = load_color(raw_color, use_linear_blending);

    // Sonicboom VFX: expanding double ring explosion
    uvec4 boom_raw = unpack4u8(sonicboom_color_packed);
    if (boom_raw.a > 0u && sonicboom_radius > 0.0) {
        float dist = length(gl_FragCoord.xy - sonicboom_center);
        
        // Primary expanding ring
        float ring_inner = sonicboom_radius - sonicboom_thickness;
        float ring_outer = sonicboom_radius + sonicboom_thickness;
        float ring1 = smoothstep(ring_inner - 2.0, ring_inner + 1.0, dist) *
                      (1.0 - smoothstep(ring_outer - 1.0, ring_outer + 2.0, dist));
        
        // Secondary ring at 70% radius for double shockwave effect
        float ring2_radius = sonicboom_radius * 0.7;
        float ring2_inner = ring2_radius - sonicboom_thickness * 0.6;
        float ring2_outer = ring2_radius + sonicboom_thickness * 0.6;
        float ring2 = smoothstep(ring2_inner - 1.5, ring2_inner + 0.5, dist) *
                      (1.0 - smoothstep(ring2_outer - 0.5, ring2_outer + 1.5, dist));

        float combined = max(ring1, ring2 * 0.5);

        if (combined > 0.001) {
            vec4 boom_color = load_color(boom_raw, use_linear_blending);
            float alpha = boom_color.a * combined;
            result = mix(result, vec4(boom_color.rgb, 1.0), alpha);
        }
    }

    return result;
}

void main() {
    out_FragColor = cell_bg();
}
