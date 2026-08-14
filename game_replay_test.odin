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
game_pixel_snap_replay_keeps_fixed_pose_subjects_on_parallel_lanes :: proc(
    t: ^testing.T,
) {
    replay, replay_error := load_game_replay("replays/pixel-snap-fixed-pose.json")
    testing.expect_value(t, replay_error, Game_Replay_Error.NONE)
    if replay_error != .NONE {
        return
    }
    defer destroy_game_replay(&replay)

    state := game_state_init(replay.start_room)
    zombie_index := GAME_ZOMBIE_COUNT - 1
    player: Game_Replay_Player
    for {
        input, available := game_replay_next_input(&replay, &player)
        if !available {
            break
        }
        game_fixed_update(&state, input, GAME_FIXED_DT)
    }

    testing.expect_value(t, replay.total_ticks, u64(240))
    testing.expect_value(t, state.current_room, Game_Room_ID.TEST_PIXEL_SNAP)
    testing.expect_value(t, state.tick, u64(240))
    testing.expect_value(t, state.dash_count, 0)
    testing.expectf(
        t,
        state.player.position.x > -2.67 && state.player.position.x < -2.66,
        "player should finish its fixed-pose lane near -2.667, got %.6f",
        state.player.position.x,
    )
    testing.expectf(
        t,
        state.zombies[zombie_index].position.x > 2.66 &&
            state.zombies[zombie_index].position.x < 2.67,
        "zombie should finish its fixed-pose lane near 2.667, got %.6f",
        state.zombies[zombie_index].position.x,
    )
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

@(test)
game_overlook_completion_replay_finishes_the_authored_loop :: proc(t: ^testing.T) {
    replay, replay_error := load_game_replay("replays/overlook-completion-loop.json")
    testing.expect_value(t, replay_error, Game_Replay_Error.NONE)
    if replay_error != .NONE { return }
    defer destroy_game_replay(&replay)

    expected_rooms := [?]Game_Room_ID{
        .R00_START_FOREST,
        .R01_FOREST_PASSAGE,
        .R02_CENTRAL_RUIN,
        .R04_RAVINE_CROSSING,
        .R05_OVERLOOK,
        .R06_LOWER_TRAIL,
        .R00_START_FOREST,
    }
    expected_room_index := 0
    state := game_state_init(replay.start_room)
    stats: Game_Replay_Stats
    player: Game_Replay_Player
    for {
        input, available := game_replay_next_input(&replay, &player)
        if !available { break }
        room_before_tick := state.current_room
        dashes_before_tick := state.dash_count
        hits_before_tick := state.zombie_hits
        resets_before_tick := state.reset_count
        game_fixed_update(&state, input, GAME_FIXED_DT)
        game_replay_stats_observe_tick(
            &stats,
            room_before_tick,
            dashes_before_tick,
            hits_before_tick,
            resets_before_tick,
            &state,
        )
        if state.current_room != expected_rooms[expected_room_index] {
            expected_room_index += 1
            testing.expectf(
                t,
                expected_room_index < len(expected_rooms),
                "completion replay entered an unexpected extra room %s",
                game_room(state.current_room).name,
            )
            if expected_room_index >= len(expected_rooms) { return }
            testing.expect_value(
                t,
                state.current_room,
                expected_rooms[expected_room_index],
            )
        }
    }

    testing.expect_value(t, replay.total_ticks, u64(1_896))
    testing.expect_value(t, expected_room_index, len(expected_rooms) - 1)
    testing.expect(t, state.overlook_reached)
    testing.expect(t, state.completed)
    testing.expect(t, stats.completed)
    testing.expect_value(t, stats.completion_tick, u64(1_873))
    testing.expect_value(t, stats.observed_ticks, stats.completion_tick)
    room_tick_sum: u64
    for room_stats in stats.rooms {
        room_tick_sum += room_stats.ticks
    }
    testing.expect_value(t, room_tick_sum, stats.completion_tick)
    testing.expect_value(t, stats.dashes, 1)
    testing.expect_value(t, stats.hits, 0)
    testing.expect_value(t, stats.resets, 0)
    testing.expect_value(t, state.dash_count, 1)
    testing.expect_value(t, state.zombie_hits, 0)
    testing.expect_value(t, state.reset_count, 0)
}

@(test)
game_all_rooms_camera_review_replay_visits_the_full_authored_route :: proc(
    t: ^testing.T,
) {
    replay, replay_error := load_game_replay(
        "replays/all-rooms-camera-review.json",
    )
    testing.expect_value(t, replay_error, Game_Replay_Error.NONE)
    if replay_error != .NONE { return }
    defer destroy_game_replay(&replay)

    state := game_state_init(replay.start_room)
    visited: [7]bool
    visited[int(state.current_room)] = true
    player: Game_Replay_Player
    for {
        input, available := game_replay_next_input(&replay, &player)
        if !available { break }
        game_fixed_update(&state, input, GAME_FIXED_DT)
        if int(state.current_room) < len(visited) {
            visited[int(state.current_room)] = true
        }
    }

    for was_visited, room_index in visited {
        testing.expectf(
            t,
            was_visited,
            "camera-review replay never visited %s",
            game_room(Game_Room_ID(room_index)).name,
        )
    }
    testing.expectf(
        t,
        state.completed,
        "camera-review replay ended in %s at (%.3f, %.3f) without completing",
        game_room(state.current_room).name,
        state.player.position.x,
        state.player.position.z,
    )
    testing.expect_value(t, state.tick, replay.total_ticks)
}

@(test)
game_zombie_encounter_replay_commits_to_one_dodge :: proc(t: ^testing.T) {
    replay, replay_error := load_game_replay("replays/zombie-encounter-smoke.json")
    testing.expect_value(t, replay_error, Game_Replay_Error.NONE)
    if replay_error != .NONE { return }
    defer destroy_game_replay(&replay)

    state := game_state_init(replay.start_room)
    stats: Game_Replay_Stats
    player: Game_Replay_Player
    for {
        input, available := game_replay_next_input(&replay, &player)
        if !available { break }
        room_before_tick := state.current_room
        dashes_before_tick := state.dash_count
        hits_before_tick := state.zombie_hits
        resets_before_tick := state.reset_count
        game_fixed_update(&state, input, GAME_FIXED_DT)
        game_replay_stats_observe_tick(
            &stats,
            room_before_tick,
            dashes_before_tick,
            hits_before_tick,
            resets_before_tick,
            &state,
        )
    }
    testing.expect_value(t, state.tick, u64(90))
    testing.expect_value(t, state.dash_count, 1)
    testing.expect_value(t, state.zombie_hits, 0)
    testing.expect_value(t, stats.dashes, 1)
    testing.expect_value(t, stats.hits, 0)
    testing.expect_value(t, stats.resets, 0)
    testing.expectf(
        t,
        state.player.position.z > 2.5,
        "the encounter replay should finish beyond the committed lunge lane",
    )
}

@(test)
game_zombie_gauntlet_replay_runs_thirty_seconds_of_active_evasion :: proc(
    t: ^testing.T,
) {
    replay, replay_error := load_game_replay("replays/zombie-gauntlet-30s.json")
    testing.expect_value(t, replay_error, Game_Replay_Error.NONE)
    if replay_error != .NONE { return }
    defer destroy_game_replay(&replay)

    state := game_state_init(replay.start_room)
    stats: Game_Replay_Stats
    player: Game_Replay_Player
    windup_ticks := 0
    lunge_ticks := 0
    maximum_chasers := 0
    first_hit_tick: u64
    first_exit_tick: u64
    for {
        input, available := game_replay_next_input(&replay, &player)
        if !available { break }
        room_before_tick := state.current_room
        dashes_before_tick := state.dash_count
        hits_before_tick := state.zombie_hits
        resets_before_tick := state.reset_count
        game_fixed_update(&state, input, GAME_FIXED_DT)
        game_replay_stats_observe_tick(
            &stats,
            room_before_tick,
            dashes_before_tick,
            hits_before_tick,
            resets_before_tick,
            &state,
        )
        if first_hit_tick == 0 && state.zombie_hits > 0 {
            first_hit_tick = state.tick
        }
        if first_exit_tick == 0 && state.current_room != .R03_WIDE_GROVE {
            first_exit_tick = state.tick
        }

        chasers := 0
        for spawn, zombie_index in GAME_ZOMBIE_SPAWNS {
            if spawn.room != state.current_room { continue }
            #partial switch state.zombies[zombie_index].mode {
            case .CHASING:
                chasers += 1
            case .WINDUP:
                windup_ticks += 1
            case .LUNGING:
                lunge_ticks += 1
            }
        }
        maximum_chasers = max(maximum_chasers, chasers)
    }

    testing.expect_value(t, replay.total_ticks, u64(1_800))
    testing.expect_value(t, state.tick, u64(1_800))
    testing.expect_value(t, state.dash_count, 39)
    testing.expect_value(t, state.zombie_hits, 3)
    testing.expect_value(t, state.reset_count, 3)
    testing.expect_value(t, stats.observed_ticks, replay.total_ticks)
    testing.expect_value(t, stats.dashes, 39)
    testing.expect_value(t, stats.hits, 3)
    testing.expect_value(t, stats.resets, 3)
    testing.expectf(
        t,
        state.current_room == .R03_WIDE_GROVE,
        "gauntlet left R03 at tick %d after first hit tick %d",
        first_exit_tick,
        first_hit_tick,
    )
    testing.expectf(t, state.dash_count >= 30, "gauntlet should contain repeated dashes")
    testing.expectf(t, maximum_chasers >= 3, "at least three zombies should join one chase")
    testing.expectf(t, windup_ticks > 0, "gauntlet should show attack windups")
    testing.expectf(t, lunge_ticks > 0, "gauntlet should show committed lunges")
}
