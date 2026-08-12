package main

import "core:fmt"
import "core:os"
import "core:time"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
import rgl "vendor:raylib/rlgl"
// import cgltf "vendor:cgltf"

Vertex :: struct {
    pos: [3]f32,
    color: [4]f32,
}

VS_PATH             :: "shaders/custom.vs"
FS_PATH             :: "shaders/custom.fs"
DOWNSCALE_FS_PATH   :: "shaders/downscale.fs"
MASK_FS_PATH        :: "shaders/mask.fs"
MASK_DOWNSCALE_FS_PATH :: "shaders/mask_downscale.fs"
ASSETS_PATH         :: "assets"
DEFAULT_MODEL_PATH  :: "assets/CesiumMan.glb"

PIXEL_SCALE :: 10
LENS_WIDTH  :: 400
LENS_HEIGHT :: 400

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

// inspect_glb :: proc(path: string) -> bool {
//     options := cgltf.options{}
//     path_cstr := strings.clone_to_cstring(path, context.temp_allocator);

//     data, parse_result := cgltf.parse_file(options, path_cstr);
//     if parse_result != .success {
//         log.error("Failed to parse GLB file: ", path);
//         return false;
//     }
//     defer cgltf.free(data);

//     load_result := cgltf.load_buffers(options, data, path_cstr);
//     if load_result != .success {
//         log.error("Failed to load buffers for GLB file: ", path);
//         return false;
//     }

//     validate_result := cgltf.validate(data);
//     if validate_result != .success {
//         log.error("Failed to validate GLB file: ", path);
//         return false;
//     }

//     log.info("Successfully loaded and validated GLB file: ", path);
//     log.info("=== glb inspection result ===");
//     log.info("meshes:     ", len(data.meshes));
//     log.info("materials:  ", len(data.materials));
//     log.info("textures:   ", len(data.textures));
//     log.info("images:     ", len(data.images));
//     log.info("nodes:      ", len(data.nodes));
//     log.info("skins:      ", len(data.skins));
//     log.info("animations: ", len(data.animations));

//     return true;
// }

import "core:c"

get_file_mod_time :: proc(filepath: string) -> (mod_time: time.Time, ok: bool) {
    info, err := os.stat(filepath, context.temp_allocator);
    if err != nil {
        log.error("Error occurred while fetching file info for %s: %v", filepath, err);
        return {}, false;
    }
    return info.modification_time, true;
}

load_fragment_shader_with_includes :: proc(path: string) -> (
    shader: rl.Shader,
    source: Preprocessed_Shader_Source,
    ok: bool,
) {
    preprocess_ok: bool
    source, preprocess_ok = preprocess_shader_file(path)
    if !preprocess_ok {
        return {}, source, false
    }

    source_cstr := strings.clone_to_cstring(source.code, context.temp_allocator)
    shader = rl.LoadShaderFromMemory(nil, source_cstr)
    return shader, source, rl.IsShaderValid(shader)
}

reload_fragment_shader_with_includes :: proc(
    path: string,
    shader: ^rl.Shader,
    source: ^Preprocessed_Shader_Source,
) -> bool {
    if !shader_source_dependencies_changed(source) {
        return false
    }

    log.info("Shader dependency changed; reloading %s", path)
    new_shader, new_source, loaded := load_fragment_shader_with_includes(path)
    destroy_preprocessed_shader_source(source)
    source^ = new_source

    if !loaded {
        log.error("Failed to reload %s. Keeping the old shader.", path)
        if rl.IsShaderValid(new_shader) {
            rl.UnloadShader(new_shader)
        }
        return false
    }

    rl.UnloadShader(shader^)
    shader^ = new_shader
    return true
}

is_supported_model_path :: proc(path: string) -> bool {
    extension := os.ext(path)
    for supported in SUPPORTED_MODEL_EXTENSIONS {
        if strings.equal_fold(extension, supported) {
            return true
        }
    }
    return false
}

scan_model_assets :: proc(root: string) -> Model_Assets {
    assets: Model_Assets
    walker := os.walker_create(root)
    defer os.walker_destroy(&walker)

    for info in os.walker_walk(&walker) {
        if error_path, err := os.walker_error(&walker); err != nil {
            log.error("Failed to scan model asset %s: %v", error_path, err)
            continue
        }
        if info.type != .Regular || !is_supported_model_path(info.fullpath) {
            continue
        }
        append(&assets.paths, strings.clone(info.fullpath))
    }

    slice.sort_by_key(assets.paths[:], proc(path: string) -> string { return path })
    for path in assets.paths {
        append(&assets.kinds, Model_Source_Kind.ASSET)
        label := path
        asset_marker := "/" + ASSETS_PATH + "/"
        if marker_index := strings.last_index(path, asset_marker); marker_index >= 0 {
            label = path[marker_index + len(asset_marker):]
        } else {
            label = strings.trim_prefix(path, ASSETS_PATH + "/")
        }
        if len(label) > 36 {
            label = fmt.tprintf("%s...%s", label[:14], label[len(label) - 19:])
        }
        append(&assets.labels, strings.clone_to_cstring(label))
    }

    for builtin in BUILTIN_MODEL_SOURCES {
        append(&assets.paths, strings.clone(builtin.path))
        append(&assets.labels, strings.clone_to_cstring(builtin.label))
        append(&assets.kinds, builtin.kind)
    }

    log.info("Found %d model assets under %s and added 3 built-in models", len(assets.paths) - 3, root)
    return assets
}

destroy_model_assets :: proc(assets: ^Model_Assets) {
    for path in assets.paths do delete(path)
    for label in assets.labels do delete(label)
    delete(assets.paths)
    delete(assets.labels)
    delete(assets.kinds)
}

load_model_source :: proc(assets: ^Model_Assets, index: int) -> rl.Model {
    switch assets.kinds[index] {
    case .ASSET:
        return rl.LoadModel(
            strings.clone_to_cstring(assets.paths[index], context.temp_allocator),
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

get_model_center :: proc(model: rl.Model) -> rl.Vector3 {
    bounds := rl.GetModelBoundingBox(model)
    return {
        bounds.min.x + (bounds.max.x - bounds.min.x) * 0.5,
        bounds.min.y + (bounds.max.y - bounds.min.y) * 0.5,
        bounds.min.z + (bounds.max.z - bounds.min.z) * 0.5,
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

    correction := camera_right * (snapped_x - pan_x) +
                  camera_up * (snapped_y - pan_y)
    camera.position += correction
    camera.target += correction
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
    kind: Model_Source_Kind,
    camera: ^rl.Camera3D,
) -> f32 {
    bounds := rl.GetModelBoundingBox(model)
    center := rl.Vector3{
        bounds.min.x + (bounds.max.x - bounds.min.x) * 0.5,
        bounds.min.y + (bounds.max.y - bounds.min.y) * 0.5,
        bounds.min.z + (bounds.max.z - bounds.min.z) * 0.5,
    }
    size := rl.Vector3{
        bounds.max.x - bounds.min.x,
        bounds.max.y - bounds.min.y,
        bounds.max.z - bounds.min.z,
    }
    scene_size := max(size.x, max(size.y, size.z))
    if scene_size <= 0 {
        scene_size = 1
    }

    if kind == .CUBE || kind == .SPHERE || kind == .TRIANGLE {
        projected_width := size.x
        projected_height := size.y
        camera_position := rl.Vector3{center.x, center.y, center.z + scene_size * 3}
        camera_up := rl.Vector3{0, 1, 0}

        if kind == .TRIANGLE {
            // GenMeshPoly() lies on the XZ plane, so view it from above.
            projected_height = size.z
            camera_position = {center.x, center.y + scene_size * 3, center.z}
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
            target     = center,
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
            target     = center,
            position   = {
                center.x + scene_size * 1.5,
                center.y + scene_size * 0.7,
                center.z + scene_size * 1.5,
            },
            up         = {0, 1, 0},
            fovy       = scene_size * 2.5,
            projection = .ORTHOGRAPHIC,
        }
    }

    log.infof(
        "Model bounding box: min(%f, %f, %f), max(%f, %f, %f)",
        bounds.min.x,
        bounds.min.y,
        bounds.min.z,
        bounds.max.x,
        bounds.max.y,
        bounds.max.z,
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
                material := model.materials[material_index]
                material.shader = shader
                rl.DrawMesh(
                    model.meshes[mesh_index],
                    material,
                    model.transform,
                )
            }
        }
        // rl.DrawModelWires(model, {}, 1.0, rl.YELLOW)
    rl.EndMode3D()
}

draw_model_mask :: proc(
    mask_material: rl.Material,
    model: rl.Model,
    camera: rl.Camera3D,
) {
    rl.ClearBackground(rl.BLANK)
    rl.BeginMode3D(camera)
        if is_model_loaded(model) {
            for mesh_index := 0; mesh_index < int(model.meshCount); mesh_index += 1 {
                rl.DrawMesh(
                    model.meshes[mesh_index],
                    mask_material,
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

        for i := -grid_half_count; i <= grid_half_count; i += 1 {
            if i == 0 {
                continue
            }
            offset := f32(i) * grid_spacing
            rl.DrawLine3D(
                {-grid_extent, 0, offset},
                { grid_extent, 0, offset},
                grid_color,
            )
            rl.DrawLine3D(
                {offset, 0, -grid_extent},
                {offset, 0,  grid_extent},
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

    x_label := rl.GetWorldToScreen({axis_length, 0, 0}, camera)
    y_label := rl.GetWorldToScreen({0, axis_length, 0}, camera)
    z_label := rl.GetWorldToScreen({0, 0, axis_length}, camera)
    rl.DrawText("X", c.int(x_label.x + 6), c.int(x_label.y - 8), 18, x_color)
    rl.DrawText("Y", c.int(y_label.x + 6), c.int(y_label.y - 8), 18, y_color)
    rl.DrawText("Z", c.int(z_label.x + 6), c.int(z_label.y - 8), 18, z_color)
}

draw_model_browser :: proc(
    bounds: rl.Rectangle,
    assets: ^Model_Assets,
    scroll_index: ^c.int,
    active_index: ^c.int,
    focus_index: ^c.int,
    loaded_index: c.int,
    load_failed: bool,
) {
    rl.GuiPanel(bounds, "MODEL ASSETS")

    list_bounds := rl.Rectangle{
        bounds.x + 10,
        bounds.y + 28,
        bounds.width - 20,
        bounds.height - 62,
    }
    if len(assets.labels) > 0 {
        rl.GuiListViewEx(
            list_bounds,
            raw_data(assets.labels[:]),
            c.int(len(assets.labels)),
            scroll_index,
            active_index,
            focus_index,
        )
    } else {
        rl.GuiLabel(list_bounds, "No supported models found in assets/")
    }

    status_bounds := rl.Rectangle{
        bounds.x + 10,
        bounds.y + bounds.height - 28,
        bounds.width - 20,
        20,
    }
    if load_failed {
        rl.GuiLabel(status_bounds, "Load failed; previous model kept")
    } else if loaded_index >= 0 && int(loaded_index) < len(assets.labels) {
        rl.GuiLabel(
            status_bounds,
            rl.TextFormat("Loaded: %s", assets.labels[loaded_index]),
        )
    }
}

draw_camera_controls :: proc(
    bounds: rl.Rectangle,
    camera: ^rl.Camera3D,
    model_center: rl.Vector3,
    scene_size: f32,
    pixel_width, pixel_height: i32,
) {
    rl.GuiPanel(bounds, "CAMERA CONTROLS")

    x := bounds.x + 12
    y := bounds.y + 28
    width := bounds.width - 24
    line_height: f32 = 20

    rl.GuiLabel({x, y, width, 18}, "Reset axis view (from positive axis)")
    y += 22

    button_gap: f32 = 6
    button_width := (width - button_gap * 2) / 3
    if rl.GuiButton({x, y, button_width, 24}, "X") {
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
        {x + button_width + button_gap, y, button_width, 24},
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
        {x + (button_width + button_gap) * 2, y, button_width, 24},
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
    y += 32

    rl.GuiLabel({x, y, width, 18}, "LMB drag       Orbit around target")
    y += line_height
    rl.GuiLabel({x, y, width, 18}, "MMB drag       Screen-plane pan")
    y += line_height
    rl.GuiLabel({x, y, width, 18}, "WASD / Arrows  Screen-plane pan")
    y += line_height
    rl.GuiLabel({x, y, width, 18}, "Q / E          Zoom out / in")
    y += line_height
    rl.GuiLabel({x, y, width, 18}, "Mouse wheel    Zoom")
    y += line_height
    rl.GuiLabel({x, y, width, 18}, "Shift          Faster keyboard")
    y += line_height
    rl.GuiLabel({x, y, width, 18}, "1 / 2 / 3      Pixel / blend / mask")
    y += line_height + 4
    rl.GuiLabel(
        {x, y, width, 18},
        rl.TextFormat("Pan + zoom snap: %d x %d", pixel_width, pixel_height),
    )
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
    image_bounds := rl.Rectangle{
        bounds.x + 10,
        bounds.y + 28,
        display_size,
        display_size,
    }
    source_bounds := rl.Rectangle{
        f32(sample_x),
        f32(screen_height - sample_y - MAGNIFIER_SAMPLE_SIZE),
        f32(MAGNIFIER_SAMPLE_SIZE),
        -f32(MAGNIFIER_SAMPLE_SIZE),
    }

    rl.GuiPanel(bounds, "MAGNIFIER 16 x 16")
    rl.DrawTexturePro(
        source_texture,
        source_bounds,
        image_bounds,
        {},
        0,
        rl.WHITE,
    )

    grid_color := rl.Color{0, 0, 0, 80}
    for pixel := 0; pixel <= MAGNIFIER_SAMPLE_SIZE; pixel += 1 {
        offset := f32(pixel * MAGNIFIER_DISPLAY_SCALE)
        rl.DrawLineV(
            {image_bounds.x + offset, image_bounds.y},
            {image_bounds.x + offset, image_bounds.y + image_bounds.height},
            grid_color,
        )
        rl.DrawLineV(
            {image_bounds.x, image_bounds.y + offset},
            {image_bounds.x + image_bounds.width, image_bounds.y + offset},
            grid_color,
        )
    }

    // Keep the exact pixel under the cursor identifiable inside the 16x16 sample.
    cursor_column := mouse_x - sample_x
    cursor_row := mouse_y - sample_y
    cursor_pixel_bounds := rl.Rectangle{
        image_bounds.x + f32(cursor_column * MAGNIFIER_DISPLAY_SCALE),
        image_bounds.y + f32(cursor_row * MAGNIFIER_DISPLAY_SCALE),
        MAGNIFIER_DISPLAY_SCALE,
        MAGNIFIER_DISPLAY_SCALE,
    }
    rl.DrawRectangleLinesEx(cursor_pixel_bounds, 2, rl.YELLOW)
    rl.DrawRectangleLinesEx(image_bounds, 1, rl.RAYWHITE)
    rl.GuiLabel(
        {
            bounds.x + 10,
            image_bounds.y + image_bounds.height + 4,
            bounds.width - 20,
            18,
        },
        rl.TextFormat("Cursor: %d, %d", mouse_x, mouse_y),
    )
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
        yaw := -mouse_delta.x * mouse_look_sensitivity
        pitch := -mouse_delta.y * mouse_look_sensitivity

        // Turntable orbit: yaw is always around world Y, while pitch is around
        // the current horizontal camera-right axis. Never rotate camera.up;
        // doing so turns this into a trackball and introduces unwanted roll.
        world_up := rl.Vector3{0, 1, 0}
        position_from_pivot := camera.position - orbit_pivot
        target_from_pivot := camera.target - orbit_pivot

        if yaw != 0 {
            position_from_pivot = rl.Vector3RotateByAxisAngle(
                position_from_pivot,
                world_up,
                yaw,
            )
            target_from_pivot = rl.Vector3RotateByAxisAngle(
                target_from_pivot,
                world_up,
                yaw,
            )
        }

        if pitch != 0 {
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
                    max(pitch, -max_elevation - elevation),
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
        mouse_pan := camera_right * (-mouse_delta.x * pan_sensitivity) +
                     camera_up * (mouse_delta.y * pan_sensitivity)
        camera.position += mouse_pan
        camera.target += mouse_pan
        if mouse_delta.x != 0 || mouse_delta.y != 0 {
            camera_changed = true
        }
    }

    wheel := rl.GetMouseWheelMove()
    if wheel != 0 {
        zoom_factor := 1.0 - wheel * 0.1
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

    columns := int(lens_bounds.width) / PIXEL_SCALE
    rows := int(lens_bounds.height) / PIXEL_SCALE

    for column := 0; column <= columns; column += 1 {
        x := lens_bounds.x + f32(column * PIXEL_SCALE)
        color := rl.Color{255, 255, 255, 45}
        if column % 5 == 0 {
            color = rl.Color{255, 230, 80, 100}
        }
        rl.DrawLineV(
            {x, lens_bounds.y},
            {x, lens_bounds.y + lens_bounds.height},
            color,
        )
    }

    for row := 0; row <= rows; row += 1 {
        y := lens_bounds.y + f32(row * PIXEL_SCALE)
        color := rl.Color{255, 255, 255, 45}
        if row % 5 == 0 {
            color = rl.Color{255, 230, 80, 100}
        }
        rl.DrawLineV(
            {lens_bounds.x, y},
            {lens_bounds.x + lens_bounds.width, y},
            color,
        )
    }
}

main :: proc() {
    logger := log.create_console_logger()
    defer log.destroy_console_logger(logger)
    context.logger = logger

    model_assets := scan_model_assets(ASSETS_PATH)
    defer destroy_model_assets(&model_assets)

    rl.SetTraceLogLevel(.WARNING);
    // inspect_glb(DEFAULT_MODEL_PATH);

    rl.SetConfigFlags({.WINDOW_TOPMOST});
    rl.InitWindow(1280, 720, "Lab0");
    defer rl.CloseWindow();
	rgl.SetClipPlanes(0.001, 1000.0)

    rl.SetTargetFPS(60);

    fs_last_time, ok := get_file_mod_time(FS_PATH);
    shader := rl.LoadShader(VS_PATH, FS_PATH);
    defer rl.UnloadShader(shader);
    assert(ok);
    assert(rl.IsShaderValid(shader))
    log.info("Initial fragment shader modification time: %s", fs_last_time);

    downscale_shader, downscale_source, downscale_ok := load_fragment_shader_with_includes(
        DOWNSCALE_FS_PATH,
    )
    defer rl.UnloadShader(downscale_shader)
    defer destroy_preprocessed_shader_source(&downscale_source)
    assert(downscale_ok)

    mask_shader := rl.LoadShader(nil, MASK_FS_PATH)
    assert(rl.IsShaderValid(mask_shader))
    mask_material := rl.LoadMaterialDefault()
    defer rl.UnloadMaterial(mask_material)
    mask_material.shader = mask_shader

    mask_downscale_shader, mask_downscale_source, mask_downscale_ok :=
        load_fragment_shader_with_includes(MASK_DOWNSCALE_FS_PATH)
    defer rl.UnloadShader(mask_downscale_shader)
    defer destroy_preprocessed_shader_source(&mask_downscale_source)
    assert(mask_downscale_ok)

    model: rl.Model
    defer {
        if is_model_loaded(model) {
            rl.UnloadModel(model)
        }
    }

    camera := rl.Camera3D{
        position   = {1.5, 0.7, 1.5},
        target     = {},
        up         = {0, 1, 0},
        fovy       = 2.5,
        projection = .ORTHOGRAPHIC,
    }
    max_size: f32 = 1
    model_center: rl.Vector3
    loaded_model_index: c.int = -1
    model_active_index: c.int = -1
    model_scroll_index: c.int
    model_focus_index: c.int = -1
    model_load_failed := false

    if len(model_assets.paths) > 0 {
        initial_index := 0
        for path, index in model_assets.paths {
            if path == DEFAULT_MODEL_PATH || strings.has_suffix(path, "/" + DEFAULT_MODEL_PATH) {
                initial_index = index
                break
            }
        }

        initial_model := load_model_source(&model_assets, initial_index)
        if is_model_loaded(initial_model) {
            model = initial_model
            model_center = get_model_center(model)
            loaded_model_index = c.int(initial_index)
            model_active_index = loaded_model_index
            max_size = frame_camera_to_model(
                model,
                model_assets.kinds[initial_index],
                &camera,
            )
            log.info("Loaded initial model: %s", model_assets.paths[initial_index])
        } else {
            rl.UnloadModel(initial_model)
            model_load_failed = true
            log.error("Failed to load initial model: %s", model_assets.paths[initial_index])
        }
    }
    // Keep continuous input state separate from the quantized render camera.
    // Otherwise a sub-pixel drag would be rounded away every frame and could
    // never accumulate enough movement to cross the next pixel boundary.
    control_camera := camera

    screen_width := rl.GetScreenWidth()
    screen_height := rl.GetScreenHeight()
    scene_target := rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(scene_target)
    mask_scene_target := rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(mask_scene_target)

    pixel_width := screen_width / PIXEL_SCALE
    pixel_height := screen_height / PIXEL_SCALE
    pixel_target := rl.LoadRenderTexture(pixel_width, pixel_height)
    defer rl.UnloadRenderTexture(pixel_target)
    rl.SetTextureFilter(pixel_target.texture, .POINT)
    mask_pixel_target := rl.LoadRenderTexture(pixel_width, pixel_height)
    defer rl.UnloadRenderTexture(mask_pixel_target)
    rl.SetTextureFilter(mask_pixel_target.texture, .POINT)
    composite_target := rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(composite_target)
    rl.SetTextureFilter(composite_target.texture, .POINT)

    source_resolution := [2]f32{f32(screen_width), f32(screen_height)}
    target_resolution := [2]f32{f32(pixel_width), f32(pixel_height)}
    downscale_source_resolution_loc := rl.GetShaderLocation(downscale_shader, "u_source_resolution")
    downscale_target_resolution_loc := rl.GetShaderLocation(downscale_shader, "u_target_resolution")
    downscale_time_loc := rl.GetShaderLocation(downscale_shader, "u_time")
    downscale_mask_texture_loc := rl.GetShaderLocation(downscale_shader, "u_mask_texture")
    mask_downscale_source_resolution_loc := rl.GetShaderLocation(
        mask_downscale_shader,
        "u_source_resolution",
    )
    mask_downscale_target_resolution_loc := rl.GetShaderLocation(
        mask_downscale_shader,
        "u_target_resolution",
    )

    lens_mode := Lens_Mode.PIXELATED
    model_browser_bounds := rl.Rectangle{f32(screen_width) - 280, 10, 270, 310}
    camera_controls_bounds := rl.Rectangle{f32(screen_width) - 280, 330, 270, 250}
    magnifier_bounds := rl.Rectangle{10, f32(screen_height) - 194, 148, 184}
    coverage_alpha: f32 = -1

    for !rl.WindowShouldClose() {
        window_focused := rl.IsWindowFocused()
        if window_focused {
            rl.SetWindowOpacity(1.0)
        } else {
            rl.SetWindowOpacity(0.5)
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
        if window_focused &&
           !mouse_over_model_browser &&
           !mouse_over_camera_controls {
            update_camera_controls(&control_camera, max_size, model_center)
        }
        camera = control_camera
        snap_orthographic_zoom_to_pixel_grid(
            &camera,
            max_size,
            pixel_height,
        )
        snap_orthographic_camera_to_pixel_grid(
            &camera,
            model_center,
            pixel_height,
        )

        if window_focused {
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
        }

        fs_curr_time, ok := get_file_mod_time(FS_PATH);
        assert(ok);
        if fs_curr_time != fs_last_time {
            log.info("Fragment shader modified at: %s", fs_curr_time);
            fs_last_time = fs_curr_time;

            new_shader := rl.LoadShader(VS_PATH, FS_PATH);
            if rl.IsShaderValid(new_shader) {
                rl.UnloadShader(shader);
                shader = new_shader;
            } else {
                log.error("Failed to reload shader. Keeping the old shader.");
                rl.UnloadShader(new_shader);
            }
        }

        if reload_fragment_shader_with_includes(
            DOWNSCALE_FS_PATH,
            &downscale_shader,
            &downscale_source,
        ) {
            downscale_source_resolution_loc = rl.GetShaderLocation(downscale_shader, "u_source_resolution")
            downscale_target_resolution_loc = rl.GetShaderLocation(downscale_shader, "u_target_resolution")
            downscale_time_loc = rl.GetShaderLocation(downscale_shader, "u_time")
            downscale_mask_texture_loc = rl.GetShaderLocation(downscale_shader, "u_mask_texture")
        }

        if reload_fragment_shader_with_includes(
            MASK_DOWNSCALE_FS_PATH,
            &mask_downscale_shader,
            &mask_downscale_source,
        ) {
            mask_downscale_source_resolution_loc = rl.GetShaderLocation(
                mask_downscale_shader,
                "u_source_resolution",
            )
            mask_downscale_target_resolution_loc = rl.GetShaderLocation(
                mask_downscale_shader,
                "u_target_resolution",
            )
        }

        time_val := f32(rl.GetTime());
        rl.SetShaderValue(downscale_shader, downscale_source_resolution_loc, &source_resolution, .VEC2)
        rl.SetShaderValue(downscale_shader, downscale_target_resolution_loc, &target_resolution, .VEC2)
        rl.SetShaderValue(downscale_shader, downscale_time_loc, &time_val, .FLOAT)
        rl.SetShaderValue(
            mask_downscale_shader,
            mask_downscale_source_resolution_loc,
            &source_resolution,
            .VEC2,
        )
        rl.SetShaderValue(
            mask_downscale_shader,
            mask_downscale_target_resolution_loc,
            &target_resolution,
            .VEC2,
        )

        rl.BeginTextureMode(scene_target)
            draw_scene(shader, model, camera)
        rl.EndTextureMode()

        rl.BeginTextureMode(mask_scene_target)
            draw_model_mask(mask_material, model, camera)
        rl.EndTextureMode()

        scene_source := rl.Rectangle{
            width  = f32(screen_width),
            height = -f32(screen_height),
        }

        rl.BeginTextureMode(pixel_target)
            rl.ClearBackground(rl.BLANK)
            rl.BeginShaderMode(downscale_shader)
                rl.SetShaderValueTexture(
                    downscale_shader,
                    downscale_mask_texture_loc,
                    mask_scene_target.texture,
                )
                rl.DrawTexturePro(
                    scene_target.texture,
                    scene_source,
                    {0, 0, f32(pixel_width), f32(pixel_height)},
                    {},
                    0,
                    rl.WHITE,
                )
            rl.EndShaderMode()
        rl.EndTextureMode()

        rl.BeginTextureMode(mask_pixel_target)
            rl.ClearBackground(rl.BLANK)
            rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
            rl.BeginShaderMode(mask_downscale_shader)
                rl.DrawTexturePro(
                    mask_scene_target.texture,
                    scene_source,
                    {0, 0, f32(pixel_width), f32(pixel_height)},
                    {},
                    0,
                    rl.WHITE,
                )
            rl.EndShaderMode()
            rl.EndBlendMode()
        rl.EndTextureMode()

        rl.BeginTextureMode(composite_target)
            rl.ClearBackground(rl.BLACK)
            rl.DrawTexturePro(
                scene_target.texture,
                scene_source,
                {0, 0, f32(screen_width), f32(screen_height)},
                {},
                0,
                rl.WHITE,
            )

            centered_rect := rl.Rectangle{
                x      = (f32(screen_width) - LENS_WIDTH) / 2,
                y      = (f32(screen_height) - LENS_HEIGHT) / 2,
                width  = LENS_WIDTH,
                height = LENS_HEIGHT,
            }

            pixel_source := rl.Rectangle{
                x      = centered_rect.x / PIXEL_SCALE,
                y      = f32(pixel_height) - (centered_rect.y + centered_rect.height) / PIXEL_SCALE,
                width  = centered_rect.width / PIXEL_SCALE,
                height = -centered_rect.height / PIXEL_SCALE,
            }
            coverage_alpha = -1
            mouse_position := rl.GetMousePosition()
            if lens_mode == .COVERAGE_MASK &&
               rl.CheckCollisionPointRec(mouse_position, centered_rect) {
                lens_column := c.int(
                    (mouse_position.x - centered_rect.x) / f32(PIXEL_SCALE),
                )
                lens_row := c.int(
                    (mouse_position.y - centered_rect.y) / f32(PIXEL_SCALE),
                )
                mask_x := c.int(centered_rect.x / f32(PIXEL_SCALE)) + lens_column
                mask_y := c.int(centered_rect.y / f32(PIXEL_SCALE)) + lens_row
                mask_image := rl.LoadImageFromTexture(mask_pixel_target.texture)
                mask_image_y := mask_image.height - 1 - mask_y
                mask_color := rl.GetImageColor(mask_image, mask_x, mask_image_y)
                coverage_alpha = f32(mask_color.a) / 255.0
                rl.UnloadImage(mask_image)
            }
            lens_tint := rl.WHITE
            if lens_mode == .BLENDED {
                lens_tint.a = 128
            }
            lens_texture := pixel_target.texture
            if lens_mode == .COVERAGE_MASK {
                lens_texture = mask_pixel_target.texture
            }
            if lens_mode == .COVERAGE_MASK {
                rl.DrawRectangleRec(centered_rect, rl.BLACK)
                rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
                    rl.DrawTexturePro(
                        lens_texture,
                        pixel_source,
                        centered_rect,
                        {},
                        0,
                        lens_tint,
                    )
                rl.EndBlendMode()
            } else {
                rl.DrawTexturePro(
                    lens_texture,
                    pixel_source,
                    centered_rect,
                    {},
                    0,
                    lens_tint,
                )
            }
            draw_coordinate_grid_overlay(camera, model, max_size)
            draw_orthographic_snap_debug(
                &camera,
                model_center,
                pixel_height,
                centered_rect,
                lens_mode,
                coverage_alpha,
            )
            rl.DrawRectangleLinesEx(centered_rect, 2, rl.WHITE)
            draw_model_browser(
                model_browser_bounds,
                &model_assets,
                &model_scroll_index,
                &model_active_index,
                &model_focus_index,
                loaded_model_index,
                model_load_failed,
            )
            draw_camera_controls(
                camera_controls_bounds,
                &control_camera,
                model_center,
                max_size,
                pixel_width,
                pixel_height,
            )
        rl.EndTextureMode()

        rl.BeginDrawing()
            rl.ClearBackground(rl.BLACK)
            rl.DrawTexturePro(
                composite_target.texture,
                scene_source,
                {0, 0, f32(screen_width), f32(screen_height)},
                {},
                0,
                rl.WHITE,
            )
            draw_mouse_magnifier(
                magnifier_bounds,
                composite_target.texture,
                rl.GetMousePosition(),
                screen_width,
                screen_height,
            )
        rl.EndDrawing()

        if model_active_index != loaded_model_index &&
           model_active_index >= 0 &&
            int(model_active_index) < len(model_assets.paths) {
            requested_index := int(model_active_index)
            requested_label := model_assets.labels[requested_index]
            new_model := load_model_source(&model_assets, requested_index)
            if is_model_loaded(new_model) {
                if is_model_loaded(model) {
                    rl.UnloadModel(model)
                }
                model = new_model
                model_center = get_model_center(model)
                loaded_model_index = model_active_index
                max_size = frame_camera_to_model(
                    model,
                    model_assets.kinds[requested_index],
                    &camera,
                )
                control_camera = camera
                model_load_failed = false
                log.info("Loaded model: %s", requested_label)
            } else {
                rl.UnloadModel(new_model)
                model_active_index = loaded_model_index
                model_load_failed = true
                log.error("Failed to load model: %s", requested_label)
            }
        }
    }
}
