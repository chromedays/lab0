// Single source of truth for scene shading and cel-band classification.
// The fixed array size keeps this compatible with GLSL 330 while the active
// prefix is controlled by the UI.
const int CEL_MAX_BAND_COUNT = 8;

uniform int u_cel_band_count;
uniform float u_cel_band_thresholds[CEL_MAX_BAND_COUNT - 1];

int cel_band_id(vec3 normal) {
    vec3 light_direction = normalize(vec3(0.35, 0.80, 0.55));
    float diffuse = max(dot(normalize(normal), light_direction), 0.0);
    int band_count = clamp(u_cel_band_count, 1, CEL_MAX_BAND_COUNT);
    int band_id = 0;

    for (int threshold_index = 0;
         threshold_index < CEL_MAX_BAND_COUNT - 1;
         threshold_index++) {
        if (threshold_index >= band_count - 1 ||
            diffuse <= u_cel_band_thresholds[threshold_index]) {
            break;
        }
        band_id++;
    }
    return band_id;
}

float cel_band_brightness(int band_id) {
    int band_count = clamp(u_cel_band_count, 1, CEL_MAX_BAND_COUNT);
    if (band_count == 1) {
        return 1.0;
    }

    // A gentle curve retains the original three-band appearance closely
    // (0.32, ~0.62, 1.0) and produces useful levels for every other count.
    float band_position =
        float(clamp(band_id, 0, band_count - 1)) / float(band_count - 1);
    return mix(0.32, 1.0, pow(band_position, 1.18));
}
