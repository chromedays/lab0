package main

import "core:math"
import "core:testing"
import rl "vendor:raylib"

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
        math.abs((position_60hz.x - 0) - GAME_DASH_SPEED * GAME_DASH_DURATION) < 0.0001,
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
    testing.expect_value(t, state.player.position, game_room(.R03_WIDE_GROVE).spawn)
    testing.expect_value(t, state.zombies[zombie_index].position, GAME_ZOMBIE_SPAWNS[zombie_index].position)
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
