#include "common.glsl"

layout(binding = 0) uniform sampler2DRect atlas_grayscale;
layout(binding = 1) uniform sampler2DRect atlas_color;

in CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat vec4 bg_color;
    vec2 tex_coord;
    vec2 screen_pos;  // For clipping during scroll
    flat uvec2 grid_pos_out;
    flat uint is_in_scroll_region; // Only clip cells that are part of the scroll region
} in_data;

// Values `atlas` can take.
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

void main() {
    // Manual clipping for TUI scroll region
    // When scroll_region is active (scroll_region_top > 0), we need to clip content
    // to prevent it from drawing outside the scroll region bounds.
    // This is needed both during animation AND when content overflows.
    if (scroll_region_top > 0u && in_data.is_in_scroll_region != 0u) {
        uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
        uint eff_bot = scroll_region_bot == 0u ? grid_size.y : scroll_region_bot;
        uint eff_right = scroll_region_right == 0u ? grid_size.x : scroll_region_right;
        
        // Calculate clip bounds in screen space
        // These are the fixed boundaries where scroll region content should appear
        float top_y = float(scroll_region_top) * cell_size.y - pixel_scroll_offset_y;
        float bot_y = float(eff_bot) * cell_size.y - pixel_scroll_offset_y;
        float left_x = float(scroll_region_left) * cell_size.x;
        float right_x = float(eff_right) * cell_size.x;

        // Clip any fragment that falls outside the scroll region bounds
        if (in_data.screen_pos.y < top_y || in_data.screen_pos.y >= bot_y ||
            in_data.screen_pos.x < left_x || in_data.screen_pos.x >= right_x) {
            discard;
        }
    }

    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;
    
    // NOTE: For TUI smooth scrolling, clipping is handled by the scroll_blend shader.
    // The scroll_blend shader composites prev/curr frames with proper region handling.

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
