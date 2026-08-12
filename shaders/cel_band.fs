#version 330

in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;

out vec4 finalColor;

#include "cel_shading_common.glsl"

void main() {
    int band_id = cel_band_id(fragNormal);

    // Store band IDs as exact RGBA8 byte values 1, 2 and 3. Zero remains
    // reserved for the transparent background.
    float encoded_band = float(band_id + 1) / 255.0;
    finalColor = vec4(encoded_band, 0.0, 0.0, 1.0);
}
