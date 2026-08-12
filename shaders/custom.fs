#version 330

in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

void main() {
    vec4 albedo = texture(texture0, fragTexCoord) * colDiffuse * fragColor;

    // Three discrete Lambert bands produce a simple cel-shaded look.
    vec3 lightDirection = normalize(vec3(0.35, 0.80, 0.55));
    float diffuse = max(dot(normalize(fragNormal), lightDirection), 0.0);

    float lightBand = 0.32;
    if (diffuse > 0.65) {
        lightBand = 1.0;
    } else if (diffuse > 0.25) {
        lightBand = 0.62;
    }

    finalColor = vec4(albedo.rgb * lightBand, albedo.a);
}
