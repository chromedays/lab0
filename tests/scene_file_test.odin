package tests

// CPU-only coverage for the Scene Editor schema, validation, canonical
// persistence, transform order, and lighting reference calculations.

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

scene_test_temp_path :: proc(t: ^testing.T, filename: string) -> (
    directory, path: string,
    ok: bool,
) {
    temporary_directory, temporary_error := os.make_directory_temp(
        "",
        "lab0-scene-test-*",
        context.allocator,
    )
    if !testing.expectf(
        t,
        temporary_error == nil,
        "failed to create scene test directory: %v",
        temporary_error,
    ) {
        return
    }
    output_path, path_error := filepath.join({temporary_directory, filename})
    if !testing.expectf(
        t,
        path_error == nil,
        "failed to create scene test path: %v",
        path_error,
    ) {
        _ = os.remove_all(temporary_directory)
        delete(temporary_directory)
        return
    }
    return temporary_directory, output_path, true
}

@test
scene_default_is_valid_and_uses_strict_json_conventions :: proc(t: ^testing.T) {
    scene := scene_make_default()
    defer scene_destroy(&scene)
    testing.expect_value(t, scene_validate(&scene), Scene_Error.NONE)
    testing.expect_value(t, scene.style_path, "styles/classic.json")
    testing.expect_value(t, scene.render.downscale_level, DEFAULT_DOWNSCALE_LEVEL)
    testing.expect_value(t, scene.camera.projection, Scene_Projection.PERSPECTIVE)
    testing.expect(t, scene.directional_light.casts_shadows)
    testing.expect_value(
        t,
        scene.directional_light.shadow_extent,
        SCENE_DEFAULT_SHADOW_EXTENT,
    )
}

@test
scene_legacy_v1_without_shadow_members_preserves_unshadowed_output :: proc(
    t: ^testing.T,
) {
    source := scene_make_default()
    defer scene_destroy(&source)
    file := scene_to_file_data(&source)
    defer scene_file_destroy(&file)
    file.directional_light.casts_shadows = {}
    file.directional_light.shadow_strength = {}
    file.directional_light.shadow_bias = {}
    file.directional_light.shadow_extent = {}

    loaded, load_error := scene_from_file_data(&file, false)
    defer scene_destroy(&loaded)
    if !testing.expect_value(t, load_error, Scene_Error.NONE) { return }
    testing.expect(t, !loaded.directional_light.casts_shadows)
    testing.expect_value(
        t,
        loaded.directional_light.shadow_strength,
        SCENE_DEFAULT_SHADOW_STRENGTH,
    )
    testing.expect_value(
        t,
        loaded.directional_light.shadow_bias,
        SCENE_DEFAULT_SHADOW_BIAS,
    )
    testing.expect_value(
        t,
        loaded.directional_light.shadow_extent,
        SCENE_DEFAULT_SHADOW_EXTENT,
    )
}

@test
scene_loader_rejects_json5_trailing_commas :: proc(t: ^testing.T) {
    directory, path, ok := scene_test_temp_path(t, "invalid.json")
    if !ok { return }
    defer delete(path)
    defer delete(directory)
    defer os.remove_all(directory)

    invalid_json := `{"schema_version": 1,}`
    write_error := os.write_entire_file(path, transmute([]byte)invalid_json)
    if !testing.expectf(t, write_error == nil, "write failed: %v", write_error) {
        return
    }
    scene, load_error := scene_load(path, false)
    defer scene_destroy(&scene)
    testing.expect_value(t, load_error, Scene_Error.PARSE_FAILED)
}

@test
scene_loader_rejects_json_comments :: proc(t: ^testing.T) {
    directory, path, ok := scene_test_temp_path(t, "comment.json")
    if !ok { return }
    defer delete(path)
    defer delete(directory)
    defer os.remove_all(directory)

    invalid_json := "{\n  // not strict JSON\n  \"schema_version\": 1\n}"
    write_error := os.write_entire_file(path, transmute([]byte)invalid_json)
    if !testing.expectf(t, write_error == nil, "write failed: %v", write_error) {
        return
    }
    scene, load_error := scene_load(path, false)
    defer scene_destroy(&scene)
    testing.expect_value(t, load_error, Scene_Error.PARSE_FAILED)
}

@test
scene_json_round_trip_preserves_fixed_pose_and_lights :: proc(t: ^testing.T) {
    directory, path, ok := scene_test_temp_path(t, "round-trip.json")
    if !ok { return }
    defer delete(path)
    defer delete(directory)
    defer os.remove_all(directory)

    scene := scene_make_default()
    defer scene_destroy(&scene)
    append(&scene.models, Scene_Model{
        id = strings.clone("model_001"),
        name = strings.clone("Runner"),
        visible = true,
        source = strings.clone("assets/CesiumMan.glb"),
        transform = {
            rotation_euler_deg = {0, 450, 0},
            scale = {1, 1, 1},
        },
        tint = rl.WHITE,
        animation = Scene_Animation_Pose{clip_index = 0, frame = 24},
    })
    append(&scene.primitives, Scene_Primitive{
        id = strings.clone("primitive_001"),
        name = strings.clone("Floor"),
        visible = true,
        shape = .PLANE,
        transform = {scale = {10, 1, 10}},
        albedo = {160, 170, 185, 255},
    })
    append(&scene.point_lights, Scene_Point_Light{
        id = strings.clone("point_001"),
        name = strings.clone("Fill"),
        enabled = true,
        position = {-2, 2, 1},
        color = {1, 0.15, 0.1},
        intensity = 1.2,
        range = 6,
    })
    append(&scene.spot_lights, Scene_Spot_Light{
        id = strings.clone("spot_001"),
        name = strings.clone("Key"),
        enabled = true,
        position = {3, 4, 3},
        direction = {-0.55, -0.7, -0.45},
        color = {0.2, 0.45, 1},
        intensity = 1.5,
        range = 10,
        inner_angle_deg = 18,
        outer_angle_deg = 30,
    })

    save_error := scene_save(path, &scene)
    if !testing.expect_value(t, save_error, Scene_Error.NONE) { return }
    loaded, load_error := scene_load(path)
    defer scene_destroy(&loaded)
    if !testing.expect_value(t, load_error, Scene_Error.NONE) { return }

    testing.expect_value(t, len(loaded.models), 1)
    testing.expect_value(t, len(loaded.primitives), 1)
    testing.expect_value(t, len(loaded.point_lights), 1)
    testing.expect_value(t, len(loaded.spot_lights), 1)
    testing.expect(t, loaded.directional_light.casts_shadows)
    testing.expect_value(
        t,
        loaded.directional_light.shadow_strength,
        SCENE_DEFAULT_SHADOW_STRENGTH,
    )
    testing.expect_value(t, loaded.models[0].transform.rotation_euler_deg.y, f32(90))
    pose, pose_present := loaded.models[0].animation.?
    testing.expect(t, pose_present)
    if pose_present {
        testing.expect_value(t, pose.clip_index, 0)
        testing.expect_value(t, pose.frame, 24)
    }
    testing.expectf(
        t,
        math.abs(rl.Vector3Length(loaded.spot_lights[0].direction) - 1) < 0.0001,
        "spot direction should be normalized",
    )

    first_bytes, first_read_error := os.read_entire_file(path, context.allocator)
    if !testing.expectf(t, first_read_error == nil, "read failed: %v", first_read_error) {
        return
    }
    defer delete(first_bytes)
    second_save_error := scene_save(path, &loaded)
    if !testing.expect_value(t, second_save_error, Scene_Error.NONE) { return }
    second_bytes, second_read_error := os.read_entire_file(path, context.allocator)
    if !testing.expectf(t, second_read_error == nil, "read failed: %v", second_read_error) {
        return
    }
    defer delete(second_bytes)
    testing.expect_value(t, string(first_bytes), string(second_bytes))
}

@test
scene_save_omits_absent_animation_member :: proc(t: ^testing.T) {
    directory, path, ok := scene_test_temp_path(t, "static.json")
    if !ok { return }
    defer delete(path)
    defer delete(directory)
    defer os.remove_all(directory)

    scene := scene_make_default()
    defer scene_destroy(&scene)
    append(&scene.primitives, Scene_Primitive{
        id = strings.clone("primitive_001"),
        name = strings.clone("Cube"),
        visible = true,
        shape = .CUBE,
        transform = {scale = {1, 1, 1}},
        albedo = rl.WHITE,
    })
    if !testing.expect_value(t, scene_save(path, &scene), Scene_Error.NONE) {
        return
    }
    bytes, read_error := os.read_entire_file(path, context.allocator)
    if !testing.expectf(t, read_error == nil, "read failed: %v", read_error) {
        return
    }
    defer delete(bytes)
    testing.expect(t, !strings.contains(string(bytes), `"animation"`))
}

@test
scene_validation_rejects_ids_shared_between_item_types :: proc(t: ^testing.T) {
    scene := scene_make_default()
    defer scene_destroy(&scene)
    append(&scene.primitives, Scene_Primitive{
        id = strings.clone("shared_001"),
        name = strings.clone("Cube"),
        visible = true,
        shape = .CUBE,
        transform = {scale = {1, 1, 1}},
        albedo = rl.WHITE,
    })
    append(&scene.point_lights, Scene_Point_Light{
        id = strings.clone("shared_001"),
        name = strings.clone("Light"),
        enabled = true,
        color = {1, 1, 1},
        intensity = 1,
        range = 4,
    })
    testing.expect_value(t, scene_validate(&scene), Scene_Error.DUPLICATE_ID)
}

@test
scene_validation_rejects_invalid_camera_and_light_limits :: proc(t: ^testing.T) {
    scene := scene_make_default()
    defer scene_destroy(&scene)

    valid_camera := scene.camera
    scene.camera.projection = Scene_Projection(99)
    testing.expect_value(t, scene_validate(&scene), Scene_Error.INVALID_CAMERA)
    scene.camera = valid_camera

    scene.directional_light.intensity = SCENE_MAX_LIGHT_INTENSITY + 1
    testing.expect_value(
        t,
        scene_validate(&scene),
        Scene_Error.INVALID_DIRECTIONAL_LIGHT,
    )
    scene.directional_light.intensity = 1

    scene.directional_light.shadow_bias = SCENE_MAX_SHADOW_BIAS + 0.01
    testing.expect_value(
        t,
        scene_validate(&scene),
        Scene_Error.INVALID_DIRECTIONAL_LIGHT,
    )
    scene.directional_light.shadow_bias = SCENE_DEFAULT_SHADOW_BIAS

    for light_index := 0; light_index <= SCENE_MAX_POINT_LIGHTS; light_index += 1 {
        append(&scene.point_lights, Scene_Point_Light{})
    }
    testing.expect_value(
        t,
        scene_validate(&scene),
        Scene_Error.TOO_MANY_POINT_LIGHTS,
    )
}

@test
scene_shadow_projection_snaps_to_whole_light_texels :: proc(t: ^testing.T) {
    scene := scene_make_default()
    defer scene_destroy(&scene)
    scene.camera.target = {0.137, 1.271, -0.083}
    frame := scene_shadow_frame_make(&scene)
    if !testing.expect(t, frame.enabled) { return }

    forward := rl.Vector3Normalize(frame.camera.target - frame.camera.position)
    right := rl.Vector3Normalize(
        rl.Vector3CrossProduct(forward, frame.camera.up),
    )
    horizontal_texels := rl.Vector3DotProduct(frame.camera.target, right) /
                         frame.world_units_per_texel
    vertical_texels := rl.Vector3DotProduct(
        frame.camera.target,
        frame.camera.up,
    ) / frame.world_units_per_texel
    testing.expectf(
        t,
        math.abs(horizontal_texels - math.round(horizontal_texels)) < 0.0001,
        "shadow target x was not texel-snapped: %f",
        horizontal_texels,
    )
    testing.expectf(
        t,
        math.abs(vertical_texels - math.round(vertical_texels)) < 0.0001,
        "shadow target y was not texel-snapped: %f",
        vertical_texels,
    )
}

@test
scene_paths_reject_absolute_parent_and_windows_forms :: proc(t: ^testing.T) {
    testing.expect(t, scene_file_path_is_portable("styles/classic.json", ".json"))
    testing.expect(t, !scene_file_path_is_portable("/tmp/classic.json", ".json"))
    testing.expect(t, !scene_file_path_is_portable("../styles/classic.json", ".json"))
    testing.expect(t, !scene_file_path_is_portable("styles/../classic.json", ".json"))
    testing.expect(t, !scene_file_path_is_portable("styles\\classic.json", ".json"))
}

@test
scene_transform_applies_scale_then_xyz_rotation_then_translation :: proc(t: ^testing.T) {
    transform := Scene_Transform{
        position = {1, 2, 3},
        rotation_euler_deg = {0, 0, 90},
        scale = {2, 1, 1},
    }
    transformed := rl.Vector3Transform({1, 0, 0}, scene_transform_matrix(transform))
    testing.expectf(t, math.abs(transformed.x - 1) < 0.0001, "x=%f", transformed.x)
    testing.expectf(t, math.abs(transformed.y - 4) < 0.0001, "y=%f", transformed.y)
    testing.expectf(t, math.abs(transformed.z - 3) < 0.0001, "z=%f", transformed.z)
}

@test
scene_light_reference_functions_have_fixed_boundaries :: proc(t: ^testing.T) {
    testing.expect_value(t, scene_distance_attenuation(0, 10), f32(1))
    testing.expect_value(t, scene_distance_attenuation(10, 10), f32(0))
    testing.expectf(
        t,
        math.abs(scene_distance_attenuation(5, 10) - 0.5625) < 0.0001,
        "half-range attenuation changed",
    )
    testing.expectf(
        t,
        scene_spot_attenuation(1, 15, 30) > 0.9999,
        "spot center should have full attenuation",
    )
    testing.expect_value(t, scene_light_band_input({0.4, 1.4, 0.2}), f32(1))
    testing.expect_value(
        t,
        scene_wrapped_lambert({0, 1, 0}, {0, 1, 0}, 0),
        f32(1),
    )
    testing.expect_value(
        t,
        scene_wrapped_lambert({0, 1, 0}, {0, -1, 0}, 0),
        f32(0),
    )
}
