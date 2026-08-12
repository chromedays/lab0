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
    pos: [3]f32,
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

load_shader_with_includes :: proc(vertex_path, fragment_path: string) -> (
    shader: rl.Shader,
    source: Preprocessed_Shader_Program_Source,
    ok: bool,
) {
    preprocess_ok: bool
    source, preprocess_ok = preprocess_shader_program(vertex_path, fragment_path)
    if !preprocess_ok {
        return {}, source, false
    }

    vertex_cstr := strings.clone_to_cstring(source.vertex.code, context.temp_allocator)
    fragment_cstr := strings.clone_to_cstring(source.fragment.code, context.temp_allocator)
    shader = rl.LoadShaderFromMemory(vertex_cstr, fragment_cstr)
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

reload_shader_with_includes :: proc(
    vertex_path, fragment_path: string,
    shader: ^rl.Shader,
    source: ^Preprocessed_Shader_Program_Source,
) -> bool {
    if !shader_program_source_dependencies_changed(source) {
        return false
    }

    log.info(
        "Shader dependency changed; reloading %s and %s",
        vertex_path,
        fragment_path,
    )
    new_shader, new_source, loaded := load_shader_with_includes(
        vertex_path,
        fragment_path,
    )
    destroy_preprocessed_shader_program_source(source)
    source^ = new_source

    if !loaded {
        log.error("Failed to reload %s. Keeping the old shader.", fragment_path)
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

has_playable_animations :: proc(playback: ^Animation_Playback) -> bool {
    return playback.animations != nil && len(playback.valid_indices) > 0
}

get_active_animation :: proc(
    playback: ^Animation_Playback,
) -> (animation: rl.ModelAnimation, ok: bool) {
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
    path: string,
    kind: Model_Source_Kind,
) -> Animation_Playback {
    if kind != .ASSET {
        return {}
    }

    playback := Animation_Playback{
        speed = 1.0,
        loop = true,
        sample_count = 4,
    }
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    playback.animations = rl.LoadModelAnimations(
        path_cstr,
        &playback.animation_count,
    )
    if playback.animations == nil || playback.animation_count <= 0 {
        return playback
    }

    options_builder := strings.builder_make()
    defer strings.builder_destroy(&options_builder)

    for animation_index := 0;
        animation_index < int(playback.animation_count);
        animation_index += 1 {
        animation := playback.animations[animation_index]
        if animation.keyframeCount <= 0 {
            log.warnf(
                "Ignoring animation %d in %s because it has no keyframes",
                animation_index,
                path,
            )
            continue
        }
        if !rl.IsModelAnimationValid(model, animation) {
            log.warnf(
                "Ignoring animation %d in %s because its skeleton is incompatible",
                animation_index,
                path,
            )
            continue
        }

        if len(playback.valid_indices) > 0 {
            strings.write_byte(&options_builder, ';')
        }
        append(&playback.valid_indices, c.int(animation_index))

        animation_name := string(cstring(&animation.name[0]))
        if len(animation_name) > 0 {
            strings.write_string(&options_builder, animation_name)
        } else {
            strings.write_string(
                &options_builder,
                fmt.tprintf("Animation %d", animation_index + 1),
            )
        }
    }

    if len(playback.valid_indices) == 0 {
        destroy_animation_playback(&playback)
        return {}
    }

    playback.clip_options = strings.clone_to_cstring(
        strings.to_string(options_builder),
    )
    playback.active_index = 0
    playback.current_frame = 0
    playback.applied_frame = 0
    playback.pose_dirty = true

    animation, animation_ok := get_active_animation(&playback)
    if animation_ok {
        rl.UpdateModelAnimation(model, animation, playback.current_frame)
        playback.pose_dirty = false
    }

    log.infof(
        "Loaded %d playable animation(s) from %s",
        len(playback.valid_indices),
        path,
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
    animation, ok := get_active_animation(playback)
    if !ok {
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

draw_animation_controls :: proc(
    bounds: rl.Rectangle,
    playback: ^Animation_Playback,
) {
    animation, ok := get_active_animation(playback)
    if !ok {
        return
    }

    rl.GuiPanel(bounds, "MODEL ANIMATION")

    x := bounds.x + 12
    width := bounds.width - 24
    clip_bounds := rl.Rectangle{x + 42, bounds.y + 28, width - 42, 24}
    rl.GuiLabel({x, bounds.y + 31, 38, 18}, "Clip")

    if playback.dropdown_open {
        rl.GuiLock()
    }

    transport_y := bounds.y + 58
    button_gap: f32 = 4
    reset_width: f32 = 44
    step_width: f32 = 40
    play_width := width - reset_width - step_width * 2 - button_gap * 3

    if rl.GuiButton({x, transport_y, reset_width, 24}, "|<") {
        playback.current_frame = 0
        playback.is_playing = false
        playback.pose_dirty = true
    }
    previous_x := x + reset_width + button_gap
    if rl.GuiButton({previous_x, transport_y, step_width, 24}, "<") {
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

    play_x := previous_x + step_width + button_gap
    play_label: cstring = "Play [Space]"
    if playback.is_playing {
        play_label = "Pause [Space]"
    }
    if rl.GuiButton({play_x, transport_y, play_width, 24}, play_label) {
        playback.is_playing = !playback.is_playing
    }

    next_x := play_x + play_width + button_gap
    last_frame := f32(max(animation.keyframeCount - 1, 0))
    if rl.GuiButton({next_x, transport_y, step_width, 24}, ">") {
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
        {x, timeline_label_y, width, 18},
        rl.TextFormat(
            "Frame %d / %d",
            c.int(math.round(display_frame)),
            animation.keyframeCount - 1,
        ),
    )
    previous_frame := playback.current_frame
    rl.GuiSliderBar(
        {x, bounds.y + 108, width, 18},
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
    rl.GuiLabel({x, options_y, 40, 18}, "Speed")
    rl.GuiSliderBar(
        {x + 42, options_y, 105, 18},
        nil,
        nil,
        &playback.speed,
        0.25,
        2.0,
    )
    rl.GuiLabel(
        {x + 152, options_y, 48, 18},
        rl.TextFormat("%.2fx", playback.speed),
    )
    rl.GuiCheckBox({x + 202, options_y + 1, 16, 16}, nil, &playback.loop)
    rl.GuiLabel({x + 222, options_y, 36, 18}, "Loop")

    sample_options_y := bounds.y + 162
    previous_sampled_playback := playback.sampled_playback
    rl.GuiCheckBox(
        {x, sample_options_y + 1, 16, 16},
        nil,
        &playback.sampled_playback,
    )
    rl.GuiLabel({x + 20, sample_options_y, 66, 18}, "Sampled")
    rl.GuiLabel({x + 91, sample_options_y, 42, 18}, "Count")
    previous_sample_count := playback.sample_count
    rl.GuiSpinner(
        {x + 136, sample_options_y - 2, width - 136, 22},
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
    pixel_width, pixel_height: i32,
) {
    rl.GuiPanel(bounds, "CAMERA CONTROLS")

    x := bounds.x + 12
    y := bounds.y + 28
    width := bounds.width - 24
    line_height: f32 = 18

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
    y += 28

    if rl.GuiButton({x, y, width, 24}, "Isometric") {
        reset_camera_to_axis_view(
            camera,
            model_center,
            rl.Vector3Normalize({1, 1, 1}),
            {0, 1, 0},
            scene_size,
        )
        log.info("Camera reset to isometric view")
    }
    y += 26

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
    y += line_height
    rl.GuiLabel(
        {x, y, width, 18},
        rl.TextFormat("Pan + zoom snap: %d x %d", pixel_width, pixel_height),
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

export_lens_downsample_png :: proc(
    source_texture: rl.Texture2D,
    lens_bounds: rl.Rectangle,
    pixel_scale: i32,
    next_export_index: ^int,
) -> (path: string, ok: bool) {
    if pixel_scale <= 0 {
        return "", false
    }

    image := rl.LoadImageFromTexture(source_texture)
    if image.data == nil {
        return "", false
    }
    defer rl.UnloadImage(image)

    // RenderTexture readback is vertically inverted. Crop in readback space,
    // then flip the cropped image so the exported PNG matches the lens view.
    crop_x := c.int(math.round(lens_bounds.x / f32(pixel_scale)))
    logical_crop_y := c.int(math.round(lens_bounds.y / f32(pixel_scale)))
    crop_width := c.int(math.round(lens_bounds.width / f32(pixel_scale)))
    crop_height := c.int(math.round(lens_bounds.height / f32(pixel_scale)))
    crop_y := image.height - logical_crop_y - crop_height

    if crop_x < 0 || crop_y < 0 || crop_width <= 0 || crop_height <= 0 ||
       crop_x + crop_width > image.width || crop_y + crop_height > image.height {
        log.errorf(
            "Lens export crop is outside the downsample target: crop(%d, %d, %d, %d), target(%d, %d)",
            crop_x,
            crop_y,
            crop_width,
            crop_height,
            image.width,
            image.height,
        )
        return "", false
    }

    rl.ImageCrop(
        &image,
        {
            f32(crop_x),
            f32(crop_y),
            f32(crop_width),
            f32(crop_height),
        },
    )
    rl.ImageFlipVertical(&image)
    rl.ImageFormat(&image, .UNCOMPRESSED_R8G8B8A8)

    // Never overwrite a previous export. Continue from the next available
    // sequence number even when files already exist from an earlier run.
    for {
        candidate := fmt.tprintf("lens_downsample_%03d.png", next_export_index^)
        next_export_index^ += 1
        candidate_cstr := strings.clone_to_cstring(candidate, context.temp_allocator)
        if !rl.FileExists(candidate_cstr) {
            path = strings.clone(candidate)
            break
        }
    }

    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    ok = rl.ExportImage(image, path_cstr)
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

    shader, shader_source, shader_ok := load_shader_with_includes(VS_PATH, FS_PATH)
    defer rl.UnloadShader(shader)
    defer destroy_preprocessed_shader_program_source(&shader_source)
    assert(shader_ok)

    downscale_shader, downscale_source, downscale_ok := load_fragment_shader_with_includes(
        DOWNSCALE_FS_PATH,
    )
    defer rl.UnloadShader(downscale_shader)
    defer destroy_preprocessed_shader_source(&downscale_source)
    assert(downscale_ok)

    cel_band_shader, cel_band_source, cel_band_ok := load_shader_with_includes(
        VS_PATH,
        CEL_BAND_FS_PATH,
    )
    defer destroy_preprocessed_shader_program_source(&cel_band_source)
    assert(cel_band_ok)
    cel_band_material := rl.LoadMaterialDefault()
    defer rl.UnloadMaterial(cel_band_material)
    cel_band_material.shader = cel_band_shader

    mask_downscale_shader, mask_downscale_source, mask_downscale_ok :=
        load_fragment_shader_with_includes(MASK_DOWNSCALE_FS_PATH)
    defer rl.UnloadShader(mask_downscale_shader)
    defer destroy_preprocessed_shader_source(&mask_downscale_source)
    assert(mask_downscale_ok)

    model: rl.Model
    animation_playback: Animation_Playback
    defer {
        destroy_animation_playback(&animation_playback)
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
            animation_playback = load_animation_playback(
                model,
                model_assets.paths[initial_index],
                model_assets.kinds[initial_index],
            )
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
    cel_band_scene_target := rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(cel_band_scene_target)
    rl.SetTextureFilter(cel_band_scene_target.texture, .POINT)
    rl.SetTextureWrap(cel_band_scene_target.texture, .CLAMP)

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
    downscale_cel_band_texture_loc := rl.GetShaderLocation(downscale_shader, "u_cel_band_texture")
    downscale_color_cluster_threshold_loc := rl.GetShaderLocation(
        downscale_shader,
        "u_color_cluster_threshold",
    )
    mask_downscale_source_resolution_loc := rl.GetShaderLocation(
        mask_downscale_shader,
        "u_source_resolution",
    )
    mask_downscale_target_resolution_loc := rl.GetShaderLocation(
        mask_downscale_shader,
        "u_target_resolution",
    )
    color_cluster_threshold := f32(DEFAULT_COLOR_CLUSTER_THRESHOLD)

    lens_mode := Lens_Mode.PIXELATED
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
           !mouse_over_model_browser &&
           !mouse_over_camera_controls &&
           !mouse_over_background_controls &&
           !mouse_over_animation_controls {
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

        export_requested := false
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
            if rl.IsKeyPressed(.P) {
                export_requested = true
            }
            if has_playable_animations(&animation_playback) &&
               !animation_playback.dropdown_open &&
               rl.IsKeyPressed(.SPACE) {
                animation_playback.is_playing = !animation_playback.is_playing
            }
        }

        update_animation_playback(&animation_playback, model)

        _ = reload_shader_with_includes(
            VS_PATH,
            FS_PATH,
            &shader,
            &shader_source,
        )

        if reload_shader_with_includes(
            VS_PATH,
            CEL_BAND_FS_PATH,
            &cel_band_shader,
            &cel_band_source,
        ) {
            cel_band_material.shader = cel_band_shader
        }

        if reload_fragment_shader_with_includes(
            DOWNSCALE_FS_PATH,
            &downscale_shader,
            &downscale_source,
        ) {
            downscale_source_resolution_loc = rl.GetShaderLocation(downscale_shader, "u_source_resolution")
            downscale_target_resolution_loc = rl.GetShaderLocation(downscale_shader, "u_target_resolution")
            downscale_cel_band_texture_loc = rl.GetShaderLocation(
                downscale_shader,
                "u_cel_band_texture",
            )
            downscale_color_cluster_threshold_loc = rl.GetShaderLocation(
                downscale_shader,
                "u_color_cluster_threshold",
            )
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

        rl.SetShaderValue(downscale_shader, downscale_source_resolution_loc, &source_resolution, .VEC2)
        rl.SetShaderValue(downscale_shader, downscale_target_resolution_loc, &target_resolution, .VEC2)
        rl.SetShaderValue(
            downscale_shader,
            downscale_color_cluster_threshold_loc,
            &color_cluster_threshold,
            .FLOAT,
        )
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

        rl.BeginTextureMode(cel_band_scene_target)
            draw_model_cel_bands(cel_band_material, model, camera)
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
                    downscale_cel_band_texture_loc,
                    cel_band_scene_target.texture,
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
                    cel_band_scene_target.texture,
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
            rl.ClearBackground(scene_background_color)
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
                rl.DrawRectangleRec(centered_rect, scene_background_color)
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

            export_button_bounds := rl.Rectangle{
                centered_rect.x + (centered_rect.width - 300) / 2,
                centered_rect.y + centered_rect.height + 10,
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
                        centered_rect.x,
                        export_button_bounds.y + export_button_bounds.height + 2,
                        centered_rect.width,
                        18,
                    },
                    export_status,
                )
            }
            draw_model_browser(
                model_browser_bounds,
                &model_assets,
                &model_scroll_index,
                &model_active_index,
                &model_focus_index,
                loaded_model_index,
                model_load_failed,
            )
            draw_animation_controls(
                animation_controls_bounds,
                &animation_playback,
            )
            draw_camera_controls(
                camera_controls_bounds,
                &control_camera,
                model_center,
                max_size,
                pixel_width,
                pixel_height,
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
                pixel_target.texture,
                centered_rect,
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
                new_animation_playback := load_animation_playback(
                    new_model,
                    model_assets.paths[requested_index],
                    model_assets.kinds[requested_index],
                )
                destroy_animation_playback(&animation_playback)
                if is_model_loaded(model) {
                    rl.UnloadModel(model)
                }
                model = new_model
                animation_playback = new_animation_playback
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
