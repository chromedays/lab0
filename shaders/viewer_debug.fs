#version 330

// Screen-only semantic visualization for Viewer RenderTextures. This shader is
// never used by the authoritative render graph or deterministic capture path.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform int u_display_mode;

out vec4 finalColor;

vec3 checkerboard_color() {
    vec2 cell = floor(gl_FragCoord.xy / 16.0);
    float alternate = mod(cell.x + cell.y, 2.0);
    return mix(vec3(0.12), vec3(0.22), alternate);
}

vec3 band_palette(int band_id) {
    int palette_index = band_id % 8;
    if (palette_index == 0) return vec3(0.94, 0.32, 0.28);
    if (palette_index == 1) return vec3(0.98, 0.68, 0.22);
    if (palette_index == 2) return vec3(0.48, 0.80, 0.32);
    if (palette_index == 3) return vec3(0.20, 0.76, 0.74);
    if (palette_index == 4) return vec3(0.28, 0.56, 0.94);
    if (palette_index == 5) return vec3(0.54, 0.40, 0.90);
    if (palette_index == 6) return vec3(0.88, 0.36, 0.78);
    return vec3(0.72, 0.72, 0.76);
}

void main() {
    vec4 source = texture(texture0, fragTexCoord);

    if (u_display_mode == 1) {
        if (source.a <= 0.0) {
            finalColor = vec4(checkerboard_color(), 1.0);
            return;
        }
        int band_id = max(int(round(source.r * 255.0)) - 1, 0);
        int accents = int(round(source.g * 255.0));
        vec3 color = band_palette(band_id);
        if ((accents & 1) != 0) {
            color = mix(color, vec3(0.15, 0.95, 1.0), 0.35);
        }
        if ((accents & 2) != 0) {
            color = mix(color, vec3(1.0, 0.25, 0.85), 0.48);
        }
        finalColor = vec4(color, 1.0);
        return;
    }

    if (u_display_mode == 2) {
        float coverage = source.a;
        finalColor = vec4(vec3(coverage), 1.0);
        return;
    }

    vec3 checker = checkerboard_color();
    vec3 composite = source.rgb * source.a + checker * (1.0 - source.a);
    finalColor = vec4(composite, 1.0) * fragColor * colDiffuse;
}
