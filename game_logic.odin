package main

// The traversal prototype deliberately keeps game rules small and explicit.
// Rooms, exits, movement, and progress live here so they can be tested without
// opening a graphics window. Rendering and live input are owned by game_mode.

import "core:math"
import rl "vendor:raylib"

GAME_FIXED_DT              :: f32(1.0 / 60.0)
GAME_MAX_FIXED_TICKS       :: 8
GAME_MOVE_SPEED            :: f32(3.6)
GAME_ACCELERATION          :: f32(28.0)
GAME_DECELERATION          :: f32(36.0)
GAME_PLAYER_RADIUS         :: f32(0.32)
GAME_DASH_DURATION         :: f32(0.16)
GAME_DASH_SPEED            :: f32(10.0)
GAME_DASH_COOLDOWN         :: f32(0.24)
GAME_DASH_BUFFER           :: f32(0.10)
GAME_GAMEPAD_DEADZONE      :: f32(0.20)
GAME_EXIT_REENTRY_LOCK     :: f32(0.15)
GAME_GOAL_RADIUS           :: f32(1.2)
GAME_ZOMBIE_COUNT          :: 8
GAME_ZOMBIE_RADIUS         :: f32(0.34)
GAME_ZOMBIE_SHAMBLE_SPEED  :: f32(0.72)
GAME_ZOMBIE_CHASE_SPEED    :: f32(1.65)
GAME_ZOMBIE_SIGHT_RADIUS   :: f32(7.0)
GAME_ZOMBIE_HEARING_RADIUS :: f32(10.0)
GAME_ZOMBIE_MEMORY         :: f32(2.4)
GAME_ZOMBIE_ATTACK_RANGE   :: f32(1.35)
GAME_ZOMBIE_WINDUP_TIME    :: f32(0.46)
GAME_ZOMBIE_LUNGE_TIME     :: f32(0.22)
GAME_ZOMBIE_LUNGE_SPEED    :: f32(7.0)
GAME_ZOMBIE_RECOVERY_TIME  :: f32(0.62)
// The T01 diagnostic moves both subjects by exactly one quarter of a 256x144
// render pixel per fixed tick: (8 world units / 144 pixels) * 60 Hz / 4.
GAME_PIXEL_SNAP_TEST_SPEED :: f32(5.0 / 6.0)

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

Game_Player_Mode :: enum {
    GROUNDED,
    DASHING,
    ROOM_TRANSITION,
}

Game_Zombie_Mode :: enum {
    SHAMBLING,
    CHASING,
    WINDUP,
    LUNGING,
    RECOVERING,
}

Game_Exit_Side :: enum {
    NORTH,
    EAST,
    SOUTH,
    WEST,
}

Game_Rect :: struct {
    min_x: f32,
    min_z: f32,
    max_x: f32,
    max_z: f32,
}

Game_Room :: struct {
    id:            Game_Room_ID,
    name:          string,
    bounds:        Game_Rect,
    floor_y:       f32,
    spawn:         rl.Vector3,
    camera_follow: bool,
    color:         rl.Color,
}

Game_Room_Exit :: struct {
    source:          Game_Room_ID,
    target:          Game_Room_ID,
    side:            Game_Exit_Side,
    span_center:     f32,
    half_width:      f32,
    target_position: rl.Vector3,
    duration:        f32,
    one_way_drop:    bool,
}

Game_Obstacle :: struct {
    room:   Game_Room_ID,
    bounds: Game_Rect,
}

Game_Hazard :: struct {
    room:   Game_Room_ID,
    bounds: Game_Rect,
}

Game_Zombie_Spawn :: struct {
    room:       Game_Room_ID,
    position:   rl.Vector3,
    patrol_end: rl.Vector3,
}

Game_Input :: struct {
    move:         rl.Vector2,
    dash_pressed: bool,
}

Game_Player :: struct {
    position:              rl.Vector3,
    velocity:              rl.Vector2,
    facing:                rl.Vector2,
    mode:                  Game_Player_Mode,
    dash_direction:        rl.Vector2,
    dash_start:            rl.Vector3,
    dash_elapsed:          f32,
    dash_cooldown:         f32,
    dash_buffer:           f32,
    transition_from_room:  Game_Room_ID,
    transition_to_room:    Game_Room_ID,
    transition_start:      rl.Vector3,
    transition_end:        rl.Vector3,
    transition_elapsed:    f32,
    transition_duration:   f32,
    exit_reentry_lock:     f32,
}

Game_Zombie :: struct {
    position:        rl.Vector3,
    facing:          rl.Vector2,
    mode:            Game_Zombie_Mode,
    mode_elapsed:    f32,
    alert_memory:    f32,
    last_known:      rl.Vector3,
    attack_direction: rl.Vector2,
    patrol_to_end:   bool,
}

Game_State :: struct {
    current_room:       Game_Room_ID,
    player:             Game_Player,
    zombies:            [GAME_ZOMBIE_COUNT]Game_Zombie,
    last_safe_position: rl.Vector3,
    overlook_reached:   bool,
    completed:          bool,
    completion_reported: bool,
    elapsed_time:       f32,
    dash_count:         int,
    zombie_hits:        int,
    tick:               u64,
    debug_visible:      bool,
}

GAME_ROOMS := [?]Game_Room{
    {
        id = .R00_START_FOREST,
        name = "R00 Start Forest",
        bounds = {-8, -5, 8, 5},
        floor_y = 0,
        spawn = {0, 0, 1.5},
        camera_follow = false,
        color = {28, 103, 102, 255},
    },
    {
        id = .R01_FOREST_PASSAGE,
        name = "R01 Forest Passage",
        bounds = {9, -4, 27, 4},
        floor_y = 0,
        spawn = {10, 0, 0},
        camera_follow = true,
        color = {29, 82, 111, 255},
    },
    {
        id = .R02_CENTRAL_RUIN,
        name = "R02 Central Ruin",
        bounds = {28, -8, 48, 8},
        floor_y = 0,
        spawn = {29, 0, 0},
        camera_follow = true,
        color = {57, 55, 116, 255},
    },
    {
        id = .R03_WIDE_GROVE,
        name = "R03 Wide Grove",
        bounds = {49, -7, 67, 7},
        floor_y = 0,
        spawn = {50, 0, 0},
        camera_follow = false,
        color = {30, 108, 78, 255},
    },
    {
        id = .R04_RAVINE_CROSSING,
        name = "R04 Ravine Crossing",
        bounds = {29, -23, 47, -13},
        floor_y = 1.5,
        spawn = {38, 1.5, -13.8},
        camera_follow = false,
        color = {99, 46, 92, 255},
    },
    {
        id = .R05_OVERLOOK,
        name = "R05 Overlook",
        bounds = {11, -23, 25, -13},
        floor_y = 1.5,
        spawn = {24.2, 1.5, -20.5},
        camera_follow = false,
        color = {117, 55, 81, 255},
    },
    {
        id = .R06_LOWER_TRAIL,
        name = "R06 Lower Trail",
        bounds = {-12, -22, 10, -6},
        floor_y = 0,
        spawn = {9.2, 0, -20.5},
        camera_follow = true,
        color = {25, 64, 94, 255},
    },
    {
        id = .TEST_OCCLUSION,
        name = "T00 Occlusion Test",
        bounds = {74, -4, 86, 4},
        floor_y = 0,
        spawn = {80, 0, 3},
        camera_follow = false,
        color = {45, 45, 63, 255},
    },
    {
        id = .TEST_PIXEL_SNAP,
        name = "T01 Pixel Snap Test",
        bounds = {-8, 26, 8, 34},
        floor_y = 0,
        spawn = {-6, 0, 31.5},
        camera_follow = false,
        color = {28, 48, 62, 255},
    },
}

GAME_EXITS := [?]Game_Room_Exit{
    {.R00_START_FOREST, .R01_FOREST_PASSAGE, .EAST, 0, 1.6, {9.8, 0, 0}, 0.30, false},
    {.R00_START_FOREST, .R06_LOWER_TRAIL, .NORTH, 0, 1.6, {0, 0, -6.8}, 0.30, false},
    {.R01_FOREST_PASSAGE, .R00_START_FOREST, .WEST, 0, 1.6, {7.2, 0, 0}, 0.30, false},
    {.R01_FOREST_PASSAGE, .R02_CENTRAL_RUIN, .EAST, 0, 1.6, {28.8, 0, 0}, 0.30, false},
    {.R02_CENTRAL_RUIN, .R01_FOREST_PASSAGE, .WEST, 0, 1.6, {26.2, 0, 0}, 0.30, false},
    {.R02_CENTRAL_RUIN, .R03_WIDE_GROVE, .EAST, 0, 1.6, {49.8, 0, 0}, 0.30, false},
    {.R02_CENTRAL_RUIN, .R04_RAVINE_CROSSING, .NORTH, 38, 1.6, {38, 1.5, -13.8}, 0.34, false},
    {.R03_WIDE_GROVE, .R02_CENTRAL_RUIN, .WEST, 0, 1.6, {47.2, 0, 0}, 0.30, false},
    {.R04_RAVINE_CROSSING, .R02_CENTRAL_RUIN, .SOUTH, 38, 1.6, {38, 0, -7.2}, 0.34, false},
    {.R04_RAVINE_CROSSING, .R05_OVERLOOK, .WEST, -20.5, 1.5, {24.2, 1.5, -20.5}, 0.30, false},
    {.R05_OVERLOOK, .R04_RAVINE_CROSSING, .EAST, -20.5, 1.5, {29.8, 1.5, -20.5}, 0.30, false},
    {.R05_OVERLOOK, .R06_LOWER_TRAIL, .WEST, -20.5, 1.5, {9.2, 0, -20.5}, 0.35, true},
    {.R06_LOWER_TRAIL, .R00_START_FOREST, .SOUTH, 0, 1.6, {0, 0, -4.2}, 0.30, false},
}

GAME_OBSTACLES := [?]Game_Obstacle{
    {.R00_START_FOREST, {-4.0, 0.5, -2.8, 1.7}},
    {.R00_START_FOREST, {3.2, -3.3, 4.2, -2.3}},
    {.R01_FOREST_PASSAGE, {14.0, -3.4, 15.1, -2.3}},
    {.R01_FOREST_PASSAGE, {20.2, 2.0, 21.5, 3.3}},
    {.R02_CENTRAL_RUIN, {34.0, -2.0, 35.2, -0.8}},
    {.R02_CENTRAL_RUIN, {40.8, 2.5, 42.0, 3.7}},
    {.R02_CENTRAL_RUIN, {43.0, -5.7, 44.4, -4.3}},
    {.R03_WIDE_GROVE, {56.2, -1.8, 59.8, 1.8}},
    {.R03_WIDE_GROVE, {63.0, 3.0, 64.2, 4.2}},
    {.R04_RAVINE_CROSSING, {31.0, -22.2, 32.3, -20.9}},
    {.R04_RAVINE_CROSSING, {44.0, -16.4, 45.4, -15.0}},
    {.R05_OVERLOOK, {14.0, -16.0, 15.2, -14.8}},
    {.R06_LOWER_TRAIL, {-8.4, -18.8, -5.2, -18.0}},
    {.R06_LOWER_TRAIL, {3.0, -11.0, 4.1, -9.9}},
}

GAME_HAZARDS := [?]Game_Hazard{
    // The ravine is just wider than a walking step and narrower than one dash.
    {.R04_RAVINE_CROSSING, {29.0, -17.85, 47.0, -17.10}},
}

// The central-ruin zombie stays away from the authored speedrun line. The six
// wide-grove zombies turn that optional room into a dedicated evasion arena.
GAME_ZOMBIE_SPAWNS := [GAME_ZOMBIE_COUNT]Game_Zombie_Spawn{
    {.R02_CENTRAL_RUIN, {44.6, 0, 6.1}, {41.8, 0, 6.1}},
    {.R03_WIDE_GROVE, {53.2, 0, 2.8}, {51.8, 0, -2.5}},
    {.R03_WIDE_GROVE, {63.0, 0, 2.2}, {65.2, 0, -3.8}},
    {.R03_WIDE_GROVE, {51.2, 0, -5.0}, {54.0, 0, -3.6}},
    {.R03_WIDE_GROVE, {55.0, 0, 5.4}, {60.5, 0, 5.2}},
    {.R03_WIDE_GROVE, {65.1, 0, 5.3}, {65.4, 0, 2.7}},
    {.R03_WIDE_GROVE, {62.0, 0, -5.1}, {58.8, 0, -4.2}},
    {.TEST_PIXEL_SNAP, {6, 0, 28.5}, {-6, 0, 28.5}},
}

GAME_OVERLOOK_POSITION :: rl.Vector3{18, 2.35, -18}

game_room :: proc(room_id: Game_Room_ID) -> ^Game_Room {
    return &GAME_ROOMS[int(room_id)]
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

game_state_init :: proc(start_room: Game_Room_ID = .R00_START_FOREST) -> Game_State {
    room := game_room(start_room)
    state := Game_State{
        current_room = start_room,
        player = {
            position = room.spawn,
            facing = {1, 0},
            mode = .GROUNDED,
        },
        last_safe_position = room.spawn,
    }
    game_reset_all_zombies(&state)
    return state
}

game_reset_current_room :: proc(state: ^Game_State) {
    room := game_room(state.current_room)
    facing := state.player.facing
    state.player = {
        position = room.spawn,
        facing = facing,
        mode = .GROUNDED,
    }
    if game_vector_length(state.player.facing) < 0.001 {
        state.player.facing = {1, 0}
    }
    state.last_safe_position = room.spawn
    game_reset_zombies_in_room(state, state.current_room)
}

game_vector_length :: proc(value: rl.Vector2) -> f32 {
    return math.sqrt(value.x * value.x + value.y * value.y)
}

game_normalize_input :: proc(value: rl.Vector2) -> rl.Vector2 {
    length := game_vector_length(value)
    if length <= 0.00001 {
        return {}
    }
    if length <= 1 {
        return value
    }
    return value / length
}

game_move_towards :: proc(current, target: rl.Vector2, max_delta: f32) -> rl.Vector2 {
    difference := target - current
    distance := game_vector_length(difference)
    if distance <= max_delta || distance <= 0.00001 {
        return target
    }
    return current + difference / distance * max_delta
}

game_rect_overlaps_circle :: proc(
    bounds: Game_Rect,
    center: rl.Vector2,
    radius: f32,
) -> bool {
    nearest_x := clamp(center.x, bounds.min_x, bounds.max_x)
    nearest_z := clamp(center.y, bounds.min_z, bounds.max_z)
    delta_x := center.x - nearest_x
    delta_z := center.y - nearest_z
    return delta_x * delta_x + delta_z * delta_z < radius * radius
}

game_position_inside_room_radius :: proc(
    room_id: Game_Room_ID,
    position: rl.Vector3,
    radius: f32,
) -> bool {
    bounds := game_room(room_id).bounds
    return position.x >= bounds.min_x + radius &&
           position.x <= bounds.max_x - radius &&
           position.z >= bounds.min_z + radius &&
           position.z <= bounds.max_z - radius
}

game_position_hits_obstacle_radius :: proc(
    room_id: Game_Room_ID,
    position: rl.Vector3,
    radius: f32,
) -> bool {
    center := rl.Vector2{position.x, position.z}
    for obstacle in GAME_OBSTACLES {
        if obstacle.room == room_id &&
           game_rect_overlaps_circle(obstacle.bounds, center, radius) {
            return true
        }
    }
    return false
}

game_position_hits_hazard_radius :: proc(
    room_id: Game_Room_ID,
    position: rl.Vector3,
    radius: f32,
) -> bool {
    center := rl.Vector2{position.x, position.z}
    for hazard in GAME_HAZARDS {
        if hazard.room == room_id &&
           game_rect_overlaps_circle(hazard.bounds, center, radius) {
            return true
        }
    }
    return false
}

game_position_hits_obstacle :: proc(
    room_id: Game_Room_ID,
    position: rl.Vector3,
) -> bool {
    return game_position_hits_obstacle_radius(room_id, position, GAME_PLAYER_RADIUS)
}

game_position_hits_hazard :: proc(
    room_id: Game_Room_ID,
    position: rl.Vector3,
) -> bool {
    return game_position_hits_hazard_radius(room_id, position, GAME_PLAYER_RADIUS)
}

game_position_inside_room :: proc(
    room_id: Game_Room_ID,
    position: rl.Vector3,
) -> bool {
    return game_position_inside_room_radius(room_id, position, GAME_PLAYER_RADIUS)
}

game_reset_zombie :: proc(state: ^Game_State, zombie_index: int) {
    spawn := GAME_ZOMBIE_SPAWNS[zombie_index]
    patrol_direction := rl.Vector2{
        spawn.patrol_end.x - spawn.position.x,
        spawn.patrol_end.z - spawn.position.z,
    }
    patrol_direction = game_normalize_input(patrol_direction)
    if game_vector_length(patrol_direction) <= 0.001 {
        patrol_direction = {1, 0}
    }
    state.zombies[zombie_index] = {
        position = spawn.position,
        facing = patrol_direction,
        mode = .SHAMBLING,
        last_known = spawn.position,
        patrol_to_end = true,
    }
}

game_reset_all_zombies :: proc(state: ^Game_State) {
    for zombie_index in 0 ..< GAME_ZOMBIE_COUNT {
        game_reset_zombie(state, zombie_index)
    }
}

game_reset_zombies_in_room :: proc(
    state: ^Game_State,
    room_id: Game_Room_ID,
) {
    for spawn, zombie_index in GAME_ZOMBIE_SPAWNS {
        if spawn.room == room_id {
            game_reset_zombie(state, zombie_index)
        }
    }
}

game_zombie_position_blocked :: proc(
    room_id: Game_Room_ID,
    position: rl.Vector3,
) -> bool {
    return !game_position_inside_room_radius(room_id, position, GAME_ZOMBIE_RADIUS) ||
           game_position_hits_obstacle_radius(room_id, position, GAME_ZOMBIE_RADIUS) ||
           game_position_hits_hazard_radius(room_id, position, GAME_ZOMBIE_RADIUS)
}

game_line_of_sight_clear :: proc(
    room_id: Game_Room_ID,
    start, finish: rl.Vector3,
) -> bool {
    delta := rl.Vector2{finish.x - start.x, finish.z - start.z}
    distance := game_vector_length(delta)
    sample_count := max(int(math.ceil(distance / 0.20)), 1)
    for sample_index in 1 ..< sample_count {
        t := f32(sample_index) / f32(sample_count)
        point := rl.Vector2{start.x + delta.x * t, start.z + delta.y * t}
        for obstacle in GAME_OBSTACLES {
            if obstacle.room == room_id &&
               point.x >= obstacle.bounds.min_x && point.x <= obstacle.bounds.max_x &&
               point.y >= obstacle.bounds.min_z && point.y <= obstacle.bounds.max_z {
                return false
            }
        }
    }
    return true
}

game_zombie_can_see_player :: proc(
    state: ^Game_State,
    zombie: ^Game_Zombie,
) -> bool {
    to_player := rl.Vector2{
        state.player.position.x - zombie.position.x,
        state.player.position.z - zombie.position.z,
    }
    distance := game_vector_length(to_player)
    if distance > GAME_ZOMBIE_SIGHT_RADIUS {
        return false
    }
    direction := game_normalize_input(to_player)
    facing := game_normalize_input(zombie.facing)
    // Close movement is always noticed. Farther away, the zombie has a broad
    // forward field of view so slipping behind one remains useful.
    if distance > 1.5 &&
       facing.x * direction.x + facing.y * direction.y < -0.25 {
        return false
    }
    return game_line_of_sight_clear(
        state.current_room,
        zombie.position,
        state.player.position,
    )
}

game_move_zombie :: proc(
    state: ^Game_State,
    zombie_index: int,
    displacement: rl.Vector2,
) -> bool {
    zombie := &state.zombies[zombie_index]
    room_id := GAME_ZOMBIE_SPAWNS[zombie_index].room
    start := zombie.position
    moved := false

    candidate_x := start
    candidate_x.x += displacement.x
    candidate_x.y = game_room(room_id).floor_y
    if !game_zombie_position_blocked(room_id, candidate_x) {
        zombie.position = candidate_x
        moved = true
    }

    candidate_z := zombie.position
    candidate_z.z += displacement.y
    candidate_z.y = game_room(room_id).floor_y
    if !game_zombie_position_blocked(room_id, candidate_z) {
        zombie.position = candidate_z
        moved = true
    }
    return moved
}

game_zombie_walk_towards :: proc(
    state: ^Game_State,
    zombie_index: int,
    target: rl.Vector3,
    speed, dt: f32,
) -> bool {
    zombie := &state.zombies[zombie_index]
    direction := rl.Vector2{
        target.x - zombie.position.x,
        target.z - zombie.position.z,
    }
    distance := game_vector_length(direction)
    if distance <= 0.0001 {
        return false
    }
    direction /= distance
    zombie.facing = direction
    step := min(speed * dt, distance)
    return game_move_zombie(state, zombie_index, direction * step)
}

game_zombie_hits_player :: proc(
    state: ^Game_State,
    zombie: ^Game_Zombie,
) -> bool {
    if state.player.mode != .GROUNDED {
        return false
    }
    delta_x := state.player.position.x - zombie.position.x
    delta_z := state.player.position.z - zombie.position.z
    hit_radius := GAME_PLAYER_RADIUS + GAME_ZOMBIE_RADIUS
    return delta_x * delta_x + delta_z * delta_z <= hit_radius * hit_radius
}

game_set_zombie_mode :: proc(
    zombie: ^Game_Zombie,
    mode: Game_Zombie_Mode,
) {
    zombie.mode = mode
    zombie.mode_elapsed = 0
}

game_update_zombie :: proc(
    state: ^Game_State,
    zombie_index: int,
    dash_noise: bool,
    dt: f32,
) -> bool {
    spawn := GAME_ZOMBIE_SPAWNS[zombie_index]
    if spawn.room != state.current_room {
        return false
    }
    zombie := &state.zombies[zombie_index]
    if spawn.room == .TEST_PIXEL_SNAP {
        // Keep the diagnostic independent from perception, attacks, and their
        // pose changes. The subject only translates along its authored lane.
        patrol_target := spawn.patrol_end
        if !zombie.patrol_to_end {
            patrol_target = spawn.position
        }
        patrol_delta := rl.Vector2{
            patrol_target.x - zombie.position.x,
            patrol_target.z - zombie.position.z,
        }
        if game_vector_length(patrol_delta) <= 0.0001 {
            zombie.patrol_to_end = !zombie.patrol_to_end
        } else {
            game_zombie_walk_towards(
                state,
                zombie_index,
                patrol_target,
                GAME_PIXEL_SNAP_TEST_SPEED,
                dt,
            )
        }
        return false
    }
    to_player := rl.Vector2{
        state.player.position.x - zombie.position.x,
        state.player.position.z - zombie.position.z,
    }
    player_distance := game_vector_length(to_player)
    sees_player := game_zombie_can_see_player(state, zombie)
    hears_player := dash_noise && player_distance <= GAME_ZOMBIE_HEARING_RADIUS
    if sees_player || hears_player {
        zombie.last_known = state.player.position
        zombie.alert_memory = GAME_ZOMBIE_MEMORY
    } else {
        zombie.alert_memory = max(zombie.alert_memory - dt, 0)
    }

    switch zombie.mode {
    case .SHAMBLING:
        if sees_player || hears_player {
            game_set_zombie_mode(zombie, .CHASING)
            return false
        }
        patrol_target := spawn.patrol_end
        if !zombie.patrol_to_end {
            patrol_target = spawn.position
        }
        patrol_delta := rl.Vector2{
            patrol_target.x - zombie.position.x,
            patrol_target.z - zombie.position.z,
        }
        if game_vector_length(patrol_delta) <= 0.10 {
            zombie.patrol_to_end = !zombie.patrol_to_end
        } else {
            game_zombie_walk_towards(
                state,
                zombie_index,
                patrol_target,
                GAME_ZOMBIE_SHAMBLE_SPEED,
                dt,
            )
        }

    case .CHASING:
        if sees_player && player_distance <= GAME_ZOMBIE_ATTACK_RANGE {
            attack_direction := game_normalize_input(to_player)
            if game_vector_length(attack_direction) <= 0.001 {
                attack_direction = zombie.facing
            }
            zombie.attack_direction = attack_direction
            zombie.facing = attack_direction
            game_set_zombie_mode(zombie, .WINDUP)
            return false
        }
        if zombie.alert_memory <= 0 {
            game_set_zombie_mode(zombie, .SHAMBLING)
            return false
        }
        game_zombie_walk_towards(
            state,
            zombie_index,
            zombie.last_known,
            GAME_ZOMBIE_CHASE_SPEED,
            dt,
        )

    case .WINDUP:
        zombie.mode_elapsed += dt
        if zombie.mode_elapsed + 0.00001 >= GAME_ZOMBIE_WINDUP_TIME {
            game_set_zombie_mode(zombie, .LUNGING)
        }

    case .LUNGING:
        remaining_time := min(dt, GAME_ZOMBIE_LUNGE_TIME - zombie.mode_elapsed)
        distance := GAME_ZOMBIE_LUNGE_SPEED * remaining_time
        step_count := max(int(math.ceil(distance / 0.08)), 1)
        step_distance := distance / f32(step_count)
        if game_zombie_hits_player(state, zombie) {
            return true
        }
        for _ in 0 ..< step_count {
            moved := game_move_zombie(
                state,
                zombie_index,
                zombie.attack_direction * step_distance,
            )
            if game_zombie_hits_player(state, zombie) {
                return true
            }
            if !moved {
                game_set_zombie_mode(zombie, .RECOVERING)
                return false
            }
        }
        zombie.mode_elapsed += remaining_time
        if zombie.mode_elapsed + 0.00001 >= GAME_ZOMBIE_LUNGE_TIME {
            game_set_zombie_mode(zombie, .RECOVERING)
        }

    case .RECOVERING:
        zombie.mode_elapsed += dt
        if zombie.mode_elapsed + 0.00001 >= GAME_ZOMBIE_RECOVERY_TIME {
            if zombie.alert_memory > 0 {
                game_set_zombie_mode(zombie, .CHASING)
            } else {
                game_set_zombie_mode(zombie, .SHAMBLING)
            }
        }
    }
    return false
}

game_update_zombies :: proc(
    state: ^Game_State,
    dash_noise: bool,
    dt: f32,
) -> bool {
    for zombie_index in 0 ..< GAME_ZOMBIE_COUNT {
        if game_update_zombie(state, zombie_index, dash_noise, dt) {
            state.zombie_hits += 1
            game_reset_current_room(state)
            return true
        }
    }
    return false
}

game_exit_contains_crossing :: proc(
    room: ^Game_Room,
    exit: Game_Room_Exit,
    position: rl.Vector3,
) -> bool {
    // Ground movement clamps the player center one radius inside the room.
    // Use that same inset for exits so ordinary movement can actually reach
    // the trigger instead of being stopped just short of it.
    crossing_margin := GAME_PLAYER_RADIUS
    switch exit.side {
    case .NORTH:
        return position.z <= room.bounds.min_z + crossing_margin &&
               math.abs(position.x - exit.span_center) <= exit.half_width
    case .EAST:
        return position.x >= room.bounds.max_x - crossing_margin &&
               math.abs(position.z - exit.span_center) <= exit.half_width
    case .SOUTH:
        return position.z >= room.bounds.max_z - crossing_margin &&
               math.abs(position.x - exit.span_center) <= exit.half_width
    case .WEST:
        return position.x <= room.bounds.min_x + crossing_margin &&
               math.abs(position.z - exit.span_center) <= exit.half_width
    }
    return false
}

game_start_room_transition :: proc(
    state: ^Game_State,
    exit: Game_Room_Exit,
) {
    state.player.mode = .ROOM_TRANSITION
    state.player.velocity = {}
    state.player.transition_from_room = exit.source
    state.player.transition_to_room = exit.target
    state.player.transition_start = state.player.position
    state.player.transition_end = exit.target_position
    state.player.transition_elapsed = 0
    state.player.transition_duration = exit.duration
    state.player.dash_elapsed = 0
    state.player.dash_buffer = 0
}

game_try_start_room_transition :: proc(
    state: ^Game_State,
    position: rl.Vector3,
) -> bool {
    if state.player.exit_reentry_lock > 0 {
        return false
    }
    room := game_room(state.current_room)
    for exit in GAME_EXITS {
        if exit.source == state.current_room &&
           game_exit_contains_crossing(room, exit, position) {
            game_start_room_transition(state, exit)
            return true
        }
    }
    return false
}

game_clamp_to_room :: proc(room_id: Game_Room_ID, position: rl.Vector3) -> rl.Vector3 {
    room := game_room(room_id)
    result := position
    result.x = clamp(
        result.x,
        room.bounds.min_x + GAME_PLAYER_RADIUS,
        room.bounds.max_x - GAME_PLAYER_RADIUS,
    )
    result.z = clamp(
        result.z,
        room.bounds.min_z + GAME_PLAYER_RADIUS,
        room.bounds.max_z - GAME_PLAYER_RADIUS,
    )
    result.y = room.floor_y
    return result
}

game_position_blocked :: proc(
    room_id: Game_Room_ID,
    position: rl.Vector3,
    hazards_block: bool,
) -> bool {
    if !game_position_inside_room(room_id, position) ||
       game_position_hits_obstacle(room_id, position) {
        return true
    }
    return hazards_block && game_position_hits_hazard(room_id, position)
}

game_move_grounded :: proc(
    state: ^Game_State,
    displacement: rl.Vector2,
) {
    start := state.player.position
    combined := start
    combined.x += displacement.x
    combined.z += displacement.y
    if game_try_start_room_transition(state, combined) {
        return
    }

    candidate_x := start
    candidate_x.x += displacement.x
    candidate_x = game_clamp_to_room(state.current_room, candidate_x)
    if !game_position_blocked(state.current_room, candidate_x, true) {
        state.player.position = candidate_x
    }

    candidate_z := state.player.position
    candidate_z.z += displacement.y
    if game_try_start_room_transition(state, candidate_z) {
        return
    }
    candidate_z = game_clamp_to_room(state.current_room, candidate_z)
    if !game_position_blocked(state.current_room, candidate_z, true) {
        state.player.position = candidate_z
    }
}

game_finish_dash :: proc(state: ^Game_State) {
    if game_position_hits_hazard(state.current_room, state.player.position) ||
       !game_position_inside_room(state.current_room, state.player.position) {
        state.player.position = state.player.dash_start
    }
    state.player.position = game_clamp_to_room(
        state.current_room,
        state.player.position,
    )
    state.player.mode = .GROUNDED
    state.player.velocity = {}
    state.player.dash_elapsed = 0
}

game_update_dash :: proc(state: ^Game_State, dt: f32) {
    remaining_time := min(dt, GAME_DASH_DURATION - state.player.dash_elapsed)
    distance := GAME_DASH_SPEED * remaining_time
    step_count := max(int(math.ceil(distance / 0.10)), 1)
    step_distance := distance / f32(step_count)

    for _ in 0 ..< step_count {
        candidate := state.player.position
        candidate.x += state.player.dash_direction.x * step_distance
        candidate.z += state.player.dash_direction.y * step_distance
        if game_try_start_room_transition(state, candidate) {
            return
        }
        if !game_position_inside_room(state.current_room, candidate) ||
           game_position_hits_obstacle(state.current_room, candidate) {
            game_finish_dash(state)
            return
        }
        candidate.y = game_room(state.current_room).floor_y
        state.player.position = candidate
    }

    state.player.dash_elapsed += remaining_time
    if state.player.dash_elapsed + 0.00001 >= GAME_DASH_DURATION {
        game_finish_dash(state)
    }
}

game_update_room_transition :: proc(state: ^Game_State, dt: f32) {
    state.player.transition_elapsed += dt
    normalized_time := clamp(
        state.player.transition_elapsed / state.player.transition_duration,
        f32(0),
        f32(1),
    )
    smooth_time := normalized_time * normalized_time * (3 - 2 * normalized_time)
    state.player.position = state.player.transition_start +
                            (state.player.transition_end -
                             state.player.transition_start) * smooth_time
    if normalized_time < 1 {
        return
    }

    state.current_room = state.player.transition_to_room
    state.player.position = state.player.transition_end
    state.player.mode = .GROUNDED
    state.player.exit_reentry_lock = GAME_EXIT_REENTRY_LOCK
    state.last_safe_position = state.player.position
}

game_update_progress :: proc(state: ^Game_State) {
    if state.current_room == .R05_OVERLOOK {
        delta_x := state.player.position.x - GAME_OVERLOOK_POSITION.x
        delta_z := state.player.position.z - GAME_OVERLOOK_POSITION.z
        if delta_x * delta_x + delta_z * delta_z <= GAME_GOAL_RADIUS * GAME_GOAL_RADIUS {
            state.overlook_reached = true
        }
    }
    if state.overlook_reached &&
       state.current_room == .R00_START_FOREST &&
       state.player.mode == .GROUNDED {
        state.completed = true
    }
}

game_fixed_update :: proc(state: ^Game_State, raw_input: Game_Input, dt: f32) {
    state.tick += 1
    state.elapsed_time += dt
    dash_noise := raw_input.dash_pressed || state.player.mode == .DASHING
    state.player.dash_cooldown = max(state.player.dash_cooldown - dt, 0)
    state.player.exit_reentry_lock = max(state.player.exit_reentry_lock - dt, 0)

    if state.current_room == .TEST_PIXEL_SNAP {
        // T01 removes acceleration, dashes, collisions, AI, and rotation from
        // the visual experiment. Only deterministic sub-pixel translation is
        // allowed to change the two fixed-pose subjects.
        move_input := game_normalize_input(rl.Vector2{raw_input.move.x, 0})
        state.player.facing = {1, 0}
        state.player.velocity = move_input * GAME_PIXEL_SNAP_TEST_SPEED
        game_move_grounded(state, state.player.velocity * dt)
        state.last_safe_position = state.player.position
        game_update_zombies(state, false, dt)
        return
    }

    if raw_input.dash_pressed {
        state.player.dash_buffer = GAME_DASH_BUFFER
    } else {
        state.player.dash_buffer = max(state.player.dash_buffer - dt, 0)
    }

    if state.player.mode == .ROOM_TRANSITION {
        game_update_room_transition(state, dt)
        game_update_progress(state)
        return
    }
    if state.player.mode == .DASHING {
        game_update_dash(state, dt)
        if state.player.mode != .ROOM_TRANSITION {
            game_update_zombies(state, true, dt)
        }
        game_update_progress(state)
        return
    }

    move_input := game_normalize_input(raw_input.move)
    if game_vector_length(move_input) > 0.001 {
        state.player.facing = move_input
    }

    if state.player.dash_buffer > 0 && state.player.dash_cooldown <= 0 {
        dash_direction := move_input
        if game_vector_length(dash_direction) <= 0.001 {
            dash_direction = state.player.facing
        }
        dash_direction = game_normalize_input(dash_direction)
        if game_vector_length(dash_direction) > 0.001 {
            state.player.mode = .DASHING
            state.player.dash_direction = dash_direction
            state.player.dash_start = state.player.position
            state.player.dash_elapsed = 0
            state.player.dash_cooldown = GAME_DASH_COOLDOWN
            state.player.dash_buffer = 0
            state.dash_count += 1
            game_update_dash(state, dt)
            if state.player.mode != .ROOM_TRANSITION {
                game_update_zombies(state, true, dt)
            }
            game_update_progress(state)
            return
        }
    }

    target_velocity := move_input * GAME_MOVE_SPEED
    acceleration := GAME_ACCELERATION
    if game_vector_length(move_input) <= 0.001 {
        acceleration = GAME_DECELERATION
    }
    state.player.velocity = game_move_towards(
        state.player.velocity,
        target_velocity,
        acceleration * dt,
    )
    game_move_grounded(state, state.player.velocity * dt)

    if state.player.mode == .GROUNDED &&
       !game_position_hits_hazard(state.current_room, state.player.position) {
        state.last_safe_position = state.player.position
    }
    game_update_zombies(state, dash_noise, dt)
    game_update_progress(state)
}
