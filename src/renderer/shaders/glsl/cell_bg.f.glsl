#include "common.glsl"

// Position the origin to the upper left
layout(origin_upper_left) in vec4 gl_FragCoord;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

struct CellBgData {
    uint color;           // Packed RGBA (4 bytes)
    int offset_and_winid; // Lower 16 bits: 8.8 fixed point Y offset, bits 16-23: window_id, bits 24-31: padding
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
    bool allow_fixed_overlap = (window_rect_count == 0u);
    if (grid_pos.x >= 0 && grid_pos.x < int(grid_size.x) &&
        grid_pos.y >= 0 && grid_pos.y < int(grid_size.y)) {
        int cell_index = grid_pos.y * int(grid_size.x) + grid_pos.x;
        // Read offset as int, but it's stored as i16 in lower 16 bits - sign extend it
        int offset_raw = cells[cell_index].offset_and_winid;
        int offset_i16 = (offset_raw << 16) >> 16; // Sign extend from 16-bit to 32-bit
        
        // Only apply offset to cells that have one (non-zero)
        // Cells with offset=0 are statuslines/margins - they stay fixed and opaque
        if (offset_i16 != 0) {
            float per_cell_offset_y = round(float(offset_i16) / 256.0);
            adjusted_coord.y -= per_cell_offset_y;
            ivec2 new_grid_pos = ivec2(floor((adjusted_coord - grid_padding.wx) / cell_size));
            
            // Check if the new position is a fixed cell (statusline)
            // If so, don't use that cell's color - keep the original scrolling cell's color
            if (new_grid_pos.x >= 0 && new_grid_pos.x < int(grid_size.x) &&
                new_grid_pos.y >= 0 && new_grid_pos.y < int(grid_size.y)) {
                int new_cell_index = new_grid_pos.y * int(grid_size.x) + new_grid_pos.x;
                int new_offset_raw = cells[new_cell_index].offset_and_winid;
                int new_offset_i16 = (new_offset_raw << 16) >> 16;
                
                // Only use the new position if it's also a scrolling cell (not fixed)
                if (new_offset_i16 != 0 || allow_fixed_overlap) {
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
    int cell_index_final = grid_pos.y * int(grid_size.x) + grid_pos.x;
    uvec4 raw_color = unpack4u8(cells[cell_index_final].color);
    raw_color.a = 255u;  // Force full opacity before premultiplication
    // Extract window_id from bits 16-23 of offset_and_winid
    uint cell_window_id = uint(cells[cell_index_final].offset_and_winid >> 16) & 0xFFu;
    vec4 result = load_color(raw_color, use_linear_blending);

    // SDF Rounded Corners: apply rounded rectangle clipping per-window
    if (corner_radius > 0.0 && cell_window_id > 0u &&
        cell_window_id <= window_rect_count) {
        vec4 wrect = window_rects[cell_window_id - 1u];
        vec2 win_pos = wrect.xy;
        vec2 win_size = wrect.zw;

        // Position relative to window center
        vec2 frag_pos = gl_FragCoord.xy;
        vec2 center = win_pos + win_size * 0.5;
        vec2 half_size = win_size * 0.5;
        float r = corner_radius;

        // SDF for rounded rectangle
        vec2 d = abs(frag_pos - center) - half_size + vec2(r);
        float dist = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - r;

        // Anti-aliased edge
        float alpha = 1.0 - smoothstep(-1.0, 0.5, dist);

        // Outside the rounded rect: show gap color
        if (alpha < 1.0) {
            vec4 gap_bg = load_color(unpack4u8(gap_color_packed), use_linear_blending);
            result = mix(gap_bg, result, alpha);
        }
    }

    // Matte/ink color post-processing
    if (matte_intensity > 0.0) {
        float t = matte_intensity;

        // Work in gamma space for perceptual correctness
        vec4 color_gamma = use_linear_blending ? unlinearize(result) : result;

        // 1. Slight desaturation - makes colors less "digital"
        float lum = dot(color_gamma.rgb, vec3(0.2126, 0.7152, 0.0722));
        color_gamma.rgb = mix(color_gamma.rgb, vec3(lum), 0.12 * t);

        // 2. Shadow lift + highlight compression
        float lift = 0.02 * t;
        float compress = 0.97 + 0.03 * (1.0 - t);
        color_gamma.rgb = color_gamma.rgb * compress + vec3(lift);

        // 3. Cool-tint shadows
        float shadow_strength = (1.0 - lum) * t;
        color_gamma.rgb += vec3(-0.003, -0.001, 0.008) * shadow_strength;

        // Clamp to valid range
        color_gamma.rgb = clamp(color_gamma.rgb, 0.0, 1.0);

        result = use_linear_blending ? linearize(color_gamma) : color_gamma;
        result.a = 1.0;
    }

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
