#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform sampler2D u_cel_band_texture;
uniform vec4 colDiffuse;
uniform vec2 u_source_resolution;
uniform vec2 u_target_resolution;
uniform float u_color_cluster_threshold;
uniform int u_rim_preserve_samples;
uniform int u_highlight_preserve_samples;

out vec4 finalColor;

#include "downsample_common.glsl"

float color_distance_squared(vec3 first_color, vec3 second_color) {
    vec3 color_delta = first_color - second_color;
    return dot(color_delta * color_delta, vec3(0.299, 0.587, 0.114));
}

void main() {
    vec2 sample_uvs[DOWNSAMPLE_SAMPLE_COUNT];
    int sample_bands[DOWNSAMPLE_SAMPLE_COUNT];
    int sample_accents[DOWNSAMPLE_SAMPLE_COUNT];

    for (int sample_index = 0;
         sample_index < DOWNSAMPLE_SAMPLE_COUNT;
         sample_index++) {
        vec2 sample_uv = downsample_sample_uv(
            fragTexCoord,
            u_source_resolution,
            u_target_resolution,
            sample_index
        );
        sample_uvs[sample_index] = sample_uv;
        sample_bands[sample_index] = decode_cel_band(
            texture(u_cel_band_texture, sample_uv)
        );
        sample_accents[sample_index] = decode_cel_accents(
            texture(u_cel_band_texture, sample_uv)
        );
    }

    // First choose the cel-shading band with the greatest source coverage.
    int winning_band = -1;
    int winning_band_votes = -1;
    float winning_band_center_distance = 2.0;
    for (int candidate_index = 0;
         candidate_index < DOWNSAMPLE_SAMPLE_COUNT;
         candidate_index++) {
        int candidate_band = sample_bands[candidate_index];
        if (candidate_band < 0) {
            continue;
        }

        int matching_band_votes = 0;
        float nearest_center_distance = 2.0;
        for (int sample_index = 0;
             sample_index < DOWNSAMPLE_SAMPLE_COUNT;
             sample_index++) {
            if (sample_bands[sample_index] == candidate_band) {
                matching_band_votes++;
                vec2 grid_position = downsample_grid_position(sample_index);
                nearest_center_distance = min(
                    nearest_center_distance,
                    dot(grid_position, grid_position)
                );
            }
        }

        bool wins_by_count = matching_band_votes > winning_band_votes;
        bool wins_count_tie =
            matching_band_votes == winning_band_votes &&
            nearest_center_distance < winning_band_center_distance;
        bool wins_stable_tie =
            matching_band_votes == winning_band_votes &&
            nearest_center_distance == winning_band_center_distance &&
            (winning_band < 0 || candidate_band < winning_band);
        if (wins_by_count || wins_count_tie || wins_stable_tie) {
            winning_band = candidate_band;
            winning_band_votes = matching_band_votes;
            winning_band_center_distance = nearest_center_distance;
        }
    }

    if (winning_band < 0) {
        finalColor = vec4(0.0);
        return;
    }

    const int CEL_ACCENT_RIM = 1;
    const int CEL_ACCENT_HIGHLIGHT = 2;
    int rim_votes = 0;
    int highlight_votes = 0;
    for (int sample_index = 0;
         sample_index < DOWNSAMPLE_SAMPLE_COUNT;
         sample_index++) {
        if (sample_bands[sample_index] != winning_band) {
            continue;
        }
        if ((sample_accents[sample_index] & CEL_ACCENT_RIM) != 0) {
            rim_votes++;
        }
        if ((sample_accents[sample_index] & CEL_ACCENT_HIGHLIGHT) != 0) {
            highlight_votes++;
        }
    }

    int winning_accent = 0;
    if (highlight_votes >= clamp(
            u_highlight_preserve_samples,
            1,
            DOWNSAMPLE_SAMPLE_COUNT
        )) {
        winning_accent = CEL_ACCENT_HIGHLIGHT;
    } else if (rim_votes >= clamp(
                   u_rim_preserve_samples,
                   1,
                   DOWNSAMPLE_SAMPLE_COUNT
               )) {
        winning_accent = CEL_ACCENT_RIM;
    }

    // Within the dominant band, find the actual source color with the densest
    // neighborhood. Returning an existing sample avoids inventing a blended
    // color at hard albedo boundaries.
    vec3 sample_colors[DOWNSAMPLE_SAMPLE_COUNT];
    for (int sample_index = 0;
         sample_index < DOWNSAMPLE_SAMPLE_COUNT;
         sample_index++) {
        bool accent_matches = winning_accent == 0 ||
            (sample_accents[sample_index] & winning_accent) != 0;
        if (sample_bands[sample_index] == winning_band && accent_matches) {
            sample_colors[sample_index] = texture(
                texture0,
                sample_uvs[sample_index]
            ).rgb;
        } else {
            sample_colors[sample_index] = vec3(0.0);
        }
    }

    float color_cluster_threshold = max(u_color_cluster_threshold, 0.0);
    float color_cluster_threshold_squared =
        color_cluster_threshold * color_cluster_threshold;
    int winning_sample_index = -1;
    int winning_color_votes = -1;
    float winning_color_center_distance = 2.0;

    for (int candidate_index = 0;
         candidate_index < DOWNSAMPLE_SAMPLE_COUNT;
         candidate_index++) {
        bool candidate_accent_matches = winning_accent == 0 ||
            (sample_accents[candidate_index] & winning_accent) != 0;
        if (sample_bands[candidate_index] != winning_band ||
            !candidate_accent_matches) {
            continue;
        }

        int neighboring_color_votes = 0;
        for (int sample_index = 0;
             sample_index < DOWNSAMPLE_SAMPLE_COUNT;
             sample_index++) {
            bool sample_accent_matches = winning_accent == 0 ||
                (sample_accents[sample_index] & winning_accent) != 0;
            if (sample_bands[sample_index] == winning_band &&
                sample_accent_matches &&
                color_distance_squared(
                    sample_colors[candidate_index],
                    sample_colors[sample_index]
                ) <= color_cluster_threshold_squared) {
                neighboring_color_votes++;
            }
        }

        vec2 grid_position = downsample_grid_position(candidate_index);
        float center_distance = dot(grid_position, grid_position);
        if (neighboring_color_votes > winning_color_votes ||
            (neighboring_color_votes == winning_color_votes &&
             center_distance < winning_color_center_distance)) {
            winning_sample_index = candidate_index;
            winning_color_votes = neighboring_color_votes;
            winning_color_center_distance = center_distance;
        }
    }

    vec4 winning_color = vec4(sample_colors[winning_sample_index], 1.0);
    finalColor = winning_color * fragColor * colDiffuse;
}
