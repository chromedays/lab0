package main

import "core:fmt"
import "core:os"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
import rgl "vendor:raylib/rlgl"
// import cgltf "vendor:cgltf"

Vertex :: struct {
    position: [3]f32,
    color: [4]f32,
}

VS_PATH             :: "shaders/custom.vs"
FS_PATH             :: "shaders/custom.fs"
DOWNSCALE_FS_PATH   :: "shaders/downscale.fs"
CEL_BAND_FS_PATH    :: "shaders/cel_band.fs"
MASK_DOWNSCALE_FS_PATH :: "shaders/mask_downscale.fs"
ASSETS_PATH         :: "assets"
DEFAULT_MODEL_PATH  :: "assets/CesiumMan.glb"
ANIMATION_SAMPLE_FPS :: 60.0

PIXEL_SCALE :: 10
LENS_WIDTH  :: 400
LENS_HEIGHT :: 400
DEFAULT_COLOR_CLUSTER_THRESHOLD :: 0.10
MODEL_SEARCH_TEXT_CAPACITY :: 128

MAGNIFIER_SAMPLE_SIZE  :: 16
MAGNIFIER_DISPLAY_SCALE :: 8

SUPPORTED_MODEL_EXTENSIONS := [?]string{
    ".obj",
    ".iqm",
    ".gltf",
    ".glb",
    ".vox",
    ".m3d",
}

Lens_Mode :: enum {
    PIXELATED,
    BLENDED,
    COVERAGE_MASK,
}

Model_Source_Kind :: enum {
    ASSET,
    CUBE,
    SPHERE,
    TRIANGLE,
}

Builtin_Model_Source :: struct {
    kind:  Model_Source_Kind,
    path:  string,
    label: string,
}

BUILTIN_MODEL_SOURCES := [?]Builtin_Model_Source{
    {.CUBE,     "builtin:cube",     "Built-in / Cube"},
    {.SPHERE,   "builtin:sphere",   "Built-in / Sphere"},
    {.TRIANGLE, "builtin:triangle", "Built-in / Triangle"},
}

Model_Assets :: struct {
    paths:  [dynamic]string,
    labels: [dynamic]cstring,
    kinds:  [dynamic]Model_Source_Kind,
}

Model_Search_Result :: struct {
    source_index: c.int,
    score:        int,
}

Model_Browser_State :: struct {
    search_text:          [MODEL_SEARCH_TEXT_CAPACITY]u8,
    previous_search_text: [MODEL_SEARCH_TEXT_CAPACITY]u8,
    results:              [dynamic]Model_Search_Result,
    result_labels:        [dynamic]cstring,
    scroll_index:         c.int,
    active_index:         c.int,
    focus_index:          c.int,
    search_editing:       bool,
}

// inspect_glb :: proc(model_path: string) -> bool {
//     cgltf_options := cgltf.options{}
//     model_path_cstr := strings.clone_to_cstring(model_path, context.temp_allocator);

//     gltf_data, parse_result := cgltf.parse_file(cgltf_options, model_path_cstr);
//     if parse_result != .success {
//         log.error("Failed to parse GLB file: ", model_path);
//         return false;
//     }
//     defer cgltf.free(gltf_data);

//     load_result := cgltf.load_buffers(cgltf_options, gltf_data, model_path_cstr);
//     if load_result != .success {
//         log.error("Failed to load buffers for GLB file: ", model_path);
//         return false;
//     }

//     validate_result := cgltf.validate(gltf_data);
//     if validate_result != .success {
//         log.error("Failed to validate GLB file: ", model_path);
//         return false;
//     }

//     log.info("Successfully loaded and validated GLB file: ", model_path);
//     log.info("=== glb inspection result ===");
//     log.info("meshes:     ", len(gltf_data.meshes));
//     log.info("materials:  ", len(gltf_data.materials));
//     log.info("textures:   ", len(gltf_data.textures));
//     log.info("images:     ", len(gltf_data.images));
//     log.info("nodes:      ", len(gltf_data.nodes));
//     log.info("skins:      ", len(gltf_data.skins));
//     log.info("animations: ", len(gltf_data.animations));

//     return true;
// }

import "core:c"

Animation_Playback :: struct {
    animations:      [^]rl.ModelAnimation,
    animation_count: c.int,
    valid_indices:   [dynamic]c.int,
    clip_options:    cstring,
    active_index:    c.int,
    current_frame:   f32,
    applied_frame:   f32,
    speed:           f32,
    is_playing:      bool,
    loop:            bool,
    sampled_playback: bool,
    sample_count:    c.int,
    dropdown_open:   bool,
    pose_dirty:      bool,
}

load_fragment_shader_with_includes :: proc(fragment_path: string) -> (
    shader: rl.Shader,
    preprocessed_source: Preprocessed_Shader_Source,
    loaded: bool,
) {
    preprocess_succeeded: bool
    preprocessed_source, preprocess_succeeded = preprocess_shader_file(fragment_path)
    if !preprocess_succeeded {
        return {}, preprocessed_source, false
    }

    source_code_cstr := strings.clone_to_cstring(
        preprocessed_source.code,
        context.temp_allocator,
    )
    shader = rl.LoadShaderFromMemory(nil, source_code_cstr)
    return shader, preprocessed_source, rl.IsShaderValid(shader)
}

load_shader_with_includes :: proc(vertex_path, fragment_path: string) -> (
    shader: rl.Shader,
    preprocessed_program: Preprocessed_Shader_Program_Source,
    loaded: bool,
) {
    preprocess_succeeded: bool
    preprocessed_program, preprocess_succeeded = preprocess_shader_program(
        vertex_path,
        fragment_path,
    )
    if !preprocess_succeeded {
        return {}, preprocessed_program, false
    }

    vertex_code_cstr := strings.clone_to_cstring(
        preprocessed_program.vertex.code,
        context.temp_allocator,
    )
    fragment_code_cstr := strings.clone_to_cstring(
        preprocessed_program.fragment.code,
        context.temp_allocator,
    )
    shader = rl.LoadShaderFromMemory(vertex_code_cstr, fragment_code_cstr)
    return shader, preprocessed_program, rl.IsShaderValid(shader)
}

reload_fragment_shader_with_includes :: proc(
    fragment_path: string,
    shader: ^rl.Shader,
    preprocessed_source: ^Preprocessed_Shader_Source,
) -> bool {
    if !shader_source_dependencies_changed(preprocessed_source) {
        return false
    }

    log.info("Shader dependency changed; reloading %s", fragment_path)
    replacement_shader, replacement_source, reload_succeeded :=
        load_fragment_shader_with_includes(fragment_path)
    destroy_preprocessed_shader_source(preprocessed_source)
    preprocessed_source^ = replacement_source

    if !reload_succeeded {
        log.error("Failed to reload %s. Keeping the old shader.", fragment_path)
        if rl.IsShaderValid(replacement_shader) {
            rl.UnloadShader(replacement_shader)
        }
        return false
    }

    rl.UnloadShader(shader^)
    shader^ = replacement_shader
    return true
}

reload_shader_with_includes :: proc(
    vertex_path, fragment_path: string,
    shader: ^rl.Shader,
    preprocessed_program: ^Preprocessed_Shader_Program_Source,
) -> bool {
    if !shader_program_source_dependencies_changed(preprocessed_program) {
        return false
    }

    log.info(
        "Shader dependency changed; reloading %s and %s",
        vertex_path,
        fragment_path,
    )
    replacement_shader, replacement_program, reload_succeeded := load_shader_with_includes(
        vertex_path,
        fragment_path,
    )
    destroy_preprocessed_shader_program_source(preprocessed_program)
    preprocessed_program^ = replacement_program

    if !reload_succeeded {
        log.error("Failed to reload %s. Keeping the old shader.", fragment_path)
        if rl.IsShaderValid(replacement_shader) {
            rl.UnloadShader(replacement_shader)
        }
        return false
    }

    rl.UnloadShader(shader^)
    shader^ = replacement_shader
    return true
}

is_supported_model_path :: proc(model_path: string) -> bool {
    model_extension := os.ext(model_path)
    for supported_extension in SUPPORTED_MODEL_EXTENSIONS {
        if strings.equal_fold(model_extension, supported_extension) {
            return true
        }
    }
    return false
}

scan_model_assets :: proc(assets_root: string) -> Model_Assets {
    assets: Model_Assets
    directory_walker := os.walker_create(assets_root)
    defer os.walker_destroy(&directory_walker)

    for asset_entry in os.walker_walk(&directory_walker) {
        if failed_path, walk_error := os.walker_error(&directory_walker);
           walk_error != nil {
            log.errorf("Failed to scan model asset %s: %v", failed_path, walk_error)
            continue
        }
        if asset_entry.type != .Regular ||
           !is_supported_model_path(asset_entry.fullpath) {
            continue
        }
        append(&assets.paths, strings.clone(asset_entry.fullpath))
    }

    slice.sort_by_key(
        assets.paths[:],
        proc(asset_path: string) -> string { return asset_path },
    )
    for asset_path in assets.paths {
        append(&assets.kinds, Model_Source_Kind.ASSET)
        display_label := asset_path
        asset_marker := "/" + ASSETS_PATH + "/"
        if marker_index := strings.last_index(asset_path, asset_marker);
           marker_index >= 0 {
            display_label = asset_path[marker_index + len(asset_marker):]
        } else {
            display_label = strings.trim_prefix(asset_path, ASSETS_PATH + "/")
        }
        if len(display_label) > 36 {
            display_label = fmt.tprintf(
                "%s...%s",
                display_label[:14],
                display_label[len(display_label) - 19:],
            )
        }
        append(&assets.labels, strings.clone_to_cstring(display_label))
    }

    for builtin_source in BUILTIN_MODEL_SOURCES {
        append(&assets.paths, strings.clone(builtin_source.path))
        append(&assets.labels, strings.clone_to_cstring(builtin_source.label))
        append(&assets.kinds, builtin_source.kind)
    }

    log.infof(
        "Found %d model assets under %s and added 3 built-in models",
        len(assets.paths) - 3,
        assets_root,
    )
    return assets
}

destroy_model_assets :: proc(assets: ^Model_Assets) {
    for asset_path in assets.paths do delete(asset_path)
    for asset_label in assets.labels do delete(asset_label)
    delete(assets.paths)
    delete(assets.labels)
    delete(assets.kinds)
}

ascii_search_lower :: proc(value: u8) -> u8 {
    if value >= 'A' && value <= 'Z' {
        return value + ('a' - 'A')
    }
    return value
}

is_model_search_separator :: proc(value: u8) -> bool {
    switch value {
    case ' ', '\t', '_', '-', '/', '\\', '.', ':':
        return true
    }
    return false
}

is_model_search_boundary :: proc(candidate: string, index: int) -> bool {
    return index == 0 || is_model_search_separator(candidate[index - 1])
}

// Match query characters in order, rewarding consecutive matches and word
// boundaries. Separators in the query are optional so inputs such as
// "female run" also match filenames that use underscores or extra words.
fuzzy_model_score :: proc(query, candidate: string) -> (
    score: int,
    matched: bool,
) {
    candidate_cursor := 0
    previous_match_index := -2
    consecutive_matches := 0
    matched_character_count := 0

    for query_index := 0; query_index < len(query); query_index += 1 {
        query_character := query[query_index]
        if is_model_search_separator(query_character) {
            continue
        }

        match_index := -1
        for candidate_index := candidate_cursor;
            candidate_index < len(candidate);
            candidate_index += 1 {
            if ascii_search_lower(candidate[candidate_index]) ==
               ascii_search_lower(query_character) {
                match_index = candidate_index
                break
            }
        }
        if match_index < 0 {
            return 0, false
        }

        gap_size := match_index - candidate_cursor
        score -= gap_size * 2
        if match_index == previous_match_index + 1 {
            consecutive_matches += 1
            score += 12 * consecutive_matches
        } else {
            consecutive_matches = 0
        }
        if is_model_search_boundary(candidate, match_index) {
            score += 24
        }
        if candidate[match_index] == query_character {
            score += 1
        }

        matched_character_count += 1
        previous_match_index = match_index
        candidate_cursor = match_index + 1
    }

    // A query containing only separators behaves like an empty query.
    if matched_character_count == 0 {
        return 0, true
    }
    score += matched_character_count * 10
    score -= (len(candidate) - matched_character_count) / 6
    return score, true
}

rebuild_model_search_results :: proc(
    model_assets: ^Model_Assets,
    browser: ^Model_Browser_State,
) {
    resize(&browser.results, 0)
    resize(&browser.result_labels, 0)

    search_query := string(cstring(&browser.search_text[0]))
    for model_path, source_index in model_assets.paths {
        path_score, path_matches := fuzzy_model_score(search_query, model_path)
        label_score, label_matches := fuzzy_model_score(
            search_query,
            string(model_assets.labels[source_index]),
        )
        if !path_matches && !label_matches {
            continue
        }

        match_score := path_score
        if label_matches && (!path_matches || label_score > path_score) {
            match_score = label_score
        }
        append(
            &browser.results,
            Model_Search_Result{c.int(source_index), match_score},
        )
    }

    slice.sort_by(
        browser.results[:],
        proc(left, right: Model_Search_Result) -> bool {
            if left.score == right.score {
                return left.source_index < right.source_index
            }
            return left.score > right.score
        },
    )
    for result in browser.results {
        append(
            &browser.result_labels,
            model_assets.labels[result.source_index],
        )
    }

    browser.previous_search_text = browser.search_text
    browser.scroll_index = 0
    browser.focus_index = -1
    if len(browser.results) > 0 {
        browser.active_index = 0
    } else {
        browser.active_index = -1
    }
}

destroy_model_browser_state :: proc(browser: ^Model_Browser_State) {
    delete(browser.results)
    delete(browser.result_labels)
}

set_model_browser_active_source :: proc(
    browser: ^Model_Browser_State,
    source_index: c.int,
) {
    for result, result_index in browser.results {
        if result.source_index == source_index {
            browser.active_index = c.int(result_index)
            return
        }
    }
    browser.active_index = -1
}

load_model_source :: proc(model_assets: ^Model_Assets, source_index: int) -> rl.Model {
    switch model_assets.kinds[source_index] {
    case .ASSET:
        return rl.LoadModel(
            strings.clone_to_cstring(
                model_assets.paths[source_index],
                context.temp_allocator,
            ),
        )
    case .CUBE:
        return rl.LoadModelFromMesh(rl.GenMeshCube(1, 1, 1))
    case .SPHERE:
        // A denser silhouette prevents low-resolution pixels from changing
        // merely because the camera orbited around an otherwise round sphere.
        return rl.LoadModelFromMesh(rl.GenMeshSphere(0.5, 64, 64))
    case .TRIANGLE:
        return rl.LoadModelFromMesh(rl.GenMeshPoly(3, 0.65))
    }
    return {}
}

is_model_loaded :: proc(model: rl.Model) -> bool {
    // IsModelValid() also fails when an otherwise usable model has a missing
    // or unsupported material texture. The browser only needs drawable meshes.
    return model.meshCount > 0 && model.meshes != nil
}

has_playable_animations :: proc(playback: ^Animation_Playback) -> bool {
    return playback.animations != nil && len(playback.valid_indices) > 0
}

get_active_animation :: proc(
    playback: ^Animation_Playback,
) -> (animation: rl.ModelAnimation, animation_found: bool) {
    if !has_playable_animations(playback) ||
       playback.active_index < 0 ||
       int(playback.active_index) >= len(playback.valid_indices) {
        return {}, false
    }

    animation_index := int(playback.valid_indices[playback.active_index])
    if animation_index < 0 || animation_index >= int(playback.animation_count) {
        return {}, false
    }
    return playback.animations[animation_index], true
}

destroy_animation_playback :: proc(playback: ^Animation_Playback) {
    if playback.animations != nil {
        rl.UnloadModelAnimations(playback.animations, playback.animation_count)
    }
    delete(playback.valid_indices)
    if playback.clip_options != nil {
        delete(playback.clip_options)
    }
    playback^ = {}
}

load_animation_playback :: proc(
    model: rl.Model,
    model_path: string,
    source_kind: Model_Source_Kind,
) -> Animation_Playback {
    if source_kind != .ASSET {
        return {}
    }

    playback := Animation_Playback{
        speed = 1.0,
        loop = true,
        sample_count = 4,
    }
    model_path_cstr := strings.clone_to_cstring(
        model_path,
        context.temp_allocator,
    )
    playback.animations = rl.LoadModelAnimations(
        model_path_cstr,
        &playback.animation_count,
    )
    if playback.animations == nil || playback.animation_count <= 0 {
        return playback
    }

    clip_options_builder := strings.builder_make()
    defer strings.builder_destroy(&clip_options_builder)

    for animation_index := 0;
        animation_index < int(playback.animation_count);
        animation_index += 1 {
        animation := playback.animations[animation_index]
        if animation.keyframeCount <= 0 {
            log.warnf(
                "Ignoring animation %d in %s because it has no keyframes",
                animation_index,
                model_path,
            )
            continue
        }
        if !rl.IsModelAnimationValid(model, animation) {
            log.warnf(
                "Ignoring animation %d in %s because its skeleton is incompatible",
                animation_index,
                model_path,
            )
            continue
        }

        if len(playback.valid_indices) > 0 {
            strings.write_byte(&clip_options_builder, ';')
        }
        append(&playback.valid_indices, c.int(animation_index))

        animation_name := string(cstring(&animation.name[0]))
        if len(animation_name) > 0 {
            strings.write_string(&clip_options_builder, animation_name)
        } else {
            strings.write_string(
                &clip_options_builder,
                fmt.tprintf("Animation %d", animation_index + 1),
            )
        }
    }

    if len(playback.valid_indices) == 0 {
        destroy_animation_playback(&playback)
        return {}
    }

    playback.clip_options = strings.clone_to_cstring(
        strings.to_string(clip_options_builder),
    )
    playback.active_index = 0
    playback.current_frame = 0
    playback.applied_frame = 0
    playback.pose_dirty = true

    animation, animation_found := get_active_animation(&playback)
    if animation_found {
        rl.UpdateModelAnimation(model, animation, playback.current_frame)
        playback.pose_dirty = false
    }

    log.infof(
        "Loaded %d playable animation(s) from %s",
        len(playback.valid_indices),
        model_path,
    )
    return playback
}

get_max_sample_count :: proc(animation: rl.ModelAnimation) -> c.int {
    // The terminal keyframe marks the end of the loop, so a 120-frame cycle
    // exposes the distinct frames 0...119 for sampled playback.
    return max(animation.keyframeCount - 1, 1)
}

get_sampled_frame_at_index :: proc(
    animation: rl.ModelAnimation,
    sample_count, sample_index: c.int,
) -> f32 {
    last_frame := f32(max(animation.keyframeCount - 1, 0))
    if last_frame <= 0 {
        return 0
    }

    clamped_count := clamp(sample_count, 1, get_max_sample_count(animation))
    clamped_index := clamp(sample_index, 0, clamped_count - 1)
    return f32(c.int(
        f32(clamped_index) * last_frame / f32(clamped_count),
    ))
}

get_sample_index_for_frame :: proc(
    animation: rl.ModelAnimation,
    sample_count: c.int,
    frame: f32,
) -> c.int {
    last_frame := f32(max(animation.keyframeCount - 1, 0))
    if last_frame <= 0 {
        return 0
    }

    clamped_count := clamp(sample_count, 1, get_max_sample_count(animation))
    clamped_frame := clamp(frame, 0, last_frame)
    sample_index := c.int(clamped_frame / last_frame * f32(clamped_count))
    return clamp(sample_index, 0, clamped_count - 1)
}

get_animation_pose_frame :: proc(
    playback: ^Animation_Playback,
    animation: rl.ModelAnimation,
) -> f32 {
    last_frame := f32(max(animation.keyframeCount - 1, 0))
    if !playback.sampled_playback {
        return clamp(playback.current_frame, 0, last_frame)
    }

    sample_index := get_sample_index_for_frame(
        animation,
        playback.sample_count,
        playback.current_frame,
    )
    return get_sampled_frame_at_index(
        animation,
        playback.sample_count,
        sample_index,
    )
}

update_animation_playback :: proc(
    playback: ^Animation_Playback,
    model: rl.Model,
) {
    animation, animation_found := get_active_animation(playback)
    if !animation_found {
        return
    }

    last_frame := f32(max(animation.keyframeCount - 1, 0))
    playback.sample_count = clamp(
        playback.sample_count,
        1,
        get_max_sample_count(animation),
    )
    if playback.is_playing {
        if last_frame <= 0 {
            playback.current_frame = 0
            playback.is_playing = false
        } else {
            playback.current_frame += rl.GetFrameTime() *
                                      f32(ANIMATION_SAMPLE_FPS) *
                                      playback.speed
            if playback.sampled_playback && !playback.loop {
                final_sample_frame := get_sampled_frame_at_index(
                    animation,
                    playback.sample_count,
                    playback.sample_count - 1,
                )
                if playback.current_frame >= final_sample_frame {
                    playback.current_frame = final_sample_frame
                    playback.is_playing = false
                }
            } else if playback.loop {
                if playback.current_frame >= last_frame {
                    playback.current_frame = math.mod(
                        playback.current_frame,
                        last_frame,
                    )
                }
            } else if playback.current_frame >= last_frame {
                playback.current_frame = last_frame
                playback.is_playing = false
            }
        }
    }

    playback.current_frame = clamp(playback.current_frame, 0, last_frame)
    pose_frame := get_animation_pose_frame(playback, animation)
    if playback.pose_dirty || pose_frame != playback.applied_frame {
        rl.UpdateModelAnimation(model, animation, pose_frame)
        playback.applied_frame = pose_frame
        playback.pose_dirty = false
    }
}

get_model_center :: proc(model: rl.Model) -> rl.Vector3 {
    model_bounds := rl.GetModelBoundingBox(model)
    return {
        model_bounds.min.x + (model_bounds.max.x - model_bounds.min.x) * 0.5,
        model_bounds.min.y + (model_bounds.max.y - model_bounds.min.y) * 0.5,
        model_bounds.min.z + (model_bounds.max.z - model_bounds.min.z) * 0.5,
    }
}

reset_camera_to_axis_view :: proc(
    camera: ^rl.Camera3D,
    pivot: rl.Vector3,
    axis: rl.Vector3,
    up: rl.Vector3,
    scene_size: f32,
) {
    // Orthographic projection does not use the orbit radius for framing, but
    // retaining it keeps the near/far relationship stable after the reset.
    orbit_radius := rl.Vector3Length(camera.position - camera.target)
    if orbit_radius < 0.00001 {
        orbit_radius = max(scene_size * 3, 1)
    }

    camera.target = pivot
    camera.position = pivot + axis * orbit_radius
    camera.up = up
}

snap_orthographic_camera_to_pixel_grid :: proc(
    camera: ^rl.Camera3D,
    anchor: rl.Vector3,
    pixel_target_height: i32,
) {
    if pixel_target_height <= 0 || camera.fovy <= 0 {
        return
    }

    world_units_per_pixel := camera.fovy / f32(pixel_target_height)
    camera_forward := rl.GetCameraForward(camera)
    camera_right := rl.GetCameraRight(camera)
    // Camera.up is not guaranteed to remain perpendicular to forward after
    // orbiting. Rebuild the actual vertical screen axis used by the view.
    camera_up := rl.Vector3Normalize(
        rl.Vector3CrossProduct(camera_right, camera_forward),
    )

    // Quantize the view center relative to the model center. Moving position
    // and target by the same delta preserves the orbit radius/orientation.
    pan_offset := camera.target - anchor
    pan_x := rl.Vector3DotProduct(pan_offset, camera_right)
    pan_y := rl.Vector3DotProduct(pan_offset, camera_up)
    snapped_x := math.round(pan_x / world_units_per_pixel) * world_units_per_pixel
    snapped_y := math.round(pan_y / world_units_per_pixel) * world_units_per_pixel

    snap_correction := camera_right * (snapped_x - pan_x) +
                       camera_up * (snapped_y - pan_y)
    camera.position += snap_correction
    camera.target += snap_correction
}

snap_orthographic_zoom_to_pixel_grid :: proc(
    camera: ^rl.Camera3D,
    reference_world_size: f32,
    pixel_target_height: i32,
) {
    if pixel_target_height <= 0 || camera.fovy <= 0 || reference_world_size <= 0 {
        return
    }

    projected_pixels := reference_world_size * f32(pixel_target_height) / camera.fovy
    snapped_pixels := max(math.round(projected_pixels), 1)
    camera.fovy = reference_world_size * f32(pixel_target_height) / snapped_pixels
}

frame_camera_to_model :: proc(
    model: rl.Model,
    source_kind: Model_Source_Kind,
    camera: ^rl.Camera3D,
) -> f32 {
    model_bounds := rl.GetModelBoundingBox(model)
    model_center := rl.Vector3{
        model_bounds.min.x + (model_bounds.max.x - model_bounds.min.x) * 0.5,
        model_bounds.min.y + (model_bounds.max.y - model_bounds.min.y) * 0.5,
        model_bounds.min.z + (model_bounds.max.z - model_bounds.min.z) * 0.5,
    }
    model_dimensions := rl.Vector3{
        model_bounds.max.x - model_bounds.min.x,
        model_bounds.max.y - model_bounds.min.y,
        model_bounds.max.z - model_bounds.min.z,
    }
    scene_size := max(
        model_dimensions.x,
        max(model_dimensions.y, model_dimensions.z),
    )
    if scene_size <= 0 {
        scene_size = 1
    }

    if source_kind == .CUBE ||
       source_kind == .SPHERE ||
       source_kind == .TRIANGLE {
        projected_width := model_dimensions.x
        projected_height := model_dimensions.y
        camera_position := rl.Vector3{
            model_center.x,
            model_center.y,
            model_center.z + scene_size * 3,
        }
        camera_up := rl.Vector3{0, 1, 0}

        if source_kind == .TRIANGLE {
            // GenMeshPoly() lies on the XZ plane, so view it from above.
            projected_height = model_dimensions.z
            camera_position = {
                model_center.x,
                model_center.y + scene_size * 3,
                model_center.z,
            }
            camera_up = {0, 0, 1}
        }

        // raylib's orthographic fovy is the full screen height in world units.
        // Fit the projected model into the narrower 200x400 lens, not merely
        // into the 800x600 window, and retain 10% padding on every side.
        lens_fill: f32 = 0.8
        screen_height := f32(rl.GetScreenHeight())
        fovy_for_width := projected_width * screen_height / f32(LENS_WIDTH) / lens_fill
        fovy_for_height := projected_height * screen_height / f32(LENS_HEIGHT) / lens_fill

        camera^ = rl.Camera3D{
            target     = model_center,
            position   = camera_position,
            up         = camera_up,
            fovy       = max(fovy_for_width, fovy_for_height),
            projection = .ORTHOGRAPHIC,
        }
        log.infof(
            "Built-in lens framing: projected(%f, %f), ortho fovy=%f",
            projected_width,
            projected_height,
            camera.fovy,
        )
    } else {
        camera^ = rl.Camera3D{
            target     = model_center,
            position   = {
                model_center.x + scene_size * 1.5,
                model_center.y + scene_size * 0.7,
                model_center.z + scene_size * 1.5,
            },
            up         = {0, 1, 0},
            fovy       = scene_size * 2.5,
            projection = .ORTHOGRAPHIC,
        }
    }

    log.infof(
        "Model bounding box: min(%f, %f, %f), max(%f, %f, %f)",
        model_bounds.min.x,
        model_bounds.min.y,
        model_bounds.min.z,
        model_bounds.max.x,
        model_bounds.max.y,
        model_bounds.max.z,
    )
    return scene_size
}

draw_scene :: proc(shader: rl.Shader, model: rl.Model, camera: rl.Camera3D) {
    rl.ClearBackground(rl.BLANK)

    rl.BeginMode3D(camera)
        if is_model_loaded(model) {
            // Keep each mesh's textures and material tint, but replace its
            // shader for this draw only. The model still owns its materials.
            for mesh_index := 0; mesh_index < int(model.meshCount); mesh_index += 1 {
                material_index := int(model.meshMaterial[mesh_index])
                if material_index < 0 || material_index >= int(model.materialCount) {
                    material_index = 0
                }
                mesh_material := model.materials[material_index]
                mesh_material.shader = shader
                rl.DrawMesh(
                    model.meshes[mesh_index],
                    mesh_material,
                    model.transform,
                )
            }
        }
        // rl.DrawModelWires(model, {}, 1.0, rl.YELLOW)
    rl.EndMode3D()
}

draw_model_cel_bands :: proc(
    cel_band_material: rl.Material,
    model: rl.Model,
    camera: rl.Camera3D,
) {
    rl.ClearBackground(rl.BLANK)
    rl.BeginMode3D(camera)
        if is_model_loaded(model) {
            for mesh_index := 0; mesh_index < int(model.meshCount); mesh_index += 1 {
                rl.DrawMesh(
                    model.meshes[mesh_index],
                    cel_band_material,
                    model.transform,
                )
            }
        }
    rl.EndMode3D()
}

// Drawn directly into the final framebuffer after both scene render targets
// have been resolved. This keeps the reference grid out of the downscale pass.
draw_coordinate_grid_overlay :: proc(
    camera: rl.Camera3D,
    model: rl.Model,
    scene_size: f32,
) {
    grid_spacing := max(scene_size * 0.5, 0.0001)
    grid_half_count := 10
    grid_extent := grid_spacing * f32(grid_half_count)
    grid_color := rl.Color{190, 190, 190, 105}

    x_color := rl.Color{235, 70, 70, 255}
    y_color := rl.Color{80, 220, 100, 255}
    z_color := rl.Color{70, 135, 245, 255}

    axis_length := max(scene_size * 1.5, 0.0003)
    shaft_radius := max(scene_size * 0.008, 0.000002)
    arrow_length := axis_length * 0.14
    arrow_radius := shaft_radius * 3.2
    shaft_end := axis_length - arrow_length

    rl.BeginMode3D(camera)
        // Seed only the final framebuffer's depth buffer so the overlay remains
        // spatially legible around the model without re-drawing its color.
        if is_model_loaded(model) {
            rl.DrawModel(model, {}, 1.0, rl.BLANK)
        }

        for grid_line_index := -grid_half_count;
            grid_line_index <= grid_half_count;
            grid_line_index += 1 {
            if grid_line_index == 0 {
                continue
            }
            grid_line_offset := f32(grid_line_index) * grid_spacing
            rl.DrawLine3D(
                {-grid_extent, 0, grid_line_offset},
                { grid_extent, 0, grid_line_offset},
                grid_color,
            )
            rl.DrawLine3D(
                {grid_line_offset, 0, -grid_extent},
                {grid_line_offset, 0,  grid_extent},
                grid_color,
            )
        }

        // Dim negative halves plus solid positive shafts and arrowheads make
        // both the axis identity and positive direction immediately visible.
        rl.DrawLine3D({-axis_length, 0, 0}, {}, rl.Color{150, 45, 45, 210})
        rl.DrawLine3D({0, -axis_length, 0}, {}, rl.Color{45, 140, 65, 210})
        rl.DrawLine3D({0, 0, -axis_length}, {}, rl.Color{45, 80, 155, 210})

        rl.DrawCylinderEx({}, {shaft_end, 0, 0}, shaft_radius, shaft_radius, 8, x_color)
        rl.DrawCylinderEx({shaft_end, 0, 0}, {axis_length, 0, 0}, arrow_radius, 0, 8, x_color)
        rl.DrawCylinderEx({}, {0, shaft_end, 0}, shaft_radius, shaft_radius, 8, y_color)
        rl.DrawCylinderEx({0, shaft_end, 0}, {0, axis_length, 0}, arrow_radius, 0, 8, y_color)
        rl.DrawCylinderEx({}, {0, 0, shaft_end}, shaft_radius, shaft_radius, 8, z_color)
        rl.DrawCylinderEx({0, 0, shaft_end}, {0, 0, axis_length}, arrow_radius, 0, 8, z_color)
    rl.EndMode3D()

    x_axis_label_position := rl.GetWorldToScreen({axis_length, 0, 0}, camera)
    y_axis_label_position := rl.GetWorldToScreen({0, axis_length, 0}, camera)
    z_axis_label_position := rl.GetWorldToScreen({0, 0, axis_length}, camera)
    rl.DrawText(
        "X",
        c.int(x_axis_label_position.x + 6),
        c.int(x_axis_label_position.y - 8),
        18,
        x_color,
    )
    rl.DrawText(
        "Y",
        c.int(y_axis_label_position.x + 6),
        c.int(y_axis_label_position.y - 8),
        18,
        y_color,
    )
    rl.DrawText(
        "Z",
        c.int(z_axis_label_position.x + 6),
        c.int(z_axis_label_position.y - 8),
        18,
        z_color,
    )
}

draw_model_browser :: proc(
    bounds: rl.Rectangle,
    model_assets: ^Model_Assets,
    browser: ^Model_Browser_State,
    loaded_index: c.int,
    load_failed: bool,
    requested_source_index: ^c.int,
) {
    rl.GuiPanel(bounds, "MODEL ASSETS")

    search_bounds := rl.Rectangle{
        bounds.x + 10,
        bounds.y + 28,
        bounds.width - 48,
        24,
    }
    clear_bounds := rl.Rectangle{
        search_bounds.x + search_bounds.width + 4,
        search_bounds.y,
        24,
        24,
    }
    search_was_editing := browser.search_editing
    if rl.GuiTextBox(
        search_bounds,
        cstring(&browser.search_text[0]),
        MODEL_SEARCH_TEXT_CAPACITY,
        browser.search_editing,
    ) {
        browser.search_editing = !browser.search_editing
    }
    search_query := string(cstring(&browser.search_text[0]))
    if len(search_query) == 0 && !browser.search_editing {
        rl.GuiLabel(
            {
                search_bounds.x + 8,
                search_bounds.y,
                search_bounds.width - 12,
                search_bounds.height,
            },
            rl.GuiIconText(
                .ICON_ZOOM_SMALL,
                rl.TextFormat("Search %d models...", len(model_assets.paths)),
            ),
        )
    }
    if rl.GuiButton(clear_bounds, rl.GuiIconText(.ICON_CROSS_SMALL, nil)) {
        browser.search_text = {}
        browser.search_editing = true
    }

    search_keyboard_active := search_was_editing || browser.search_editing
    enter_pressed := search_keyboard_active &&
                     (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER))
    if search_keyboard_active && rl.IsKeyPressed(.ESCAPE) {
        if len(search_query) > 0 {
            browser.search_text = {}
        } else {
            browser.search_editing = false
        }
    }
    if browser.search_text != browser.previous_search_text {
        rebuild_model_search_results(model_assets, browser)
    }

    if search_keyboard_active && len(browser.results) > 0 {
        if rl.IsKeyPressed(.DOWN) {
            browser.active_index = min(
                browser.active_index + 1,
                c.int(len(browser.results) - 1),
            )
        }
        if rl.IsKeyPressed(.UP) {
            browser.active_index = max(browser.active_index - 1, 0)
        }

        visible_result_count: c.int = 8
        if browser.active_index < browser.scroll_index {
            browser.scroll_index = browser.active_index
        } else if browser.active_index >=
                  browser.scroll_index + visible_result_count {
            browser.scroll_index = browser.active_index - visible_result_count + 1
        }
    }

    list_bounds := rl.Rectangle{
        bounds.x + 10,
        bounds.y + 58,
        bounds.width - 20,
        bounds.height - 92,
    }
    if len(browser.result_labels) > 0 {
        rl.GuiListViewEx(
            list_bounds,
            raw_data(browser.result_labels[:]),
            c.int(len(browser.result_labels)),
            &browser.scroll_index,
            &browser.active_index,
            &browser.focus_index,
        )
        result_clicked := rl.CheckCollisionPointRec(
            rl.GetMousePosition(),
            list_bounds,
        ) && rl.IsMouseButtonReleased(.LEFT) && browser.focus_index >= 0
        if (result_clicked || enter_pressed) &&
           browser.active_index >= 0 &&
           int(browser.active_index) < len(browser.results) {
            requested_source_index^ =
                browser.results[browser.active_index].source_index
            if result_clicked {
                browser.search_editing = false
            }
        }
    } else {
        rl.GuiLabel(list_bounds, "No matching models")
    }

    status_bounds := rl.Rectangle{
        bounds.x + 10,
        bounds.y + bounds.height - 28,
        bounds.width - 20,
        20,
    }
    if load_failed {
        rl.GuiLabel(status_bounds, "Load failed; previous model kept")
    } else if loaded_index >= 0 &&
              int(loaded_index) < len(model_assets.labels) {
        rl.GuiLabel(
            status_bounds,
            rl.TextFormat("Loaded: %s", model_assets.labels[loaded_index]),
        )
    }
}

draw_animation_controls :: proc(
    bounds: rl.Rectangle,
    playback: ^Animation_Playback,
) {
    animation, animation_found := get_active_animation(playback)
    if !animation_found {
        return
    }

    rl.GuiPanel(bounds, "MODEL ANIMATION")

    content_x := bounds.x + 12
    content_width := bounds.width - 24
    clip_bounds := rl.Rectangle{
        content_x + 42,
        bounds.y + 28,
        content_width - 42,
        24,
    }
    rl.GuiLabel({content_x, bounds.y + 31, 38, 18}, "Clip")

    if playback.dropdown_open {
        rl.GuiLock()
    }

    transport_y := bounds.y + 58
    button_gap: f32 = 4
    reset_width: f32 = 44
    step_width: f32 = 40
    play_width := content_width - reset_width - step_width * 2 - button_gap * 3

    if rl.GuiButton({content_x, transport_y, reset_width, 24}, "|<") {
        playback.current_frame = 0
        playback.is_playing = false
        playback.pose_dirty = true
    }
    previous_button_x := content_x + reset_width + button_gap
    if rl.GuiButton({previous_button_x, transport_y, step_width, 24}, "<") {
        if playback.sampled_playback {
            sample_index := get_sample_index_for_frame(
                animation,
                playback.sample_count,
                playback.current_frame,
            )
            playback.current_frame = get_sampled_frame_at_index(
                animation,
                playback.sample_count,
                sample_index - 1,
            )
        } else {
            playback.current_frame = max(playback.current_frame - 1, 0)
        }
        playback.is_playing = false
        playback.pose_dirty = true
    }

    play_button_x := previous_button_x + step_width + button_gap
    play_label: cstring = "Play [Space]"
    if playback.is_playing {
        play_label = "Pause [Space]"
    }
    if rl.GuiButton({play_button_x, transport_y, play_width, 24}, play_label) {
        playback.is_playing = !playback.is_playing
    }

    next_button_x := play_button_x + play_width + button_gap
    last_frame := f32(max(animation.keyframeCount - 1, 0))
    if rl.GuiButton({next_button_x, transport_y, step_width, 24}, ">") {
        if playback.sampled_playback {
            sample_index := get_sample_index_for_frame(
                animation,
                playback.sample_count,
                playback.current_frame,
            )
            playback.current_frame = get_sampled_frame_at_index(
                animation,
                playback.sample_count,
                sample_index + 1,
            )
        } else {
            playback.current_frame = min(playback.current_frame + 1, last_frame)
        }
        playback.is_playing = false
        playback.pose_dirty = true
    }

    timeline_label_y := bounds.y + 88
    display_frame := get_animation_pose_frame(playback, animation)
    rl.GuiLabel(
        {content_x, timeline_label_y, content_width, 18},
        rl.TextFormat(
            "Frame %d / %d",
            c.int(math.round(display_frame)),
            animation.keyframeCount - 1,
        ),
    )
    previous_frame := playback.current_frame
    rl.GuiSliderBar(
        {content_x, bounds.y + 108, content_width, 18},
        nil,
        nil,
        &playback.current_frame,
        0,
        last_frame,
    )
    if playback.current_frame != previous_frame {
        if playback.sampled_playback {
            playback.current_frame = get_animation_pose_frame(
                playback,
                animation,
            )
        }
        playback.is_playing = false
        playback.pose_dirty = true
    }

    options_y := bounds.y + 136
    rl.GuiLabel({content_x, options_y, 40, 18}, "Speed")
    rl.GuiSliderBar(
        {content_x + 42, options_y, 105, 18},
        nil,
        nil,
        &playback.speed,
        0.25,
        2.0,
    )
    rl.GuiLabel(
        {content_x + 152, options_y, 48, 18},
        rl.TextFormat("%.2fx", playback.speed),
    )
    rl.GuiCheckBox({content_x + 202, options_y + 1, 16, 16}, nil, &playback.loop)
    rl.GuiLabel({content_x + 222, options_y, 36, 18}, "Loop")

    sample_options_y := bounds.y + 162
    previous_sampled_playback := playback.sampled_playback
    rl.GuiCheckBox(
        {content_x, sample_options_y + 1, 16, 16},
        nil,
        &playback.sampled_playback,
    )
    rl.GuiLabel({content_x + 20, sample_options_y, 66, 18}, "Sampled")
    rl.GuiLabel({content_x + 91, sample_options_y, 42, 18}, "Count")
    previous_sample_count := playback.sample_count
    rl.GuiSpinner(
        {content_x + 136, sample_options_y - 2, content_width - 136, 22},
        nil,
        &playback.sample_count,
        1,
        get_max_sample_count(animation),
        false,
    )
    if playback.sampled_playback != previous_sampled_playback ||
       playback.sample_count != previous_sample_count {
        playback.sample_count = clamp(
            playback.sample_count,
            1,
            get_max_sample_count(animation),
        )
        if playback.sampled_playback {
            playback.current_frame = get_animation_pose_frame(
                playback,
                animation,
            )
        }
        playback.pose_dirty = true
    }

    if playback.dropdown_open {
        rl.GuiUnlock()
    }

    if len(playback.valid_indices) == 1 {
        rl.GuiLabel(clip_bounds, playback.clip_options)
    } else {
        previous_active_index := playback.active_index
        if rl.GuiDropdownBox(
            clip_bounds,
            playback.clip_options,
            &playback.active_index,
            playback.dropdown_open,
        ) {
            playback.dropdown_open = !playback.dropdown_open
        }
        if playback.active_index != previous_active_index {
            playback.current_frame = 0
            playback.pose_dirty = true
            log.infof(
                "Selected animation clip %d",
                playback.active_index + 1,
            )
        }
    }
}

draw_camera_controls :: proc(
    bounds: rl.Rectangle,
    camera: ^rl.Camera3D,
    model_center: rl.Vector3,
    scene_size: f32,
    downsample_width, downsample_height: i32,
    lens_grid_visible: bool,
) {
    rl.GuiPanel(bounds, "CAMERA CONTROLS")

    content_x := bounds.x + 12
    content_y := bounds.y + 28
    content_width := bounds.width - 24
    line_height: f32 = 18

    rl.GuiLabel(
        {content_x, content_y, content_width, 18},
        "Reset axis view (from positive axis)",
    )
    content_y += 22

    button_gap: f32 = 6
    button_width := (content_width - button_gap * 2) / 3
    if rl.GuiButton({content_x, content_y, button_width, 24}, "X") {
        reset_camera_to_axis_view(
            camera,
            model_center,
            {1, 0, 0},
            {0, 1, 0},
            scene_size,
        )
        log.info("Camera reset to +X axis view")
    }
    if rl.GuiButton(
        {content_x + button_width + button_gap, content_y, button_width, 24},
        "Y",
    ) {
        reset_camera_to_axis_view(
            camera,
            model_center,
            {0, 1, 0},
            {0, 0, 1},
            scene_size,
        )
        log.info("Camera reset to +Y axis view")
    }
    if rl.GuiButton(
        {
            content_x + (button_width + button_gap) * 2,
            content_y,
            button_width,
            24,
        },
        "Z",
    ) {
        reset_camera_to_axis_view(
            camera,
            model_center,
            {0, 0, 1},
            {0, 1, 0},
            scene_size,
        )
        log.info("Camera reset to +Z axis view")
    }
    content_y += 28

    if rl.GuiButton({content_x, content_y, content_width, 24}, "Isometric") {
        reset_camera_to_axis_view(
            camera,
            model_center,
            rl.Vector3Normalize({1, 1, 1}),
            {0, 1, 0},
            scene_size,
        )
        log.info("Camera reset to isometric view")
    }
    content_y += 26

    rl.GuiLabel({content_x, content_y, content_width, 18}, "LMB drag       Orbit around target")
    content_y += line_height
    rl.GuiLabel({content_x, content_y, content_width, 18}, "MMB drag       Screen-plane pan")
    content_y += line_height
    rl.GuiLabel({content_x, content_y, content_width, 18}, "WASD / Arrows  Screen-plane pan")
    content_y += line_height
    rl.GuiLabel({content_x, content_y, content_width, 18}, "Q / E          Zoom out / in")
    content_y += line_height
    rl.GuiLabel({content_x, content_y, content_width, 18}, "Mouse wheel    Zoom")
    content_y += line_height
    rl.GuiLabel({content_x, content_y, content_width, 18}, "Shift          Faster keyboard")
    content_y += line_height
    lens_grid_status: cstring = "OFF"
    if lens_grid_visible {
        lens_grid_status = "ON"
    }
    rl.GuiLabel(
        {content_x, content_y, content_width, 18},
        rl.TextFormat("1/2/3 Lens mode | G Grid: %s", lens_grid_status),
    )
    content_y += line_height
    rl.GuiLabel(
        {content_x, content_y, content_width, 18},
        rl.TextFormat(
            "Pan + zoom snap: %d x %d",
            downsample_width,
            downsample_height,
        ),
    )
}

draw_background_controls :: proc(
    bounds: rl.Rectangle,
    picker_bounds: rl.Rectangle,
    background_color: ^rl.Color,
    picker_open: ^bool,
) {
    rl.GuiPanel(bounds, "SCENE BACKGROUND")

    swatch_bounds := rl.Rectangle{
        bounds.x + 12,
        bounds.y + 30,
        54,
        54,
    }
    rl.DrawRectangleRec(swatch_bounds, background_color^)
    rl.DrawRectangleLinesEx(swatch_bounds, 2, rl.RAYWHITE)

    button_x := swatch_bounds.x + swatch_bounds.width + 12
    button_width := bounds.x + bounds.width - button_x - 12
    picker_button_text: cstring = "Open color picker"
    if picker_open^ {
        picker_button_text = "Close color picker"
    }
    if rl.GuiButton(
        {button_x, bounds.y + 30, button_width, 25},
        picker_button_text,
    ) {
        picker_open^ = !picker_open^
    }
    if rl.GuiButton(
        {button_x, bounds.y + 59, button_width, 25},
        "Reset to black",
    ) {
        background_color^ = rl.BLACK
    }

    rl.GuiLabel(
        {bounds.x + 12, bounds.y + 88, bounds.width - 24, 18},
        rl.TextFormat(
            "RGB: %d, %d, %d",
            c.int(background_color.r),
            c.int(background_color.g),
            c.int(background_color.b),
        ),
    )

    if picker_open^ {
        if rl.GuiWindowBox(picker_bounds, "BACKGROUND COLOR") != 0 {
            picker_open^ = false
            return
        }
        rl.GuiColorPicker(
            {
                picker_bounds.x + 12,
                picker_bounds.y + 34,
                165,
                165,
            },
            nil,
            background_color,
        )
    }
}

draw_mouse_magnifier :: proc(
    bounds: rl.Rectangle,
    source_texture: rl.Texture2D,
    mouse_position: rl.Vector2,
    screen_width, screen_height: i32,
) {
    mouse_x := min(max(i32(mouse_position.x), 0), screen_width - 1)
    mouse_y := min(max(i32(mouse_position.y), 0), screen_height - 1)
    sample_x := min(
        max(mouse_x - MAGNIFIER_SAMPLE_SIZE / 2, 0),
        max(screen_width - MAGNIFIER_SAMPLE_SIZE, 0),
    )
    sample_y := min(
        max(mouse_y - MAGNIFIER_SAMPLE_SIZE / 2, 0),
        max(screen_height - MAGNIFIER_SAMPLE_SIZE, 0),
    )

    display_size := f32(MAGNIFIER_SAMPLE_SIZE * MAGNIFIER_DISPLAY_SCALE)
    magnified_image_bounds := rl.Rectangle{
        bounds.x + 10,
        bounds.y + 28,
        display_size,
        display_size,
    }
    texture_source_bounds := rl.Rectangle{
        f32(sample_x),
        f32(screen_height - sample_y - MAGNIFIER_SAMPLE_SIZE),
        f32(MAGNIFIER_SAMPLE_SIZE),
        -f32(MAGNIFIER_SAMPLE_SIZE),
    }

    rl.GuiPanel(bounds, "MAGNIFIER 16 x 16")
    rl.DrawTexturePro(
        source_texture,
        texture_source_bounds,
        magnified_image_bounds,
        {},
        0,
        rl.WHITE,
    )

    grid_color := rl.Color{0, 0, 0, 80}
    for grid_line_index := 0;
        grid_line_index <= MAGNIFIER_SAMPLE_SIZE;
        grid_line_index += 1 {
        grid_line_offset := f32(grid_line_index * MAGNIFIER_DISPLAY_SCALE)
        rl.DrawLineV(
            {
                magnified_image_bounds.x + grid_line_offset,
                magnified_image_bounds.y,
            },
            {
                magnified_image_bounds.x + grid_line_offset,
                magnified_image_bounds.y + magnified_image_bounds.height,
            },
            grid_color,
        )
        rl.DrawLineV(
            {
                magnified_image_bounds.x,
                magnified_image_bounds.y + grid_line_offset,
            },
            {
                magnified_image_bounds.x + magnified_image_bounds.width,
                magnified_image_bounds.y + grid_line_offset,
            },
            grid_color,
        )
    }

    // Keep the exact pixel under the cursor identifiable inside the 16x16 sample.
    cursor_column := mouse_x - sample_x
    cursor_row := mouse_y - sample_y
    cursor_pixel_bounds := rl.Rectangle{
        magnified_image_bounds.x + f32(cursor_column * MAGNIFIER_DISPLAY_SCALE),
        magnified_image_bounds.y + f32(cursor_row * MAGNIFIER_DISPLAY_SCALE),
        MAGNIFIER_DISPLAY_SCALE,
        MAGNIFIER_DISPLAY_SCALE,
    }
    rl.DrawRectangleLinesEx(cursor_pixel_bounds, 2, rl.YELLOW)
    rl.DrawRectangleLinesEx(magnified_image_bounds, 1, rl.RAYWHITE)
    rl.GuiLabel(
        {
            bounds.x + 10,
            magnified_image_bounds.y + magnified_image_bounds.height + 4,
            bounds.width - 20,
            18,
        },
        rl.TextFormat("Cursor: %d, %d", mouse_x, mouse_y),
    )
}

export_lens_downsample_png :: proc(
    source_texture: rl.Texture2D,
    lens_bounds: rl.Rectangle,
    pixel_scale: i32,
    next_export_index: ^int,
) -> (export_path: string, export_succeeded: bool) {
    if pixel_scale <= 0 {
        return "", false
    }

    texture_readback := rl.LoadImageFromTexture(source_texture)
    if texture_readback.data == nil {
        return "", false
    }
    defer rl.UnloadImage(texture_readback)

    // RenderTexture readback is vertically inverted. Crop in readback space,
    // then flip the cropped image so the exported PNG matches the lens view.
    crop_x := c.int(math.round(lens_bounds.x / f32(pixel_scale)))
    logical_crop_y := c.int(math.round(lens_bounds.y / f32(pixel_scale)))
    crop_width := c.int(math.round(lens_bounds.width / f32(pixel_scale)))
    crop_height := c.int(math.round(lens_bounds.height / f32(pixel_scale)))
    crop_y := texture_readback.height - logical_crop_y - crop_height

    if crop_x < 0 || crop_y < 0 || crop_width <= 0 || crop_height <= 0 ||
       crop_x + crop_width > texture_readback.width ||
       crop_y + crop_height > texture_readback.height {
        log.errorf(
            "Lens export crop is outside the downsample target: crop(%d, %d, %d, %d), target(%d, %d)",
            crop_x,
            crop_y,
            crop_width,
            crop_height,
            texture_readback.width,
            texture_readback.height,
        )
        return "", false
    }

    rl.ImageCrop(
        &texture_readback,
        {
            f32(crop_x),
            f32(crop_y),
            f32(crop_width),
            f32(crop_height),
        },
    )
    rl.ImageFlipVertical(&texture_readback)
    rl.ImageFormat(&texture_readback, .UNCOMPRESSED_R8G8B8A8)

    // Never overwrite a previous export. Continue from the next available
    // sequence number even when files already exist from an earlier run.
    for {
        candidate_path := fmt.tprintf(
            "lens_downsample_%03d.png",
            next_export_index^,
        )
        next_export_index^ += 1
        candidate_path_cstr := strings.clone_to_cstring(
            candidate_path,
            context.temp_allocator,
        )
        if !rl.FileExists(candidate_path_cstr) {
            export_path = strings.clone(candidate_path)
            break
        }
    }

    export_path_cstr := strings.clone_to_cstring(
        export_path,
        context.temp_allocator,
    )
    export_succeeded = rl.ExportImage(texture_readback, export_path_cstr)
    return
}

update_camera_controls :: proc(
    camera: ^rl.Camera3D,
    scene_size: f32,
    orbit_pivot: rl.Vector3,
) -> bool {
    frame_time := rl.GetFrameTime()
    move_speed := scene_size * 2.0
    camera_changed := false
    if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
        move_speed *= 4.0
    }
    move_distance := move_speed * frame_time

    camera_forward := rl.GetCameraForward(camera)
    camera_right := rl.GetCameraRight(camera)
    camera_up := rl.Vector3Normalize(
        rl.Vector3CrossProduct(camera_right, camera_forward),
    )

    // WASD and arrows now have one unambiguous meaning: translation in the
    // visible camera plane. Q/E are reserved for orthographic zoom.
    pan_delta: rl.Vector3
    if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) {
        pan_delta += camera_up * move_distance
    }
    if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN) {
        pan_delta -= camera_up * move_distance
    }
    if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) {
        pan_delta -= camera_right * move_distance
    }
    if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) {
        pan_delta += camera_right * move_distance
    }
    if pan_delta.x != 0 || pan_delta.y != 0 || pan_delta.z != 0 {
        camera.position += pan_delta
        camera.target += pan_delta
        camera_changed = true
    }

    keyboard_zoom_factor := 1.0 + frame_time * 1.5
    if rl.IsKeyDown(.Q) {
        camera.fovy *= keyboard_zoom_factor
        camera_changed = true
    }
    if rl.IsKeyDown(.E) {
        camera.fovy = max(
            camera.fovy / keyboard_zoom_factor,
            scene_size * 0.05,
        )
        camera_changed = true
    }

    mouse_delta := rl.GetMouseDelta()
    if rl.IsMouseButtonDown(.LEFT) {
        mouse_look_sensitivity: f32 = 0.003
        yaw_delta := -mouse_delta.x * mouse_look_sensitivity
        pitch_delta := -mouse_delta.y * mouse_look_sensitivity

        // Turntable orbit: yaw is always around world Y, while pitch is around
        // the current horizontal camera-right axis. Never rotate camera.up;
        // doing so turns this into a trackball and introduces unwanted roll.
        world_up := rl.Vector3{0, 1, 0}
        position_from_pivot := camera.position - orbit_pivot
        target_from_pivot := camera.target - orbit_pivot

        if yaw_delta != 0 {
            position_from_pivot = rl.Vector3RotateByAxisAngle(
                position_from_pivot,
                world_up,
                yaw_delta,
            )
            target_from_pivot = rl.Vector3RotateByAxisAngle(
                target_from_pivot,
                world_up,
                yaw_delta,
            )
        }

        if pitch_delta != 0 {
            yawed_position := orbit_pivot + position_from_pivot
            yawed_target := orbit_pivot + target_from_pivot
            yawed_forward := rl.Vector3Normalize(yawed_target - yawed_position)
            camera_right := rl.Vector3CrossProduct(yawed_forward, world_up)
            right_length := rl.Vector3Length(camera_right)

            // At a top/bottom view the world-up cross product is singular.
            // Retain the previous screen-right direction until the camera has
            // moved far enough away from the pole to derive it again.
            if right_length < 0.00001 {
                camera_right = rl.GetCameraRight(camera)
                camera_right.y = 0
                right_length = rl.Vector3Length(camera_right)
            }
            if right_length >= 0.00001 {
                camera_right /= right_length

                max_elevation := f32(math.PI / 2 - 0.01)
                elevation := math.asin(
                    min(max(rl.Vector3DotProduct(yawed_forward, world_up), -1), 1),
                )
                clamped_pitch := min(
                    max(pitch_delta, -max_elevation - elevation),
                    max_elevation - elevation,
                )

                position_from_pivot = rl.Vector3RotateByAxisAngle(
                    position_from_pivot,
                    camera_right,
                    clamped_pitch,
                )
                target_from_pivot = rl.Vector3RotateByAxisAngle(
                    target_from_pivot,
                    camera_right,
                    clamped_pitch,
                )
            }
        }

        camera.position = orbit_pivot + position_from_pivot
        camera.target = orbit_pivot + target_from_pivot
        final_forward := rl.Vector3Normalize(camera.target - camera.position)
        if math.abs(rl.Vector3DotProduct(final_forward, world_up)) > 0.99995 {
            // An exact top/bottom view cannot use world Y as the view-up
            // vector. Keep its existing orthogonal screen-up until it leaves
            // the pole; yaw itself still remains locked to world Y.
            fallback_up := camera.up - final_forward *
                           rl.Vector3DotProduct(camera.up, final_forward)
            if rl.Vector3Length(fallback_up) < 0.00001 {
                fallback_up = rl.Vector3CrossProduct(camera_right, final_forward)
            }
            camera.up = rl.Vector3Normalize(fallback_up)
        } else {
            camera.up = world_up
        }
        if mouse_delta.x != 0 || mouse_delta.y != 0 {
            camera_changed = true
        }
    }

    if rl.IsMouseButtonDown(.MIDDLE) {
        pan_sensitivity := camera.fovy / f32(rl.GetScreenHeight())
        mouse_pan_delta := camera_right * (-mouse_delta.x * pan_sensitivity) +
                           camera_up * (mouse_delta.y * pan_sensitivity)
        camera.position += mouse_pan_delta
        camera.target += mouse_pan_delta
        if mouse_delta.x != 0 || mouse_delta.y != 0 {
            camera_changed = true
        }
    }

    wheel_delta := rl.GetMouseWheelMove()
    if wheel_delta != 0 {
        zoom_factor := 1.0 - wheel_delta * 0.1
        camera.fovy = max(camera.fovy * zoom_factor, scene_size * 0.05)
        camera_changed = true
    }

    return camera_changed
}

draw_orthographic_snap_debug :: proc(
    camera: ^rl.Camera3D,
    snap_anchor: rl.Vector3,
    pixel_target_height: i32,
    lens_bounds: rl.Rectangle,
    lens_mode: Lens_Mode,
    lens_grid_visible: bool,
    coverage_alpha: f32,
) {
    world_units_per_pixel := camera.fovy / f32(pixel_target_height)
    camera_forward := rl.GetCameraForward(camera)
    camera_right := rl.GetCameraRight(camera)
    camera_up := rl.Vector3Normalize(
        rl.Vector3CrossProduct(camera_right, camera_forward),
    )

    pan_offset := camera.target - snap_anchor
    camera_grid_x := rl.Vector3DotProduct(pan_offset, camera_right) / world_units_per_pixel
    camera_grid_y := rl.Vector3DotProduct(pan_offset, camera_up) / world_units_per_pixel
    snapped_grid_x := math.round(camera_grid_x)
    snapped_grid_y := math.round(camera_grid_y)
    snapped_plane_x := snapped_grid_x * world_units_per_pixel
    snapped_plane_y := snapped_grid_y * world_units_per_pixel

    panel_height: f32 = 150
    if lens_mode == .COVERAGE_MASK {
        panel_height += 22
    }
    panel_bounds := rl.Rectangle{10, 10, 280, panel_height}
    rl.GuiPanel(panel_bounds, "ORTHOGRAPHIC PIXEL SNAP")

    label_x := panel_bounds.x + 12
    label_y := panel_bounds.y + 30
    label_width := panel_bounds.width - 24
    label_height: f32 = 18
    line_height: f32 = 22

    rl.GuiLabel(
        {label_x, label_y, label_width, label_height},
        rl.TextFormat("world units/pixel: %.8f", world_units_per_pixel),
    )
    label_y += line_height
    rl.GuiLabel(
        {label_x, label_y, label_width, label_height},
        rl.TextFormat("pan grid: (%.3f, %.3f)", camera_grid_x, camera_grid_y),
    )
    label_y += line_height
    rl.GuiLabel(
        {label_x, label_y, label_width, label_height},
        rl.TextFormat("nearest snap: (%.0f, %.0f)", snapped_grid_x, snapped_grid_y),
    )
    label_y += line_height
    rl.GuiLabel(
        {label_x, label_y, label_width, label_height},
        rl.TextFormat("snap plane: (%.6f, %.6f)", snapped_plane_x, snapped_plane_y),
    )
    label_y += line_height
    lens_mode_text: cstring = "PIXELATED [1]"
    if lens_mode == .BLENDED {
        lens_mode_text = "BLENDED 50/50 [2]"
    } else if lens_mode == .COVERAGE_MASK {
        lens_mode_text = "COVERAGE MASK [3]"
    }
    rl.GuiLabel(
        {label_x, label_y, label_width, label_height},
        rl.TextFormat("lens mode: %s", lens_mode_text),
    )
    if lens_mode == .COVERAGE_MASK {
        label_y += line_height
        if coverage_alpha >= 0 {
            coverage_sample_count := i32(math.round(coverage_alpha * 16.0))
            rl.GuiLabel(
                {label_x, label_y, label_width, label_height},
                rl.TextFormat(
                    "coverage: %d/16  alpha: %.4f",
                    coverage_sample_count,
                    coverage_alpha,
                ),
            )
        } else {
            rl.GuiLabel(
                {label_x, label_y, label_width, label_height},
                "coverage: hover a lens pixel",
            )
        }
    }

    if lens_grid_visible {
        grid_column_count := int(lens_bounds.width) / PIXEL_SCALE
        grid_row_count := int(lens_bounds.height) / PIXEL_SCALE

        for column_index := 0; column_index <= grid_column_count; column_index += 1 {
            grid_line_x := lens_bounds.x + f32(column_index * PIXEL_SCALE)
            grid_line_color := rl.Color{255, 255, 255, 45}
            if column_index % 5 == 0 {
                grid_line_color = rl.Color{255, 230, 80, 100}
            }
            rl.DrawLineV(
                {grid_line_x, lens_bounds.y},
                {grid_line_x, lens_bounds.y + lens_bounds.height},
                grid_line_color,
            )
        }

        for row_index := 0; row_index <= grid_row_count; row_index += 1 {
            grid_line_y := lens_bounds.y + f32(row_index * PIXEL_SCALE)
            grid_line_color := rl.Color{255, 255, 255, 45}
            if row_index % 5 == 0 {
                grid_line_color = rl.Color{255, 230, 80, 100}
            }
            rl.DrawLineV(
                {lens_bounds.x, grid_line_y},
                {lens_bounds.x + lens_bounds.width, grid_line_y},
                grid_line_color,
            )
        }
    }
}

run_application :: proc() -> int {
    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    capture_parse_result := parse_capture_options(os.args[1:])
    defer destroy_capture_options(&capture_parse_result.options)
    if capture_parse_result.options.help_requested {
        print_capture_usage()
        return 0
    }
    if capture_parse_result.error != .NONE {
        log.errorf(
            "%s: %s",
            capture_parse_error_message(capture_parse_result.error),
            capture_parse_result.error_argument,
        )
        print_capture_usage()
        return 2
    }
    capture_options := &capture_parse_result.options

    model_assets := scan_model_assets(ASSETS_PATH)
    defer destroy_model_assets(&model_assets)

    rl.SetTraceLogLevel(.WARNING);
    // inspect_glb(DEFAULT_MODEL_PATH);

    if capture_options.enabled {
        if capture_options.hide_window {
            rl.SetConfigFlags({.WINDOW_ALWAYS_RUN, .WINDOW_HIDDEN})
        } else {
            rl.SetConfigFlags({.WINDOW_ALWAYS_RUN})
        }
    } else {
        rl.SetConfigFlags({.WINDOW_TOPMOST})
    }
    rl.InitWindow(1280, 720, "Lab0")
    defer rl.CloseWindow();
	if capture_options.enabled {
		// Keep raygui hover and the coverage probe independent of the desktop's
		// shared cursor while a deterministic capture is running.
		rl.SetMouseOffset(-100000, -100000)
	}
	rgl.SetClipPlanes(0.001, 1000.0)

    rl.SetTargetFPS(60);

    scene_shader, scene_shader_source, scene_shader_loaded :=
        load_shader_with_includes(VS_PATH, FS_PATH)
    defer rl.UnloadShader(scene_shader)
    defer destroy_preprocessed_shader_program_source(&scene_shader_source)
    assert(scene_shader_loaded)

    downscale_shader, downscale_shader_source, downscale_shader_loaded :=
        load_fragment_shader_with_includes(DOWNSCALE_FS_PATH)
    defer rl.UnloadShader(downscale_shader)
    defer destroy_preprocessed_shader_source(&downscale_shader_source)
    assert(downscale_shader_loaded)

    cel_band_shader, cel_band_shader_source, cel_band_shader_loaded := load_shader_with_includes(
        VS_PATH,
        CEL_BAND_FS_PATH,
    )
    defer destroy_preprocessed_shader_program_source(&cel_band_shader_source)
    assert(cel_band_shader_loaded)
    cel_band_material := rl.LoadMaterialDefault()
    defer rl.UnloadMaterial(cel_band_material)
    cel_band_material.shader = cel_band_shader

    mask_downscale_shader, mask_downscale_shader_source, mask_downscale_shader_loaded :=
        load_fragment_shader_with_includes(MASK_DOWNSCALE_FS_PATH)
    defer rl.UnloadShader(mask_downscale_shader)
    defer destroy_preprocessed_shader_source(&mask_downscale_shader_source)
    assert(mask_downscale_shader_loaded)

    active_model: rl.Model
    animation_playback: Animation_Playback
    defer {
        destroy_animation_playback(&animation_playback)
        if is_model_loaded(active_model) {
            rl.UnloadModel(active_model)
        }
    }

    render_camera := rl.Camera3D{
        position   = {1.5, 0.7, 1.5},
        target     = {},
        up         = {0, 1, 0},
        fovy       = 2.5,
        projection = .ORTHOGRAPHIC,
    }
    scene_size: f32 = 1
    model_center: rl.Vector3
    loaded_model_index: c.int = -1
    model_active_index: c.int = -1
    model_load_failed := false
    model_browser := Model_Browser_State{
        active_index = -1,
        focus_index = -1,
    }
    defer destroy_model_browser_state(&model_browser)
    rebuild_model_search_results(&model_assets, &model_browser)

    if len(model_assets.paths) > 0 {
        initial_model_index := 0
        if capture_options.enabled && len(capture_options.model_source) > 0 {
            requested_model_index, requested_model_found :=
                find_capture_model_source(
                    &model_assets,
                    capture_options.model_source,
                )
            if !requested_model_found {
                log.errorf(
                    "Capture model source was not found: %s",
                    capture_options.model_source,
                )
                return 2
            }
            initial_model_index = requested_model_index
        } else {
            for model_path, model_index in model_assets.paths {
                if model_path == DEFAULT_MODEL_PATH ||
                   strings.has_suffix(model_path, "/" + DEFAULT_MODEL_PATH) {
                    initial_model_index = model_index
                    break
                }
            }
        }

        initial_model := load_model_source(&model_assets, initial_model_index)
        if is_model_loaded(initial_model) {
            active_model = initial_model
            animation_playback = load_animation_playback(
                active_model,
                model_assets.paths[initial_model_index],
                model_assets.kinds[initial_model_index],
            )
            model_center = get_model_center(active_model)
            loaded_model_index = c.int(initial_model_index)
            model_active_index = loaded_model_index
            set_model_browser_active_source(
                &model_browser,
                loaded_model_index,
            )
            scene_size = frame_camera_to_model(
                active_model,
                model_assets.kinds[initial_model_index],
                &render_camera,
            )
            if capture_options.enabled {
                apply_capture_view(
                    capture_options.view,
                    &render_camera,
                    model_center,
                    scene_size,
                )
                animation_playback.is_playing = false
                if capture_options.animation_frame_set ||
                   capture_options.frame_range_set {
                    capture_animation, capture_animation_found :=
                        get_active_animation(&animation_playback)
                    if !capture_animation_found {
                        if capture_options.frame_range_set {
                            log.errorf(
                                "Capture frame range %d:%d:%d was requested, but %s has no playable animation",
                                capture_options.frame_range_start,
                                capture_options.frame_range_end,
                                capture_options.frame_range_step,
                                model_assets.paths[initial_model_index],
                            )
                        } else {
                            log.errorf(
                                "Capture frame %.3f was requested, but %s has no playable animation",
                                capture_options.animation_frame,
                                model_assets.paths[initial_model_index],
                            )
                        }
                        return 2
                    }
                    capture_last_frame := f32(max(
                        capture_animation.keyframeCount - 1,
                        0,
                    ))
                    requested_last_frame := capture_options.animation_frame
                    if capture_options.frame_range_set {
                        requested_last_frame = f32(capture_options.frame_range_end)
                    }
                    if requested_last_frame > capture_last_frame {
                        log.errorf(
                            "Capture frame %.3f exceeds the animation's last frame %.3f",
                            requested_last_frame,
                            capture_last_frame,
                        )
                        return 2
                    }
                    requested_first_frame := capture_options.animation_frame
                    if capture_options.frame_range_set {
                        requested_first_frame = f32(capture_options.frame_range_start)
                    }
                    animation_playback.current_frame = requested_first_frame
                    animation_playback.pose_dirty = true
                    update_animation_playback(
                        &animation_playback,
                        active_model,
                    )
                }
            }
            log.infof(
                "Loaded initial model: %s",
                model_assets.paths[initial_model_index],
            )
        } else {
            rl.UnloadModel(initial_model)
            model_load_failed = true
            log.errorf(
                "Failed to load initial model: %s",
                model_assets.paths[initial_model_index],
            )
            if capture_options.enabled {
                return 1
            }
        }
    }
    // Keep continuous input state separate from the quantized render camera.
    // Otherwise a sub-pixel drag would be rounded away every frame and could
    // never accumulate enough movement to cross the next pixel boundary.
    control_camera := render_camera

    screen_width := rl.GetScreenWidth()
    screen_height := rl.GetScreenHeight()
    scene_render_target := rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(scene_render_target)
    cel_band_render_target := rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(cel_band_render_target)
    rl.SetTextureFilter(cel_band_render_target.texture, .POINT)
    rl.SetTextureWrap(cel_band_render_target.texture, .CLAMP)

    downsample_width := screen_width / PIXEL_SCALE
    downsample_height := screen_height / PIXEL_SCALE
    downsample_render_target := rl.LoadRenderTexture(
        downsample_width,
        downsample_height,
    )
    defer rl.UnloadRenderTexture(downsample_render_target)
    rl.SetTextureFilter(downsample_render_target.texture, .POINT)
    coverage_mask_render_target := rl.LoadRenderTexture(
        downsample_width,
        downsample_height,
    )
    defer rl.UnloadRenderTexture(coverage_mask_render_target)
    rl.SetTextureFilter(coverage_mask_render_target.texture, .POINT)
    composite_render_target := rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(composite_render_target)
    rl.SetTextureFilter(composite_render_target.texture, .POINT)

    scene_resolution := [2]f32{f32(screen_width), f32(screen_height)}
    downsample_resolution := [2]f32{
        f32(downsample_width),
        f32(downsample_height),
    }
    downscale_source_resolution_location := rl.GetShaderLocation(
        downscale_shader,
        "u_source_resolution",
    )
    downscale_target_resolution_location := rl.GetShaderLocation(
        downscale_shader,
        "u_target_resolution",
    )
    downscale_cel_band_texture_location := rl.GetShaderLocation(
        downscale_shader,
        "u_cel_band_texture",
    )
    downscale_color_cluster_threshold_location := rl.GetShaderLocation(
        downscale_shader,
        "u_color_cluster_threshold",
    )
    mask_downscale_source_resolution_location := rl.GetShaderLocation(
        mask_downscale_shader,
        "u_source_resolution",
    )
    mask_downscale_target_resolution_location := rl.GetShaderLocation(
        mask_downscale_shader,
        "u_target_resolution",
    )
    color_cluster_threshold := f32(DEFAULT_COLOR_CLUSTER_THRESHOLD)

    lens_mode := Lens_Mode.PIXELATED
    if capture_options.enabled {
        lens_mode = capture_options.lens_mode
    }
    lens_grid_visible := true
    scene_background_color := rl.BLACK
    background_picker_open := false
    model_browser_bounds := rl.Rectangle{f32(screen_width) - 280, 10, 270, 310}
    camera_controls_bounds := rl.Rectangle{f32(screen_width) - 280, 330, 270, 250}
    background_controls_bounds := rl.Rectangle{
        f32(screen_width) - 280,
        590,
        270,
        120,
    }
    background_picker_bounds := rl.Rectangle{
        f32(screen_width) - 510,
        360,
        220,
        212,
    }
    animation_controls_bounds := rl.Rectangle{10, 190, 280, 190}
    magnifier_bounds := rl.Rectangle{10, f32(screen_height) - 194, 148, 184}
    coverage_alpha: f32 = -1
    next_export_index := 1
    last_export_path: string
    defer {
        if len(last_export_path) > 0 {
            delete(last_export_path)
        }
    }
    last_export_succeeded := false
    last_export_time: f64 = -10
    capture_complete := false
    capture_succeeded := false
    rendered_capture_frames := 0
    capture_sequence_frame := capture_options.frame_range_start
    captured_sequence_frames := 0

    for !rl.WindowShouldClose() && !capture_complete {
        window_focused := rl.IsWindowFocused()
        if capture_options.enabled {
            // A capture never consumes live desktop input, even when its
            // window is shown for debugging.
            window_focused = false
        } else {
            if window_focused {
                rl.SetWindowOpacity(1.0)
            } else {
                rl.SetWindowOpacity(0.5)
            }
        }

        search_shortcut_modifier := rl.IsKeyDown(.LEFT_CONTROL) ||
                                    rl.IsKeyDown(.RIGHT_CONTROL) ||
                                    rl.IsKeyDown(.LEFT_SUPER) ||
                                    rl.IsKeyDown(.RIGHT_SUPER)
        if window_focused && search_shortcut_modifier && rl.IsKeyPressed(.F) {
            model_browser.search_editing = true
            // Do not let the shortcut's F leak into the newly focused field.
            for rl.GetCharPressed() != 0 {}
        }

        ui_mouse_position := rl.GetMousePosition()
        mouse_over_model_browser := rl.CheckCollisionPointRec(
            ui_mouse_position,
            model_browser_bounds,
        )
        mouse_over_camera_controls := rl.CheckCollisionPointRec(
            ui_mouse_position,
            camera_controls_bounds,
        )
        mouse_over_background_controls := rl.CheckCollisionPointRec(
            ui_mouse_position,
            background_controls_bounds,
        )
        mouse_over_animation_controls := has_playable_animations(
            &animation_playback,
        ) && rl.CheckCollisionPointRec(
            ui_mouse_position,
            animation_controls_bounds,
        )
        if window_focused &&
           !background_picker_open &&
           !animation_playback.dropdown_open &&
           !model_browser.search_editing &&
           !mouse_over_model_browser &&
           !mouse_over_camera_controls &&
           !mouse_over_background_controls &&
           !mouse_over_animation_controls {
            update_camera_controls(&control_camera, scene_size, model_center)
        }
        render_camera = control_camera
        snap_orthographic_zoom_to_pixel_grid(
            &render_camera,
            scene_size,
            downsample_height,
        )
        snap_orthographic_camera_to_pixel_grid(
            &render_camera,
            model_center,
            downsample_height,
        )

        export_requested := false
        if window_focused && !model_browser.search_editing {
            if rl.IsKeyPressed(.ONE) || rl.IsKeyPressed(.KP_1) {
                lens_mode = .PIXELATED
                log.info("Lens mode: pixelated")
            }
            if rl.IsKeyPressed(.TWO) || rl.IsKeyPressed(.KP_2) {
                lens_mode = .BLENDED
                log.info("Lens mode: blended 50/50")
            }
            if rl.IsKeyPressed(.THREE) || rl.IsKeyPressed(.KP_3) {
                lens_mode = .COVERAGE_MASK
                log.info("Lens mode: 16-sample coverage mask")
            }
            if rl.IsKeyPressed(.G) {
                lens_grid_visible = !lens_grid_visible
                if lens_grid_visible {
                    log.info("Lens grid: on")
                } else {
                    log.info("Lens grid: off")
                }
            }
            if rl.IsKeyPressed(.P) {
                export_requested = true
            }
            if has_playable_animations(&animation_playback) &&
               !animation_playback.dropdown_open &&
               rl.IsKeyPressed(.SPACE) {
                animation_playback.is_playing = !animation_playback.is_playing
            }
        }

        update_animation_playback(&animation_playback, active_model)

        if !capture_options.enabled {
            _ = reload_shader_with_includes(
                VS_PATH,
                FS_PATH,
                &scene_shader,
                &scene_shader_source,
            )

            if reload_shader_with_includes(
                VS_PATH,
                CEL_BAND_FS_PATH,
                &cel_band_shader,
                &cel_band_shader_source,
            ) {
                cel_band_material.shader = cel_band_shader
            }

            if reload_fragment_shader_with_includes(
                DOWNSCALE_FS_PATH,
                &downscale_shader,
                &downscale_shader_source,
            ) {
                downscale_source_resolution_location = rl.GetShaderLocation(
                    downscale_shader,
                    "u_source_resolution",
                )
                downscale_target_resolution_location = rl.GetShaderLocation(
                    downscale_shader,
                    "u_target_resolution",
                )
                downscale_cel_band_texture_location = rl.GetShaderLocation(
                    downscale_shader,
                    "u_cel_band_texture",
                )
                downscale_color_cluster_threshold_location = rl.GetShaderLocation(
                    downscale_shader,
                    "u_color_cluster_threshold",
                )
            }

            if reload_fragment_shader_with_includes(
                MASK_DOWNSCALE_FS_PATH,
                &mask_downscale_shader,
                &mask_downscale_shader_source,
            ) {
                mask_downscale_source_resolution_location = rl.GetShaderLocation(
                    mask_downscale_shader,
                    "u_source_resolution",
                )
                mask_downscale_target_resolution_location = rl.GetShaderLocation(
                    mask_downscale_shader,
                    "u_target_resolution",
                )
            }
        }

        rl.SetShaderValue(
            downscale_shader,
            downscale_source_resolution_location,
            &scene_resolution,
            .VEC2,
        )
        rl.SetShaderValue(
            downscale_shader,
            downscale_target_resolution_location,
            &downsample_resolution,
            .VEC2,
        )
        rl.SetShaderValue(
            downscale_shader,
            downscale_color_cluster_threshold_location,
            &color_cluster_threshold,
            .FLOAT,
        )
        rl.SetShaderValue(
            mask_downscale_shader,
            mask_downscale_source_resolution_location,
            &scene_resolution,
            .VEC2,
        )
        rl.SetShaderValue(
            mask_downscale_shader,
            mask_downscale_target_resolution_location,
            &downsample_resolution,
            .VEC2,
        )

        rl.BeginTextureMode(scene_render_target)
            draw_scene(scene_shader, active_model, render_camera)
        rl.EndTextureMode()

        rl.BeginTextureMode(cel_band_render_target)
            draw_model_cel_bands(cel_band_material, active_model, render_camera)
        rl.EndTextureMode()

        flipped_scene_source_bounds := rl.Rectangle{
            width  = f32(screen_width),
            height = -f32(screen_height),
        }

        rl.BeginTextureMode(downsample_render_target)
            rl.ClearBackground(rl.BLANK)
            rl.BeginShaderMode(downscale_shader)
                rl.SetShaderValueTexture(
                    downscale_shader,
                    downscale_cel_band_texture_location,
                    cel_band_render_target.texture,
                )
                rl.DrawTexturePro(
                    scene_render_target.texture,
                    flipped_scene_source_bounds,
                    {0, 0, f32(downsample_width), f32(downsample_height)},
                    {},
                    0,
                    rl.WHITE,
                )
            rl.EndShaderMode()
        rl.EndTextureMode()

        rl.BeginTextureMode(coverage_mask_render_target)
            rl.ClearBackground(rl.BLANK)
            rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
            rl.BeginShaderMode(mask_downscale_shader)
                rl.DrawTexturePro(
                    cel_band_render_target.texture,
                    flipped_scene_source_bounds,
                    {0, 0, f32(downsample_width), f32(downsample_height)},
                    {},
                    0,
                    rl.WHITE,
                )
            rl.EndShaderMode()
            rl.EndBlendMode()
        rl.EndTextureMode()

        rl.BeginTextureMode(composite_render_target)
            rl.ClearBackground(scene_background_color)
            rl.DrawTexturePro(
                scene_render_target.texture,
                flipped_scene_source_bounds,
                {0, 0, f32(screen_width), f32(screen_height)},
                {},
                0,
                rl.WHITE,
            )

            lens_bounds := rl.Rectangle{
                x      = (f32(screen_width) - LENS_WIDTH) / 2,
                y      = (f32(screen_height) - LENS_HEIGHT) / 2,
                width  = LENS_WIDTH,
                height = LENS_HEIGHT,
            }

            lens_texture_source_bounds := rl.Rectangle{
                x      = lens_bounds.x / PIXEL_SCALE,
                y      = f32(downsample_height) -
                         (lens_bounds.y + lens_bounds.height) / PIXEL_SCALE,
                width  = lens_bounds.width / PIXEL_SCALE,
                height = -lens_bounds.height / PIXEL_SCALE,
            }
            coverage_alpha = -1
            lens_mouse_position := rl.GetMousePosition()
            if lens_mode == .COVERAGE_MASK &&
               rl.CheckCollisionPointRec(lens_mouse_position, lens_bounds) {
                lens_column := c.int(
                    (lens_mouse_position.x - lens_bounds.x) / f32(PIXEL_SCALE),
                )
                lens_row := c.int(
                    (lens_mouse_position.y - lens_bounds.y) / f32(PIXEL_SCALE),
                )
                mask_pixel_x := c.int(lens_bounds.x / f32(PIXEL_SCALE)) +
                                lens_column
                mask_pixel_y := c.int(lens_bounds.y / f32(PIXEL_SCALE)) +
                                lens_row
                mask_readback := rl.LoadImageFromTexture(
                    coverage_mask_render_target.texture,
                )
                mask_readback_y := mask_readback.height - 1 - mask_pixel_y
                coverage_pixel := rl.GetImageColor(
                    mask_readback,
                    mask_pixel_x,
                    mask_readback_y,
                )
                coverage_alpha = f32(coverage_pixel.a) / 255.0
                rl.UnloadImage(mask_readback)
            }
            lens_tint := rl.WHITE
            if lens_mode == .BLENDED {
                lens_tint.a = 128
            }
            active_lens_texture := downsample_render_target.texture
            if lens_mode == .COVERAGE_MASK {
                active_lens_texture = coverage_mask_render_target.texture
            }
            if lens_mode == .COVERAGE_MASK {
                rl.DrawRectangleRec(lens_bounds, scene_background_color)
                rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
                    rl.DrawTexturePro(
                        active_lens_texture,
                        lens_texture_source_bounds,
                        lens_bounds,
                        {},
                        0,
                        lens_tint,
                    )
                rl.EndBlendMode()
            } else {
                rl.DrawTexturePro(
                    active_lens_texture,
                    lens_texture_source_bounds,
                    lens_bounds,
                    {},
                    0,
                    lens_tint,
                )
            }
            draw_coordinate_grid_overlay(render_camera, active_model, scene_size)
            draw_orthographic_snap_debug(
                &render_camera,
                model_center,
                downsample_height,
                lens_bounds,
                lens_mode,
                lens_grid_visible,
                coverage_alpha,
            )
            rl.DrawRectangleLinesEx(lens_bounds, 2, rl.WHITE)

            export_button_bounds := rl.Rectangle{
                lens_bounds.x + (lens_bounds.width - 300) / 2,
                lens_bounds.y + lens_bounds.height + 10,
                300,
                28,
            }
            if rl.GuiButton(
                export_button_bounds,
                rl.TextFormat(
                    "EXPORT %d x %d TRANSPARENT PNG [P]",
                    c.int(LENS_WIDTH / PIXEL_SCALE),
                    c.int(LENS_HEIGHT / PIXEL_SCALE),
                ),
            ) {
                export_requested = true
            }
            if rl.GetTime() - last_export_time < 5.0 {
                export_status: cstring = "PNG export failed"
                if last_export_succeeded {
                    last_export_path_cstr := strings.clone_to_cstring(
                        last_export_path,
                        context.temp_allocator,
                    )
                    export_status = rl.TextFormat("Saved: %s", last_export_path_cstr)
                }
                rl.GuiLabel(
                    {
                        lens_bounds.x,
                        export_button_bounds.y + export_button_bounds.height + 2,
                        lens_bounds.width,
                        18,
                    },
                    export_status,
                )
            }
            draw_model_browser(
                model_browser_bounds,
                &model_assets,
                &model_browser,
                loaded_model_index,
                model_load_failed,
                &model_active_index,
            )
            draw_animation_controls(
                animation_controls_bounds,
                &animation_playback,
            )
            draw_camera_controls(
                camera_controls_bounds,
                &control_camera,
                model_center,
                scene_size,
                downsample_width,
                downsample_height,
                lens_grid_visible,
            )
            draw_background_controls(
                background_controls_bounds,
                background_picker_bounds,
                &scene_background_color,
                &background_picker_open,
            )
        rl.EndTextureMode()

        if export_requested {
            if len(last_export_path) > 0 {
                delete(last_export_path)
                last_export_path = ""
            }
            last_export_path, last_export_succeeded = export_lens_downsample_png(
                downsample_render_target.texture,
                lens_bounds,
                PIXEL_SCALE,
                &next_export_index,
            )
            last_export_time = rl.GetTime()
            if last_export_succeeded {
                log.infof("Exported transparent lens PNG: %s", last_export_path)
            } else {
                log.error("Failed to export transparent lens PNG")
            }
        }

        rl.BeginDrawing()
            rl.ClearBackground(scene_background_color)
            rl.DrawTexturePro(
                composite_render_target.texture,
                flipped_scene_source_bounds,
                {0, 0, f32(screen_width), f32(screen_height)},
                {},
                0,
                rl.WHITE,
            )
            draw_mouse_magnifier(
                magnifier_bounds,
                composite_render_target.texture,
                rl.GetMousePosition(),
                screen_width,
                screen_height,
            )
        rl.EndDrawing()

        if capture_options.enabled {
            rendered_capture_frames += 1
            if rendered_capture_frames >= capture_options.warmup_frames {
                capture_output_path := capture_options.output_path
                capture_output_path_owned := false
                if capture_options.frame_range_set {
                    capture_output_path = format_capture_sequence_output_path(
                        capture_options.output_path,
                        capture_options.output_template,
                        capture_sequence_frame,
                    )
                    capture_output_path_owned = true
                }
                capture_succeeded = export_capture_target(
                    capture_options,
                    capture_output_path,
                    composite_render_target,
                    scene_render_target,
                    downsample_render_target,
                    coverage_mask_render_target,
                    lens_bounds,
                )
                if capture_succeeded {
                    if capture_options.frame_range_set {
                        captured_sequence_frames += 1
                        log.infof(
                            "Captured case %s frame %d to %s",
                            capture_options.case_name,
                            capture_sequence_frame,
                            capture_output_path,
                        )
                    } else {
                        log.infof(
                            "Captured case %s to %s",
                            capture_options.case_name,
                            capture_output_path,
                        )
                    }
                } else {
                    log.errorf(
                        "Failed to capture case %s to %s",
                        capture_options.case_name,
                        capture_output_path,
                    )
                }
                if capture_output_path_owned {
                    delete(capture_output_path)
                }

                if !capture_succeeded || !capture_options.frame_range_set {
                    capture_complete = true
                } else if capture_options.frame_range_step <=
                          capture_options.frame_range_end &&
                          capture_sequence_frame <=
                          capture_options.frame_range_end -
                          capture_options.frame_range_step {
                    capture_sequence_frame += capture_options.frame_range_step
                    animation_playback.current_frame = f32(capture_sequence_frame)
                    animation_playback.pose_dirty = true
                } else {
                    capture_complete = true
                    log.infof(
                        "Captured sequence case %s with %d frame(s)",
                        capture_options.case_name,
                        captured_sequence_frames,
                    )
                }
            }
        }

        if model_active_index != loaded_model_index &&
           model_active_index >= 0 &&
            int(model_active_index) < len(model_assets.paths) {
            requested_model_index := int(model_active_index)
            requested_model_label := model_assets.labels[requested_model_index]
            requested_model := load_model_source(
                &model_assets,
                requested_model_index,
            )
            if is_model_loaded(requested_model) {
                requested_animation_playback := load_animation_playback(
                    requested_model,
                    model_assets.paths[requested_model_index],
                    model_assets.kinds[requested_model_index],
                )
                destroy_animation_playback(&animation_playback)
                if is_model_loaded(active_model) {
                    rl.UnloadModel(active_model)
                }
                active_model = requested_model
                animation_playback = requested_animation_playback
                model_center = get_model_center(active_model)
                loaded_model_index = model_active_index
                set_model_browser_active_source(
                    &model_browser,
                    loaded_model_index,
                )
                scene_size = frame_camera_to_model(
                    active_model,
                    model_assets.kinds[requested_model_index],
                    &render_camera,
                )
                control_camera = render_camera
                model_load_failed = false
                log.infof("Loaded model: %s", requested_model_label)
            } else {
                rl.UnloadModel(requested_model)
                model_active_index = loaded_model_index
                set_model_browser_active_source(
                    &model_browser,
                    loaded_model_index,
                )
                model_load_failed = true
                log.errorf("Failed to load model: %s", requested_model_label)
            }
        }
    }

    if capture_options.enabled && (!capture_complete || !capture_succeeded) {
        return 1
    }
    return 0
}

main :: proc() {
    exit_code := run_application()
    if exit_code != 0 {
        os.exit(exit_code)
    }
}
