package main

// These tests define integer downsample sizing at normal and pathological
// inputs, ensuring RenderTexture dimensions can never become zero.

import "core:testing"

// A positive level performs the expected truncating integer division.
@test
downsample_dimension_uses_the_selected_level :: proc(t: ^testing.T) {
    testing.expect_value(t, get_downsample_dimension(1280, 10), 128)
    testing.expect_value(t, get_downsample_dimension(720, 10), 72)
    testing.expect_value(t, get_downsample_dimension(1280, 16), 80)
    testing.expect_value(t, get_downsample_dimension(720, 16), 45)
}

// Oversized levels and invalid source dimensions still produce at least one pixel.
@test
downsample_dimension_never_reaches_zero :: proc(t: ^testing.T) {
    testing.expect_value(t, get_downsample_dimension(16, 32), 1)
    testing.expect_value(t, get_downsample_dimension(16, 0), 16)
}
