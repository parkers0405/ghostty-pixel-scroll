#include "common.glsl"

// Position the origin to the upper left for clipping check
layout(origin_upper_left) in vec4 gl_FragCoord;

layout(binding = 0) uniform sampler2DRect atlas_grayscale;
layout(binding = 1) uniform sampler2DRect atlas_color;

// Per-cell background data for checking if fragment falls into fixed (statusline) region
struct CellBgData {
    uint color;
    int offset_y_fixed;
};

layout(binding = 1, std430) readonly buffer bg_cells {
    CellBgData cells[];
};

in CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat vec4 bg_color;
    flat int pixel_offset_y;  // From vertex shader for clipping check
    flat uvec2 cell_grid_pos;  // Original grid position for TUI scroll clipping
    vec2 tex_coord;
} in_data;

// Values `atlas` can take.
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

void main() {
    // Check if this fragment is scrolling text that landed in a fixed cell (statusline)
    // Only clip if: this text HAS an offset AND lands in a cell with offset=0
    if (in_data.pixel_offset_y != 0) {
        uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
        vec2 adjusted_coord = gl_FragCoord.xy;
        adjusted_coord.y += pixel_scroll_offset_y;
        ivec2 dest_grid_pos = ivec2(floor((adjusted_coord - grid_padding.wx) / cell_size));
        
        if (dest_grid_pos.x >= 0 && dest_grid_pos.x < int(grid_size.x) &&
            dest_grid_pos.y >= 0 && dest_grid_pos.y < int(grid_size.y)) {
            int cell_index = dest_grid_pos.y * int(grid_size.x) + dest_grid_pos.x;
            int offset_raw = cells[cell_index].offset_y_fixed;
            int offset_i16 = (offset_raw << 16) >> 16;
            
            // If dest cell is fixed (offset=0) but this text has offset, clip it
            // This prevents scrolling text from bleeding into statusline
            if (offset_i16 == 0) {
                discard;
            }
        }
    }
    // Clip TUI scrolling text at scroll region boundaries
    if (tui_scroll_offset_y != 0.0) {
        uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
        uvec2 tui_region = unpack2u16(tui_scroll_region_packed);
        vec2 adj = gl_FragCoord.xy;
        adj.y += pixel_scroll_offset_y;
        ivec2 frag_grid = ivec2(floor((adj - grid_padding.wx) / cell_size));
        if (in_data.cell_grid_pos.y >= tui_region.x &&
            in_data.cell_grid_pos.y <= tui_region.y) {
            if (frag_grid.y < int(tui_region.x) || frag_grid.y > int(tui_region.y)) {
                discard;
            }
        }
    }

    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;

    switch (in_data.atlas) {
        default:
        case ATLAS_GRAYSCALE:
        {
            // Our input color is always linear.
            vec4 color = in_data.color;

            // If we're not doing linear blending, then we need to
            // re-apply the gamma encoding to our color manually.
            //
            // Since the alpha is premultiplied, we need to divide
            // it out before unlinearizing and re-multiply it after.
            if (!use_linear_blending) {
                color.rgb /= vec3(color.a);
                color = unlinearize(color);
                color.rgb *= vec3(color.a);
            }

            // Fetch our alpha mask for this pixel.
            float a = texture(atlas_grayscale, in_data.tex_coord).r;

            // Linear blending weight correction corrects the alpha value to
            // produce blending results which match gamma-incorrect blending.
            if (use_linear_correction) {
                // Short explanation of how this works:
                //
                // We get the luminances of the foreground and background colors,
                // and then unlinearize them and perform blending on them. This
                // gives us our desired luminance, which we derive our new alpha
                // value from by mapping the range [bg_l, fg_l] to [0, 1], since
                // our final blend will be a linear interpolation from bg to fg.
                //
                // This yields virtually identical results for grayscale blending,
                // and very similar but non-identical results for color blending.
                vec4 bg = in_data.bg_color;
                float fg_l = luminance(color.rgb);
                float bg_l = luminance(bg.rgb);
                // To avoid numbers going haywire, we don't apply correction
                // when the bg and fg luminances are within 0.001 of each other.
                if (abs(fg_l - bg_l) > 0.001) {
                    float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
                    a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
                }
            }

            // Multiply our whole color by the alpha mask.
            // Since we use premultiplied alpha, this is
            // the correct way to apply the mask.
            color *= a;

            out_FragColor = color;
            return;
        }

        case ATLAS_COLOR:
        {
            // For now, we assume that color glyphs
            // are already premultiplied linear colors.
            vec4 color = texture(atlas_color, in_data.tex_coord);

            // If we are doing linear blending, we can return this right away.
            if (use_linear_blending) {
                out_FragColor = color;
                return;
            }

            // Otherwise we need to unlinearize the color. Since the alpha is
            // premultiplied, we need to divide it out before unlinearizing.
            color.rgb /= vec3(color.a);
            color = unlinearize(color);
            color.rgb *= vec3(color.a);

            out_FragColor = color;
            return;
        }
    }
}
