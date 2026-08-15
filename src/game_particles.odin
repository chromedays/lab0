package main

// Small, deterministic world-space dust particles for the traversal mode.
// The effect intentionally stays in fixed-update game state so replay captures
// produce the same particles without depending on render frame timing.

import "core:math"
import shared "./shared"
import rl "vendor:raylib"

GAME_PARTICLE_CAPACITY           :: 128
GAME_PARTICLE_RANDOM_SEED        :: u32(0x6d2b79f5)
GAME_PARTICLE_GRAVITY            :: f32(1.45)
GAME_PARTICLE_HORIZONTAL_DRAG    :: f32(2.2)
GAME_STEP_DUST_DISTANCE_MIN      :: f32(0.78)
GAME_STEP_DUST_DISTANCE_MAX      :: f32(1.08)
GAME_DASH_DUST_DISTANCE_MIN      :: f32(0.28)
GAME_DASH_DUST_DISTANCE_MAX      :: f32(0.38)
GAME_PARTICLE_RANDOM_UNIT_SCALE  :: f32(1.0 / 16777215.0)

GAME_DUST_COLORS := [?]rl.Color{
    {154, 146, 132, 255},
    {181, 169, 146, 255},
    {119, 116, 109, 255},
}

// Particles own no GPU resources; the renderer reads these fixed-update values
// as immutable draw inputs. floor_y is the resting plane captured at emission.
Game_Particle :: struct {
    active:     bool,
    position:   rl.Vector3,
    velocity:   rl.Vector3,
    floor_y:    f32,
    age:        f32,
    lifetime:   f32,
    start_size: f32,
    color:      rl.Color,
}

// The fixed array avoids allocator and lifetime variability during replays.
// RNG state, ring cursor, and distance accumulators are part of Game_State, so
// restoring a checkpoint also restores the exact future emission sequence.
Game_Particle_System :: struct {
    particles:             [GAME_PARTICLE_CAPACITY]Game_Particle,
    random_state:          u32,
    spawn_cursor:          int,
    step_distance:         f32,
    next_step_distance:    f32,
    dash_distance:         f32,
    next_dash_distance:    f32,
}

game_particles_init :: proc() -> Game_Particle_System {
    return {
        random_state = GAME_PARTICLE_RANDOM_SEED,
        next_step_distance = 0.66,
        next_dash_distance = GAME_DASH_DUST_DISTANCE_MIN,
    }
}

// A local xorshift generator deliberately avoids Odin's ambient random context.
// Zero is repaired because it is the absorbing state of this recurrence.
game_particles_random_u32 :: proc(system: ^Game_Particle_System) -> u32 {
    value := system.random_state
    if value == 0 {
        value = GAME_PARTICLE_RANDOM_SEED
    }
    value = value ~ (value << 13)
    value = value ~ (value >> 17)
    value = value ~ (value << 5)
    system.random_state = value
    return value
}

game_particles_random_unit :: proc(system: ^Game_Particle_System) -> f32 {
    value := game_particles_random_u32(system) & u32(0x00ffffff)
    return f32(value) * GAME_PARTICLE_RANDOM_UNIT_SCALE
}

game_particles_random_range :: proc(
    system: ^Game_Particle_System,
    minimum, maximum: f32,
) -> f32 {
    return minimum + (maximum - minimum) * game_particles_random_unit(system)
}

// Allocate from the deterministic ring, preferring inactive entries. Capacity
// exhaustion overwrites in cursor order instead of allocating or dropping an
// input-dependent particle nondeterministically.
game_particles_spawn :: proc(
    system: ^Game_Particle_System,
    position, velocity: rl.Vector3,
    floor_y, lifetime, size: f32,
) {
    slot := -1
    for offset in 0 ..< GAME_PARTICLE_CAPACITY {
        index := (system.spawn_cursor + offset) % GAME_PARTICLE_CAPACITY
        if !system.particles[index].active {
            slot = index
            break
        }
    }
    if slot < 0 {
        // The authored effects stay far below capacity. Overwriting in cursor
        // order still gives deterministic behavior if a future effect spikes.
        slot = system.spawn_cursor
    }
    system.spawn_cursor = (slot + 1) % GAME_PARTICLE_CAPACITY
    color_index := int(game_particles_random_u32(system) % u32(len(GAME_DUST_COLORS)))
    system.particles[slot] = {
        active = true,
        position = position,
        velocity = velocity,
        floor_y = floor_y,
        lifetime = lifetime,
        start_size = size,
        color = GAME_DUST_COLORS[color_index],
    }
}

// Simulation advances before the current tick emits new particles. Resting
// particles retain horizontal drag but cannot fall below their captured floor.
game_particles_fixed_update :: proc(system: ^Game_Particle_System, dt: f32) {
    horizontal_drag := max(f32(0), 1 - GAME_PARTICLE_HORIZONTAL_DRAG * dt)
    for &particle in system.particles {
        if !particle.active {
            continue
        }
        particle.age += dt
        if particle.age + 0.00001 >= particle.lifetime {
            particle.active = false
            continue
        }

        particle.velocity.x *= horizontal_drag
        particle.velocity.z *= horizontal_drag
        particle.velocity.y -= GAME_PARTICLE_GRAVITY * dt
        particle.position += particle.velocity * dt

        resting_y := particle.floor_y + 0.035
        if particle.position.y < resting_y {
            particle.position.y = resting_y
            particle.velocity.y = 0
        }
    }
}

game_particles_emit_step :: proc(
    system: ^Game_Particle_System,
    position: rl.Vector3,
    move_direction: rl.Vector2,
) {
    perpendicular := rl.Vector2{-move_direction.y, move_direction.x}
    side_sign: f32 = -1
    if game_particles_random_unit(system) >= 0.5 {
        side_sign = 1
    }
    side_offset := side_sign * game_particles_random_range(system, 0.11, 0.21)
    backwards_offset := game_particles_random_range(system, 0.08, 0.15)
    spawn_position := position
    spawn_position.x += perpendicular.x * side_offset - move_direction.x * backwards_offset
    spawn_position.z += perpendicular.y * side_offset - move_direction.y * backwards_offset
    spawn_position.y += game_particles_random_range(system, 0.045, 0.075)

    backwards_speed := game_particles_random_range(system, 0.12, 0.28)
    sideways_speed := game_particles_random_range(system, -0.09, 0.09)
    velocity := rl.Vector3{
        -move_direction.x * backwards_speed + perpendicular.x * sideways_speed,
        game_particles_random_range(system, 0.15, 0.25),
        -move_direction.y * backwards_speed + perpendicular.y * sideways_speed,
    }
    game_particles_spawn(
        system,
        spawn_position,
        velocity,
        position.y,
        game_particles_random_range(system, 0.20, 0.31),
        game_particles_random_range(system, 0.065, 0.095),
    )
}

// Emission is distance-based rather than tick-based, making density independent
// of acceleration and of how a path is split across fixed updates.
game_particles_track_steps :: proc(
    system: ^Game_Particle_System,
    from, to: rl.Vector3,
) {
    displacement := rl.Vector2{to.x - from.x, to.z - from.z}
    distance := shared.game_vector2_length(displacement)
    if distance <= 0.0001 {
        return
    }
    system.step_distance += distance
    direction := displacement / distance
    for system.step_distance >= system.next_step_distance {
        system.step_distance -= system.next_step_distance
        game_particles_emit_step(system, to, direction)
        system.next_step_distance = game_particles_random_range(
            system,
            GAME_STEP_DUST_DISTANCE_MIN,
            GAME_STEP_DUST_DISTANCE_MAX,
        )
    }
}

game_particles_emit_dash_start :: proc(
    system: ^Game_Particle_System,
    position: rl.Vector3,
    dash_direction: rl.Vector2,
) {
    perpendicular := rl.Vector2{-dash_direction.y, dash_direction.x}
    for _ in 0 ..< 3 {
        sideways := game_particles_random_range(system, -0.24, 0.24)
        backwards := game_particles_random_range(system, 0.08, 0.20)
        spawn_position := position
        spawn_position.x += perpendicular.x * sideways - dash_direction.x * backwards
        spawn_position.z += perpendicular.y * sideways - dash_direction.y * backwards
        spawn_position.y += game_particles_random_range(system, 0.045, 0.085)

        backwards_speed := game_particles_random_range(system, 0.32, 0.62)
        sideways_speed := game_particles_random_range(system, -0.18, 0.18)
        velocity := rl.Vector3{
            -dash_direction.x * backwards_speed + perpendicular.x * sideways_speed,
            game_particles_random_range(system, 0.18, 0.34),
            -dash_direction.y * backwards_speed + perpendicular.y * sideways_speed,
        }
        game_particles_spawn(
            system,
            spawn_position,
            velocity,
            position.y,
            game_particles_random_range(system, 0.22, 0.34),
            game_particles_random_range(system, 0.075, 0.115),
        )
    }
    system.dash_distance = 0
    system.next_dash_distance = game_particles_random_range(
        system,
        GAME_DASH_DUST_DISTANCE_MIN,
        GAME_DASH_DUST_DISTANCE_MAX,
    )
}

game_particles_emit_dash_trail :: proc(
    system: ^Game_Particle_System,
    position: rl.Vector3,
    dash_direction: rl.Vector2,
) {
    perpendicular := rl.Vector2{-dash_direction.y, dash_direction.x}
    sideways := game_particles_random_range(system, -0.18, 0.18)
    spawn_position := position
    spawn_position.x += perpendicular.x * sideways - dash_direction.x * 0.20
    spawn_position.z += perpendicular.y * sideways - dash_direction.y * 0.20
    spawn_position.y += game_particles_random_range(system, 0.045, 0.075)
    backwards_speed := game_particles_random_range(system, 0.18, 0.34)
    velocity := rl.Vector3{
        -dash_direction.x * backwards_speed,
        game_particles_random_range(system, 0.13, 0.24),
        -dash_direction.y * backwards_speed,
    }
    game_particles_spawn(
        system,
        spawn_position,
        velocity,
        position.y,
        game_particles_random_range(system, 0.18, 0.28),
        game_particles_random_range(system, 0.065, 0.095),
    )
}

// Dash trails have a separate accumulator because the burst at dash start
// resets trail spacing without disturbing the walking cadence.
game_particles_track_dash :: proc(
    system: ^Game_Particle_System,
    from, to: rl.Vector3,
    dash_direction: rl.Vector2,
) {
    delta_x := to.x - from.x
    delta_z := to.z - from.z
    distance := math.sqrt(delta_x * delta_x + delta_z * delta_z)
    if distance <= 0.0001 {
        return
    }
    system.dash_distance += distance
    for system.dash_distance >= system.next_dash_distance {
        system.dash_distance -= system.next_dash_distance
        game_particles_emit_dash_trail(system, to, dash_direction)
        system.next_dash_distance = game_particles_random_range(
            system,
            GAME_DASH_DUST_DISTANCE_MIN,
            GAME_DASH_DUST_DISTANCE_MAX,
        )
    }
}

game_particles_emit_landing :: proc(
    system: ^Game_Particle_System,
    position: rl.Vector3,
    drop_height: f32,
) {
    particle_count := 5
    if drop_height >= 1.25 {
        particle_count = 6
    }
    for _ in 0 ..< particle_count {
        angle := game_particles_random_range(system, 0, f32(2 * math.PI))
        direction := rl.Vector2{f32(math.cos(f64(angle))), f32(math.sin(f64(angle)))}
        radius := game_particles_random_range(system, 0.08, 0.25)
        spawn_position := position
        spawn_position.x += direction.x * radius
        spawn_position.z += direction.y * radius
        spawn_position.y += game_particles_random_range(system, 0.045, 0.075)
        speed := game_particles_random_range(system, 0.34, 0.68)
        velocity := rl.Vector3{
            direction.x * speed,
            game_particles_random_range(system, 0.20, 0.38),
            direction.y * speed,
        }
        game_particles_spawn(
            system,
            spawn_position,
            velocity,
            position.y,
            game_particles_random_range(system, 0.26, 0.40),
            game_particles_random_range(system, 0.075, 0.115),
        )
    }
}
