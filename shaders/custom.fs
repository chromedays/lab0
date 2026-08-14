#version 330

// Main scene-color fragment stage. It applies material alpha, quantized diffuse
// bands, tint replacement, and optional rim/highlight accents using the shared
// classification code also consumed by the metadata pass.

in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;
in vec3 fragWorldPosition;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

#include "cel_shading_common.glsl"

void main() {
    // Preserve raylib's material/vertex-color multiplication before cel logic.
    vec4 albedo = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    if (cel_alpha_discarded(albedo.a)) {
        discard;
    }
    // Classification is performed once so band shading and accents agree with
    // the parallel cel_band.fs metadata texture used during downsampling.
    Cel_Ramp_Sample ramp_sample = cel_ramp_sample(fragNormal);
    int accent_flags = cel_accent_flags(fragNormal, fragWorldPosition);
    vec3 color = cel_apply_band(albedo.rgb, ramp_sample);
    color = cel_apply_accents(color, accent_flags);
    finalColor = vec4(color, 1.0);
}
