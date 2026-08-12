#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

out vec4 finalColor;

void main() {
    // Geometry coverage only: textures, lighting and model colors intentionally
    // do not affect this pass.
    finalColor = vec4(1.0);
}
