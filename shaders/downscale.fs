#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform sampler2D u_mask_texture;
uniform vec4 colDiffuse;

// Full-resolution scene texture size, currently 800x600.
uniform vec2 u_source_resolution;

// Downscaled render-target size, currently 80x60.
uniform vec2 u_target_resolution;

// Seconds since startup. Available for animated custom effects.
uniform float u_time;

out vec4 finalColor;

#include "downsample_common.glsl"

void main() {
    // Only scene samples covered by solid mask geometry contribute color.
    vec4 color = sample_downscaled_texture(
        texture0,
        u_mask_texture,
        fragTexCoord,
        u_source_resolution,
        u_target_resolution,
        true
    );

    // Customize the downscale pass here. For example:
    // color.rgb = floor(color.rgb * 8.0) / 8.0;  // Color quantization
    // color.rgb *= 0.9 + 0.1 * sin(u_time * 3.0); // Animated brightness
    // color.rgb = vec3(dot(color.rgb, vec3(0.299, 0.587, 0.114))); // Grayscale

    finalColor = color * fragColor * colDiffuse;
}
