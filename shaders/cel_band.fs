#version 330

in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;
in vec3 fragWorldPosition;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

#include "cel_shading_common.glsl"

void main() {
    vec4 albedo = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    if (cel_alpha_discarded(albedo.a)) {
        discard;
    }
    Cel_Ramp_Sample ramp_sample = cel_ramp_sample(fragNormal);
    int accent_flags = cel_accent_flags(fragNormal, fragWorldPosition);

    // Exact RGBA8 metadata. Byte zero remains reserved for the background.
    float encoded_band = float(ramp_sample.band_id + 1) / 255.0;
    float encoded_accents = float(accent_flags) / 255.0;
    finalColor = vec4(encoded_band, encoded_accents, 0.0, 1.0);
}
