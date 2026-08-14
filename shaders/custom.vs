#version 330

// Main geometry vertex stage. raylib supplies object-space attributes and
// matrices; this shader forwards material data plus world-space normal/position
// needed by cel lighting and view-dependent accents.

// Per-vertex mesh inputs bound by raylib's standard shader locations.
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;

// Interpolants consumed by both the color and metadata fragment passes.
out vec2 fragTexCoord;
out vec4 fragColor;
out vec3 fragNormal;
out vec3 fragWorldPosition;

// mvp positions the vertex for rasterization, matModel produces world position,
// and matNormal removes translation while correctly transforming normals.
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;

void main() {
    // Normalize after the normal-matrix transform so non-unit source normals do
    // not change band thresholds. Fragment stages normalize again after interpolation.
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
    fragWorldPosition = vec3(matModel * vec4(vertexPosition, 1.0));
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
