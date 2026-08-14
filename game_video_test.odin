package main

import "core:testing"

@(test)
game_run_options_parse_video_output :: proc(t: ^testing.T) {
    options, valid, error_argument := parse_game_run_options([]string{
        "--mode", "game",
        "--game-replay", "replays/traversal-dash-smoke.json",
        "--game-video-output", "artifacts/report/game-test.mp4",
        "--capture-case", "video-report",
    })
    testing.expect(t, valid, error_argument)
    testing.expect_value(
        t,
        options.video_output,
        "artifacts/report/game-test.mp4",
    )
}

@(test)
game_video_options_accept_replay_composite_capture :: proc(t: ^testing.T) {
    run_options := Game_Run_Options{
        replay_path = "replays/traversal-dash-smoke.json",
        video_output = "artifacts/report/game-test.mp4",
    }
    capture := Capture_Options{
        enabled = true,
        target = .COMPOSITE,
    }
    testing.expect_value(
        t,
        validate_game_video_options(&run_options, &capture),
        Game_Video_Options_Error.NONE,
    )
}

@(test)
game_video_options_reject_invalid_and_conflicting_requests :: proc(t: ^testing.T) {
    run_options := Game_Run_Options{
        video_output = "artifacts/report/game-test.mov",
    }
    capture := Capture_Options{
        enabled = true,
        target = .COMPOSITE,
    }
    testing.expect_value(
        t,
        validate_game_video_options(&run_options, &capture),
        Game_Video_Options_Error.INVALID_OUTPUT,
    )

    run_options.video_output = "artifacts/report/game-test.mp4"
    testing.expect_value(
        t,
        validate_game_video_options(&run_options, &capture),
        Game_Video_Options_Error.MISSING_REPLAY,
    )

    run_options.replay_path = "replays/traversal-dash-smoke.json"
    capture.enabled = false
    testing.expect_value(
        t,
        validate_game_video_options(&run_options, &capture),
        Game_Video_Options_Error.MISSING_CAPTURE,
    )

    capture.enabled = true
    capture.target = .SCENE
    testing.expect_value(
        t,
        validate_game_video_options(&run_options, &capture),
        Game_Video_Options_Error.INVALID_TARGET,
    )

    capture.target = .COMPOSITE
    run_options.record_directory = "artifacts/report/frames"
    testing.expect_value(
        t,
        validate_game_video_options(&run_options, &capture),
        Game_Video_Options_Error.CONFLICTING_RECORD_DIRECTORY,
    )

    run_options.record_directory = ""
    run_options.capture_tick_set = true
    testing.expect_value(
        t,
        validate_game_video_options(&run_options, &capture),
        Game_Video_Options_Error.CONFLICTING_CAPTURE_TICK,
    )

    run_options.capture_tick_set = false
    capture.output_path_explicit = true
    testing.expect_value(
        t,
        validate_game_video_options(&run_options, &capture),
        Game_Video_Options_Error.CONFLICTING_CAPTURE_OUTPUT,
    )
}

@(test)
video_stream_frame_and_ffmpeg_contract_are_stable :: proc(t: ^testing.T) {
    testing.expect_value(
        t,
        video_stream_frame_byte_count(GAME_SCREEN_WIDTH, GAME_SCREEN_HEIGHT),
        3_686_400,
    )
    testing.expect_value(
        t,
        video_stream_frame_byte_count(0, GAME_SCREEN_HEIGHT),
        0,
    )

    temporary_path := video_stream_temporary_output_path(
        "artifacts/report/game-test.mp4",
        42,
    )
    defer delete(temporary_path)
    testing.expect_value(
        t,
        temporary_path,
        "artifacts/report/game-test.partial-42.mp4",
    )

    command := video_stream_ffmpeg_command(temporary_path, "1280x720", "60")
    testing.expect_value(t, command[0], "ffmpeg")
    testing.expect_value(t, command[5], "rawvideo")
    testing.expect_value(t, command[7], "rgba")
    testing.expect_value(t, command[9], "1280x720")
    testing.expect_value(t, command[11], "60")
    testing.expect_value(t, command[13], "pipe:0")
    testing.expect_value(t, command[15], "vflip")
    testing.expect_value(t, command[len(command) - 1], temporary_path)
}

@(test)
capture_parser_marks_explicit_output_for_video_conflict_checks :: proc(t: ^testing.T) {
    result := parse_capture_options([]string{
        "--capture-case", "video-report",
        "--capture-output", "artifacts/report/frame.png",
    })
    defer destroy_capture_options(&result.options)
    testing.expect_value(t, result.error, Capture_Parse_Error.NONE)
    testing.expect(t, result.options.output_path_explicit)
}
