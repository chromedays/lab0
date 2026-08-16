package main

// Lab0's entry point only selects a runtime mode. Each mode owns its parsing,
// resources, application loop, and exit status in its corresponding source file.

import "core:os"
import shared "./shared"

// Viewer selection is explicit so arbitrary or capture-only arguments cannot
// fall through into GPU initialization.
viewer_mode_requested :: proc(arguments: []string) -> bool {
    for argument, index in arguments {
        if argument == "--mode" && index + 1 < len(arguments) {
            return arguments[index + 1] == "viewer"
        }
    }
    return false
}

main :: proc() {
    arguments := os.args[1:]
    exit_code := 0

    if len(arguments) == 0 {
        shared.cli_viewer_usage_print()
    } else if scene_editor_mode_requested(arguments) ||
       shared.cli_argument_is_present(arguments, "--scene-help") {
        exit_code = run_scene_editor_mode(arguments)
    } else if game_mode_requested(arguments) ||
              shared.cli_argument_is_present(arguments, "--game-help") {
        exit_code = run_game_mode(arguments)
    } else if shared.cli_help_is_requested(arguments) {
        shared.cli_viewer_usage_print()
    } else if viewer_mode_requested(arguments) ||
              shared.cli_argument_is_present(arguments, "--capture-help") {
        exit_code = run_viewer_mode(arguments)
    } else {
        shared.cli_viewer_usage_print()
        exit_code = 2
    }

    if exit_code != 0 {
        os.exit(exit_code)
    }
}
