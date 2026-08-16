package tests

// Viewer camera tests specify the initial orientation and lens-aware framing
// without requiring a raylib window or GPU context.

import "core:math"
import "core:testing"
import rl "vendor:raylib"

@(test)
viewer_initial_camera_is_isometric_and_fits_the_lens :: proc(t: ^testing.T) {
    model_center := rl.Vector3{2, 3, 4}
    model_dimensions := rl.Vector3{1, 2, 3}
    screen_height: f32 = 720

    camera, projected_width, projected_height :=
        viewer_isometric_camera_frame(
            model_center,
            model_dimensions,
            3,
            screen_height,
        )

    camera_axis := rl.Vector3Normalize(camera.position - camera.target)
    expected_axis := rl.Vector3Normalize(rl.Vector3{1, 1, 1})
    testing.expectf(
        t,
        rl.Vector3Distance(camera_axis, expected_axis) < 0.00001,
        "initial camera axis must give +X, +Y, and +Z equal weight",
    )
    testing.expect_value(t, camera.target, model_center)
    testing.expect_value(t, camera.up, rl.Vector3{0, 1, 0})
    testing.expect_value(t, camera.projection, rl.CameraProjection.ORTHOGRAPHIC)

    lens_world_width := camera.fovy * DEFAULT_LENS_SIZE / screen_height
    lens_world_height := camera.fovy * DEFAULT_LENS_SIZE / screen_height
    width_fill := projected_width / lens_world_width
    height_fill := projected_height / lens_world_height
    testing.expectf(
        t,
        width_fill <= 0.80001 && height_fill <= 0.80001,
        "isometric projection must fit inside the initial lens",
    )
    testing.expectf(
        t,
        math.abs(max(width_fill, height_fill) - 0.8) < 0.00001,
        "largest projected dimension must use 80%% of the lens",
    )
}
