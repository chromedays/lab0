package main

import "core:math"
import "core:testing"
import rl "vendor:raylib"

@(test)
game_pixel_snap_test_moves_fixed_subjects_one_pixel_every_four_ticks :: proc(
    t: ^testing.T,
) {
    state := game_state_init(.TEST_PIXEL_SNAP)
    player_start := state.player.position
    zombie_index := GAME_ZOMBIE_COUNT - 1
    testing.expect_value(
        t,
        GAME_ZOMBIE_SPAWNS[zombie_index].room,
        Game_Room_ID.TEST_PIXEL_SNAP,
    )
    zombie_start := state.zombies[zombie_index].position

    for _ in 0 ..< 4 {
        game_fixed_update(&state, Game_Input{{1, 0}, true}, GAME_FIXED_DT)
    }

    one_pixel := GAME_CAMERA_FOVY / f32(GAME_PIXEL_HEIGHT)
    testing.expectf(
        t,
        math.abs(state.player.position.x - (player_start.x + one_pixel)) < 0.00001,
        "player should move one render pixel in four ticks, got %.6f",
        state.player.position.x - player_start.x,
    )
    testing.expectf(
        t,
        math.abs(state.zombies[zombie_index].position.x -
                 (zombie_start.x - one_pixel)) < 0.00001,
        "zombie should move one render pixel in four ticks, got %.6f",
        state.zombies[zombie_index].position.x - zombie_start.x,
    )
    testing.expect_value(t, state.player.facing, rl.Vector2{1, 0})
    testing.expect_value(t, state.player.mode, Game_Player_Mode.GROUNDED)
    testing.expect_value(t, state.dash_count, 0)
    testing.expect_value(t, state.zombies[zombie_index].facing, rl.Vector2{-1, 0})
    testing.expect_value(t, state.zombies[zombie_index].mode, Game_Zombie_Mode.SHAMBLING)
}

game_test_finish_transition :: proc(
    t: ^testing.T,
    state: ^Game_State,
    crossing: rl.Vector3,
    expected_room: Game_Room_ID,
) {
    state.player.exit_reentry_lock = 0
    state.player.position = crossing
    started := game_try_start_room_transition(state, crossing)
    testing.expect(t, started, "the authored route crossing should start a transition")
    for state.player.mode == .ROOM_TRANSITION {
        game_fixed_update(state, {}, GAME_FIXED_DT)
    }
    testing.expect_value(t, state.current_room, expected_room)
}

@(test)
game_diagonal_input_is_normalized :: proc(t: ^testing.T) {
    normalized := game_normalize_input({1, 1})
    testing.expectf(
        t,
        math.abs(game_vector_length(normalized) - 1) < 0.0001,
        "diagonal input should have unit length, got %.6f",
        game_vector_length(normalized),
    )
    testing.expectf(
        t,
        math.abs(normalized.x - normalized.y) < 0.0001,
        "normalized diagonal should preserve direction",
    )
}

@(test)
game_dash_has_a_fixed_frame_rate_independent_distance :: proc(t: ^testing.T) {
    simulate_dash := proc(dt: f32) -> rl.Vector3 {
        state := game_state_init()
        game_fixed_update(&state, {{1, 0}, true}, dt)
        for state.player.mode == .DASHING {
            game_fixed_update(&state, {}, dt)
        }
        return state.player.position
    }

    position_60hz := simulate_dash(1.0 / 60.0)
    position_120hz := simulate_dash(1.0 / 120.0)
    testing.expectf(
        t,
        math.abs(position_60hz.x - position_120hz.x) < 0.0001,
        "dash distance should not depend on tick subdivision: %.6f vs %.6f",
        position_60hz.x,
        position_120hz.x,
    )
    testing.expectf(
        t,
        math.abs((position_60hz.x - 0) - GAME_DASH_DISTANCE) < 0.0001,
        "dash should travel the configured distance, got %.6f",
        position_60hz.x,
    )
}

@(test)
game_room_exit_starts_and_finishes_a_transition :: proc(t: ^testing.T) {
    state := game_state_init()
    state.player.position = {7.84, 0, 0}
    state.last_safe_position = state.player.position

    game_fixed_update(&state, {{1, 0}, false}, GAME_FIXED_DT)
    testing.expect_value(t, state.player.mode, Game_Player_Mode.ROOM_TRANSITION)
    testing.expect_value(
        t,
        state.player.transition_to_room,
        Game_Room_ID.R01_FOREST_PASSAGE,
    )

    for state.player.mode == .ROOM_TRANSITION {
        game_fixed_update(&state, {}, GAME_FIXED_DT)
    }
    testing.expect_value(t, state.current_room, Game_Room_ID.R01_FOREST_PASSAGE)
    testing.expect_value(t, state.player.mode, Game_Player_Mode.GROUNDED)
    testing.expectf(
        t,
        math.abs(state.player.position.x - 9.8) < 0.001,
        "transition should finish at the target entrance",
    )
}

@(test)
game_ravine_blocks_walking_but_accepts_a_full_dash :: proc(t: ^testing.T) {
    walking := game_state_init(.R04_RAVINE_CROSSING)
    walking.player.position = {38, 1.5, -16.65}
    walking.last_safe_position = walking.player.position
    for _ in 0 ..< 45 {
        game_fixed_update(&walking, {{0, -1}, false}, GAME_FIXED_DT)
    }
    testing.expectf(
        t,
        walking.player.position.z > -17.10,
        "walking should stop before the ravine, got z %.4f",
        walking.player.position.z,
    )

    dashing := game_state_init(.R04_RAVINE_CROSSING)
    dashing.player.position = {38, 1.5, -16.65}
    dashing.player.facing = {0, -1}
    dashing.last_safe_position = dashing.player.position
    game_fixed_update(&dashing, {{0, -1}, true}, GAME_FIXED_DT)
    for dashing.player.mode == .DASHING {
        game_fixed_update(&dashing, {}, GAME_FIXED_DT)
    }
    testing.expectf(
        t,
        dashing.player.position.z < -18.10,
        "a full dash should clear the ravine, got z %.4f",
        dashing.player.position.z,
    )
}

@(test)
game_overlook_and_return_complete_the_route :: proc(t: ^testing.T) {
    state := game_state_init(.R05_OVERLOOK)
    state.player.position = GAME_OVERLOOK_POSITION
    game_fixed_update(&state, {}, GAME_FIXED_DT)
    testing.expect(t, state.overlook_reached, "the overlook beacon should mark the objective")
    testing.expect(t, !state.completed, "the objective alone should not complete the route")

    state.current_room = .R00_START_FOREST
    state.player.position = game_room(.R00_START_FOREST).spawn
    game_fixed_update(&state, {}, GAME_FIXED_DT)
    testing.expect(t, state.completed, "returning to R00 after the overlook should complete the route")
}

@(test)
game_lower_trail_cannot_reverse_the_one_way_drop :: proc(t: ^testing.T) {
    state := game_state_init(.R06_LOWER_TRAIL)
    state.player.position = {9.60, 0, -20.5}
    for _ in 0 ..< 30 {
        game_fixed_update(&state, {{1, 0}, false}, GAME_FIXED_DT)
    }
    testing.expect_value(t, state.current_room, Game_Room_ID.R06_LOWER_TRAIL)
    testing.expect_value(t, state.player.mode, Game_Player_Mode.GROUNDED)
    testing.expectf(
        t,
        state.player.position.x <= 10 - GAME_PLAYER_RADIUS + 0.0001,
        "the one-way ledge should clamp reverse movement",
    )
}

@(test)
game_authored_main_route_connects_overlook_back_to_start :: proc(t: ^testing.T) {
    state := game_state_init()
    game_test_finish_transition(
        t,
        &state,
        {7.9, 0, 0},
        .R01_FOREST_PASSAGE,
    )
    game_test_finish_transition(
        t,
        &state,
        {26.9, 0, 0},
        .R02_CENTRAL_RUIN,
    )
    game_test_finish_transition(
        t,
        &state,
        {38, 0, -7.9},
        .R04_RAVINE_CROSSING,
    )
    game_test_finish_transition(
        t,
        &state,
        {29.1, 1.5, -20.5},
        .R05_OVERLOOK,
    )

    state.player.position = GAME_OVERLOOK_POSITION
    game_update_progress(&state)
    testing.expect(t, state.overlook_reached, "the authored route should reach its objective")

    game_test_finish_transition(
        t,
        &state,
        {11.1, 1.5, -20.5},
        .R06_LOWER_TRAIL,
    )
    game_test_finish_transition(
        t,
        &state,
        {0, 0, -6.1},
        .R00_START_FOREST,
    )
    testing.expect(t, state.completed, "the authored loop should complete after returning to R00")
}

@(test)
game_zombies_spawn_in_valid_patrol_space :: proc(t: ^testing.T) {
    state := game_state_init(.R03_WIDE_GROVE)
    for spawn, zombie_index in GAME_ZOMBIE_SPAWNS {
        zombie := state.zombies[zombie_index]
        testing.expect_value(t, zombie.position, spawn.position)
        testing.expect_value(t, zombie.mode, Game_Zombie_Mode.SHAMBLING)
        testing.expectf(
            t,
            game_position_inside_room_radius(spawn.room, zombie.position, GAME_ZOMBIE_RADIUS),
            "zombie %d should start inside %s",
            zombie_index,
            game_room(spawn.room).name,
        )
        testing.expectf(
            t,
            !game_zombie_position_blocked(spawn.room, zombie.position),
            "zombie %d should not start in geometry or a hazard",
            zombie_index,
        )
    }
}

@(test)
game_zombie_crowd_queues_through_a_tight_lane_without_overlap :: proc(
    t: ^testing.T,
) {
    state := game_state_init(.R03_WIDE_GROVE)
    target := rl.Vector3{62.0, 0, -2.20}
    lane_start_x: f32 = 50.4
    lane_spacing: f32 = 0.72
    first_zombie := 1
    last_zombie := 6
    for zombie_index in first_zombie ..= last_zombie {
        lane_index := zombie_index - first_zombie
        state.zombies[zombie_index].position = {
            lane_start_x + f32(lane_index) * lane_spacing,
            0,
            -2.20,
        }
        state.zombies[zombie_index].facing = {1, 0}
    }
    rear_start_x := state.zombies[first_zombie].position.x
    front_start_x := state.zombies[last_zombie].position.x

    for _ in 0 ..< 120 {
        for zombie_index in first_zombie ..= last_zombie {
            game_zombie_walk_towards(
                &state,
                zombie_index,
                target,
                GAME_ZOMBIE_CHASE_SPEED,
                GAME_FIXED_DT,
            )
        }
        for zombie_index in first_zombie ..= last_zombie {
            for other_index in zombie_index + 1 ..= last_zombie {
                delta := rl.Vector2{
                    state.zombies[zombie_index].position.x -
                        state.zombies[other_index].position.x,
                    state.zombies[zombie_index].position.z -
                        state.zombies[other_index].position.z,
                }
                testing.expectf(
                    t,
                    game_vector_length(delta) + 0.0001 >= GAME_ZOMBIE_SEPARATION,
                    "zombies %d and %d overlapped in the tight lane",
                    zombie_index,
                    other_index,
                )
            }
        }
    }

    testing.expectf(
        t,
        state.zombies[first_zombie].position.x > rear_start_x + 2.0,
        "the back of the queue should keep advancing, got %.3f",
        state.zombies[first_zombie].position.x,
    )
    testing.expectf(
        t,
        state.zombies[last_zombie].position.x > front_start_x + 2.0,
        "the queue leader should clear the bottleneck, got %.3f",
        state.zombies[last_zombie].position.x,
    )
}

@(test)
game_zombie_disengages_and_returns_to_its_patrol_lane :: proc(t: ^testing.T) {
    state := game_state_init(.R02_CENTRAL_RUIN)
    zombie_index := 0
    zombie := &state.zombies[zombie_index]
    zombie.position = {37.0, 0, 6.1}
    zombie.facing = {-1, 0}
    zombie.mode = .CHASING
    zombie.alert_memory = 0

    game_fixed_update(&state, {}, GAME_FIXED_DT)
    testing.expect_value(t, zombie.mode, Game_Zombie_Mode.RETURNING)
    testing.expectf(
        t,
        math.abs(zombie.return_target.x - 41.8) < 0.0001 &&
            math.abs(zombie.return_target.z - 6.1) < 0.0001,
        "R02 zombie should return to the nearest point on its patrol lane",
    )
    testing.expectf(
        t,
        zombie.reengage_delay > 0,
        "returning should have a short re-engagement delay",
    )

    returned := false
    for _ in 0 ..< 240 {
        game_fixed_update(&state, {}, GAME_FIXED_DT)
        if zombie.mode == .SHAMBLING {
            returned = true
            break
        }
    }
    testing.expect(t, returned, "R02 zombie should regain its patrol lane")
    anchor := game_zombie_patrol_anchor(zombie_index, zombie.position)
    anchor_delta := rl.Vector2{
        zombie.position.x - anchor.x,
        zombie.position.z - anchor.z,
    }
    testing.expectf(
        t,
        game_vector_length(anchor_delta) <= GAME_ZOMBIE_RETURN_RADIUS + 0.001,
        "returned zombie should be on its patrol segment",
    )
}

@(test)
game_zombie_sight_starts_a_chase_but_obstacles_block_it :: proc(t: ^testing.T) {
    state := game_state_init(.R03_WIDE_GROVE)
    zombie_index := 1
    game_fixed_update(&state, {}, GAME_FIXED_DT)
    testing.expect_value(
        t,
        state.zombies[zombie_index].mode,
        Game_Zombie_Mode.CHASING,
    )

    state.player.position = {61, 0, 0}
    state.zombies[zombie_index].position = {55, 0, 0}
    state.zombies[zombie_index].facing = {1, 0}
    state.zombies[zombie_index].mode = .SHAMBLING
    state.zombies[zombie_index].alert_memory = 0
    testing.expect(
        t,
        !game_zombie_can_see_player(&state, &state.zombies[zombie_index]),
        "the wide-grove trunk should block zombie sight",
    )
}

@(test)
game_zombie_hears_a_dash_beyond_its_sight_radius :: proc(t: ^testing.T) {
    state := game_state_init(.R02_CENTRAL_RUIN)
    zombie_index := 0
    state.player.position = {35.8, 0, 6.1}
    state.player.facing = {0, 1}
    game_fixed_update(&state, {{0, 1}, true}, GAME_FIXED_DT)
    testing.expect_value(
        t,
        state.zombies[zombie_index].mode,
        Game_Zombie_Mode.CHASING,
    )
    testing.expectf(
        t,
        state.zombies[zombie_index].alert_memory > 0,
        "a heard dash should refresh zombie memory",
    )
}

@(test)
game_zombie_lunge_resets_the_room_after_a_hit :: proc(t: ^testing.T) {
    state := game_state_init(.R03_WIDE_GROVE)
    zombie_index := 1
    state.player.position = {52, 0, -4.6}
    zombie := &state.zombies[zombie_index]
    zombie.mode = .CHASING
    zombie.position = {53.2, 0, -4.6}
    zombie.facing = {-1, 0}
    zombie.last_known = state.player.position
    zombie.alert_memory = GAME_ZOMBIE_MEMORY

    game_fixed_update(&state, {}, GAME_FIXED_DT)
    testing.expect_value(t, zombie.mode, Game_Zombie_Mode.WINDUP)
    for _ in 0 ..< 90 {
        if state.zombie_hits > 0 { break }
        game_fixed_update(&state, {}, GAME_FIXED_DT)
    }
    testing.expect_value(t, state.zombie_hits, 1)
    testing.expect_value(t, state.reset_count, 1)
    testing.expect_value(t, state.player.position, game_room(.R03_WIDE_GROVE).spawn)
    testing.expect_value(t, state.zombies[zombie_index].position, GAME_ZOMBIE_SPAWNS[zombie_index].position)
    testing.expectf(
        t,
        state.hit_feedback > 0,
        "a zombie hit should leave visible feedback after the room reset",
    )
}

@(test)
game_dash_can_evade_a_committed_zombie_lunge :: proc(t: ^testing.T) {
    state := game_state_init(.R03_WIDE_GROVE)
    zombie_index := 1
    state.player.position = {52, 0, -4.6}
    state.player.facing = {0, 1}
    zombie := &state.zombies[zombie_index]
    zombie.mode = .WINDUP
    zombie.mode_elapsed = GAME_ZOMBIE_WINDUP_TIME - GAME_FIXED_DT
    zombie.position = {53.2, 0, -4.6}
    zombie.facing = {-1, 0}
    zombie.attack_direction = {-1, 0}
    zombie.last_known = state.player.position
    zombie.alert_memory = GAME_ZOMBIE_MEMORY

    game_fixed_update(&state, {{0, 1}, true}, GAME_FIXED_DT)
    for _ in 0 ..< 24 {
        game_fixed_update(&state, {}, GAME_FIXED_DT)
    }
    testing.expect_value(t, state.zombie_hits, 0)
    testing.expectf(
        t,
        state.player.position.z > -3.2,
        "the perpendicular dash should clear the lunge lane, got z %.3f",
        state.player.position.z,
    )
}

@(test)
game_step_dust_uses_actual_distance_travelled :: proc(t: ^testing.T) {
    state := game_state_init()
    for _ in 0 ..< 20 {
        game_fixed_update(&state, {{1, 0}, false}, GAME_FIXED_DT)
    }
    testing.expectf(
        t,
        game_particles_active_count(&state.particle_system) > 0,
        "ground movement should leave a sparse active dust particle",
    )
    testing.expectf(
        t,
        state.particle_system.spawn_cursor <= 2,
        "short movement should remain sparse, spawned %d particles",
        state.particle_system.spawn_cursor,
    )
}

@(test)
game_dash_dust_starts_with_a_small_fixed_burst :: proc(t: ^testing.T) {
    state := game_state_init()
    game_fixed_update(&state, {{1, 0}, true}, GAME_FIXED_DT)
    testing.expect_value(t, game_particles_active_count(&state.particle_system), 3)

    for _ in 0 ..< 3 {
        game_fixed_update(&state, {}, GAME_FIXED_DT)
    }
    testing.expectf(
        t,
        game_particles_active_count(&state.particle_system) > 3,
        "dash travel should add restrained distance-based trail particles",
    )
}

@(test)
game_one_way_drop_emits_landing_dust :: proc(t: ^testing.T) {
    state := game_state_init(.R05_OVERLOOK)
    state.player.position = {11.1, 1.5, -20.5}
    state.player.exit_reentry_lock = 0
    started := game_try_start_room_transition(&state, state.player.position)
    testing.expect(t, started, "the one-way drop should start a room transition")

    for state.player.mode == .ROOM_TRANSITION {
        game_fixed_update(&state, {}, GAME_FIXED_DT)
    }
    testing.expect_value(t, state.current_room, Game_Room_ID.R06_LOWER_TRAIL)
    testing.expect_value(t, game_particles_active_count(&state.particle_system), 6)
}

@(test)
game_dust_is_deterministic_for_matching_fixed_input :: proc(t: ^testing.T) {
    first := game_state_init()
    second := game_state_init()
    for tick in 0 ..< 90 {
        input := Game_Input{{1, 0}, tick == 28}
        game_fixed_update(&first, input, GAME_FIXED_DT)
        game_fixed_update(&second, input, GAME_FIXED_DT)
    }

    testing.expect_value(
        t,
        first.particle_system.random_state,
        second.particle_system.random_state,
    )
    testing.expect_value(
        t,
        first.particle_system.spawn_cursor,
        second.particle_system.spawn_cursor,
    )
    testing.expect_value(
        t,
        first.particle_system.particles,
        second.particle_system.particles,
    )
}
