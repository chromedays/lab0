package shared

// Viewer infrastructure shared by Viewer, Game, and Scene Editor.

import "core:fmt"
import json "core:encoding/json"
import "core:os"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

ASSETS_PATH :: "assets"
ANIMATION_SAMPLE_FPS :: 60.0
GLTF_SKIN_SCALE_EPSILON :: f32(0.0001)
MODEL_SEARCH_TEXT_CAPACITY :: 128
DEFAULT_DOWNSCALE_LEVEL :: 10
MIN_DOWNSCALE_LEVEL :: 1
MAX_DOWNSCALE_LEVEL :: 32
DEFAULT_COLOR_CLUSTER_THRESHOLD :: 0.10
DOWNSCALE_FS_PATH :: "shaders/downscale.fs"
MASK_DOWNSCALE_FS_PATH :: "shaders/mask_downscale.fs"
OUTLINE_FS_PATH :: "shaders/outline.fs"
VIEWER_VIDEO_FRAMES_PER_SECOND :: 60

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

// Edge_AA_Mode controls only the viewer's low-resolution silhouette resolve.
// HARD preserves the historical binary output; COVERAGE exposes the existing
// deterministic 4x4 occupancy as fractional alpha.
Edge_AA_Mode :: enum {
    HARD,
    COVERAGE,
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
