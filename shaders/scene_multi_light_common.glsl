// Shared Scene Editor lighting, cel classification, alpha, and accent logic.
// Both visible color and metadata shaders include this file so their band and
// accent decisions remain pixel-for-pixel identical.

const int CEL_MAX_BANDS = 8;
const int CEL_ALPHA_MODE_OPAQUE = 0;
const int CEL_ALPHA_MODE_MASK = 1;
const int CEL_ACCENT_RIM = 1;
const int CEL_ACCENT_HIGHLIGHT = 2;
const int SCENE_MAX_POINT_LIGHTS = 8;
const int SCENE_MAX_SPOT_LIGHTS = 8;
const float SCENE_EPSILON = 0.00001;

uniform sampler2D u_cel_ramp;
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

uniform int u_directional_enabled;
uniform vec3 u_directional_direction;
uniform vec3 u_directional_color;
uniform float u_directional_intensity;

uniform int u_shadow_enabled;
uniform sampler2D u_shadow_map;
uniform float u_shadow_strength;
uniform float u_shadow_bias;

uniform int u_point_count;
uniform vec3 u_point_positions[SCENE_MAX_POINT_LIGHTS];
uniform vec3 u_point_colors[SCENE_MAX_POINT_LIGHTS];
uniform float u_point_intensities[SCENE_MAX_POINT_LIGHTS];
uniform float u_point_ranges[SCENE_MAX_POINT_LIGHTS];

uniform int u_spot_count;
uniform vec3 u_spot_positions[SCENE_MAX_SPOT_LIGHTS];
uniform vec3 u_spot_directions[SCENE_MAX_SPOT_LIGHTS];
uniform vec3 u_spot_colors[SCENE_MAX_SPOT_LIGHTS];
uniform float u_spot_intensities[SCENE_MAX_SPOT_LIGHTS];
uniform float u_spot_ranges[SCENE_MAX_SPOT_LIGHTS];
uniform float u_spot_inner_cos[SCENE_MAX_SPOT_LIGHTS];
uniform float u_spot_outer_cos[SCENE_MAX_SPOT_LIGHTS];

struct Scene_Light_Sample {
    float band_input;
    vec3 hue;
    float highlight_score;
    int shadowed;
};

struct Cel_Ramp_Sample {
    int band_id;
    vec3 tint;
};

float scene_wrapped_lambert(vec3 normal, vec3 surface_to_light) {
    float denominator = max(1.0 + u_wrap_lighting, 0.0001);
    return clamp(
        (dot(normal, surface_to_light) + u_wrap_lighting) / denominator,
        0.0,
        1.0
    );
}

float scene_distance_attenuation(float distance_to_light, float light_range) {
    float x = clamp(distance_to_light / max(light_range, 0.001), 0.0, 1.0);
    float falloff = 1.0 - x * x;
    return falloff * falloff;
}

float scene_highlight_value(
    vec3 normal,
    vec3 surface_to_light,
    vec3 view_direction
) {
    vec3 half_delta = surface_to_light + view_direction;
    float half_length = length(half_delta);
    if (half_length <= SCENE_EPSILON) {
        return 0.0;
    }
    return max(dot(normal, half_delta / half_length), 0.0);
}

// A single nearest depth lookup deliberately produces a binary result. The
// light projection is texel-snapped on the CPU and this classification is also
// written to metadata, so no filtered/subpixel shadow boundary reaches the
// logical output-pixel resolver.
int scene_directional_shadow(vec3 normal) {
    if (u_shadow_enabled == 0 || fragShadowPosition.w <= SCENE_EPSILON) {
        return 0;
    }
    vec3 projected = fragShadowPosition.xyz / fragShadowPosition.w;
    vec3 shadow_coordinate = projected * 0.5 + 0.5;
    if (shadow_coordinate.x <= 0.0 || shadow_coordinate.x >= 1.0 ||
        shadow_coordinate.y <= 0.0 || shadow_coordinate.y >= 1.0 ||
        shadow_coordinate.z <= 0.0 || shadow_coordinate.z >= 1.0) {
        return 0;
    }
    float stored_depth = texture(u_shadow_map, shadow_coordinate.xy).r;
    float normal_alignment = max(
        dot(normal, normalize(u_directional_direction)),
        0.0
    );
    float receiver_bias = u_shadow_bias;
    return shadow_coordinate.z - receiver_bias > stored_depth ? 1 : 0;
}

Scene_Light_Sample scene_light_sample(vec3 input_normal, vec3 world_position) {
    vec3 normal = normalize(input_normal);
    vec3 view_delta = u_view_position - world_position;
    float view_length = length(view_delta);
    vec3 view_direction = view_length > SCENE_EPSILON ?
        view_delta / view_length : vec3(0.0, 0.0, 1.0);
    vec3 energy = vec3(0.0);
    float highlight_score = 0.0;
    int directional_shadow = scene_directional_shadow(normal);

    if (u_directional_enabled != 0) {
        vec3 light_direction = normalize(u_directional_direction);
        float diffuse = scene_wrapped_lambert(normal, light_direction);
        float visibility = 1.0 -
            float(directional_shadow) * clamp(u_shadow_strength, 0.0, 1.0);
        energy += u_directional_color *
                  u_directional_intensity * diffuse * visibility;
        highlight_score = max(
            highlight_score,
            scene_highlight_value(normal, light_direction, view_direction) *
                u_directional_intensity * visibility
        );
    }

    for (int i = 0; i < SCENE_MAX_POINT_LIGHTS; i++) {
        if (i >= u_point_count) {
            break;
        }
        vec3 delta = u_point_positions[i] - world_position;
        float distance_to_light = length(delta);
        vec3 light_direction = distance_to_light > SCENE_EPSILON ?
            delta / distance_to_light : normal;
        float attenuation = scene_distance_attenuation(
            distance_to_light,
            u_point_ranges[i]
        );
        float diffuse = scene_wrapped_lambert(normal, light_direction);
        float weight = u_point_intensities[i] * attenuation;
        energy += u_point_colors[i] * weight * diffuse;
        highlight_score = max(
            highlight_score,
            scene_highlight_value(normal, light_direction, view_direction) * weight
        );
    }

    for (int i = 0; i < SCENE_MAX_SPOT_LIGHTS; i++) {
        if (i >= u_spot_count) {
            break;
        }
        vec3 delta = u_spot_positions[i] - world_position;
        float distance_to_light = length(delta);
        vec3 light_direction = distance_to_light > SCENE_EPSILON ?
            delta / distance_to_light : normal;
        vec3 light_to_fragment = distance_to_light > SCENE_EPSILON ?
            -light_direction : normalize(u_spot_directions[i]);
        float theta = dot(normalize(u_spot_directions[i]), light_to_fragment);
        float cone = smoothstep(
            u_spot_outer_cos[i],
            u_spot_inner_cos[i],
            theta
        );
        float attenuation = scene_distance_attenuation(
            distance_to_light,
            u_spot_ranges[i]
        );
        float diffuse = scene_wrapped_lambert(normal, light_direction);
        float weight = u_spot_intensities[i] * attenuation * cone;
        energy += u_spot_colors[i] * weight * diffuse;
        highlight_score = max(
            highlight_score,
            scene_highlight_value(normal, light_direction, view_direction) * weight
        );
    }

    float peak = max(energy.r, max(energy.g, energy.b));
    Scene_Light_Sample result;
    result.band_input = clamp(peak, 0.0, 1.0);
    result.hue = peak > SCENE_EPSILON ? energy / peak : vec3(1.0);
    result.highlight_score = highlight_score;
    result.shadowed = directional_shadow;
    return result;
}

Cel_Ramp_Sample cel_ramp_sample(float diffuse) {
    int ramp_index = int(floor(clamp(diffuse, 0.0, 1.0) * 255.0 + 0.5));
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

int cel_accent_flags(
    vec3 input_normal,
    vec3 world_position,
    float highlight_score
) {
    vec3 normal = normalize(input_normal);
    vec3 view_delta = u_view_position - world_position;
    float view_length = length(view_delta);
    vec3 view_direction = view_length > SCENE_EPSILON ?
        view_delta / view_length : vec3(0.0, 0.0, 1.0);
    int flags = 0;
    float rim_value = 1.0 - max(dot(normal, view_direction), 0.0);
    if (u_rim_enabled != 0 && rim_value >= u_rim_threshold) {
        flags |= CEL_ACCENT_RIM;
    }
    if (u_highlight_enabled != 0 && highlight_score >= u_highlight_threshold) {
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
