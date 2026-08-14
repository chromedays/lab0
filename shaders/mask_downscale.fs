#version 330

// Coverage-only downsample pass. It uses the scene alpha attachment and the
// shared 4x4 footprint to measure how much of each logical pixel is occupied.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec2 u_source_resolution;
uniform vec2 u_target_resolution;

out vec4 finalColor;

#include "downsample_common.glsl"

void main() {
    // Coverage remains fractional instead of thresholded here; outline.fs owns
    // the style-specific decision about which neighboring cells count as solid.
    float coverage = sample_downscaled_alpha(
        texture0,
        fragTexCoord,
        u_source_resolution,
        u_target_resolution
    );
    // Store coverage in both grayscale and alpha. Grayscale makes the mask
    // directly inspectable; alpha keeps the numeric coverage available.
    finalColor = vec4(vec3(coverage), coverage);
}
