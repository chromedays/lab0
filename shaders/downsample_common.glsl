// Shared 4x4 sampling coordinates for color and coverage downscaling.
const int DOWNSAMPLE_GRID_SIZE = 4;
const int DOWNSAMPLE_SAMPLE_COUNT =
    DOWNSAMPLE_GRID_SIZE * DOWNSAMPLE_GRID_SIZE;

vec2 downsample_grid_position(int sample_index) {
    int x = sample_index % DOWNSAMPLE_GRID_SIZE;
    int y = sample_index / DOWNSAMPLE_GRID_SIZE;
    return
        (vec2(float(x), float(y)) + 0.5) /
        float(DOWNSAMPLE_GRID_SIZE) - 0.5;
}

vec2 downsample_sample_uv(
    vec2 texture_coordinate,
    vec2 source_resolution,
    vec2 target_resolution,
    int sample_index
) {
    vec2 source_texel_size = 1.0 / source_resolution;
    vec2 target_pixel = floor(texture_coordinate * target_resolution);
    vec2 footprint_in_source_pixels = source_resolution / target_resolution;
    vec2 source_center =
        (target_pixel + 0.5) * footprint_in_source_pixels;
    vec2 source_position =
        source_center +
        downsample_grid_position(sample_index) * footprint_in_source_pixels;
    vec2 sample_uv = source_position / source_resolution;
    return clamp(
        sample_uv,
        source_texel_size * 0.5,
        vec2(1.0) - source_texel_size * 0.5
    );
}

float sample_downscaled_alpha(
    sampler2D source_texture,
    vec2 texture_coordinate,
    vec2 source_resolution,
    vec2 target_resolution
) {
    float alpha = 0.0;
    for (int sample_index = 0;
         sample_index < DOWNSAMPLE_SAMPLE_COUNT;
         sample_index++) {
        vec2 sample_uv = downsample_sample_uv(
            texture_coordinate,
            source_resolution,
            target_resolution,
            sample_index
        );
        alpha += texture(source_texture, sample_uv).a;
    }
    return alpha / float(DOWNSAMPLE_SAMPLE_COUNT);
}

int decode_cel_band(vec4 encoded_sample) {
    if (encoded_sample.a <= 0.8) {
        return -1;
    }
    return int(floor(encoded_sample.r * 255.0 + 0.5)) - 1;
}
