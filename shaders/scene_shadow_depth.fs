#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform int u_alpha_mode;
uniform float u_alpha_cutoff;

const int CEL_ALPHA_MODE_MASK = 1;

void main() {
    float material_alpha =
        (texture(texture0, fragTexCoord) * colDiffuse * fragColor).a;
    if (u_alpha_mode == CEL_ALPHA_MODE_MASK &&
        material_alpha < u_alpha_cutoff) {
        discard;
    }
    // The framebuffer has only a sampleable depth attachment. The color output
    // is intentionally ignored; surviving fragments write fixed-function depth.
    finalColor = vec4(1.0);
}
