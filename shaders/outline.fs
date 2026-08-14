#version 330

// Final low-resolution outline pass. Existing color pixels pass through unchanged;
// transparent cells become outline color when nearby coverage exceeds the style
// threshold. The fixed maximum radius matches the validated CPU width range.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform sampler2D u_coverage_texture;
uniform vec4 colDiffuse;
uniform vec2 u_target_resolution;
uniform int u_outline_width;
uniform vec4 u_outline_color;
uniform float u_coverage_threshold;
uniform int u_edge_aa_mode;

out vec4 finalColor;

void main() {
    vec4 source_color = texture(texture0, fragTexCoord);

    // Hard mode preserves the original binary fill/outline behavior exactly.
    if (u_edge_aa_mode == 0) {
        if (u_outline_width <= 0 || source_color.a > 0.0) {
            finalColor = source_color * fragColor * colDiffuse;
            return;
        }

        vec2 hard_texel_size = 1.0 / u_target_resolution;
        bool neighboring_coverage = false;
        for (int offset_y = -3; offset_y <= 3; offset_y++) {
            for (int offset_x = -3; offset_x <= 3; offset_x++) {
                if (abs(offset_x) > u_outline_width ||
                    abs(offset_y) > u_outline_width ||
                    (offset_x == 0 && offset_y == 0)) {
                    continue;
                }
                vec2 sample_uv = clamp(
                    fragTexCoord + vec2(float(offset_x), float(offset_y)) *
                        hard_texel_size,
                    hard_texel_size * 0.5,
                    vec2(1.0) - hard_texel_size * 0.5
                );
                if (texture(u_coverage_texture, sample_uv).a >=
                    u_coverage_threshold) {
                    neighboring_coverage = true;
                }
            }
        }
        finalColor = neighboring_coverage ? u_outline_color : vec4(0.0);
        return;
    }

    // With no outline, coverage-resolved fill passes through as straight alpha.
    if (u_outline_width <= 0 || source_color.a >= 1.0) {
        finalColor = source_color * fragColor * colDiffuse;
        return;
    }

    // Use the strongest qualifying neighbor as fractional outline occupancy.
    // This retains the authored rejection threshold while avoiding a second
    // binary edge at sparsely covered outline corners.
    vec2 texel_size = 1.0 / u_target_resolution;
    float neighboring_coverage = 0.0;
    for (int offset_y = -3; offset_y <= 3; offset_y++) {
        for (int offset_x = -3; offset_x <= 3; offset_x++) {
            if (abs(offset_x) > u_outline_width ||
                abs(offset_y) > u_outline_width ||
                (offset_x == 0 && offset_y == 0)) {
                continue;
            }
            vec2 sample_uv = clamp(
                fragTexCoord + vec2(float(offset_x), float(offset_y)) * texel_size,
                texel_size * 0.5,
                vec2(1.0) - texel_size * 0.5
            );
            float sample_coverage = texture(
                u_coverage_texture,
                sample_uv
            ).a;
            if (sample_coverage >= u_coverage_threshold) {
                neighboring_coverage = max(
                    neighboring_coverage,
                    sample_coverage
                );
            }
        }
    }

    // Composite the partially covered fill over its outline, then convert the
    // premultiplied result back to straight alpha for PNG export and display.
    vec4 fill = source_color * fragColor * colDiffuse;
    float outline_alpha = u_outline_color.a * neighboring_coverage;
    float result_alpha = fill.a + outline_alpha * (1.0 - fill.a);
    vec3 result_premultiplied =
        fill.rgb * fill.a +
        u_outline_color.rgb * outline_alpha * (1.0 - fill.a);
    vec3 result_color = result_alpha > 0.0 ?
        result_premultiplied / result_alpha : vec3(0.0);
    finalColor = vec4(result_color, result_alpha);
}
