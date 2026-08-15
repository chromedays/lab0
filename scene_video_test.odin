package main

// Scene video tests specify exact duration-to-frame conversion, option
// compatibility, and the non-duplicating camera orbit sampled from one authored
// camera pose.

import "core:math"
import "core:testing"
import rl "vendor:raylib"

@test
scene_video_duration_requires_exact_60_hz_frame_count :: proc(t: ^testing.T) {
    frame_count, valid := scene_video_duration_frame_count("5")
    testing.expect(t, valid)
    testing.expect_value(t, frame_count, u64(300))

    _, fractional_invalid := scene_video_duration_frame_count("1.001")
    testing.expect(t, !fractional_invalid)
    _, zero_invalid := scene_video_duration_frame_count("0")
    testing.expect(t, !zero_invalid)
}

@test
scene_video_options_accept_scene_composite_capture :: proc(t: ^testing.T) {
    options := Scene_Run_Options{
        scene_path = "scenes/primitive-light-grid.json",
        scene_path_set = true,
        video_output = "artifacts/report/scene-editor-test.mp4",
        video_frame_count = 300,
    }
    capture := Capture_Options{enabled = true, target = .COMPOSITE}
    testing.expect_value(
        t,
        validate_scene_video_options(&options, &capture),
        Scene_Video_Options_Error.NONE,
    )
}

@test
scene_video_options_reject_invalid_and_conflicting_requests :: proc(
    t: ^testing.T,
) {
    options := Scene_Run_Options{video_duration_set = true}
    capture := Capture_Options{enabled = true, target = .COMPOSITE}
    testing.expect_value(
        t,
        validate_scene_video_options(&options, &capture),
        Scene_Video_Options_Error.DURATION_WITHOUT_OUTPUT,
    )

    options.video_output = "artifacts/report/scene-editor-test.mov"
    testing.expect_value(
        t,
        validate_scene_video_options(&options, &capture),
        Scene_Video_Options_Error.INVALID_OUTPUT,
    )
    options.video_output = "artifacts/report/scene-editor-test.mp4"
    testing.expect_value(
        t,
        validate_scene_video_options(&options, &capture),
        Scene_Video_Options_Error.MISSING_SCENE,
    )
    options.scene_path_set = true
    capture.enabled = false
    testing.expect_value(
        t,
        validate_scene_video_options(&options, &capture),
        Scene_Video_Options_Error.MISSING_CAPTURE,
    )
    capture.enabled = true
    capture.target = .SCENE
    testing.expect_value(
        t,
        validate_scene_video_options(&options, &capture),
        Scene_Video_Options_Error.INVALID_TARGET,
    )
    capture.target = .COMPOSITE
    capture.output_path_explicit = true
    testing.expect_value(
        t,
        validate_scene_video_options(&options, &capture),
        Scene_Video_Options_Error.CONFLICTING_CAPTURE_OUTPUT,
    )
}

@test
scene_video_orbit_preserves_radius_and_omits_duplicate_endpoint :: proc(
    t: ^testing.T,
) {
    scene := make_default_scene()
    defer destroy_scene(&scene)
    camera := scene.camera
    start_radius := rl.Vector3Distance(camera.position, camera.target)
    first := scene_video_orbit_camera(camera, 0, 300)
    quarter := scene_video_orbit_camera(camera, 75, 300)
    last := scene_video_orbit_camera(camera, 299, 300)

    testing.expect_value(t, first.position, camera.position)
    testing.expectf(
        t,
        math.abs(rl.Vector3Distance(quarter.position, camera.target) -
                 start_radius) < 0.0001,
        "quarter-orbit radius changed",
    )
    testing.expectf(
        t,
        rl.Vector3Distance(last.position, first.position) > 0.001,
        "last frame must not duplicate frame zero",
    )
    testing.expectf(
        t,
        math.abs(scene_video_orbit_degrees(299, 300) - 358.8) < 0.0001,
        "unexpected final orbit angle",
    )
}
