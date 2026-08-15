package main

// Interactive raygui hierarchy, inspector, file controls, picking, and camera
// navigation for shared.Scene Editor mode. Editor-only overlays are drawn after the
// deterministic composite texture and therefore never enter captures.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import shared "./shared"
import rl "vendor:raylib"

SCENE_EDITOR_TOP_HEIGHT   :: f32(40)
SCENE_EDITOR_LEFT_WIDTH   :: f32(250)
SCENE_EDITOR_RIGHT_WIDTH  :: f32(320)
SCENE_EDITOR_PATH_CAPACITY :: 384
SCENE_EDITOR_MODEL_PATH_CAPACITY :: 256
SCENE_EDITOR_NAME_CAPACITY :: shared.SCENE_MAX_NAME_BYTES + 1

Scene_Selection_Kind :: enum {
    NONE,
    MODEL,
    PRIMITIVE,
    POINT_LIGHT,
    SPOT_LIGHT,
}

// Selection indexes one of shared.Scene's four dynamic arrays. Model selection also
// indexes shared.Scene_Resources.models; mutation helpers must keep those arrays in
// identical order and clear selection after an index-removing operation.
Scene_Selection :: struct {
    kind:  Scene_Selection_Kind,
    index: int,
}

Scene_Gizmo_Mode :: enum {
    TRANSLATE,
    ROTATE,
    SCALE,
}

// Pending actions are destructive operations deferred behind the unsaved-work
// modal. DELETE uses its own confirmation path; the others resume through
// scene_editor_complete_pending_action after Save or Discard.
Scene_Pending_Action :: enum {
    NONE,
    NEW,
    OPEN,
    DELETE,
    EXIT,
}

Scene_UI_Status :: enum {
    NONE,
    SAVED,
    SAVE_FAILED,
    LOADED,
    LOAD_FAILED,
    UNSAVED_LOAD_BLOCKED,
    MODEL_ADDED,
    MODEL_ADD_FAILED,
    ITEM_ADDED,
    ITEM_DELETED,
    NEW_SCENE,
}

// Editor UI state is transient and never serialized. Fixed byte buffers are
// zero-terminated storage passed directly to raygui; *_editing owns keyboard
// focus, while pending_action/save_as_open own modal input.
Scene_Editor_UI_State :: struct {
    selection:          Scene_Selection,
    hierarchy_scroll:   c.int,
    hierarchy_active:   c.int,
    hierarchy_focus:    c.int,
    primitive_shape:    c.int,
    scene_path:         [SCENE_EDITOR_PATH_CAPACITY]u8,
    scene_path_editing: bool,
    save_as_path:       [SCENE_EDITOR_PATH_CAPACITY]u8,
    save_as_open:       bool,
    save_as_secret:     bool,
    model_path:         [SCENE_EDITOR_MODEL_PATH_CAPACITY]u8,
    model_path_editing: bool,
    item_name:          [SCENE_EDITOR_NAME_CAPACITY]u8,
    item_name_editing:  bool,
    item_name_target:   Scene_Selection,
    status:             Scene_UI_Status,
    load_requested:     bool,
    new_requested:      bool,
    pending_action:     Scene_Pending_Action,
    exit_requested:     bool,
    gizmo_mode:         Scene_Gizmo_Mode,
    gizmo_axis:         int,
}

scene_ui_buffer_set :: proc(buffer: []u8, value: string) {
    for &character in buffer { character = 0 }
    copy(buffer[:max(len(buffer) - 1, 0)], transmute([]u8)value)
}

scene_ui_buffer_string :: proc(buffer: []u8) -> string {
    if len(buffer) == 0 { return "" }
    return string(cstring(raw_data(buffer)))
}

scene_editor_ui_init :: proc(
    state: ^Scene_Editor_UI_State,
    scene_path: string,
) {
    state.selection = {.NONE, -1}
    state.hierarchy_active = -1
    state.hierarchy_focus = -1
    state.gizmo_mode = .TRANSLATE
    state.gizmo_axis = -1
    state.item_name_target = {.NONE, -1}
    path := scene_path
    if len(path) == 0 { path = "scenes/untitled.json" }
    scene_ui_buffer_set(state.scene_path[:], path)
    scene_ui_buffer_set(state.model_path[:], "assets/CesiumMan.glb")
}

scene_editor_request_save_as :: proc(state: ^Scene_Editor_UI_State) {
    scene_ui_buffer_set(
        state.save_as_path[:],
        scene_ui_buffer_string(state.scene_path[:]),
    )
    state.save_as_secret = false
    state.save_as_open = true
}

scene_editor_complete_pending_action :: proc(
    state: ^Scene_Editor_UI_State,
) {
    switch state.pending_action {
    case .NONE:
    case .NEW:  state.new_requested = true
    case .OPEN: state.load_requested = true
    case .DELETE:
    case .EXIT: state.exit_requested = true
    }
    state.pending_action = .NONE
}

scene_ui_status_text :: proc(status: Scene_UI_Status) -> cstring {
    switch status {
    case .NONE:                 return "Ready"
    case .SAVED:                return "shared.Scene saved"
    case .SAVE_FAILED:          return "Save failed - check validation and path"
    case .LOADED:               return "shared.Scene loaded"
    case .LOAD_FAILED:          return "Load failed - previous scene kept"
    case .UNSAVED_LOAD_BLOCKED: return "Save changes before loading another scene"
    case .MODEL_ADDED:          return "Model added"
    case .MODEL_ADD_FAILED:     return "Model path or resource is invalid"
    case .ITEM_ADDED:           return "Item added"
    case .ITEM_DELETED:         return "Item deleted"
    case .NEW_SCENE:            return "New scene"
    }
    return ""
}

scene_editor_viewport_bounds :: proc() -> rl.Rectangle {
    available := rl.Rectangle{
        SCENE_EDITOR_LEFT_WIDTH,
        SCENE_EDITOR_TOP_HEIGHT,
        f32(shared.SCENE_SCREEN_WIDTH) - SCENE_EDITOR_LEFT_WIDTH - SCENE_EDITOR_RIGHT_WIDTH,
        f32(shared.SCENE_SCREEN_HEIGHT) - SCENE_EDITOR_TOP_HEIGHT,
    }
    target_aspect := f32(shared.SCENE_SCREEN_WIDTH) / f32(shared.SCENE_SCREEN_HEIGHT)
    width := available.width
    height := width / target_aspect
    if height > available.height {
        height = available.height
        width = height * target_aspect
    }
    return {
        available.x + (available.width - width) * 0.5,
        available.y + (available.height - height) * 0.5,
        width,
        height,
    }
}

scene_selection_valid :: proc(selection: Scene_Selection, scene: ^shared.Scene) -> bool {
    switch selection.kind {
    case .NONE:        return false
    case .MODEL:       return selection.index >= 0 && selection.index < len(scene.models)
    case .PRIMITIVE:   return selection.index >= 0 && selection.index < len(scene.primitives)
    case .POINT_LIGHT: return selection.index >= 0 && selection.index < len(scene.point_lights)
    case .SPOT_LIGHT:  return selection.index >= 0 && selection.index < len(scene.spot_lights)
    }
    return false
}

scene_selection_name :: proc(
    selection: Scene_Selection,
    scene: ^shared.Scene,
) -> string {
    if !scene_selection_valid(selection, scene) { return "" }
    switch selection.kind {
    case .NONE:
    case .MODEL:       return scene.models[selection.index].name
    case .PRIMITIVE:   return scene.primitives[selection.index].name
    case .POINT_LIGHT: return scene.point_lights[selection.index].name
    case .SPOT_LIGHT:  return scene.spot_lights[selection.index].name
    }
    return ""
}

scene_selection_id :: proc(
    selection: Scene_Selection,
    scene: ^shared.Scene,
) -> string {
    if !scene_selection_valid(selection, scene) { return "" }
    switch selection.kind {
    case .NONE:
    case .MODEL:       return scene.models[selection.index].id
    case .PRIMITIVE:   return scene.primitives[selection.index].id
    case .POINT_LIGHT: return scene.point_lights[selection.index].id
    case .SPOT_LIGHT:  return scene.spot_lights[selection.index].id
    }
    return ""
}

scene_set_selection_name :: proc(
    selection: Scene_Selection,
    scene: ^shared.Scene,
    name: string,
) -> bool {
    if !scene_selection_valid(selection, scene) || !shared.scene_name_is_valid(name) {
        return false
    }
    target: ^string
    switch selection.kind {
    case .NONE:
        return false
    case .MODEL:       target = &scene.models[selection.index].name
    case .PRIMITIVE:   target = &scene.primitives[selection.index].name
    case .POINT_LIGHT: target = &scene.point_lights[selection.index].name
    case .SPOT_LIGHT:  target = &scene.spot_lights[selection.index].name
    }
    replacement := strings.clone(name)
    delete(target^)
    target^ = replacement
    scene.dirty = true
    return true
}

scene_item_id_exists :: proc(scene: ^shared.Scene, id: string) -> bool {
    for item in scene.models do if item.id == id { return true }
    for item in scene.primitives do if item.id == id { return true }
    for item in scene.point_lights do if item.id == id { return true }
    for item in scene.spot_lights do if item.id == id { return true }
    return false
}

scene_item_count :: proc(scene: ^shared.Scene) -> int {
    return len(scene.models) + len(scene.primitives) +
           len(scene.point_lights) + len(scene.spot_lights)
}

// ID counters are deliberately absent from scene JSON. On first allocation
// after load, scan every item kind for the largest matching numeric suffix,
// then advance monotonically while still checking the global namespace.
scene_next_item_id :: proc(scene: ^shared.Scene, prefix: string) -> string {
    counter: ^int
    switch prefix {
    case "model":     counter = &scene.next_model_id
    case "primitive": counter = &scene.next_primitive_id
    case "point":     counter = &scene.next_point_id
    case "spot":      counter = &scene.next_spot_id
    case:
        return fmt.aprintf("%s_item", prefix)
    }
    if counter^ <= 0 {
        maximum_suffix := 0
        inspect_id :: proc(id, prefix: string, maximum: ^int) {
            marker_length := len(prefix) + 1
            if len(id) <= marker_length ||
               !strings.has_prefix(id, prefix) || id[len(prefix)] != '_' {
                return
            }
            suffix := 0
            for character in id[marker_length:] {
                if character < '0' || character > '9' { return }
                suffix = suffix * 10 + int(character - '0')
            }
            maximum^ = max(maximum^, suffix)
        }
        for item in scene.models do inspect_id(item.id, prefix, &maximum_suffix)
        for item in scene.primitives do inspect_id(item.id, prefix, &maximum_suffix)
        for item in scene.point_lights do inspect_id(item.id, prefix, &maximum_suffix)
        for item in scene.spot_lights do inspect_id(item.id, prefix, &maximum_suffix)
        counter^ = maximum_suffix + 1
    }
    for counter^ <= 999999 {
        suffix := counter^
        counter^ += 1
        candidate := fmt.aprintf("%s_%03d", prefix, suffix)
        if !scene_item_id_exists(scene, candidate) {
            return candidate
        }
        delete(candidate)
    }
    return fmt.aprintf("%s_item", prefix)
}

scene_add_primitive :: proc(
    scene: ^shared.Scene,
    shape: shared.Scene_Primitive_Shape,
) -> int {
    if scene_item_count(scene) >= shared.SCENE_MAX_ITEMS { return -1 }
    id := scene_next_item_id(scene, "primitive")
    name := strings.clone(shared.scene_primitive_shape_to_string(shape))
    if len(name) > 0 {
        mutable := transmute([]u8)name
        mutable[0] = shared.ascii_byte_to_lower(mutable[0]) - ('a' - 'A')
    }
    append(&scene.primitives, shared.Scene_Primitive{
        id = id,
        name = name,
        visible = true,
        shape = shape,
        transform = {
            position = scene.camera.target,
            scale = {1, 1, 1},
        },
        albedo = {210, 216, 230, 255},
    })
    scene.dirty = true
    return len(scene.primitives) - 1
}

scene_add_point_light :: proc(scene: ^shared.Scene) -> int {
    if scene_item_count(scene) >= shared.SCENE_MAX_ITEMS ||
       len(scene.point_lights) >= shared.SCENE_MAX_POINT_LIGHTS {
        return -1
    }
    append(&scene.point_lights, shared.Scene_Point_Light{
        id = scene_next_item_id(scene, "point"),
        name = strings.clone("Point Light"),
        enabled = true,
        position = scene.camera.target + rl.Vector3{0, 2, 0},
        color = {1, 0.82, 0.65},
        intensity = 1,
        range = 6,
    })
    scene.dirty = true
    return len(scene.point_lights) - 1
}

scene_add_spot_light :: proc(scene: ^shared.Scene) -> int {
    if scene_item_count(scene) >= shared.SCENE_MAX_ITEMS ||
       len(scene.spot_lights) >= shared.SCENE_MAX_SPOT_LIGHTS {
        return -1
    }
    direction := scene.camera.target - scene.camera.position
    append(&scene.spot_lights, shared.Scene_Spot_Light{
        id = scene_next_item_id(scene, "spot"),
        name = strings.clone("Spot Light"),
        enabled = true,
        position = scene.camera.position,
        direction = shared.scene_direction_normalize_stable(direction),
        color = {0.65, 0.78, 1},
        intensity = 1,
        range = 10,
        inner_angle_deg = 18,
        outer_angle_deg = 30,
    })
    scene.dirty = true
    return len(scene.spot_lights) - 1
}

// Stage the raylib resource before appending either array. Success preserves
// the invariant that scene.models[i] and resources.models[i] describe the same
// imported instance; failure leaves both active arrays unchanged.
scene_editor_add_model :: proc(
    scene: ^shared.Scene,
    resources: ^shared.Scene_Resources,
    source: string,
) -> bool {
    if scene_item_count(scene) >= shared.SCENE_MAX_ITEMS ||
       len(scene.models) >= shared.SCENE_MAX_MODELS ||
       !shared.scene_file_path_is_portable(source, os.ext(source)) ||
       !shared.scene_model_extension_is_supported(source) ||
       !os.is_file(source) {
        return false
    }
    display_name := filepath.base(source)
    model := shared.Scene_Model{
        id = scene_next_item_id(scene, "model"),
        name = strings.clone(display_name),
        visible = true,
        source = strings.clone(source),
        transform = {
            position = scene.camera.target,
            scale = {1, 1, 1},
        },
        tint = rl.WHITE,
    }
    resource, resource_error := shared.scene_model_resource_load(&model)
    if resource_error != .NONE {
        delete(model.id)
        delete(model.name)
        delete(model.source)
        return false
    }
    append(&scene.models, model)
    append(&resources.models, resource)
    scene.dirty = true
    return true
}

// Duplicates receive independent owned strings. Models additionally load an
// independent mutable raylib model because applying a fixed animation pose
// mutates mesh vertices and cannot be shared safely between instances.
scene_editor_duplicate_selection :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
    resources: ^shared.Scene_Resources,
) -> bool {
    selection := state.selection
    if !scene_selection_valid(selection, scene) ||
       scene_item_count(scene) >= shared.SCENE_MAX_ITEMS {
        return false
    }

    switch selection.kind {
    case .NONE:
        return false
    case .MODEL:
        if len(scene.models) >= shared.SCENE_MAX_MODELS { return false }
        source := &scene.models[selection.index]
        duplicate := source^
        duplicate.id = scene_next_item_id(scene, "model")
        duplicate.name = strings.clone(source.name)
        duplicate.source = strings.clone(source.source)
        resource, resource_error := shared.scene_model_resource_load(&duplicate)
        if resource_error != .NONE {
            delete(duplicate.id)
            delete(duplicate.name)
            delete(duplicate.source)
            return false
        }
        append(&scene.models, duplicate)
        append(&resources.models, resource)
        state.selection = {.MODEL, len(scene.models) - 1}
    case .PRIMITIVE:
        source := &scene.primitives[selection.index]
        duplicate := source^
        duplicate.id = scene_next_item_id(scene, "primitive")
        duplicate.name = strings.clone(source.name)
        append(&scene.primitives, duplicate)
        state.selection = {.PRIMITIVE, len(scene.primitives) - 1}
    case .POINT_LIGHT:
        if len(scene.point_lights) >= shared.SCENE_MAX_POINT_LIGHTS { return false }
        source := &scene.point_lights[selection.index]
        duplicate := source^
        duplicate.id = scene_next_item_id(scene, "point")
        duplicate.name = strings.clone(source.name)
        append(&scene.point_lights, duplicate)
        state.selection = {.POINT_LIGHT, len(scene.point_lights) - 1}
    case .SPOT_LIGHT:
        if len(scene.spot_lights) >= shared.SCENE_MAX_SPOT_LIGHTS { return false }
        source := &scene.spot_lights[selection.index]
        duplicate := source^
        duplicate.id = scene_next_item_id(scene, "spot")
        duplicate.name = strings.clone(source.name)
        append(&scene.spot_lights, duplicate)
        state.selection = {.SPOT_LIGHT, len(scene.spot_lights) - 1}
    }
    scene.dirty = true
    state.status = .ITEM_ADDED
    return true
}

// Ordered removal is required for models so the CPU description and GPU
// resource arrays keep matching indices after the selected resource is freed.
scene_editor_delete_selection :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
    resources: ^shared.Scene_Resources,
) -> bool {
    selection := state.selection
    if !scene_selection_valid(selection, scene) { return false }
    switch selection.kind {
    case .NONE:
    case .MODEL:
        item := &scene.models[selection.index]
        delete(item.id); delete(item.name); delete(item.source)
        shared.scene_model_resource_destroy(&resources.models[selection.index])
        ordered_remove(&scene.models, selection.index)
        ordered_remove(&resources.models, selection.index)
    case .PRIMITIVE:
        item := &scene.primitives[selection.index]
        delete(item.id); delete(item.name)
        ordered_remove(&scene.primitives, selection.index)
    case .POINT_LIGHT:
        item := &scene.point_lights[selection.index]
        delete(item.id); delete(item.name)
        ordered_remove(&scene.point_lights, selection.index)
    case .SPOT_LIGHT:
        item := &scene.spot_lights[selection.index]
        delete(item.id); delete(item.name)
        ordered_remove(&scene.spot_lights, selection.index)
    }
    state.selection = {.NONE, -1}
    state.hierarchy_active = -1
    scene.dirty = true
    state.status = .ITEM_DELETED
    return true
}

// Opening is an all-or-nothing replacement. Load and initialize the complete
// CPU scene, cel style, renderer, and asset set first; destroy the active graph
// only after every replacement component is valid.
scene_editor_open_path :: proc(
    path: string,
    scene: ^shared.Scene,
    style: ^shared.Cel_Style,
    renderer: ^shared.Scene_Renderer,
    resources: ^shared.Scene_Resources,
) -> bool {
    replacement_scene, scene_error := shared.scene_load(path)
    if scene_error != .NONE { return false }
    replacement_style, style_error := shared.cel_style_load(replacement_scene.style_path)
    if style_error != .NONE {
        shared.scene_destroy(&replacement_scene)
        return false
    }
    replacement_renderer: shared.Scene_Renderer
    if !shared.scene_renderer_init(
        &replacement_renderer,
        &replacement_style,
        replacement_scene.render.downscale_level,
    ) {
        shared.scene_renderer_destroy(&replacement_renderer)
        shared.cel_style_destroy(&replacement_style)
        shared.scene_destroy(&replacement_scene)
        return false
    }
    replacement_resources, resource_error := shared.scene_resources_load(&replacement_scene)
    if resource_error != .NONE {
        shared.scene_resources_destroy(&replacement_resources)
        shared.scene_renderer_destroy(&replacement_renderer)
        shared.cel_style_destroy(&replacement_style)
        shared.scene_destroy(&replacement_scene)
        return false
    }

    shared.scene_resources_destroy(resources)
    shared.scene_renderer_destroy(renderer)
    shared.cel_style_destroy(style)
    shared.scene_destroy(scene)
    scene^ = replacement_scene
    style^ = replacement_style
    renderer^ = replacement_renderer
    resources^ = replacement_resources
    return true
}

// New follows the same transactional path as Open so shader or asset failures
// cannot strand the editor without its previous valid scene and renderer.
scene_editor_new_default :: proc(
    scene: ^shared.Scene,
    style: ^shared.Cel_Style,
    renderer: ^shared.Scene_Renderer,
    resources: ^shared.Scene_Resources,
) -> bool {
    replacement_scene := shared.scene_make_default()
    replacement_scene.dirty = true
    replacement_style, style_error := shared.cel_style_load(replacement_scene.style_path)
    if style_error != .NONE {
        shared.scene_destroy(&replacement_scene)
        return false
    }
    replacement_renderer: shared.Scene_Renderer
    if !shared.scene_renderer_init(
        &replacement_renderer,
        &replacement_style,
        replacement_scene.render.downscale_level,
    ) {
        shared.scene_renderer_destroy(&replacement_renderer)
        shared.cel_style_destroy(&replacement_style)
        shared.scene_destroy(&replacement_scene)
        return false
    }
    replacement_resources, resource_error := shared.scene_resources_load(&replacement_scene)
    if resource_error != .NONE {
        shared.scene_resources_destroy(&replacement_resources)
        shared.scene_renderer_destroy(&replacement_renderer)
        shared.cel_style_destroy(&replacement_style)
        shared.scene_destroy(&replacement_scene)
        return false
    }

    shared.scene_resources_destroy(resources)
    shared.scene_renderer_destroy(renderer)
    shared.cel_style_destroy(style)
    shared.scene_destroy(scene)
    scene^ = replacement_scene
    style^ = replacement_style
    renderer^ = replacement_renderer
    resources^ = replacement_resources
    return true
}

// Convert coordinates from the letterboxed native viewport back to the fixed
// 1280x720 render space used to construct the ray. Test every visible mesh and
// light proxy, retaining the nearest world-space collision across item kinds.
scene_editor_pick :: proc(
    scene: ^shared.Scene,
    resources: ^shared.Scene_Resources,
    viewport: rl.Rectangle,
    mouse_position: rl.Vector2,
) -> Scene_Selection {
    internal_position := rl.Vector2{
        (mouse_position.x - viewport.x) / viewport.width * shared.SCENE_SCREEN_WIDTH,
        (mouse_position.y - viewport.y) / viewport.height * shared.SCENE_SCREEN_HEIGHT,
    }
    ray := rl.GetScreenToWorldRayEx(
        internal_position,
        shared.scene_camera_to_raylib_camera(scene.camera),
        shared.SCENE_SCREEN_WIDTH,
        shared.SCENE_SCREEN_HEIGHT,
    )
    closest_distance := f32(math.F32_MAX)
    result := Scene_Selection{.NONE, -1}
    for model_data, model_index in scene.models {
        if !model_data.visible || model_index >= len(resources.models) { continue }
        model := &resources.models[model_index].model
        transform := shared.scene_transform_matrix(model_data.transform) * model.transform
        for mesh_index := 0; mesh_index < int(model.meshCount); mesh_index += 1 {
            collision := rl.GetRayCollisionMesh(ray, model.meshes[mesh_index], transform)
            if collision.hit && collision.distance < closest_distance {
                closest_distance = collision.distance
                result = {.MODEL, model_index}
            }
        }
    }
    for primitive, primitive_index in scene.primitives {
        if !primitive.visible { continue }
        model := &resources.primitives[int(primitive.shape)]
        transform := shared.scene_transform_matrix(primitive.transform) *
                     shared.scene_primitive_local_transform(primitive.shape) *
                     model.transform
        for mesh_index := 0; mesh_index < int(model.meshCount); mesh_index += 1 {
            collision := rl.GetRayCollisionMesh(ray, model.meshes[mesh_index], transform)
            if collision.hit && collision.distance < closest_distance {
                closest_distance = collision.distance
                result = {.PRIMITIVE, primitive_index}
            }
        }
    }
    for light, light_index in scene.point_lights {
        collision := rl.GetRayCollisionSphere(ray, light.position, 0.25)
        if collision.hit && collision.distance < closest_distance {
            closest_distance = collision.distance
            result = {.POINT_LIGHT, light_index}
        }
    }
    for light, light_index in scene.spot_lights {
        collision := rl.GetRayCollisionSphere(ray, light.position, 0.25)
        if collision.hit && collision.distance < closest_distance {
            closest_distance = collision.distance
            result = {.SPOT_LIGHT, light_index}
        }
    }
    return result
}

SCENE_GIZMO_AXES := [3]rl.Vector3{
    {1, 0, 0},
    {0, 1, 0},
    {0, 0, 1},
}

SCENE_GIZMO_COLORS := [3]rl.Color{
    {235, 70, 70, 255},
    {80, 220, 100, 255},
    {80, 130, 245, 255},
}

scene_editor_selection_position :: proc(
    selection: Scene_Selection,
    scene: ^shared.Scene,
) -> (rl.Vector3, bool) {
    if !scene_selection_valid(selection, scene) { return {}, false }
    switch selection.kind {
    case .NONE:
    case .MODEL:       return scene.models[selection.index].transform.position, true
    case .PRIMITIVE:   return scene.primitives[selection.index].transform.position, true
    case .POINT_LIGHT: return scene.point_lights[selection.index].position, true
    case .SPOT_LIGHT:  return scene.spot_lights[selection.index].position, true
    }
    return {}, false
}

scene_editor_gizmo_mode_supported :: proc(
    selection: Scene_Selection,
    mode: Scene_Gizmo_Mode,
) -> bool {
    switch selection.kind {
    case .NONE:
        return false
    case .MODEL, .PRIMITIVE:
        return true
    case .POINT_LIGHT:
        return mode == .TRANSLATE
    case .SPOT_LIGHT:
        return mode == .TRANSLATE || mode == .ROTATE
    }
    return false
}

// Scale handles in world units to retain roughly constant on-screen size in
// either projection, while clamping extremes near and far from the camera.
scene_editor_gizmo_world_length :: proc(
    scene: ^shared.Scene,
    origin: rl.Vector3,
) -> f32 {
    if scene.camera.projection == .ORTHOGRAPHIC {
        return clamp(scene.camera.ortho_height * 0.12, f32(0.25), f32(12))
    }
    return clamp(
        rl.Vector3Distance(scene.camera.position, origin) * 0.12,
        f32(0.25),
        f32(12),
    )
}

scene_editor_distance_to_segment :: proc(
    point, start, finish: rl.Vector2,
) -> f32 {
    segment := finish - start
    segment_length_squared := rl.Vector2LengthSqr(segment)
    if segment_length_squared <= 0.0001 {
        return rl.Vector2Distance(point, start)
    }
    t := clamp(
        rl.Vector2DotProduct(point - start, segment) / segment_length_squared,
        f32(0),
        f32(1),
    )
    return rl.Vector2Distance(point, start + segment * t)
}

scene_editor_try_begin_gizmo :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
    viewport: rl.Rectangle,
    mouse: rl.Vector2,
) -> bool {
    origin, valid := scene_editor_selection_position(state.selection, scene)
    if !valid || !scene_editor_gizmo_mode_supported(state.selection, state.gizmo_mode) {
        return false
    }
    camera := shared.scene_camera_to_raylib_camera(scene.camera)
    screen_origin := scene_editor_world_to_viewport(origin, camera, viewport)
    world_length := scene_editor_gizmo_world_length(scene, origin)
    closest_axis := -1
    closest_distance := f32(10)
    for axis, axis_index in SCENE_GIZMO_AXES {
        screen_end := scene_editor_world_to_viewport(
            origin + axis * world_length,
            camera,
            viewport,
        )
        distance := scene_editor_distance_to_segment(
            mouse,
            screen_origin,
            screen_end,
        )
        if distance < closest_distance {
            closest_distance = distance
            closest_axis = axis_index
        }
    }
    if closest_axis < 0 { return false }
    state.gizmo_axis = closest_axis
    return true
}

// Project the selected world axis to screen space, then measure mouse movement
// along that projected axis. This avoids camera-angle-dependent sign changes
// and provides one scalar delta shared by translate, rotate, and scale modes.
scene_editor_apply_gizmo_drag :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
    viewport: rl.Rectangle,
) {
    if state.gizmo_axis < 0 || state.gizmo_axis >= len(SCENE_GIZMO_AXES) ||
       !scene_editor_gizmo_mode_supported(state.selection, state.gizmo_mode) {
        return
    }
    origin, valid := scene_editor_selection_position(state.selection, scene)
    if !valid { return }
    axis := SCENE_GIZMO_AXES[state.gizmo_axis]
    camera := shared.scene_camera_to_raylib_camera(scene.camera)
    world_length := scene_editor_gizmo_world_length(scene, origin)
    screen_origin := scene_editor_world_to_viewport(origin, camera, viewport)
    screen_end := scene_editor_world_to_viewport(
        origin + axis * world_length,
        camera,
        viewport,
    )
    screen_axis := screen_end - screen_origin
    screen_length := rl.Vector2Length(screen_axis)
    if screen_length <= 0.001 { return }
    pixel_delta := rl.Vector2DotProduct(
        rl.GetMouseDelta(),
        screen_axis / screen_length,
    )
    if math.abs(pixel_delta) <= 0.0001 { return }

    selection := state.selection
    switch state.gizmo_mode {
    case .TRANSLATE:
        world_delta := axis * (pixel_delta * world_length / screen_length)
        switch selection.kind {
        case .NONE:
        case .MODEL:       scene.models[selection.index].transform.position += world_delta
        case .PRIMITIVE:   scene.primitives[selection.index].transform.position += world_delta
        case .POINT_LIGHT: scene.point_lights[selection.index].position += world_delta
        case .SPOT_LIGHT:  scene.spot_lights[selection.index].position += world_delta
        }
    case .ROTATE:
        angle_degrees := pixel_delta * 0.8
        switch selection.kind {
        case .NONE, .POINT_LIGHT:
        case .MODEL:
            rotation := &scene.models[selection.index].transform.rotation_euler_deg
            rotation[state.gizmo_axis] += angle_degrees
        case .PRIMITIVE:
            rotation := &scene.primitives[selection.index].transform.rotation_euler_deg
            rotation[state.gizmo_axis] += angle_degrees
        case .SPOT_LIGHT:
            light := &scene.spot_lights[selection.index]
            light.direction = shared.scene_direction_normalize_stable(
                rl.Vector3RotateByAxisAngle(
                    light.direction,
                    axis,
                    angle_degrees * f32(math.PI / 180),
                ),
            )
        }
    case .SCALE:
        factor := math.pow(f32(1.01), pixel_delta)
        switch selection.kind {
        case .NONE, .POINT_LIGHT, .SPOT_LIGHT:
        case .MODEL:
            scale := &scene.models[selection.index].transform.scale
            scale[state.gizmo_axis] = clamp(
                scale[state.gizmo_axis] * factor,
                shared.SCENE_MIN_SCALE,
                shared.SCENE_MAX_SCALE,
            )
        case .PRIMITIVE:
            scale := &scene.primitives[selection.index].transform.scale
            scale[state.gizmo_axis] = clamp(
                scale[state.gizmo_axis] * factor,
                shared.SCENE_MIN_SCALE,
                shared.SCENE_MAX_SCALE,
            )
        }
    }
    scene.dirty = true
}

scene_editor_frame_selection :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
) {
    origin, valid := scene_editor_selection_position(state.selection, scene)
    if !valid { return }
    view_offset := scene.camera.position - scene.camera.target
    if !shared.scene_direction_is_valid(view_offset) { view_offset = {1, 0.6, 1} }
    distance: f32 = 4
    switch state.selection.kind {
    case .NONE, .POINT_LIGHT, .SPOT_LIGHT:
    case .MODEL:
        scale := scene.models[state.selection.index].transform.scale
        distance = max(scale.x, max(scale.y, scale.z)) * 3
    case .PRIMITIVE:
        scale := scene.primitives[state.selection.index].transform.scale
        distance = max(scale.x, max(scale.y, scale.z)) * 3
    }
    distance = clamp(distance, f32(1), f32(1000))
    scene.camera.target = origin
    scene.camera.position = origin + rl.Vector3Normalize(view_offset) * distance
    scene.dirty = true
}

// Viewport input has an explicit ownership order: active gizmo drag, camera
// navigation, then selection. Controls outside the letterboxed viewport return
// before any scene camera or selection mutation.
scene_editor_update_viewport_input :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
    resources: ^shared.Scene_Resources,
) {
    viewport := scene_editor_viewport_bounds()
    mouse := rl.GetMousePosition()
    if rl.IsMouseButtonReleased(.LEFT) {
        state.gizmo_axis = -1
    }
    if !state.scene_path_editing && !state.model_path_editing {
        if rl.IsKeyPressed(.W) { state.gizmo_mode = .TRANSLATE }
        if rl.IsKeyPressed(.E) { state.gizmo_mode = .ROTATE }
        if rl.IsKeyPressed(.R) { state.gizmo_mode = .SCALE }
        if rl.IsKeyPressed(.F) { scene_editor_frame_selection(state, scene) }
    }
    if !rl.CheckCollisionPointRec(mouse, viewport) { return }

    if rl.IsMouseButtonPressed(.LEFT) &&
       scene_editor_try_begin_gizmo(state, scene, viewport, mouse) {
        return
    }
    if state.gizmo_axis >= 0 && rl.IsMouseButtonDown(.LEFT) {
        scene_editor_apply_gizmo_drag(state, scene, viewport)
        return
    }

    camera := &scene.camera
    if rl.IsMouseButtonDown(.RIGHT) {
        delta := rl.GetMouseDelta()
        offset := camera.position - camera.target
        radius := max(rl.Vector3Length(offset), f32(0.01))
        azimuth := math.atan2(offset.z, offset.x) - delta.x * 0.006
        elevation := math.asin(clamp(offset.y / radius, f32(-1), f32(1))) +
                     delta.y * 0.006
        elevation = clamp(elevation, f32(-1.48), f32(1.48))
        horizontal := math.cos(elevation) * radius
        camera.position = camera.target + rl.Vector3{
            math.cos(azimuth) * horizontal,
            math.sin(elevation) * radius,
            math.sin(azimuth) * horizontal,
        }
        scene.dirty = true
    }
    if rl.IsMouseButtonDown(.MIDDLE) {
        delta := rl.GetMouseDelta()
        forward := rl.Vector3Normalize(camera.target - camera.position)
        right := rl.Vector3Normalize(rl.Vector3CrossProduct(forward, camera.up))
        up := rl.Vector3Normalize(rl.Vector3CrossProduct(right, forward))
        distance := max(rl.Vector3Length(camera.target - camera.position), f32(1))
        movement := right * (-delta.x * distance * 0.0015) +
                    up * (delta.y * distance * 0.0015)
        camera.position += movement
        camera.target += movement
        scene.dirty = true
    }
    wheel := rl.GetMouseWheelMove()
    if wheel != 0 {
        if camera.projection == .ORTHOGRAPHIC {
            camera.ortho_height = clamp(
                camera.ortho_height * math.pow(f32(0.9), wheel),
                shared.SCENE_MIN_SCALE,
                shared.SCENE_MAX_POSITION,
            )
        } else {
            forward := rl.Vector3Normalize(camera.target - camera.position)
            distance := rl.Vector3Length(camera.target - camera.position)
            step := min(distance * 0.12, f32(10)) * wheel
            if distance - step > 0.05 {
                camera.position += forward * step
            }
        }
        scene.dirty = true
    }
    if rl.IsMouseButtonPressed(.LEFT) {
        state.selection = scene_editor_pick(scene, resources, viewport, mouse)
    }
}

scene_gui_scaled_spinner :: proc(
    bounds: rl.Rectangle,
    label: cstring,
    value: ^f32,
    minimum, maximum, scale: f32,
) -> bool {
    scaled := c.int(math.round(value^ * scale))
    previous := scaled
    _ = rl.GuiSpinner(
        bounds,
        label,
        &scaled,
        c.int(math.round(minimum * scale)),
        c.int(math.round(maximum * scale)),
        false,
    )
    if scaled == previous { return false }
    value^ = f32(scaled) / scale
    return true
}

scene_gui_vector3 :: proc(
    x, y: f32,
    width: f32,
    value: ^rl.Vector3,
    minimum, maximum, scale: f32,
) -> bool {
    gap: f32 = 4
    component_width := (width - gap * 2) / 3
    changed := scene_gui_scaled_spinner({x, y, component_width, 22}, "X", &value.x, minimum, maximum, scale)
    changed = scene_gui_scaled_spinner({x + component_width + gap, y, component_width, 22}, "Y", &value.y, minimum, maximum, scale) || changed
    changed = scene_gui_scaled_spinner({x + (component_width + gap) * 2, y, component_width, 22}, "Z", &value.z, minimum, maximum, scale) || changed
    return changed
}

scene_gui_color3 :: proc(
    x, y, width: f32,
    value: ^rl.Vector3,
) -> bool {
    return scene_gui_vector3(x, y, width, value, 0, 1, 100)
}

scene_gui_color8 :: proc(
    x, y, width: f32,
    value: ^rl.Color,
) -> bool {
    normalized := rl.Vector3{
        f32(value.r) / 255,
        f32(value.g) / 255,
        f32(value.b) / 255,
    }
    if !scene_gui_color3(x, y, width, &normalized) {
        return false
    }
    value.r = u8(math.round(clamp(normalized.x, f32(0), f32(1)) * 255))
    value.g = u8(math.round(clamp(normalized.y, f32(0), f32(1)) * 255))
    value.b = u8(math.round(clamp(normalized.z, f32(0), f32(1)) * 255))
    return true
}

scene_gui_transform :: proc(
    x: f32,
    y: ^f32,
    width: f32,
    transform: ^shared.Scene_Transform,
) -> bool {
    changed := false
    rl.GuiLabel({x, y^, width, 18}, "Position")
    y^ += 19
    changed = scene_gui_vector3(x, y^, width, &transform.position, -10000, 10000, 100) || changed
    y^ += 27
    rl.GuiLabel({x, y^, width, 18}, "Rotation XYZ degrees")
    y^ += 19
    changed = scene_gui_vector3(x, y^, width, &transform.rotation_euler_deg, -180, 180, 10) || changed
    y^ += 27
    rl.GuiLabel({x, y^, width, 18}, "Scale")
    y^ += 19
    changed = scene_gui_vector3(x, y^, width, &transform.scale, shared.SCENE_MIN_SCALE, 100, 100) || changed
    y^ += 29
    return changed
}

scene_editor_draw_hierarchy :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
    resources: ^shared.Scene_Resources,
) {
    x: f32 = 8
    width := SCENE_EDITOR_LEFT_WIDTH - 16
    rl.GuiPanel({0, SCENE_EDITOR_TOP_HEIGHT, SCENE_EDITOR_LEFT_WIDTH, shared.SCENE_SCREEN_HEIGHT - SCENE_EDITOR_TOP_HEIGHT}, "HIERARCHY")

    labels := make([dynamic]cstring, 0, shared.SCENE_MAX_ITEMS, context.temp_allocator)
    references := make([dynamic]Scene_Selection, 0, shared.SCENE_MAX_ITEMS, context.temp_allocator)
    active: c.int = -1
    append_item :: proc(
        label_prefix: string,
        name: string,
        selection: Scene_Selection,
        labels: ^[dynamic]cstring,
        references: ^[dynamic]Scene_Selection,
        active: ^c.int,
        current: Scene_Selection,
    ) {
        label := fmt.tprintf("%s  %s", label_prefix, name)
        append(labels, strings.clone_to_cstring(label, context.temp_allocator))
        append(references, selection)
        if selection == current { active^ = c.int(len(labels^) - 1) }
    }
    for item, index in scene.models {
        append_item("M", item.name, {.MODEL, index}, &labels, &references, &active, state.selection)
    }
    for item, index in scene.primitives {
        append_item("P", item.name, {.PRIMITIVE, index}, &labels, &references, &active, state.selection)
    }
    for item, index in scene.point_lights {
        append_item("L", item.name, {.POINT_LIGHT, index}, &labels, &references, &active, state.selection)
    }
    for item, index in scene.spot_lights {
        append_item("S", item.name, {.SPOT_LIGHT, index}, &labels, &references, &active, state.selection)
    }
    state.hierarchy_active = active
    list_y := SCENE_EDITOR_TOP_HEIGHT + 28
    list_height: f32 = 300
    if len(labels) > 0 {
        _ = rl.GuiListViewEx(
            {x, list_y, width, list_height},
            raw_data(labels[:]),
            c.int(len(labels)),
            &state.hierarchy_scroll,
            &state.hierarchy_active,
            &state.hierarchy_focus,
        )
        if state.hierarchy_active >= 0 && int(state.hierarchy_active) < len(references) {
            state.selection = references[state.hierarchy_active]
        }
    } else {
        rl.GuiLabel({x + 8, list_y + 8, width - 16, 22}, "shared.Scene is empty")
    }

    add_y := list_y + list_height + 10
    if rl.GuiComboBox(
        {x, add_y, width - 72, 24},
        "Cube;Sphere;Plane;Triangle;Cylinder;Cone;Torus",
        &state.primitive_shape,
    ) != 0 {}
    if rl.GuiButton({x + width - 68, add_y, 68, 24}, "Add") {
        index := scene_add_primitive(scene, shared.Scene_Primitive_Shape(state.primitive_shape))
        if index >= 0 {
            state.selection = {.PRIMITIVE, index}
            state.status = .ITEM_ADDED
        }
    }
    add_y += 30
    if rl.GuiButton({x, add_y, (width - 6) * 0.5, 24}, "+ Point") &&
       len(scene.point_lights) < shared.SCENE_MAX_POINT_LIGHTS {
        index := scene_add_point_light(scene)
        if index >= 0 {
            state.selection = {.POINT_LIGHT, index}
            state.status = .ITEM_ADDED
        }
    }
    if rl.GuiButton({x + (width + 6) * 0.5, add_y, (width - 6) * 0.5, 24}, "+ Spot") &&
       len(scene.spot_lights) < shared.SCENE_MAX_SPOT_LIGHTS {
        index := scene_add_spot_light(scene)
        if index >= 0 {
            state.selection = {.SPOT_LIGHT, index}
            state.status = .ITEM_ADDED
        }
    }
    add_y += 34
    rl.GuiLabel({x, add_y, width, 18}, "Model path")
    add_y += 19
    if rl.GuiTextBox(
        {x, add_y, width, 24},
        cstring(&state.model_path[0]),
        SCENE_EDITOR_MODEL_PATH_CAPACITY,
        state.model_path_editing,
    ) {
        state.model_path_editing = !state.model_path_editing
    }
    add_y += 29
    if rl.GuiButton({x, add_y, width, 24}, "Add Model") {
        if scene_editor_add_model(
            scene,
            resources,
            scene_ui_buffer_string(state.model_path[:]),
        ) {
            state.selection = {.MODEL, len(scene.models) - 1}
            state.status = .MODEL_ADDED
        } else {
            state.status = .MODEL_ADD_FAILED
        }
    }
    add_y += 30
    if rl.GuiButton({x, add_y, width, 24}, "Delete Selected") {
        if scene_selection_valid(state.selection, scene) {
            state.pending_action = .DELETE
        }
    }
    add_y += 30
    if rl.GuiButton({x, add_y, width, 24}, "Duplicate Selected") {
        _ = scene_editor_duplicate_selection(state, scene, resources)
    }
}

scene_editor_draw_camera :: proc(scene: ^shared.Scene, x: f32, y: ^f32, width: f32) {
    rl.GuiLine({x, y^, width, 18}, "CAMERA")
    y^ += 20
    projection := c.int(scene.camera.projection)
    previous_projection := projection
    _ = rl.GuiComboBox({x, y^, width, 22}, "Perspective;Orthographic", &projection)
    if projection != previous_projection {
        scene.camera.projection = shared.Scene_Projection(projection)
        scene.dirty = true
    }
    y^ += 27
    rl.GuiLabel({x, y^, width, 18}, "Position")
    y^ += 18
    previous_camera := scene.camera
    if scene_gui_vector3(x, y^, width, &scene.camera.position, -10000, 10000, 100) {
        if shared.scene_camera_is_valid(scene.camera) {
            scene.dirty = true
        } else {
            scene.camera = previous_camera
        }
    }
    y^ += 26
    rl.GuiLabel({x, y^, width, 18}, "Target")
    y^ += 18
    previous_camera = scene.camera
    if scene_gui_vector3(x, y^, width, &scene.camera.target, -10000, 10000, 100) {
        if shared.scene_camera_is_valid(scene.camera) {
            scene.dirty = true
        } else {
            scene.camera = previous_camera
        }
    }
    y^ += 27
    rl.GuiLabel({x, y^, width, 18}, "Up")
    y^ += 18
    previous_camera = scene.camera
    if scene_gui_vector3(x, y^, width, &scene.camera.up, -1, 1, 100) {
        if shared.scene_camera_is_valid(scene.camera) {
            scene.dirty = true
        } else {
            scene.camera = previous_camera
        }
    }
    y^ += 27
    if scene.camera.projection == .PERSPECTIVE {
        if scene_gui_scaled_spinner({x, y^, width, 22}, "FOV", &scene.camera.vertical_fov_deg, 1, 179, 10) {
            scene.dirty = true
        }
    } else if scene_gui_scaled_spinner({x, y^, width, 22}, "Height", &scene.camera.ortho_height, 0.1, 1000, 10) {
        scene.dirty = true
    }
    y^ += 29

    rl.GuiLine({x, y^, width, 18}, "RENDER")
    y^ += 20
    rl.GuiLabel({x, y^, width, 18}, "Background RGB")
    y^ += 18
    if scene_gui_color8(x, y^, width, &scene.render.background) {
        scene.dirty = true
    }
    y^ += 27
    alpha := c.int(scene.render.background.a)
    previous_alpha := alpha
    _ = rl.GuiSpinner({x, y^, width, 22}, "Alpha", &alpha, 0, 255, false)
    if alpha != previous_alpha {
        scene.render.background.a = u8(alpha)
        scene.dirty = true
    }
    y^ += 27
    downscale := c.int(scene.render.downscale_level)
    previous_downscale := downscale
    _ = rl.GuiSpinner(
        {x, y^, width, 22},
        "Downscale",
        &downscale,
        MIN_DOWNSCALE_LEVEL,
        MAX_DOWNSCALE_LEVEL,
        false,
    )
    if downscale != previous_downscale {
        scene.render.downscale_level = int(downscale)
        scene.dirty = true
    }
    y^ += 27
    edge_aa := c.int(scene.render.edge_aa)
    previous_edge_aa := edge_aa
    _ = rl.GuiComboBox({x, y^, width, 22}, "Hard;Coverage", &edge_aa)
    if edge_aa != previous_edge_aa {
        scene.render.edge_aa = shared.Edge_AA_Mode(edge_aa)
        scene.dirty = true
    }
    y^ += 29
}

scene_editor_draw_selection_inspector :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
    resources: ^shared.Scene_Resources,
    x: f32,
    y: ^f32,
    width: f32,
) {
    rl.GuiLine({x, y^, width, 18}, "SELECTION")
    y^ += 20
    if !scene_selection_valid(state.selection, scene) {
        rl.GuiLabel({x, y^, width, 20}, "Select an item in the viewport or hierarchy")
        y^ += 24
        return
    }
    selection := state.selection
    if state.item_name_target != selection {
        state.item_name_target = selection
        state.item_name_editing = false
        scene_ui_buffer_set(
            state.item_name[:],
            scene_selection_name(selection, scene),
        )
    }
    id_label := fmt.tprintf("ID  %s", scene_selection_id(selection, scene))
    rl.GuiLabel(
        {x, y^, width, 18},
        strings.clone_to_cstring(id_label, context.temp_allocator),
    )
    y^ += 18
    was_name_editing := state.item_name_editing
    if rl.GuiTextBox(
        {x, y^, width, 24},
        cstring(&state.item_name[0]),
        SCENE_EDITOR_NAME_CAPACITY,
        state.item_name_editing,
    ) {
        state.item_name_editing = !state.item_name_editing
    }
    if was_name_editing && !state.item_name_editing {
        edited_name := scene_ui_buffer_string(state.item_name[:])
        if !scene_set_selection_name(selection, scene, edited_name) {
            scene_ui_buffer_set(
                state.item_name[:],
                scene_selection_name(selection, scene),
            )
        }
    }
    y^ += 29
    switch selection.kind {
    case .NONE:
    case .MODEL:
        item := &scene.models[selection.index]
        previous_visible := item.visible
        _ = rl.GuiCheckBox({x, y^, 20, 20}, "Visible", &item.visible)
        if previous_visible != item.visible { scene.dirty = true }
        y^ += 25
        if scene_gui_transform(x, y, width, &item.transform) { scene.dirty = true }
        rl.GuiLabel({x, y^, width, 18}, "Tint RGB")
        y^ += 18
        if scene_gui_color8(x, y^, width, &item.tint) { scene.dirty = true }
        y^ += 27
        if pose, present := item.animation.?; present && selection.index < len(resources.models) {
            resource := &resources.models[selection.index]
            clip := c.int(pose.clip_index)
            frame := c.int(pose.frame)
            previous_clip, previous_frame := clip, frame
            _ = rl.GuiSpinner({x, y^, width * 0.48, 22}, "Clip", &clip, 0, max(resource.playback.animation_count - 1, 0), false)
            _ = rl.GuiSpinner({x + width * 0.52, y^, width * 0.48, 22}, "Frame", &frame, 0, 100000, false)
            if clip != previous_clip || frame != previous_frame {
                clip_index := int(clip)
                if resource.playback.animations != nil && clip_index >= 0 &&
                   clip_index < int(resource.playback.animation_count) {
                    animation := resource.playback.animations[clip_index]
                    if frame >= 0 && frame < animation.keyframeCount &&
                       rl.IsModelAnimationValid(resource.model, animation) {
                        item.animation = shared.Scene_Animation_Pose{clip_index, int(frame)}
                        rl.UpdateModelAnimation(resource.model, animation, f32(frame))
                        scene.dirty = true
                    }
                }
            }
            y^ += 28
        } else if selection.index < len(resources.models) &&
                  rl.GuiButton({x, y^, width, 22}, "Enable Fixed Animation Pose") {
            resource := &resources.models[selection.index]
            shared.animation_playback_destroy(&resource.playback)
            resource.playback = shared.animation_playback_load(
                resource.model,
                item.source,
                .ASSET,
            )
            if len(resource.playback.valid_indices) > 0 {
                raw_clip_index := int(resource.playback.valid_indices[0])
                item.animation = shared.Scene_Animation_Pose{
                    clip_index = raw_clip_index,
                    frame = 0,
                }
                scene.dirty = true
            }
            y^ += 28
        }
    case .PRIMITIVE:
        item := &scene.primitives[selection.index]
        previous_visible := item.visible
        _ = rl.GuiCheckBox({x, y^, 20, 20}, "Visible", &item.visible)
        if previous_visible != item.visible { scene.dirty = true }
        y^ += 25
        if scene_gui_transform(x, y, width, &item.transform) { scene.dirty = true }
        rl.GuiLabel({x, y^, width, 18}, "Albedo RGB")
        y^ += 18
        if scene_gui_color8(x, y^, width, &item.albedo) { scene.dirty = true }
        y^ += 27
    case .POINT_LIGHT:
        item := &scene.point_lights[selection.index]
        previous_enabled := item.enabled
        _ = rl.GuiCheckBox({x, y^, 20, 20}, "Enabled", &item.enabled)
        if previous_enabled != item.enabled { scene.dirty = true }
        y^ += 24
        rl.GuiLabel({x, y^, width, 18}, "Position")
        y^ += 18
        if scene_gui_vector3(x, y^, width, &item.position, -10000, 10000, 100) { scene.dirty = true }
        y^ += 27
        rl.GuiLabel({x, y^, width, 18}, "Color RGB")
        y^ += 18
        if scene_gui_color3(x, y^, width, &item.color) { scene.dirty = true }
        y^ += 27
        if scene_gui_scaled_spinner({x, y^, width, 22}, "Intensity", &item.intensity, 0, 16, 100) { scene.dirty = true }
        y^ += 27
        if scene_gui_scaled_spinner({x, y^, width, 22}, "Range", &item.range, 0.01, 1000, 100) { scene.dirty = true }
        y^ += 28
    case .SPOT_LIGHT:
        item := &scene.spot_lights[selection.index]
        previous_enabled := item.enabled
        _ = rl.GuiCheckBox({x, y^, 20, 20}, "Enabled", &item.enabled)
        if previous_enabled != item.enabled { scene.dirty = true }
        y^ += 24
        rl.GuiLabel({x, y^, width, 18}, "Position")
        y^ += 18
        if scene_gui_vector3(x, y^, width, &item.position, -10000, 10000, 100) { scene.dirty = true }
        y^ += 27
        rl.GuiLabel({x, y^, width, 18}, "Direction")
        y^ += 18
        previous_direction := item.direction
        if scene_gui_vector3(x, y^, width, &item.direction, -1, 1, 100) {
            if shared.scene_direction_is_valid(item.direction) {
                item.direction = shared.scene_direction_normalize_stable(item.direction)
                scene.dirty = true
            } else {
                item.direction = previous_direction
            }
        }
        y^ += 27
        rl.GuiLabel({x, y^, width, 18}, "Color RGB")
        y^ += 18
        if scene_gui_color3(x, y^, width, &item.color) { scene.dirty = true }
        y^ += 27
        if scene_gui_scaled_spinner({x, y^, width * 0.48, 22}, "Intensity", &item.intensity, 0, 16, 100) { scene.dirty = true }
        if scene_gui_scaled_spinner({x + width * 0.52, y^, width * 0.48, 22}, "Range", &item.range, 0.01, 1000, 100) { scene.dirty = true }
        y^ += 27
        if scene_gui_scaled_spinner({x, y^, width * 0.48, 22}, "Inner", &item.inner_angle_deg, 0, 88, 10) { scene.dirty = true }
        if scene_gui_scaled_spinner({x + width * 0.52, y^, width * 0.48, 22}, "Outer", &item.outer_angle_deg, 1, 89, 10) { scene.dirty = true }
        if item.inner_angle_deg >= item.outer_angle_deg {
            item.inner_angle_deg = max(item.outer_angle_deg - 0.1, f32(0))
        }
        y^ += 28
    }
}

scene_editor_draw_directional_light :: proc(scene: ^shared.Scene, bounds: rl.Rectangle) {
    rl.GuiPanel(bounds, "GLOBAL DIRECTIONAL LIGHT")
    x := bounds.x + 10
    y := bounds.y + 28
    width := bounds.width - 20
    light := &scene.directional_light
    previous_enabled := light.enabled
    _ = rl.GuiCheckBox({x, y, 20, 20}, "Enabled", &light.enabled)
    if previous_enabled != light.enabled { scene.dirty = true }
    y += 25

    direction := shared.scene_direction_normalize_stable(light.direction)
    radians_to_degrees :: f32(180 / math.PI)
    degrees_to_radians :: f32(math.PI / 180)
    azimuth := math.atan2(direction.z, direction.x) * radians_to_degrees
    elevation := math.asin(clamp(direction.y, f32(-1), f32(1))) * radians_to_degrees
    azimuth_changed := scene_gui_scaled_spinner({x, y, width, 22}, "Azimuth", &azimuth, -180, 180, 10)
    y += 27
    elevation_changed := scene_gui_scaled_spinner({x, y, width, 22}, "Elevation", &elevation, -89, 89, 10)
    if azimuth_changed || elevation_changed {
        azimuth_radians := azimuth * degrees_to_radians
        elevation_radians := elevation * degrees_to_radians
        horizontal := math.cos(elevation_radians)
        light.direction = {
            horizontal * math.cos(azimuth_radians),
            math.sin(elevation_radians),
            horizontal * math.sin(azimuth_radians),
        }
        scene.dirty = true
    }
    y += 27
    if scene_gui_scaled_spinner({x, y, width, 22}, "Intensity", &light.intensity, 0, 16, 100) {
        scene.dirty = true
    }
    y += 27
    rl.GuiLabel({x, y, width, 18}, "Color RGB")
    y += 18
    if scene_gui_color3(x, y, width, &light.color) { scene.dirty = true }
    y += 29
    previous_casts_shadows := light.casts_shadows
    _ = rl.GuiCheckBox(
        {x, y, 20, 20},
        "Pixel Hard Shadows",
        &light.casts_shadows,
    )
    if previous_casts_shadows != light.casts_shadows { scene.dirty = true }
    y += 25
    if scene_gui_scaled_spinner(
        {x, y, width * 0.48, 22},
        "Strength",
        &light.shadow_strength,
        shared.SCENE_MIN_SHADOW_STRENGTH,
        shared.SCENE_MAX_SHADOW_STRENGTH,
        100,
    ) {
        scene.dirty = true
    }
    if scene_gui_scaled_spinner(
        {x + width * 0.52, y, width * 0.48, 22},
        "Extent",
        &light.shadow_extent,
        shared.SCENE_MIN_SHADOW_EXTENT,
        shared.SCENE_MAX_SHADOW_EXTENT,
        10,
    ) {
        scene.dirty = true
    }
    y += 27
    if scene_gui_scaled_spinner(
        {x, y, width, 22},
        "Bias x100k",
        &light.shadow_bias,
        shared.SCENE_MIN_SHADOW_BIAS,
        shared.SCENE_MAX_SHADOW_BIAS,
        100000,
    ) {
        scene.dirty = true
    }
    y += 29
    if rl.GuiButton({x, y, width, 22}, "Reset Direction") {
        light.direction = shared.scene_direction_normalize_stable({0.35, 0.8, 0.55})
        scene.dirty = true
    }
}

scene_editor_world_to_viewport :: proc(
    position: rl.Vector3,
    camera: rl.Camera3D,
    viewport: rl.Rectangle,
) -> rl.Vector2 {
    internal := rl.GetWorldToScreenEx(
        position,
        camera,
        shared.SCENE_SCREEN_WIDTH,
        shared.SCENE_SCREEN_HEIGHT,
    )
    return {
        viewport.x + internal.x / shared.SCENE_SCREEN_WIDTH * viewport.width,
        viewport.y + internal.y / shared.SCENE_SCREEN_HEIGHT * viewport.height,
    }
}

// Overlays are drawn onto the native window after the deterministic composite
// texture. Selection rings, light markers, and gizmos therefore never enter a
// shared.Scene capture or alter its regression bytes.
scene_editor_draw_overlays :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
    viewport: rl.Rectangle,
) {
    camera := shared.scene_camera_to_raylib_camera(scene.camera)
    for light in scene.point_lights {
        position := scene_editor_world_to_viewport(light.position, camera, viewport)
        rl.DrawCircleV(position, 6, {255, 211, 88, 230})
        rl.DrawCircleLines(c.int(position.x), c.int(position.y), 8, {255, 245, 190, 230})
    }
    for light in scene.spot_lights {
        position := scene_editor_world_to_viewport(light.position, camera, viewport)
        target := scene_editor_world_to_viewport(light.position + light.direction, camera, viewport)
        rl.DrawCircleV(position, 6, {98, 190, 255, 230})
        rl.DrawLineV(position, target, {98, 190, 255, 220})
    }
    if world_position, valid := scene_editor_selection_position(
        state.selection,
        scene,
    ); valid {
        position := scene_editor_world_to_viewport(world_position, camera, viewport)
        rl.DrawCircleLines(c.int(position.x), c.int(position.y), 13, {255, 255, 255, 255})
        if scene_editor_gizmo_mode_supported(state.selection, state.gizmo_mode) {
            world_length := scene_editor_gizmo_world_length(scene, world_position)
            for axis, axis_index in SCENE_GIZMO_AXES {
                endpoint := scene_editor_world_to_viewport(
                    world_position + axis * world_length,
                    camera,
                    viewport,
                )
                color := SCENE_GIZMO_COLORS[axis_index]
                thickness: f32 = 3
                radius: f32 = 4
                if state.gizmo_axis == axis_index {
                    thickness = 5
                    radius = 6
                }
                rl.DrawLineEx(position, endpoint, thickness, color)
                rl.DrawCircleV(endpoint, radius, color)
            }
        }
    }
}

// Compose the captured texture, editor chrome, and at most one modal. GuiLock
// prevents background widgets from mutating the scene while a confirmation or
// Save As dialog owns input.
scene_editor_draw_ui :: proc(
    state: ^Scene_Editor_UI_State,
    scene: ^shared.Scene,
    style: ^shared.Cel_Style,
    renderer: ^shared.Scene_Renderer,
    resources: ^shared.Scene_Resources,
) {
    viewport := scene_editor_viewport_bounds()
    modal_active := state.save_as_open || state.pending_action != .NONE
    if modal_active { rl.GuiLock() }
    rl.ClearBackground({14, 16, 22, 255})
    rl.DrawTexturePro(
        renderer.composite_target.texture,
        {0, 0, shared.SCENE_SCREEN_WIDTH, -shared.SCENE_SCREEN_HEIGHT},
        viewport,
        {},
        0,
        rl.WHITE,
    )
    rl.DrawRectangleLinesEx(viewport, 1, {82, 88, 108, 255})
    scene_editor_draw_overlays(state, scene, viewport)
    gizmo_label: cstring = "W  TRANSLATE"
    if state.gizmo_mode == .ROTATE { gizmo_label = "E  ROTATE" }
    if state.gizmo_mode == .SCALE { gizmo_label = "R  SCALE" }
    rl.GuiLabel(
        {viewport.x + 8, viewport.y + viewport.height - 26, 130, 20},
        gizmo_label,
    )

    rl.GuiPanel({0, 0, shared.SCENE_SCREEN_WIDTH, SCENE_EDITOR_TOP_HEIGHT}, nil)
    dirty_label: cstring = "SCENE EDITOR"
    if scene.dirty { dirty_label = "SCENE EDITOR  *" }
    rl.GuiLabel({10, 8, 106, 24}, dirty_label)
    if rl.GuiTextBox(
        {120, 8, 420, 24},
        cstring(&state.scene_path[0]),
        SCENE_EDITOR_PATH_CAPACITY,
        state.scene_path_editing,
    ) {
        state.scene_path_editing = !state.scene_path_editing
    }
    if rl.GuiButton({548, 8, 52, 24}, "New") {
        if scene.dirty {
            state.pending_action = .NEW
        } else {
            state.new_requested = true
        }
    }
    if rl.GuiButton({606, 8, 52, 24}, "Open") {
        if scene.dirty {
            state.pending_action = .OPEN
        } else {
            state.load_requested = true
        }
    }
    if rl.GuiButton({664, 8, 52, 24}, "Save") {
        save_error := shared.scene_save(scene_ui_buffer_string(state.scene_path[:]), scene)
        if save_error == .NONE {
            scene.dirty = false
            state.status = .SAVED
        } else {
            state.status = .SAVE_FAILED
        }
    }
    if rl.GuiButton({722, 8, 72, 24}, "Save As") {
        scene_editor_request_save_as(state)
    }
    rl.GuiLabel({804, 8, 466, 24}, scene_ui_status_text(state.status))

    scene_editor_draw_hierarchy(state, scene, resources)

    right_x := f32(shared.SCENE_SCREEN_WIDTH) - SCENE_EDITOR_RIGHT_WIDTH
    directional_height: f32 = 300
    inspector_height := f32(shared.SCENE_SCREEN_HEIGHT) - SCENE_EDITOR_TOP_HEIGHT - directional_height
    rl.GuiPanel({right_x, SCENE_EDITOR_TOP_HEIGHT, SCENE_EDITOR_RIGHT_WIDTH, inspector_height}, "INSPECTOR")
    content_x := right_x + 10
    content_width := SCENE_EDITOR_RIGHT_WIDTH - 20
    content_y := SCENE_EDITOR_TOP_HEIGHT + 28
    if scene_selection_valid(state.selection, scene) {
        scene_editor_draw_selection_inspector(state, scene, resources, content_x, &content_y, content_width)
    } else {
        scene_editor_draw_camera(scene, content_x, &content_y, content_width)
        scene_editor_draw_selection_inspector(state, scene, resources, content_x, &content_y, content_width)
    }
    scene_editor_draw_directional_light(
        scene,
        {right_x, shared.SCENE_SCREEN_HEIGHT - directional_height, SCENE_EDITOR_RIGHT_WIDTH, directional_height},
    )

    if modal_active { rl.GuiUnlock() }
    if state.save_as_open {
        result := rl.GuiTextInputBox(
            {430, 245, 420, 190},
            "SAVE SCENE AS",
            "Repository-relative .json path",
            "Save;Cancel",
            cstring(&state.save_as_path[0]),
            SCENE_EDITOR_PATH_CAPACITY,
            &state.save_as_secret,
        )
        if result == 1 {
            path := scene_ui_buffer_string(state.save_as_path[:])
            save_error := shared.scene_save(path, scene)
            if save_error == .NONE {
                scene_ui_buffer_set(state.scene_path[:], path)
                scene.dirty = false
                state.status = .SAVED
                state.save_as_open = false
            } else {
                state.status = .SAVE_FAILED
            }
        } else if result == 2 || result == -1 {
            state.save_as_open = false
        }
    } else if state.pending_action == .DELETE {
        result := rl.GuiMessageBox(
            {450, 270, 380, 150},
            "DELETE ITEM",
            "Delete the selected item?",
            "Delete;Cancel",
        )
        if result == 1 {
            _ = scene_editor_delete_selection(state, scene, resources)
            state.pending_action = .NONE
        } else if result == 2 || result == -1 {
            state.pending_action = .NONE
        }
    } else if state.pending_action != .NONE {
        result := rl.GuiMessageBox(
            {430, 245, 420, 190},
            "UNSAVED CHANGES",
            "Save the current scene before continuing?",
            "Save;Discard;Cancel",
        )
        if result == 1 {
            save_error := shared.scene_save(
                scene_ui_buffer_string(state.scene_path[:]),
                scene,
            )
            if save_error == .NONE {
                scene.dirty = false
                state.status = .SAVED
                scene_editor_complete_pending_action(state)
            } else {
                state.status = .SAVE_FAILED
            }
        } else if result == 2 {
            scene_editor_complete_pending_action(state)
        } else if result == 3 || result == -1 {
            state.pending_action = .NONE
        }
    }
}
