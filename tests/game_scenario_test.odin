package tests

// These helpers are a tiny headless game driver: they express player intent,
// feed the real fixed update, and retain every input for deterministic replay.

import "core:testing"
import rl "vendor:raylib"

Game_Test_Driver :: struct {
    state:  Game_State,
    inputs: [dynamic]Game_Input,
}

game_test_driver_init :: proc() -> Game_Test_Driver {
    return {state = game_state_init()}
}

game_test_driver_destroy :: proc(driver: ^Game_Test_Driver) {
    delete(driver.inputs)
    driver^ = {}
}

game_test_driver_step :: proc(driver: ^Game_Test_Driver, input: Game_Input) {
    append(&driver.inputs, input)
    game_fixed_update(&driver.state, input, GAME_FIXED_DT)
}

game_test_drive_to :: proc(
    driver: ^Game_Test_Driver,
    target: rl.Vector2,
    max_ticks: int = 900,
) -> bool {
    for _ in 0 ..< max_ticks {
        if driver.state.player.mode == .ROOM_TRANSITION {
            game_test_driver_step(driver, {})
            continue
        }
        delta := target - rl.Vector2{
            driver.state.player.position.x,
            driver.state.player.position.z,
        }
        if game_vector_length(delta) < 0.04 {
            return true
        }
        game_test_driver_step(driver, {move = game_normalize_input(delta)})
    }
    return false
}

game_test_drive_until_room :: proc(
    driver: ^Game_Test_Driver,
    target: rl.Vector2,
    expected_room: Game_Room_ID,
    max_ticks: int = 900,
) -> bool {
    for _ in 0 ..< max_ticks {
        if driver.state.current_room == expected_room &&
           driver.state.player.mode == .GROUNDED {
            return true
        }
        input: Game_Input
        if driver.state.player.mode == .GROUNDED {
            delta := target - rl.Vector2{
                driver.state.player.position.x,
                driver.state.player.position.z,
            }
            input.move = game_normalize_input(delta)
        }
        game_test_driver_step(driver, input)
    }
    return false
}

game_test_dash_and_finish :: proc(
    driver: ^Game_Test_Driver,
    direction: rl.Vector2,
) {
    game_test_driver_step(driver, {direction, true})
    for driver.state.player.mode != .GROUNDED {
        game_test_driver_step(driver, {})
    }
}

game_test_expect_drive :: proc(
    t: ^testing.T,
    driver: ^Game_Test_Driver,
    target: rl.Vector2,
    label: string,
) -> bool {
    reached := game_test_drive_to(driver, target)
    testing.expectf(
        t,
        reached,
        "%s timed out in %s at (%.3f, %.3f)",
        label,
        game_room(driver.state.current_room).name,
        driver.state.player.position.x,
        driver.state.player.position.z,
    )
    return reached
}

game_test_expect_room :: proc(
    t: ^testing.T,
    driver: ^Game_Test_Driver,
    target: rl.Vector2,
    expected_room: Game_Room_ID,
    label: string,
) -> bool {
    reached := game_test_drive_until_room(driver, target, expected_room)
    testing.expectf(
        t,
        reached,
        "%s timed out in %s at (%.3f, %.3f)",
        label,
        game_room(driver.state.current_room).name,
        driver.state.player.position.x,
        driver.state.player.position.z,
    )
    return reached
}

// game_test_run_authored_route uses no teleports. It is the executable version
// of the prototype route and is shared by scenario and replay assertions.
game_test_run_authored_route :: proc(
    t: ^testing.T,
    driver: ^Game_Test_Driver,
) -> bool {
    if !game_test_expect_drive(t, driver, {6.5, 0}, "R00 east approach") { return false }
    if !game_test_expect_room(t, driver, {8.2, 0}, .R01_FOREST_PASSAGE, "R00 to R01") { return false }
    if !game_test_expect_room(t, driver, {27.2, 0}, .R02_CENTRAL_RUIN, "R01 to R02") { return false }

    // This waypoint goes above the central ruin's first blocking column.
    if !game_test_expect_drive(t, driver, {36.5, 0.2}, "R02 ruin approach") { return false }
    if !game_test_expect_drive(t, driver, {38, -6.4}, "R02 north exit approach") { return false }
    if !game_test_expect_room(t, driver, {38, -8.2}, .R04_RAVINE_CROSSING, "R02 to R04") { return false }

    if !game_test_expect_drive(t, driver, {38, -16.65}, "ravine lip") { return false }
    game_test_dash_and_finish(driver, {0, -1})
    testing.expectf(
        t,
        driver.state.player.position.z < -18.10,
        "route dash should clear the ravine, got z %.3f",
        driver.state.player.position.z,
    )
    if driver.state.player.position.z >= -18.10 { return false }

    if !game_test_expect_drive(t, driver, {36.0, -20.0}, "R04 west turn") { return false }
    if !game_test_expect_room(t, driver, {28.8, -20.5}, .R05_OVERLOOK, "R04 to R05") { return false }
    if !game_test_expect_drive(t, driver, {18, -18}, "overlook beacon") { return false }
    testing.expect(t, driver.state.overlook_reached, "walking onto the beacon should set progress")
    if !driver.state.overlook_reached { return false }

    if !game_test_expect_drive(t, driver, {12.0, -20.5}, "R05 drop approach") { return false }
    if !game_test_expect_room(t, driver, {10.8, -20.5}, .R06_LOWER_TRAIL, "R05 one-way drop") { return false }

    // Stay east of the lower-trail obstacle until it is safely behind us.
    if !game_test_expect_drive(t, driver, {7.0, -12.0}, "R06 upper trail") { return false }
    if !game_test_expect_drive(t, driver, {7.0, -8.0}, "R06 obstacle bypass") { return false }
    if !game_test_expect_drive(t, driver, {0, -7.0}, "R06 south exit approach") { return false }
    if !game_test_expect_room(t, driver, {0, -5.8}, .R00_START_FOREST, "R06 to R00") { return false }
    testing.expect(t, driver.state.completed, "the fully walked authored route should complete")
    return driver.state.completed
}

@(test)
game_headless_scenario_walks_the_complete_authored_route :: proc(t: ^testing.T) {
    driver := game_test_driver_init()
    defer game_test_driver_destroy(&driver)
    completed := game_test_run_authored_route(t, &driver)
    testing.expect(t, completed, "the scenario driver should reach its final checkpoint")
    testing.expectf(t, len(driver.inputs) > 0, "the scenario should record replayable inputs")
}

@(test)
game_recorded_inputs_reproduce_the_exact_final_state :: proc(t: ^testing.T) {
    original := game_test_driver_init()
    defer game_test_driver_destroy(&original)
    if !game_test_run_authored_route(t, &original) { return }

    replayed := game_state_init()
    for input in original.inputs {
        game_fixed_update(&replayed, input, GAME_FIXED_DT)
    }
    testing.expect_value(t, replayed, original.state)
}

game_test_xorshift32 :: proc(seed: ^u32) -> u32 {
    seed^ = seed^ ~ (seed^ << 13)
    seed^ = seed^ ~ (seed^ >> 17)
    seed^ = seed^ ~ (seed^ << 5)
    return seed^
}

@(test)
game_fixed_seed_random_inputs_preserve_simulation_invariants :: proc(t: ^testing.T) {
    seed := u32(0x5eed_c0de)
    state := game_state_init()
    directions := [?]rl.Vector2{
        {}, {1, 0}, {-1, 0}, {0, 1}, {0, -1},
        {1, 1}, {1, -1}, {-1, 1}, {-1, -1},
    }

    for tick in 0 ..< 10_000 {
        if tick > 0 && tick % 2_000 == 0 {
            room_index := (tick / 2_000) % len(GAME_ROOMS)
            state = game_state_init(Game_Room_ID(room_index))
        }
        word := game_test_xorshift32(&seed)
        direction := directions[int(word % u32(len(directions)))]
        dash := ((word >> 8) & 31) == 0
        game_fixed_update(&state, {direction, dash}, GAME_FIXED_DT)

        position := state.player.position
        finite := cel_f32_is_finite(position.x) &&
                  cel_f32_is_finite(position.y) &&
                  cel_f32_is_finite(position.z) &&
                  cel_f32_is_finite(state.player.velocity.x) &&
                  cel_f32_is_finite(state.player.velocity.y)
        testing.expectf(t, finite, "seed 0x%08x produced non-finite state at tick %d", seed, tick)
        testing.expectf(t, state.player.dash_cooldown >= 0, "negative dash cooldown at tick %d", tick)
        testing.expectf(t, state.player.dash_buffer >= 0, "negative dash buffer at tick %d", tick)
        testing.expectf(t, state.player.exit_reentry_lock >= 0, "negative exit lock at tick %d", tick)
        for spawn, zombie_index in GAME_ZOMBIE_SPAWNS {
            zombie := state.zombies[zombie_index]
            zombie_finite := cel_f32_is_finite(zombie.position.x) &&
                             cel_f32_is_finite(zombie.position.y) &&
                             cel_f32_is_finite(zombie.position.z) &&
                             cel_f32_is_finite(zombie.facing.x) &&
                             cel_f32_is_finite(zombie.facing.y) &&
                             cel_f32_is_finite(zombie.mode_elapsed) &&
                             cel_f32_is_finite(zombie.alert_memory)
            testing.expectf(
                t,
                zombie_finite,
                "zombie %d produced non-finite state at tick %d",
                zombie_index,
                tick,
            )
            testing.expectf(
                t,
                zombie.mode_elapsed >= 0 && zombie.alert_memory >= 0,
                "zombie %d produced a negative timer at tick %d",
                zombie_index,
                tick,
            )
            testing.expectf(
                t,
                !game_zombie_position_blocked(spawn.room, zombie.position),
                "zombie %d entered blocked space at tick %d",
                zombie_index,
                tick,
            )
        }

        if state.player.mode == .GROUNDED {
            testing.expectf(
                t,
                game_position_inside_room(state.current_room, position),
                "grounded player escaped room bounds at tick %d",
                tick,
            )
            testing.expectf(
                t,
                !game_position_hits_obstacle(state.current_room, position),
                "grounded player overlapped an obstacle at tick %d",
                tick,
            )
            testing.expectf(
                t,
                !game_position_hits_hazard(state.current_room, position),
                "grounded player stopped in a hazard at tick %d",
                tick,
            )
        } else if state.player.mode == .ROOM_TRANSITION {
            testing.expectf(
                t,
                state.player.transition_elapsed <= state.player.transition_duration + GAME_FIXED_DT,
                "transition timer exceeded its duration at tick %d",
                tick,
            )
        }
    }
}
