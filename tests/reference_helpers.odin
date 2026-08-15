package tests

// Test-only state inspection and CPU reference math. The lighting helpers
// mirror scene_multi_light_common.glsl; they specify expected boundaries but
// do not execute or validate the GPU shader itself.

import "core:math"
import app "../src"
import shared "../src/shared"
import rl "vendor:raylib"

game_particles_active_count :: proc(system: ^app.Game_Particle_System) -> int {
    count := 0
    for particle in system.particles {
        if particle.active {
            count += 1
        }
    }
    return count
}

scene_wrapped_lambert :: proc(
    normal, surface_to_light: rl.Vector3,
    wrap_lighting: f32,
) -> f32 {
    if !shared.scene_direction_valid(normal) ||
       !shared.scene_direction_valid(surface_to_light) {
        return 0
    }
    unit_normal := rl.Vector3Normalize(normal)
    unit_light := rl.Vector3Normalize(surface_to_light)
    denominator := max(1 + wrap_lighting, f32(0.0001))
    return clamp(
        (rl.Vector3DotProduct(unit_normal, unit_light) + wrap_lighting) /
        denominator,
        f32(0),
        f32(1),
    )
}

scene_distance_attenuation :: proc(distance, light_range: f32) -> f32 {
    if !shared.scene_f32_finite(distance) || !shared.scene_f32_finite(light_range) ||
       distance < 0 || light_range < shared.SCENE_MIN_LIGHT_RANGE {
        return 0
    }
    x := clamp(distance / light_range, f32(0), f32(1))
    falloff := 1 - x * x
    return falloff * falloff
}

scene_spot_attenuation :: proc(
    theta, inner_angle_deg, outer_angle_deg: f32,
) -> f32 {
    if !shared.scene_f32_finite(theta) ||
       !shared.scene_f32_finite(inner_angle_deg) ||
       !shared.scene_f32_finite(outer_angle_deg) ||
       inner_angle_deg < 0 || inner_angle_deg >= outer_angle_deg ||
       outer_angle_deg > 89 {
        return 0
    }
    degrees_to_radians :: f32(math.PI / 180)
    outer_cos := math.cos(outer_angle_deg * degrees_to_radians)
    inner_cos := math.cos(inner_angle_deg * degrees_to_radians)
    t := clamp(
        (theta - outer_cos) / max(inner_cos - outer_cos, f32(0.0001)),
        f32(0),
        f32(1),
    )
    return t * t * (3 - 2 * t)
}

scene_light_band_input :: proc(energy: rl.Vector3) -> f32 {
    if !shared.scene_vector3_finite(energy) {
        return 0
    }
    return clamp(max(energy.x, max(energy.y, energy.z)), f32(0), f32(1))
}
