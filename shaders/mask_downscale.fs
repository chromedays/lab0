#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec2 u_source_resolution;
uniform vec2 u_target_resolution;

out vec4 finalColor;

#include "downsample_common.glsl"

void main() {
    float coverage = sample_downscaled_texture(
        texture0,
        texture0,
        fragTexCoord,
        u_source_resolution,
        u_target_resolution,
        false
    ).a;
    // Store coverage in both grayscale and alpha. Grayscale makes the mask
    // directly inspectable; alpha keeps the numeric coverage available.
    finalColor = vec4(vec3(coverage), coverage);
}
