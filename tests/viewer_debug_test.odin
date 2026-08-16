package tests

// CPU-only contracts for pass navigation and preview-to-texture coordinates.

import "core:c"
import "core:testing"
import rl "vendor:raylib"

@(test)
viewer_debug_cycle_wraps_in_both_directions :: proc(t: ^testing.T) {
    state := viewer_render_debug_state_make()
    testing.expect_value(t, state.selected, Viewer_Render_Debug_Pass.SCENE_COLOR)

    viewer_render_debug_cycle_pass(&state, -1)
    testing.expect_value(t, state.selected, Viewer_Render_Debug_Pass.COMPOSITE)

    viewer_render_debug_cycle_pass(&state, 1)
    testing.expect_value(t, state.selected, Viewer_Render_Debug_Pass.SCENE_COLOR)

    viewer_render_debug_cycle_pass(&state, 3)
    testing.expect_value(t, state.selected, Viewer_Render_Debug_Pass.COVERAGE)
}

@(test)
viewer_debug_video_divides_300_frames_across_six_passes :: proc(t: ^testing.T) {
    testing.expect_value(
        t,
        viewer_render_debug_video_pass(0, 300),
        Viewer_Render_Debug_Pass.SCENE_COLOR,
    )
    testing.expect_value(
        t,
        viewer_render_debug_video_pass(49, 300),
        Viewer_Render_Debug_Pass.SCENE_COLOR,
    )
    testing.expect_value(
        t,
        viewer_render_debug_video_pass(50, 300),
        Viewer_Render_Debug_Pass.CEL_BANDS,
    )
    testing.expect_value(
        t,
        viewer_render_debug_video_pass(249, 300),
        Viewer_Render_Debug_Pass.OUTLINED,
    )
    testing.expect_value(
        t,
        viewer_render_debug_video_pass(250, 300),
        Viewer_Render_Debug_Pass.COMPOSITE,
    )
    testing.expect_value(
        t,
        viewer_render_debug_video_pass(999, 300),
        Viewer_Render_Debug_Pass.COMPOSITE,
    )
}

@(test)
viewer_debug_close_restores_frozen_playback :: proc(t: ^testing.T) {
    state := viewer_render_debug_state_make()
    state.open = true
    animation := Animation_Playback{is_playing = true}

    viewer_render_debug_freeze_toggle(&state, &animation)
    testing.expect(t, state.frozen)
    testing.expect(t, !animation.is_playing)

    viewer_render_debug_close(&state, &animation)
    testing.expect(t, !state.open)
    testing.expect(t, !state.frozen)
    testing.expect(t, animation.is_playing)
}

@(test)
viewer_debug_preview_preserves_source_aspect_ratio :: proc(t: ^testing.T) {
    full := viewer_render_debug_preview_bounds(128, 72, 1280, 720)
    testing.expect_value(t, full, rl.Rectangle{0, 0, 1280, 720})

    pillarboxed := viewer_render_debug_preview_bounds(400, 400, 1280, 720)
    testing.expect_value(t, pillarboxed, rl.Rectangle{280, 0, 720, 720})

    letterboxed := viewer_render_debug_preview_bounds(1280, 400, 1280, 720)
    testing.expect_value(t, letterboxed, rl.Rectangle{0, 160, 1280, 400})
}

@(test)
viewer_debug_preview_maps_top_left_logical_pixels :: proc(t: ^testing.T) {
    preview := rl.Rectangle{280, 0, 720, 720}

    x, y, valid := viewer_render_debug_preview_pixel(
        {280, 0},
        preview,
        400,
        400,
    )
    testing.expect(t, valid)
    testing.expect_value(t, x, c.int(0))
    testing.expect_value(t, y, c.int(0))

    x, y, valid = viewer_render_debug_preview_pixel(
        {999, 719},
        preview,
        400,
        400,
    )
    testing.expect(t, valid)
    testing.expect_value(t, x, c.int(399))
    testing.expect_value(t, y, c.int(399))

    _, _, valid = viewer_render_debug_preview_pixel(
        {100, 100},
        preview,
        400,
        400,
    )
    testing.expect(t, !valid)
}
