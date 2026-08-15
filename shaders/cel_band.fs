#version 330

// Auxiliary metadata fragment stage. Geometry and alpha testing match custom.fs,
// but RGBA encodes classification instead of visible color. The downscale pass
// uses this texture to preserve hard lighting bands and sparse accents.

in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;
in vec3 fragWorldPosition;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

#include "cel_shading_common.glsl"

void main() {
    // Use identical albedo alpha and shared classifiers so metadata coverage is
    // pixel-for-pixel aligned with the scene-color RenderTexture.
    vec4 albedo = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    if (cel_alpha_discarded(albedo.a)) {
        discard;
    }
    if (cel_visibility_discarded()) {
        discard;
    }
    Cel_Ramp_Sample ramp_sample = cel_ramp_sample(fragNormal);
    int accent_flags = cel_accent_flags(fragNormal, fragWorldPosition);

    // Exact RGBA8 metadata. Byte zero remains reserved for the background.
    float encoded_band = float(ramp_sample.band_id + 1) / 255.0;
    float encoded_accents = float(accent_flags) / 255.0;
    finalColor = vec4(encoded_band, encoded_accents, 0.0, 1.0);
}
