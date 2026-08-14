package main

import "core:testing"

@(test)
game_replay_segments_expand_to_exact_tick_inputs :: proc(t: ^testing.T) {
    replay_file := Game_Replay_File{
        schema_version = GAME_REPLAY_SCHEMA_VERSION,
        start_room = "R04",
    }
    append(&replay_file.segments, Game_Replay_File_Segment{
        ticks = 3,
        move = {0, -1},
        dash_on_first = true,
    })
    defer delete(replay_file.segments)

    replay, replay_error := game_replay_from_file(&replay_file)
    testing.expect_value(t, replay_error, Game_Replay_Error.NONE)
    defer destroy_game_replay(&replay)
    testing.expect_value(t, replay.start_room, Game_Room_ID.R04_RAVINE_CROSSING)
    testing.expect_value(t, replay.total_ticks, u64(3))

    player: Game_Replay_Player
    first, first_ok := game_replay_next_input(&replay, &player)
    second, second_ok := game_replay_next_input(&replay, &player)
    third, third_ok := game_replay_next_input(&replay, &player)
    _, fourth_ok := game_replay_next_input(&replay, &player)
    testing.expect(t, first_ok && second_ok && third_ok && !fourth_ok)
    testing.expect(t, first.dash_pressed, "dash_on_first should affect only the first tick")
    testing.expect(t, !second.dash_pressed && !third.dash_pressed)
    testing.expect_value(t, first.move, second.move)
    testing.expect_value(t, player.ticks_played, u64(3))
}

@(test)
game_replay_fixture_loads_and_drives_the_real_simulation :: proc(t: ^testing.T) {
    replay, replay_error := load_game_replay("replays/traversal-dash-smoke.json")
    testing.expect_value(t, replay_error, Game_Replay_Error.NONE)
    if replay_error != .NONE { return }
    defer destroy_game_replay(&replay)

    state := game_state_init(replay.start_room)
    player: Game_Replay_Player
    for {
        input, available := game_replay_next_input(&replay, &player)
        if !available { break }
        game_fixed_update(&state, input, GAME_FIXED_DT)
    }
    testing.expect_value(t, state.tick, replay.total_ticks)
    testing.expect_value(t, state.dash_count, 1)
    testing.expectf(t, state.player.position.x > 1.5, "fixture should move the player, got x %.3f", state.player.position.x)
}

@(test)
game_replay_validation_rejects_bad_segments :: proc(t: ^testing.T) {
    replay_file := Game_Replay_File{
        schema_version = GAME_REPLAY_SCHEMA_VERSION,
        start_room = "R00",
    }
    append(&replay_file.segments, Game_Replay_File_Segment{
        ticks = 0,
        move = {1, 0},
    })
    defer delete(replay_file.segments)
    _, replay_error := game_replay_from_file(&replay_file)
    testing.expect_value(t, replay_error, Game_Replay_Error.INVALID_SEGMENT)
}

@(test)
game_room_transition_replay_enters_r01_through_the_real_exit :: proc(t: ^testing.T) {
    replay, replay_error := load_game_replay("replays/room-transition-smoke.json")
    testing.expect_value(t, replay_error, Game_Replay_Error.NONE)
    if replay_error != .NONE { return }
    defer destroy_game_replay(&replay)

    state := game_state_init(replay.start_room)
    player: Game_Replay_Player
    for {
        input, available := game_replay_next_input(&replay, &player)
        if !available { break }
        game_fixed_update(&state, input, GAME_FIXED_DT)
    }
    testing.expect_value(t, state.tick, u64(240))
    testing.expect_value(t, state.current_room, Game_Room_ID.R01_FOREST_PASSAGE)
    testing.expect_value(t, state.player.mode, Game_Player_Mode.GROUNDED)
    testing.expectf(
        t,
        state.player.position.x > game_room(.R01_FOREST_PASSAGE).bounds.min_x,
        "transition replay should finish inside R01, got x %.3f",
        state.player.position.x,
    )
}
