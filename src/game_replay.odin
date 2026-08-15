package main

// Game replays store controller input in fixed-tick runs. The compact segment
// format is pleasant to review in source control while still reproducing the
// exact Game_Input delivered to every 60 Hz simulation tick.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import shared "./shared"

GAME_REPLAY_SCHEMA_VERSION :: 1
GAME_REPLAY_MAX_TICKS       :: 1_000_000

Game_Replay_Error :: enum {
    NONE,
    READ_FAILED,
    PARSE_FAILED,
    INVALID_SCHEMA,
    INVALID_START_ROOM,
    EMPTY,
    INVALID_SEGMENT,
    TOO_LONG,
}

// File structs are JSON-owned and use plain arrays/strings. Runtime structs
// below replace textual room IDs and compact movement arrays with game types.
Game_Replay_File_Segment :: struct {
    ticks:         int,
    move:          [2]f32,
    dash_on_first: bool,
}

Game_Replay_File :: struct {
    schema_version: int,
    start_room:     string,
    segments:       [dynamic]Game_Replay_File_Segment,
}

Game_Replay_Segment :: struct {
    ticks:         int,
    input:         Game_Input,
    dash_on_first: bool,
}

// A validated replay owns segments and caches total_ticks so capture option
// checks never need to expand the compact sequence.
Game_Replay :: struct {
    start_room:  shared.Game_Room_ID,
    segments:    [dynamic]Game_Replay_Segment,
    total_ticks: u64,
}

// The player is a cursor, not replay-owned state. A fresh zero value starts at
// tick one, and multiple players may traverse the same immutable replay.
Game_Replay_Player :: struct {
    segment_index: int,
    segment_tick:  int,
    ticks_played:  u64,
}

Game_Replay_Room_Stats :: struct {
    ticks:  u64,
    dashes: int,
    hits:   int,
    resets: int,
}

// Statistics stop at the first completed tick, so trailing celebration input
// cannot inflate room dwell times or event counts in the completion report.
Game_Replay_Stats :: struct {
    rooms:           [len(GAME_ROOMS)]Game_Replay_Room_Stats,
    observed_ticks:  u64,
    completion_tick: u64,
    dashes:          int,
    hits:            int,
    resets:          int,
    completed:       bool,
    printed:         bool,
}

game_room_code :: proc(room_id: shared.Game_Room_ID) -> string {
    switch room_id {
    case .R00_START_FOREST:    return "R00"
    case .R01_FOREST_PASSAGE:  return "R01"
    case .R02_CENTRAL_RUIN:    return "R02"
    case .R03_WIDE_GROVE:      return "R03"
    case .R04_RAVINE_CROSSING: return "R04"
    case .R05_OVERLOOK:        return "R05"
    case .R06_LOWER_TRAIL:     return "R06"
    case .TEST_OCCLUSION:      return "T00"
    case .TEST_PIXEL_SNAP:     return "T01"
    }
    return "UNKNOWN"
}

// Attribute events to the room that owned the tick before simulation. A room
// transition can change state.current_room during that tick, but its input and
// event deltas still belong to the source room.
game_replay_stats_observe_tick :: proc(
    stats: ^Game_Replay_Stats,
    room_before_tick: shared.Game_Room_ID,
    dashes_before_tick, hits_before_tick, resets_before_tick: int,
    state: ^Game_State,
) {
    if stats.completed {
        return
    }

    room_stats := &stats.rooms[int(room_before_tick)]
    room_stats.ticks += 1
    dash_delta := max(state.dash_count - dashes_before_tick, 0)
    hit_delta := max(state.zombie_hits - hits_before_tick, 0)
    reset_delta := max(state.reset_count - resets_before_tick, 0)
    room_stats.dashes += dash_delta
    room_stats.hits += hit_delta
    room_stats.resets += reset_delta
    stats.dashes += dash_delta
    stats.hits += hit_delta
    stats.resets += reset_delta
    stats.observed_ticks += 1

    if state.completed {
        stats.completed = true
        stats.completion_tick = state.tick
    }
}

// These stable, machine-readable lines are converted into the Markdown table
// by scripts/test-game.sh and stay legible in the raw recording log.
game_replay_stats_print :: proc(stats: ^Game_Replay_Stats, replay_ticks: u64) {
    for room_id in shared.Game_Room_ID {
        room_stats := stats.rooms[int(room_id)]
        if room_stats.ticks == 0 && room_stats.dashes == 0 &&
           room_stats.hits == 0 && room_stats.resets == 0 {
            continue
        }
        fmt.printf(
            "GAME_REPLAY_ROOM_METRIC code=%s ticks=%d seconds=%.3f dashes=%d hits=%d resets=%d\n",
            game_room_code(room_id),
            room_stats.ticks,
            f64(room_stats.ticks) / 60.0,
            room_stats.dashes,
            room_stats.hits,
            room_stats.resets,
        )
    }
    fmt.printf(
        "GAME_REPLAY_TOTAL_METRIC completed=%v completion_tick=%d completion_seconds=%.3f replay_ticks=%d observed_ticks=%d dashes=%d hits=%d resets=%d\n",
        stats.completed,
        stats.completion_tick,
        f64(stats.completion_tick) / 60.0,
        replay_ticks,
        stats.observed_ticks,
        stats.dashes,
        stats.hits,
        stats.resets,
    )
}

game_replay_error_message :: proc(error: Game_Replay_Error) -> string {
    switch error {
    case .NONE:               return "no error"
    case .READ_FAILED:        return "file could not be read"
    case .PARSE_FAILED:       return "JSON could not be parsed"
    case .INVALID_SCHEMA:     return "unsupported schema version"
    case .INVALID_START_ROOM: return "unknown start room"
    case .EMPTY:              return "replay has no input segments"
    case .INVALID_SEGMENT:    return "segment has invalid ticks or movement"
    case .TOO_LONG:           return "replay exceeds the fixed-tick safety limit"
    }
    return "unknown replay error"
}

destroy_game_replay_file :: proc(replay_file: ^Game_Replay_File) {
    if len(replay_file.start_room) > 0 {
        delete(replay_file.start_room)
    }
    delete(replay_file.segments)
    replay_file^ = {}
}

destroy_game_replay :: proc(replay: ^Game_Replay) {
    delete(replay.segments)
    replay^ = {}
}

// Convert and validate incrementally. Any invalid segment destroys the partial
// runtime allocation before returning, so callers only own a replay on success.
game_replay_from_file :: proc(
    replay_file: ^Game_Replay_File,
) -> (Game_Replay, Game_Replay_Error) {
    if replay_file.schema_version != GAME_REPLAY_SCHEMA_VERSION {
        return {}, .INVALID_SCHEMA
    }
    start_room, room_valid := shared.game_room_from_string(replay_file.start_room)
    if !room_valid {
        return {}, .INVALID_START_ROOM
    }
    if len(replay_file.segments) == 0 {
        return {}, .EMPTY
    }

    replay := Game_Replay{start_room = start_room}
    for segment in replay_file.segments {
        move_x := segment.move[0]
        move_y := segment.move[1]
        if segment.ticks <= 0 ||
           !shared.cel_f32_is_finite(move_x) ||
           !shared.cel_f32_is_finite(move_y) ||
           math.abs(move_x) > 1 ||
           math.abs(move_y) > 1 {
            destroy_game_replay(&replay)
            return {}, .INVALID_SEGMENT
        }
        if replay.total_ticks + u64(segment.ticks) > GAME_REPLAY_MAX_TICKS {
            destroy_game_replay(&replay)
            return {}, .TOO_LONG
        }
        append(&replay.segments, Game_Replay_Segment{
            ticks = segment.ticks,
            input = {{move_x, move_y}, false},
            dash_on_first = segment.dash_on_first,
        })
        replay.total_ticks += u64(segment.ticks)
    }
    return replay, .NONE
}

load_game_replay :: proc(path: string) -> (Game_Replay, Game_Replay_Error) {
    file_data, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        return {}, .READ_FAILED
    }
    defer delete(file_data)

    replay_file: Game_Replay_File
    unmarshal_error := json.unmarshal(file_data, &replay_file, spec = .JSON)
    if unmarshal_error != nil {
        destroy_game_replay_file(&replay_file)
        return {}, .PARSE_FAILED
    }
    defer destroy_game_replay_file(&replay_file)
    return game_replay_from_file(&replay_file)
}

// Expand one logical tick without materializing the full input stream.
// dash_on_first is asserted only for segment tick zero; exhaustion is the sole
// false result and leaves the cursor at the end.
game_replay_next_input :: proc(
    replay: ^Game_Replay,
    player: ^Game_Replay_Player,
) -> (Game_Input, bool) {
    for player.segment_index < len(replay.segments) {
        segment := &replay.segments[player.segment_index]
        if player.segment_tick >= segment.ticks {
            player.segment_index += 1
            player.segment_tick = 0
            continue
        }
        input := segment.input
        input.dash_pressed = segment.dash_on_first && player.segment_tick == 0
        player.segment_tick += 1
        player.ticks_played += 1
        return input, true
    }
    return {}, false
}
