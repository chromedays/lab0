package main

// Game replays store controller input in fixed-tick runs. The compact segment
// format is pleasant to review in source control while still reproducing the
// exact Game_Input delivered to every 60 Hz simulation tick.

import "core:encoding/json"
import "core:math"
import "core:os"

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

Game_Replay :: struct {
    start_room:  Game_Room_ID,
    segments:    [dynamic]Game_Replay_Segment,
    total_ticks: u64,
}

Game_Replay_Player :: struct {
    segment_index: int,
    segment_tick:  int,
    ticks_played:  u64,
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

game_replay_from_file :: proc(
    replay_file: ^Game_Replay_File,
) -> (Game_Replay, Game_Replay_Error) {
    if replay_file.schema_version != GAME_REPLAY_SCHEMA_VERSION {
        return {}, .INVALID_SCHEMA
    }
    start_room, room_valid := game_room_from_string(replay_file.start_room)
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
           !cel_f32_is_finite(move_x) ||
           !cel_f32_is_finite(move_y) ||
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
