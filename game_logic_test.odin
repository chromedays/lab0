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
