#version 330

// Classification-aware color downsampler. For each logical pixel it samples a
// fixed 4x4 source footprint, chooses a dominant cel band and preservable accent,
// then returns an existing representative source color rather than averaging
// across hard albedo or lighting boundaries.

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
uniform int u_edge_aa_mode;

out vec4 finalColor;

#include "downsample_common.glsl"

// color_distance_squared uses luma-weighted squared RGB distance. Avoiding sqrt
// keeps the pairwise clustering loop inexpensive and threshold comparisons exact.
float color_distance_squared(vec3 first_color, vec3 second_color) {
    vec3 color_delta = first_color - second_color;
    return dot(color_delta * color_delta, vec3(0.299, 0.587, 0.114));
}

void main() {
    // Cache UVs and decoded metadata once; later voting stages repeatedly compare
    // the same 16 samples.
    vec2 sample_uvs[DOWNSAMPLE_SAMPLE_COUNT];
    int sample_bands[DOWNSAMPLE_SAMPLE_COUNT];
    int sample_accents[DOWNSAMPLE_SAMPLE_COUNT];
    int sample_shadows[DOWNSAMPLE_SAMPLE_COUNT];
    float resolved_coverage = 0.0;

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
        vec4 encoded_sample = texture(u_cel_band_texture, sample_uv);
        sample_bands[sample_index] = decode_cel_band(encoded_sample);
        sample_accents[sample_index] = decode_cel_accents(encoded_sample);
        sample_shadows[sample_index] = decode_cel_shadow(encoded_sample);
        resolved_coverage += encoded_sample.a;
    }

    // First choose the cel-shading band with the greatest source coverage.
    // Ties prefer a sample nearest the footprint center, then the lower band ID,
    // making output stable regardless of candidate traversal coincidences.
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

    // Resolve the binary shadow state independently inside the dominant cel
    // band. This keeps hard shadow boundaries from being erased by the later
    // color-neighborhood vote. Unshadowed Viewer/Game metadata remains all zero
    // and follows the exact historical selection path.
    int winning_shadow = 0;
    int winning_shadow_votes = -1;
    float winning_shadow_center_distance = 2.0;
    for (int candidate_index = 0;
         candidate_index < DOWNSAMPLE_SAMPLE_COUNT;
         candidate_index++) {
        if (sample_bands[candidate_index] != winning_band) {
            continue;
        }
        int candidate_shadow = sample_shadows[candidate_index];
        int matching_shadow_votes = 0;
        float nearest_center_distance = 2.0;
        for (int sample_index = 0;
             sample_index < DOWNSAMPLE_SAMPLE_COUNT;
             sample_index++) {
            if (sample_bands[sample_index] == winning_band &&
                sample_shadows[sample_index] == candidate_shadow) {
                matching_shadow_votes++;
                vec2 grid_position = downsample_grid_position(sample_index);
                nearest_center_distance = min(
                    nearest_center_distance,
                    dot(grid_position, grid_position)
                );
            }
        }
        bool wins_by_count = matching_shadow_votes > winning_shadow_votes;
        bool wins_count_tie =
            matching_shadow_votes == winning_shadow_votes &&
            nearest_center_distance < winning_shadow_center_distance;
        bool wins_stable_tie =
            matching_shadow_votes == winning_shadow_votes &&
            nearest_center_distance == winning_shadow_center_distance &&
            candidate_shadow < winning_shadow;
        if (wins_by_count || wins_count_tie || wins_stable_tie) {
            winning_shadow = candidate_shadow;
            winning_shadow_votes = matching_shadow_votes;
            winning_shadow_center_distance = nearest_center_distance;
        }
    }

    const int CEL_ACCENT_RIM = 1;
    const int CEL_ACCENT_HIGHLIGHT = 2;
    int rim_votes = 0;
    int highlight_votes = 0;
    for (int sample_index = 0;
         sample_index < DOWNSAMPLE_SAMPLE_COUNT;
         sample_index++) {
        if (sample_bands[sample_index] != winning_band ||
            sample_shadows[sample_index] != winning_shadow) {
            continue;
        }
        if ((sample_accents[sample_index] & CEL_ACCENT_RIM) != 0) {
            rim_votes++;
        }
        if ((sample_accents[sample_index] & CEL_ACCENT_HIGHLIGHT) != 0) {
            highlight_votes++;
        }
    }

    // Highlights outrank rims when both satisfy their authorable preservation
    // vote thresholds. A zero winner allows all samples in the dominant band.
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
        if (sample_bands[sample_index] == winning_band &&
            sample_shadows[sample_index] == winning_shadow &&
            accent_matches) {
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
            sample_shadows[candidate_index] != winning_shadow ||
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
                sample_shadows[sample_index] == winning_shadow &&
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

    // winning_sample_index is guaranteed once a non-background band wins because
    // at least one sample belongs to that band and matches the selected accent.
    // Coverage AA keeps the representative source color but resolves silhouette
    // occupancy from the same deterministic 4x4 metadata footprint. Hard mode
    // deliberately retains the historical binary alpha contract.
    float output_alpha = 1.0;
    if (u_edge_aa_mode != 0) {
        output_alpha = clamp(
            resolved_coverage / float(DOWNSAMPLE_SAMPLE_COUNT),
            0.0,
            1.0
        );
    }
    vec4 winning_color = vec4(
        sample_colors[winning_sample_index],
        output_alpha
    );
    finalColor = winning_color * fragColor * colDiffuse;
}
