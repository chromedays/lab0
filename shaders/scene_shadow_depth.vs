#version 330

// Directional-light depth pass for Scene Editor hard shadows. The regular
// material UV/color contract is retained so alpha-masked meshes cast the same
// silhouette they show in the visible and metadata passes.

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;

out vec2 fragTexCoord;
out vec4 fragColor;

uniform mat4 mvp;

void main() {
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
