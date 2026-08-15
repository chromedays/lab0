package tests

// This is an automated handling playtest, not a second movement model. Every
// candidate is fed through game_fixed_update so acceleration, collisions,
// buffered dashes, cooldowns, hazards, and failed landings use production code.

import "core:fmt"
import "core:testing"
import rl "vendor:raylib"

Game_Tuning_Candidate :: struct {
    name:   string,
    tuning: Game_Movement_Tuning,
}

Game_Tuning_Scenario_Result :: struct {
    corner_escape_distance:   f32,
    stop_ticks:               int,
    reverse_ticks:            int,
    repeated_dash_interval:   int,
    repeated_dash_count:      int,
    ravine_cleared:           bool,
    failed_landing_recovered: bool,
}

GAME_TUNING_CANDIDATES := [?]Game_Tuning_Candidate{
    {
        name = "precision",
        tuning = {
            acceleration = 36,
            deceleration = 48,
            dash_distance = 1.50,
            dash_cooldown = 0.32,
        },
    },
    {
        name = "balanced",
        tuning = {
            acceleration = 32,
            deceleration = 44,
            dash_distance = 1.65,
            dash_cooldown = 0.28,
        },
    },
    {
        name = "flow",
        tuning = {
            acceleration = 24,
            deceleration = 32,
            dash_distance = 1.90,
            dash_cooldown = 0.20,
        },
    },
}

game_tuning_test_state :: proc(
    room: Game_Room_ID,
    tuning: Game_Movement_Tuning,
) -> Game_State {
    state := game_state_init(room)
    state.movement_tuning = tuning
    return state
}

game_tuning_finish_dash :: proc(state: ^Game_State) {
    for _ in 0 ..< 60 {
        if state.player.mode == .GROUNDED {
            return
        }
        game_fixed_update(state, {}, GAME_FIXED_DT)
    }
}

game_tuning_corner_escape :: proc(tuning: Game_Movement_Tuning) -> f32 {
    state := game_tuning_test_state(.R02_CENTRAL_RUIN, tuning)
    // Push diagonally into the southwest corner of the first ruin column, then
    // release along its tangent. A collision must never leave the player in a
    // sticky state that prevents a clean escape on the next intent change.
    state.player.position = {33.55, 0, -2.45}
    state.last_safe_position = state.player.position
    for _ in 0 ..< 20 {
        game_fixed_update(&state, {{1, 1}, false}, GAME_FIXED_DT)
    }
    contact_z := state.player.position.z
    for _ in 0 ..< 30 {
        game_fixed_update(&state, {{0, -1}, false}, GAME_FIXED_DT)
    }
    return contact_z - state.player.position.z
}

game_tuning_reverse_ticks :: proc(tuning: Game_Movement_Tuning) -> int {
    state := game_tuning_test_state(.R00_START_FOREST, tuning)
    state.player.position = {0, 0, 3.5}
    state.last_safe_position = state.player.position
    for _ in 0 ..< 30 {
        game_fixed_update(&state, {{1, 0}, false}, GAME_FIXED_DT)
    }
    reverse_target := -GAME_MOVE_SPEED * 0.90
    for tick in 1 ..= 60 {
        game_fixed_update(&state, {{-1, 0}, false}, GAME_FIXED_DT)
        if state.player.velocity.x <= reverse_target {
            return tick
        }
    }
    return 0
}

game_tuning_stop_ticks :: proc(tuning: Game_Movement_Tuning) -> int {
    state := game_tuning_test_state(.R00_START_FOREST, tuning)
    state.player.position = {0, 0, 3.5}
    state.last_safe_position = state.player.position
    for _ in 0 ..< 30 {
        game_fixed_update(&state, {{1, 0}, false}, GAME_FIXED_DT)
    }
    for tick in 1 ..= 60 {
        game_fixed_update(&state, {}, GAME_FIXED_DT)
        if game_vector2_length(state.player.velocity) <= 0.001 {
            return tick
        }
    }
    return 0
}

game_tuning_repeated_dash :: proc(
    tuning: Game_Movement_Tuning,
) -> (interval: int, count: int) {
    state := game_tuning_test_state(.R00_START_FOREST, tuning)
    state.player.position = {0, 0, -2}
    state.last_safe_position = state.player.position
    previous_start := -1

    for tick in 0 ..< 120 {
        direction := rl.Vector2{1, 0}
        if state.player.position.x > 0.8 {
            direction = {-1, 0}
        }
        previous_count := state.dash_count
        game_fixed_update(&state, {direction, true}, GAME_FIXED_DT)
        if state.dash_count != previous_count {
            if previous_start >= 0 && interval == 0 {
                interval = tick - previous_start
            }
            previous_start = tick
        }
    }
    return interval, state.dash_count
}

game_tuning_ravine_clear :: proc(tuning: Game_Movement_Tuning) -> bool {
    state := game_tuning_test_state(.R04_RAVINE_CROSSING, tuning)
    state.player.position = {38, 1.5, -16.65}
    state.player.facing = {0, -1}
    state.last_safe_position = state.player.position
    game_fixed_update(&state, {{0, -1}, true}, GAME_FIXED_DT)
    game_tuning_finish_dash(&state)
    return state.player.position.z < -18.17
}

game_tuning_failed_landing_recovers :: proc(
    tuning: Game_Movement_Tuning,
) -> bool {
    state := game_tuning_test_state(.R04_RAVINE_CROSSING, tuning)
    state.player.position = {38, 1.5, -16.65}
    state.player.facing = {1, -0.5}
    state.last_safe_position = state.player.position
    start := state.player.position
    game_fixed_update(&state, {{1, -0.5}, true}, GAME_FIXED_DT)
    game_tuning_finish_dash(&state)
    return game_vector2_length({
        state.player.position.x - start.x,
        state.player.position.z - start.z,
    }) < 0.0001
}

game_tuning_run_scenarios :: proc(
    tuning: Game_Movement_Tuning,
) -> Game_Tuning_Scenario_Result {
    result: Game_Tuning_Scenario_Result
    result.corner_escape_distance = game_tuning_corner_escape(tuning)
    result.stop_ticks = game_tuning_stop_ticks(tuning)
    result.reverse_ticks = game_tuning_reverse_ticks(tuning)
    result.repeated_dash_interval, result.repeated_dash_count =
        game_tuning_repeated_dash(tuning)
    result.ravine_cleared = game_tuning_ravine_clear(tuning)
    result.failed_landing_recovered = game_tuning_failed_landing_recovers(tuning)
    return result
}

game_tuning_passes_playtest :: proc(result: Game_Tuning_Scenario_Result) -> bool {
    return result.corner_escape_distance >= 1.0 &&
           result.stop_ticks > 0 && result.stop_ticks <= 6 &&
           result.reverse_ticks > 0 && result.reverse_ticks <= 14 &&
           result.repeated_dash_interval >= 15 &&
           result.repeated_dash_interval <= 18 &&
           result.repeated_dash_count >= 6 &&
           result.ravine_cleared &&
           result.failed_landing_recovered
}

@(test)
game_movement_candidates_run_the_same_automated_playtest :: proc(t: ^testing.T) {
    passing_count := 0
    passing_name := ""
    fmt.println("movement tuning playtest: candidate corner-m stop-ticks reverse-ticks dash-gap dash-count ravine failed-landing pass")

    for candidate in GAME_TUNING_CANDIDATES {
        result := game_tuning_run_scenarios(candidate.tuning)
        passed := game_tuning_passes_playtest(result)
        fmt.printf(
            "movement tuning playtest: %-9s %.3f %d %d %d %d %v %v %v\n",
            candidate.name,
            result.corner_escape_distance,
            result.stop_ticks,
            result.reverse_ticks,
            result.repeated_dash_interval,
            result.repeated_dash_count,
            result.ravine_cleared,
            result.failed_landing_recovered,
            passed,
        )
        testing.expectf(
            t,
            result.corner_escape_distance >= 1.0,
            "%s should escape a wall corner, got %.3fm",
            candidate.name,
            result.corner_escape_distance,
        )
        testing.expectf(
            t,
            result.failed_landing_recovered,
            "%s should return exactly to the dash start after a failed landing",
            candidate.name,
        )
        if passed {
            passing_count += 1
            passing_name = candidate.name
        }
    }

    testing.expect_value(t, passing_count, 1)
    testing.expect_value(t, passing_name, "balanced")
}

@(test)
game_default_tuning_matches_the_playtest_winner :: proc(t: ^testing.T) {
    winner := GAME_TUNING_CANDIDATES[1].tuning
    testing.expect_value(t, game_default_movement_tuning(), winner)
    testing.expect(
        t,
        game_tuning_passes_playtest(game_tuning_run_scenarios(winner)),
        "the production defaults must keep passing the candidate comparison",
    )
}
