// Single source of truth for scene shading and cel-band classification.
const int CEL_BAND_SHADOW = 0;
const int CEL_BAND_MIDDLE = 1;
const int CEL_BAND_BRIGHT = 2;

int cel_band_id(vec3 normal) {
    vec3 light_direction = normalize(vec3(0.35, 0.80, 0.55));
    float diffuse = max(dot(normalize(normal), light_direction), 0.0);

    if (diffuse > 0.65) {
        return CEL_BAND_BRIGHT;
    }
    if (diffuse > 0.25) {
        return CEL_BAND_MIDDLE;
    }
    return CEL_BAND_SHADOW;
}

float cel_band_brightness(int band_id) {
    if (band_id == CEL_BAND_BRIGHT) {
        return 1.0;
    }
    if (band_id == CEL_BAND_MIDDLE) {
        return 0.62;
    }
    return 0.32;
}
