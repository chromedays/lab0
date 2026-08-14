#version 330

in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;
in vec3 fragWorldPosition;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

#include "scene_multi_light_common.glsl"

void main() {
    vec4 albedo = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    if (cel_alpha_discarded(albedo.a)) {
        discard;
    }
    Scene_Light_Sample light_sample = scene_light_sample(
        fragNormal,
        fragWorldPosition
    );
    Cel_Ramp_Sample ramp_sample = cel_ramp_sample(light_sample.band_input);
    int accent_flags = cel_accent_flags(
        fragNormal,
        fragWorldPosition,
        light_sample.highlight_score
    );
    finalColor = vec4(
        float(ramp_sample.band_id + 1) / 255.0,
        float(accent_flags) / 255.0,
        0.0,
        1.0
    );
}
