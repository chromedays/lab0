package main

// Runtime data and pure math for the visual-test-only Scene Editor. File
// compatibility is kept in scene_file.odin so raylib resource ownership and
// schema migration remain independent concerns.

import "core:math"
import "core:strings"
import rl "vendor:raylib"

SCENE_SCHEMA_VERSION       :: 1
SCENE_SCREEN_WIDTH         :: 1280
SCENE_SCREEN_HEIGHT        :: 720
SCENE_MAX_ITEMS            :: 256
SCENE_MAX_MODELS           :: 128
SCENE_MAX_POINT_LIGHTS     :: 8
SCENE_MAX_SPOT_LIGHTS      :: 8
SCENE_MAX_NAME_BYTES       :: 128
SCENE_MAX_ID_BYTES         :: 64
SCENE_DIRECTION_EPSILON    :: f32(0.00001)
SCENE_MIN_SCALE            :: f32(0.001)
SCENE_MAX_SCALE            :: f32(1000)
SCENE_MAX_POSITION         :: f32(100000)
SCENE_MIN_LIGHT_RANGE      :: f32(0.001)
SCENE_MAX_LIGHT_RANGE      :: f32(100000)
SCENE_MAX_LIGHT_INTENSITY  :: f32(16)
SCENE_SHADOW_MAP_SIZE      :: 1024
SCENE_MIN_SHADOW_STRENGTH  :: f32(0)
SCENE_MAX_SHADOW_STRENGTH  :: f32(1)
SCENE_MIN_SHADOW_BIAS      :: f32(0.00001)
SCENE_MAX_SHADOW_BIAS      :: f32(0.01)
SCENE_MIN_SHADOW_EXTENT    :: f32(1)
SCENE_MAX_SHADOW_EXTENT    :: f32(1000)
SCENE_DEFAULT_SHADOW_STRENGTH :: f32(0.65)
SCENE_DEFAULT_SHADOW_BIAS     :: f32(0.00035)
SCENE_DEFAULT_SHADOW_EXTENT   :: f32(20)

Scene_Error :: enum {
    NONE,
    READ_FAILED,
    PARSE_FAILED,
    WRITE_FAILED,
    INVALID_SCHEMA,
    INVALID_NAME,
    INVALID_STYLE_PATH,
    INVALID_RENDER,
    INVALID_CAMERA,
    TOO_MANY_ITEMS,
    TOO_MANY_MODELS,
    TOO_MANY_POINT_LIGHTS,
    TOO_MANY_SPOT_LIGHTS,
    INVALID_ID,
    DUPLICATE_ID,
    INVALID_TRANSFORM,
    INVALID_MODEL,
    INVALID_ANIMATION,
    INVALID_PRIMITIVE,
    INVALID_DIRECTIONAL_LIGHT,
    INVALID_POINT_LIGHT,
    INVALID_SPOT_LIGHT,
}

scene_error_message :: proc(error: Scene_Error) -> string {
    switch error {
    case .NONE:                      return "no error"
    case .READ_FAILED:               return "scene file could not be read"
    case .PARSE_FAILED:              return "scene file is not valid strict JSON"
    case .WRITE_FAILED:              return "scene file could not be written"
    case .INVALID_SCHEMA:            return "unsupported scene schema version"
    case .INVALID_NAME:              return "scene or item name is invalid"
    case .INVALID_STYLE_PATH:        return "scene cel-style path is invalid"
    case .INVALID_RENDER:            return "scene render settings are invalid"
    case .INVALID_CAMERA:            return "scene camera is invalid"
    case .TOO_MANY_ITEMS:            return "scene exceeds the total item limit"
    case .TOO_MANY_MODELS:           return "scene exceeds the imported-model limit"
    case .TOO_MANY_POINT_LIGHTS:     return "scene exceeds the point-light limit"
    case .TOO_MANY_SPOT_LIGHTS:      return "scene exceeds the spot-light limit"
    case .INVALID_ID:                return "scene item ID is invalid"
    case .DUPLICATE_ID:              return "scene item IDs must be globally unique"
    case .INVALID_TRANSFORM:         return "scene transform is invalid"
    case .INVALID_MODEL:             return "scene model is invalid"
    case .INVALID_ANIMATION:         return "scene fixed animation pose is invalid"
    case .INVALID_PRIMITIVE:         return "scene primitive is invalid"
    case .INVALID_DIRECTIONAL_LIGHT: return "scene directional light is invalid"
    case .INVALID_POINT_LIGHT:       return "scene point light is invalid"
    case .INVALID_SPOT_LIGHT:        return "scene spot light is invalid"
    }
    return "unknown scene error"
}

Scene_Projection :: enum {
    PERSPECTIVE,
    ORTHOGRAPHIC,
}

Scene_Primitive_Shape :: enum {
    CUBE,
    SPHERE,
    PLANE,
    TRIANGLE,
    CYLINDER,
    CONE,
    TORUS,
}

// Transforms use world units, XYZ Euler degrees, and strictly positive scale.
// scene_transform_matrix defines the serialized v1 order; editing that order
// changes both picking and rendered output for every scene.
Scene_Transform :: struct {
    position:           rl.Vector3,
    rotation_euler_deg: rl.Vector3,
    scale:              rl.Vector3,
}

Scene_Animation_Pose :: struct {
    clip_index: int,
    frame:      int,
}

// Runtime items own their id/name/source strings. A Scene_Model's optional pose
// is a fixed keyframe selection, never a wall-clock animation request.
Scene_Model :: struct {
    id:        string,
    name:      string,
    visible:   bool,
    source:    string,
    transform: Scene_Transform,
    tint:      rl.Color,
    animation: Maybe(Scene_Animation_Pose),
}

Scene_Primitive :: struct {
    id:        string,
    name:      string,
    visible:   bool,
    shape:     Scene_Primitive_Shape,
    transform: Scene_Transform,
    albedo:    rl.Color,
}

// Directional direction points from a surface toward the source. Spot direction
// instead points outward from the light into its cone; both are normalized on
// load before reaching renderer uniform upload.
Scene_Directional_Light :: struct {
    enabled:         bool,
    direction:       rl.Vector3,
    color:           rl.Vector3,
    intensity:       f32,
    casts_shadows:   bool,
    shadow_strength: f32,
    shadow_bias:     f32,
    shadow_extent:   f32,
}

Scene_Point_Light :: struct {
    id:        string,
    name:      string,
    enabled:   bool,
    position:  rl.Vector3,
    color:     rl.Vector3,
    intensity: f32,
    range:     f32,
}

Scene_Spot_Light :: struct {
    id:              string,
    name:            string,
    enabled:         bool,
    position:        rl.Vector3,
    direction:       rl.Vector3,
    color:           rl.Vector3,
    intensity:       f32,
    range:           f32,
    inner_angle_deg: f32,
    outer_angle_deg: f32,
}

Scene_Render_Settings :: struct {
    background:      rl.Color,
    downscale_level: int,
    edge_aa:         Edge_AA_Mode,
}

Scene_Camera :: struct {
    projection:       Scene_Projection,
    position:         rl.Vector3,
    target:           rl.Vector3,
    up:               rl.Vector3,
    vertical_fov_deg: f32,
    ortho_height:     f32,
}

// Scene owns every string and dynamic array below. UI selection and GPU model
// resources live in parallel editor structures and are intentionally excluded
// from serialization. next_* counters are transient ID allocators rebuilt from
// existing IDs on first use after load.
Scene :: struct {
    name:              string,
    style_path:        string,
    render:            Scene_Render_Settings,
    camera:            Scene_Camera,
    directional_light: Scene_Directional_Light,
    models:            [dynamic]Scene_Model,
    primitives:        [dynamic]Scene_Primitive,
    point_lights:      [dynamic]Scene_Point_Light,
    spot_lights:       [dynamic]Scene_Spot_Light,
    dirty:             bool,
    next_model_id:     int,
    next_primitive_id: int,
    next_point_id:     int,
    next_spot_id:      int,
}

scene_f32_finite :: proc(value: f32) -> bool {
    return !math.is_nan(value) && !math.is_inf(value)
}

scene_vector3_finite :: proc(value: rl.Vector3) -> bool {
    return scene_f32_finite(value.x) &&
           scene_f32_finite(value.y) &&
           scene_f32_finite(value.z)
}

scene_color3_valid :: proc(value: rl.Vector3) -> bool {
    return scene_vector3_finite(value) &&
           value.x >= 0 && value.x <= 1 &&
           value.y >= 0 && value.y <= 1 &&
           value.z >= 0 && value.z <= 1
}

scene_direction_valid :: proc(value: rl.Vector3) -> bool {
    return scene_vector3_finite(value) &&
           rl.Vector3Length(value) > SCENE_DIRECTION_EPSILON
}

// Avoid repeatedly normalizing an already unit-length serialized vector. A
// second f32 normalization can change the final bit and break canonical
// save/load/save bytes even though the direction is visually identical.
scene_normalize_direction_stable :: proc(value: rl.Vector3) -> rl.Vector3 {
    length := rl.Vector3Length(value)
    if !scene_f32_finite(length) || length <= SCENE_DIRECTION_EPSILON {
        return value
    }
    if math.abs(length - 1) <= SCENE_DIRECTION_EPSILON {
        return value
    }
    return value / length
}

scene_name_valid :: proc(value: string) -> bool {
    return len(value) > 0 && len(value) <= SCENE_MAX_NAME_BYTES
}

scene_id_valid :: proc(value: string) -> bool {
    if len(value) == 0 || len(value) > SCENE_MAX_ID_BYTES {
        return false
    }
    first := value[0]
    if !((first >= 'A' && first <= 'Z') ||
         (first >= 'a' && first <= 'z')) {
        return false
    }
    for character in value[1:] {
        if (character >= 'A' && character <= 'Z') ||
           (character >= 'a' && character <= 'z') ||
           (character >= '0' && character <= '9') ||
           character == '_' || character == '-' {
            continue
        }
        return false
    }
    return true
}

scene_transform_valid :: proc(transform: Scene_Transform) -> bool {
    if !scene_vector3_finite(transform.position) ||
       !scene_vector3_finite(transform.rotation_euler_deg) ||
       !scene_vector3_finite(transform.scale) {
        return false
    }
    if math.abs(transform.position.x) > SCENE_MAX_POSITION ||
       math.abs(transform.position.y) > SCENE_MAX_POSITION ||
       math.abs(transform.position.z) > SCENE_MAX_POSITION {
        return false
    }
    return transform.scale.x >= SCENE_MIN_SCALE &&
           transform.scale.x <= SCENE_MAX_SCALE &&
           transform.scale.y >= SCENE_MIN_SCALE &&
           transform.scale.y <= SCENE_MAX_SCALE &&
           transform.scale.z >= SCENE_MIN_SCALE &&
           transform.scale.z <= SCENE_MAX_SCALE
}

scene_camera_valid :: proc(camera: Scene_Camera) -> bool {
    camera_forward := camera.target - camera.position
    return (camera.projection == .PERSPECTIVE ||
            camera.projection == .ORTHOGRAPHIC) &&
           scene_vector3_finite(camera.position) &&
           scene_vector3_finite(camera.target) &&
           scene_direction_valid(camera_forward) &&
           scene_direction_valid(camera.up) &&
           rl.Vector3Length(
               rl.Vector3CrossProduct(camera_forward, camera.up),
           ) > SCENE_DIRECTION_EPSILON &&
           scene_f32_finite(camera.vertical_fov_deg) &&
           camera.vertical_fov_deg >= 1 && camera.vertical_fov_deg <= 179 &&
           scene_f32_finite(camera.ortho_height) &&
           camera.ortho_height >= SCENE_MIN_SCALE &&
           camera.ortho_height <= SCENE_MAX_POSITION
}

scene_normalize_angle_degrees :: proc(value: f32) -> f32 {
    normalized := math.mod(value + 180, 360)
    if normalized < 0 {
        normalized += 360
    }
    return normalized - 180
}

scene_normalize_euler_degrees :: proc(value: rl.Vector3) -> rl.Vector3 {
    return {
        scene_normalize_angle_degrees(value.x),
        scene_normalize_angle_degrees(value.y),
        scene_normalize_angle_degrees(value.z),
    }
}

// Preserve the v1 transform contract: vertices see Scale, then local X/Y/Z
// rotations, then Translation (M = T * Rz * Ry * Rx * S).
scene_transform_matrix :: proc(transform: Scene_Transform) -> rl.Matrix {
    degrees_to_radians :: f32(math.PI / 180)
    rotation := transform.rotation_euler_deg * degrees_to_radians
    translation_matrix := rl.MatrixTranslate(
        transform.position.x,
        transform.position.y,
        transform.position.z,
    )
    rotation_matrix := rl.MatrixRotateZ(rotation.z) *
                       rl.MatrixRotateY(rotation.y) *
                       rl.MatrixRotateX(rotation.x)
    scale_matrix := rl.MatrixScale(
        transform.scale.x,
        transform.scale.y,
        transform.scale.z,
    )
    return translation_matrix * rotation_matrix * scale_matrix
}

scene_camera_to_raylib :: proc(camera: Scene_Camera) -> rl.Camera3D {
    projection := rl.CameraProjection.PERSPECTIVE
    fovy := camera.vertical_fov_deg
    if camera.projection == .ORTHOGRAPHIC {
        projection = .ORTHOGRAPHIC
        fovy = camera.ortho_height
    }
    return {
        position = camera.position,
        target = camera.target,
        up = camera.up,
        fovy = fovy,
        projection = projection,
    }
}

scene_projection_from_string :: proc(value: string) -> (Scene_Projection, bool) {
    switch value {
    case "perspective":  return .PERSPECTIVE, true
    case "orthographic": return .ORTHOGRAPHIC, true
    }
    return {}, false
}

scene_projection_to_string :: proc(value: Scene_Projection) -> string {
    switch value {
    case .PERSPECTIVE:  return "perspective"
    case .ORTHOGRAPHIC: return "orthographic"
    }
    return ""
}

scene_primitive_shape_from_string :: proc(value: string) -> (Scene_Primitive_Shape, bool) {
    switch value {
    case "cube":     return .CUBE, true
    case "sphere":   return .SPHERE, true
    case "plane":    return .PLANE, true
    case "triangle": return .TRIANGLE, true
    case "cylinder": return .CYLINDER, true
    case "cone":     return .CONE, true
    case "torus":    return .TORUS, true
    }
    return {}, false
}

scene_primitive_shape_to_string :: proc(value: Scene_Primitive_Shape) -> string {
    switch value {
    case .CUBE:     return "cube"
    case .SPHERE:   return "sphere"
    case .PLANE:    return "plane"
    case .TRIANGLE: return "triangle"
    case .CYLINDER: return "cylinder"
    case .CONE:     return "cone"
    case .TORUS:    return "torus"
    }
    return ""
}

scene_edge_aa_from_string :: proc(value: string) -> (Edge_AA_Mode, bool) {
    switch value {
    case "hard":     return .HARD, true
    case "coverage": return .COVERAGE, true
    }
    return {}, false
}

scene_edge_aa_to_string :: proc(value: Edge_AA_Mode) -> string {
    switch value {
    case .HARD:     return "hard"
    case .COVERAGE: return "coverage"
    }
    return ""
}

// The default scene follows the same ownership contract as a loaded scene: its
// static defaults are cloned so destroy_scene is always the matching cleanup.
make_default_scene :: proc() -> Scene {
    return {
        name = strings.clone("Untitled Scene"),
        style_path = strings.clone("styles/classic.json"),
        render = {
            background = {28, 30, 38, 255},
            downscale_level = DEFAULT_DOWNSCALE_LEVEL,
            edge_aa = .COVERAGE,
        },
        camera = {
            projection = .PERSPECTIVE,
            position = {6, 4, 6},
            target = {0, 1, 0},
            up = {0, 1, 0},
            vertical_fov_deg = 45,
            ortho_height = 8,
        },
        directional_light = {
            enabled = true,
            direction = scene_normalize_direction_stable({0.35, 0.8, 0.55}),
            color = {1, 1, 1},
            intensity = 0.7,
            casts_shadows = true,
            shadow_strength = SCENE_DEFAULT_SHADOW_STRENGTH,
            shadow_bias = SCENE_DEFAULT_SHADOW_BIAS,
            shadow_extent = SCENE_DEFAULT_SHADOW_EXTENT,
        },
    }
}

// Release child strings before their containing arrays, then clear the owner so
// deferred cleanup remains safe after transactional scene replacement.
destroy_scene :: proc(scene: ^Scene) {
    if len(scene.name) > 0 { delete(scene.name) }
    if len(scene.style_path) > 0 { delete(scene.style_path) }
    for model in scene.models {
        if len(model.id) > 0 { delete(model.id) }
        if len(model.name) > 0 { delete(model.name) }
        if len(model.source) > 0 { delete(model.source) }
    }
    for primitive in scene.primitives {
        if len(primitive.id) > 0 { delete(primitive.id) }
        if len(primitive.name) > 0 { delete(primitive.name) }
    }
    for light in scene.point_lights {
        if len(light.id) > 0 { delete(light.id) }
        if len(light.name) > 0 { delete(light.name) }
    }
    for light in scene.spot_lights {
        if len(light.id) > 0 { delete(light.id) }
        if len(light.name) > 0 { delete(light.name) }
    }
    delete(scene.models)
    delete(scene.primitives)
    delete(scene.point_lights)
    delete(scene.spot_lights)
    scene^ = {}
}
