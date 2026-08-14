package main

// Game mode is an isolated traversal prototype. The existing viewer remains
// the default entry path; `--mode game` selects this loop before viewer setup.

import "core:fmt"
import "core:c"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"
import rgl "vendor:raylib/rlgl"

GAME_SCREEN_WIDTH       :: 1280
GAME_SCREEN_HEIGHT      :: 720
GAME_PIXEL_WIDTH        :: 256
GAME_PIXEL_HEIGHT       :: 144
GAME_CAMERA_FOVY        :: f32(8.0)
GAME_CAMERA_SMOOTH_TIME :: f32(0.12)
GAME_CAMERA_LOOK_AHEAD  :: f32(0.7)
GAME_CONNECTION_HEIGHT  :: f32(0.18)
GAME_CONNECTION_LIFT    :: f32(0.015)
GAME_OVERLAY_HEIGHT     :: f32(0.06)
GAME_OVERLAY_EMBED      :: f32(0.01)
GAME_PLAYER_MODEL_PATH  :: "assets/Meshy_AI_lowpoly_man_rigged_biped_Meshy_AI_Meshy_Merged_Animations.glb"
GAME_ZOMBIE_MODEL_PATH  :: "assets/godotman.glb"
GAME_PLAYER_ANIMATION_SAMPLE_COUNT :: c.int(8)
GAME_ZOMBIE_ANIMATION_SAMPLE_COUNT :: c.int(8)
GAME_OCCLUSION_DEBUG_TINT :: rl.Color{255, 96, 200, 255}

Game_Run_Options :: struct {
    start_room:          Game_Room_ID,
    start_room_explicit: bool,
    debug_visible:       bool,
    replay_path:         string,
    capture_tick:        u64,
    capture_tick_set:    bool,
    record_directory:    string,
    video_output:        string,
}

Game_Camera_State :: struct {
    target:      rl.Vector3,
    initialized: bool,
}

Game_Pixel_Snap_Offset :: struct {
    ndc:   rl.Vector2,
    world: rl.Vector3,
}

Game_Imported_Model :: struct {
    model:  rl.Model,
    bounds: rl.BoundingBox,
    valid:  bool,
}

Game_Assets :: struct {
    cube:       rl.Model,
    sphere:     rl.Model,
    cylinder:   rl.Model,
    player:     Game_Imported_Model,
    zombie:     Game_Imported_Model,
    tree:       Game_Imported_Model,
    dead_tree:  Game_Imported_Model,
    trunk:      Game_Imported_Model,
    grass:      Game_Imported_Model,
    animation:  Animation_Playback,
    walk_clip:  c.int,
    run_clip:   c.int,
    active_clip: c.int,
    zombie_animation: Animation_Playback,
    zombie_walk_clip: c.int,
    zombie_idle_clip: c.int,
    zombie_attack_clip: c.int,
    zombie_clips_valid: bool,
    debug_white_texture: rl.Texture2D,
}

game_configure_player_animation :: proc(playback: ^Animation_Playback) {
    playback.sampled_playback = true
    playback.sample_count = GAME_PLAYER_ANIMATION_SAMPLE_COUNT
}

game_configure_zombie_animation :: proc(playback: ^Animation_Playback) {
    playback.sampled_playback = true
    playback.sample_count = GAME_ZOMBIE_ANIMATION_SAMPLE_COUNT
}

Game_Zombie_Animation_Kind :: enum {
    WALKING,
    IDLE,
    ATTACK,
}

game_zombie_animation_kind :: proc(mode: Game_Zombie_Mode) -> Game_Zombie_Animation_Kind {
    switch mode {
    case .SHAMBLING, .CHASING:
        return .WALKING
    case .WINDUP, .LUNGING:
        return .ATTACK
    case .RECOVERING:
        return .IDLE
    }
    return .IDLE
}

Game_Decor_Kind :: enum {
    TREE,
    DEAD_TREE,
    TRUNK,
    GRASS,
    ROCK,
    COLUMN,
}

Game_Decor :: struct {
    kind:     Game_Decor_Kind,
    position: rl.Vector3,
    height:   f32,
    rotation: f32,
    tint:     rl.Color,
}

Game_Screen_Bounds :: struct {
    min:   rl.Vector2,
    max:   rl.Vector2,
    valid: bool,
}

Game_Decor_Occlusion_Query :: struct {
    player_ground: rl.Vector2,
    camera_ground: rl.Vector2,
    decor_center:  rl.Vector2,
    projection:    f32,
    player_bounds: Game_Screen_Bounds,
    decor_bounds:  Game_Screen_Bounds,
    overlap:       Game_Screen_Bounds,
    depth_valid:   bool,
    occluded:      bool,
}

// Isolated from the authored route so visibility changes can be exercised with
// one known occluder and a fixed camera in TEST_OCCLUSION.
GAME_OCCLUSION_TEST_TREE :: Game_Decor{
    .TREE,
    {80, 0, 0},
    4.0,
    0,
    {100, 210, 180, 255},
}

GAME_DECOR := [?]Game_Decor{
    {.DEAD_TREE, {-3.4, 0, 1.1}, 4.5, 18, {224, 118, 154, 255}},
    {.TREE, {-6.2, 0, -3.1}, 4.2, -12, {112, 232, 206, 255}},
    {.TREE, {5.8, 0, 3.2}, 3.8, 24, {86, 214, 191, 255}},
    {.GRASS, {-1.0, 0, -2.8}, 0.7, 0, {184, 245, 132, 255}},
    {.TREE, {12.0, 0, -3.1}, 4.1, 5, {86, 195, 213, 255}},
    {.TREE, {16.5, 0, 3.0}, 4.6, -20, {105, 218, 206, 255}},
    {.TREE, {23.5, 0, -3.0}, 4.0, 11, {79, 184, 205, 255}},
    {.TRUNK, {21.0, 0, 2.5}, 0.7, 74, {241, 146, 119, 255}},
    {.COLUMN, {34.6, 0, -1.4}, 2.4, 0, {190, 176, 238, 255}},
    {.COLUMN, {41.4, 0, 3.1}, 2.1, 0, {151, 189, 232, 255}},
    {.ROCK, {45.0, 0, -5.0}, 1.2, 0, {142, 156, 211, 255}},
    {.GRASS, {31.0, 0, 5.5}, 0.8, 0, {104, 226, 198, 255}},
    {.TREE, {52.0, 0, -5.0}, 4.2, 8, {97, 232, 171, 255}},
    {.TRUNK, {58.0, 0, 0}, 2.4, 22, {236, 133, 121, 255}},
    {.TREE, {64.0, 0, 4.5}, 4.8, -8, {78, 211, 166, 255}},
    {.GRASS, {61.0, 0, -4.8}, 0.9, 0, {211, 242, 108, 255}},
    {.ROCK, {31.6, 1.5, -21.5}, 1.0, 0, {183, 142, 207, 255}},
    {.DEAD_TREE, {44.7, 1.5, -15.7}, 3.8, 35, {235, 118, 149, 255}},
    {.GRASS, {40.5, 1.5, -21.2}, 0.7, 0, {250, 184, 101, 255}},
    {.COLUMN, {14.6, 1.5, -15.4}, 2.2, 0, {218, 161, 205, 255}},
    {.TREE, {22.4, 1.5, -15.2}, 3.6, 16, {117, 221, 196, 255}},
    {.ROCK, {13.3, 1.5, -21.5}, 1.0, 0, {191, 143, 190, 255}},
    {.TRUNK, {-6.8, 0, -18.4}, 3.0, 82, {225, 115, 143, 255}},
    {.TREE, {-9.2, 0, -10.0}, 4.1, 7, {77, 183, 195, 255}},
    {.TREE, {7.0, 0, -8.0}, 4.0, -14, {89, 204, 201, 255}},
    {.GRASS, {1.5, 0, -15.0}, 0.8, 0, {127, 224, 187, 255}},
    GAME_OCCLUSION_TEST_TREE,
}

Game_Floor_Accent :: struct {
    room:   Game_Room_ID,
    bounds: Game_Rect,
    color:  rl.Color,
}

// Bright path fragments give the open floors a readable rhythm and point toward
// exits without changing collision or the authored traversal route.
GAME_FLOOR_ACCENTS := [?]Game_Floor_Accent{
    {.R00_START_FOREST, {-0.8, -0.22, 7.7, 0.22}, {39, 154, 151, 255}},
    {.R00_START_FOREST, {-0.22, -4.8, 0.22, -0.22}, {39, 154, 151, 255}},
    {.R00_START_FOREST, {-1.8, 2.7, -0.8, 3.05}, {215, 70, 130, 255}},
    {.R01_FOREST_PASSAGE, {9.2, -0.24, 26.8, 0.24}, {45, 132, 175, 255}},
    {.R01_FOREST_PASSAGE, {18.0, -2.9, 19.1, -2.55}, {224, 86, 126, 255}},
    {.R02_CENTRAL_RUIN, {28.2, -0.23, 47.8, 0.23}, {93, 93, 175, 255}},
    {.R02_CENTRAL_RUIN, {37.77, -7.8, 38.23, 0.3}, {62, 164, 194, 255}},
    {.R02_CENTRAL_RUIN, {36.2, 4.9, 39.8, 5.25}, {208, 80, 151, 255}},
    {.R03_WIDE_GROVE, {49.2, -0.24, 56.3, 0.24}, {48, 161, 123, 255}},
    {.R03_WIDE_GROVE, {59.8, -4.8, 63.1, -4.45}, {180, 204, 67, 255}},
    {.R04_RAVINE_CROSSING, {37.76, -22.8, 38.24, -18.0}, {189, 65, 133, 255}},
    {.R04_RAVINE_CROSSING, {37.76, -16.95, 38.24, -13.2}, {189, 65, 133, 255}},
    {.R04_RAVINE_CROSSING, {29.2, -20.74, 34.6, -20.26}, {218, 115, 66, 255}},
    {.R05_OVERLOOK, {18.0, -20.74, 24.8, -20.26}, {199, 71, 113, 255}},
    {.R05_OVERLOOK, {17.76, -20.2, 18.24, -18.0}, {230, 132, 70, 255}},
    {.R06_LOWER_TRAIL, {-11.8, -15.76, 9.8, -15.29}, {38, 115, 160, 255}},
    {.R06_LOWER_TRAIL, {-0.24, -15.2, 0.24, -6.2}, {38, 115, 160, 255}},
    {.R06_LOWER_TRAIL, {-9.3, -10.6, -7.8, -10.25}, {177, 65, 153, 255}},
    {.TEST_OCCLUSION, {79.88, -3.7, 80.12, 3.7}, {87, 119, 148, 255}},
    {.TEST_OCCLUSION, {78.6, -0.08, 81.4, 0.08}, {202, 180, 102, 255}},
    // T01 has two isolated motion lanes and stationary crossbars. They make
    // sub-pixel drift visible without adding any animated scenery.
    {.TEST_PIXEL_SNAP, {-7.6, 31.44, 7.6, 31.56}, {69, 198, 211, 255}},
    {.TEST_PIXEL_SNAP, {-7.6, 28.44, 7.6, 28.56}, {231, 91, 155, 255}},
    {.TEST_PIXEL_SNAP, {-4.03, 26.4, -3.97, 33.6}, {83, 109, 132, 255}},
    {.TEST_PIXEL_SNAP, {-0.03, 26.4, 0.03, 33.6}, {112, 129, 145, 255}},
    {.TEST_PIXEL_SNAP, {3.97, 26.4, 4.03, 33.6}, {83, 109, 132, 255}},
}

GAME_ROOM_WALL_COLORS := [?]rl.Color{
    {38, 59, 100, 255},
    {37, 56, 104, 255},
    {49, 45, 100, 255},
    {35, 68, 91, 255},
    {64, 42, 91, 255},
    {76, 44, 88, 255},
    {31, 45, 84, 255},
    {64, 64, 82, 255},
    {45, 69, 82, 255},
}

GAME_ROOM_OBSTACLE_COLORS := [?]rl.Color{
    {83, 119, 150, 255},
    {73, 113, 155, 255},
    {115, 105, 169, 255},
    {68, 129, 126, 255},
    {147, 91, 146, 255},
    {164, 102, 134, 255},
    {69, 102, 143, 255},
    {118, 118, 136, 255},
    {82, 118, 132, 255},
}

GAME_ROOM_BACKGROUND_COLORS := [?]rl.Color{
    {17, 25, 55, 255},
    {16, 24, 56, 255},
    {21, 20, 58, 255},
    {15, 29, 53, 255},
    {29, 18, 55, 255},
    {38, 21, 55, 255},
    {13, 23, 49, 255},
    {18, 18, 28, 255},
    {12, 24, 31, 255},
}

GAME_ROOM_HUD_ACCENT_COLORS := [?]rl.Color{
    {80, 224, 207, 255},
    {83, 198, 229, 255},
    {151, 145, 235, 255},
    {101, 229, 168, 255},
    {244, 103, 162, 255},
    {255, 143, 142, 255},
    {83, 188, 224, 255},
    {255, 57, 153, 255},
    {103, 226, 218, 255},
}

Game_Renderer :: struct {
    scene_shader:       rl.Shader,
    scene_source:       Preprocessed_Shader_Program_Source,
    scene_bindings:     Cel_Shader_Bindings,
    cel_band_shader:    rl.Shader,
    cel_band_source:    Preprocessed_Shader_Program_Source,
    cel_band_bindings:  Cel_Shader_Bindings,
    downscale_shader:   rl.Shader,
    downscale_source:   Preprocessed_Shader_Source,
    mask_shader:        rl.Shader,
    mask_source:        Preprocessed_Shader_Source,
    outline_shader:     rl.Shader,
    outline_source:     Preprocessed_Shader_Source,
    cel_ramp_texture:   rl.Texture2D,
    scene_target:       rl.RenderTexture2D,
    cel_band_target:    rl.RenderTexture2D,
    downsample_target:  rl.RenderTexture2D,
    coverage_target:    rl.RenderTexture2D,
    outlined_target:    rl.RenderTexture2D,
    composite_target:   rl.RenderTexture2D,
    downscale_source_resolution: c.int,
    downscale_target_resolution: c.int,
    downscale_band_texture:      c.int,
    downscale_cluster_threshold: c.int,
    downscale_rim_samples:       c.int,
    downscale_highlight_samples: c.int,
    mask_source_resolution:      c.int,
    mask_target_resolution:      c.int,
    outline_target_resolution:   c.int,
    outline_coverage_texture:    c.int,
    outline_width:               c.int,
    outline_color:               c.int,
    outline_coverage_threshold:  c.int,
}

game_mode_requested :: proc(arguments: []string) -> bool {
    for argument, index in arguments {
        if argument == "--mode" && index + 1 < len(arguments) {
            return arguments[index + 1] == "game"
        }
    }
    return false
}

parse_game_run_options :: proc(arguments: []string) -> (
    options: Game_Run_Options,
    valid: bool,
    error_argument: string,
) {
    options.start_room = .R00_START_FOREST
    valid = true
    index := 0
    for index < len(arguments) {
        argument := arguments[index]
        index += 1
        if argument == "--game-debug" {
            options.debug_visible = true
            continue
        }
        if argument == "--game-replay" {
            if index >= len(arguments) {
                return options, false, argument
            }
            options.replay_path = arguments[index]
            index += 1
            if len(options.replay_path) == 0 {
                return options, false, argument
            }
            continue
        }
        if argument == "--game-capture-tick" {
            if index >= len(arguments) {
                return options, false, argument
            }
            tick_value := arguments[index]
            index += 1
            parsed_tick, parsed := strconv.parse_int(tick_value)
            if !parsed || parsed_tick <= 0 {
                return options, false, tick_value
            }
            options.capture_tick = u64(parsed_tick)
            options.capture_tick_set = true
            continue
        }
        if argument == "--game-record-dir" {
            if index >= len(arguments) {
                return options, false, argument
            }
            options.record_directory = arguments[index]
            index += 1
            if len(options.record_directory) == 0 {
                return options, false, argument
            }
            continue
        }
        if argument == "--game-video-output" {
            if index >= len(arguments) {
                return options, false, argument
            }
            options.video_output = arguments[index]
            index += 1
            if len(options.video_output) == 0 {
                return options, false, argument
            }
            continue
        }
        if argument != "--game-room" {
            continue
        }
        if index >= len(arguments) {
            return options, false, argument
        }
        room_value := arguments[index]
        index += 1
        parsed_room, found := game_room_from_string(room_value)
        if !found {
            return options, false, room_value
        }
        options.start_room = parsed_room
        options.start_room_explicit = true
    }
    return
}

print_game_usage :: proc() {
    fmt.println("Lab0 traversal prototype")
    fmt.println("")
    fmt.println("  --mode game                 Run the traversal prototype")
    fmt.println("  --game-room <R00..R06|T00|T01>  Start in a room or diagnostic scene")
    fmt.println("  --game-debug                Show collision and camera diagnostics")
    fmt.println("  --game-replay <path>        Drive the 60 Hz simulation from replay JSON")
    fmt.println("  --game-capture-tick <tick>  Capture the exact replay tick (1-based)")
    fmt.println("  --game-record-dir <path>    Export every replay tick as frame-%06d.png")
    fmt.println("  --game-video-output <mp4>   Stream every replay tick through FFmpeg")
    fmt.println("  --capture-case <name>       Capture a deterministic game frame")
    fmt.println("  --capture-output <path>     Select the PNG output path")
    fmt.println("  --capture-target <target>   composite|scene|downsample|coverage-mask")
}

game_load_imported_model :: proc(path: string) -> Game_Imported_Model {
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    model := rl.LoadModel(path_cstr)
    if !is_model_loaded(model) {
        if model.meshCount > 0 || model.materialCount > 0 {
            rl.UnloadModel(model)
        }
        log.warnf("Game asset could not be loaded: %s", path)
        return {}
    }
    return {
        model = model,
        bounds = rl.GetModelBoundingBox(model),
        valid = true,
    }
}

game_unload_imported_model :: proc(asset: ^Game_Imported_Model) {
    if asset.valid && is_model_loaded(asset.model) {
        rl.UnloadModel(asset.model)
    }
    asset^ = {}
}

game_find_animation_clip :: proc(
    playback: ^Animation_Playback,
    requested_name: string,
) -> c.int {
    for valid_index, playback_index in playback.valid_indices {
        animation := playback.animations[valid_index]
        animation_name := string(cstring(&animation.name[0]))
        if strings.equal_fold(animation_name, requested_name) {
            return c.int(playback_index)
        }
    }
    return 0
}

game_try_find_animation_clip :: proc(
    playback: ^Animation_Playback,
    requested_name: string,
) -> (clip: c.int, found: bool) {
    for valid_index, playback_index in playback.valid_indices {
        animation := playback.animations[valid_index]
        animation_name := string(cstring(&animation.name[0]))
        if strings.equal_fold(animation_name, requested_name) {
            return c.int(playback_index), true
        }
    }
    return 0, false
}

game_load_assets :: proc() -> Game_Assets {
    assets: Game_Assets
    assets.cube = rl.LoadModelFromMesh(rl.GenMeshCube(1, 1, 1))
    assets.sphere = rl.LoadModelFromMesh(rl.GenMeshSphere(0.5, 12, 12))
    assets.cylinder = rl.LoadModelFromMesh(rl.GenMeshCylinder(0.5, 1, 12))
    assets.player = game_load_imported_model(GAME_PLAYER_MODEL_PATH)
    assets.zombie = game_load_imported_model(GAME_ZOMBIE_MODEL_PATH)
    assets.tree = game_load_imported_model("assets/tree_1.glb")
    assets.dead_tree = game_load_imported_model("assets/dead_tree_1.glb")
    assets.trunk = game_load_imported_model("assets/trunk_1.glb")
    assets.grass = game_load_imported_model("assets/grass_1.glb")
    white_image := rl.GenImageColor(1, 1, rl.WHITE)
    assets.debug_white_texture = rl.LoadTextureFromImage(white_image)
    rl.UnloadImage(white_image)

    if assets.player.valid {
        assets.animation = load_animation_playback(
            assets.player.model,
            GAME_PLAYER_MODEL_PATH,
            .ASSET,
        )
        game_configure_player_animation(&assets.animation)
        assets.walk_clip = game_find_animation_clip(&assets.animation, "Walking")
        assets.run_clip = game_find_animation_clip(&assets.animation, "Running")
        assets.active_clip = -1
    }
    if assets.zombie.valid {
        assets.zombie_animation = load_animation_playback(
            assets.zombie.model,
            GAME_ZOMBIE_MODEL_PATH,
            .ASSET,
        )
        game_configure_zombie_animation(&assets.zombie_animation)
        attack_found, idle_found, walk_found: bool
        assets.zombie_attack_clip, attack_found = game_try_find_animation_clip(
            &assets.zombie_animation,
            "attack",
        )
        assets.zombie_idle_clip, idle_found = game_try_find_animation_clip(
            &assets.zombie_animation,
            "idle",
        )
        assets.zombie_walk_clip, walk_found = game_try_find_animation_clip(
            &assets.zombie_animation,
            "walking",
        )
        if !walk_found {
            // GodotMan currently names its locomotion clip "run". At the
            // shamble speed it serves as the temporary zombie walk cycle.
            assets.zombie_walk_clip, walk_found = game_try_find_animation_clip(
                &assets.zombie_animation,
                "run",
            )
        }
        assets.zombie_clips_valid = attack_found && idle_found && walk_found
        if !assets.zombie_clips_valid {
            log.warn("GodotMan is missing a required attack, idle, or walking/run clip")
        }
    }
    return assets
}

game_unload_assets :: proc(assets: ^Game_Assets) {
    destroy_animation_playback(&assets.animation)
    destroy_animation_playback(&assets.zombie_animation)
    game_unload_imported_model(&assets.player)
    game_unload_imported_model(&assets.zombie)
    game_unload_imported_model(&assets.tree)
    game_unload_imported_model(&assets.dead_tree)
    game_unload_imported_model(&assets.trunk)
    game_unload_imported_model(&assets.grass)
    if is_model_loaded(assets.cube) { rl.UnloadModel(assets.cube) }
    if is_model_loaded(assets.sphere) { rl.UnloadModel(assets.sphere) }
    if is_model_loaded(assets.cylinder) { rl.UnloadModel(assets.cylinder) }
    if rl.IsTextureValid(assets.debug_white_texture) {
        rl.UnloadTexture(assets.debug_white_texture)
    }
    assets^ = {}
}

game_prepare_model_shader :: proc(
    model: ^rl.Model,
    shader: rl.Shader,
    cel_ramp: rl.Texture2D,
) {
    if !is_model_loaded(model^) {
        return
    }
    for material_index := 0; material_index < int(model.materialCount); material_index += 1 {
        model.materials[material_index].shader = shader
        model.materials[material_index].maps[rl.MaterialMapIndex.EMISSION].texture = cel_ramp
    }
}

game_prepare_assets_shader :: proc(
    assets: ^Game_Assets,
    shader: rl.Shader,
    cel_ramp: rl.Texture2D,
) {
    game_prepare_model_shader(&assets.cube, shader, cel_ramp)
    game_prepare_model_shader(&assets.sphere, shader, cel_ramp)
    game_prepare_model_shader(&assets.cylinder, shader, cel_ramp)
    if assets.player.valid { game_prepare_model_shader(&assets.player.model, shader, cel_ramp) }
    if assets.zombie.valid { game_prepare_model_shader(&assets.zombie.model, shader, cel_ramp) }
    if assets.tree.valid { game_prepare_model_shader(&assets.tree.model, shader, cel_ramp) }
    if assets.dead_tree.valid { game_prepare_model_shader(&assets.dead_tree.model, shader, cel_ramp) }
    if assets.trunk.valid { game_prepare_model_shader(&assets.trunk.model, shader, cel_ramp) }
    if assets.grass.valid { game_prepare_model_shader(&assets.grass.model, shader, cel_ramp) }
}

game_imported_scale :: proc(asset: ^Game_Imported_Model, target_height: f32) -> f32 {
    if !asset.valid {
        return 1
    }
    source_height := asset.bounds.max.y - asset.bounds.min.y
    if source_height <= 0.0001 {
        return 1
    }
    return target_height / source_height
}

game_draw_imported :: proc(
    asset: ^Game_Imported_Model,
    position: rl.Vector3,
    target_height, rotation: f32,
    tint: rl.Color,
) {
    if !asset.valid {
        return
    }
    scale := game_imported_scale(asset, target_height)
    draw_position := position
    draw_position.y -= asset.bounds.min.y * scale
    rl.DrawModelEx(
        asset.model,
        draw_position,
        {0, 1, 0},
        rotation,
        {scale, scale, scale},
        tint,
    )
}

game_draw_imported_debug_tint :: proc(
    asset: ^Game_Imported_Model,
    position: rl.Vector3,
    target_height, rotation: f32,
    tint: rl.Color,
    white_texture: rl.Texture2D,
) {
    if !asset.valid || !rl.IsTextureValid(white_texture) {
        game_draw_imported(asset, position, target_height, rotation, tint)
        return
    }

    // DrawModelEx multiplies its tint by each material's albedo texture. Keep
    // the original maps, substitute white only for this diagnostic draw, then
    // restore them immediately so normal rendering is untouched.
    material_count := int(asset.model.materialCount)
    original_albedos := make(
        []rl.MaterialMap,
        material_count,
        context.temp_allocator,
    )
    for material_index := 0; material_index < material_count; material_index += 1 {
        albedo := &asset.model.materials[material_index].maps[rl.MaterialMapIndex.ALBEDO]
        original_albedos[material_index] = albedo^
        albedo.texture = white_texture
        albedo.color = rl.WHITE
    }

    game_draw_imported(asset, position, target_height, rotation, tint)

    for material_index := 0; material_index < material_count; material_index += 1 {
        asset.model.materials[material_index].maps[rl.MaterialMapIndex.ALBEDO] =
            original_albedos[material_index]
    }
}

game_renderer_init :: proc(renderer: ^Game_Renderer, style: ^Cel_Style) -> bool {
    scene_loaded: bool
    renderer.scene_shader, renderer.scene_source, scene_loaded =
        load_shader_with_includes(VS_PATH, FS_PATH)
    if !scene_loaded {
        log.error("Failed to load the game scene shader")
        return false
    }
    renderer.scene_bindings = resolve_cel_shader_bindings(renderer.scene_shader)

    band_loaded: bool
    renderer.cel_band_shader, renderer.cel_band_source, band_loaded =
        load_shader_with_includes(VS_PATH, CEL_BAND_FS_PATH)
    if !band_loaded {
        log.error("Failed to load the game cel-band shader")
        return false
    }
    renderer.cel_band_bindings = resolve_cel_shader_bindings(renderer.cel_band_shader)

    downscale_loaded: bool
    renderer.downscale_shader, renderer.downscale_source, downscale_loaded =
        load_fragment_shader_with_includes(DOWNSCALE_FS_PATH)
    if !downscale_loaded {
        log.error("Failed to load the game downscale shader")
        return false
    }

    mask_loaded: bool
    renderer.mask_shader, renderer.mask_source, mask_loaded =
        load_fragment_shader_with_includes(MASK_DOWNSCALE_FS_PATH)
    if !mask_loaded {
        log.error("Failed to load the game coverage shader")
        return false
    }

    outline_loaded: bool
    renderer.outline_shader, renderer.outline_source, outline_loaded =
        load_fragment_shader_with_includes(OUTLINE_FS_PATH)
    if !outline_loaded {
        log.error("Failed to load the game outline shader")
        return false
    }

    ramp_pixels := build_cel_ramp_pixels(style)
    ramp_image := rl.Image{
        data = raw_data(ramp_pixels[:]),
        width = CEL_RAMP_WIDTH,
        height = 1,
        mipmaps = 1,
        format = .UNCOMPRESSED_R8G8B8A8,
    }
    renderer.cel_ramp_texture = rl.LoadTextureFromImage(ramp_image)
    if !rl.IsTextureValid(renderer.cel_ramp_texture) {
        log.error("Failed to create the game cel ramp")
        return false
    }
    rl.SetTextureFilter(renderer.cel_ramp_texture, .POINT)
    rl.SetTextureWrap(renderer.cel_ramp_texture, .CLAMP)

    renderer.scene_target = rl.LoadRenderTexture(GAME_SCREEN_WIDTH, GAME_SCREEN_HEIGHT)
    renderer.cel_band_target = rl.LoadRenderTexture(GAME_SCREEN_WIDTH, GAME_SCREEN_HEIGHT)
    renderer.downsample_target = rl.LoadRenderTexture(GAME_PIXEL_WIDTH, GAME_PIXEL_HEIGHT)
    renderer.coverage_target = rl.LoadRenderTexture(GAME_PIXEL_WIDTH, GAME_PIXEL_HEIGHT)
    renderer.outlined_target = rl.LoadRenderTexture(GAME_PIXEL_WIDTH, GAME_PIXEL_HEIGHT)
    renderer.composite_target = rl.LoadRenderTexture(GAME_SCREEN_WIDTH, GAME_SCREEN_HEIGHT)
    if !rl.IsRenderTextureValid(renderer.scene_target) ||
       !rl.IsRenderTextureValid(renderer.cel_band_target) ||
       !rl.IsRenderTextureValid(renderer.downsample_target) ||
       !rl.IsRenderTextureValid(renderer.coverage_target) ||
       !rl.IsRenderTextureValid(renderer.outlined_target) ||
       !rl.IsRenderTextureValid(renderer.composite_target) {
        log.error("Failed to create one or more game render targets")
        return false
    }

    rl.SetTextureFilter(renderer.cel_band_target.texture, .POINT)
    rl.SetTextureWrap(renderer.cel_band_target.texture, .CLAMP)
    rl.SetTextureFilter(renderer.downsample_target.texture, .POINT)
    rl.SetTextureFilter(renderer.coverage_target.texture, .POINT)
    rl.SetTextureFilter(renderer.outlined_target.texture, .POINT)
    rl.SetTextureFilter(renderer.composite_target.texture, .POINT)

    renderer.downscale_source_resolution = rl.GetShaderLocation(
        renderer.downscale_shader,
        "u_source_resolution",
    )
    renderer.downscale_target_resolution = rl.GetShaderLocation(
        renderer.downscale_shader,
        "u_target_resolution",
    )
    renderer.downscale_band_texture = rl.GetShaderLocation(
        renderer.downscale_shader,
        "u_cel_band_texture",
    )
    renderer.downscale_cluster_threshold = rl.GetShaderLocation(
        renderer.downscale_shader,
        "u_color_cluster_threshold",
    )
    renderer.downscale_rim_samples = rl.GetShaderLocation(
        renderer.downscale_shader,
        "u_rim_preserve_samples",
    )
    renderer.downscale_highlight_samples = rl.GetShaderLocation(
        renderer.downscale_shader,
        "u_highlight_preserve_samples",
    )
    renderer.mask_source_resolution = rl.GetShaderLocation(
        renderer.mask_shader,
        "u_source_resolution",
    )
    renderer.mask_target_resolution = rl.GetShaderLocation(
        renderer.mask_shader,
        "u_target_resolution",
    )
    renderer.outline_target_resolution = rl.GetShaderLocation(
        renderer.outline_shader,
        "u_target_resolution",
    )
    renderer.outline_coverage_texture = rl.GetShaderLocation(
        renderer.outline_shader,
        "u_coverage_texture",
    )
    renderer.outline_width = rl.GetShaderLocation(
        renderer.outline_shader,
        "u_outline_width",
    )
    renderer.outline_color = rl.GetShaderLocation(
        renderer.outline_shader,
        "u_outline_color",
    )
    renderer.outline_coverage_threshold = rl.GetShaderLocation(
        renderer.outline_shader,
        "u_coverage_threshold",
    )
    return true
}

game_renderer_destroy :: proc(renderer: ^Game_Renderer) {
    if rl.IsRenderTextureValid(renderer.composite_target) {
        rl.UnloadRenderTexture(renderer.composite_target)
    }
    if rl.IsRenderTextureValid(renderer.outlined_target) {
        rl.UnloadRenderTexture(renderer.outlined_target)
    }
    if rl.IsRenderTextureValid(renderer.coverage_target) {
        rl.UnloadRenderTexture(renderer.coverage_target)
    }
    if rl.IsRenderTextureValid(renderer.downsample_target) {
        rl.UnloadRenderTexture(renderer.downsample_target)
    }
    if rl.IsRenderTextureValid(renderer.cel_band_target) {
        rl.UnloadRenderTexture(renderer.cel_band_target)
    }
    if rl.IsRenderTextureValid(renderer.scene_target) {
        rl.UnloadRenderTexture(renderer.scene_target)
    }
    if rl.IsTextureValid(renderer.cel_ramp_texture) {
        rl.UnloadTexture(renderer.cel_ramp_texture)
    }
    if rl.IsShaderValid(renderer.outline_shader) { rl.UnloadShader(renderer.outline_shader) }
    if rl.IsShaderValid(renderer.mask_shader) { rl.UnloadShader(renderer.mask_shader) }
    if rl.IsShaderValid(renderer.downscale_shader) { rl.UnloadShader(renderer.downscale_shader) }
    if rl.IsShaderValid(renderer.cel_band_shader) { rl.UnloadShader(renderer.cel_band_shader) }
    if rl.IsShaderValid(renderer.scene_shader) { rl.UnloadShader(renderer.scene_shader) }
    destroy_preprocessed_shader_source(&renderer.outline_source)
    destroy_preprocessed_shader_source(&renderer.mask_source)
    destroy_preprocessed_shader_source(&renderer.downscale_source)
    destroy_preprocessed_shader_program_source(&renderer.cel_band_source)
    destroy_preprocessed_shader_program_source(&renderer.scene_source)
    renderer^ = {}
}

game_room_center :: proc(room_id: Game_Room_ID) -> rl.Vector3 {
    room := game_room(room_id)
    return {
        (room.bounds.min_x + room.bounds.max_x) * 0.5,
        room.floor_y + 0.65,
        (room.bounds.min_z + room.bounds.max_z) * 0.5,
    }
}

game_camera_desired_target :: proc(
    camera_state: ^Game_Camera_State,
    state: ^Game_State,
    move_input: rl.Vector2,
) -> rl.Vector3 {
    room := game_room(state.current_room)
    desired := game_room_center(state.current_room)
    if room.camera_follow {
        if camera_state.initialized {
            desired = camera_state.target
        }
        focus_x := state.player.position.x + move_input.x * GAME_CAMERA_LOOK_AHEAD
        focus_z := state.player.position.z + move_input.y * GAME_CAMERA_LOOK_AHEAD
        deadzone_half_x := GAME_CAMERA_FOVY * (16.0 / 9.0) * 0.07
        deadzone_half_z := GAME_CAMERA_FOVY * 0.05
        if focus_x < desired.x - deadzone_half_x {
            desired.x = focus_x + deadzone_half_x
        } else if focus_x > desired.x + deadzone_half_x {
            desired.x = focus_x - deadzone_half_x
        }
        if focus_z < desired.z - deadzone_half_z {
            desired.z = focus_z + deadzone_half_z
        } else if focus_z > desired.z + deadzone_half_z {
            desired.z = focus_z - deadzone_half_z
        }
        desired.x = clamp(desired.x, room.bounds.min_x + 4.2, room.bounds.max_x - 4.2)
        desired.z = clamp(desired.z, room.bounds.min_z + 3.0, room.bounds.max_z - 3.0)
        desired.y = room.floor_y + 0.65
    }
    if state.player.mode == .ROOM_TRANSITION {
        progress := clamp(
            state.player.transition_elapsed / state.player.transition_duration,
            f32(0),
            f32(1),
        )
        smooth := progress * progress * (3 - 2 * progress)
        from_target := game_room_center(state.player.transition_from_room)
        to_target := game_room_center(state.player.transition_to_room)
        desired = from_target + (to_target - from_target) * smooth
    }
    return desired
}

game_update_camera :: proc(
    camera_state: ^Game_Camera_State,
    state: ^Game_State,
    move_input: rl.Vector2,
    dt: f32,
) -> rl.Camera3D {
    desired := game_camera_desired_target(camera_state, state, move_input)
    if !camera_state.initialized {
        camera_state.target = desired
        camera_state.initialized = true
    } else {
        smoothing := f32(1) - math.exp(-dt / GAME_CAMERA_SMOOTH_TIME)
        camera_state.target += (desired - camera_state.target) * smoothing
    }

    camera := rl.Camera3D{
        target = camera_state.target,
        position = camera_state.target + rl.Vector3{0, 10, 7.8},
        up = {0, 1, 0},
        fovy = GAME_CAMERA_FOVY,
        projection = .ORTHOGRAPHIC,
    }

    // Snap in camera-plane coordinates around a stable world origin. The
    // simulation remains sub-pixel; only the render camera is quantized.
    world_units_per_pixel := camera.fovy / f32(GAME_PIXEL_HEIGHT)
    forward := rl.GetCameraForward(&camera)
    right := rl.GetCameraRight(&camera)
    up := rl.Vector3Normalize(rl.Vector3CrossProduct(right, forward))
    horizontal := rl.Vector3DotProduct(camera.target, right)
    vertical := rl.Vector3DotProduct(camera.target, up)
    snapped_horizontal := math.round(horizontal / world_units_per_pixel) * world_units_per_pixel
    snapped_vertical := math.round(vertical / world_units_per_pixel) * world_units_per_pixel
    correction := right * (snapped_horizontal - horizontal) +
                  up * (snapped_vertical - vertical)
    camera.target += correction
    camera.position += correction
    return camera
}

game_pixel_snap_offset :: proc(
    anchor: rl.Vector3,
    camera: rl.Camera3D,
) -> Game_Pixel_Snap_Offset {
    if camera.projection != .ORTHOGRAPHIC || camera.fovy <= 0 {
        return {}
    }

    // Quantize one entity anchor in the same camera plane and logical pixel
    // units used by the render camera. The returned translation is shared by
    // every draw that composes the entity, preserving its rigid silhouette.
    world_units_per_pixel := camera.fovy / f32(GAME_PIXEL_HEIGHT)
    render_camera := camera
    forward := rl.GetCameraForward(&render_camera)
    right := rl.GetCameraRight(&render_camera)
    up := rl.Vector3Normalize(rl.Vector3CrossProduct(right, forward))
    horizontal_pixels := rl.Vector3DotProduct(anchor, right) / world_units_per_pixel
    vertical_pixels := rl.Vector3DotProduct(anchor, up) / world_units_per_pixel
    snapped_horizontal := math.floor(horizontal_pixels + 0.5)
    snapped_vertical := math.floor(vertical_pixels + 0.5)
    horizontal_delta := snapped_horizontal - horizontal_pixels
    vertical_delta := snapped_vertical - vertical_pixels
    return {
        ndc = {
            horizontal_delta * 2 / f32(GAME_PIXEL_WIDTH),
            vertical_delta * 2 / f32(GAME_PIXEL_HEIGHT),
        },
        world = right * (horizontal_delta * world_units_per_pixel) +
                up * (vertical_delta * world_units_per_pixel),
    }
}

game_room_opening :: proc(
    room_id: Game_Room_ID,
    side: Game_Exit_Side,
) -> (center, half_width: f32, found: bool) {
    for exit in GAME_EXITS {
        if exit.source == room_id && exit.side == side {
            return exit.span_center, exit.half_width, true
        }
        if exit.target != room_id {
            continue
        }
        target_side := Game_Exit_Side.NORTH
        switch exit.side {
        case .NORTH: target_side = .SOUTH
        case .EAST:  target_side = .WEST
        case .SOUTH: target_side = .NORTH
        case .WEST:  target_side = .EAST
        }
        if target_side != side {
            continue
        }
        if side == .NORTH || side == .SOUTH {
            return exit.target_position.x, exit.half_width, true
        }
        return exit.target_position.z, exit.half_width, true
    }
    return 0, 0, false
}

game_draw_wall_piece :: proc(
    cube: rl.Model,
    center: rl.Vector3,
    size: rl.Vector3,
    tint: rl.Color,
) {
    if size.x <= 0.01 || size.z <= 0.01 {
        return
    }
    rl.DrawModelEx(cube, center, {0, 1, 0}, 0, size, tint)
}

game_draw_room_walls :: proc(assets: ^Game_Assets, room: ^Game_Room) {
    wall_color := GAME_ROOM_WALL_COLORS[int(room.id)]
    wall_height: f32 = 0.55
    wall_thickness: f32 = 0.35
    wall_y := room.floor_y + wall_height * 0.5

    for side in Game_Exit_Side {
        opening_center, opening_half, opening_found := game_room_opening(room.id, side)
        if side == .NORTH || side == .SOUTH {
            z := room.bounds.min_z
            if side == .SOUTH { z = room.bounds.max_z }
            if !opening_found {
                game_draw_wall_piece(
                    assets.cube,
                    {(room.bounds.min_x + room.bounds.max_x) * 0.5, wall_y, z},
                    {room.bounds.max_x - room.bounds.min_x, wall_height, wall_thickness},
                    wall_color,
                )
                continue
            }
            left_length := opening_center - opening_half - room.bounds.min_x
            right_start := opening_center + opening_half
            right_length := room.bounds.max_x - right_start
            game_draw_wall_piece(
                assets.cube,
                {room.bounds.min_x + left_length * 0.5, wall_y, z},
                {left_length, wall_height, wall_thickness},
                wall_color,
            )
            game_draw_wall_piece(
                assets.cube,
                {right_start + right_length * 0.5, wall_y, z},
                {right_length, wall_height, wall_thickness},
                wall_color,
            )
        } else {
            x := room.bounds.min_x
            if side == .EAST { x = room.bounds.max_x }
            if !opening_found {
                game_draw_wall_piece(
                    assets.cube,
                    {x, wall_y, (room.bounds.min_z + room.bounds.max_z) * 0.5},
                    {wall_thickness, wall_height, room.bounds.max_z - room.bounds.min_z},
                    wall_color,
                )
                continue
            }
            near_length := opening_center - opening_half - room.bounds.min_z
            far_start := opening_center + opening_half
            far_length := room.bounds.max_z - far_start
            game_draw_wall_piece(
                assets.cube,
                {x, wall_y, room.bounds.min_z + near_length * 0.5},
                {wall_thickness, wall_height, near_length},
                wall_color,
            )
            game_draw_wall_piece(
                assets.cube,
                {x, wall_y, far_start + far_length * 0.5},
                {wall_thickness, wall_height, far_length},
                wall_color,
            )
        }
    }
}

game_exit_boundary_position :: proc(exit: Game_Room_Exit) -> rl.Vector3 {
    room := game_room(exit.source)
    result: rl.Vector3
    result.y = room.floor_y
    switch exit.side {
    case .NORTH:
        result = {exit.span_center, room.floor_y, room.bounds.min_z}
    case .EAST:
        result = {room.bounds.max_x, room.floor_y, exit.span_center}
    case .SOUTH:
        result = {exit.span_center, room.floor_y, room.bounds.max_z}
    case .WEST:
        result = {room.bounds.min_x, room.floor_y, exit.span_center}
    }
    return result
}

game_exit_target_boundary_position :: proc(exit: Game_Room_Exit) -> rl.Vector3 {
    room := game_room(exit.target)
    result := exit.target_position
    result.y = room.floor_y
    switch exit.side {
    case .NORTH:
        result.z = room.bounds.max_z
    case .EAST:
        result.x = room.bounds.min_x
    case .SOUTH:
        result.z = room.bounds.min_z
    case .WEST:
        result.x = room.bounds.max_x
    }
    return result
}

game_draw_connections :: proc(assets: ^Game_Assets) {
    connection_color := rl.Color{103, 119, 178, 255}
    for exit in GAME_EXITS {
        // Reciprocal exits share one physical connector.
        if int(exit.source) > int(exit.target) && !exit.one_way_drop {
            continue
        }
        start := game_exit_boundary_position(exit)
        // Transition destinations sit inside the target room so the player
        // clears its trigger. Rendering stops at the target boundary instead,
        // keeping the connector from overlapping the room floor.
        end := game_exit_target_boundary_position(exit)
        delta := end - start
        horizontal_distance := math.sqrt(delta.x * delta.x + delta.z * delta.z)
        step_count := max(int(math.ceil(horizontal_distance / 0.65)), 1)
        for step_index := 0; step_index < step_count; step_index += 1 {
            t := (f32(step_index) + 0.5) / f32(step_count)
            center := start + delta * t
            // Butt segments edge-to-edge. The old overlap made adjacent top
            // faces coplanar and could flicker even away from room floors.
            segment_length := horizontal_distance / f32(step_count)
            size := rl.Vector3{2.8, GAME_CONNECTION_HEIGHT, segment_length}
            if math.abs(delta.x) > math.abs(delta.z) {
                size = {segment_length, GAME_CONNECTION_HEIGHT, 2.8}
            }
            // Keep the connector top visibly above the interpolated floor.
            // It previously landed exactly on the room floor and produced a
            // true coplanar depth conflict where the pieces overlapped.
            center.y += GAME_CONNECTION_LIFT - GAME_CONNECTION_HEIGHT * 0.5
            rl.DrawModelEx(assets.cube, center, {0, 1, 0}, 0, size, connection_color)
        }
    }
}

game_draw_fallback_tree :: proc(
    assets: ^Game_Assets,
    position: rl.Vector3,
    height: f32,
    tint: rl.Color,
) {
    trunk_height := height * 0.55
    rl.DrawModelEx(
        assets.cylinder,
        position,
        {0, 1, 0},
        0,
        {0.38, trunk_height, 0.38},
        {112, 87, 58, 255},
    )
    rl.DrawModelEx(
        assets.sphere,
        position + rl.Vector3{0, height * 0.78, 0},
        {0, 1, 0},
        0,
        {height * 0.58, height * 0.72, height * 0.58},
        tint,
    )
}

game_project_local_bounds :: proc(
    bounds: rl.BoundingBox,
    position, scale: rl.Vector3,
    rotation: f32,
    camera: rl.Camera3D,
) -> Game_Screen_Bounds {
    result: Game_Screen_Bounds
    radians := rotation * f32(math.PI / 180.0)
    cosine := math.cos(radians)
    sine := math.sin(radians)

    for corner_index := 0; corner_index < 8; corner_index += 1 {
        local := rl.Vector3{bounds.min.x, bounds.min.y, bounds.min.z}
        if corner_index & 1 != 0 { local.x = bounds.max.x }
        if corner_index & 2 != 0 { local.y = bounds.max.y }
        if corner_index & 4 != 0 { local.z = bounds.max.z }
        scaled := rl.Vector3{
            local.x * scale.x,
            local.y * scale.y,
            local.z * scale.z,
        }
        world := position + rl.Vector3{
            scaled.x * cosine + scaled.z * sine,
            scaled.y,
            -scaled.x * sine + scaled.z * cosine,
        }
        screen := rl.GetWorldToScreenEx(
            world,
            camera,
            GAME_SCREEN_WIDTH,
            GAME_SCREEN_HEIGHT,
        )
        if !result.valid {
            result.min = screen
            result.max = screen
            result.valid = true
        } else {
            result.min.x = min(result.min.x, screen.x)
            result.min.y = min(result.min.y, screen.y)
            result.max.x = max(result.max.x, screen.x)
            result.max.y = max(result.max.y, screen.y)
        }
    }
    return result
}

game_project_imported_bounds :: proc(
    asset: ^Game_Imported_Model,
    position: rl.Vector3,
    target_height, rotation: f32,
    camera: rl.Camera3D,
) -> Game_Screen_Bounds {
    if !asset.valid {
        return {}
    }
    scale := game_imported_scale(asset, target_height)
    draw_position := position
    draw_position.y -= asset.bounds.min.y * scale
    return game_project_local_bounds(
        asset.bounds,
        draw_position,
        {scale, scale, scale},
        rotation,
        camera,
    )
}

game_screen_bounds_intersection :: proc(
    first, second: Game_Screen_Bounds,
) -> Game_Screen_Bounds {
    if !first.valid || !second.valid {
        return {}
    }
    result := Game_Screen_Bounds{
        min = {max(first.min.x, second.min.x), max(first.min.y, second.min.y)},
        max = {min(first.max.x, second.max.x), min(first.max.y, second.max.y)},
        valid = true,
    }
    if result.min.x >= result.max.x || result.min.y >= result.max.y {
        return {}
    }
    return result
}

game_player_screen_bounds :: proc(
    assets: ^Game_Assets,
    state: ^Game_State,
    camera: rl.Camera3D,
) -> Game_Screen_Bounds {
    facing := state.player.facing
    rotation := f32(math.atan2(f64(facing.x), f64(facing.y)) * 180.0 / math.PI)
    if assets.player.valid {
        return game_project_imported_bounds(
            &assets.player,
            state.player.position,
            1.7,
            rotation,
            camera,
        )
    }
    fallback_bounds := rl.BoundingBox{
        min = {-0.32, 0, -0.32},
        max = {0.32, 2.0, 0.32},
    }
    return game_project_local_bounds(
        fallback_bounds,
        state.player.position,
        {1, 1, 1},
        rotation,
        camera,
    )
}

game_decor_screen_bounds :: proc(
    assets: ^Game_Assets,
    decor: Game_Decor,
    camera: rl.Camera3D,
) -> Game_Screen_Bounds {
    #partial switch decor.kind {
    case .TREE:
        if assets.tree.valid {
            return game_project_imported_bounds(
                &assets.tree,
                decor.position,
                decor.height,
                decor.rotation,
                camera,
            )
        }
        fallback_bounds := rl.BoundingBox{
            min = {-0.5, 0, -0.5},
            max = {0.5, 1.14, 0.5},
        }
        return game_project_local_bounds(
            fallback_bounds,
            decor.position,
            {decor.height * 0.58, decor.height, decor.height * 0.58},
            decor.rotation,
            camera,
        )
    case .DEAD_TREE:
        if assets.dead_tree.valid {
            return game_project_imported_bounds(
                &assets.dead_tree,
                decor.position,
                decor.height,
                decor.rotation,
                camera,
            )
        }
        fallback_bounds := rl.BoundingBox{
            min = {-0.5, 0, -0.5},
            max = {0.5, 1, 0.5},
        }
        return game_project_local_bounds(
            fallback_bounds,
            decor.position,
            {0.45, decor.height, 0.45},
            decor.rotation,
            camera,
        )
    case .COLUMN:
        cube_bounds := rl.BoundingBox{
            min = {-0.5, -0.5, -0.5},
            max = {0.5, 0.5, 0.5},
        }
        return game_project_local_bounds(
            cube_bounds,
            decor.position + rl.Vector3{0, decor.height * 0.5, 0},
            {0.75, decor.height, 0.75},
            decor.rotation,
            camera,
        )
    }
    return {}
}

game_decor_occlusion_query :: proc(
    assets: ^Game_Assets,
    decor: Game_Decor,
    state: ^Game_State,
    camera: rl.Camera3D,
) -> Game_Decor_Occlusion_Query {
    query := Game_Decor_Occlusion_Query{
        player_ground = {state.player.position.x, state.player.position.z},
        camera_ground = {camera.position.x, camera.position.z},
        decor_center = {decor.position.x, decor.position.z},
        player_bounds = game_player_screen_bounds(assets, state, camera),
        decor_bounds = game_decor_screen_bounds(assets, decor, camera),
    }
    query.overlap = game_screen_bounds_intersection(
        query.player_bounds,
        query.decor_bounds,
    )
    if decor.kind != .TREE && decor.kind != .DEAD_TREE && decor.kind != .COLUMN {
        return query
    }
    sight_line := query.camera_ground - query.player_ground
    line_length_squared := sight_line.x * sight_line.x + sight_line.y * sight_line.y
    if line_length_squared <= 0.0001 {
        return query
    }
    to_decor := query.decor_center - query.player_ground
    query.projection = clamp(
        (to_decor.x * sight_line.x + to_decor.y * sight_line.y) /
        line_length_squared,
        f32(0),
        f32(1),
    )
    if query.projection <= 0.04 || query.projection >= 0.96 {
        return query
    }
    query.depth_valid = true
    query.occluded = query.overlap.valid
    return query
}

game_decor_occludes_player :: proc(
    assets: ^Game_Assets,
    decor: Game_Decor,
    state: ^Game_State,
    camera: rl.Camera3D,
) -> bool {
    return game_decor_occlusion_query(assets, decor, state, camera).occluded
}

game_decor_visibility_tint :: proc(
    assets: ^Game_Assets,
    decor: Game_Decor,
    state: ^Game_State,
    camera: rl.Camera3D,
) -> rl.Color {
    if game_decor_occludes_player(assets, decor, state, camera) {
        return GAME_OCCLUSION_DEBUG_TINT
    }
    return decor.tint
}

game_draw_decor :: proc(
    assets: ^Game_Assets,
    state: ^Game_State,
    camera: rl.Camera3D,
) {
    for decor in GAME_DECOR {
        // Make the visibility detector observable without changing geometry or
        // collision: any decor currently classified as a player occluder is
        // rendered hot pink for this frame.
        occluded := game_decor_occludes_player(assets, decor, state, camera)
        tint := decor.tint
        if occluded { tint = GAME_OCCLUSION_DEBUG_TINT }
        switch decor.kind {
        case .TREE:
            if assets.tree.valid {
                if occluded {
                    game_draw_imported_debug_tint(
                        &assets.tree,
                        decor.position,
                        decor.height,
                        decor.rotation,
                        tint,
                        assets.debug_white_texture,
                    )
                } else {
                    game_draw_imported(&assets.tree, decor.position, decor.height, decor.rotation, tint)
                }
            } else {
                game_draw_fallback_tree(assets, decor.position, decor.height, tint)
            }
        case .DEAD_TREE:
            if assets.dead_tree.valid {
                if occluded {
                    game_draw_imported_debug_tint(
                        &assets.dead_tree,
                        decor.position,
                        decor.height,
                        decor.rotation,
                        tint,
                        assets.debug_white_texture,
                    )
                } else {
                    game_draw_imported(&assets.dead_tree, decor.position, decor.height, decor.rotation, tint)
                }
            } else {
                rl.DrawModelEx(
                    assets.cylinder,
                    decor.position,
                    {0, 1, 0},
                    0,
                    {0.45, decor.height, 0.45},
                    tint,
                )
            }
        case .TRUNK:
            if assets.trunk.valid {
                game_draw_imported(&assets.trunk, decor.position, decor.height, decor.rotation, tint)
            } else {
                rl.DrawModelEx(
                    assets.cylinder,
                    decor.position + rl.Vector3{0, 0.35, 0},
                    {0, 0, 1},
                    90,
                    {0.55, decor.height, 0.55},
                    tint,
                )
            }
        case .GRASS:
            if assets.grass.valid {
                game_draw_imported(&assets.grass, decor.position, decor.height, decor.rotation, tint)
            } else {
                rl.DrawModelEx(
                    assets.sphere,
                    decor.position + rl.Vector3{0, decor.height * 0.3, 0},
                    {0, 1, 0},
                    0,
                    {decor.height, decor.height * 0.6, decor.height},
                    tint,
                )
            }
        case .ROCK:
            rl.DrawModelEx(
                assets.sphere,
                decor.position + rl.Vector3{0, decor.height * 0.35, 0},
                {0, 1, 0},
                decor.rotation,
                {decor.height, decor.height * 0.7, decor.height * 0.85},
                tint,
            )
        case .COLUMN:
            rl.DrawModelEx(
                assets.cube,
                decor.position + rl.Vector3{0, decor.height * 0.5, 0},
                {0, 1, 0},
                decor.rotation,
                {0.75, decor.height, 0.75},
                tint,
            )
        }
    }

    beacon_pulse := f32(1) + f32(math.sin(f64(state.elapsed_time * 3.2))) * 0.08
    rl.DrawModelEx(
        assets.cylinder,
        GAME_OVERLOOK_POSITION - rl.Vector3{0, 0.55, 0},
        {0, 1, 0},
        0,
        {0.36, 1.0, 0.36},
        {228, 92, 158, 255},
    )
    rl.DrawModelEx(
        assets.sphere,
        GAME_OVERLOOK_POSITION,
        {0, 1, 0},
        0,
        {beacon_pulse, beacon_pulse, beacon_pulse},
        {104, 244, 239, 255},
    )
}

game_draw_floor_accents :: proc(assets: ^Game_Assets) {
    for accent in GAME_FLOOR_ACCENTS {
        room := game_room(accent.room)
        center := rl.Vector3{
            (accent.bounds.min_x + accent.bounds.max_x) * 0.5,
            room.floor_y + GAME_OVERLAY_HEIGHT * 0.5 - GAME_OVERLAY_EMBED,
            (accent.bounds.min_z + accent.bounds.max_z) * 0.5,
        }
        size := rl.Vector3{
            accent.bounds.max_x - accent.bounds.min_x,
            GAME_OVERLAY_HEIGHT,
            accent.bounds.max_z - accent.bounds.min_z,
        }
        rl.DrawModelEx(assets.cube, center, {0, 1, 0}, 0, size, accent.color)
    }
}

game_draw_obstacle_markers :: proc(assets: ^Game_Assets) {
    for obstacle in GAME_OBSTACLES {
        room := game_room(obstacle.room)
        center := rl.Vector3{
            (obstacle.bounds.min_x + obstacle.bounds.max_x) * 0.5,
            room.floor_y + 0.18,
            (obstacle.bounds.min_z + obstacle.bounds.max_z) * 0.5,
        }
        size := rl.Vector3{
            obstacle.bounds.max_x - obstacle.bounds.min_x,
            0.36,
            obstacle.bounds.max_z - obstacle.bounds.min_z,
        }
        rl.DrawModelEx(
            assets.sphere,
            center,
            {0, 1, 0},
            0,
            size,
            GAME_ROOM_OBSTACLE_COLORS[int(obstacle.room)],
        )
    }
}

game_draw_player :: proc(assets: ^Game_Assets, state: ^Game_State) {
    facing := state.player.facing
    rotation := f32(math.atan2(f64(facing.x), f64(facing.y)) * 180.0 / math.PI)
    marker_color := rl.Color{20, 24, 58, 255}
    marker_scale := rl.Vector3{0.82, 0.055, 0.58}
    if state.player.mode == .DASHING {
        marker_color = {77, 235, 229, 255}
        marker_scale = {1.08, 0.065, 0.66}
    }
    rl.DrawModelEx(
        assets.sphere,
        state.player.position + rl.Vector3{0, 0.035, 0},
        {0, 1, 0},
        rotation,
        marker_scale,
        marker_color,
    )
    if assets.player.valid {
        game_draw_imported(
            &assets.player,
            state.player.position,
            1.7,
            rotation,
            rl.WHITE,
        )
        return
    }
    player_color := rl.Color{214, 222, 207, 255}
    if state.player.mode == .DASHING {
        player_color = {226, 248, 225, 255}
    }
    rl.DrawModelEx(
        assets.cylinder,
        state.player.position,
        {0, 1, 0},
        0,
        {0.55, 1.25, 0.55},
        player_color,
    )
    rl.DrawModelEx(
        assets.sphere,
        state.player.position + rl.Vector3{0, 1.45, 0},
        {0, 1, 0},
        0,
        {0.55, 0.55, 0.55},
        player_color,
    )
}

game_draw_particles :: proc(assets: ^Game_Assets, state: ^Game_State) {
    for particle in state.particle_system.particles {
        if !particle.active || particle.lifetime <= 0 {
            continue
        }
        lifetime_fraction := clamp(particle.age / particle.lifetime, f32(0), f32(1))
        visibility_scale: f32 = 1
        if lifetime_fraction > 0.68 {
            visibility_scale = (1 - lifetime_fraction) / 0.32
        }
        size := particle.start_size * max(visibility_scale, f32(0.08))
        rl.DrawModelEx(
            assets.cube,
            particle.position,
            {0, 1, 0},
            0,
            {size, size * 0.72, size},
            particle.color,
        )
    }
}

game_zombie_mode_label :: proc(mode: Game_Zombie_Mode) -> cstring {
    switch mode {
    case .SHAMBLING:  return "SHAMBLING"
    case .CHASING:    return "CHASING"
    case .WINDUP:     return "WINDUP"
    case .LUNGING:    return "LUNGING"
    case .RECOVERING: return "RECOVERING"
    }
    return "UNKNOWN"
}

game_zombie_count_in_room :: proc(room_id: Game_Room_ID) -> int {
    count := 0
    for spawn in GAME_ZOMBIE_SPAWNS {
        if spawn.room == room_id {
            count += 1
        }
    }
    return count
}

game_apply_zombie_animation :: proc(
    assets: ^Game_Assets,
    state: ^Game_State,
    zombie_index: int,
) {
    if !assets.zombie.valid ||
       !assets.zombie_clips_valid ||
       !has_playable_animations(&assets.zombie_animation) {
        return
    }

    zombie := &state.zombies[zombie_index]
    animation_kind := game_zombie_animation_kind(zombie.mode)
    desired_clip := assets.zombie_idle_clip
    switch animation_kind {
    case .WALKING: desired_clip = assets.zombie_walk_clip
    case .IDLE:    desired_clip = assets.zombie_idle_clip
    case .ATTACK:  desired_clip = assets.zombie_attack_clip
    }
    assets.zombie_animation.active_index = desired_clip
    animation, found := get_active_animation(&assets.zombie_animation)
    if !found {
        return
    }

    last_frame := f32(max(animation.keyframeCount - 1, 0))
    frame: f32
    if state.current_room != .TEST_PIXEL_SNAP && last_frame > 0 {
        switch animation_kind {
        case .WALKING:
            playback_speed: f32 = 0.52
            if zombie.mode == .CHASING {
                playback_speed = 1.05
            }
            frame = math.mod(
                state.elapsed_time * ANIMATION_SAMPLE_FPS * playback_speed +
                    f32(zombie_index) * 7.0,
                last_frame,
            )
        case .IDLE:
            frame = math.mod(
                state.elapsed_time * ANIMATION_SAMPLE_FPS * 0.38 +
                    f32(zombie_index) * 5.0,
                last_frame,
            )
        case .ATTACK:
            attack_elapsed := zombie.mode_elapsed
            if zombie.mode == .LUNGING {
                attack_elapsed += GAME_ZOMBIE_WINDUP_TIME
            }
            attack_duration := GAME_ZOMBIE_WINDUP_TIME + GAME_ZOMBIE_LUNGE_TIME
            attack_progress := clamp(attack_elapsed / attack_duration, f32(0), f32(1))
            frame = attack_progress * last_frame
        }
    }

    assets.zombie_animation.current_frame = frame
    pose_frame := get_animation_pose_frame(&assets.zombie_animation, animation)
    // All zombies share one animated model. Upload each deterministic pose
    // immediately before its draw so every instance can show its own state.
    rl.UpdateModelAnimation(assets.zombie.model, animation, pose_frame)
    assets.zombie_animation.applied_frame = pose_frame
}

game_draw_zombie :: proc(
    assets: ^Game_Assets,
    state: ^Game_State,
    zombie_index: int,
) {
    zombie := &state.zombies[zombie_index]
    facing := game_normalize_input(zombie.facing)
    if game_vector_length(facing) <= 0.001 {
        facing = {0, 1}
    }
    side := rl.Vector2{-facing.y, facing.x}
    rotation := f32(math.atan2(f64(facing.x), f64(facing.y)) * 180.0 / math.PI)

    skin_color := rl.Color{139, 178, 111, 255}
    shirt_color := rl.Color{75, 75, 111, 255}
    marker_color := rl.Color{27, 31, 52, 255}
    eye_color := rl.Color{241, 86, 119, 255}
    lean: f32
    height_offset: f32
    arm_reach: f32 = 0.28
    switch zombie.mode {
    case .SHAMBLING:
        sway := f32(math.sin(f64(state.elapsed_time * 7.0 + f32(zombie_index) * 1.9)))
        lean = sway * 0.035
        arm_reach = 0.22 + sway * 0.04
    case .CHASING:
        skin_color = {167, 197, 104, 255}
        shirt_color = {91, 66, 112, 255}
        marker_color = {103, 112, 58, 255}
        lean = 0.09
        arm_reach = 0.38
    case .WINDUP:
        skin_color = {225, 188, 83, 255}
        shirt_color = {116, 60, 105, 255}
        marker_color = {244, 91, 145, 255}
        eye_color = {255, 225, 127, 255}
        lean = -0.16
        height_offset = 0.06
        arm_reach = 0.08
    case .LUNGING:
        skin_color = {231, 118, 82, 255}
        shirt_color = {126, 47, 83, 255}
        marker_color = {255, 129, 78, 255}
        eye_color = {255, 236, 183, 255}
        lean = 0.24
        height_offset = -0.18
        arm_reach = 0.55
    case .RECOVERING:
        skin_color = {116, 145, 111, 255}
        shirt_color = {61, 55, 91, 255}
        marker_color = {72, 58, 91, 255}
        lean = 0.13
        height_offset = -0.14
        arm_reach = 0.46
    }

    if zombie.mode == .WINDUP || zombie.mode == .LUNGING {
        telegraph_length: f32 = 1.65
        if zombie.mode == .LUNGING {
            telegraph_length = 1.15
        }
        telegraph_center := zombie.position + rl.Vector3{
            facing.x * telegraph_length * 0.5,
            0.025,
            facing.y * telegraph_length * 0.5,
        }
        rl.DrawModelEx(
            assets.cube,
            telegraph_center,
            {0, 1, 0},
            rotation,
            {0.24, 0.045, telegraph_length},
            marker_color,
        )
    }

    body_offset := rl.Vector3{facing.x * lean, 0, facing.y * lean}
    rl.DrawModelEx(
        assets.sphere,
        zombie.position + rl.Vector3{0, 0.03, 0},
        {0, 1, 0},
        rotation,
        {0.82, 0.055, 0.62},
        marker_color,
    )

    if assets.zombie.valid && assets.zombie_clips_valid {
        zombie_tint := rl.Color{178, 214, 162, 255}
        switch zombie.mode {
        case .SHAMBLING:  zombie_tint = {178, 214, 162, 255}
        case .CHASING:    zombie_tint = {205, 227, 154, 255}
        case .WINDUP:     zombie_tint = {255, 211, 127, 255}
        case .LUNGING:    zombie_tint = {255, 151, 112, 255}
        case .RECOVERING: zombie_tint = {148, 170, 158, 255}
        }
        game_apply_zombie_animation(assets, state, zombie_index)
        game_draw_imported(
            &assets.zombie,
            zombie.position,
            1.68,
            rotation,
            zombie_tint,
        )
        return
    }

    side_signs := [2]f32{-1, 1}
    leg_height := f32(0.58)
    for side_sign in side_signs {
        leg_position := zombie.position + rl.Vector3{
            side.x * side_sign * 0.13,
            leg_height * 0.5,
            side.y * side_sign * 0.13,
        }
        rl.DrawModelEx(
            assets.cylinder,
            leg_position,
            {0, 1, 0},
            rotation,
            {0.34, leg_height, 0.34},
            {46, 49, 74, 255},
        )
    }

    body_position := zombie.position + body_offset + rl.Vector3{0, 0.91 + height_offset, 0}
    rl.DrawModelEx(
        assets.cylinder,
        body_position,
        {0, 1, 0},
        rotation,
        {0.72, 0.88, 0.58},
        shirt_color,
    )

    for side_sign in side_signs {
        arm_center := zombie.position + body_offset + rl.Vector3{
            side.x * side_sign * 0.29 + facing.x * arm_reach,
            1.10 + height_offset,
            side.y * side_sign * 0.29 + facing.y * arm_reach,
        }
        rl.DrawModelEx(
            assets.cube,
            arm_center,
            {0, 1, 0},
            rotation,
            {0.15, 0.15, 0.68},
            skin_color,
        )
    }

    head_position := zombie.position + body_offset + rl.Vector3{
        facing.x * 0.05,
        1.52 + height_offset,
        facing.y * 0.05,
    }
    rl.DrawModelEx(
        assets.sphere,
        head_position,
        {0, 1, 0},
        rotation,
        {0.58, 0.58, 0.54},
        skin_color,
    )
    for side_sign in side_signs {
        eye_position := head_position + rl.Vector3{
            facing.x * 0.26 + side.x * side_sign * 0.105,
            0.035,
            facing.y * 0.26 + side.y * side_sign * 0.105,
        }
        rl.DrawModelEx(
            assets.sphere,
            eye_position,
            {0, 1, 0},
            rotation,
            {0.13, 0.13, 0.09},
            eye_color,
        )
    }
}

game_set_pixel_snap_offset :: proc(
    shader: rl.Shader,
    bindings: ^Cel_Shader_Bindings,
    offset: Game_Pixel_Snap_Offset,
) {
    snap_offset := offset
    rl.SetShaderValue(
        shader,
        bindings.pixel_snap_ndc_offset,
        &snap_offset.ndc,
        .VEC2,
    )
    rl.SetShaderValue(
        shader,
        bindings.pixel_snap_world_offset,
        &snap_offset.world,
        .VEC3,
    )
}

game_draw_zombies :: proc(
    assets: ^Game_Assets,
    state: ^Game_State,
    shader: rl.Shader,
    bindings: ^Cel_Shader_Bindings,
    camera: rl.Camera3D,
) {
    for spawn, zombie_index in GAME_ZOMBIE_SPAWNS {
        if spawn.room == state.current_room {
            game_set_pixel_snap_offset(
                shader,
                bindings,
                game_pixel_snap_offset(state.zombies[zombie_index].position, camera),
            )
            game_draw_zombie(assets, state, zombie_index)
        }
    }
    game_set_pixel_snap_offset(shader, bindings, {})
}

game_set_cel_accents_enabled :: proc(
    shader: rl.Shader,
    bindings: ^Cel_Shader_Bindings,
    rim_enabled, highlight_enabled: bool,
) {
    rim_value := c.int(0)
    if rim_enabled { rim_value = 1 }
    highlight_value := c.int(0)
    if highlight_enabled { highlight_value = 1 }
    rl.SetShaderValue(shader, bindings.rim_enabled, &rim_value, .INT)
    rl.SetShaderValue(shader, bindings.highlight_enabled, &highlight_value, .INT)
}

game_draw_world :: proc(
    assets: ^Game_Assets,
    state: ^Game_State,
    shader: rl.Shader,
    bindings: ^Cel_Shader_Bindings,
    cel_ramp: rl.Texture2D,
    style: ^Cel_Style,
    camera: rl.Camera3D,
) {
    game_prepare_assets_shader(assets, shader, cel_ramp)
    game_set_pixel_snap_offset(shader, bindings, {})

    // View-dependent rim/highlight thresholds can divide a large flat floor
    // into hard regions that resemble z-fighting. Terrain has its own authored
    // colors, so render it with stable diffuse bands and reserve accents for
    // walls, props, and the player.
    game_set_cel_accents_enabled(shader, bindings, false, false)
    for &room in GAME_ROOMS {
        center := rl.Vector3{
            (room.bounds.min_x + room.bounds.max_x) * 0.5,
            room.floor_y - 0.12,
            (room.bounds.min_z + room.bounds.max_z) * 0.5,
        }
        size := rl.Vector3{
            room.bounds.max_x - room.bounds.min_x,
            0.24,
            room.bounds.max_z - room.bounds.min_z,
        }
        rl.DrawModelEx(assets.cube, center, {0, 1, 0}, 0, size, room.color)
    }
    game_draw_connections(assets)
    game_draw_floor_accents(assets)

    for hazard in GAME_HAZARDS {
        room := game_room(hazard.room)
        center := rl.Vector3{
            (hazard.bounds.min_x + hazard.bounds.max_x) * 0.5,
            room.floor_y + GAME_OVERLAY_HEIGHT * 0.5 - GAME_OVERLAY_EMBED,
            (hazard.bounds.min_z + hazard.bounds.max_z) * 0.5,
        }
        size := rl.Vector3{
            hazard.bounds.max_x - hazard.bounds.min_x,
            GAME_OVERLAY_HEIGHT,
            hazard.bounds.max_z - hazard.bounds.min_z,
        }
        rl.DrawModelEx(assets.cube, center, {0, 1, 0}, 0, size, {13, 17, 43, 255})
        warning_size := rl.Vector3{size.x, 0.07, 0.12}
        rl.DrawModelEx(
            assets.cube,
            {center.x, room.floor_y + 0.04, hazard.bounds.min_z + 0.06},
            {0, 1, 0},
            0,
            warning_size,
            {241, 77, 139, 255},
        )
        rl.DrawModelEx(
            assets.cube,
            {center.x, room.floor_y + 0.04, hazard.bounds.max_z - 0.06},
            {0, 1, 0},
            0,
            warning_size,
            {92, 225, 230, 255},
        )
    }

    game_set_cel_accents_enabled(
        shader,
        bindings,
        style.rim.enabled,
        style.highlight.enabled,
    )
    for &room in GAME_ROOMS {
        game_draw_room_walls(assets, &room)
    }
    game_draw_obstacle_markers(assets)
    game_draw_decor(assets, state, camera)
    game_draw_zombies(assets, state, shader, bindings, camera)
    game_draw_particles(assets, state)
    game_set_pixel_snap_offset(
        shader,
        bindings,
        game_pixel_snap_offset(state.player.position, camera),
    )
    game_draw_player(assets, state)
    game_set_pixel_snap_offset(shader, bindings, {})
}

game_update_player_animation :: proc(
    assets: ^Game_Assets,
    state: ^Game_State,
    simulated_dt: f32,
) {
    if !assets.player.valid || !has_playable_animations(&assets.animation) {
        return
    }
    desired_clip := assets.walk_clip
    fixed_pose := state.current_room == .TEST_PIXEL_SNAP
    moving := !fixed_pose && game_vector_length(state.player.velocity) > 0.08
    speed: f32 = max(game_vector_length(state.player.velocity) / GAME_MOVE_SPEED, 0.65)
    if !fixed_pose && state.player.mode == .DASHING {
        desired_clip = assets.run_clip
        moving = true
        speed = 1.35
    }
    if assets.active_clip != desired_clip {
        assets.active_clip = desired_clip
        assets.animation.active_index = desired_clip
        assets.animation.current_frame = 0
        assets.animation.applied_frame = -1
    }
    animation, found := get_active_animation(&assets.animation)
    if !found {
        return
    }
    last_frame := f32(max(animation.keyframeCount - 1, 0))
    if moving && last_frame > 0 {
        assets.animation.current_frame += simulated_dt * ANIMATION_SAMPLE_FPS * speed
        if assets.animation.current_frame >= last_frame {
            assets.animation.current_frame = math.mod(assets.animation.current_frame, last_frame)
        }
    } else {
        assets.animation.current_frame = 0
    }
    pose_frame := get_animation_pose_frame(&assets.animation, animation)
    if pose_frame != assets.animation.applied_frame {
        rl.UpdateModelAnimation(
            assets.player.model,
            animation,
            pose_frame,
        )
        assets.animation.applied_frame = pose_frame
    }
}

game_draw_projected_rect :: proc(
    bounds: Game_Rect,
    y: f32,
    camera: rl.Camera3D,
    color: rl.Color,
) {
    points := [4]rl.Vector2{
        rl.GetWorldToScreen({bounds.min_x, y, bounds.min_z}, camera),
        rl.GetWorldToScreen({bounds.max_x, y, bounds.min_z}, camera),
        rl.GetWorldToScreen({bounds.max_x, y, bounds.max_z}, camera),
        rl.GetWorldToScreen({bounds.min_x, y, bounds.max_z}, camera),
    }
    for index := 0; index < 4; index += 1 {
        rl.DrawLineV(points[index], points[(index + 1) % 4], color)
    }
}

game_draw_screen_bounds :: proc(
    bounds: Game_Screen_Bounds,
    thickness: f32,
    color: rl.Color,
) {
    if !bounds.valid {
        return
    }
    rectangle := rl.Rectangle{
        bounds.min.x,
        bounds.min.y,
        bounds.max.x - bounds.min.x,
        bounds.max.y - bounds.min.y,
    }
    rl.DrawRectangleLinesEx(rectangle, thickness, color)
}

game_draw_occlusion_test_overlay :: proc(
    assets: ^Game_Assets,
    state: ^Game_State,
    camera: rl.Camera3D,
) {
    query := game_decor_occlusion_query(
        assets,
        GAME_OCCLUSION_TEST_TREE,
        state,
        camera,
    )
    bound_color := rl.Color{255, 215, 82, 255}
    status: cstring = "OUTSIDE"
    if query.occluded {
        bound_color = GAME_OCCLUSION_DEBUG_TINT
        status = "INSIDE"
    }

    game_draw_screen_bounds(query.decor_bounds, 3, bound_color)
    game_draw_screen_bounds(query.player_bounds, 3, {75, 229, 241, 255})
    if query.overlap.valid {
        overlap_rectangle := rl.Rectangle{
            query.overlap.min.x,
            query.overlap.min.y,
            query.overlap.max.x - query.overlap.min.x,
            query.overlap.max.y - query.overlap.min.y,
        }
        rl.DrawRectangleRec(overlap_rectangle, {255, 255, 255, 48})
        rl.DrawRectangleLinesEx(overlap_rectangle, 2, rl.WHITE)
    }

    ground_y := GAME_OCCLUSION_TEST_TREE.position.y + 0.08
    player_screen := rl.GetWorldToScreen(
        {query.player_ground.x, ground_y, query.player_ground.y},
        camera,
    )
    camera_ground_screen := rl.GetWorldToScreen(
        {query.camera_ground.x, ground_y, query.camera_ground.y},
        camera,
    )
    rl.DrawLineEx(player_screen, camera_ground_screen, 2, {75, 229, 241, 220})

    overlap_width := f32(0)
    overlap_height := f32(0)
    if query.overlap.valid {
        overlap_width = query.overlap.max.x - query.overlap.min.x
        overlap_height = query.overlap.max.y - query.overlap.min.y
    }
    rl.DrawRectangle(900, 16, 364, 78, {12, 14, 38, 224})
    rl.DrawRectangle(900, 16, 5, 78, bound_color)
    rl.DrawText(
        rl.TextFormat("PROJECTED BOUNDS: %s", status),
        916,
        24,
        20,
        bound_color,
    )
    rl.DrawText(
        rl.TextFormat(
            "overlap %.0f x %.0f px   depth t %.3f",
            overlap_width,
            overlap_height,
            query.projection,
        ),
        916,
        49,
        16,
        rl.RAYWHITE,
    )
    rl.DrawText(
        "cyan: player model   yellow/pink: tree model",
        916,
        68,
        14,
        {75, 229, 241, 255},
    )
}

game_draw_debug_overlay :: proc(state: ^Game_State, camera: rl.Camera3D) {
    room := game_room(state.current_room)
    game_draw_projected_rect(room.bounds, room.floor_y + 0.04, camera, rl.YELLOW)
    for obstacle in GAME_OBSTACLES {
        if obstacle.room == state.current_room {
            game_draw_projected_rect(
                obstacle.bounds,
                room.floor_y + 0.48,
                camera,
                rl.RED,
            )
        }
    }
    for hazard in GAME_HAZARDS {
        if hazard.room == state.current_room {
            game_draw_projected_rect(
                hazard.bounds,
                room.floor_y + 0.08,
                camera,
                rl.SKYBLUE,
            )
        }
    }
    for spawn, zombie_index in GAME_ZOMBIE_SPAWNS {
        if spawn.room != state.current_room {
            continue
        }
        zombie := &state.zombies[zombie_index]
        zombie_screen := rl.GetWorldToScreen(
            zombie.position + rl.Vector3{0, 1.8, 0},
            camera,
        )
        debug_color := rl.Color{174, 224, 95, 255}
        if zombie.mode == .WINDUP || zombie.mode == .LUNGING {
            debug_color = {255, 91, 145, 255}
        }
        rl.DrawCircleLines(
            c.int(zombie_screen.x),
            c.int(zombie_screen.y),
            12,
            debug_color,
        )
        rl.DrawText(
            game_zombie_mode_label(zombie.mode),
            c.int(zombie_screen.x) - 42,
            c.int(zombie_screen.y) - 28,
            10,
            debug_color,
        )
    }
    player_screen := rl.GetWorldToScreen(state.player.position, camera)
    rl.DrawCircleLines(c.int(player_screen.x), c.int(player_screen.y), 11, rl.LIME)
    rl.DrawRectangleLines(
        550,
        324,
        179,
        72,
        rl.MAGENTA,
    )
    rl.DrawText(
        rl.TextFormat(
            "pos %.2f %.2f  vel %.2f %.2f  tick %llu",
            state.player.position.x,
            state.player.position.z,
            state.player.velocity.x,
            state.player.velocity.y,
            state.tick,
        ),
        18,
        72,
        18,
        rl.RAYWHITE,
    )
}

game_draw_hud :: proc(
    assets: ^Game_Assets,
    state: ^Game_State,
    camera: rl.Camera3D,
) {
    room := game_room(state.current_room)
    accent := GAME_ROOM_HUD_ACCENT_COLORS[int(state.current_room)]
    if state.current_room == .TEST_OCCLUSION {
        game_draw_occlusion_test_overlay(assets, state, camera)
    }
    rl.DrawRectangle(12, 12, 310, 48, {12, 14, 38, 224})
    rl.DrawRectangle(12, 12, 5, 48, accent)
    room_name := strings.clone_to_cstring(room.name, context.temp_allocator)
    rl.DrawText(room_name, 25, 20, 20, {244, 244, 255, 255})
    objective_text: cstring = "Reach the overlook"
    if state.current_room == .TEST_OCCLUSION {
        if game_decor_occludes_player(
            assets,
            GAME_OCCLUSION_TEST_TREE,
            state,
            camera,
        ) {
            objective_text = "OCCLUDED: tree should be hot pink"
        } else {
            objective_text = "CLEAR: projected model bounds do not overlap"
        }
    } else if state.current_room == .TEST_PIXEL_SNAP {
        objective_text = "FIXED POSE  |  0.25 PIXEL PER TICK"
    } else if state.overlook_reached {
        objective_text = "Return to the start forest"
    }
    rl.DrawText(objective_text, 25, 42, 14, accent)

    zombie_count := game_zombie_count_in_room(state.current_room)
    if zombie_count > 0 {
        threat_panel := rl.Rectangle{1010, 12, 258, 48}
        rl.DrawRectangleRec(threat_panel, {20, 17, 39, 230})
        rl.DrawRectangle(1010, 12, 5, 48, {242, 88, 137, 255})
        rl.DrawText("INFECTED AREA", 1024, 18, 17, {244, 207, 113, 255})
        rl.DrawText(
            rl.TextFormat("Undead %d    Hits %d", zombie_count, state.zombie_hits),
            1024,
            40,
            13,
            {225, 218, 238, 255},
        )
    }

    rl.DrawRectangle(12, GAME_SCREEN_HEIGHT - 34, 420, 22, {12, 14, 38, 205})
    rl.DrawRectangle(12, GAME_SCREEN_HEIGHT - 34, 5, 22, {239, 91, 145, 255})
    controls_text: cstring = "Move: WASD / arrows    Dash: Space    Reset: R    Debug: F3"
    if state.current_room == .TEST_OCCLUSION {
        controls_text = "W/S: cross tree    A/D: sweep projected edge    White: screen overlap"
    } else if state.current_room == .TEST_PIXEL_SNAP {
        controls_text = "T01 diagnostic: translation only, fixed camera and poses"
    }
    rl.DrawText(
        controls_text,
        20,
        GAME_SCREEN_HEIGHT - 30,
        14,
        {221, 224, 247, 255},
    )

    if state.completed {
        panel := rl.Rectangle{390, 274, 500, 172}
        rl.DrawRectangleRec(panel, {14, 12, 42, 242})
        rl.DrawRectangle(390, 274, 500, 7, {83, 226, 220, 255})
        rl.DrawRectangleLinesEx(panel, 2, {241, 93, 151, 255})
        rl.DrawText("TRAVERSAL COMPLETE", 473, 302, 28, {111, 242, 231, 255})
        rl.DrawText(
            rl.TextFormat("Time  %.1fs     Dashes  %d", state.elapsed_time, state.dash_count),
            493,
            350,
            20,
            rl.RAYWHITE,
        )
        rl.DrawText(
            "Keep exploring or press R to reset this room",
            458,
            392,
            16,
            {218, 209, 239, 255},
        )
    }
    if state.debug_visible {
        game_draw_debug_overlay(state, camera)
    }
}

game_renderer_render :: proc(
    renderer: ^Game_Renderer,
    assets: ^Game_Assets,
    state: ^Game_State,
    style: ^Cel_Style,
    camera: rl.Camera3D,
    background_color: rl.Color,
) {
    scene_resolution := [2]f32{GAME_SCREEN_WIDTH, GAME_SCREEN_HEIGHT}
    target_resolution := [2]f32{GAME_PIXEL_WIDTH, GAME_PIXEL_HEIGHT}
    cluster_threshold := f32(DEFAULT_COLOR_CLUSTER_THRESHOLD)
    rim_samples := c.int(style.rim.preserve_samples)
    highlight_samples := c.int(style.highlight.preserve_samples)
    outline_width := c.int(style.outline.width)
    outline_color := [4]f32{
        f32(style.outline.color.r) / 255,
        f32(style.outline.color.g) / 255,
        f32(style.outline.color.b) / 255,
        f32(style.outline.color.a) / 255,
    }

    rl.SetShaderValue(
        renderer.downscale_shader,
        renderer.downscale_source_resolution,
        &scene_resolution,
        .VEC2,
    )
    rl.SetShaderValue(
        renderer.downscale_shader,
        renderer.downscale_target_resolution,
        &target_resolution,
        .VEC2,
    )
    rl.SetShaderValue(
        renderer.downscale_shader,
        renderer.downscale_cluster_threshold,
        &cluster_threshold,
        .FLOAT,
    )
    rl.SetShaderValue(
        renderer.downscale_shader,
        renderer.downscale_rim_samples,
        &rim_samples,
        .INT,
    )
    rl.SetShaderValue(
        renderer.downscale_shader,
        renderer.downscale_highlight_samples,
        &highlight_samples,
        .INT,
    )
    rl.SetShaderValue(
        renderer.mask_shader,
        renderer.mask_source_resolution,
        &scene_resolution,
        .VEC2,
    )
    rl.SetShaderValue(
        renderer.mask_shader,
        renderer.mask_target_resolution,
        &target_resolution,
        .VEC2,
    )
    rl.SetShaderValue(
        renderer.outline_shader,
        renderer.outline_target_resolution,
        &target_resolution,
        .VEC2,
    )
    rl.SetShaderValue(
        renderer.outline_shader,
        renderer.outline_width,
        &outline_width,
        .INT,
    )
    rl.SetShaderValue(
        renderer.outline_shader,
        renderer.outline_color,
        &outline_color,
        .VEC4,
    )
    rl.SetShaderValue(
        renderer.outline_shader,
        renderer.outline_coverage_threshold,
        &style.outline.coverage_threshold,
        .FLOAT,
    )

    rl.BeginTextureMode(renderer.scene_target)
        rl.ClearBackground(rl.BLANK)
        apply_cel_style_to_shader(
            renderer.scene_shader,
            &renderer.scene_bindings,
            style,
            camera,
            rl.Matrix(1),
        )
        rl.BeginMode3D(camera)
            game_draw_world(
                assets,
                state,
                renderer.scene_shader,
                &renderer.scene_bindings,
                renderer.cel_ramp_texture,
                style,
                camera,
            )
        rl.EndMode3D()
    rl.EndTextureMode()

    rl.BeginTextureMode(renderer.cel_band_target)
        rl.ClearBackground(rl.BLANK)
        apply_cel_style_to_shader(
            renderer.cel_band_shader,
            &renderer.cel_band_bindings,
            style,
            camera,
            rl.Matrix(1),
        )
        rl.BeginMode3D(camera)
            game_draw_world(
                assets,
                state,
                renderer.cel_band_shader,
                &renderer.cel_band_bindings,
                renderer.cel_ramp_texture,
                style,
                camera,
            )
        rl.EndMode3D()
    rl.EndTextureMode()

    scene_source := rl.Rectangle{0, 0, GAME_SCREEN_WIDTH, -GAME_SCREEN_HEIGHT}
    rl.BeginTextureMode(renderer.downsample_target)
        rl.ClearBackground(rl.BLANK)
        rl.BeginShaderMode(renderer.downscale_shader)
            rl.SetShaderValueTexture(
                renderer.downscale_shader,
                renderer.downscale_band_texture,
                renderer.cel_band_target.texture,
            )
            rl.DrawTexturePro(
                renderer.scene_target.texture,
                scene_source,
                {0, 0, GAME_PIXEL_WIDTH, GAME_PIXEL_HEIGHT},
                {},
                0,
                rl.WHITE,
            )
        rl.EndShaderMode()
    rl.EndTextureMode()

    rl.BeginTextureMode(renderer.coverage_target)
        rl.ClearBackground(rl.BLANK)
        rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
            rl.BeginShaderMode(renderer.mask_shader)
                rl.DrawTexturePro(
                    renderer.cel_band_target.texture,
                    scene_source,
                    {0, 0, GAME_PIXEL_WIDTH, GAME_PIXEL_HEIGHT},
                    {},
                    0,
                    rl.WHITE,
                )
            rl.EndShaderMode()
        rl.EndBlendMode()
    rl.EndTextureMode()

    pixel_source := rl.Rectangle{0, 0, GAME_PIXEL_WIDTH, -GAME_PIXEL_HEIGHT}
    rl.BeginTextureMode(renderer.outlined_target)
        rl.ClearBackground(rl.BLANK)
        rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
            rl.BeginShaderMode(renderer.outline_shader)
                rl.SetShaderValueTexture(
                    renderer.outline_shader,
                    renderer.outline_coverage_texture,
                    renderer.coverage_target.texture,
                )
                rl.DrawTexturePro(
                    renderer.downsample_target.texture,
                    pixel_source,
                    {0, 0, GAME_PIXEL_WIDTH, GAME_PIXEL_HEIGHT},
                    {},
                    0,
                    rl.WHITE,
                )
            rl.EndShaderMode()
        rl.EndBlendMode()
    rl.EndTextureMode()

    rl.BeginTextureMode(renderer.composite_target)
        rl.ClearBackground(background_color)
        rl.DrawTexturePro(
            renderer.outlined_target.texture,
            pixel_source,
            {0, 0, GAME_SCREEN_WIDTH, GAME_SCREEN_HEIGHT},
            {},
            0,
            rl.WHITE,
        )
        game_draw_hud(assets, state, camera)
    rl.EndTextureMode()
}

game_collect_input :: proc() -> Game_Input {
    input: Game_Input
    if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) { input.move.x += 1 }
    if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)  { input.move.x -= 1 }
    if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)  { input.move.y += 1 }
    if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP)    { input.move.y -= 1 }

    if rl.IsGamepadAvailable(0) {
        stick := rl.Vector2{
            rl.GetGamepadAxisMovement(0, .LEFT_X),
            rl.GetGamepadAxisMovement(0, .LEFT_Y),
        }
        if game_vector_length(stick) >= GAME_GAMEPAD_DEADZONE {
            input.move = stick
        } else {
            if rl.IsGamepadButtonDown(0, .LEFT_FACE_RIGHT) { input.move.x += 1 }
            if rl.IsGamepadButtonDown(0, .LEFT_FACE_LEFT)  { input.move.x -= 1 }
            if rl.IsGamepadButtonDown(0, .LEFT_FACE_DOWN)  { input.move.y += 1 }
            if rl.IsGamepadButtonDown(0, .LEFT_FACE_UP)    { input.move.y -= 1 }
        }
        input.dash_pressed = rl.IsGamepadButtonPressed(0, .RIGHT_FACE_DOWN)
    }
    input.move = game_normalize_input(input.move)
    input.dash_pressed = input.dash_pressed || rl.IsKeyPressed(.SPACE)
    return input
}

game_quit_requested :: proc() -> bool {
    primary_down := rl.IsKeyDown(.LEFT_CONTROL) ||
                    rl.IsKeyDown(.RIGHT_CONTROL) ||
                    rl.IsKeyDown(.LEFT_SUPER) ||
                    rl.IsKeyDown(.RIGHT_SUPER)
    return primary_down && rl.IsKeyPressed(.Q)
}

game_capture_texture :: proc(
    renderer: ^Game_Renderer,
    target: Capture_Target,
) -> rl.Texture2D {
    switch target {
    case .COMPOSITE:
        return renderer.composite_target.texture
    case .SCENE:
        return renderer.scene_target.texture
    case .DOWNSAMPLE:
        return renderer.outlined_target.texture
    case .COVERAGE_MASK:
        return renderer.coverage_target.texture
    case .LENS:
        return {}
    }
    return {}
}

make_game_cel_style :: proc() -> Cel_Style {
    style := make_classic_cel_style()
    style.name = "Neon Twilight"
    style.light_space = .WORLD
    style.light_direction = {-0.35, 0.86, -0.42}
    style.wrap_lighting = 0.10
    style.band_count = 4
    style.bands[0] = {
        upper_bound = 0.22,
        brightness = 0.46,
        tint = {0.10, 0.06, 0.30},
        tint_mix = 0.42,
    }
    style.bands[1] = {
        upper_bound = 0.50,
        brightness = 0.72,
        tint = {0.08, 0.34, 0.50},
        tint_mix = 0.20,
    }
    style.bands[2] = {
        upper_bound = 0.78,
        brightness = 0.88,
        tint = {0.42, 0.86, 0.94},
        tint_mix = 0.05,
    }
    style.bands[3] = {
        brightness = 0.94,
        tint = {1.00, 0.56, 0.72},
        tint_mix = 0.04,
    }
    style.rim = {
        enabled = true,
        color = {0.24, 0.92, 0.96},
        threshold = 0.80,
        strength = 0.18,
        preserve_samples = 2,
    }
    style.highlight = {
        enabled = true,
        color = {1.00, 0.42, 0.62},
        threshold = 0.96,
        strength = 0.12,
        preserve_samples = 1,
    }
    style.outline = {
        width = 1,
        color = {12, 13, 37, 255},
        coverage_threshold = 0.25,
    }
    style.revision += 1
    return style
}

run_game_mode :: proc(arguments: []string) -> int {
    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    run_options, run_options_valid, bad_game_argument := parse_game_run_options(arguments)
    if !run_options_valid {
        log.errorf("Invalid game room or missing value: %s", bad_game_argument)
        print_game_usage()
        return 2
    }

    capture_result := parse_capture_options(arguments)
    defer destroy_capture_options(&capture_result.options)
    if capture_result.options.help_requested {
        print_game_usage()
        fmt.println("")
        print_capture_usage()
        return 0
    }
    if capture_result.error != .NONE {
        log.errorf("Invalid game capture argument: %s", capture_result.error_argument)
        print_game_usage()
        return 2
    }
    capture := &capture_result.options
    if len(capture.video_output) > 0 || capture.video_frame_count > 0 {
        log.error("Viewer video options are available only in Viewer mode")
        return 2
    }
    if capture.enabled &&
       (capture.target == .LENS ||
        capture.frame_range_set ||
        capture.animation_frame_set ||
        capture.view != .DEFAULT ||
        capture.lens_mode != .PIXELATED ||
        len(capture.model_source) > 0) {
        log.error("Game capture supports composite, scene, downsample, or coverage-mask at a fixed room spawn")
        return 2
    }

    replay: Game_Replay
    defer destroy_game_replay(&replay)
    replay_enabled := len(run_options.replay_path) > 0
    if replay_enabled {
        replay_error: Game_Replay_Error
        replay, replay_error = load_game_replay(run_options.replay_path)
        if replay_error != .NONE {
            log.errorf(
                "Failed to load game replay %s: %s",
                run_options.replay_path,
                game_replay_error_message(replay_error),
            )
            return 2
        }
        if run_options.start_room_explicit && run_options.start_room != replay.start_room {
            log.error("--game-room conflicts with the replay start_room")
            return 2
        }
        run_options.start_room = replay.start_room
    }
    if run_options.capture_tick_set {
        if !capture.enabled || !replay_enabled {
            log.error("--game-capture-tick requires --game-replay and --capture-case")
            return 2
        }
        if run_options.capture_tick > replay.total_ticks {
            log.errorf(
                "Game capture tick %d exceeds replay length %d",
                int(run_options.capture_tick),
                int(replay.total_ticks),
            )
            return 2
        }
    }
    recording_enabled := len(run_options.record_directory) > 0
    if recording_enabled {
        if !capture.enabled || !replay_enabled {
            log.error("--game-record-dir requires --game-replay and --capture-case")
            return 2
        }
        if run_options.capture_tick_set {
            log.error("--game-record-dir cannot be combined with --game-capture-tick")
            return 2
        }
    }
    video_enabled := len(run_options.video_output) > 0
    video_options_error := validate_game_video_options(&run_options, capture)
    if video_options_error != .NONE {
        log.error(game_video_options_error_message(video_options_error))
        return 2
    }

    video_encoder: Video_Stream_Encoder
    defer destroy_video_stream_encoder(&video_encoder)
    if video_enabled {
        video_start_error := start_video_stream_encoder(
            &video_encoder,
            run_options.video_output,
            GAME_SCREEN_WIDTH,
            GAME_SCREEN_HEIGHT,
            60,
        )
        if video_start_error == .FFMPEG_NOT_FOUND {
            return 2
        }
        if video_start_error != .NONE {
            return 1
        }
    }

    style := make_game_cel_style()
    defer destroy_cel_style(&style)
    if capture.enabled && len(capture.style_path) > 0 {
        loaded_style, style_error := load_cel_style(capture.style_path)
        if style_error != .NONE {
            log.errorf(
                "Failed to load game capture style %s: %s",
                capture.style_path,
                cel_style_error_message(style_error),
            )
            return 2
        }
        replace_cel_style(&style, loaded_style)
    }
    if style.outline.width == 0 {
        style.outline.width = 1
        style.revision += 1
    }

    if capture.enabled {
        if capture.hide_window {
            rl.SetConfigFlags({.WINDOW_ALWAYS_RUN, .WINDOW_HIDDEN})
        } else {
            rl.SetConfigFlags({.WINDOW_ALWAYS_RUN})
        }
    } else {
        rl.SetConfigFlags({.WINDOW_TOPMOST})
    }
    rl.InitWindow(GAME_SCREEN_WIDTH, GAME_SCREEN_HEIGHT, "Lab0 - Traversal Prototype")
    defer rl.CloseWindow()
    rl.SetExitKey(.KEY_NULL)
    if capture.enabled {
        rl.SetMouseOffset(-100000, -100000)
    }
    rgl.SetClipPlanes(0.001, 1000.0)
    rl.SetTargetFPS(60)

    renderer: Game_Renderer
    if !game_renderer_init(&renderer, &style) {
        game_renderer_destroy(&renderer)
        return 1
    }
    defer game_renderer_destroy(&renderer)

    assets := game_load_assets()
    defer game_unload_assets(&assets)

    state := game_state_init(run_options.start_room)
    state.debug_visible = run_options.debug_visible && !capture.enabled
    camera_state: Game_Camera_State
    camera := game_update_camera(&camera_state, &state, {}, GAME_FIXED_DT)
    accumulator: f32
    pending_dash := false
    capture_frames := 0
    capture_complete := false
    capture_succeeded := false
    recorded_frames := 0
    replay_player: Game_Replay_Player
    replay_complete := false
    background_color := GAME_ROOM_BACKGROUND_COLORS[int(state.current_room)]

    if video_enabled {
        // Warm the normal GPU pipeline before consuming the first replay input.
        // These renders are deliberately not written to the video stream.
        for _ in 0 ..< capture.warmup_frames {
            game_renderer_render(
                &renderer,
                &assets,
                &state,
                &style,
                camera,
                background_color,
            )
        }
    }

    for !rl.WindowShouldClose() && !capture_complete && !replay_complete {
        frame_dt := min(rl.GetFrameTime(), f32(0.25))
        frame_input: Game_Input
        capture_tick_reached := run_options.capture_tick_set &&
                                state.tick >= run_options.capture_tick
        if capture.enabled || replay_enabled {
            frame_dt = GAME_FIXED_DT
        }
        if !capture.enabled && !replay_enabled {
            frame_input = game_collect_input()
            pending_dash = pending_dash || frame_input.dash_pressed
            if rl.IsKeyPressed(.R) ||
               (rl.IsGamepadAvailable(0) &&
                rl.IsGamepadButtonPressed(0, .MIDDLE_LEFT)) {
                game_reset_current_room(&state)
                camera_state.initialized = false
            }
            if rl.IsKeyPressed(.F3) {
                state.debug_visible = !state.debug_visible
            }
            if game_quit_requested() {
                break
            }
        }

        if !capture_tick_reached {
            accumulator += frame_dt
        }
        ticks_run := 0
        for accumulator >= GAME_FIXED_DT && ticks_run < GAME_MAX_FIXED_TICKS {
            tick_input: Game_Input
            if replay_enabled {
                replay_input, replay_has_input := game_replay_next_input(
                    &replay,
                    &replay_player,
                )
                if !replay_has_input {
                    replay_complete = !capture.enabled
                    accumulator = 0
                    break
                }
                tick_input = replay_input
                frame_input = replay_input
            } else {
                tick_input = frame_input
                tick_input.dash_pressed = pending_dash
            }
            game_fixed_update(&state, tick_input, GAME_FIXED_DT)
            pending_dash = false
            accumulator -= GAME_FIXED_DT
            ticks_run += 1
        }
        if ticks_run == GAME_MAX_FIXED_TICKS && accumulator >= GAME_FIXED_DT {
            accumulator = 0
        }
        game_update_player_animation(
            &assets,
            &state,
            f32(ticks_run) * GAME_FIXED_DT,
        )
        camera = game_update_camera(
            &camera_state,
            &state,
            frame_input.move,
            frame_dt,
        )

        if state.completed && !state.completion_reported {
            state.completion_reported = true
            log.infof(
                "Traversal complete in %.2f seconds with %d dashes",
                state.elapsed_time,
                state.dash_count,
            )
        }

        background_color = GAME_ROOM_BACKGROUND_COLORS[int(state.current_room)]

        game_renderer_render(
            &renderer,
            &assets,
            &state,
            &style,
            camera,
            background_color,
        )

        rl.BeginDrawing()
            rl.ClearBackground(background_color)
            rl.DrawTexturePro(
                renderer.composite_target.texture,
                {0, 0, GAME_SCREEN_WIDTH, -GAME_SCREEN_HEIGHT},
                {0, 0, GAME_SCREEN_WIDTH, GAME_SCREEN_HEIGHT},
                {},
                0,
                rl.WHITE,
            )
        rl.EndDrawing()

        if capture.enabled {
            if video_enabled && ticks_run > 0 {
                if ticks_run != 1 {
                    log.errorf(
                        "Game video rendered %d fixed ticks into one frame",
                        ticks_run,
                    )
                    capture_complete = true
                    capture_succeeded = false
                } else if !video_stream_write_render_texture(
                    &video_encoder,
                    renderer.composite_target.texture,
                ) {
                    log.errorf(
                        "Failed to stream game case %s at tick %d",
                        capture.case_name,
                        int(state.tick),
                    )
                    capture_complete = true
                    capture_succeeded = false
                } else if replay_player.ticks_played >= replay.total_ticks {
                    capture_complete = true
                    capture_succeeded = finish_video_stream_encoder(
                        &video_encoder,
                        run_options.video_output,
                        replay.total_ticks,
                        "fixed-tick",
                    )
                }
            } else if recording_enabled && ticks_run > 0 {
                capture_texture := game_capture_texture(&renderer, capture.target)
                frame_path := fmt.aprintf(
                    "%s/frame-%06d.png",
                    run_options.record_directory,
                    int(state.tick),
                )
                frame_succeeded := export_render_texture_png(
                    capture_texture,
                    frame_path,
                )
                delete(frame_path)
                if !frame_succeeded {
                    log.errorf(
                        "Failed to record game case %s at tick %d",
                        capture.case_name,
                        int(state.tick),
                    )
                    capture_complete = true
                    capture_succeeded = false
                } else {
                    recorded_frames += 1
                    if replay_player.ticks_played >= replay.total_ticks {
                        capture_complete = true
                        capture_succeeded = true
                        log.infof(
                            "Recorded %d fixed-tick frames for game case %s to %s",
                            recorded_frames,
                            capture.case_name,
                            run_options.record_directory,
                        )
                    }
                }
            } else if !recording_enabled && !video_enabled {
                tick_ready := !run_options.capture_tick_set ||
                              state.tick == run_options.capture_tick
                if tick_ready {
                    capture_frames += 1
                }
                if tick_ready && capture_frames >= capture.warmup_frames {
                    capture_texture := game_capture_texture(&renderer, capture.target)
                    capture_succeeded = export_render_texture_png(
                        capture_texture,
                        capture.output_path,
                    )
                    capture_complete = true
                    if capture_succeeded {
                        log.infof(
                            "Captured game case %s in %s to %s",
                            capture.case_name,
                            game_room(state.current_room).name,
                            capture.output_path,
                        )
                    } else {
                        log.errorf(
                            "Failed to capture game case %s to %s",
                            capture.case_name,
                            capture.output_path,
                        )
                    }
                }
            }
        }
    }

    if capture.enabled && !capture_succeeded {
        return 1
    }
    return 0
}
