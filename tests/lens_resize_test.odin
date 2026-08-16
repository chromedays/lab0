package tests

// Lens resize tests keep the interaction math independent of a native window.
// They protect the centered-square invariant, layout limits, pixel snapping,
// and drag ownership transitions used by the interactive Viewer.

import "core:testing"

@(test)
lens_default_bounds_remain_centered_and_square :: proc(t: ^testing.T) {
    bounds := centered_lens_bounds(1280, 720, DEFAULT_LENS_SIZE)

    testing.expect_value(t, bounds.x, f32(440))
    testing.expect_value(t, bounds.y, f32(160))
    testing.expect_value(t, bounds.width, f32(400))
    testing.expect_value(t, bounds.height, f32(400))

    handle := lens_resize_handle_bounds(bounds)
    testing.expect_value(t, handle.x, f32(831))
    testing.expect_value(t, handle.y, f32(551))
    testing.expect_value(t, handle.width, f32(18))
    testing.expect_value(t, handle.height, f32(18))
}

@(test)
lens_layout_limit_avoids_inspector_and_timeline :: proc(t: ^testing.T) {
    maximum_size := lens_layout_max_size(1280, 720, 940, 620)
    testing.expect_value(t, maximum_size, f32(500))
}

@(test)
lens_pointer_resize_snaps_and_clamps_square_size :: proc(t: ^testing.T) {
    snapped := lens_resize_size_for_pointer(
        813,
        520,
        640,
        360,
        MIN_LENS_SIZE,
        500,
        10,
    )
    testing.expect_value(t, snapped, f32(350))

    minimum := lens_resize_size_for_pointer(
        640,
        360,
        640,
        360,
        MIN_LENS_SIZE,
        500,
        10,
    )
    testing.expect_value(t, minimum, MIN_LENS_SIZE)

    crossed_center := lens_resize_size_for_pointer(
        500,
        200,
        640,
        360,
        MIN_LENS_SIZE,
        500,
        10,
    )
    testing.expect_value(t, crossed_center, MIN_LENS_SIZE)

    maximum := lens_resize_size_for_pointer(
        1000,
        720,
        640,
        360,
        MIN_LENS_SIZE,
        500,
        10,
    )
    testing.expect_value(t, maximum, f32(500))
}

@(test)
lens_resize_drag_owns_press_hold_and_release_frames :: proc(t: ^testing.T) {
    press_drag, active_drag := lens_resize_drag_for_frame(
        false,
        true,
        false,
        true,
        true,
        true,
    )
    testing.expect(t, press_drag)
    testing.expect(t, active_drag)

    hold_drag, next_drag := lens_resize_drag_for_frame(
        active_drag,
        true,
        false,
        false,
        false,
        true,
    )
    testing.expect(t, hold_drag)
    testing.expect(t, next_drag)

    release_drag, released_drag := lens_resize_drag_for_frame(
        next_drag,
        true,
        false,
        false,
        false,
        false,
    )
    testing.expect(t, release_drag)
    testing.expect(t, !released_drag)
}

@(test)
lens_resize_drag_refuses_blocked_or_unfocused_presses :: proc(t: ^testing.T) {
    blocked_drag, blocked_next := lens_resize_drag_for_frame(
        false,
        true,
        true,
        true,
        true,
        true,
    )
    testing.expect(t, !blocked_drag)
    testing.expect(t, !blocked_next)

    unfocused_drag, unfocused_next := lens_resize_drag_for_frame(
        true,
        false,
        false,
        true,
        false,
        true,
    )
    testing.expect(t, !unfocused_drag)
    testing.expect(t, !unfocused_next)
}
