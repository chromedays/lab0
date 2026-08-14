// Single source of truth for scene shading and metadata classification.
const int CEL_MAX_BANDS = 8;
const int CEL_RAMP_WIDTH = 256;
const int CEL_ALPHA_MODE_OPAQUE = 0;
const int CEL_ALPHA_MODE_MASK = 1;
const int CEL_ACCENT_RIM = 1;
const int CEL_ACCENT_HIGHLIGHT = 2;

uniform sampler2D u_cel_ramp;
uniform vec3 u_light_direction;
uniform float u_wrap_lighting;
uniform float u_band_brightness[CEL_MAX_BANDS];
uniform float u_band_tint_mix[CEL_MAX_BANDS];
uniform int u_alpha_mode;
uniform float u_alpha_cutoff;
uniform vec3 u_view_position;
uniform int u_rim_enabled;
uniform vec3 u_rim_color;
uniform float u_rim_threshold;
uniform float u_rim_strength;
uniform int u_highlight_enabled;
uniform vec3 u_highlight_color;
uniform float u_highlight_threshold;
uniform float u_highlight_strength;

struct Cel_Ramp_Sample {
    int band_id;
    vec3 tint;
};

float cel_diffuse_value(vec3 normal) {
    float raw_diffuse = dot(
        normalize(normal),
        normalize(u_light_direction)
    );
    float wrap_denominator = max(1.0 + u_wrap_lighting, 0.0001);
    return clamp(
        (raw_diffuse + u_wrap_lighting) / wrap_denominator,
        0.0,
        1.0
    );
}

Cel_Ramp_Sample cel_ramp_sample(vec3 normal) {
    float diffuse = cel_diffuse_value(normal);
    int ramp_index = int(floor(diffuse * 255.0 + 0.5));
    vec4 encoded = texelFetch(u_cel_ramp, ivec2(ramp_index, 0), 0);
    Cel_Ramp_Sample result;
    result.band_id = clamp(
        int(floor(encoded.a * 255.0 + 0.5)) - 1,
        0,
        CEL_MAX_BANDS - 1
    );
    result.tint = encoded.rgb;
    return result;
}

bool cel_alpha_discarded(float material_alpha) {
    return u_alpha_mode == CEL_ALPHA_MODE_MASK &&
           material_alpha < u_alpha_cutoff;
}

int cel_accent_flags(vec3 normal, vec3 world_position) {
    vec3 unit_normal = normalize(normal);
    vec3 view_delta = u_view_position - world_position;
    float view_length = length(view_delta);
    vec3 view_direction = view_length > 0.00001 ?
        view_delta / view_length : vec3(0.0, 0.0, 1.0);

    int flags = 0;
    float rim_value = 1.0 - max(dot(unit_normal, view_direction), 0.0);
    if (u_rim_enabled != 0 && rim_value >= u_rim_threshold) {
        flags |= CEL_ACCENT_RIM;
    }

    vec3 half_delta = normalize(u_light_direction) + view_direction;
    float half_length = length(half_delta);
    float highlight_value = 0.0;
    if (half_length > 0.00001) {
        highlight_value = max(dot(unit_normal, half_delta / half_length), 0.0);
    }
    if (u_highlight_enabled != 0 &&
        highlight_value >= u_highlight_threshold) {
        flags |= CEL_ACCENT_HIGHLIGHT;
    }
    return flags;
}

vec3 cel_apply_band(vec3 albedo, Cel_Ramp_Sample ramp_sample) {
    float brightness = u_band_brightness[ramp_sample.band_id];
    float tint_mix = u_band_tint_mix[ramp_sample.band_id];
    vec3 multiplied = albedo * brightness;
    vec3 tinted = ramp_sample.tint * brightness;
    return mix(multiplied, tinted, tint_mix);
}

vec3 cel_apply_accents(vec3 color, int accent_flags) {
    vec3 result = color;
    if ((accent_flags & CEL_ACCENT_RIM) != 0) {
        result += u_rim_color * u_rim_strength;
    }
    if ((accent_flags & CEL_ACCENT_HIGHLIGHT) != 0) {
        result += u_highlight_color * u_highlight_strength;
    }
    return result;
}
