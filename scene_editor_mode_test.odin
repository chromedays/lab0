package main

import "core:testing"

@test
scene_mode_parser_accepts_scene_path_and_mode :: proc(t: ^testing.T) {
    options, valid, bad_argument := parse_scene_run_options({
        "--mode", "scene-editor",
        "--scene", "scenes/primitive-light-grid.json",
    })
    testing.expect(t, valid, bad_argument)
    testing.expect(t, options.scene_path_set)
    testing.expect_value(t, options.scene_path, "scenes/primitive-light-grid.json")
}

@test
scene_mode_parser_rejects_game_options :: proc(t: ^testing.T) {
    _, valid, bad_argument := parse_scene_run_options({
        "--mode", "scene-editor",
        "--game-room", "R00",
    })
    testing.expect(t, !valid)
    testing.expect_value(t, bad_argument, "--game-room")
}

@test
scene_mode_parser_accepts_video_report_options :: proc(t: ^testing.T) {
    arguments := []string{
        "--mode", "scene-editor",
        "--scene", "scenes/primitive-light-grid.json",
        "--scene-video-output", "artifacts/report/scene-editor-test.mp4",
        "--scene-video-duration", "5",
        "--capture-case", "scene-video",
        "--capture-target", "composite",
    }
    options, valid, bad_argument := parse_scene_run_options(arguments)
    testing.expect(t, valid, bad_argument)
    testing.expect_value(
        t,
        options.video_output,
        "artifacts/report/scene-editor-test.mp4",
    )
    testing.expect(t, options.video_duration_set)
    testing.expect_value(t, options.video_frame_count, u64(300))

    capture_result := parse_capture_options(arguments)
    defer destroy_capture_options(&capture_result.options)
    testing.expect_value(t, capture_result.error, Capture_Parse_Error.NONE)
    testing.expect(
        t,
        validate_scene_capture_options(
            arguments,
            &options,
            &capture_result.options,
        ),
    )
    testing.expect_value(
        t,
        validate_scene_video_options(&options, &capture_result.options),
        Scene_Video_Options_Error.NONE,
    )
}

@test
scene_capture_accepts_only_scene_owned_render_state :: proc(t: ^testing.T) {
    arguments := []string{
        "--mode", "scene-editor",
        "--scene", "scenes/primitive-light-grid.json",
        "--capture-case", "scene-grid",
        "--capture-target", "scene",
    }
    options, valid, _ := parse_scene_run_options(arguments)
    testing.expect(t, valid)
    capture_result := parse_capture_options(arguments)
    defer destroy_capture_options(&capture_result.options)
    testing.expect_value(t, capture_result.error, Capture_Parse_Error.NONE)
    testing.expect(
        t,
        validate_scene_capture_options(arguments, &options, &capture_result.options),
    )

    invalid_arguments := []string{
        "--mode", "scene-editor",
        "--scene", "scenes/primitive-light-grid.json",
        "--capture-case", "scene-grid",
        "--capture-edge-aa", "hard",
    }
    invalid_capture := parse_capture_options(invalid_arguments)
    defer destroy_capture_options(&invalid_capture.options)
    testing.expect(
        t,
        !validate_scene_capture_options(
            invalid_arguments,
            &options,
            &invalid_capture.options,
        ),
    )
}

@test
bundled_scene_fixture_loads_with_fixed_pose_metadata :: proc(t: ^testing.T) {
    scene, load_error := load_scene("scenes/primitive-light-grid.json")
    defer destroy_scene(&scene)
    if !testing.expect_value(t, load_error, Scene_Error.NONE) { return }
    testing.expect_value(t, len(scene.models), 1)
    testing.expect_value(t, len(scene.primitives), 7)
    testing.expect_value(t, len(scene.point_lights), 2)
    testing.expect_value(t, len(scene.spot_lights), 1)
    testing.expect(t, scene.directional_light.casts_shadows)
    testing.expect_value(t, scene.directional_light.shadow_extent, f32(18))
    _, pose_present := scene.models[0].animation.?
    testing.expect(t, pose_present)
}

@test
bundled_animated_pose_fixture_loads :: proc(t: ^testing.T) {
    scene, load_error := load_scene("scenes/animated-model-pose.json")
    defer destroy_scene(&scene)
    if !testing.expect_value(t, load_error, Scene_Error.NONE) { return }
    testing.expect_value(t, len(scene.models), 1)
    pose, pose_present := scene.models[0].animation.?
    if !testing.expect(t, pose_present) { return }
    testing.expect_value(t, pose.clip_index, 0)
    testing.expect_value(t, pose.frame, 24)
}

@test
bundled_shadow_alignment_fixture_is_directional_only :: proc(t: ^testing.T) {
    scene, load_error := load_scene("scenes/shadow-alignment.json")
    defer destroy_scene(&scene)
    if !testing.expect_value(t, load_error, Scene_Error.NONE) { return }
    testing.expect_value(t, len(scene.models), 0)
    testing.expect_value(t, len(scene.primitives), 2)
    testing.expect_value(t, len(scene.point_lights), 0)
    testing.expect_value(t, len(scene.spot_lights), 0)
    testing.expect(t, scene.directional_light.casts_shadows)
    testing.expect_value(t, scene.directional_light.shadow_extent, f32(10))
}

@test
scene_editor_primitive_mutations_update_dirty_state :: proc(t: ^testing.T) {
    scene := make_default_scene()
    defer destroy_scene(&scene)
    resources: Scene_Resources
    state: Scene_Editor_UI_State
    scene_editor_ui_init(&state, "")

    original_index := scene_add_primitive(&scene, .CUBE)
    if !testing.expect_value(t, original_index, 0) { return }
    testing.expect(t, scene.dirty)
    scene.dirty = false
    state.selection = {.PRIMITIVE, original_index}
    if !testing.expect(
        t,
        scene_editor_duplicate_selection(&state, &scene, &resources),
    ) { return }
    testing.expect_value(t, len(scene.primitives), 2)
    testing.expect(t, scene.primitives[0].id != scene.primitives[1].id)
    testing.expect(t, scene.dirty)

    scene.dirty = false
    testing.expect(t, scene_editor_delete_selection(&state, &scene, &resources))
    testing.expect_value(t, len(scene.primitives), 1)
    testing.expect(t, scene.dirty)

    next_index := scene_add_primitive(&scene, .SPHERE)
    if !testing.expect_value(t, next_index, 1) { return }
    testing.expect_value(t, scene.primitives[next_index].id, "primitive_003")
}
