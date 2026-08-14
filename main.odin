package main

// Lab0 is a raylib model viewer that renders cel-shaded geometry into multiple
// intermediate textures, downsamples them into a configurable pixel grid, and
// presents both an interactive UI and a deterministic non-interactive capture
// path. This file owns application orchestration, assets, animation, camera
// behavior, render-pass ordering, and the inlined UI composition.

import "core:fmt"
import json "core:encoding/json"
import "core:os"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
import rgl "vendor:raylib/rlgl"

// Vertex is the minimal position/color layout used by procedural debug geometry.
Vertex :: struct {
    position: [3]f32,
    color: [4]f32,
}

VS_PATH             :: "shaders/custom.vs"
FS_PATH             :: "shaders/custom.fs"
DOWNSCALE_FS_PATH   :: "shaders/downscale.fs"
CEL_BAND_FS_PATH    :: "shaders/cel_band.fs"
MASK_DOWNSCALE_FS_PATH :: "shaders/mask_downscale.fs"
OUTLINE_FS_PATH        :: "shaders/outline.fs"
ASSETS_PATH         :: "assets"
DEFAULT_MODEL_PATH  :: "assets/CesiumMan.glb"
ANIMATION_SAMPLE_FPS :: 60.0
GLTF_SKIN_SCALE_EPSILON :: f32(0.0001)

DEFAULT_DOWNSCALE_LEVEL :: 10
MIN_DOWNSCALE_LEVEL     :: 1
MAX_DOWNSCALE_LEVEL     :: 32
LENS_WIDTH              :: 400
LENS_HEIGHT             :: 400
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

// Lens_Mode selects how the low-resolution render is composited into the 400px
// lens: nearest pixels, a 50/50 blend, or raw subpixel coverage visualization.
Lens_Mode :: enum {
    PIXELATED,
    BLENDED,
    COVERAGE_MASK,
}

// Model_Source_Kind distinguishes disk assets from generated primitives because
// loading, animation availability, and camera framing differ by source.
Model_Source_Kind :: enum {
    ASSET,
    CUBE,
    SPHERE,
    TRIANGLE,
}

// Builtin_Model_Source supplies the path-like ID and browser label for a
// generated primitive.
Builtin_Model_Source :: struct {
    kind:  Model_Source_Kind,
    path:  string,
    label: string,
}

// Built-ins are appended after sorted disk assets in this stable order.
BUILTIN_MODEL_SOURCES := [?]Builtin_Model_Source{
    {.CUBE,     "builtin:cube",     "Built-in / Cube"},
    {.SPHERE,   "builtin:sphere",   "Built-in / Sphere"},
    {.TRIANGLE, "builtin:triangle", "Built-in / Triangle"},
}

// get_downsample_dimension performs integer downscaling while guaranteeing a
// valid RenderTexture dimension. Non-positive levels preserve the source size.
get_downsample_dimension :: proc(
    source_dimension, downscale_level: c.int,
) -> c.int {
    if source_dimension <= 0 {
        return 1
    }
    if downscale_level <= 0 {
        return source_dimension
    }
    return max(source_dimension / downscale_level, 1)
}

// Model_Assets stores parallel arrays indexed by one canonical source index.
// paths and labels are owned strings released by destroy_model_assets.
Model_Assets :: struct {
    paths:  [dynamic]string,
    labels: [dynamic]cstring,
    kinds:  [dynamic]Model_Source_Kind,
}

// Model_Search_Result preserves the source index while sorting by fuzzy score.
Model_Search_Result :: struct {
    source_index: c.int,
    score:        int,
}

// Model_Browser_State separates filtered result indices from source storage and
// retains raygui list/search interaction state across frames.
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

// Animation_Playback owns raylib animation data, a filtered list of compatible
// clips, and both continuous and sampled timeline state. pose_dirty avoids
// redundant CPU skinning updates when the displayed pose has not changed.
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

// load_fragment_shader_with_includes preprocesses one fragment stage, compiles
// it from memory, and returns dependency state even when compilation fails.
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

// load_shader_with_includes preprocesses both program stages and compiles them
// together. The caller owns both the raylib shader and preprocessed sources.
load_shader_with_includes :: proc(vertex_path, fragment_path: string) -> (
    shader: rl.Shader,
    preprocessed_program: Preprocessed_Shader_Program_Source,
    loaded: bool,
) {
    // Preprocess both shader stages inline at this sole program-load site.
    vertex_preprocess_succeeded, fragment_preprocess_succeeded: bool
    preprocessed_program.vertex, vertex_preprocess_succeeded =
        preprocess_shader_file(vertex_path)
    preprocessed_program.fragment, fragment_preprocess_succeeded =
        preprocess_shader_file(fragment_path)
    preprocess_succeeded := vertex_preprocess_succeeded &&
                            fragment_preprocess_succeeded
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

// reload_fragment_shader_with_includes recompiles only after a dependency
// snapshot changes. A failed replacement is unloaded and the working shader is
// retained, while dependency state advances to prevent retrying every frame.
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

// reload_shader_with_includes applies the same safe replacement policy to a
// vertex/fragment program and transfers ownership of the new dependency state.
reload_shader_with_includes :: proc(
    vertex_path, fragment_path: string,
    shader: ^rl.Shader,
    preprocessed_program: ^Preprocessed_Shader_Program_Source,
) -> bool {
    // Check both stage dependency sets inline before attempting a reload.
    dependencies_changed :=
        shader_source_dependencies_changed(&preprocessed_program.vertex) ||
        shader_source_dependencies_changed(&preprocessed_program.fragment)
    if !dependencies_changed {
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

// destroy_model_assets frees every cloned path/label and all parallel arrays.
destroy_model_assets :: proc(assets: ^Model_Assets) {
    for asset_path in assets.paths do delete(asset_path)
    for asset_label in assets.labels do delete(asset_label)
    delete(assets.paths)
    delete(assets.labels)
    delete(assets.kinds)
}

// ascii_search_lower provides allocation-free case folding for asset filenames.
ascii_search_lower :: proc(value: u8) -> u8 {
    if value >= 'A' && value <= 'Z' {
        return value + ('a' - 'A')
    }
    return value
}

// is_model_search_separator defines optional query delimiters and word boundaries.
is_model_search_separator :: proc(value: u8) -> bool {
    switch value {
    case ' ', '\t', '_', '-', '/', '\\', '.', ':':
        return true
    }
    return false
}

// fuzzy_model_score matches query characters in order, rewarding consecutive
// matches, exact case, and word boundaries while penalizing gaps. Query
// separators are optional, so "female run" matches underscore-delimited names.
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
        // Reward a boundary directly where the fuzzy score consumes it.
        match_is_boundary := match_index == 0 ||
                             is_model_search_separator(candidate[match_index - 1])
        if match_is_boundary {
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

// rebuild_model_search_results scores both full paths and display labels, keeps
// the better score, sorts deterministically, and resets list navigation state.
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

// destroy_model_browser_state frees result arrays; labels remain asset-owned.
destroy_model_browser_state :: proc(browser: ^Model_Browser_State) {
    delete(browser.results)
    delete(browser.result_labels)
}

// set_model_browser_active_source maps a canonical source index back into the
// current filtered list, or clears selection when the source is filtered out.
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

// load_model_source dispatches disk loading or procedural mesh generation from
// one canonical source index. The caller owns and must unload a valid model.
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

// is_model_loaded accepts drawable geometry even when raylib rejects a model for
// a missing material texture; texture warnings are validated separately.
is_model_loaded :: proc(model: rl.Model) -> bool {
    // IsModelValid() also fails when an otherwise usable model has a missing
    // or unsupported material texture. The browser only needs drawable meshes.
    return model.meshCount > 0 && model.meshes != nil
}

// has_playable_animations checks both raylib storage and the compatible clip list.
has_playable_animations :: proc(playback: ^Animation_Playback) -> bool {
    return playback.animations != nil && len(playback.valid_indices) > 0
}

// get_active_animation validates both filtered and raw indices before returning
// a raylib animation value, protecting UI/capture code from stale selection.
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

// destroy_animation_playback unloads raylib animations, owned option text, and
// dynamic indices, then clears the complete playback state.
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

// get_pure_uniform_scale_from_matrix accepts only positive, origin-centered,
// axis-aligned uniform scales. Any translation, rotation, shear, or non-uniform
// component is rejected because the later correction handles scale alone.
get_pure_uniform_scale_from_matrix :: proc(
    transform: [16]f32,
) -> (scale: f32, valid: bool) {
    // glTF matrices are column-major. Only compensate transforms that are a
    // positive uniform scale around the origin; translation, rotation, shear,
    // or non-uniform scale require a full skin-matrix conversion instead.
    zero_indices := [?]int{1, 2, 3, 4, 6, 7, 8, 9, 11, 12, 13, 14}
    for index in zero_indices {
        if math.abs(transform[index]) > GLTF_SKIN_SCALE_EPSILON {
            return 1, false
        }
    }
    if math.abs(transform[15] - 1) > GLTF_SKIN_SCALE_EPSILON {
        return 1, false
    }

    scale = transform[0]
    if scale <= GLTF_SKIN_SCALE_EPSILON ||
       math.abs(transform[5] - scale) > GLTF_SKIN_SCALE_EPSILON ||
       math.abs(transform[10] - scale) > GLTF_SKIN_SCALE_EPSILON {
        return 1, false
    }
    return scale, true
}

// GLTF_Skin_Node_Metadata contains only fields required to trace transforms from
// skinned mesh nodes to the scene roots; Maybe distinguishes absent JSON values.
GLTF_Skin_Node_Metadata :: struct {
    mesh:             Maybe(int),
    skin:             Maybe(int),
    children:         []int,
    transform_matrix: Maybe([16]f32) `json:"matrix"`,
    translation:      Maybe([3]f32),
    rotation:         Maybe([4]f32),
    scale:            Maybe([3]f32),
}

// GLTF_Skin_Metadata is the minimal temporary JSON decode target.
GLTF_Skin_Metadata :: struct {
    nodes: []GLTF_Skin_Node_Metadata,
}

// get_gltf_skinned_mesh_uniform_scale parses GLB/GLTF metadata without loading a
// second raylib model. It requires every skinned mesh to share one pure ancestor
// scale so a model-wide skeleton translation correction is mathematically valid.
get_gltf_skinned_mesh_uniform_scale :: proc(
    model_path: string,
) -> (scale: f32, found: bool) {
    is_gltf := strings.has_suffix(model_path, ".glb") ||
               strings.has_suffix(model_path, ".gltf") ||
               strings.has_suffix(model_path, ".GLB") ||
               strings.has_suffix(model_path, ".GLTF")
    if !is_gltf {
        return 1, false
    }

    file_data, read_error := os.read_entire_file(model_path, context.allocator)
    if read_error != nil {
        return 1, false
    }
    defer delete(file_data)

    // Extract the JSON payload inline for the only metadata decoder.
    json_bytes := file_data
    gltf_valid := true
    is_binary_gltf := len(file_data) >= 4 &&
                      file_data[0] == 'g' && file_data[1] == 'l' &&
                      file_data[2] == 'T' && file_data[3] == 'F'
    if is_binary_gltf {
        if len(file_data) < 20 {
            gltf_valid = false
        } else {
            chunk_length := int(u32(file_data[12]) |
                                u32(file_data[13]) << 8 |
                                u32(file_data[14]) << 16 |
                                u32(file_data[15]) << 24)
            is_json_chunk := file_data[16] == 'J' &&
                             file_data[17] == 'S' &&
                             file_data[18] == 'O' &&
                             file_data[19] == 'N'
            if !is_json_chunk || chunk_length < 0 ||
               chunk_length > len(file_data) - 20 {
                gltf_valid = false
            } else {
                json_bytes = file_data[20:20 + chunk_length]
            }
        }
    }
    if !gltf_valid {
        return 1, false
    }
    metadata: GLTF_Skin_Metadata
    unmarshal_error := json.unmarshal(
        json_bytes,
        &metadata,
        spec = .JSON,
    )
    // Release decoded node child arrays when this sole metadata scope exits.
    defer {
        for metadata_node in metadata.nodes {
            delete(metadata_node.children)
        }
        delete(metadata.nodes)
    }
    if unmarshal_error != nil || len(metadata.nodes) == 0 {
        return 1, false
    }

    parents := make([]int, len(metadata.nodes))
    defer delete(parents)
    for &parent in parents {
        parent = -1
    }
    for node, parent_index in metadata.nodes {
        for child_index in node.children {
            if child_index < 0 || child_index >= len(metadata.nodes) {
                return 1, false
            }
            if parents[child_index] >= 0 {
                return 1, false
            }
            parents[child_index] = parent_index
        }
    }

    uniform_scale := f32(1)
    scale_found := false
    for node, node_index in metadata.nodes {
        mesh_index, mesh_present := node.mesh.?
        skin_index, skin_present := node.skin.?
        if !mesh_present || !skin_present {
            continue
        }
        if mesh_index < 0 || skin_index < 0 {
            return 1, false
        }

        node_scale := f32(1)
        ancestor_index := node_index
        ancestor_count := 0
        for ancestor_index >= 0 {
            if ancestor_count >= len(metadata.nodes) {
                return 1, false
            }
            ancestor := metadata.nodes[ancestor_index]
            // Validate and accumulate the ancestor's local uniform scale here.
            local_scale := f32(1)
            local_valid := true
            if ancestor_matrix, matrix_present := ancestor.transform_matrix.?;
               matrix_present {
                if ancestor.translation != nil || ancestor.rotation != nil ||
                   ancestor.scale != nil {
                    local_valid = false
                } else {
                    local_scale, local_valid =
                        get_pure_uniform_scale_from_matrix(ancestor_matrix)
                }
            } else {
                if translation, translation_present := ancestor.translation.?;
                   translation_present {
                    if math.abs(translation[0]) > GLTF_SKIN_SCALE_EPSILON ||
                       math.abs(translation[1]) > GLTF_SKIN_SCALE_EPSILON ||
                       math.abs(translation[2]) > GLTF_SKIN_SCALE_EPSILON {
                        local_valid = false
                    }
                }
                if rotation, rotation_present := ancestor.rotation.?;
                   rotation_present {
                    if math.abs(rotation[0]) > GLTF_SKIN_SCALE_EPSILON ||
                       math.abs(rotation[1]) > GLTF_SKIN_SCALE_EPSILON ||
                       math.abs(rotation[2]) > GLTF_SKIN_SCALE_EPSILON ||
                       math.abs(math.abs(rotation[3]) - 1) >
                           GLTF_SKIN_SCALE_EPSILON {
                        local_valid = false
                    }
                }
                if ancestor_scale, scale_present := ancestor.scale.?;
                   scale_present {
                    if ancestor_scale[0] <= GLTF_SKIN_SCALE_EPSILON ||
                       math.abs(ancestor_scale[1] - ancestor_scale[0]) >
                           GLTF_SKIN_SCALE_EPSILON ||
                       math.abs(ancestor_scale[2] - ancestor_scale[0]) >
                           GLTF_SKIN_SCALE_EPSILON {
                        local_valid = false
                    } else {
                        local_scale = ancestor_scale[0]
                    }
                }
            }
            if !local_valid {
                return 1, false
            }
            node_scale *= local_scale
            ancestor_index = parents[ancestor_index]
            ancestor_count += 1
        }
        if scale_found &&
           math.abs(node_scale - uniform_scale) > GLTF_SKIN_SCALE_EPSILON {
            // A model-wide pose correction cannot represent differently
            // scaled skinned meshes sharing raylib's single skeleton.
            return 1, false
        }
        uniform_scale = node_scale
        scale_found = true
    }
    return uniform_scale, scale_found
}

// load_animation_playback loads all clips, filters empty/incompatible entries,
// builds raygui option text, applies the glTF scale correction, and initializes
// the model to the first valid pose. Non-asset primitives return empty playback.
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

    // Correct glTF skin translation scale inline after loading the sole playback.
    if model.skeleton.boneCount > 0 &&
       model.skeleton.bindPose != nil &&
       playback.animations != nil {
        uniform_scale, scale_found :=
            get_gltf_skinned_mesh_uniform_scale(model_path)
        if scale_found &&
           math.abs(uniform_scale - 1) > GLTF_SKIN_SCALE_EPSILON {
            // raylib bakes this node scale into mesh vertices but leaves absolute
            // bone translations in the unscaled skeleton space.
            for bone_index := 0;
                bone_index < int(model.skeleton.boneCount);
                bone_index += 1 {
                model.skeleton.bindPose[bone_index].translation *= uniform_scale
            }
            for valid_index in playback.valid_indices {
                corrected_animation := playback.animations[valid_index]
                for frame_index := 0;
                    frame_index < int(corrected_animation.keyframeCount);
                    frame_index += 1 {
                    for bone_index := 0;
                        bone_index < int(corrected_animation.boneCount);
                        bone_index += 1 {
                        corrected_animation.keyframePoses[frame_index][bone_index].translation *=
                            uniform_scale
                    }
                }
            }

            log.infof(
                "Applied glTF skin scale correction %.6f to %s",
                uniform_scale,
                model_path,
            )
        }
    }

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

// get_max_sample_count excludes the duplicate terminal loop keyframe while
// retaining a minimum of one sample for degenerate clips.
get_max_sample_count :: proc(animation: rl.ModelAnimation) -> c.int {
    // The terminal keyframe marks the end of the loop, so a 120-frame cycle
    // exposes the distinct frames 0...119 for sampled playback.
    return max(animation.keyframeCount - 1, 1)
}

// get_sampled_frame_at_index maps an evenly spaced sample slot to a keyframe,
// clamping both count and index to the distinct loop-frame range.
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

// get_sample_index_for_frame finds the nearest sampled slot for a continuous
// frame so toggling sampled playback does not produce a surprising large jump.
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

// get_animation_pose_frame resolves the actual frame displayed by the model,
// applying sample quantization only when sampled playback is enabled.
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

// animation_reset_to_first_frame stops playback and marks frame zero for upload.
animation_reset_to_first_frame :: proc(playback: ^Animation_Playback) {
    playback.current_frame = 0
    playback.is_playing = false
    playback.pose_dirty = true
}

// animation_step_frame advances either one keyframe or one sample slot. It wraps
// only when looping is enabled and always pauses continuous playback.
animation_step_frame :: proc(
    playback: ^Animation_Playback,
    direction: int,
) -> bool {
    animation, animation_found := get_active_animation(playback)
    if !animation_found || direction == 0 {
        return false
    }
    if playback.sampled_playback {
        sample_index := get_sample_index_for_frame(
            animation,
            playback.sample_count,
            playback.current_frame,
        )
        playback.current_frame = get_sampled_frame_at_index(
            animation,
            playback.sample_count,
            sample_index + c.int(direction),
        )
    } else {
        last_frame := f32(max(animation.keyframeCount - 1, 0))
        playback.current_frame = clamp(
            playback.current_frame + f32(direction),
            f32(0),
            last_frame,
        )
    }
    playback.is_playing = false
    playback.pose_dirty = true
    return true
}

// animation_cycle_clip selects the previous/next compatible clip with wrapping,
// resets timeline state, and marks the new first pose dirty.
animation_cycle_clip :: proc(
    playback: ^Animation_Playback,
    direction: int,
) -> bool {
    clip_count := c.int(len(playback.valid_indices))
    if clip_count <= 1 || direction == 0 {
        return false
    }
    playback.active_index = clamp(
        playback.active_index + c.int(direction),
        c.int(0),
        clip_count - 1,
    )
    playback.current_frame = 0
    playback.is_playing = false
    playback.pose_dirty = true
    return true
}

// update_animation_playback advances time, applies loop/end rules, quantizes the
// pose when requested, and calls raylib only when the resolved pose changed.
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

// get_model_center returns the midpoint of the current world-space bounding box.
get_model_center :: proc(model: rl.Model) -> rl.Vector3 {
    model_bounds := rl.GetModelBoundingBox(model)
    return {
        model_bounds.min.x + (model_bounds.max.x - model_bounds.min.x) * 0.5,
        model_bounds.min.y + (model_bounds.max.y - model_bounds.min.y) * 0.5,
        model_bounds.min.z + (model_bounds.max.z - model_bounds.min.z) * 0.5,
    }
}

// reset_camera_to_axis_view preserves a sensible orbit radius while replacing
// orientation and pivot with a reproducible axis or isometric view.
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

// frame_camera_to_model computes model bounds, chooses an orthographic camera,
// and returns the largest model dimension used as the scene movement scale.
// Built-ins receive lens-aware front/top framing; assets use an isometric view.
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

// inspector_section_height collapses a section to the shared header height.
inspector_section_height :: proc(expanded: bool, expanded_height: f32) -> f32 {
    if expanded {
        return expanded_height
    }
    return INSPECTOR_SECTION_HEADER_HEIGHT
}

// inspector_cel_section_offset computes the cel editor's scroll-space Y offset
// from the expansion state of the preceding model and camera sections.
inspector_cel_section_offset :: proc(state: ^Inspector_UI_State) -> f32 {
    return inspector_section_height(state.model_open, 310) +
           INSPECTOR_SECTION_GAP +
           inspector_section_height(state.camera_open, 250) +
           INSPECTOR_SECTION_GAP
}

// inspector_content_height combines every section's current extent so scrolling
// and scrollbar geometry can be resolved before clipped controls are drawn.
inspector_content_height :: proc(
    state: ^Inspector_UI_State,
    cel_style_ui: ^Cel_Style_UI_State,
    cel_style: ^Cel_Style,
) -> f32 {
    return inspector_cel_section_offset(state) +
           cel_style_editor_height(cel_style_ui, cel_style) +
           INSPECTOR_SECTION_GAP +
           inspector_section_height(state.background_open, 120)
}

// Camera_Input_Permissions separates keyboard and mouse eligibility because UI
// focus may block one input source without blocking an owned scene drag.
Camera_Input_Permissions :: struct {
    keyboard: bool,
    mouse:    bool,
}

// Camera_Mouse_Drag records which scene gesture owns a held mouse button.
Camera_Mouse_Drag :: enum {
    NONE,
    ORBIT,
    PAN,
}

// camera_mouse_drag_for_frame chooses drag ownership on the press frame and
// retains it through the release frame, preventing UI controls from stealing or
// inheriting a gesture after the pointer crosses their bounds.
camera_mouse_drag_for_frame :: proc(
    previous_drag: Camera_Mouse_Drag,
    window_focused: bool,
    ui_captures_input: bool,
    mouse_over_ui: bool,
    left_pressed: bool,
    middle_pressed: bool,
    left_down: bool,
    middle_down: bool,
) -> (frame_drag, next_drag: Camera_Mouse_Drag) {
    if !window_focused {
        return .NONE, .NONE
    }

    frame_drag = previous_drag
    if frame_drag == .NONE && !ui_captures_input && !mouse_over_ui {
        if left_pressed {
            frame_drag = .ORBIT
        } else if middle_pressed {
            frame_drag = .PAN
        }
    }

    // The release frame is still owned by the drag that began in the scene.
    // This prevents a raygui control under the release position from treating
    // that release as its own click.
    next_drag = frame_drag
    switch frame_drag {
    case .ORBIT:
        if !left_down {
            next_drag = .NONE
        }
    case .PAN:
        if !middle_down {
            next_drag = .NONE
        }
    case .NONE:
    }
    return
}

// camera_input_permissions applies focus, hover, and drag-ownership rules to
// derive the two input channels consumed by camera movement code.
camera_input_permissions :: proc(
    window_focused: bool,
    ui_captures_input: bool,
    mouse_over_ui: bool,
    camera_drag_owns_mouse: bool,
    camera_drag_button_down: bool,
) -> Camera_Input_Permissions {
    if !window_focused {
        return {}
    }

    // A drag keeps the owner chosen on its press frame. Scene drags may cross
    // the UI without stopping, while UI-originated drags may leave the UI
    // without leaking their held button into the camera controls.
    return {
        keyboard = !ui_captures_input,
        mouse    = camera_drag_owns_mouse ||
                   (!ui_captures_input &&
                    !mouse_over_ui &&
                    !camera_drag_button_down),
    }
}

// App_UI_Command_Context groups pointers to every state slice a semantic command
// may mutate, keeping execute_ui_command independent of frame-local variables.
App_UI_Command_Context :: struct {
    quit_requested:          ^bool,
    shortcuts_help_open:     ^bool,
    export_requested:        ^bool,
    lens_mode:               ^Lens_Mode,
    lens_grid_visible:       ^bool,
    downscale_level:         ^c.int,
    inspector:               ^Inspector_UI_State,
    inspector_max_scroll:    f32,
    model_browser:           ^Model_Browser_State,
    cel_ui:                  ^Cel_Style_UI_State,
    cel_style:               ^Cel_Style,
    animation:               ^Animation_Playback,
    camera:                  ^rl.Camera3D,
    model_center:            rl.Vector3,
    scene_size:              f32,
    background_color:        ^rl.Color,
    background_picker_open:  ^bool,
}

// execute_ui_command applies one already-filtered semantic command. It also
// maintains modal exclusivity, focus transfer, scroll positioning, and bounds
// clamping so keyboard actions match their corresponding visible controls.
execute_ui_command :: proc(
    command: UI_Command,
    command_context: ^App_UI_Command_Context,
) {
    #partial switch command {
    case .TOGGLE_HELP:
        command_context.shortcuts_help_open^ =
            !command_context.shortcuts_help_open^
        if command_context.shortcuts_help_open^ {
            ui_keyboard_set_focus(.HELP_CLOSE)
        } else {
            ui_keyboard_clear_focus()
        }
    case .QUIT:
        command_context.quit_requested^ = true
    case .FOCUS_MODEL_SEARCH:
        command_context.inspector.model_open = true
        command_context.inspector.scroll_y = 0
        command_context.model_browser.search_editing = true
        command_context.animation.dropdown_open = false
        command_context.background_picker_open^ = false
        command_context.cel_ui.color_target = .NONE
        ui_keyboard_set_focus(.MODEL_SEARCH)
        // Prevent the shortcut key from becoming search text.
        for rl.GetCharPressed() != 0 {}
    case .TOGGLE_MODEL_SECTION:
        command_context.inspector.model_open =
            !command_context.inspector.model_open
        if command_context.inspector.model_open {
            command_context.inspector.scroll_y = 0
        }
        if !command_context.inspector.model_open {
            command_context.model_browser.search_editing = false
        }
    case .TOGGLE_CAMERA_SECTION:
        command_context.inspector.camera_open =
            !command_context.inspector.camera_open
        if command_context.inspector.camera_open {
            command_context.inspector.scroll_y = inspector_section_height(
                command_context.inspector.model_open,
                310,
            ) + INSPECTOR_SECTION_GAP
        }
    case .TOGGLE_CEL_SECTION:
        command_context.cel_ui.open = !command_context.cel_ui.open
        if command_context.cel_ui.open {
            command_context.background_picker_open^ = false
            command_context.animation.dropdown_open = false
            sync_cel_style_light_angles(
                command_context.cel_ui,
                command_context.cel_style,
            )
            command_context.inspector.scroll_y = inspector_cel_section_offset(
                command_context.inspector,
            )
            ui_keyboard_set_focus(.CEL_HEADER)
        } else {
            command_context.cel_ui.color_target = .NONE
        }
    case .TOGGLE_BACKGROUND_SECTION:
        command_context.inspector.background_open =
            !command_context.inspector.background_open
        if command_context.inspector.background_open {
            command_context.inspector.scroll_y =
                command_context.inspector_max_scroll
        }
        if !command_context.inspector.background_open {
            command_context.background_picker_open^ = false
        }
    case .INSPECTOR_PAGE_UP:
        command_context.inspector.scroll_y = max(
            command_context.inspector.scroll_y - 210,
            f32(0),
        )
    case .INSPECTOR_PAGE_DOWN:
        command_context.inspector.scroll_y = min(
            command_context.inspector.scroll_y + 210,
            command_context.inspector_max_scroll,
        )
    case .INSPECTOR_HOME:
        command_context.inspector.scroll_y = 0
    case .INSPECTOR_END:
        command_context.inspector.scroll_y = command_context.inspector_max_scroll
    case .LENS_PIXELATED:
        command_context.lens_mode^ = .PIXELATED
        log.info("Lens mode: pixelated")
    case .LENS_BLENDED:
        command_context.lens_mode^ = .BLENDED
        log.info("Lens mode: blended 50/50")
    case .LENS_COVERAGE:
        command_context.lens_mode^ = .COVERAGE_MASK
        log.info("Lens mode: 16-sample coverage mask")
    case .TOGGLE_LENS_GRID:
        command_context.lens_grid_visible^ =
            !command_context.lens_grid_visible^
        if command_context.lens_grid_visible^ {
            log.info("Lens grid: on")
        } else {
            log.info("Lens grid: off")
        }
    case .EXPORT_PNG:
        command_context.export_requested^ = true
    case .CAMERA_X:
        reset_camera_to_axis_view(
            command_context.camera,
            command_context.model_center,
            {1, 0, 0},
            {0, 1, 0},
            command_context.scene_size,
        )
    case .CAMERA_Y:
        reset_camera_to_axis_view(
            command_context.camera,
            command_context.model_center,
            {0, 1, 0},
            {0, 0, 1},
            command_context.scene_size,
        )
    case .CAMERA_Z:
        reset_camera_to_axis_view(
            command_context.camera,
            command_context.model_center,
            {0, 0, 1},
            {0, 1, 0},
            command_context.scene_size,
        )
    case .CAMERA_ISOMETRIC:
        reset_camera_to_axis_view(
            command_context.camera,
            command_context.model_center,
            rl.Vector3Normalize({1, 1, 1}),
            {0, 1, 0},
            command_context.scene_size,
        )
    case .DOWNSCALE_DECREASE:
        command_context.downscale_level^ = max(
            command_context.downscale_level^ - 1,
            c.int(MIN_DOWNSCALE_LEVEL),
        )
    case .DOWNSCALE_INCREASE:
        command_context.downscale_level^ = min(
            command_context.downscale_level^ + 1,
            c.int(MAX_DOWNSCALE_LEVEL),
        )
    case .ANIMATION_PLAY_PAUSE:
        if has_playable_animations(command_context.animation) {
            command_context.animation.is_playing =
                !command_context.animation.is_playing
        }
    case .ANIMATION_FIRST_FRAME:
        if has_playable_animations(command_context.animation) {
            animation_reset_to_first_frame(command_context.animation)
        }
    case .ANIMATION_PREVIOUS_FRAME:
        _ = animation_step_frame(command_context.animation, -1)
    case .ANIMATION_NEXT_FRAME:
        _ = animation_step_frame(command_context.animation, 1)
    case .ANIMATION_PREVIOUS_CLIP:
        _ = animation_cycle_clip(command_context.animation, -1)
    case .ANIMATION_NEXT_CLIP:
        _ = animation_cycle_clip(command_context.animation, 1)
    case .ANIMATION_TOGGLE_LOOP:
        if has_playable_animations(command_context.animation) {
            command_context.animation.loop = !command_context.animation.loop
        }
    case .ANIMATION_TOGGLE_SAMPLED:
        if animation, found := get_active_animation(command_context.animation);
           found {
            command_context.animation.sampled_playback =
                !command_context.animation.sampled_playback
            if command_context.animation.sampled_playback {
                command_context.animation.current_frame = get_animation_pose_frame(
                    command_context.animation,
                    animation,
                )
            }
            command_context.animation.pose_dirty = true
        }
    case .CEL_PRESET_CLASSIC, .CEL_PRESET_ANIME, .CEL_PRESET_NOIR:
        preset_index: c.int
        if command == .CEL_PRESET_ANIME {
            preset_index = 1
        } else if command == .CEL_PRESET_NOIR {
            preset_index = 2
        }
        command_context.cel_ui.preset_index = preset_index
        _ = load_selected_cel_style_preset(
            command_context.cel_ui,
            command_context.cel_style,
        )
    case .CEL_RELOAD:
        _ = load_selected_cel_style_preset(
            command_context.cel_ui,
            command_context.cel_style,
        )
    case .CEL_SAVE:
        _ = save_selected_cel_style_preset(
            command_context.cel_ui,
            command_context.cel_style,
        )
    case .CEL_RESET:
        reset_cel_style_to_classic(
            command_context.cel_ui,
            command_context.cel_style,
        )
    case .TOGGLE_BACKGROUND_PICKER:
        command_context.inspector.background_open = true
        command_context.background_picker_open^ =
            !command_context.background_picker_open^
        if command_context.background_picker_open^ {
            command_context.cel_ui.color_target = .NONE
            command_context.animation.dropdown_open = false
            ui_keyboard_set_focus(.BACKGROUND_PICKER)
        }
    case .RESET_BACKGROUND:
        command_context.background_color^ = rl.BLACK
    }
}

// main owns every long-lived CPU/GPU resource and the complete application loop.
// A single outer block preserves structured defer cleanup while allowing startup
// and capture failures to set exit codes: 0 success, 1 render/export failure,
// and 2 invalid capture configuration or state.
main :: proc() {
    if game_mode_requested(os.args[1:]) {
        game_exit_code := run_game_mode(os.args[1:])
        if game_exit_code != 0 {
            os.exit(game_exit_code)
        }
        return
    }

    exit_code := 0
    // Run the application inline because main is its only entry point.
    for {
        console_logger := log.create_console_logger()
        defer log.destroy_console_logger(console_logger)
        context.logger = console_logger

        capture_parse_result := parse_capture_options(os.args[1:])
        defer destroy_capture_options(&capture_parse_result.options)
        if capture_parse_result.options.help_requested {
            print_capture_usage()
            exit_code = 0
            break
        }
        if capture_parse_result.error != .NONE {
            // Select the parse error text inline at its sole reporting site.
            capture_error_message := "invalid capture configuration"
            switch capture_parse_result.error {
            case .NONE:
                capture_error_message = ""
            case .MISSING_VALUE:
                capture_error_message = "capture option requires a value"
            case .UNKNOWN_ARGUMENT:
                capture_error_message = "unknown capture option"
            case .MISSING_CASE:
                capture_error_message = "capture options require --capture-case <name>"
            case .INVALID_CASE:
                capture_error_message = "capture case names may contain only letters, digits, '-' and '_'"
            case .INVALID_MODEL:
                capture_error_message = "capture model must be a non-empty asset path or built-in source"
            case .INVALID_STYLE:
                capture_error_message = "capture style must be a non-empty .json path"
            case .INVALID_MODE:
                capture_error_message = "capture mode must be pixelated, blended, or coverage-mask"
            case .INVALID_VIEW:
                capture_error_message = "capture view must be default, x, y, z, or isometric"
            case .INVALID_TARGET:
                capture_error_message = "capture target must be composite, lens, scene, downsample, or coverage-mask"
            case .INVALID_FRAME:
                capture_error_message = "capture frame must be a non-negative number"
            case .INVALID_FRAME_RANGE:
                capture_error_message = "capture frame range must be start:end[:step] with non-negative integers, start <= end, and step > 0"
            case .CONFLICTING_FRAME_OPTIONS:
                capture_error_message = "capture frame and capture frame range cannot be used together"
            case .INVALID_WARMUP:
                capture_error_message = "capture warmup must be an integer from 1 through 600"
            case .INVALID_OUTPUT:
                capture_error_message = "capture output must be a non-empty .png path"
            case .INVALID_OUTPUT_TEMPLATE:
                capture_error_message = "capture sequence output must contain exactly one %d or %0Nd frame token"
            }
            log.errorf(
                "%s: %s",
                capture_error_message,
                capture_parse_result.error_argument,
            )
            print_capture_usage()
            exit_code = 2
            break
        }
        capture_options := &capture_parse_result.options

        cel_style := make_classic_cel_style()
        defer destroy_cel_style(&cel_style)
        if capture_options.enabled && len(capture_options.style_path) > 0 {
            loaded_style, style_error := load_cel_style(capture_options.style_path)
            if style_error != .NONE {
                log.errorf(
                    "Failed to load capture cel style %s: %s",
                    capture_options.style_path,
                    cel_style_error_message(style_error),
                )
                exit_code = 2
                break
            }
            replace_cel_style(&cel_style, loaded_style)
        }

        // Scan and label model sources inline during the application's only startup.
        model_assets: Model_Assets
        {
            directory_walker := os.walker_create(ASSETS_PATH)
            defer os.walker_destroy(&directory_walker)

            for asset_entry in os.walker_walk(&directory_walker) {
                if failed_path, walk_error := os.walker_error(&directory_walker);
                   walk_error != nil {
                    log.errorf(
                        "Failed to scan model asset %s: %v",
                        failed_path,
                        walk_error,
                    )
                    continue
                }
                model_path_supported := false
                model_extension := os.ext(asset_entry.fullpath)
                for supported_extension in SUPPORTED_MODEL_EXTENSIONS {
                    if strings.equal_fold(model_extension, supported_extension) {
                        model_path_supported = true
                        break
                    }
                }
                if asset_entry.type != .Regular || !model_path_supported {
                    continue
                }
                append(&model_assets.paths, strings.clone(asset_entry.fullpath))
            }

            slice.sort_by_key(
                model_assets.paths[:],
                proc(asset_path: string) -> string { return asset_path },
            )
            for asset_path in model_assets.paths {
                append(&model_assets.kinds, Model_Source_Kind.ASSET)
                display_label := asset_path
                asset_marker := "/" + ASSETS_PATH + "/"
                if marker_index := strings.last_index(asset_path, asset_marker);
                   marker_index >= 0 {
                    display_label = asset_path[marker_index + len(asset_marker):]
                } else {
                    display_label = strings.trim_prefix(
                        asset_path,
                        ASSETS_PATH + "/",
                    )
                }
                if len(display_label) > 36 {
                    display_label = fmt.tprintf(
                        "%s...%s",
                        display_label[:14],
                        display_label[len(display_label) - 19:],
                    )
                }
                append(
                    &model_assets.labels,
                    strings.clone_to_cstring(display_label),
                )
            }

            for builtin_source in BUILTIN_MODEL_SOURCES {
                append(&model_assets.paths, strings.clone(builtin_source.path))
                append(
                    &model_assets.labels,
                    strings.clone_to_cstring(builtin_source.label),
                )
                append(&model_assets.kinds, builtin_source.kind)
            }

            log.infof(
                "Found %d model assets under %s and added 3 built-in models",
                len(model_assets.paths) - 3,
                ASSETS_PATH,
            )
        }
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
        rl.SetExitKey(.KEY_NULL)
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
        scene_cel_bindings := resolve_cel_shader_bindings(scene_shader)

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
        cel_band_bindings := resolve_cel_shader_bindings(cel_band_shader)

        mask_downscale_shader, mask_downscale_shader_source, mask_downscale_shader_loaded :=
            load_fragment_shader_with_includes(MASK_DOWNSCALE_FS_PATH)
        defer rl.UnloadShader(mask_downscale_shader)
        defer destroy_preprocessed_shader_source(&mask_downscale_shader_source)
        assert(mask_downscale_shader_loaded)

        outline_shader, outline_shader_source, outline_shader_loaded :=
            load_fragment_shader_with_includes(OUTLINE_FS_PATH)
        defer rl.UnloadShader(outline_shader)
        defer destroy_preprocessed_shader_source(&outline_shader_source)
        assert(outline_shader_loaded)

        // Build the ramp texture inline at its only creation site.
        cel_ramp_pixels := build_cel_ramp_pixels(&cel_style)
        cel_ramp_image := rl.Image{
            data = raw_data(cel_ramp_pixels[:]),
            width = CEL_RAMP_WIDTH,
            height = 1,
            mipmaps = 1,
            format = .UNCOMPRESSED_R8G8B8A8,
        }
        cel_ramp_texture := rl.LoadTextureFromImage(cel_ramp_image)
        if rl.IsTextureValid(cel_ramp_texture) {
            rl.SetTextureFilter(cel_ramp_texture, .POINT)
            rl.SetTextureWrap(cel_ramp_texture, .CLAMP)
        }
        defer rl.UnloadTexture(cel_ramp_texture)
        assert(rl.IsTextureValid(cel_ramp_texture))
        applied_cel_ramp_revision := cel_style.revision

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
                    exit_code = 2
                    break
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
                    // Apply the requested fixed capture view at its only setup site.
                    switch capture_options.view {
                    case .DEFAULT:
                    case .X:
                        reset_camera_to_axis_view(
                            &render_camera,
                            model_center,
                            {1, 0, 0},
                            {0, 1, 0},
                            scene_size,
                        )
                    case .Y:
                        reset_camera_to_axis_view(
                            &render_camera,
                            model_center,
                            {0, 1, 0},
                            {0, 0, 1},
                            scene_size,
                        )
                    case .Z:
                        reset_camera_to_axis_view(
                            &render_camera,
                            model_center,
                            {0, 0, 1},
                            {0, 1, 0},
                            scene_size,
                        )
                    case .ISOMETRIC:
                        reset_camera_to_axis_view(
                            &render_camera,
                            model_center,
                            rl.Vector3Normalize({1, 1, 1}),
                            {0, 1, 0},
                            scene_size,
                        )
                    }
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
                            exit_code = 2
                            break
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
                            exit_code = 2
                            break
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
                    exit_code = 1
                    break
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

        downscale_level := c.int(DEFAULT_DOWNSCALE_LEVEL)
        applied_downscale_level := downscale_level
        downsample_width := get_downsample_dimension(screen_width, downscale_level)
        downsample_height := get_downsample_dimension(screen_height, downscale_level)
        downsample_render_target := rl.LoadRenderTexture(
            downsample_width,
            downsample_height,
        )
        rl.SetTextureFilter(downsample_render_target.texture, .POINT)
        coverage_mask_render_target := rl.LoadRenderTexture(
            downsample_width,
            downsample_height,
        )
        rl.SetTextureFilter(coverage_mask_render_target.texture, .POINT)
        outlined_render_target := rl.LoadRenderTexture(
            downsample_width,
            downsample_height,
        )
        rl.SetTextureFilter(outlined_render_target.texture, .POINT)
        defer {
            rl.UnloadRenderTexture(downsample_render_target)
            rl.UnloadRenderTexture(coverage_mask_render_target)
            rl.UnloadRenderTexture(outlined_render_target)
        }
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
        downscale_rim_preserve_samples_location := rl.GetShaderLocation(
            downscale_shader,
            "u_rim_preserve_samples",
        )
        downscale_highlight_preserve_samples_location := rl.GetShaderLocation(
            downscale_shader,
            "u_highlight_preserve_samples",
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
        outline_target_resolution_location := rl.GetShaderLocation(
            outline_shader,
            "u_target_resolution",
        )
        outline_coverage_texture_location := rl.GetShaderLocation(
            outline_shader,
            "u_coverage_texture",
        )
        outline_width_location := rl.GetShaderLocation(
            outline_shader,
            "u_outline_width",
        )
        outline_color_location := rl.GetShaderLocation(
            outline_shader,
            "u_outline_color",
        )
        outline_coverage_threshold_location := rl.GetShaderLocation(
            outline_shader,
            "u_coverage_threshold",
        )

        lens_mode := Lens_Mode.PIXELATED
        if capture_options.enabled {
            lens_mode = capture_options.lens_mode
        }
        lens_grid_visible := true
        scene_background_color := rl.BLACK
        background_picker_open := false
        inspector_bounds := rl.Rectangle{
            f32(screen_width) - 340,
            10,
            330,
            f32(screen_height) - 20,
        }
        background_picker_bounds := rl.Rectangle{
            inspector_bounds.x - 230,
            360,
            220,
            212,
        }
        inspector_ui := Inspector_UI_State{
            model_open = true,
            camera_open = true,
        }
        cel_style_ui: Cel_Style_UI_State
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
        camera_mouse_drag := Camera_Mouse_Drag.NONE
        quit_requested := false
        shortcuts_help_open := false

        for !rl.WindowShouldClose() && !capture_complete && !quit_requested {
            if downscale_level != applied_downscale_level {
                requested_downscale_level := clamp(
                    downscale_level,
                    c.int(MIN_DOWNSCALE_LEVEL),
                    c.int(MAX_DOWNSCALE_LEVEL),
                )
                requested_width := get_downsample_dimension(
                    screen_width,
                    requested_downscale_level,
                )
                requested_height := get_downsample_dimension(
                    screen_height,
                    requested_downscale_level,
                )
                replacement_downsample_target := rl.LoadRenderTexture(
                    requested_width,
                    requested_height,
                )
                replacement_mask_target := rl.LoadRenderTexture(
                    requested_width,
                    requested_height,
                )
                replacement_outline_target := rl.LoadRenderTexture(
                    requested_width,
                    requested_height,
                )
                if rl.IsRenderTextureValid(replacement_downsample_target) &&
                   rl.IsRenderTextureValid(replacement_mask_target) &&
                   rl.IsRenderTextureValid(replacement_outline_target) {
                    rl.SetTextureFilter(replacement_downsample_target.texture, .POINT)
                    rl.SetTextureFilter(replacement_mask_target.texture, .POINT)
                    rl.SetTextureFilter(replacement_outline_target.texture, .POINT)
                    rl.UnloadRenderTexture(downsample_render_target)
                    rl.UnloadRenderTexture(coverage_mask_render_target)
                    rl.UnloadRenderTexture(outlined_render_target)
                    downsample_render_target = replacement_downsample_target
                    coverage_mask_render_target = replacement_mask_target
                    outlined_render_target = replacement_outline_target
                    downsample_width = requested_width
                    downsample_height = requested_height
                    downsample_resolution = {
                        f32(downsample_width),
                        f32(downsample_height),
                    }
                    downscale_level = requested_downscale_level
                    applied_downscale_level = requested_downscale_level
                    log.infof(
                        "Downscale level: %dx (%d x %d)",
                        applied_downscale_level,
                        downsample_width,
                        downsample_height,
                    )
                } else {
                    if rl.IsRenderTextureValid(replacement_downsample_target) {
                        rl.UnloadRenderTexture(replacement_downsample_target)
                    }
                    if rl.IsRenderTextureValid(replacement_mask_target) {
                        rl.UnloadRenderTexture(replacement_mask_target)
                    }
                    if rl.IsRenderTextureValid(replacement_outline_target) {
                        rl.UnloadRenderTexture(replacement_outline_target)
                    }
                    downscale_level = applied_downscale_level
                    log.errorf(
                        "Failed to create %d x %d downsample render targets; keeping level %d",
                        requested_width,
                        requested_height,
                        applied_downscale_level,
                    )
                }
            }

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

            export_requested := false
            active_modal := shortcuts_help_open || background_picker_open ||
                            animation_playback.dropdown_open ||
                            model_browser.search_editing ||
                            cel_style_ui.color_target != .NONE
            // Initialize keyboard navigation inline at its only frame start.
            for {
                enabled := window_focused
                trap_tab := active_modal
                ui_keyboard.enabled = enabled
                ui_keyboard.current_count = 0
                if !enabled {
                    ui_keyboard.focused = .NONE
                    break
                }

                if !trap_tab && rl.IsKeyPressed(.TAB) && ui_keyboard.previous_count > 0 {
                    focused_index := ui_find_focus_index(
                        &ui_keyboard.previous_order[0],
                        ui_keyboard.previous_count,
                        ui_keyboard.focused,
                    )
                    move_backward := rl.IsKeyDown(.LEFT_SHIFT) ||
                                     rl.IsKeyDown(.RIGHT_SHIFT)
                    if move_backward {
                        if focused_index < 0 {
                            focused_index = ui_keyboard.previous_count - 1
                        } else {
                            focused_index = (focused_index - 1 + ui_keyboard.previous_count) %
                                            ui_keyboard.previous_count
                        }
                    } else {
                        focused_index = (focused_index + 1) % ui_keyboard.previous_count
                    }
                    ui_keyboard.focused = ui_keyboard.previous_order[focused_index]
                }
                break
            }
            if shortcuts_help_open {
                ui_keyboard_set_focus(.HELP_CLOSE)
            } else if model_browser.search_editing {
                ui_keyboard_set_focus(.MODEL_SEARCH)
            } else if animation_playback.dropdown_open {
                ui_keyboard_set_focus(.ANIMATION_CLIP)
            } else if background_picker_open {
                ui_keyboard_set_focus(.BACKGROUND_PICKER)
            } else {
                switch cel_style_ui.color_target {
                case .BAND_TINT: ui_keyboard_set_focus(.CEL_BAND_TINT_PICKER)
                case .RIM:       ui_keyboard_set_focus(.CEL_RIM_PICKER)
                case .HIGHLIGHT: ui_keyboard_set_focus(.CEL_HIGHLIGHT_PICKER)
                case .OUTLINE:   ui_keyboard_set_focus(.CEL_OUTLINE_PICKER)
                case .NONE:
                }
            }

            if window_focused && rl.IsKeyPressed(.ESCAPE) {
                if shortcuts_help_open {
                    shortcuts_help_open = false
                    ui_keyboard_clear_focus()
                } else if animation_playback.dropdown_open {
                    animation_playback.dropdown_open = false
                    ui_keyboard_set_focus(.ANIMATION_CLIP)
                } else if background_picker_open {
                    background_picker_open = false
                    ui_keyboard_set_focus(.BACKGROUND_PICKER_TOGGLE)
                } else if cel_style_ui.color_target != .NONE {
                    cel_style_ui.color_target = .NONE
                } else if !model_browser.search_editing {
                    ui_keyboard_clear_focus()
                }
            }

            // Resolve the active shortcut inline at its only dispatch point.
            shortcut_command := UI_Command.NONE
            if window_focused {
                shortcut_modifiers := ui_modifier_mask()
                for binding in UI_SHORTCUT_BINDINGS {
                    if !ui_shortcut_matches(binding, shortcut_modifiers, false) ||
                       !rl.IsKeyPressed(binding.key) {
                        continue
                    }
                    shortcut_command = binding.command
                    break
                }
            }

            // Check focused-control conflicts inline before dispatching the command.
            shortcut_conflicts_with_focus := false
            #partial switch shortcut_command {
            case .ANIMATION_PLAY_PAUSE:
                shortcut_conflicts_with_focus = ui_keyboard.focused != .NONE
            case .ANIMATION_FIRST_FRAME:
                #partial switch ui_keyboard.focused {
                case .ANIMATION_TIMELINE, .ANIMATION_SPEED,
                     .ANIMATION_SAMPLE_COUNT, .MODEL_LIST, .CAMERA_DOWNSCALE,
                     .CEL_PRESET, .CEL_LIGHT_SPACE, .CEL_LIGHT_AZIMUTH,
                     .CEL_LIGHT_ELEVATION, .CEL_LIGHT_WRAP, .CEL_BAND_SELECT,
                     .CEL_BAND_UPPER_BOUND, .CEL_BAND_BRIGHTNESS,
                     .CEL_BAND_TINT_MIX, .CEL_BAND_TINT_PICKER,
                     .CEL_ALPHA_MODE, .CEL_ALPHA_CUTOFF, .CEL_RIM_THRESHOLD,
                     .CEL_RIM_STRENGTH, .CEL_RIM_SAMPLES, .CEL_RIM_PICKER,
                     .CEL_HIGHLIGHT_THRESHOLD, .CEL_HIGHLIGHT_STRENGTH,
                     .CEL_HIGHLIGHT_SAMPLES, .CEL_HIGHLIGHT_PICKER,
                     .CEL_OUTLINE_WIDTH, .CEL_OUTLINE_COVERAGE,
                     .CEL_OUTLINE_PICKER, .CEL_OUTLINE_ALPHA,
                     .BACKGROUND_PICKER, .INSPECTOR_SCROLLBAR:
                    shortcut_conflicts_with_focus = true
                }
            case .INSPECTOR_PAGE_UP, .INSPECTOR_PAGE_DOWN:
                shortcut_conflicts_with_focus =
                    ui_keyboard.focused == .MODEL_LIST ||
                    ui_keyboard.focused == .INSPECTOR_SCROLLBAR
            }
            if ui_keyboard_has_focus() && shortcut_conflicts_with_focus {
                shortcut_command = .NONE
            }
            if active_modal && shortcut_command != .TOGGLE_HELP &&
               shortcut_command != .QUIT {
                shortcut_command = .NONE
            }
            inspector_max_scroll := max(
                inspector_content_height(&inspector_ui, &cel_style_ui, &cel_style) -
                (inspector_bounds.height - 36),
                f32(0),
            )
            command_context := App_UI_Command_Context{
                quit_requested = &quit_requested,
                shortcuts_help_open = &shortcuts_help_open,
                export_requested = &export_requested,
                lens_mode = &lens_mode,
                lens_grid_visible = &lens_grid_visible,
                downscale_level = &downscale_level,
                inspector = &inspector_ui,
                inspector_max_scroll = inspector_max_scroll,
                model_browser = &model_browser,
                cel_ui = &cel_style_ui,
                cel_style = &cel_style,
                animation = &animation_playback,
                camera = &control_camera,
                model_center = model_center,
                scene_size = scene_size,
                background_color = &scene_background_color,
                background_picker_open = &background_picker_open,
            }
            execute_ui_command(shortcut_command, &command_context)

            ui_mouse_position := rl.GetMousePosition()
            mouse_over_inspector := rl.CheckCollisionPointRec(
                ui_mouse_position,
                inspector_bounds,
            )
            mouse_over_background_picker := background_picker_open &&
                rl.CheckCollisionPointRec(ui_mouse_position, background_picker_bounds)
            mouse_over_animation_controls := has_playable_animations(
                &animation_playback,
            ) && rl.CheckCollisionPointRec(
                ui_mouse_position,
                animation_controls_bounds,
            )
            input_lens_bounds := rl.Rectangle{
                (f32(screen_width) - LENS_WIDTH) / 2,
                (f32(screen_height) - LENS_HEIGHT) / 2,
                LENS_WIDTH,
                LENS_HEIGHT,
            }
            mouse_over_export_button := rl.CheckCollisionPointRec(
                ui_mouse_position,
                {
                    input_lens_bounds.x + (input_lens_bounds.width - 300) / 2,
                    input_lens_bounds.y + input_lens_bounds.height + 10,
                    300,
                    28,
                },
            )
            mouse_over_ui := mouse_over_inspector ||
                             mouse_over_background_picker ||
                             mouse_over_animation_controls ||
                             mouse_over_export_button
            ui_captures_camera_input := shortcuts_help_open ||
                                        background_picker_open ||
                                        animation_playback.dropdown_open ||
                                        model_browser.search_editing ||
                                        cel_style_ui.color_target != .NONE
            left_mouse_down := rl.IsMouseButtonDown(.LEFT)
            middle_mouse_down := rl.IsMouseButtonDown(.MIDDLE)
            camera_drag_for_frame, next_camera_mouse_drag :=
                camera_mouse_drag_for_frame(
                    camera_mouse_drag,
                    window_focused,
                    ui_captures_camera_input,
                    mouse_over_ui,
                    rl.IsMouseButtonPressed(.LEFT),
                    rl.IsMouseButtonPressed(.MIDDLE),
                    left_mouse_down,
                    middle_mouse_down,
                )
            camera_mouse_drag = next_camera_mouse_drag
            camera_input := camera_input_permissions(
                window_focused,
                ui_captures_camera_input,
                mouse_over_ui,
                camera_drag_for_frame != .NONE,
                left_mouse_down || middle_mouse_down,
            )
            // Reserve primary/Alt-modified keys inline before camera handling.
            camera_shortcut_modifiers := ui_modifier_mask()
            shortcut_uses_command_modifier :=
                camera_shortcut_modifiers & (UI_MOD_PRIMARY | UI_MOD_ALT) != 0
            if ui_keyboard_has_focus() || shortcut_uses_command_modifier {
                camera_input.keyboard = false
            }
            if !mouse_over_ui &&
               (rl.IsMouseButtonPressed(.LEFT) ||
                rl.IsMouseButtonPressed(.MIDDLE)) {
                ui_keyboard_clear_focus()
            }
            if camera_input.keyboard || camera_input.mouse {
                // Apply keyboard, orbit, pan, and zoom input inline at the sole update site.
                camera := &control_camera
                frame_time := rl.GetFrameTime()
                move_speed := scene_size * 2.0
                camera_forward := rl.GetCameraForward(camera)
                camera_right := rl.GetCameraRight(camera)
                camera_up := rl.Vector3Normalize(
                    rl.Vector3CrossProduct(camera_right, camera_forward),
                )

                if camera_input.keyboard {
                    if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
                        move_speed *= 4.0
                    }
                    move_distance := move_speed * frame_time

                    // Translate in the visible plane; Q/E control orthographic zoom.
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
                    }

                    keyboard_zoom_factor := 1.0 + frame_time * 1.5
                    if rl.IsKeyDown(.Q) {
                        camera.fovy *= keyboard_zoom_factor
                    }
                    if rl.IsKeyDown(.E) {
                        camera.fovy = max(
                            camera.fovy / keyboard_zoom_factor,
                            scene_size * 0.05,
                        )
                    }
                }

                if camera_input.mouse {
                    mouse_delta := rl.GetMouseDelta()
                    if camera_drag_for_frame == .ORBIT &&
                       rl.IsMouseButtonDown(.LEFT) {
                        mouse_look_sensitivity: f32 = 0.003
                        yaw_delta := -mouse_delta.x * mouse_look_sensitivity
                        pitch_delta := -mouse_delta.y * mouse_look_sensitivity

                        // Keep turntable yaw on world Y and pitch on screen right.
                        world_up := rl.Vector3{0, 1, 0}
                        position_from_pivot := camera.position - model_center
                        target_from_pivot := camera.target - model_center

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
                            yawed_position := model_center + position_from_pivot
                            yawed_target := model_center + target_from_pivot
                            yawed_forward := rl.Vector3Normalize(
                                yawed_target - yawed_position,
                            )
                            orbit_camera_right := rl.Vector3CrossProduct(
                                yawed_forward,
                                world_up,
                            )
                            right_length := rl.Vector3Length(orbit_camera_right)

                            if right_length < 0.00001 {
                                orbit_camera_right = rl.GetCameraRight(camera)
                                orbit_camera_right.y = 0
                                right_length = rl.Vector3Length(orbit_camera_right)
                            }
                            if right_length >= 0.00001 {
                                orbit_camera_right /= right_length
                                max_elevation := f32(math.PI / 2 - 0.01)
                                elevation := math.asin(
                                    min(
                                        max(
                                            rl.Vector3DotProduct(
                                                yawed_forward,
                                                world_up,
                                            ),
                                            -1,
                                        ),
                                        1,
                                    ),
                                )
                                clamped_pitch := min(
                                    max(
                                        pitch_delta,
                                        -max_elevation - elevation,
                                    ),
                                    max_elevation - elevation,
                                )
                                position_from_pivot = rl.Vector3RotateByAxisAngle(
                                    position_from_pivot,
                                    orbit_camera_right,
                                    clamped_pitch,
                                )
                                target_from_pivot = rl.Vector3RotateByAxisAngle(
                                    target_from_pivot,
                                    orbit_camera_right,
                                    clamped_pitch,
                                )
                            }
                        }

                        camera.position = model_center + position_from_pivot
                        camera.target = model_center + target_from_pivot
                        final_forward := rl.Vector3Normalize(
                            camera.target - camera.position,
                        )
                        if math.abs(
                            rl.Vector3DotProduct(final_forward, world_up),
                        ) > 0.99995 {
                            fallback_up := camera.up - final_forward *
                                           rl.Vector3DotProduct(
                                               camera.up,
                                               final_forward,
                                           )
                            if rl.Vector3Length(fallback_up) < 0.00001 {
                                fallback_up = rl.Vector3CrossProduct(
                                    camera_right,
                                    final_forward,
                                )
                            }
                            camera.up = rl.Vector3Normalize(fallback_up)
                        } else {
                            camera.up = world_up
                        }
                    }

                    if camera_drag_for_frame == .PAN &&
                       rl.IsMouseButtonDown(.MIDDLE) {
                        pan_sensitivity := camera.fovy /
                                           f32(rl.GetScreenHeight())
                        mouse_pan_delta :=
                            camera_right * (-mouse_delta.x * pan_sensitivity) +
                            camera_up * (mouse_delta.y * pan_sensitivity)
                        camera.position += mouse_pan_delta
                        camera.target += mouse_pan_delta
                    }

                    wheel_delta := rl.GetMouseWheelMove()
                    if wheel_delta != 0 {
                        zoom_factor := 1.0 - wheel_delta * 0.1
                        camera.fovy = max(
                            camera.fovy * zoom_factor,
                            scene_size * 0.05,
                        )
                    }
                }
            }
            render_camera = control_camera

            // Quantize orthographic zoom and pan inline before the sole render view.
            if downsample_height > 0 && render_camera.fovy > 0 && scene_size > 0 {
                projected_pixels := scene_size * f32(downsample_height) /
                                    render_camera.fovy
                snapped_pixels := max(math.round(projected_pixels), 1)
                render_camera.fovy = scene_size * f32(downsample_height) /
                                     snapped_pixels
            }
            if downsample_height > 0 && render_camera.fovy > 0 {
                world_units_per_pixel := render_camera.fovy / f32(downsample_height)
                camera_forward := rl.GetCameraForward(&render_camera)
                camera_right := rl.GetCameraRight(&render_camera)
                // Rebuild the actual vertical screen axis after orbiting.
                camera_up := rl.Vector3Normalize(
                    rl.Vector3CrossProduct(camera_right, camera_forward),
                )
                pan_offset := render_camera.target - model_center
                pan_x := rl.Vector3DotProduct(pan_offset, camera_right)
                pan_y := rl.Vector3DotProduct(pan_offset, camera_up)
                snapped_x := math.round(pan_x / world_units_per_pixel) *
                             world_units_per_pixel
                snapped_y := math.round(pan_y / world_units_per_pixel) *
                             world_units_per_pixel
                snap_correction := camera_right * (snapped_x - pan_x) +
                                   camera_up * (snapped_y - pan_y)
                render_camera.position += snap_correction
                render_camera.target += snap_correction
            }

            update_animation_playback(&animation_playback, active_model)

            if !capture_options.enabled {
                if reload_shader_with_includes(
                    VS_PATH,
                    FS_PATH,
                    &scene_shader,
                    &scene_shader_source,
                ) {
                    scene_cel_bindings = resolve_cel_shader_bindings(scene_shader)
                }

                if reload_shader_with_includes(
                    VS_PATH,
                    CEL_BAND_FS_PATH,
                    &cel_band_shader,
                    &cel_band_shader_source,
                ) {
                    cel_band_bindings = resolve_cel_shader_bindings(cel_band_shader)
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
                    downscale_rim_preserve_samples_location = rl.GetShaderLocation(
                        downscale_shader,
                        "u_rim_preserve_samples",
                    )
                    downscale_highlight_preserve_samples_location = rl.GetShaderLocation(
                        downscale_shader,
                        "u_highlight_preserve_samples",
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

                if reload_fragment_shader_with_includes(
                    OUTLINE_FS_PATH,
                    &outline_shader,
                    &outline_shader_source,
                ) {
                    outline_target_resolution_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_target_resolution",
                    )
                    outline_coverage_texture_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_coverage_texture",
                    )
                    outline_width_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_outline_width",
                    )
                    outline_color_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_outline_color",
                    )
                    outline_coverage_threshold_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_coverage_threshold",
                    )
                }
            }

            if cel_style.revision != applied_cel_ramp_revision {
                // Upload revised ramp pixels inline at the sole update point.
                revised_cel_ramp_pixels := build_cel_ramp_pixels(&cel_style)
                rl.UpdateTexture(
                    cel_ramp_texture,
                    raw_data(revised_cel_ramp_pixels[:]),
                )
                applied_cel_ramp_revision = cel_style.revision
            }
            rim_preserve_samples := c.int(cel_style.rim.preserve_samples)
            highlight_preserve_samples := c.int(
                cel_style.highlight.preserve_samples,
            )
            outline_width := c.int(cel_style.outline.width)
            outline_color := [4]f32{
                f32(cel_style.outline.color.r) / 255,
                f32(cel_style.outline.color.g) / 255,
                f32(cel_style.outline.color.b) / 255,
                f32(cel_style.outline.color.a) / 255,
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
                downscale_shader,
                downscale_rim_preserve_samples_location,
                &rim_preserve_samples,
                .INT,
            )
            rl.SetShaderValue(
                downscale_shader,
                downscale_highlight_preserve_samples_location,
                &highlight_preserve_samples,
                .INT,
            )
            rl.SetShaderValue(
                mask_downscale_shader,
                mask_downscale_source_resolution_location,
                &scene_resolution,
                .VEC2,
            )
            rl.SetShaderValue(
                outline_shader,
                outline_target_resolution_location,
                &downsample_resolution,
                .VEC2,
            )
            rl.SetShaderValue(
                outline_shader,
                outline_width_location,
                &outline_width,
                .INT,
            )
            rl.SetShaderValue(
                outline_shader,
                outline_color_location,
                &outline_color,
                .VEC4,
            )
            rl.SetShaderValue(
                outline_shader,
                outline_coverage_threshold_location,
                &cel_style.outline.coverage_threshold,
                .FLOAT,
            )
            rl.SetShaderValue(
                mask_downscale_shader,
                mask_downscale_target_resolution_location,
                &downsample_resolution,
                .VEC2,
            )

            rl.BeginTextureMode(scene_render_target)
                apply_cel_style_to_shader(
                    scene_shader,
                    &scene_cel_bindings,
                    &cel_style,
                    render_camera,
                    active_model.transform,
                )
                // Draw the cel-shaded scene inline in its only render pass.
                {
                    shader := scene_shader
                    model := active_model
                    camera := render_camera
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
                                mesh_material.maps[rl.MaterialMapIndex.EMISSION].texture =
                                    cel_ramp_texture
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
            rl.EndTextureMode()

            rl.BeginTextureMode(cel_band_render_target)
                apply_cel_style_to_shader(
                    cel_band_shader,
                    &cel_band_bindings,
                    &cel_style,
                    render_camera,
                    active_model.transform,
                )
                // Draw band IDs inline in their only auxiliary render pass.
                {
                    shader := cel_band_shader
                    model := active_model
                    camera := render_camera
                    rl.ClearBackground(rl.BLANK)
                    rl.BeginMode3D(camera)
                        if is_model_loaded(model) {
                            for mesh_index := 0; mesh_index < int(model.meshCount); mesh_index += 1 {
                                material_index := int(model.meshMaterial[mesh_index])
                                if material_index < 0 || material_index >= int(model.materialCount) {
                                    material_index = 0
                                }
                                mesh_material := model.materials[material_index]
                                mesh_material.shader = cel_band_shader
                                mesh_material.maps[rl.MaterialMapIndex.EMISSION].texture =
                                    cel_ramp_texture
                                rl.DrawMesh(
                                    model.meshes[mesh_index],
                                    mesh_material,
                                    model.transform,
                                )
                            }
                        }
                    rl.EndMode3D()
                }
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

            flipped_downsample_source_bounds := rl.Rectangle{
                width = f32(downsample_width),
                height = -f32(downsample_height),
            }
            rl.BeginTextureMode(outlined_render_target)
                rl.ClearBackground(rl.BLANK)
                rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
                rl.BeginShaderMode(outline_shader)
                    rl.SetShaderValueTexture(
                        outline_shader,
                        outline_coverage_texture_location,
                        coverage_mask_render_target.texture,
                    )
                    rl.DrawTexturePro(
                        downsample_render_target.texture,
                        flipped_downsample_source_bounds,
                        {0, 0, f32(downsample_width), f32(downsample_height)},
                        {},
                        0,
                        rl.WHITE,
                    )
                rl.EndShaderMode()
                rl.EndBlendMode()
            rl.EndTextureMode()

            rl.BeginTextureMode(composite_render_target)
                composite_locks_gui := camera_drag_for_frame != .NONE ||
                                       shortcuts_help_open
                if composite_locks_gui {
                    rl.GuiLock()
                }
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
                    x      = lens_bounds.x / f32(applied_downscale_level),
                    y      = f32(downsample_height) -
                             (lens_bounds.y + lens_bounds.height) /
                             f32(applied_downscale_level),
                    width  = lens_bounds.width / f32(applied_downscale_level),
                    height = -lens_bounds.height / f32(applied_downscale_level),
                }
                coverage_alpha = -1
                lens_mouse_position := rl.GetMousePosition()
                if lens_mode == .COVERAGE_MASK &&
                   rl.CheckCollisionPointRec(lens_mouse_position, lens_bounds) {
                    lens_column := c.int(
                        (lens_mouse_position.x - lens_bounds.x) /
                        f32(applied_downscale_level),
                    )
                    lens_row := c.int(
                        (lens_mouse_position.y - lens_bounds.y) /
                        f32(applied_downscale_level),
                    )
                    mask_pixel_x := c.int(
                        lens_bounds.x / f32(applied_downscale_level),
                    ) +
                                    lens_column
                    mask_pixel_y := c.int(
                        lens_bounds.y / f32(applied_downscale_level),
                    ) +
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
                active_lens_texture := outlined_render_target.texture
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
                // Draw the coordinate grid inline in its only overlay pass.
                {
                    camera := render_camera
                    model := active_model
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
                // Draw pixel-snap diagnostics inline in their only overlay pass.
                {
                    camera := &render_camera
                    snap_anchor := model_center
                    pixel_target_height := downsample_height
                    pixel_scale := int(applied_downscale_level)
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
                        grid_column_count := int(lens_bounds.width) / pixel_scale
                        grid_row_count := int(lens_bounds.height) / pixel_scale

                        for column_index := 0; column_index <= grid_column_count; column_index += 1 {
                            grid_line_x := lens_bounds.x + f32(column_index * pixel_scale)
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
                            grid_line_y := lens_bounds.y + f32(row_index * pixel_scale)
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
                rl.DrawRectangleLinesEx(lens_bounds, 2, rl.WHITE)

                export_button_bounds := rl.Rectangle{
                    lens_bounds.x + (lens_bounds.width - 300) / 2,
                    lens_bounds.y + lens_bounds.height + 10,
                    300,
                    28,
                }
                if ui_gui_button(
                    .EXPORT_PNG,
                    export_button_bounds,
                    rl.TextFormat(
                        "EXPORT %d x %d TRANSPARENT PNG [P]",
                        c.int(math.round(
                            LENS_WIDTH / f32(applied_downscale_level),
                        )),
                        c.int(math.round(
                            LENS_HEIGHT / f32(applied_downscale_level),
                        )),
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
                // Render animation controls inline in their only composite UI location.
                for {
                    bounds := animation_controls_bounds
                    playback := &animation_playback
                    animation, animation_found := get_active_animation(playback)
                    if !animation_found {
                        break
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

                    lock_transport_controls := playback.dropdown_open && !rl.GuiIsLocked()
                    if lock_transport_controls {
                        rl.GuiLock()
                    }

                    transport_y := bounds.y + 58
                    button_gap: f32 = 4
                    reset_width: f32 = 44
                    step_width: f32 = 40
                    play_width := content_width - reset_width - step_width * 2 - button_gap * 3

                    if ui_gui_button(
                        .ANIMATION_FIRST,
                        {content_x, transport_y, reset_width, 24},
                        "|<",
                    ) {
                        animation_reset_to_first_frame(playback)
                    }
                    previous_button_x := content_x + reset_width + button_gap
                    if ui_gui_button(
                        .ANIMATION_PREVIOUS,
                        {previous_button_x, transport_y, step_width, 24},
                        "<",
                    ) {
                        _ = animation_step_frame(playback, -1)
                    }

                    play_button_x := previous_button_x + step_width + button_gap
                    play_label: cstring = "Play [Space]"
                    if playback.is_playing {
                        play_label = "Pause [Space]"
                    }
                    if ui_gui_button(
                        .ANIMATION_PLAY,
                        {play_button_x, transport_y, play_width, 24},
                        play_label,
                    ) {
                        playback.is_playing = !playback.is_playing
                    }

                    next_button_x := play_button_x + play_width + button_gap
                    last_frame := f32(max(animation.keyframeCount - 1, 0))
                    if ui_gui_button(
                        .ANIMATION_NEXT,
                        {next_button_x, transport_y, step_width, 24},
                        ">",
                    ) {
                        _ = animation_step_frame(playback, 1)
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
                    _ = ui_gui_slider_bar(
                        .ANIMATION_TIMELINE,
                        {content_x, bounds.y + 108, content_width, 18},
                        nil,
                        nil,
                        &playback.current_frame,
                        0,
                        last_frame,
                        1,
                        10,
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
                    _ = ui_gui_slider_bar(
                        .ANIMATION_SPEED,
                        {content_x + 42, options_y, 105, 18},
                        nil,
                        nil,
                        &playback.speed,
                        0.25,
                        2.0,
                        0.05,
                        0.25,
                    )
                    rl.GuiLabel(
                        {content_x + 152, options_y, 48, 18},
                        rl.TextFormat("%.2fx", playback.speed),
                    )
                    _ = ui_gui_check_box(
                        .ANIMATION_LOOP,
                        {content_x + 202, options_y + 1, 16, 16},
                        nil,
                        &playback.loop,
                    )
                    rl.GuiLabel({content_x + 222, options_y, 36, 18}, "Loop")

                    sample_options_y := bounds.y + 162
                    previous_sampled_playback := playback.sampled_playback
                    _ = ui_gui_check_box(
                        .ANIMATION_SAMPLED,
                        {content_x, sample_options_y + 1, 16, 16},
                        nil,
                        &playback.sampled_playback,
                    )
                    rl.GuiLabel({content_x + 20, sample_options_y, 66, 18}, "Sampled")
                    rl.GuiLabel({content_x + 91, sample_options_y, 42, 18}, "Count")
                    previous_sample_count := playback.sample_count
                    _ = ui_gui_spinner(
                        .ANIMATION_SAMPLE_COUNT,
                        {content_x + 136, sample_options_y - 2, content_width - 136, 22},
                        nil,
                        &playback.sample_count,
                        1,
                        get_max_sample_count(animation),
                        1,
                        4,
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

                    if lock_transport_controls {
                        rl.GuiUnlock()
                    }

                    if len(playback.valid_indices) == 1 {
                        rl.GuiLabel(clip_bounds, playback.clip_options)
                    } else {
                        previous_active_index := playback.active_index
                        // Run the focus-aware dropdown inline in its sole clip selector.
                        clip_focused := ui_register_control(.ANIMATION_CLIP, clip_bounds)
                        clip_toggled := rl.GuiDropdownBox(
                            clip_bounds,
                            playback.clip_options,
                            &playback.active_index,
                            playback.dropdown_open,
                        )
                        if clip_focused && playback.dropdown_open &&
                           !ui_primary_modifier_down() &&
                           !(rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)) {
                            _ = ui_adjust_int(
                                &playback.active_index,
                                0,
                                max(c.int(len(playback.valid_indices)) - 1, 0),
                                1,
                                1,
                            )
                        }
                        if clip_focused && ui_activation_pressed() {
                            clip_toggled = true
                        }
                        ui_draw_focus(clip_bounds, clip_focused)
                        if clip_toggled {
                            playback.dropdown_open = !playback.dropdown_open
                            if playback.dropdown_open {
                                ui_keyboard_set_focus(.ANIMATION_CLIP)
                            }
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
                    break
                }
                // Render the inspector inline in its only composite UI location.
                {
                    bounds := inspector_bounds
                    state := &inspector_ui
                    cel_style_ui_ptr := &cel_style_ui
                    cel_style_ptr := &cel_style
                    requested_source_index := &model_active_index
                    camera := &control_camera
                    downscale_level_ptr := &downscale_level
                    background_color := &scene_background_color
                    background_picker_open_ptr := &background_picker_open
                rl.GuiPanel(bounds, "INSPECTOR")

                view := rl.Rectangle{
                    bounds.x + 8,
                    bounds.y + 28,
                    bounds.width - 16,
                    bounds.height - 36,
                }
                content_height := inspector_content_height(state, cel_style_ui_ptr, cel_style_ptr)
                max_scroll := max(content_height - view.height, f32(0))
                mouse_position := rl.GetMousePosition()
                mouse_over_view := rl.CheckCollisionPointRec(mouse_position, view)
                if mouse_over_view && !state.scrollbar_dragging {
                    wheel_delta := rl.GetMouseWheelMove()
                    if wheel_delta != 0 {
                        state.scroll_y -= wheel_delta * 42
                    }
                }
                state.scroll_y = clamp(state.scroll_y, f32(0), max_scroll)

                scrollbar_width: f32 = 0
                if content_height > view.height {
                    scrollbar_width = 14
                }
                content_width := view.width - scrollbar_width
                content_y := view.y - state.scroll_y

                content_was_locked := rl.GuiIsLocked()
                content_locked_here := !content_was_locked && !mouse_over_view
                if content_locked_here {
                    rl.GuiLock()
                }
                rl.BeginScissorMode(
                    c.int(view.x),
                    c.int(view.y),
                    c.int(view.width),
                    c.int(view.height),
                )
                    // Limit keyboard focus registration to the visible inspector viewport.
                    ui_keyboard.clip_active = true
                    ui_keyboard.clip_bounds = view
                    model_height := inspector_section_height(state.model_open, 310)
                    // Render the model browser inline in its only inspector location.
                    for {
                        bounds := rl.Rectangle{view.x, content_y, content_width, model_height}
                        expanded := &state.model_open
                        browser := &model_browser
                        loaded_index := loaded_model_index
                        load_failed := model_load_failed
                        rl.GuiPanel(bounds, nil)
                        was_expanded := expanded^
                        draw_collapsible_header(
                            .MODEL_HEADER,
                            {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
                            "MODEL ASSETS",
                            expanded,
                        )
                        if was_expanded && !expanded^ {
                            browser.search_editing = false
                        }
                        if !expanded^ {
                            break
                        }

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
                        // Run the focus-aware text box inline in its sole search field.
                        search_focused := ui_register_control(.MODEL_SEARCH, search_bounds)
                        search_was_locked := rl.GuiIsLocked()
                        unlock_for_keyboard_edit := search_was_locked && search_focused &&
                                                    browser.search_editing
                        if unlock_for_keyboard_edit {
                            rl.GuiUnlock()
                        }
                        search_toggled := rl.GuiTextBox(
                            search_bounds,
                            cstring(&browser.search_text[0]),
                            MODEL_SEARCH_TEXT_CAPACITY,
                            browser.search_editing,
                        )
                        if unlock_for_keyboard_edit {
                            rl.GuiLock()
                        }
                        if search_focused && !browser.search_editing && ui_modifier_mask() == 0 &&
                           (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) {
                            search_toggled = true
                        }
                        ui_draw_focus(search_bounds, search_focused || browser.search_editing)
                        if search_toggled {
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
                        if ui_gui_button(
                            .MODEL_CLEAR,
                            clear_bounds,
                            rl.GuiIconText(.ICON_CROSS_SMALL, nil),
                        ) {
                            browser.search_text = {}
                            browser.search_editing = true
                        }

                        search_keyboard_active := search_was_editing || browser.search_editing
                        list_has_keyboard_focus := ui_keyboard.focused == .MODEL_LIST
                        enter_pressed := (search_keyboard_active || list_has_keyboard_focus) &&
                                         (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER))
                        if search_keyboard_active && rl.IsKeyPressed(.ESCAPE) {
                            if len(search_query) > 0 {
                                browser.search_text = {}
                            } else {
                                browser.search_editing = false
                            }
                        }
                        if browser.search_text != browser.previous_search_text {
                            rebuild_model_search_results(&model_assets, browser)
                        }

                        if (search_keyboard_active || list_has_keyboard_focus) &&
                           len(browser.results) > 0 {
                            if rl.IsKeyPressed(.DOWN) {
                                browser.active_index = min(
                                    browser.active_index + 1,
                                    c.int(len(browser.results) - 1),
                                )
                            }
                            if rl.IsKeyPressed(.UP) {
                                browser.active_index = max(browser.active_index - 1, 0)
                            }

                            page_size: c.int = 8
                            if rl.IsKeyPressed(.PAGE_DOWN) {
                                browser.active_index = min(
                                    browser.active_index + page_size,
                                    c.int(len(browser.results) - 1),
                                )
                            }
                            if rl.IsKeyPressed(.PAGE_UP) {
                                browser.active_index = max(browser.active_index - page_size, 0)
                            }
                            if rl.IsKeyPressed(.HOME) {
                                browser.active_index = 0
                            }
                            if rl.IsKeyPressed(.END) {
                                browser.active_index = c.int(len(browser.results) - 1)
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
                            list_focused := ui_register_control(.MODEL_LIST, list_bounds)
                            rl.GuiListViewEx(
                                list_bounds,
                                raw_data(browser.result_labels[:]),
                                c.int(len(browser.result_labels)),
                                &browser.scroll_index,
                                &browser.active_index,
                                &browser.focus_index,
                            )
                            ui_draw_focus(list_bounds, list_focused)
                            result_clicked := !rl.GuiIsLocked() && rl.CheckCollisionPointRec(
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
                        break
                    }
                    content_y += model_height + INSPECTOR_SECTION_GAP

                    camera_height := inspector_section_height(state.camera_open, 250)
                    // Render camera controls inline in their only inspector location.
                    for {
                        bounds := rl.Rectangle{view.x, content_y, content_width, camera_height}
                        expanded := &state.camera_open
                        rl.GuiPanel(bounds, nil)
                        draw_collapsible_header(
                            .CAMERA_HEADER,
                            {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
                            "CAMERA CONTROLS",
                            expanded,
                        )
                        if !expanded^ {
                            break
                        }

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
                        if ui_gui_button(
                            .CAMERA_X,
                            {content_x, content_y, button_width, 24},
                            "X",
                        ) {
                            reset_camera_to_axis_view(
                                camera,
                                model_center,
                                {1, 0, 0},
                                {0, 1, 0},
                                scene_size,
                            )
                            log.info("Camera reset to +X axis view")
                        }
                        if ui_gui_button(
                            .CAMERA_Y,
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
                        if ui_gui_button(
                            .CAMERA_Z,
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

                        if ui_gui_button(
                            .CAMERA_ISOMETRIC,
                            {content_x, content_y, content_width, 24},
                            "Isometric [I]",
                        ) {
                            reset_camera_to_axis_view(
                                camera,
                                model_center,
                                rl.Vector3Normalize({1, 1, 1}),
                                {0, 1, 0},
                                scene_size,
                            )
                            log.info("Camera reset to isometric view")
                        }
                        content_y += 30

                        rl.GuiLabel({content_x, content_y, 104, 22}, "Downscale level")
                        _ = ui_gui_spinner(
                            .CAMERA_DOWNSCALE,
                            {content_x + 108, content_y, content_width - 108, 22},
                            nil,
                            downscale_level_ptr,
                            MIN_DOWNSCALE_LEVEL,
                            MAX_DOWNSCALE_LEVEL,
                            1,
                            4,
                            false,
                        )
                        downscale_level_ptr^ = clamp(
                            downscale_level_ptr^,
                            MIN_DOWNSCALE_LEVEL,
                            MAX_DOWNSCALE_LEVEL,
                        )
                        content_y += 24
                        rl.GuiLabel(
                            {content_x, content_y, content_width, 18},
                            rl.TextFormat(
                                "Output grid: %d x %d",
                                downsample_width,
                                downsample_height,
                            ),
                        )
                        content_y += line_height

                        rl.GuiLabel({content_x, content_y, content_width, 18}, "LMB orbit | MMB drag pan")
                        content_y += line_height
                        rl.GuiLabel({content_x, content_y, content_width, 18}, "WASD / Arrows pan | Q / E zoom")
                        content_y += line_height
                        rl.GuiLabel({content_x, content_y, content_width, 18}, "Wheel zoom | Shift faster")
                        content_y += line_height
                        lens_grid_status: cstring = "OFF"
                        if lens_grid_visible {
                            lens_grid_status = "ON"
                        }
                        rl.GuiLabel(
                            {content_x, content_y, content_width, 18},
                            rl.TextFormat("1/2/3 Lens | G Grid:%s | F1 Help", lens_grid_status),
                        )
                        break
                    }
                    content_y += camera_height + INSPECTOR_SECTION_GAP

                    cel_height := cel_style_editor_height(cel_style_ui_ptr, cel_style_ptr)
                    // Render the complete cel-style editor inline in its only inspector location.
                    for {
                        bounds := rl.Rectangle{view.x, content_y, content_width, cel_height}
                        state := cel_style_ui_ptr
                        style := cel_style_ptr
                        rl.GuiPanel(bounds, nil)
                        was_open := state.open
                        draw_collapsible_header(
                            .CEL_HEADER,
                            {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
                            "CEL SHADING [C]",
                            &state.open,
                        )
                        if was_open && !state.open {
                            state.color_target = .NONE
                        }
                        if !state.open {
                            break
                        }

                        x := bounds.x + 12
                        width := bounds.width - 24
                        y := bounds.y + INSPECTOR_SECTION_HEADER_HEIGHT + 8

                        combo_width := width * 0.38
                        button_gap: f32 = 4
                        reload_width: f32 = 56
                        save_width: f32 = 44
                        reset_width := width - combo_width - reload_width - save_width - button_gap * 3
                        previous_preset := state.preset_index
                        _ = ui_gui_combo_box(
                            .CEL_PRESET,
                            {x, y, combo_width, 24},
                            CEL_STYLE_PRESET_OPTIONS,
                            &state.preset_index,
                            3,
                        )
                        if state.preset_index != previous_preset {
                            _ = load_selected_cel_style_preset(state, style)
                        }
                        button_x := x + combo_width + button_gap
                        if ui_gui_button(.CEL_RELOAD, {button_x, y, reload_width, 24}, "Reload") {
                            _ = load_selected_cel_style_preset(state, style)
                        }
                        button_x += reload_width + button_gap
                        if ui_gui_button(.CEL_SAVE, {button_x, y, save_width, 24}, "Save") {
                            _ = save_selected_cel_style_preset(state, style)
                        }
                        button_x += save_width + button_gap
                        if ui_gui_button(.CEL_RESET, {button_x, y, reset_width, 24}, "Reset") {
                            reset_cel_style_to_classic(state, style)
                        }
                        y += 30

                        title_suffix: cstring = ""
                        if state.dirty {
                            title_suffix = " *"
                        }
                        style_name_cstr := strings.clone_to_cstring(style.name, context.temp_allocator)
                        rl.GuiLabel(
                            {x, y, width, 20},
                            rl.TextFormat("%s%s", style_name_cstr, title_suffix),
                        )
                        y += 22
                        // Draw the style ramp directly in its sole preview location.
                        ramp_bounds := rl.Rectangle{x, y, width, 22}
                        lower_bound := f32(0)
                        for band_index := 0; band_index < style.band_count; band_index += 1 {
                            band := style.bands[band_index]
                            upper_bound := f32(1)
                            if band_index < style.band_count - 1 {
                                upper_bound = band.upper_bound
                            }
                            base := rl.Vector3{1, 1, 1} * band.brightness
                            tinted := band.tint * band.brightness
                            preview := base * (1 - band.tint_mix) + tinted * band.tint_mix
                            color := rl.Color{
                                cel_color_component_to_byte(preview.x),
                                cel_color_component_to_byte(preview.y),
                                cel_color_component_to_byte(preview.z),
                                255,
                            }
                            band_x := ramp_bounds.x + lower_bound * ramp_bounds.width
                            band_width := max(
                                (upper_bound - lower_bound) * ramp_bounds.width,
                                f32(1),
                            )
                            rl.DrawRectangleRec(
                                {band_x, ramp_bounds.y, band_width, ramp_bounds.height},
                                color,
                            )
                            lower_bound = upper_bound
                        }
                        rl.DrawRectangleLinesEx(ramp_bounds, 1, rl.GRAY)
                        y += 30

                        changed := false

                        light_was_open := state.light_open
                        draw_cel_subsection(
                            .CEL_LIGHT_HEADER,
                            x,
                            y,
                            width,
                            "LIGHT",
                            &state.light_open,
                        )
                        if state.light_open {
                            // Draw and apply the light controls inline in their only subsection.
                            content_x := x + 8
                            cursor_y := y + CEL_SUBSECTION_HEADER_HEIGHT + 8
                            content_width := width - 16
                            content_changed := false
                            if !state.light_angles_valid {
                                sync_cel_style_light_angles(state, style)
                            }

                            rl.GuiLabel({content_x, cursor_y, 104, 22}, "Light space")
                            light_space := c.int(style.light_space)
                            previous_light_space := light_space
                            _ = ui_gui_combo_box(
                                .CEL_LIGHT_SPACE,
                                {content_x + 108, cursor_y, content_width - 108, 22},
                                "World;Camera;Model",
                                &light_space,
                                3,
                            )
                            if light_space != previous_light_space {
                                style.light_space = Cel_Light_Space(light_space)
                                content_changed = true
                            }
                            cursor_y += 30
                            if draw_cel_style_slider(
                                .CEL_LIGHT_AZIMUTH,
                                content_x,
                                cursor_y,
                                content_width,
                                "Azimuth",
                                &state.light_azimuth,
                                -180,
                                180,
                                1,
                                10,
                            ) {
                                update_cel_style_direction_from_angles(state, style)
                                content_changed = true
                            }
                            cursor_y += 28
                            if draw_cel_style_slider(
                                .CEL_LIGHT_ELEVATION,
                                content_x,
                                cursor_y,
                                content_width,
                                "Elevation",
                                &state.light_elevation,
                                -89,
                                89,
                                1,
                                10,
                            ) {
                                update_cel_style_direction_from_angles(state, style)
                                content_changed = true
                            }
                            cursor_y += 28
                            content_changed = draw_cel_style_slider(
                                .CEL_LIGHT_WRAP,
                                content_x,
                                cursor_y,
                                content_width,
                                "Wrap lighting",
                                &style.wrap_lighting,
                                0,
                                1,
                                0.01,
                                0.1,
                            ) || content_changed
                            cursor_y += 28
                            rl.GuiLabel(
                                {content_x, cursor_y, content_width, 32},
                                "Direction points from the surface toward the light.",
                            )
                            changed = content_changed || changed
                        }
                        if !light_was_open && state.light_open && !state.light_angles_valid {
                            sync_cel_style_light_angles(state, style)
                        }
                        y += cel_subsection_height(
                            state.light_open,
                            cel_style_light_content_height(),
                        ) + INSPECTOR_SECTION_GAP

                        bands_was_open := state.bands_open
                        draw_cel_subsection(
                            .CEL_BANDS_HEADER,
                            x,
                            y,
                            width,
                            "BANDS & ALPHA",
                            &state.bands_open,
                        )
                        if bands_was_open && !state.bands_open && state.color_target == .BAND_TINT {
                            state.color_target = .NONE
                        }
                        if state.bands_open {
                            // Draw and apply band/alpha controls inline in their only subsection.
                            bands_x := x + 8
                            cursor_y := y + CEL_SUBSECTION_HEADER_HEIGHT + 8
                            bands_width := width - 16
                            bands_changed := false
                            state.selected_band = clamp(
                                state.selected_band,
                                c.int(0),
                                c.int(style.band_count - 1),
                            )

                            rl.GuiLabel({bands_x, cursor_y, 38, 22}, "Band")
                            selected_display := state.selected_band + 1
                            _ = ui_gui_spinner(
                                .CEL_BAND_SELECT,
                                {bands_x + 40, cursor_y, 62, 22},
                                nil,
                                &selected_display,
                                1,
                                c.int(style.band_count),
                                1,
                                1,
                                false,
                            )
                            state.selected_band = selected_display - 1
                            add_width := (bands_width - 110) * 0.5
                            if ui_gui_button(
                                .CEL_BAND_ADD,
                                {bands_x + 108, cursor_y, add_width, 22},
                                "Add after",
                            ) {
                                if add_cel_band_after(style, int(state.selected_band)) {
                                    state.selected_band += 1
                                    bands_changed = true
                                }
                            }
                            if ui_gui_button(
                                .CEL_BAND_REMOVE,
                                {
                                    bands_x + 112 + add_width,
                                    cursor_y,
                                    bands_width - 112 - add_width,
                                    22,
                                },
                                "Remove",
                            ) {
                                if remove_cel_band(style, int(state.selected_band)) {
                                    state.selected_band = min(
                                        state.selected_band,
                                        c.int(style.band_count - 1),
                                    )
                                    bands_changed = true
                                }
                            }

                            band_index := int(state.selected_band)
                            band := &style.bands[band_index]
                            cursor_y += 32
                            rl.GuiLabel(
                                {bands_x, cursor_y, bands_width, 20},
                                rl.TextFormat(
                                    "Editing band %d of %d",
                                    band_index + 1,
                                    style.band_count,
                                ),
                            )
                            cursor_y += 28
                            if band_index < style.band_count - 1 {
                                band_lower_bound := f32(0)
                                if band_index > 0 {
                                    band_lower_bound = style.bands[band_index - 1].upper_bound +
                                                       CEL_BOUNDARY_MINIMUM_GAP
                                }
                                band_upper_bound := f32(1) - CEL_BOUNDARY_MINIMUM_GAP
                                if band_index < style.band_count - 2 {
                                    band_upper_bound = style.bands[band_index + 1].upper_bound -
                                                       CEL_BOUNDARY_MINIMUM_GAP
                                }
                                bands_changed = draw_cel_style_slider(
                                    .CEL_BAND_UPPER_BOUND,
                                    bands_x,
                                    cursor_y,
                                    bands_width,
                                    "Upper bound",
                                    &band.upper_bound,
                                    band_lower_bound,
                                    band_upper_bound,
                                    0.01,
                                    0.1,
                                ) || bands_changed
                                cursor_y += 28
                            }
                            bands_changed = draw_cel_style_slider(
                                .CEL_BAND_BRIGHTNESS,
                                bands_x,
                                cursor_y,
                                bands_width,
                                "Brightness",
                                &band.brightness,
                                0,
                                2,
                                0.05,
                                0.25,
                            ) || bands_changed
                            cursor_y += 28
                            bands_changed = draw_cel_style_slider(
                                .CEL_BAND_TINT_MIX,
                                bands_x,
                                cursor_y,
                                bands_width,
                                "Tint mix",
                                &band.tint_mix,
                                0,
                                1,
                                0.01,
                                0.1,
                            ) || bands_changed
                            cursor_y += 28

                            tint_color := cel_vector_color_to_raylib(band.tint)
                            draw_cel_color_swatch(
                                .CEL_BAND_TINT_SWATCH,
                                bands_x,
                                cursor_y,
                                bands_width,
                                "Tint",
                                tint_color,
                                .BAND_TINT,
                                state,
                            )
                            cursor_y += 28
                            if state.color_target == .BAND_TINT {
                                previous_tint_color := tint_color
                                _ = ui_gui_color_picker(
                                    .CEL_BAND_TINT_PICKER,
                                    {bands_x, cursor_y, 150, 150},
                                    &tint_color,
                                    false,
                                )
                                if tint_color != previous_tint_color {
                                    band.tint = cel_raylib_color_to_vector(tint_color)
                                    bands_changed = true
                                }
                                cursor_y += 158
                            }

                            rl.GuiLabel({bands_x, cursor_y, 104, 22}, "Alpha")
                            alpha_mode := c.int(style.alpha_mode)
                            previous_alpha_mode := alpha_mode
                            _ = ui_gui_combo_box(
                                .CEL_ALPHA_MODE,
                                {bands_x + 108, cursor_y, bands_width - 108, 22},
                                "Opaque;Mask",
                                &alpha_mode,
                                2,
                            )
                            if alpha_mode != previous_alpha_mode {
                                style.alpha_mode = Cel_Alpha_Mode(alpha_mode)
                                bands_changed = true
                            }
                            cursor_y += 30
                            if style.alpha_mode == .MASK {
                                bands_changed = draw_cel_style_slider(
                                    .CEL_ALPHA_CUTOFF,
                                    bands_x,
                                    cursor_y,
                                    bands_width,
                                    "Cutoff",
                                    &style.alpha_cutoff,
                                    0,
                                    1,
                                    0.01,
                                    0.1,
                                ) || bands_changed
                            }
                            changed = bands_changed || changed
                        }
                        y += cel_subsection_height(
                            state.bands_open,
                            cel_style_bands_content_height(state, style),
                        ) + INSPECTOR_SECTION_GAP

                        accents_was_open := state.accents_open
                        draw_cel_subsection(
                            .CEL_ACCENTS_HEADER,
                            x,
                            y,
                            width,
                            "ACCENTS",
                            &state.accents_open,
                        )
                        if accents_was_open && !state.accents_open &&
                           (state.color_target == .RIM || state.color_target == .HIGHLIGHT) {
                            state.color_target = .NONE
                        }
                        if state.accents_open {
                            // Compose the two accent editors inline in their only subsection.
                            accents_x := x + 8
                            accents_y := y + CEL_SUBSECTION_HEADER_HEIGHT + 8
                            accents_width := width - 16
                            rim_changed := draw_cel_accent_content(
                                accents_x,
                                accents_y,
                                accents_width,
                                "Rim light",
                                .RIM,
                                state,
                                &style.rim,
                            )
                            highlight_y := accents_y + cel_accent_block_height(state, .RIM) + 8
                            rl.GuiLine({accents_x, highlight_y - 6, accents_width, 2}, nil)
                            highlight_changed := draw_cel_accent_content(
                                accents_x,
                                highlight_y,
                                accents_width,
                                "Highlight",
                                .HIGHLIGHT,
                                state,
                                &style.highlight,
                            )
                            changed = rim_changed || highlight_changed || changed
                        }
                        y += cel_subsection_height(
                            state.accents_open,
                            cel_style_accents_content_height(state),
                        ) + INSPECTOR_SECTION_GAP

                        outline_was_open := state.outline_open
                        draw_cel_subsection(
                            .CEL_OUTLINE_HEADER,
                            x,
                            y,
                            width,
                            "OUTLINE",
                            &state.outline_open,
                        )
                        if outline_was_open && !state.outline_open && state.color_target == .OUTLINE {
                            state.color_target = .NONE
                        }
                        if state.outline_open {
                            // Draw and apply outline controls inline in their only subsection.
                            outline_x := x + 8
                            cursor_y := y + CEL_SUBSECTION_HEADER_HEIGHT + 8
                            outline_width_available := width - 16
                            outline_changed := false
                            rl.GuiLabel({outline_x, cursor_y, 104, 22}, "Width (pixels)")
                            outline_width := c.int(style.outline.width)
                            previous_width := outline_width
                            _ = ui_gui_spinner(
                                .CEL_OUTLINE_WIDTH,
                                {
                                    outline_x + 108,
                                    cursor_y,
                                    outline_width_available - 108,
                                    22,
                                },
                                nil,
                                &outline_width,
                                0,
                                3,
                                1,
                                1,
                                false,
                            )
                            if outline_width != previous_width {
                                style.outline.width = int(outline_width)
                                outline_changed = true
                            }
                            cursor_y += 32
                            outline_changed = draw_cel_style_slider(
                                .CEL_OUTLINE_COVERAGE,
                                outline_x,
                                cursor_y,
                                outline_width_available,
                                "Coverage",
                                &style.outline.coverage_threshold,
                                0,
                                1,
                                0.01,
                                0.1,
                            ) || outline_changed
                            cursor_y += 28

                            outline_color := style.outline.color
                            draw_cel_color_swatch(
                                .CEL_OUTLINE_SWATCH,
                                outline_x,
                                cursor_y,
                                outline_width_available,
                                "Color",
                                outline_color,
                                .OUTLINE,
                                state,
                            )
                            cursor_y += 32
                            if state.color_target == .OUTLINE {
                                previous_color := outline_color
                                _ = ui_gui_color_picker(
                                    .CEL_OUTLINE_PICKER,
                                    {outline_x, cursor_y, 160, 160},
                                    &outline_color,
                                    false,
                                )
                                if outline_color != previous_color {
                                    style.outline.color.r = outline_color.r
                                    style.outline.color.g = outline_color.g
                                    style.outline.color.b = outline_color.b
                                    outline_changed = true
                                }
                                cursor_y += 168
                            }

                            alpha := f32(style.outline.color.a) / 255
                            previous_alpha := alpha
                            outline_changed = draw_cel_style_slider(
                                .CEL_OUTLINE_ALPHA,
                                outline_x,
                                cursor_y,
                                outline_width_available,
                                "Alpha",
                                &alpha,
                                0,
                                1,
                                0.01,
                                0.1,
                            ) || outline_changed
                            if alpha != previous_alpha {
                                style.outline.color.a = cel_color_component_to_byte(alpha)
                            }
                            changed = outline_changed || changed
                        }
                        y += cel_subsection_height(
                            state.outline_open,
                            cel_style_outline_content_height(state),
                        ) + INSPECTOR_SECTION_GAP

                        if changed {
                            // Mark the style dirty where the editor is its only mutation aggregator.
                            style.revision += 1
                            state.dirty = true
                            state.status = .NONE
                        }

                        // Select the transient status copy directly before drawing it.
                        status_text: cstring
                        switch state.status {
                        case .NONE:        status_text = "Changes apply immediately"
                        case .LOADED:      status_text = "Preset loaded"
                        case .SAVED:       status_text = "Preset saved"
                        case .RESET:       status_text = "Reset to built-in Classic"
                        case .LOAD_FAILED: status_text = "Preset load failed; current style kept"
                        case .SAVE_FAILED: status_text = "Preset save failed"
                        }
                        if state.status == .NONE || rl.GetTime() - state.status_time < 5 {
                            rl.GuiStatusBar({x, y, width, 20}, status_text)
                        }
                        break
                    }
                    content_y += cel_height + INSPECTOR_SECTION_GAP

                    background_height := inspector_section_height(state.background_open, 120)
                    // Render background controls inline in their only inspector location.
                    for {
                        bounds := rl.Rectangle{view.x, content_y, content_width, background_height}
                        expanded := &state.background_open
                        picker_open := background_picker_open_ptr
                        rl.GuiPanel(bounds, nil)
                        was_expanded := expanded^
                        draw_collapsible_header(
                            .BACKGROUND_HEADER,
                            {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
                            "SCENE BACKGROUND",
                            expanded,
                        )
                        if was_expanded && !expanded^ {
                            picker_open^ = false
                        }
                        if !expanded^ {
                            break
                        }

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
                        if ui_gui_button(
                            .BACKGROUND_PICKER_TOGGLE,
                            {button_x, bounds.y + 30, button_width, 25},
                            picker_button_text,
                        ) {
                            picker_open^ = !picker_open^
                            if picker_open^ {
                                ui_keyboard_set_focus(.BACKGROUND_PICKER)
                            }
                        }
                        if ui_gui_button(
                            .BACKGROUND_RESET,
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

                        break
                    }
                    // End the inspector's sole focus-clipping region.
                    ui_keyboard.clip_active = false
                rl.EndScissorMode()
                if content_locked_here {
                    rl.GuiUnlock()
                }

                // Draw and interact with the inspector scrollbar inline at its sole site.
                for {
                    if content_height <= view.height {
                        state.scrollbar_dragging = false
                        break
                    }

                    track := rl.Rectangle{
                        view.x + view.width - 10,
                        view.y,
                        10,
                        view.height,
                    }
                    max_scroll := content_height - view.height
                    thumb_height := max(f32(42), view.height * view.height / content_height)
                    thumb_travel := track.height - thumb_height
                    thumb_y := track.y
                    if max_scroll > 0 {
                        thumb_y += state.scroll_y / max_scroll * thumb_travel
                    }
                    thumb := rl.Rectangle{track.x + 2, thumb_y, track.width - 4, thumb_height}
                    mouse_position := rl.GetMousePosition()
                    scrollbar_focused := ui_register_control(.INSPECTOR_SCROLLBAR, track)

                    if scrollbar_focused {
                        if ui_key_pressed_or_repeat(.UP) {
                            state.scroll_y = max(state.scroll_y - 42, f32(0))
                        }
                        if ui_key_pressed_or_repeat(.DOWN) {
                            state.scroll_y = min(state.scroll_y + 42, max_scroll)
                        }
                        if rl.IsKeyPressed(.PAGE_UP) {
                            state.scroll_y = max(state.scroll_y - 210, f32(0))
                        }
                        if rl.IsKeyPressed(.PAGE_DOWN) {
                            state.scroll_y = min(state.scroll_y + 210, max_scroll)
                        }
                        if rl.IsKeyPressed(.HOME) {
                            state.scroll_y = 0
                        }
                        if rl.IsKeyPressed(.END) {
                            state.scroll_y = max_scroll
                        }
                    }

                    if rl.IsMouseButtonPressed(.LEFT) {
                        if rl.CheckCollisionPointRec(mouse_position, thumb) {
                            state.scrollbar_dragging = true
                            state.scrollbar_drag_offset = mouse_position.y - thumb.y
                        } else if rl.CheckCollisionPointRec(mouse_position, track) {
                            state.scroll_y = clamp(
                                (mouse_position.y - track.y - thumb_height * 0.5) /
                                max(thumb_travel, f32(1)) * max_scroll,
                                f32(0),
                                max_scroll,
                            )
                        }
                    }
                    if state.scrollbar_dragging {
                        if rl.IsMouseButtonDown(.LEFT) {
                            state.scroll_y = clamp(
                                (mouse_position.y - track.y - state.scrollbar_drag_offset) /
                                max(thumb_travel, f32(1)) * max_scroll,
                                f32(0),
                                max_scroll,
                            )
                        } else {
                            state.scrollbar_dragging = false
                        }
                    }

                    rl.DrawRectangleRec(track, rl.Color{24, 24, 24, 210})
                    thumb_color := rl.Color{126, 126, 126, 255}
                    if rl.CheckCollisionPointRec(mouse_position, thumb) || state.scrollbar_dragging {
                        thumb_color = rl.Color{180, 180, 180, 255}
                    }
                    rl.DrawRectangleRec(thumb, thumb_color)
                    ui_draw_focus(track, scrollbar_focused)
                    break
                }
                // Render the floating background picker inline at its only draw point.
                for {
                    picker_bounds := background_picker_bounds
                    picker_open := background_picker_open_ptr
                    if !picker_open^ {
                        break
                    }
                    if rl.GuiWindowBox(picker_bounds, "BACKGROUND COLOR") != 0 {
                        picker_open^ = false
                        break
                    }
                    _ = ui_gui_color_picker(
                        .BACKGROUND_PICKER,
                        {
                            picker_bounds.x + 12,
                            picker_bounds.y + 34,
                            165,
                            165,
                        },
                        background_color,
                        false,
                    )
                    break
                }
                }
                if composite_locks_gui {
                    rl.GuiUnlock()
                }
                if shortcuts_help_open {
                    // Draw shortcut help inline in its only modal pass.
                    for {
                        bounds := rl.Rectangle{
                            (f32(screen_width) - 930) * 0.5,
                            (f32(screen_height) - 560) * 0.5,
                            930,
                            560,
                        }
                        open := &shortcuts_help_open
                        rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color{0, 0, 0, 170})
                        rl.GuiPanel(bounds, "KEYBOARD SHORTCUTS")
                        if ui_gui_button(
                            .HELP_CLOSE,
                            {bounds.x + bounds.width - 34, bounds.y + 4, 28, 22},
                            "X",
                        ) {
                            open^ = false
                            ui_keyboard_clear_focus()
                            break
                        }

                        column_width := (bounds.width - 42) * 0.5
                        line_height: f32 = 22
                        left_x := bounds.x + 16
                        right_x := left_x + column_width + 10
                        start_y := bounds.y + 36
                        for line, line_index in UI_SHORTCUT_HELP_LEFT {
                            color := rl.Color{45, 45, 45, 255}
                            if line == "GENERAL" || line == "MODEL & INSPECTOR" ||
                               line == "LENS & CAMERA" {
                                color = rl.Color{190, 110, 0, 255}
                            }
                            rl.DrawText(
                                line,
                                c.int(left_x),
                                c.int(start_y + f32(line_index) * line_height),
                                16,
                                color,
                            )
                        }
                        for line, line_index in UI_SHORTCUT_HELP_RIGHT {
                            color := rl.Color{45, 45, 45, 255}
                            if line == "ANIMATION" || line == "CEL & BACKGROUND" ||
                               line == "FOCUSED CONTROLS" {
                                color = rl.Color{190, 110, 0, 255}
                            }
                            rl.DrawText(
                                line,
                                c.int(right_x),
                                c.int(start_y + f32(line_index) * line_height),
                                16,
                                color,
                            )
                        }
                        break
                    }
                }
                // Finalize keyboard focus order inline at the only frame end.
                for {
                    if !ui_keyboard.enabled {
                        break
                    }
                    if ui_keyboard.focused != .NONE &&
                       ui_find_focus_index(
                           &ui_keyboard.current_order[0],
                           ui_keyboard.current_count,
                           ui_keyboard.focused,
                       ) < 0 {
                        fallback := ui_focus_fallback(ui_keyboard.focused)
                        if fallback != .NONE &&
                           ui_find_focus_index(
                               &ui_keyboard.current_order[0],
                               ui_keyboard.current_count,
                               fallback,
                           ) >= 0 {
                            ui_keyboard.focused = fallback
                        } else {
                            ui_keyboard.focused = .NONE
                        }
                    }
                    ui_keyboard.previous_count = ui_keyboard.current_count
                    for control_index := 0;
                        control_index < ui_keyboard.current_count;
                        control_index += 1 {
                        ui_keyboard.previous_order[control_index] =
                            ui_keyboard.current_order[control_index]
                    }
                    break
                }
            rl.EndTextureMode()

            if export_requested {
                if len(last_export_path) > 0 {
                    delete(last_export_path)
                    last_export_path = ""
                }
                // Crop and export the low-resolution lens inline on the sole request path.
                last_export_succeeded = false
                if applied_downscale_level > 0 {
                    texture_readback := rl.LoadImageFromTexture(
                        outlined_render_target.texture,
                    )
                    if texture_readback.data != nil {
                        // Convert the logical crop to vertically inverted readback space.
                        crop_x := c.int(
                            math.round(lens_bounds.x / f32(applied_downscale_level)),
                        )
                        logical_crop_y := c.int(
                            math.round(lens_bounds.y / f32(applied_downscale_level)),
                        )
                        crop_width := c.int(
                            math.round(
                                lens_bounds.width / f32(applied_downscale_level),
                            ),
                        )
                        crop_height := c.int(
                            math.round(
                                lens_bounds.height / f32(applied_downscale_level),
                            ),
                        )
                        crop_y := texture_readback.height - logical_crop_y -
                                  crop_height
                        crop_is_valid := crop_x >= 0 && crop_y >= 0 &&
                                         crop_width > 0 && crop_height > 0 &&
                                         crop_x + crop_width <= texture_readback.width &&
                                         crop_y + crop_height <= texture_readback.height
                        if !crop_is_valid {
                            log.errorf(
                                "Lens export crop is outside the downsample target: crop(%d, %d, %d, %d), target(%d, %d)",
                                crop_x,
                                crop_y,
                                crop_width,
                                crop_height,
                                texture_readback.width,
                                texture_readback.height,
                            )
                        } else {
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
                            rl.ImageFormat(
                                &texture_readback,
                                .UNCOMPRESSED_R8G8B8A8,
                            )

                            // Continue from the next unused sequence number.
                            for {
                                candidate_path := fmt.tprintf(
                                    "lens_downsample_%03d.png",
                                    next_export_index,
                                )
                                next_export_index += 1
                                candidate_path_cstr := strings.clone_to_cstring(
                                    candidate_path,
                                    context.temp_allocator,
                                )
                                if !rl.FileExists(candidate_path_cstr) {
                                    last_export_path = strings.clone(candidate_path)
                                    break
                                }
                            }
                            export_path_cstr := strings.clone_to_cstring(
                                last_export_path,
                                context.temp_allocator,
                            )
                            last_export_succeeded = rl.ExportImage(
                                texture_readback,
                                export_path_cstr,
                            )
                        }
                        rl.UnloadImage(texture_readback)
                    }
                }
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
                // Draw the cursor magnifier inline at its only screen pass.
                {
                    bounds := magnifier_bounds
                    source_texture := composite_render_target.texture
                    mouse_position := rl.GetMousePosition()
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
                    // Export the selected render target inline at the only capture point.
                    lens_crop_bounds := lens_bounds
                    switch capture_options.target {
                    case .COMPOSITE:
                        capture_succeeded = export_render_texture_png(
                            composite_render_target.texture,
                            capture_output_path,
                        )
                    case .LENS:
                        capture_succeeded = export_render_texture_png(
                            composite_render_target.texture,
                            capture_output_path,
                            &lens_crop_bounds,
                        )
                    case .SCENE:
                        capture_succeeded = export_render_texture_png(
                            scene_render_target.texture,
                            capture_output_path,
                        )
                    case .DOWNSAMPLE:
                        capture_succeeded = export_render_texture_png(
                            outlined_render_target.texture,
                            capture_output_path,
                        )
                    case .COVERAGE_MASK:
                        capture_succeeded = export_render_texture_png(
                            coverage_mask_render_target.texture,
                            capture_output_path,
                        )
                    }
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
            exit_code = 1
            break
        }
        exit_code = 0
        break
    }
    if exit_code != 0 {
        os.exit(exit_code)
    }
}
