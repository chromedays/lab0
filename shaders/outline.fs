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

out vec4 finalColor;

void main() {
    // Do not overwrite filled pixels; outline expansion operates only into empty
    // target cells so silhouettes never shrink.
    vec4 source_color = texture(texture0, fragTexCoord);
    if (u_outline_width <= 0 || source_color.a > 0.0) {
        finalColor = source_color * fragColor * colDiffuse;
        return;
    }

    // Search a square Chebyshev neighborhood up to the requested pixel width.
    // UV clamping prevents reads outside the RenderTexture at image borders.
    vec2 texel_size = 1.0 / u_target_resolution;
    bool neighboring_coverage = false;
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
            if (texture(u_coverage_texture, sample_uv).a >=
                u_coverage_threshold) {
                neighboring_coverage = true;
            }
        }
    }

    // Output remains transparent where no qualifying source coverage is nearby.
    finalColor = neighboring_coverage ? u_outline_color : vec4(0.0);
}
