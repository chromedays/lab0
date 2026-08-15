package main

// Lab0's entry point only selects a runtime mode. Each mode owns its parsing,
// resources, application loop, and exit status in its corresponding source file.

import "core:os"
import shared "./shared"

main :: proc() {
    arguments := os.args[1:]
    exit_code := 0

    if scene_editor_mode_requested(arguments) ||
       shared.cli_argument_is_present(arguments, "--scene-help") {
        exit_code = run_scene_editor_mode(arguments)
    } else if game_mode_requested(arguments) ||
              shared.cli_argument_is_present(arguments, "--game-help") {
        exit_code = run_game_mode(arguments)
    } else if shared.cli_help_is_requested(arguments) {
        shared.cli_viewer_usage_print()
    } else {
        exit_code = run_viewer_mode(arguments)
    }

    if exit_code != 0 {
        os.exit(exit_code)
    }
}
