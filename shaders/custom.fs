#version 330

in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

#include "cel_shading_common.glsl"

void main() {
    vec4 albedo = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    int band_id = cel_band_id(fragNormal);
    finalColor = vec4(albedo.rgb * cel_band_brightness(band_id), albedo.a);
}
