#version 330

// Scene Editor geometry stage. It intentionally mirrors the Viewer vertex
// contract while remaining a separate program so future editor-only changes
// cannot alter Viewer or Game capture output.

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;

out vec2 fragTexCoord;
out vec4 fragColor;
out vec3 fragNormal;
out vec3 fragWorldPosition;
out vec4 fragShadowPosition;

uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
uniform mat4 u_light_view_projection;

void main() {
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
    vec4 world_position = matModel * vec4(vertexPosition, 1.0);
    fragWorldPosition = world_position.xyz;
    fragShadowPosition = u_light_view_projection * world_position;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
