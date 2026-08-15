package main

import "core:math"
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
game_run_options_accept_game_help :: proc(t: ^testing.T) {
    options, valid, error_argument := parse_game_run_options([]string{
        "--mode", "game",
        "--game-help",
    })
    testing.expect(t, valid, error_argument)
    testing.expect(t, options.help_requested)
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
game_run_options_accept_pixel_snap_test_scene :: proc(t: ^testing.T) {
    options, valid, error_argument := parse_game_run_options([]string{
        "--mode", "game",
        "--game-room", "pixel-snap-test",
    })
    testing.expect(t, valid, error_argument)
    testing.expect_value(t, options.start_room, Game_Room_ID.TEST_PIXEL_SNAP)
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
game_foreground_tree_uses_pink_visibility_debug_tint_only_in_t00 :: proc(
    t: ^testing.T,
) {
    state := game_state_init(.TEST_OCCLUSION)
    camera_state: Game_Camera_State
    camera := game_update_camera(&camera_state, &state, {}, GAME_FIXED_DT)
    tree := GAME_OCCLUSION_TEST_TREE
    assets := game_test_occlusion_assets()

    testing.expect_value(t, tree.kind, Game_Decor_Kind.TREE)
    clear_effect := game_decor_visibility_effect(
        state.current_room,
        game_decor_occludes_player(&assets, tree, &state, camera),
    )
    testing.expect_value(
        t,
        game_decor_visibility_tint(tree, clear_effect),
        tree.tint,
    )

    // Moving through the isolated tree puts it exactly between the player and
    // the fixed test camera. The debug tint exposes that classification.
    state.player.position = {80, 0, -2}
    camera = game_update_camera(&camera_state, &state, {}, GAME_FIXED_DT)
    debug_effect := game_decor_visibility_effect(
        state.current_room,
        game_decor_occludes_player(&assets, tree, &state, camera),
    )
    testing.expect_value(t, debug_effect, Game_Decor_Visibility_Effect.DEBUG_TINT)
    testing.expect_value(
        t,
        game_decor_visibility_tint(tree, debug_effect),
        GAME_OCCLUSION_DEBUG_TINT,
    )
}

@(test)
game_regular_room_occluder_keeps_its_tint_and_uses_35_percent_dither :: proc(
    t: ^testing.T,
) {
    tree := GAME_OCCLUSION_TEST_TREE
    effect := game_decor_visibility_effect(.R00_START_FOREST, true)

    testing.expect_value(t, effect, Game_Decor_Visibility_Effect.DITHERED)
    testing.expect_value(t, game_decor_visibility_tint(tree, effect), tree.tint)
    testing.expect_value(
        t,
        game_decor_visibility_amount(effect),
        f32(0.35),
    )
}

@(test)
game_occlusion_dither_pattern_keeps_exactly_seven_of_twenty_cells :: proc(
    t: ^testing.T,
) {
    visible_cells := 0
    visible_cell_limit := int(math.floor(
        f64(GAME_OCCLUSION_DITHER_VISIBILITY * 20 + 0.5),
    ))
    for y in 0 ..< 5 {
        for x in 0 ..< 4 {
            linear_index := y * 4 + x
            ordered_rank := (linear_index * 13) % 20
            if ordered_rank < visible_cell_limit {
                visible_cells += 1
            }
        }
    }
    testing.expect_value(t, visible_cells, 7)
}

game_test_edge_occlusion_query :: proc(decor_min_x: f32) -> Game_Decor_Occlusion_Query {
    player_bounds := Game_Screen_Bounds{{0, 0}, {10, 10}, true}
    decor_bounds := Game_Screen_Bounds{{decor_min_x, 0}, {decor_min_x + 10, 10}, true}
    overlap := game_screen_bounds_intersection(player_bounds, decor_bounds)
    return {
        player_bounds = player_bounds,
        decor_bounds = decor_bounds,
        overlap = overlap,
        depth_valid = true,
        occluded = overlap.valid,
    }
}

@(test)
game_regular_room_occlusion_edge_hysteresis_rejects_jitter :: proc(t: ^testing.T) {
    flags := [1]bool{false}
    queries := [1]Game_Decor_Occlusion_Query{
        game_test_edge_occlusion_query(9.0),
    }

    // A one-pixel graze is not enough to enter the faded state.
    game_update_decor_visibility_flags(flags[:], queries[:], false)
    testing.expect(t, !flags[0])

    // Three pixels enters. Subsequent samples alternate between a sub-pixel
    // overlap and a sub-pixel gap, but must not flicker back to visible.
    queries[0] = game_test_edge_occlusion_query(7.0)
    game_update_decor_visibility_flags(flags[:], queries[:], false)
    testing.expect(t, flags[0])
    edge_jitter := [?]f32{9.6, 10.4, 9.8, 10.8, 9.4}
    for decor_min_x in edge_jitter {
        queries[0] = game_test_edge_occlusion_query(decor_min_x)
        game_update_decor_visibility_flags(flags[:], queries[:], false)
        testing.expect(t, flags[0], "edge jitter must retain the dither state")
    }

    queries[0] = game_test_edge_occlusion_query(12.1)
    game_update_decor_visibility_flags(flags[:], queries[:], false)
    testing.expect(t, !flags[0], "a gap beyond the exit margin must clear the fade")
}

@(test)
game_multiple_occluders_update_independently :: proc(t: ^testing.T) {
    flags := [3]bool{}
    queries := [3]Game_Decor_Occlusion_Query{
        game_test_edge_occlusion_query(7.0),
        game_test_edge_occlusion_query(13.0),
        game_test_edge_occlusion_query(6.0),
    }

    game_update_decor_visibility_flags(flags[:], queries[:], false)
    testing.expect_value(t, flags, [3]bool{true, false, true})

    // The first exits, the second enters, and the third remains held inside
    // the hysteresis margin. No object's update may overwrite another slot.
    queries = {
        game_test_edge_occlusion_query(13.0),
        game_test_edge_occlusion_query(8.0),
        game_test_edge_occlusion_query(10.5),
    }
    game_update_decor_visibility_flags(flags[:], queries[:], false)
    testing.expect_value(t, flags, [3]bool{false, true, true})
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

@(test)
game_pixel_snap_test_scene_is_fixed_camera_and_route_isolated :: proc(
    t: ^testing.T,
) {
    room := game_room(.TEST_PIXEL_SNAP)
    testing.expect_value(t, room.name, "T01 Pixel Snap Test")
    testing.expect_value(t, room.spawn, rl.Vector3{-6, 0, 31.5})
    testing.expect(t, !room.camera_follow)

    zombie_count := 0
    for spawn in GAME_ZOMBIE_SPAWNS {
        if spawn.room == .TEST_PIXEL_SNAP {
            zombie_count += 1
        }
    }
    testing.expect_value(t, zombie_count, 1)

    for exit in GAME_EXITS {
        testing.expect(
            t,
            exit.source != .TEST_PIXEL_SNAP && exit.target != .TEST_PIXEL_SNAP,
            "the pixel-snap test scene must remain outside the traversal route",
        )
    }
}

@(test)
game_entity_pixel_snap_offset_quantizes_camera_plane_translation :: proc(
    t: ^testing.T,
) {
    state := game_state_init(.TEST_PIXEL_SNAP)
    camera_state: Game_Camera_State
    camera := game_update_camera(&camera_state, &state, {}, GAME_FIXED_DT)
    game_fixed_update(&state, Game_Input{{1, 0}, false}, GAME_FIXED_DT)

    player_offset := game_pixel_snap_offset(state.player.position, camera)
    zombie_index := GAME_ZOMBIE_COUNT - 1
    zombie_offset := game_pixel_snap_offset(
        state.zombies[zombie_index].position,
        camera,
    )
    right := rl.GetCameraRight(&camera)
    quarter_pixel := GAME_CAMERA_FOVY / f32(GAME_PIXEL_HEIGHT) / 4

    testing.expectf(
        t,
        math.abs(
            rl.Vector3DotProduct(player_offset.world, right) + quarter_pixel,
        ) < 0.00001,
        "player render offset should cancel its first quarter-pixel step",
    )
    testing.expectf(
        t,
        math.abs(
            rl.Vector3DotProduct(zombie_offset.world, right) - quarter_pixel,
        ) < 0.00001,
        "zombie render offset should cancel its first negative quarter-pixel step",
    )
    testing.expectf(
        t,
        math.abs(player_offset.ndc.x + 0.5 / f32(GAME_PIXEL_WIDTH)) < 0.00001,
        "player NDC offset should be one negative quarter logical pixel",
    )
    testing.expectf(
        t,
        math.abs(zombie_offset.ndc.x - 0.5 / f32(GAME_PIXEL_WIDTH)) < 0.00001,
        "zombie NDC offset should be one positive quarter logical pixel",
    )
}
