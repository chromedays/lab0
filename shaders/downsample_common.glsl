// Shared sampling implementation for color and coverage-mask downscaling.
vec4 sample_downscaled_texture(
    sampler2D source_texture,
    vec2 texture_coordinate,
    vec2 source_resolution,
    vec2 target_resolution
) {
    vec2 source_texel_size = 1.0 / source_resolution;

    // SAMPLE_GRID=4 takes 16 evenly distributed samples across the complete
    // source footprint represented by one low-resolution output pixel.
    const int SAMPLE_GRID = 4;
    vec2 target_pixel = floor(texture_coordinate * target_resolution);
    vec2 footprint_in_source_pixels = source_resolution / target_resolution;
    vec2 source_center =
        (target_pixel + 0.5) * footprint_in_source_pixels;
    vec4 color = vec4(0.0);

    for (int y = 0; y < SAMPLE_GRID; y++) {
        for (int x = 0; x < SAMPLE_GRID; x++) {
            vec2 grid_position =
                (vec2(float(x), float(y)) + 0.5) / float(SAMPLE_GRID) - 0.5;
            vec2 source_position =
                source_center + grid_position * footprint_in_source_pixels;
            vec2 sample_uv = source_position / source_resolution;
            sample_uv = clamp(
                sample_uv,
                source_texel_size * 0.5,
                vec2(1.0) - source_texel_size * 0.5
            );
            color += texture(source_texture, sample_uv);
        }
    }

    return color / float(SAMPLE_GRID * SAMPLE_GRID);
}
