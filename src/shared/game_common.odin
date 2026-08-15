package shared

// Shared Game identifiers and command-line state used by simulation, replay,
// rendering, and the common video encoder.

import "core:math"
import rl "vendor:raylib"

Game_Room_ID :: enum {
    R00_START_FOREST,
    R01_FOREST_PASSAGE,
    R02_CENTRAL_RUIN,
    R03_WIDE_GROVE,
    R04_RAVINE_CROSSING,
    R05_OVERLOOK,
    R06_LOWER_TRAIL,
    TEST_OCCLUSION,
    TEST_PIXEL_SNAP,
}

Game_Run_Options :: struct {
    start_room:          Game_Room_ID,
    start_room_explicit: bool,
    help_requested:      bool,
    debug_visible:       bool,
    replay_path:         string,
    capture_tick:        u64,
    capture_tick_set:    bool,
    record_directory:    string,
    video_output:        string,
}

game_room_from_string :: proc(value: string) -> (Game_Room_ID, bool) {
    switch value {
    case "R00", "r00", "start", "start-forest":
        return .R00_START_FOREST, true
    case "R01", "r01", "forest-passage":
        return .R01_FOREST_PASSAGE, true
    case "R02", "r02", "central-ruin":
        return .R02_CENTRAL_RUIN, true
    case "R03", "r03", "wide-grove":
        return .R03_WIDE_GROVE, true
    case "R04", "r04", "ravine":
        return .R04_RAVINE_CROSSING, true
    case "R05", "r05", "overlook":
        return .R05_OVERLOOK, true
    case "R06", "r06", "lower-trail":
        return .R06_LOWER_TRAIL, true
    case "T00", "t00", "occlusion-test":
        return .TEST_OCCLUSION, true
    case "T01", "t01", "pixel-snap-test":
        return .TEST_PIXEL_SNAP, true
    }
    return .R00_START_FOREST, false
}

game_vector2_length :: proc(value: rl.Vector2) -> f32 {
    return math.sqrt(value.x * value.x + value.y * value.y)
}
