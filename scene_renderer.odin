package main

// GPU resources and deterministic render passes for Scene Editor mode. These
// shaders and targets are separate from Viewer and Game so their established
// capture bytes are not affected by the multi-light implementation.

import "core:c"
import "core:log"
import "core:math"
import "core:strings"
import rl "vendor:raylib"
import rgl "vendor:raylib/rlgl"

SCENE_VERTEX_SHADER_PATH   :: "shaders/scene_multi_light.vs"
SCENE_FRAGMENT_SHADER_PATH :: "shaders/scene_multi_light.fs"
SCENE_BAND_SHADER_PATH     :: "shaders/scene_multi_light_band.fs"
SCENE_SHADOW_VERTEX_SHADER_PATH   :: "shaders/scene_shadow_depth.vs"
SCENE_SHADOW_FRAGMENT_SHADER_PATH :: "shaders/scene_shadow_depth.fs"
SCENE_RENDER_NEAR_CLIP :: f32(0.001)
SCENE_RENDER_FAR_CLIP  :: f32(1000)
SCENE_SHADOW_NEAR_CLIP :: f32(0.01)

Scene_Light_Shader_Bindings :: struct {
    directional_enabled:   c.int,
    directional_direction: c.int,
    directional_color:     c.int,
    directional_intensity: c.int,
    point_count:            c.int,
    point_positions:        c.int,
    point_colors:           c.int,
    point_intensities:      c.int,
    point_ranges:           c.int,
    spot_count:             c.int,
    spot_positions:         c.int,
    spot_directions:        c.int,
    spot_colors:            c.int,
    spot_intensities:       c.int,
    spot_ranges:            c.int,
    spot_inner_cos:         c.int,
    spot_outer_cos:         c.int,
}

Scene_Shadow_Receiver_Bindings :: struct {
    enabled:               c.int,
    shadow_map:            c.int,
    strength:              c.int,
    bias:                  c.int,
    light_view_projection: c.int,
}

Scene_Shadow_Depth_Bindings :: struct {
    alpha_mode:   c.int,
    alpha_cutoff: c.int,
}

Scene_Shadow_Frame :: struct {
    enabled:               bool,
    camera:                rl.Camera3D,
    light_view_projection: rl.Matrix,
    near_clip:             f32,
    far_clip:              f32,
    world_units_per_texel: f32,
}

Scene_Renderer :: struct {
    scene_shader:      rl.Shader,
    scene_source:      Preprocessed_Shader_Program_Source,
    scene_style:       Cel_Shader_Bindings,
    scene_lights:      Scene_Light_Shader_Bindings,
    band_shader:       rl.Shader,
    band_source:       Preprocessed_Shader_Program_Source,
    band_style:        Cel_Shader_Bindings,
    band_lights:       Scene_Light_Shader_Bindings,
    scene_shadow:      Scene_Shadow_Receiver_Bindings,
    band_shadow:       Scene_Shadow_Receiver_Bindings,
    shadow_shader:     rl.Shader,
    shadow_source:     Preprocessed_Shader_Program_Source,
    shadow_depth:      Scene_Shadow_Depth_Bindings,
    downscale_shader:  rl.Shader,
    downscale_source:  Preprocessed_Shader_Source,
    mask_shader:       rl.Shader,
    mask_source:       Preprocessed_Shader_Source,
    outline_shader:    rl.Shader,
    outline_source:    Preprocessed_Shader_Source,
    cel_ramp_texture:  rl.Texture2D,
    scene_target:      rl.RenderTexture2D,
    band_target:       rl.RenderTexture2D,
    downsample_target: rl.RenderTexture2D,
    coverage_target:   rl.RenderTexture2D,
    outlined_target:   rl.RenderTexture2D,
    composite_target:  rl.RenderTexture2D,
    shadow_target:     rl.RenderTexture2D,
    low_width:         c.int,
    low_height:        c.int,
    downscale_source_resolution: c.int,
    downscale_target_resolution: c.int,
    downscale_band_texture:      c.int,
    downscale_cluster_threshold: c.int,
    downscale_rim_samples:       c.int,
    downscale_highlight_samples: c.int,
    downscale_edge_aa:           c.int,
    mask_source_resolution:      c.int,
    mask_target_resolution:      c.int,
    outline_target_resolution:   c.int,
    outline_coverage_texture:    c.int,
    outline_width:               c.int,
    outline_color:               c.int,
    outline_coverage_threshold:  c.int,
    outline_edge_aa:             c.int,
}

scene_resolve_shadow_receiver_bindings :: proc(
    shader: rl.Shader,
) -> Scene_Shadow_Receiver_Bindings {
    bindings := Scene_Shadow_Receiver_Bindings{
        enabled = rl.GetShaderLocation(shader, "u_shadow_enabled"),
        shadow_map = rl.GetShaderLocation(shader, "u_shadow_map"),
        strength = rl.GetShaderLocation(shader, "u_shadow_strength"),
        bias = rl.GetShaderLocation(shader, "u_shadow_bias"),
        light_view_projection = rl.GetShaderLocation(
            shader,
            "u_light_view_projection",
        ),
    }
    // DrawMesh binds material textures itself. Reserve the copied material's
    // occlusion slot for the editor-only shadow map, just as the emission slot
    // is reserved for the cel ramp.
    shader.locs[rl.ShaderLocationIndex.MAP_OCCLUSION] = bindings.shadow_map
    return bindings
}

// The directional shadow camera follows the serialized scene-camera target but
// snaps its two light-plane coordinates to whole shadow texels. Moving the
// authored target within one texel therefore cannot make the hard shadow crawl.
scene_make_shadow_frame :: proc(scene: ^Scene) -> Scene_Shadow_Frame {
    light := &scene.directional_light
    frame := Scene_Shadow_Frame{
        enabled = light.enabled && light.casts_shadows &&
                  light.shadow_strength > 0,
        near_clip = SCENE_SHADOW_NEAR_CLIP,
    }
    if !frame.enabled {
        frame.light_view_projection = rl.Matrix(1)
        return frame
    }

    direction := scene_normalize_direction_stable(light.direction)
    forward := -direction
    reference_up := rl.Vector3{0, 1, 0}
    if math.abs(rl.Vector3DotProduct(forward, reference_up)) > 0.98 {
        reference_up = {0, 0, 1}
    }
    right := rl.Vector3Normalize(
        rl.Vector3CrossProduct(forward, reference_up),
    )
    up := rl.Vector3Normalize(rl.Vector3CrossProduct(right, forward))

    frame.world_units_per_texel =
        light.shadow_extent / f32(SCENE_SHADOW_MAP_SIZE)
    target := scene.camera.target
    horizontal := rl.Vector3DotProduct(target, right)
    vertical := rl.Vector3DotProduct(target, up)
    snapped_horizontal := math.round(horizontal / frame.world_units_per_texel) *
                          frame.world_units_per_texel
    snapped_vertical := math.round(vertical / frame.world_units_per_texel) *
                        frame.world_units_per_texel
    target += right * (snapped_horizontal - horizontal) +
              up * (snapped_vertical - vertical)

    frame.far_clip = max(light.shadow_extent * 4, f32(10))
    frame.camera = {
        position = target + direction * (frame.far_clip * 0.5),
        target = target,
        up = up,
        fovy = light.shadow_extent,
        projection = .ORTHOGRAPHIC,
    }
    // The exact matrix used by BeginMode3D is captured during the depth pass.
    // Reconstructing it here risks a storage/order mismatch at the shader
    // boundary, especially across rlgl backends.
    frame.light_view_projection = rl.Matrix(1)
    return frame
}

// LoadRenderTexture creates a depth renderbuffer, which cannot be sampled by
// the receiver shaders. Directional shadows need a depth-only framebuffer with
// a texture attachment so the depth pass and comparison use the same GPU value.
scene_load_shadow_target :: proc(width, height: c.int) -> (rl.RenderTexture2D, bool) {
    target: rl.RenderTexture2D
    target.id = rgl.LoadFramebuffer()
    if target.id == 0 { return target, false }

    target.texture.width = width
    target.texture.height = height
    target.texture.mipmaps = 1
    target.depth = {
        id = rgl.LoadTextureDepth(width, height, false),
        width = width,
        height = height,
        mipmaps = 1,
        // rlgl exposes no public depth PixelFormat value; this metadata is not
        // used for sampling or destruction, but a known uncompressed format
        // keeps the Texture descriptor valid to raylib helpers.
        format = .UNCOMPRESSED_R32,
    }
    if target.depth.id == 0 {
        rgl.UnloadFramebuffer(target.id)
        return {}, false
    }

    rgl.EnableFramebuffer(target.id)
    rgl.FramebufferAttach(
        target.id,
        target.depth.id,
        c.int(rgl.FramebufferAttachType.DEPTH),
        c.int(rgl.FramebufferAttachTextureType.TEXTURE2D),
        0,
    )
    complete := rgl.FramebufferComplete(target.id)
    rgl.DisableFramebuffer()
    if !complete {
        rgl.UnloadTexture(target.depth.id)
        rgl.UnloadFramebuffer(target.id)
        return {}, false
    }

    rgl.TextureParameters(
        target.depth.id,
        rgl.TEXTURE_MIN_FILTER,
        rgl.TEXTURE_FILTER_NEAREST,
    )
    rgl.TextureParameters(
        target.depth.id,
        rgl.TEXTURE_MAG_FILTER,
        rgl.TEXTURE_FILTER_NEAREST,
    )
    rgl.TextureParameters(
        target.depth.id,
        rgl.TEXTURE_WRAP_S,
        rgl.TEXTURE_WRAP_CLAMP,
    )
    rgl.TextureParameters(
        target.depth.id,
        rgl.TEXTURE_WRAP_T,
        rgl.TEXTURE_WRAP_CLAMP,
    )
    return target, true
}

scene_unload_shadow_target :: proc(target: ^rl.RenderTexture2D) {
    if target.depth.id != 0 { rgl.UnloadTexture(target.depth.id) }
    if target.id != 0 { rgl.UnloadFramebuffer(target.id) }
    target^ = {}
}

scene_apply_shadow_receiver :: proc(
    shader: rl.Shader,
    bindings: ^Scene_Shadow_Receiver_Bindings,
    frame: ^Scene_Shadow_Frame,
    light: ^Scene_Directional_Light,
) {
    enabled := c.int(0)
    if frame.enabled { enabled = 1 }
    rl.SetShaderValue(shader, bindings.enabled, &enabled, .INT)
    rl.SetShaderValue(shader, bindings.strength, &light.shadow_strength, .FLOAT)
    rl.SetShaderValue(shader, bindings.bias, &light.shadow_bias, .FLOAT)
    rl.SetShaderValueMatrix(
        shader,
        bindings.light_view_projection,
        frame.light_view_projection,
    )
}

scene_apply_shadow_depth_style :: proc(
    shader: rl.Shader,
    bindings: ^Scene_Shadow_Depth_Bindings,
    style: ^Cel_Style,
) {
    alpha_mode := c.int(style.alpha_mode)
    rl.SetShaderValue(shader, bindings.alpha_mode, &alpha_mode, .INT)
    rl.SetShaderValue(shader, bindings.alpha_cutoff, &style.alpha_cutoff, .FLOAT)
}

Scene_Model_Resource :: struct {
    model:    rl.Model,
    playback: Animation_Playback,
}

Scene_Resources :: struct {
    models:     [dynamic]Scene_Model_Resource,
    primitives: [7]rl.Model,
}

scene_resolve_light_bindings :: proc(shader: rl.Shader) -> Scene_Light_Shader_Bindings {
    return {
        directional_enabled = rl.GetShaderLocation(shader, "u_directional_enabled"),
        directional_direction = rl.GetShaderLocation(shader, "u_directional_direction"),
        directional_color = rl.GetShaderLocation(shader, "u_directional_color"),
        directional_intensity = rl.GetShaderLocation(shader, "u_directional_intensity"),
        point_count = rl.GetShaderLocation(shader, "u_point_count"),
        point_positions = rl.GetShaderLocation(shader, "u_point_positions[0]"),
        point_colors = rl.GetShaderLocation(shader, "u_point_colors[0]"),
        point_intensities = rl.GetShaderLocation(shader, "u_point_intensities[0]"),
        point_ranges = rl.GetShaderLocation(shader, "u_point_ranges[0]"),
        spot_count = rl.GetShaderLocation(shader, "u_spot_count"),
        spot_positions = rl.GetShaderLocation(shader, "u_spot_positions[0]"),
        spot_directions = rl.GetShaderLocation(shader, "u_spot_directions[0]"),
        spot_colors = rl.GetShaderLocation(shader, "u_spot_colors[0]"),
        spot_intensities = rl.GetShaderLocation(shader, "u_spot_intensities[0]"),
        spot_ranges = rl.GetShaderLocation(shader, "u_spot_ranges[0]"),
        spot_inner_cos = rl.GetShaderLocation(shader, "u_spot_inner_cos[0]"),
        spot_outer_cos = rl.GetShaderLocation(shader, "u_spot_outer_cos[0]"),
    }
}

scene_apply_lights :: proc(
    shader: rl.Shader,
    bindings: ^Scene_Light_Shader_Bindings,
    scene: ^Scene,
) {
    directional_enabled := c.int(0)
    if scene.directional_light.enabled { directional_enabled = 1 }
    directional_direction := scene_normalize_direction_stable(
        scene.directional_light.direction,
    )
    rl.SetShaderValue(shader, bindings.directional_enabled, &directional_enabled, .INT)
    rl.SetShaderValue(shader, bindings.directional_direction, &directional_direction, .VEC3)
    rl.SetShaderValue(shader, bindings.directional_color, &scene.directional_light.color, .VEC3)
    rl.SetShaderValue(shader, bindings.directional_intensity, &scene.directional_light.intensity, .FLOAT)

    point_positions:   [SCENE_MAX_POINT_LIGHTS]rl.Vector3
    point_colors:      [SCENE_MAX_POINT_LIGHTS]rl.Vector3
    point_intensities: [SCENE_MAX_POINT_LIGHTS]f32
    point_ranges:      [SCENE_MAX_POINT_LIGHTS]f32
    point_count: c.int
    for light in scene.point_lights {
        if !light.enabled || point_count >= SCENE_MAX_POINT_LIGHTS { continue }
        index := int(point_count)
        point_positions[index] = light.position
        point_colors[index] = light.color
        point_intensities[index] = light.intensity
        point_ranges[index] = light.range
        point_count += 1
    }
    rl.SetShaderValue(shader, bindings.point_count, &point_count, .INT)
    rl.SetShaderValueV(shader, bindings.point_positions, raw_data(point_positions[:]), .VEC3, SCENE_MAX_POINT_LIGHTS)
    rl.SetShaderValueV(shader, bindings.point_colors, raw_data(point_colors[:]), .VEC3, SCENE_MAX_POINT_LIGHTS)
    rl.SetShaderValueV(shader, bindings.point_intensities, raw_data(point_intensities[:]), .FLOAT, SCENE_MAX_POINT_LIGHTS)
    rl.SetShaderValueV(shader, bindings.point_ranges, raw_data(point_ranges[:]), .FLOAT, SCENE_MAX_POINT_LIGHTS)

    spot_positions:   [SCENE_MAX_SPOT_LIGHTS]rl.Vector3
    spot_directions:  [SCENE_MAX_SPOT_LIGHTS]rl.Vector3
    spot_colors:      [SCENE_MAX_SPOT_LIGHTS]rl.Vector3
    spot_intensities: [SCENE_MAX_SPOT_LIGHTS]f32
    spot_ranges:      [SCENE_MAX_SPOT_LIGHTS]f32
    spot_inner_cos:   [SCENE_MAX_SPOT_LIGHTS]f32
    spot_outer_cos:   [SCENE_MAX_SPOT_LIGHTS]f32
    spot_count: c.int
    degrees_to_radians :: f32(math.PI / 180)
    for light in scene.spot_lights {
        if !light.enabled || spot_count >= SCENE_MAX_SPOT_LIGHTS { continue }
        index := int(spot_count)
        spot_positions[index] = light.position
        spot_directions[index] = scene_normalize_direction_stable(light.direction)
        spot_colors[index] = light.color
        spot_intensities[index] = light.intensity
        spot_ranges[index] = light.range
        spot_inner_cos[index] = math.cos(light.inner_angle_deg * degrees_to_radians)
        spot_outer_cos[index] = math.cos(light.outer_angle_deg * degrees_to_radians)
        spot_count += 1
    }
    rl.SetShaderValue(shader, bindings.spot_count, &spot_count, .INT)
    rl.SetShaderValueV(shader, bindings.spot_positions, raw_data(spot_positions[:]), .VEC3, SCENE_MAX_SPOT_LIGHTS)
    rl.SetShaderValueV(shader, bindings.spot_directions, raw_data(spot_directions[:]), .VEC3, SCENE_MAX_SPOT_LIGHTS)
    rl.SetShaderValueV(shader, bindings.spot_colors, raw_data(spot_colors[:]), .VEC3, SCENE_MAX_SPOT_LIGHTS)
    rl.SetShaderValueV(shader, bindings.spot_intensities, raw_data(spot_intensities[:]), .FLOAT, SCENE_MAX_SPOT_LIGHTS)
    rl.SetShaderValueV(shader, bindings.spot_ranges, raw_data(spot_ranges[:]), .FLOAT, SCENE_MAX_SPOT_LIGHTS)
    rl.SetShaderValueV(shader, bindings.spot_inner_cos, raw_data(spot_inner_cos[:]), .FLOAT, SCENE_MAX_SPOT_LIGHTS)
    rl.SetShaderValueV(shader, bindings.spot_outer_cos, raw_data(spot_outer_cos[:]), .FLOAT, SCENE_MAX_SPOT_LIGHTS)
}

scene_renderer_unload_low_targets :: proc(renderer: ^Scene_Renderer) {
    if rl.IsRenderTextureValid(renderer.outlined_target) {
        rl.UnloadRenderTexture(renderer.outlined_target)
    }
    if rl.IsRenderTextureValid(renderer.coverage_target) {
        rl.UnloadRenderTexture(renderer.coverage_target)
    }
    if rl.IsRenderTextureValid(renderer.downsample_target) {
        rl.UnloadRenderTexture(renderer.downsample_target)
    }
    renderer.outlined_target = {}
    renderer.coverage_target = {}
    renderer.downsample_target = {}
    renderer.low_width = 0
    renderer.low_height = 0
}

scene_renderer_ensure_low_targets :: proc(
    renderer: ^Scene_Renderer,
    downscale_level: int,
) -> bool {
    low_width := get_downsample_dimension(SCENE_SCREEN_WIDTH, c.int(downscale_level))
    low_height := get_downsample_dimension(SCENE_SCREEN_HEIGHT, c.int(downscale_level))
    if renderer.low_width == low_width && renderer.low_height == low_height &&
       rl.IsRenderTextureValid(renderer.downsample_target) &&
       rl.IsRenderTextureValid(renderer.coverage_target) &&
       rl.IsRenderTextureValid(renderer.outlined_target) {
        return true
    }
    scene_renderer_unload_low_targets(renderer)
    renderer.downsample_target = rl.LoadRenderTexture(low_width, low_height)
    renderer.coverage_target = rl.LoadRenderTexture(low_width, low_height)
    renderer.outlined_target = rl.LoadRenderTexture(low_width, low_height)
    if !rl.IsRenderTextureValid(renderer.downsample_target) ||
       !rl.IsRenderTextureValid(renderer.coverage_target) ||
       !rl.IsRenderTextureValid(renderer.outlined_target) {
        scene_renderer_unload_low_targets(renderer)
        log.error("Failed to create Scene Editor low-resolution render targets")
        return false
    }
    renderer.low_width = low_width
    renderer.low_height = low_height
    rl.SetTextureFilter(renderer.downsample_target.texture, .POINT)
    rl.SetTextureFilter(renderer.coverage_target.texture, .POINT)
    rl.SetTextureFilter(renderer.outlined_target.texture, .POINT)
    return true
}

scene_renderer_init :: proc(
    renderer: ^Scene_Renderer,
    style: ^Cel_Style,
    downscale_level: int,
) -> bool {
    scene_loaded: bool
    renderer.scene_shader, renderer.scene_source, scene_loaded =
        load_shader_with_includes(SCENE_VERTEX_SHADER_PATH, SCENE_FRAGMENT_SHADER_PATH)
    if !scene_loaded {
        log.error("Failed to load the Scene Editor color shader")
        return false
    }
    renderer.scene_style = resolve_cel_shader_bindings(renderer.scene_shader)
    renderer.scene_lights = scene_resolve_light_bindings(renderer.scene_shader)
    renderer.scene_shadow = scene_resolve_shadow_receiver_bindings(
        renderer.scene_shader,
    )

    band_loaded: bool
    renderer.band_shader, renderer.band_source, band_loaded =
        load_shader_with_includes(SCENE_VERTEX_SHADER_PATH, SCENE_BAND_SHADER_PATH)
    if !band_loaded {
        log.error("Failed to load the Scene Editor metadata shader")
        return false
    }
    renderer.band_style = resolve_cel_shader_bindings(renderer.band_shader)
    renderer.band_lights = scene_resolve_light_bindings(renderer.band_shader)
    renderer.band_shadow = scene_resolve_shadow_receiver_bindings(
        renderer.band_shader,
    )

    shadow_loaded: bool
    renderer.shadow_shader, renderer.shadow_source, shadow_loaded =
        load_shader_with_includes(
            SCENE_SHADOW_VERTEX_SHADER_PATH,
            SCENE_SHADOW_FRAGMENT_SHADER_PATH,
        )
    if !shadow_loaded {
        log.error("Failed to load the Scene Editor shadow-depth shader")
        return false
    }
    renderer.shadow_depth = {
        alpha_mode = rl.GetShaderLocation(renderer.shadow_shader, "u_alpha_mode"),
        alpha_cutoff = rl.GetShaderLocation(renderer.shadow_shader, "u_alpha_cutoff"),
    }

    downscale_loaded: bool
    renderer.downscale_shader, renderer.downscale_source, downscale_loaded =
        load_fragment_shader_with_includes(DOWNSCALE_FS_PATH)
    if !downscale_loaded { return false }
    mask_loaded: bool
    renderer.mask_shader, renderer.mask_source, mask_loaded =
        load_fragment_shader_with_includes(MASK_DOWNSCALE_FS_PATH)
    if !mask_loaded { return false }
    outline_loaded: bool
    renderer.outline_shader, renderer.outline_source, outline_loaded =
        load_fragment_shader_with_includes(OUTLINE_FS_PATH)
    if !outline_loaded { return false }

    ramp_pixels := build_cel_ramp_pixels(style)
    ramp_image := rl.Image{
        data = raw_data(ramp_pixels[:]),
        width = CEL_RAMP_WIDTH,
        height = 1,
        mipmaps = 1,
        format = .UNCOMPRESSED_R8G8B8A8,
    }
    renderer.cel_ramp_texture = rl.LoadTextureFromImage(ramp_image)
    if !rl.IsTextureValid(renderer.cel_ramp_texture) { return false }
    rl.SetTextureFilter(renderer.cel_ramp_texture, .POINT)
    rl.SetTextureWrap(renderer.cel_ramp_texture, .CLAMP)

    renderer.scene_target = rl.LoadRenderTexture(SCENE_SCREEN_WIDTH, SCENE_SCREEN_HEIGHT)
    renderer.band_target = rl.LoadRenderTexture(SCENE_SCREEN_WIDTH, SCENE_SCREEN_HEIGHT)
    renderer.composite_target = rl.LoadRenderTexture(SCENE_SCREEN_WIDTH, SCENE_SCREEN_HEIGHT)
    shadow_target_loaded: bool
    renderer.shadow_target, shadow_target_loaded = scene_load_shadow_target(
        SCENE_SHADOW_MAP_SIZE,
        SCENE_SHADOW_MAP_SIZE,
    )
    if !rl.IsRenderTextureValid(renderer.scene_target) ||
       !rl.IsRenderTextureValid(renderer.band_target) ||
       !rl.IsRenderTextureValid(renderer.composite_target) ||
       !shadow_target_loaded ||
       !scene_renderer_ensure_low_targets(renderer, downscale_level) {
        log.error("Failed to create Scene Editor render targets")
        return false
    }
    rl.SetTextureFilter(renderer.band_target.texture, .POINT)
    rl.SetTextureWrap(renderer.band_target.texture, .CLAMP)
    rl.SetTextureFilter(renderer.composite_target.texture, .POINT)

    renderer.downscale_source_resolution = rl.GetShaderLocation(renderer.downscale_shader, "u_source_resolution")
    renderer.downscale_target_resolution = rl.GetShaderLocation(renderer.downscale_shader, "u_target_resolution")
    renderer.downscale_band_texture = rl.GetShaderLocation(renderer.downscale_shader, "u_cel_band_texture")
    renderer.downscale_cluster_threshold = rl.GetShaderLocation(renderer.downscale_shader, "u_color_cluster_threshold")
    renderer.downscale_rim_samples = rl.GetShaderLocation(renderer.downscale_shader, "u_rim_preserve_samples")
    renderer.downscale_highlight_samples = rl.GetShaderLocation(renderer.downscale_shader, "u_highlight_preserve_samples")
    renderer.downscale_edge_aa = rl.GetShaderLocation(renderer.downscale_shader, "u_edge_aa_mode")
    renderer.mask_source_resolution = rl.GetShaderLocation(renderer.mask_shader, "u_source_resolution")
    renderer.mask_target_resolution = rl.GetShaderLocation(renderer.mask_shader, "u_target_resolution")
    renderer.outline_target_resolution = rl.GetShaderLocation(renderer.outline_shader, "u_target_resolution")
    renderer.outline_coverage_texture = rl.GetShaderLocation(renderer.outline_shader, "u_coverage_texture")
    renderer.outline_width = rl.GetShaderLocation(renderer.outline_shader, "u_outline_width")
    renderer.outline_color = rl.GetShaderLocation(renderer.outline_shader, "u_outline_color")
    renderer.outline_coverage_threshold = rl.GetShaderLocation(renderer.outline_shader, "u_coverage_threshold")
    renderer.outline_edge_aa = rl.GetShaderLocation(renderer.outline_shader, "u_edge_aa_mode")
    return true
}

scene_renderer_destroy :: proc(renderer: ^Scene_Renderer) {
    scene_unload_shadow_target(&renderer.shadow_target)
    if rl.IsRenderTextureValid(renderer.composite_target) {
        rl.UnloadRenderTexture(renderer.composite_target)
    }
    scene_renderer_unload_low_targets(renderer)
    if rl.IsRenderTextureValid(renderer.band_target) {
        rl.UnloadRenderTexture(renderer.band_target)
    }
    if rl.IsRenderTextureValid(renderer.scene_target) {
        rl.UnloadRenderTexture(renderer.scene_target)
    }
    if rl.IsTextureValid(renderer.cel_ramp_texture) {
        rl.UnloadTexture(renderer.cel_ramp_texture)
    }
    if rl.IsShaderValid(renderer.outline_shader) { rl.UnloadShader(renderer.outline_shader) }
    if rl.IsShaderValid(renderer.mask_shader) { rl.UnloadShader(renderer.mask_shader) }
    if rl.IsShaderValid(renderer.downscale_shader) { rl.UnloadShader(renderer.downscale_shader) }
    if rl.IsShaderValid(renderer.shadow_shader) { rl.UnloadShader(renderer.shadow_shader) }
    if rl.IsShaderValid(renderer.band_shader) { rl.UnloadShader(renderer.band_shader) }
    if rl.IsShaderValid(renderer.scene_shader) { rl.UnloadShader(renderer.scene_shader) }
    destroy_preprocessed_shader_source(&renderer.outline_source)
    destroy_preprocessed_shader_source(&renderer.mask_source)
    destroy_preprocessed_shader_source(&renderer.downscale_source)
    destroy_preprocessed_shader_program_source(&renderer.shadow_source)
    destroy_preprocessed_shader_program_source(&renderer.band_source)
    destroy_preprocessed_shader_program_source(&renderer.scene_source)
    renderer^ = {}
}

scene_make_primitive_model :: proc(shape: Scene_Primitive_Shape) -> rl.Model {
    mesh: rl.Mesh
    switch shape {
    case .CUBE:     mesh = rl.GenMeshCube(1, 1, 1)
    case .SPHERE:   mesh = rl.GenMeshSphere(0.5, 32, 32)
    case .PLANE:    mesh = rl.GenMeshPlane(1, 1, 1, 1)
    case .TRIANGLE: mesh = rl.GenMeshPoly(3, 0.5)
    case .CYLINDER: mesh = rl.GenMeshCylinder(0.5, 1, 24)
    case .CONE:     mesh = rl.GenMeshCone(0.5, 1, 24)
    case .TORUS:    mesh = rl.GenMeshTorus(0.25, 0.5, 24, 12)
    }
    return rl.LoadModelFromMesh(mesh)
}

scene_load_resources :: proc(scene: ^Scene) -> (Scene_Resources, Scene_Error) {
    resources: Scene_Resources
    for shape_index := 0; shape_index < len(resources.primitives); shape_index += 1 {
        resources.primitives[shape_index] = scene_make_primitive_model(
            Scene_Primitive_Shape(shape_index),
        )
        if !is_model_loaded(resources.primitives[shape_index]) {
            return resources, .INVALID_PRIMITIVE
        }
    }

    for &model_data in scene.models {
        resource, resource_error := scene_load_model_resource(&model_data)
        if resource_error != .NONE {
            return resources, resource_error
        }
        append(&resources.models, resource)
    }
    return resources, .NONE
}

scene_load_model_resource :: proc(
    model_data: ^Scene_Model,
) -> (Scene_Model_Resource, Scene_Error) {
        model_path := strings.clone_to_cstring(model_data.source, context.temp_allocator)
        resource := Scene_Model_Resource{model = rl.LoadModel(model_path)}
        if !is_model_loaded(resource.model) {
            if resource.model.meshCount > 0 || resource.model.materialCount > 0 {
                rl.UnloadModel(resource.model)
            }
            return {}, .INVALID_MODEL
        }
        if pose, pose_present := model_data.animation.?; pose_present {
            resource.playback = load_animation_playback(
                resource.model,
                model_data.source,
                .ASSET,
            )
            raw_clip_valid := false
            for valid_clip_index in resource.playback.valid_indices {
                if int(valid_clip_index) == pose.clip_index {
                    raw_clip_valid = true
                    break
                }
            }
            if !raw_clip_valid ||
               pose.clip_index >= int(resource.playback.animation_count) {
                destroy_animation_playback(&resource.playback)
                rl.UnloadModel(resource.model)
                return {}, .INVALID_ANIMATION
            }
            animation := resource.playback.animations[pose.clip_index]
            if pose.frame >= int(animation.keyframeCount) {
                destroy_animation_playback(&resource.playback)
                rl.UnloadModel(resource.model)
                return {}, .INVALID_ANIMATION
            }
            rl.UpdateModelAnimation(resource.model, animation, f32(pose.frame))
        }
        return resource, .NONE
}

scene_model_resource_destroy :: proc(resource: ^Scene_Model_Resource) {
    destroy_animation_playback(&resource.playback)
    if is_model_loaded(resource.model) {
        rl.UnloadModel(resource.model)
    }
    resource^ = {}
}

scene_resources_destroy :: proc(resources: ^Scene_Resources) {
    for &resource in resources.models {
        scene_model_resource_destroy(&resource)
    }
    delete(resources.models)
    for &model in resources.primitives {
        if is_model_loaded(model) {
            rl.UnloadModel(model)
        }
    }
    resources^ = {}
}

scene_color_multiply :: proc(left, right: rl.Color) -> rl.Color {
    multiply :: proc(a, b: u8) -> u8 {
        return u8((u16(a) * u16(b) + 127) / 255)
    }
    return {
        multiply(left.r, right.r),
        multiply(left.g, right.g),
        multiply(left.b, right.b),
        multiply(left.a, right.a),
    }
}

scene_draw_model_meshes :: proc(
    model: ^rl.Model,
    transform: rl.Matrix,
    tint: rl.Color,
    shader: rl.Shader,
    cel_ramp: rl.Texture2D,
    shadow_map := rl.Texture2D{},
) {
    for mesh_index := 0; mesh_index < int(model.meshCount); mesh_index += 1 {
        material_index := int(model.meshMaterial[mesh_index])
        if material_index < 0 || material_index >= int(model.materialCount) {
            material_index = 0
        }
        source_material := model.materials[material_index]
        material_maps: [rl.MAX_MATERIAL_MAPS]rl.MaterialMap
        copy(
            material_maps[:],
            source_material.maps[:rl.MAX_MATERIAL_MAPS],
        )
        material := source_material
        material.maps = raw_data(material_maps[:])
        material.shader = shader
        material.maps[rl.MaterialMapIndex.EMISSION].texture = cel_ramp
        if rl.IsTextureValid(shadow_map) {
            material.maps[rl.MaterialMapIndex.OCCLUSION].texture = shadow_map
        }
        material.maps[rl.MaterialMapIndex.ALBEDO].color = scene_color_multiply(
            source_material.maps[rl.MaterialMapIndex.ALBEDO].color,
            tint,
        )
        rl.DrawMesh(model.meshes[mesh_index], material, transform)
    }
}

scene_primitive_local_transform :: proc(shape: Scene_Primitive_Shape) -> rl.Matrix {
    if shape == .CYLINDER || shape == .CONE {
        return rl.MatrixTranslate(0, -0.5, 0)
    }
    return rl.Matrix(1)
}

scene_draw_geometry :: proc(
    scene: ^Scene,
    resources: ^Scene_Resources,
    shader: rl.Shader,
    cel_ramp: rl.Texture2D,
    shadow_map := rl.Texture2D{},
) {
    for model_data, model_index in scene.models {
        if !model_data.visible || model_index >= len(resources.models) { continue }
        resource := &resources.models[model_index]
        transform := scene_transform_matrix(model_data.transform) * resource.model.transform
        scene_draw_model_meshes(
            &resource.model,
            transform,
            model_data.tint,
            shader,
            cel_ramp,
            shadow_map,
        )
    }
    for primitive in scene.primitives {
        if !primitive.visible { continue }
        model := &resources.primitives[int(primitive.shape)]
        transform := scene_transform_matrix(primitive.transform) *
                     scene_primitive_local_transform(primitive.shape) *
                     model.transform
        scene_draw_model_meshes(
            model,
            transform,
            primitive.albedo,
            shader,
            cel_ramp,
            shadow_map,
        )
    }
}

scene_renderer_render :: proc(
    renderer: ^Scene_Renderer,
    resources: ^Scene_Resources,
    scene: ^Scene,
    style: ^Cel_Style,
) -> bool {
    if !scene_renderer_ensure_low_targets(renderer, scene.render.downscale_level) {
        return false
    }
    camera := scene_camera_to_raylib(scene.camera)
    shadow_frame := scene_make_shadow_frame(scene)
    source_resolution := [2]f32{SCENE_SCREEN_WIDTH, SCENE_SCREEN_HEIGHT}
    target_resolution := [2]f32{f32(renderer.low_width), f32(renderer.low_height)}
    cluster_threshold := f32(DEFAULT_COLOR_CLUSTER_THRESHOLD)
    rim_samples := c.int(style.rim.preserve_samples)
    highlight_samples := c.int(style.highlight.preserve_samples)
    edge_aa := c.int(scene.render.edge_aa)
    outline_width := c.int(style.outline.width)
    outline_color := [4]f32{
        f32(style.outline.color.r) / 255,
        f32(style.outline.color.g) / 255,
        f32(style.outline.color.b) / 255,
        f32(style.outline.color.a) / 255,
    }

    rl.SetShaderValue(renderer.downscale_shader, renderer.downscale_source_resolution, &source_resolution, .VEC2)
    rl.SetShaderValue(renderer.downscale_shader, renderer.downscale_target_resolution, &target_resolution, .VEC2)
    rl.SetShaderValue(renderer.downscale_shader, renderer.downscale_cluster_threshold, &cluster_threshold, .FLOAT)
    rl.SetShaderValue(renderer.downscale_shader, renderer.downscale_rim_samples, &rim_samples, .INT)
    rl.SetShaderValue(renderer.downscale_shader, renderer.downscale_highlight_samples, &highlight_samples, .INT)
    rl.SetShaderValue(renderer.downscale_shader, renderer.downscale_edge_aa, &edge_aa, .INT)
    rl.SetShaderValue(renderer.mask_shader, renderer.mask_source_resolution, &source_resolution, .VEC2)
    rl.SetShaderValue(renderer.mask_shader, renderer.mask_target_resolution, &target_resolution, .VEC2)
    rl.SetShaderValue(renderer.outline_shader, renderer.outline_target_resolution, &target_resolution, .VEC2)
    rl.SetShaderValue(renderer.outline_shader, renderer.outline_width, &outline_width, .INT)
    rl.SetShaderValue(renderer.outline_shader, renderer.outline_color, &outline_color, .VEC4)
    rl.SetShaderValue(renderer.outline_shader, renderer.outline_coverage_threshold, &style.outline.coverage_threshold, .FLOAT)
    rl.SetShaderValue(renderer.outline_shader, renderer.outline_edge_aa, &edge_aa, .INT)

    if shadow_frame.enabled {
        // BeginMode3D builds its projection from the active rlgl clip planes.
        // Use the same values in the matrix sampled by the visible passes, then
        // restore Lab0's normal camera range before drawing those passes.
        rgl.SetClipPlanes(
            f64(shadow_frame.near_clip),
            f64(shadow_frame.far_clip),
        )
        rl.BeginTextureMode(renderer.shadow_target)
            rl.ClearBackground(rl.WHITE)
            rgl.DisableColorBlend()
            rgl.DisableBackfaceCulling()
            scene_apply_shadow_depth_style(
                renderer.shadow_shader,
                &renderer.shadow_depth,
                style,
            )
            rl.BeginMode3D(shadow_frame.camera)
                // Match raylib's shadow-map contract: capture the exact light
                // matrices installed by BeginMode3D and combine them in rlgl's
                // storage order. The visible passes consume this same matrix.
                shadow_frame.light_view_projection =
                    rgl.GetMatrixProjection() * rgl.GetMatrixModelview()
                scene_draw_geometry(
                    scene,
                    resources,
                    renderer.shadow_shader,
                    renderer.cel_ramp_texture,
                )
            rl.EndMode3D()
            rgl.EnableBackfaceCulling()
            rgl.EnableColorBlend()
        rl.EndTextureMode()
        rgl.SetClipPlanes(
            f64(SCENE_RENDER_NEAR_CLIP),
            f64(SCENE_RENDER_FAR_CLIP),
        )
    }

    rl.BeginTextureMode(renderer.scene_target)
        rl.ClearBackground(rl.BLANK)
        apply_cel_style_to_shader(renderer.scene_shader, &renderer.scene_style, style, camera, rl.Matrix(1))
        scene_apply_lights(renderer.scene_shader, &renderer.scene_lights, scene)
        scene_apply_shadow_receiver(
            renderer.scene_shader,
            &renderer.scene_shadow,
            &shadow_frame,
            &scene.directional_light,
        )
        rl.BeginMode3D(camera)
            scene_draw_geometry(
                scene,
                resources,
                renderer.scene_shader,
                renderer.cel_ramp_texture,
                renderer.shadow_target.depth,
            )
        rl.EndMode3D()
    rl.EndTextureMode()

    rl.BeginTextureMode(renderer.band_target)
        rl.ClearBackground(rl.BLANK)
        apply_cel_style_to_shader(renderer.band_shader, &renderer.band_style, style, camera, rl.Matrix(1))
        scene_apply_lights(renderer.band_shader, &renderer.band_lights, scene)
        scene_apply_shadow_receiver(
            renderer.band_shader,
            &renderer.band_shadow,
            &shadow_frame,
            &scene.directional_light,
        )
        rl.BeginMode3D(camera)
            scene_draw_geometry(
                scene,
                resources,
                renderer.band_shader,
                renderer.cel_ramp_texture,
                renderer.shadow_target.depth,
            )
        rl.EndMode3D()
    rl.EndTextureMode()

    scene_source := rl.Rectangle{0, 0, SCENE_SCREEN_WIDTH, -SCENE_SCREEN_HEIGHT}
    rl.BeginTextureMode(renderer.downsample_target)
        rl.ClearBackground(rl.BLANK)
        rgl.DisableColorBlend()
        rl.BeginShaderMode(renderer.downscale_shader)
            rl.SetShaderValueTexture(renderer.downscale_shader, renderer.downscale_band_texture, renderer.band_target.texture)
            rl.DrawTexturePro(renderer.scene_target.texture, scene_source, {0, 0, f32(renderer.low_width), f32(renderer.low_height)}, {}, 0, rl.WHITE)
        rl.EndShaderMode()
        rgl.EnableColorBlend()
    rl.EndTextureMode()

    rl.BeginTextureMode(renderer.coverage_target)
        rl.ClearBackground(rl.BLANK)
        rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
            rl.BeginShaderMode(renderer.mask_shader)
                rl.DrawTexturePro(renderer.band_target.texture, scene_source, {0, 0, f32(renderer.low_width), f32(renderer.low_height)}, {}, 0, rl.WHITE)
            rl.EndShaderMode()
        rl.EndBlendMode()
    rl.EndTextureMode()

    low_source := rl.Rectangle{0, 0, f32(renderer.low_width), -f32(renderer.low_height)}
    rl.BeginTextureMode(renderer.outlined_target)
        rl.ClearBackground(rl.BLANK)
        rgl.DisableColorBlend()
        rl.BeginShaderMode(renderer.outline_shader)
            rl.SetShaderValueTexture(renderer.outline_shader, renderer.outline_coverage_texture, renderer.coverage_target.texture)
            rl.DrawTexturePro(renderer.downsample_target.texture, low_source, {0, 0, f32(renderer.low_width), f32(renderer.low_height)}, {}, 0, rl.WHITE)
        rl.EndShaderMode()
        rgl.EnableColorBlend()
    rl.EndTextureMode()

    rl.BeginTextureMode(renderer.composite_target)
        rl.ClearBackground(scene.render.background)
        rl.DrawTexturePro(renderer.outlined_target.texture, low_source, {0, 0, SCENE_SCREEN_WIDTH, SCENE_SCREEN_HEIGHT}, {}, 0, rl.WHITE)
    rl.EndTextureMode()
    return true
}

scene_capture_texture :: proc(
    renderer: ^Scene_Renderer,
    target: Capture_Target,
) -> rl.Texture2D {
    switch target {
    case .COMPOSITE:     return renderer.composite_target.texture
    case .SCENE:         return renderer.scene_target.texture
    case .DOWNSAMPLE:    return renderer.outlined_target.texture
    case .COVERAGE_MASK: return renderer.coverage_target.texture
    case .LENS:          return {}
    }
    return {}
}
