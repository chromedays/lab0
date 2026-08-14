package main

import "core:testing"

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
