package main

// Strict-JSON wire schema, validation, and transactional persistence for Scene
// Editor files. Runtime structs deliberately use raylib types while these file
// structs contain only predictable JSON values.

import json "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

Scene_File_Render :: struct {
    background:      [4]u8,
    downscale_level: int,
    edge_aa:         string,
}

Scene_File_Camera :: struct {
    projection:       string,
    position:         [3]f32,
    target:           [3]f32,
    up:               [3]f32,
    vertical_fov_deg: f32,
    ortho_height:     f32,
}

Scene_File_Directional_Light :: struct {
    enabled:         bool,
    direction:       [3]f32,
    color:           [3]f32,
    intensity:       f32,
    casts_shadows:   Maybe(bool) `json:"casts_shadows,omitempty"`,
    shadow_strength: Maybe(f32)  `json:"shadow_strength,omitempty"`,
    shadow_bias:     Maybe(f32)  `json:"shadow_bias,omitempty"`,
    shadow_extent:   Maybe(f32)  `json:"shadow_extent,omitempty"`,
}

Scene_File_Animation :: struct {
    clip_index: int,
    frame:      int,
}

Scene_File_Model :: struct {
    id:                 string,
    name:               string,
    visible:            bool,
    source:             string,
    position:           [3]f32,
    rotation_euler_deg: [3]f32,
    scale:              [3]f32,
    tint:               [4]u8,
    animation:          Maybe(Scene_File_Animation) `json:"animation,omitempty"`,
}

Scene_File_Primitive :: struct {
    id:                 string,
    name:               string,
    visible:            bool,
    shape:              string,
    position:           [3]f32,
    rotation_euler_deg: [3]f32,
    scale:              [3]f32,
    albedo:             [4]u8,
}

Scene_File_Point_Light :: struct {
    id:        string,
    name:      string,
    enabled:   bool,
    position:  [3]f32,
    color:     [3]f32,
    intensity: f32,
    range:     f32,
}

Scene_File_Spot_Light :: struct {
    id:              string,
    name:            string,
    enabled:         bool,
    position:        [3]f32,
    direction:       [3]f32,
    color:           [3]f32,
    intensity:       f32,
    range:           f32,
    inner_angle_deg: f32,
    outer_angle_deg: f32,
}

// Scene_File is the versioned wire owner. Strings and dynamic arrays produced
// by JSON unmarshal or scene_to_file must be released by destroy_scene_file;
// none of them are transferred into the runtime Scene by reference.
Scene_File :: struct {
    schema_version:    int,
    name:              string,
    style:             string,
    render:            Scene_File_Render,
    camera:            Scene_File_Camera,
    directional_light: Scene_File_Directional_Light,
    models:            [dynamic]Scene_File_Model,
    primitives:        [dynamic]Scene_File_Primitive,
    point_lights:      [dynamic]Scene_File_Point_Light,
    spot_lights:       [dynamic]Scene_File_Spot_Light,
}

// Odin's core JSON parser intentionally accepts a trailing comma in strict
// mode. Scene files tighten that behavior and also require exactly one root
// value so the on-disk contract remains RFC-style strict JSON.
scene_strict_json_valid :: proc(data: []byte) -> bool {
    if !json.is_valid(data, spec = .JSON) {
        return false
    }
    tokenizer := json.make_tokenizer(string(data), spec = .JSON)
    previous := json.Token_Kind.Invalid
    depth := 0
    root_started := false
    root_complete := false
    for {
        token, token_error := json.get_token(&tokenizer)
        if token_error != nil && token.kind != .EOF {
            return false
        }
        if token.kind == .EOF {
            return root_started && root_complete && depth == 0
        }
        if root_complete {
            return false
        }
        if (token.kind == .Close_Brace || token.kind == .Close_Bracket) &&
           previous == .Comma {
            return false
        }
        if !root_started {
            root_started = true
            if token.kind != .Open_Brace && token.kind != .Open_Bracket {
                root_complete = true
            }
        }
        #partial switch token.kind {
        case .Open_Brace, .Open_Bracket:
            depth += 1
        case .Close_Brace, .Close_Bracket:
            depth -= 1
            if depth == 0 {
                root_complete = true
            }
        }
        previous = token.kind
    }
}

scene_vector3_from_file :: proc(value: [3]f32) -> rl.Vector3 {
    return {value[0], value[1], value[2]}
}

scene_vector3_to_file :: proc(value: rl.Vector3) -> [3]f32 {
    return {value.x, value.y, value.z}
}

scene_transform_from_file :: proc(
    position, rotation_euler_deg, scale: [3]f32,
) -> Scene_Transform {
    return {
        position = scene_vector3_from_file(position),
        rotation_euler_deg = scene_vector3_from_file(rotation_euler_deg),
        scale = scene_vector3_from_file(scale),
    }
}

scene_file_path_portable :: proc(path: string, extension: string) -> bool {
    if len(path) == 0 || filepath.is_abs(path) ||
       strings.contains(path, "\\") ||
       path == ".." || strings.has_prefix(path, "../") ||
       strings.contains(path, "/../") || strings.has_suffix(path, "/..") ||
       !strings.equal_fold(os.ext(path), extension) {
        return false
    }
    cleaned, clean_error := filepath.clean(path)
    if clean_error != nil {
        return false
    }
    defer delete(cleaned)
    return cleaned != ".." &&
           !strings.has_prefix(cleaned, "../") &&
           !strings.contains(cleaned, "/../")
}

scene_model_extension_supported :: proc(path: string) -> bool {
    extension := os.ext(path)
    for supported_extension in SUPPORTED_MODEL_EXTENSIONS {
        if strings.equal_fold(extension, supported_extension) {
            return true
        }
    }
    return false
}

scene_light_common_valid :: proc(color: rl.Vector3, intensity: f32) -> bool {
    return scene_color3_valid(color) &&
           scene_f32_finite(intensity) &&
           intensity >= 0 && intensity <= SCENE_MAX_LIGHT_INTENSITY
}

// Validate all CPU-side invariants before GPU resources are created or a save
// is attempted. IDs share one namespace across every hierarchy kind because UI
// selection and future references identify an item independently of its array.
validate_scene :: proc(scene: ^Scene, require_files := true) -> Scene_Error {
    if !scene_name_valid(scene.name) {
        return .INVALID_NAME
    }
    if !scene_file_path_portable(scene.style_path, ".json") ||
       require_files && !os.is_file(scene.style_path) {
        return .INVALID_STYLE_PATH
    }
    if scene.render.downscale_level < MIN_DOWNSCALE_LEVEL ||
       scene.render.downscale_level > MAX_DOWNSCALE_LEVEL ||
       (scene.render.edge_aa != .HARD && scene.render.edge_aa != .COVERAGE) {
        return .INVALID_RENDER
    }

    if !scene_camera_valid(scene.camera) {
        return .INVALID_CAMERA
    }

    directional := &scene.directional_light
    if !scene_direction_valid(directional.direction) ||
       !scene_light_common_valid(directional.color, directional.intensity) ||
       !scene_f32_finite(directional.shadow_strength) ||
       directional.shadow_strength < SCENE_MIN_SHADOW_STRENGTH ||
       directional.shadow_strength > SCENE_MAX_SHADOW_STRENGTH ||
       !scene_f32_finite(directional.shadow_bias) ||
       directional.shadow_bias < SCENE_MIN_SHADOW_BIAS ||
       directional.shadow_bias > SCENE_MAX_SHADOW_BIAS ||
       !scene_f32_finite(directional.shadow_extent) ||
       directional.shadow_extent < SCENE_MIN_SHADOW_EXTENT ||
       directional.shadow_extent > SCENE_MAX_SHADOW_EXTENT {
        return .INVALID_DIRECTIONAL_LIGHT
    }

    total_items := len(scene.models) + len(scene.primitives) +
                   len(scene.point_lights) + len(scene.spot_lights)
    if total_items > SCENE_MAX_ITEMS { return .TOO_MANY_ITEMS }
    if len(scene.models) > SCENE_MAX_MODELS { return .TOO_MANY_MODELS }
    if len(scene.point_lights) > SCENE_MAX_POINT_LIGHTS {
        return .TOO_MANY_POINT_LIGHTS
    }
    if len(scene.spot_lights) > SCENE_MAX_SPOT_LIGHTS {
        return .TOO_MANY_SPOT_LIGHTS
    }

    ids := make(map[string]bool)
    defer delete(ids)
    validate_identity :: proc(id, name: string, ids: ^map[string]bool) -> Scene_Error {
        if !scene_id_valid(id) { return .INVALID_ID }
        if !scene_name_valid(name) { return .INVALID_NAME }
        if id in ids^ { return .DUPLICATE_ID }
        ids^[id] = true
        return .NONE
    }

    for model in scene.models {
        if error := validate_identity(model.id, model.name, &ids); error != .NONE {
            return error
        }
        if !scene_transform_valid(model.transform) {
            return .INVALID_TRANSFORM
        }
        if !scene_file_path_portable(model.source, os.ext(model.source)) ||
           !scene_model_extension_supported(model.source) ||
           require_files && !os.is_file(model.source) {
            return .INVALID_MODEL
        }
        if pose, present := model.animation.?; present {
            if pose.clip_index < 0 || pose.frame < 0 {
                return .INVALID_ANIMATION
            }
        }
    }

    for primitive in scene.primitives {
        if error := validate_identity(primitive.id, primitive.name, &ids);
           error != .NONE {
            return error
        }
        if !scene_transform_valid(primitive.transform) ||
           scene_primitive_shape_to_string(primitive.shape) == "" {
            return .INVALID_PRIMITIVE
        }
    }

    for light in scene.point_lights {
        if error := validate_identity(light.id, light.name, &ids);
           error != .NONE {
            return error
        }
        if !scene_vector3_finite(light.position) ||
           math.abs(light.position.x) > SCENE_MAX_POSITION ||
           math.abs(light.position.y) > SCENE_MAX_POSITION ||
           math.abs(light.position.z) > SCENE_MAX_POSITION ||
           !scene_light_common_valid(light.color, light.intensity) ||
           !scene_f32_finite(light.range) ||
           light.range < SCENE_MIN_LIGHT_RANGE ||
           light.range > SCENE_MAX_LIGHT_RANGE {
            return .INVALID_POINT_LIGHT
        }
    }

    for light in scene.spot_lights {
        if error := validate_identity(light.id, light.name, &ids);
           error != .NONE {
            return error
        }
        if !scene_vector3_finite(light.position) ||
           math.abs(light.position.x) > SCENE_MAX_POSITION ||
           math.abs(light.position.y) > SCENE_MAX_POSITION ||
           math.abs(light.position.z) > SCENE_MAX_POSITION ||
           !scene_direction_valid(light.direction) ||
           !scene_light_common_valid(light.color, light.intensity) ||
           !scene_f32_finite(light.range) ||
           light.range < SCENE_MIN_LIGHT_RANGE ||
           light.range > SCENE_MAX_LIGHT_RANGE ||
           !scene_f32_finite(light.inner_angle_deg) ||
           !scene_f32_finite(light.outer_angle_deg) ||
           light.inner_angle_deg < 0 ||
           light.inner_angle_deg >= light.outer_angle_deg ||
           light.outer_angle_deg > 89 {
            return .INVALID_SPOT_LIGHT
        }
    }
    return .NONE
}

// Both json.unmarshal and scene_to_file create the same ownership shape, so a
// single destructor handles load temporaries, save temporaries, and failures.
destroy_scene_file :: proc(file: ^Scene_File) {
    if len(file.name) > 0 { delete(file.name) }
    if len(file.style) > 0 { delete(file.style) }
    if len(file.render.edge_aa) > 0 { delete(file.render.edge_aa) }
    if len(file.camera.projection) > 0 { delete(file.camera.projection) }
    for model in file.models {
        if len(model.id) > 0 { delete(model.id) }
        if len(model.name) > 0 { delete(model.name) }
        if len(model.source) > 0 { delete(model.source) }
    }
    for primitive in file.primitives {
        if len(primitive.id) > 0 { delete(primitive.id) }
        if len(primitive.name) > 0 { delete(primitive.name) }
        if len(primitive.shape) > 0 { delete(primitive.shape) }
    }
    for light in file.point_lights {
        if len(light.id) > 0 { delete(light.id) }
        if len(light.name) > 0 { delete(light.name) }
    }
    for light in file.spot_lights {
        if len(light.id) > 0 { delete(light.id) }
        if len(light.name) > 0 { delete(light.name) }
    }
    delete(file.models)
    delete(file.primitives)
    delete(file.point_lights)
    delete(file.spot_lights)
    file^ = {}
}

// Build a fully owned runtime value without mutating an active scene. Any
// conversion or validation failure destroys the partial result before return;
// callers may commit the returned Scene only on .NONE.
scene_from_file :: proc(
    file: ^Scene_File,
    require_files := true,
) -> (Scene, Scene_Error) {
    if file.schema_version != SCENE_SCHEMA_VERSION {
        return {}, .INVALID_SCHEMA
    }
    projection, projection_valid := scene_projection_from_string(file.camera.projection)
    if !projection_valid { return {}, .INVALID_CAMERA }
    edge_aa, edge_aa_valid := scene_edge_aa_from_string(file.render.edge_aa)
    if !edge_aa_valid { return {}, .INVALID_RENDER }

    scene := Scene{
        name = strings.clone(file.name),
        style_path = strings.clone(file.style),
        render = {
            background = {
                file.render.background[0],
                file.render.background[1],
                file.render.background[2],
                file.render.background[3],
            },
            downscale_level = file.render.downscale_level,
            edge_aa = edge_aa,
        },
        camera = {
            projection = projection,
            position = scene_vector3_from_file(file.camera.position),
            target = scene_vector3_from_file(file.camera.target),
            up = scene_vector3_from_file(file.camera.up),
            vertical_fov_deg = file.camera.vertical_fov_deg,
            ortho_height = file.camera.ortho_height,
        },
        directional_light = {
            enabled = file.directional_light.enabled,
            direction = scene_vector3_from_file(file.directional_light.direction),
            color = scene_vector3_from_file(file.directional_light.color),
            intensity = file.directional_light.intensity,
            // Shadow members are optional so v1 scenes written before hard
            // shadows remain valid and preserve their original unshadowed look.
            casts_shadows = false,
            shadow_strength = SCENE_DEFAULT_SHADOW_STRENGTH,
            shadow_bias = SCENE_DEFAULT_SHADOW_BIAS,
            shadow_extent = SCENE_DEFAULT_SHADOW_EXTENT,
        },
    }
    if value, present := file.directional_light.casts_shadows.?; present {
        scene.directional_light.casts_shadows = value
    }
    if value, present := file.directional_light.shadow_strength.?; present {
        scene.directional_light.shadow_strength = value
    }
    if value, present := file.directional_light.shadow_bias.?; present {
        scene.directional_light.shadow_bias = value
    }
    if value, present := file.directional_light.shadow_extent.?; present {
        scene.directional_light.shadow_extent = value
    }
    for model in file.models {
        runtime_model := Scene_Model{
            id = strings.clone(model.id),
            name = strings.clone(model.name),
            visible = model.visible,
            source = strings.clone(model.source),
            transform = scene_transform_from_file(
                model.position,
                model.rotation_euler_deg,
                model.scale,
            ),
            tint = {model.tint[0], model.tint[1], model.tint[2], model.tint[3]},
        }
        if animation, present := model.animation.?; present {
            runtime_model.animation = Scene_Animation_Pose{
                clip_index = animation.clip_index,
                frame = animation.frame,
            }
        }
        append(&scene.models, runtime_model)
    }
    for primitive in file.primitives {
        shape, shape_valid := scene_primitive_shape_from_string(primitive.shape)
        if !shape_valid {
            destroy_scene(&scene)
            return {}, .INVALID_PRIMITIVE
        }
        append(&scene.primitives, Scene_Primitive{
            id = strings.clone(primitive.id),
            name = strings.clone(primitive.name),
            visible = primitive.visible,
            shape = shape,
            transform = scene_transform_from_file(
                primitive.position,
                primitive.rotation_euler_deg,
                primitive.scale,
            ),
            albedo = {
                primitive.albedo[0], primitive.albedo[1],
                primitive.albedo[2], primitive.albedo[3],
            },
        })
    }
    for light in file.point_lights {
        append(&scene.point_lights, Scene_Point_Light{
            id = strings.clone(light.id),
            name = strings.clone(light.name),
            enabled = light.enabled,
            position = scene_vector3_from_file(light.position),
            color = scene_vector3_from_file(light.color),
            intensity = light.intensity,
            range = light.range,
        })
    }
    for light in file.spot_lights {
        append(&scene.spot_lights, Scene_Spot_Light{
            id = strings.clone(light.id),
            name = strings.clone(light.name),
            enabled = light.enabled,
            position = scene_vector3_from_file(light.position),
            direction = scene_vector3_from_file(light.direction),
            color = scene_vector3_from_file(light.color),
            intensity = light.intensity,
            range = light.range,
            inner_angle_deg = light.inner_angle_deg,
            outer_angle_deg = light.outer_angle_deg,
        })
    }

    if scene_direction_valid(scene.directional_light.direction) {
        scene.directional_light.direction =
            scene_normalize_direction_stable(scene.directional_light.direction)
    }
    for &light in scene.spot_lights {
        if scene_direction_valid(light.direction) {
            light.direction = scene_normalize_direction_stable(light.direction)
        }
    }
    if validation_error := validate_scene(&scene, require_files);
       validation_error != .NONE {
        destroy_scene(&scene)
        return {}, validation_error
    }
    return scene, .NONE
}

// Produce an independent wire owner in declaration/array order. Euler angles
// and directions are canonicalized here so repeated save/load/save operations
// remain byte-stable instead of accumulating representational drift.
scene_to_file :: proc(scene: ^Scene) -> Scene_File {
    file := Scene_File{
        schema_version = SCENE_SCHEMA_VERSION,
        name = strings.clone(scene.name),
        style = strings.clone(scene.style_path),
        render = {
            background = {
                scene.render.background.r,
                scene.render.background.g,
                scene.render.background.b,
                scene.render.background.a,
            },
            downscale_level = scene.render.downscale_level,
            edge_aa = strings.clone(scene_edge_aa_to_string(scene.render.edge_aa)),
        },
        camera = {
            projection = strings.clone(scene_projection_to_string(scene.camera.projection)),
            position = scene_vector3_to_file(scene.camera.position),
            target = scene_vector3_to_file(scene.camera.target),
            up = scene_vector3_to_file(scene.camera.up),
            vertical_fov_deg = scene.camera.vertical_fov_deg,
            ortho_height = scene.camera.ortho_height,
        },
        directional_light = {
            enabled = scene.directional_light.enabled,
            direction = scene_vector3_to_file(
                scene_normalize_direction_stable(scene.directional_light.direction),
            ),
            color = scene_vector3_to_file(scene.directional_light.color),
            intensity = scene.directional_light.intensity,
            casts_shadows = scene.directional_light.casts_shadows,
            shadow_strength = scene.directional_light.shadow_strength,
            shadow_bias = scene.directional_light.shadow_bias,
            shadow_extent = scene.directional_light.shadow_extent,
        },
    }
    for model in scene.models {
        rotation := scene_normalize_euler_degrees(model.transform.rotation_euler_deg)
        file_model := Scene_File_Model{
            id = strings.clone(model.id),
            name = strings.clone(model.name),
            visible = model.visible,
            source = strings.clone(model.source),
            position = scene_vector3_to_file(model.transform.position),
            rotation_euler_deg = scene_vector3_to_file(rotation),
            scale = scene_vector3_to_file(model.transform.scale),
            tint = {model.tint.r, model.tint.g, model.tint.b, model.tint.a},
        }
        if animation, present := model.animation.?; present {
            file_model.animation = Scene_File_Animation{
                clip_index = animation.clip_index,
                frame = animation.frame,
            }
        }
        append(&file.models, file_model)
    }
    for primitive in scene.primitives {
        rotation := scene_normalize_euler_degrees(
            primitive.transform.rotation_euler_deg,
        )
        append(&file.primitives, Scene_File_Primitive{
            id = strings.clone(primitive.id),
            name = strings.clone(primitive.name),
            visible = primitive.visible,
            shape = strings.clone(scene_primitive_shape_to_string(primitive.shape)),
            position = scene_vector3_to_file(primitive.transform.position),
            rotation_euler_deg = scene_vector3_to_file(rotation),
            scale = scene_vector3_to_file(primitive.transform.scale),
            albedo = {
                primitive.albedo.r, primitive.albedo.g,
                primitive.albedo.b, primitive.albedo.a,
            },
        })
    }
    for light in scene.point_lights {
        append(&file.point_lights, Scene_File_Point_Light{
            id = strings.clone(light.id),
            name = strings.clone(light.name),
            enabled = light.enabled,
            position = scene_vector3_to_file(light.position),
            color = scene_vector3_to_file(light.color),
            intensity = light.intensity,
            range = light.range,
        })
    }
    for light in scene.spot_lights {
        append(&file.spot_lights, Scene_File_Spot_Light{
            id = strings.clone(light.id),
            name = strings.clone(light.name),
            enabled = light.enabled,
            position = scene_vector3_to_file(light.position),
            direction = scene_vector3_to_file(
                scene_normalize_direction_stable(light.direction),
            ),
            color = scene_vector3_to_file(light.color),
            intensity = light.intensity,
            range = light.range,
            inner_angle_deg = light.inner_angle_deg,
            outer_angle_deg = light.outer_angle_deg,
        })
    }
    return file
}

// Parsing is two-stage: the strict token pass rejects syntax accepted by Odin's
// JSON decoder, then unmarshal and conversion establish ownership and semantics.
load_scene :: proc(path: string, require_files := true) -> (Scene, Scene_Error) {
    file_data, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        return {}, .READ_FAILED
    }
    defer delete(file_data)

    if !scene_strict_json_valid(file_data) {
        return {}, .PARSE_FAILED
    }
    file: Scene_File
    parse_error := json.unmarshal(file_data, &file, spec = .JSON)
    if parse_error != nil {
        destroy_scene_file(&file)
        return {}, .PARSE_FAILED
    }
    defer destroy_scene_file(&file)
    return scene_from_file(&file, require_files)
}

// Save is transactional at the destination path. The canonical JSON is written
// to a sibling temporary file and renamed only after the entire write succeeds,
// leaving the previous scene intact on encoding or I/O failure.
save_scene :: proc(path: string, scene: ^Scene) -> Scene_Error {
    if validation_error := validate_scene(scene); validation_error != .NONE {
        return validation_error
    }
    if len(path) == 0 || !strings.equal_fold(os.ext(path), ".json") {
        return .WRITE_FAILED
    }

    file := scene_to_file(scene)
    defer destroy_scene_file(&file)
    encoded, marshal_error := json.marshal(
        file,
        {spec = .JSON, pretty = true, use_spaces = true, spaces = 2},
    )
    if marshal_error != nil {
        return .WRITE_FAILED
    }
    defer delete(encoded)

    output_directory := filepath.dir(path)
    if output_directory != "" && output_directory != "." {
        if directory_error := os.make_directory_all(output_directory);
           directory_error != nil && !os.is_directory(output_directory) {
            return .WRITE_FAILED
        }
    }
    temporary_path := fmt.aprintf("%s.tmp", path)
    defer delete(temporary_path)
    if write_error := os.write_entire_file(temporary_path, encoded);
       write_error != nil {
        return .WRITE_FAILED
    }
    if rename_error := os.rename(temporary_path, path); rename_error != nil {
        _ = os.remove(temporary_path)
        return .WRITE_FAILED
    }
    return .NONE
}
