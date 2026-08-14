package main

// These tests protect the conservative glTF skin-scale correction. False
// positives deform skeletons, so accepted transforms and the bundled fixture are
// both checked independently.

import "core:math"
import "core:testing"

// Matrix detection accepts only positive uniform scale and rejects translation, rotation, and non-uniform axes.
@test
pure_uniform_scale_matrix_detection_is_conservative :: proc(t: ^testing.T) {
    identity := [16]f32{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    }
    scale, valid := get_pure_uniform_scale_from_matrix(identity)
    testing.expect(t, valid)
    testing.expect(t, math.abs(scale - 1) <= GLTF_SKIN_SCALE_EPSILON)

    uniform_scale := identity
    uniform_scale[0] = 0.4262215
    uniform_scale[5] = 0.4262215
    uniform_scale[10] = 0.4262215
    scale, valid = get_pure_uniform_scale_from_matrix(uniform_scale)
    testing.expect(t, valid)
    testing.expect(
        t,
        math.abs(scale - 0.4262215) <= GLTF_SKIN_SCALE_EPSILON,
    )

    translated := uniform_scale
    translated[12] = 0.25
    _, valid = get_pure_uniform_scale_from_matrix(translated)
    testing.expect(t, !valid)

    non_uniform := uniform_scale
    non_uniform[5] = 0.5
    _, valid = get_pure_uniform_scale_from_matrix(non_uniform)
    testing.expect(t, !valid)

    rotated := uniform_scale
    rotated[1] = 0.1
    _, valid = get_pure_uniform_scale_from_matrix(rotated)
    testing.expect(t, !valid)
}

// The bundled GodotMan hierarchy must expose the known model-wide skinned-mesh scale.
@test
godotman_skinned_mesh_uniform_scale_is_detected :: proc(t: ^testing.T) {
    scale, found := get_gltf_skinned_mesh_uniform_scale("assets/godotman.glb")
    if !testing.expectf(t, found, "expected godotman skin scale metadata") {
        return
    }
    testing.expectf(
        t,
        math.abs(scale - 0.4262215) <= GLTF_SKIN_SCALE_EPSILON,
        "expected godotman skin scale 0.4262215, got %f",
        scale,
    )
}
