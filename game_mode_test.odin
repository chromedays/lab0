package main

import "core:testing"
import rl "vendor:raylib"

@(test)
game_player_animation_uses_eight_samples :: proc(t: ^testing.T) {
    playback: Animation_Playback
    game_configure_player_animation(&playback)

    testing.expect(t, playback.sampled_playback)
    testing.expect_value(
        t,
        playback.sample_count,
        GAME_PLAYER_ANIMATION_SAMPLE_COUNT,
    )
}

@(test)
game_player_animation_quantizes_pose_frames :: proc(t: ^testing.T) {
    playback := Animation_Playback{current_frame = 29}
    game_configure_player_animation(&playback)
    animation := rl.ModelAnimation{keyframeCount = 121}

    pose_frame := get_animation_pose_frame(&playback, animation)

    testing.expect_value(t, pose_frame, f32(15))
}

@(test)
game_zombie_animation_maps_movement_attack_and_recovery_states :: proc(
    t: ^testing.T,
) {
    testing.expect_value(
        t,
        game_zombie_animation_kind(.SHAMBLING),
        Game_Zombie_Animation_Kind.WALKING,
    )
    testing.expect_value(
        t,
        game_zombie_animation_kind(.CHASING),
        Game_Zombie_Animation_Kind.WALKING,
    )
    testing.expect_value(
        t,
        game_zombie_animation_kind(.WINDUP),
        Game_Zombie_Animation_Kind.ATTACK,
    )
    testing.expect_value(
        t,
        game_zombie_animation_kind(.LUNGING),
        Game_Zombie_Animation_Kind.ATTACK,
    )
    testing.expect_value(
        t,
        game_zombie_animation_kind(.RECOVERING),
        Game_Zombie_Animation_Kind.IDLE,
    )
}

@(test)
game_mode_requires_the_explicit_game_value :: proc(t: ^testing.T) {
    testing.expect(
        t,
        game_mode_requested([]string{"--mode", "game"}),
        "--mode game should select the traversal prototype",
    )
    testing.expect(
        t,
        !game_mode_requested([]string{"--mode", "viewer"}),
        "viewer mode should remain on the existing application path",
    )
    testing.expect(
        t,
        !game_mode_requested([]string{"--capture-case", "viewer-case"}),
        "viewer capture arguments must not select Game mode",
    )
}

@(test)
game_run_options_parse_room_and_debug_independently_of_capture_flags :: proc(
    t: ^testing.T,
) {
    options, valid, error_argument := parse_game_run_options([]string{
        "--mode", "game",
        "--capture-case", "ravine",
        "--game-room", "R04",
        "--game-debug",
    })
    testing.expect(t, valid, error_argument)
    testing.expect_value(t, options.start_room, Game_Room_ID.R04_RAVINE_CROSSING)
    testing.expect(t, options.debug_visible, "--game-debug should enable diagnostics")
}

@(test)
game_run_options_reject_an_unknown_room :: proc(t: ^testing.T) {
    _, valid, error_argument := parse_game_run_options([]string{
        "--mode", "game",
        "--game-room", "R99",
    })
    testing.expect(t, !valid, "an unknown room must fail before opening a window")
    testing.expect_value(t, error_argument, "R99")
}

@(test)
game_run_options_accept_occlusion_test_scene :: proc(t: ^testing.T) {
    options, valid, error_argument := parse_game_run_options([]string{
        "--mode", "game",
        "--game-room", "occlusion-test",
    })
    testing.expect(t, valid, error_argument)
    testing.expect_value(t, options.start_room, Game_Room_ID.TEST_OCCLUSION)
    testing.expect(t, options.start_room_explicit)
}

@(test)
game_run_options_parse_replay_and_exact_capture_tick :: proc(t: ^testing.T) {
    options, valid, error_argument := parse_game_run_options([]string{
        "--mode", "game",
        "--game-replay", "replays/traversal-dash-smoke.json",
        "--game-capture-tick", "5",
        "--capture-case", "dash-tick",
    })
    testing.expect(t, valid, error_argument)
    testing.expect_value(t, options.replay_path, "replays/traversal-dash-smoke.json")
    testing.expect(t, options.capture_tick_set)
    testing.expect_value(t, options.capture_tick, u64(5))
}

@(test)
game_run_options_reject_non_positive_capture_tick :: proc(t: ^testing.T) {
    _, valid, error_argument := parse_game_run_options([]string{
        "--mode", "game",
        "--game-capture-tick", "0",
    })
    testing.expect(t, !valid)
    testing.expect_value(t, error_argument, "0")
}

@(test)
game_run_options_parse_record_directory :: proc(t: ^testing.T) {
    options, valid, error_argument := parse_game_run_options([]string{
        "--mode", "game",
        "--game-replay", "replays/traversal-dash-smoke.json",
        "--game-record-dir", "artifacts/report/frames",
        "--capture-case", "video-report",
    })
    testing.expect(t, valid, error_argument)
    testing.expect_value(t, options.record_directory, "artifacts/report/frames")
}

@(test)
game_default_cel_style_is_valid_and_keeps_neon_accents :: proc(t: ^testing.T) {
    style := make_game_cel_style()
    defer destroy_cel_style(&style)

    testing.expect_value(t, validate_cel_style(&style), Cel_Style_Error.NONE)
    testing.expect(t, style.rim.enabled, "the game style should preserve cyan rim light")
    testing.expect(t, style.highlight.enabled, "the game style should preserve warm highlights")
    testing.expect_value(t, style.outline.width, 1)
}

game_test_occlusion_assets :: proc() -> Game_Assets {
    assets: Game_Assets
    assets.tree = {
        bounds = {
            min = {-1.2, 0, -0.6},
            max = {1.2, 4.0, 0.6},
        },
        valid = true,
    }
    assets.player = {
        bounds = {
            min = {-0.3, 0, -0.2},
            max = {0.3, 1.7, 0.2},
        },
        valid = true,
    }
    return assets
}

@(test)
game_foreground_tree_uses_pink_visibility_debug_tint :: proc(
    t: ^testing.T,
) {
    state := game_state_init(.TEST_OCCLUSION)
    camera_state: Game_Camera_State
    camera := game_update_camera(&camera_state, &state, {}, GAME_FIXED_DT)
    tree := GAME_OCCLUSION_TEST_TREE
    assets := game_test_occlusion_assets()

    testing.expect_value(t, tree.kind, Game_Decor_Kind.TREE)
    testing.expect_value(
        t,
        game_decor_visibility_tint(&assets, tree, &state, camera),
        tree.tint,
    )

    // Moving through the isolated tree puts it exactly between the player and
    // the fixed test camera. The debug tint exposes that classification.
    state.player.position = {80, 0, -2}
    camera = game_update_camera(&camera_state, &state, {}, GAME_FIXED_DT)
    testing.expect_value(
        t,
        game_decor_visibility_tint(&assets, tree, &state, camera),
        GAME_OCCLUSION_DEBUG_TINT,
    )
}

@(test)
game_occlusion_test_tree_edge_separates_inside_from_outside :: proc(
    t: ^testing.T,
) {
    state := game_state_init(.TEST_OCCLUSION)
    camera_state: Game_Camera_State
    camera := game_update_camera(&camera_state, &state, {}, GAME_FIXED_DT)
    tree := GAME_OCCLUSION_TEST_TREE
    assets := game_test_occlusion_assets()

    // The projected model bound includes the canopy, so this grazing position
    // remains occluded even though it was outside the removed 0.72 m circle.
    state.player.position = {81.25, 0, -2}
    inside := game_decor_occlusion_query(&assets, tree, &state, camera)
    testing.expect(t, inside.depth_valid)
    testing.expect(t, inside.occluded, "the canopy edge should overlap the projected player bound")
    testing.expect(t, inside.overlap.valid)

    state.player.position = {82.25, 0, -2}
    outside := game_decor_occlusion_query(&assets, tree, &state, camera)
    testing.expect(t, outside.depth_valid)
    testing.expect(t, !outside.occluded, "separated projected bounds should remain clear")
    testing.expect(t, !outside.overlap.valid)
}

@(test)
game_occlusion_test_scene_is_not_connected_to_the_authored_route :: proc(
    t: ^testing.T,
) {
    room := game_room(.TEST_OCCLUSION)
    testing.expect_value(t, room.name, "T00 Occlusion Test")
    testing.expect_value(t, room.spawn, rl.Vector3{80, 0, 3})
    testing.expect(t, !room.camera_follow)

    for exit in GAME_EXITS {
        testing.expect(
            t,
            exit.source != .TEST_OCCLUSION && exit.target != .TEST_OCCLUSION,
            "the test scene must remain outside the traversal route",
        )
    }
}
