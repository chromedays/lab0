package main

import json "core:encoding/json"
import "core:c"
import "core:math"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

MAX_CEL_BANDS :: 8
CEL_RAMP_WIDTH :: 256
CEL_BOUNDARY_MINIMUM_GAP :: f32(1.0 / 255.0)
CEL_STYLE_SCHEMA_VERSION :: 1

Cel_Light_Space :: enum {
    WORLD,
    CAMERA,
    MODEL,
}

Cel_Alpha_Mode :: enum {
    OPAQUE,
    MASK,
}

Cel_Band :: struct {
    upper_bound: f32,
    brightness:  f32,
    tint:        rl.Vector3,
    tint_mix:    f32,
}

Cel_Accent :: struct {
    enabled:          bool,
    color:            rl.Vector3,
    threshold:        f32,
    strength:         f32,
    preserve_samples: int,
}

Cel_Outline :: struct {
    width:              int,
    color:              rl.Color,
    coverage_threshold: f32,
}

Cel_Style :: struct {
    name:            string,
    name_owned:      bool,
    light_space:     Cel_Light_Space,
    light_direction: rl.Vector3,
    wrap_lighting:   f32,
    band_count:      int,
    bands:           [MAX_CEL_BANDS]Cel_Band,
    alpha_mode:      Cel_Alpha_Mode,
    alpha_cutoff:    f32,
    rim:             Cel_Accent,
    highlight:       Cel_Accent,
    outline:         Cel_Outline,
    revision:        u64,
}

Cel_Style_Error :: enum {
    NONE,
    READ_FAILED,
    PARSE_FAILED,
    WRITE_FAILED,
    INVALID_SCHEMA,
    INVALID_NAME,
    INVALID_LIGHT_SPACE,
    INVALID_LIGHT_DIRECTION,
    INVALID_WRAP,
    INVALID_BAND_COUNT,
    INVALID_BAND_BOUNDARY,
    INVALID_BAND_BRIGHTNESS,
    INVALID_BAND_TINT,
    INVALID_BAND_TINT_MIX,
    INVALID_ALPHA_MODE,
    INVALID_ALPHA_CUTOFF,
    INVALID_ACCENT,
    INVALID_OUTLINE,
}

Cel_Style_File_Light :: struct {
    space:     string,
    direction: [3]f32,
    wrap:      f32,
}

Cel_Style_File_Band :: struct {
    upper_bound: f32,
    brightness:  f32,
    tint:        [3]f32,
    tint_mix:    f32,
}

Cel_Style_File_Alpha :: struct {
    mode:   string,
    cutoff: f32,
}

Cel_Style_File_Accent :: struct {
    enabled:          bool,
    color:            [3]f32,
    threshold:        f32,
    strength:         f32,
    preserve_samples: int,
}

Cel_Style_File_Outline :: struct {
    width:              int,
    color:              [4]u8,
    coverage_threshold: f32,
}

Cel_Style_File :: struct {
    schema_version: int,
    name:           string,
    light:          Cel_Style_File_Light,
    bands:          [dynamic]Cel_Style_File_Band,
    alpha:          Cel_Style_File_Alpha,
    rim:            Cel_Style_File_Accent,
    highlight:      Cel_Style_File_Accent,
    outline:        Cel_Style_File_Outline,
}

Cel_Shader_Bindings :: struct {
    light_direction:       c.int,
    wrap_lighting:         c.int,
    cel_ramp:              c.int,
    band_brightness:       c.int,
    band_tint_mix:         c.int,
    alpha_mode:            c.int,
    alpha_cutoff:          c.int,
    view_position:         c.int,
    rim_enabled:           c.int,
    rim_color:             c.int,
    rim_threshold:         c.int,
    rim_strength:          c.int,
    highlight_enabled:     c.int,
    highlight_color:       c.int,
    highlight_threshold:   c.int,
    highlight_strength:    c.int,
}

make_classic_cel_style :: proc() -> Cel_Style {
    style := Cel_Style{
        name            = "Classic",
        light_space     = .WORLD,
        light_direction = {0.35, 0.80, 0.55},
        wrap_lighting   = 0,
        band_count      = 3,
        alpha_mode      = .MASK,
        alpha_cutoff    = 0.5,
        rim = {
            enabled = false,
            color = {1, 1, 1},
            threshold = 0.72,
            strength = 0.5,
            preserve_samples = 2,
        },
        highlight = {
            enabled = false,
            color = {1, 1, 1},
            threshold = 0.88,
            strength = 0.7,
            preserve_samples = 1,
        },
        outline = {
            width = 0,
            color = {0, 0, 0, 255},
            coverage_threshold = 0.25,
        },
        revision = 1,
    }
    style.bands[0] = {
        upper_bound = 0.25,
        brightness = 0.32,
        tint = {0, 0, 0},
        tint_mix = 0,
    }
    style.bands[1] = {
        upper_bound = 0.65,
        brightness = 0.62,
        tint = {0, 0, 0},
        tint_mix = 0,
    }
    style.bands[2] = {
        brightness = 1,
        tint = {1, 1, 1},
        tint_mix = 0,
    }
    return style
}

destroy_cel_style :: proc(style: ^Cel_Style) {
    if style.name_owned && len(style.name) > 0 {
        delete(style.name)
    }
    style^ = {}
}

cel_style_error_message :: proc(style_error: Cel_Style_Error) -> string {
    switch style_error {
    case .NONE:                    return ""
    case .READ_FAILED:             return "could not read the cel style"
    case .PARSE_FAILED:            return "could not parse the cel style JSON"
    case .WRITE_FAILED:            return "could not write the cel style"
    case .INVALID_SCHEMA:          return "unsupported cel style schema version"
    case .INVALID_NAME:            return "cel style name must not be empty"
    case .INVALID_LIGHT_SPACE:     return "cel light space must be world, camera, or model"
    case .INVALID_LIGHT_DIRECTION: return "cel light direction must be finite and non-zero"
    case .INVALID_WRAP:            return "cel wrap lighting must be from 0 through 1"
    case .INVALID_BAND_COUNT:      return "cel style must contain from 2 through 8 bands"
    case .INVALID_BAND_BOUNDARY:   return "cel band boundaries must increase by at least 1/255"
    case .INVALID_BAND_BRIGHTNESS: return "cel band brightness must be from 0 through 2"
    case .INVALID_BAND_TINT:       return "cel band tint components must be from 0 through 1"
    case .INVALID_BAND_TINT_MIX:   return "cel band tint mix must be from 0 through 1"
    case .INVALID_ALPHA_MODE:      return "cel alpha mode must be opaque or mask"
    case .INVALID_ALPHA_CUTOFF:    return "cel alpha cutoff must be from 0 through 1"
    case .INVALID_ACCENT:          return "cel accent settings are outside their valid ranges"
    case .INVALID_OUTLINE:         return "cel outline settings are outside their valid ranges"
    }
    return "invalid cel style"
}

cel_f32_is_finite :: proc(value: f32) -> bool {
    return !math.is_nan(value) && !math.is_inf(value)
}

cel_unit_value_is_valid :: proc(value: f32) -> bool {
    return cel_f32_is_finite(value) && value >= 0 && value <= 1
}

cel_color_is_valid :: proc(color: rl.Vector3) -> bool {
    return cel_unit_value_is_valid(color.x) &&
           cel_unit_value_is_valid(color.y) &&
           cel_unit_value_is_valid(color.z)
}

validate_cel_accent :: proc(accent: Cel_Accent) -> bool {
    return cel_color_is_valid(accent.color) &&
           cel_unit_value_is_valid(accent.threshold) &&
           cel_f32_is_finite(accent.strength) &&
           accent.strength >= 0 && accent.strength <= 2 &&
           accent.preserve_samples >= 1 && accent.preserve_samples <= 16
}

validate_cel_style :: proc(style: ^Cel_Style) -> Cel_Style_Error {
    if len(strings.trim_space(style.name)) == 0 {
        return .INVALID_NAME
    }
    if style.light_space < .WORLD || style.light_space > .MODEL {
        return .INVALID_LIGHT_SPACE
    }
    direction := style.light_direction
    direction_length_squared := direction.x * direction.x +
                                direction.y * direction.y +
                                direction.z * direction.z
    if !cel_f32_is_finite(direction.x) ||
       !cel_f32_is_finite(direction.y) ||
       !cel_f32_is_finite(direction.z) ||
       !cel_f32_is_finite(direction_length_squared) ||
       direction_length_squared <= 0.000001 {
        return .INVALID_LIGHT_DIRECTION
    }
    if !cel_unit_value_is_valid(style.wrap_lighting) {
        return .INVALID_WRAP
    }
    if style.band_count < 2 || style.band_count > MAX_CEL_BANDS {
        return .INVALID_BAND_COUNT
    }

    previous_boundary := f32(-CEL_BOUNDARY_MINIMUM_GAP)
    for band_index := 0; band_index < style.band_count; band_index += 1 {
        band := style.bands[band_index]
        if !cel_f32_is_finite(band.brightness) ||
           band.brightness < 0 || band.brightness > 2 {
            return .INVALID_BAND_BRIGHTNESS
        }
        if !cel_color_is_valid(band.tint) {
            return .INVALID_BAND_TINT
        }
        if !cel_unit_value_is_valid(band.tint_mix) {
            return .INVALID_BAND_TINT_MIX
        }
        if band_index < style.band_count - 1 {
            if !cel_unit_value_is_valid(band.upper_bound) ||
               band.upper_bound - previous_boundary < CEL_BOUNDARY_MINIMUM_GAP {
                return .INVALID_BAND_BOUNDARY
            }
            previous_boundary = band.upper_bound
        }
    }

    if style.alpha_mode < .OPAQUE || style.alpha_mode > .MASK {
        return .INVALID_ALPHA_MODE
    }
    if !cel_unit_value_is_valid(style.alpha_cutoff) {
        return .INVALID_ALPHA_CUTOFF
    }
    if !validate_cel_accent(style.rim) ||
       !validate_cel_accent(style.highlight) {
        return .INVALID_ACCENT
    }
    if style.outline.width < 0 || style.outline.width > 3 ||
       !cel_unit_value_is_valid(style.outline.coverage_threshold) {
        return .INVALID_OUTLINE
    }
    return .NONE
}

cel_band_for_diffuse :: proc(style: ^Cel_Style, diffuse: f32) -> int {
    clamped_diffuse := clamp(diffuse, f32(0), f32(1))
    for band_index := 0; band_index < style.band_count - 1; band_index += 1 {
        if clamped_diffuse <= style.bands[band_index].upper_bound {
            return band_index
        }
    }
    return style.band_count - 1
}

cel_color_component_to_byte :: proc(value: f32) -> u8 {
    return u8(math.round(clamp(value, f32(0), f32(1)) * 255))
}

build_cel_ramp_pixels :: proc(style: ^Cel_Style) -> [CEL_RAMP_WIDTH]rl.Color {
    pixels: [CEL_RAMP_WIDTH]rl.Color
    for &pixel, pixel_index in pixels {
        diffuse := f32(pixel_index) / f32(CEL_RAMP_WIDTH - 1)
        band_index := cel_band_for_diffuse(style, diffuse)
        tint := style.bands[band_index].tint
        pixel = {
            cel_color_component_to_byte(tint.x),
            cel_color_component_to_byte(tint.y),
            cel_color_component_to_byte(tint.z),
            u8(band_index + 1),
        }
    }
    return pixels
}

load_cel_ramp_texture :: proc(style: ^Cel_Style) -> rl.Texture2D {
    pixels := build_cel_ramp_pixels(style)
    image := rl.Image{
        data = raw_data(pixels[:]),
        width = CEL_RAMP_WIDTH,
        height = 1,
        mipmaps = 1,
        format = .UNCOMPRESSED_R8G8B8A8,
    }
    texture := rl.LoadTextureFromImage(image)
    if rl.IsTextureValid(texture) {
        rl.SetTextureFilter(texture, .POINT)
        rl.SetTextureWrap(texture, .CLAMP)
    }
    return texture
}

update_cel_ramp_texture :: proc(texture: rl.Texture2D, style: ^Cel_Style) {
    pixels := build_cel_ramp_pixels(style)
    rl.UpdateTexture(texture, raw_data(pixels[:]))
}

resolve_cel_shader_bindings :: proc(shader: rl.Shader) -> Cel_Shader_Bindings {
    bindings := Cel_Shader_Bindings{
        light_direction = rl.GetShaderLocation(shader, "u_light_direction"),
        wrap_lighting = rl.GetShaderLocation(shader, "u_wrap_lighting"),
        cel_ramp = rl.GetShaderLocation(shader, "u_cel_ramp"),
        band_brightness = rl.GetShaderLocation(shader, "u_band_brightness[0]"),
        band_tint_mix = rl.GetShaderLocation(shader, "u_band_tint_mix[0]"),
        alpha_mode = rl.GetShaderLocation(shader, "u_alpha_mode"),
        alpha_cutoff = rl.GetShaderLocation(shader, "u_alpha_cutoff"),
        view_position = rl.GetShaderLocation(shader, "u_view_position"),
        rim_enabled = rl.GetShaderLocation(shader, "u_rim_enabled"),
        rim_color = rl.GetShaderLocation(shader, "u_rim_color"),
        rim_threshold = rl.GetShaderLocation(shader, "u_rim_threshold"),
        rim_strength = rl.GetShaderLocation(shader, "u_rim_strength"),
        highlight_enabled = rl.GetShaderLocation(shader, "u_highlight_enabled"),
        highlight_color = rl.GetShaderLocation(shader, "u_highlight_color"),
        highlight_threshold = rl.GetShaderLocation(shader, "u_highlight_threshold"),
        highlight_strength = rl.GetShaderLocation(shader, "u_highlight_strength"),
    }
    // DrawMesh owns material sampler binding. Reserve the copied material's
    // emission map slot for the cel ramp so it is active with this shader.
    shader.locs[rl.ShaderLocationIndex.MAP_EMISSION] = bindings.cel_ramp
    return bindings
}

compute_world_cel_light_direction :: proc(
    style: ^Cel_Style,
    camera: rl.Camera3D,
    model_transform: rl.Matrix,
) -> rl.Vector3 {
    direction := style.light_direction
    switch style.light_space {
    case .WORLD:
    case .CAMERA:
        camera_back := rl.Vector3Normalize(camera.position - camera.target)
        camera_right := rl.Vector3Normalize(
            rl.Vector3CrossProduct(camera.up, camera_back),
        )
        camera_up := rl.Vector3Normalize(
            rl.Vector3CrossProduct(camera_back, camera_right),
        )
        direction = camera_right * direction.x +
                    camera_up * direction.y +
                    camera_back * direction.z
    case .MODEL:
        transformed_origin := rl.Vector3Transform({}, model_transform)
        transformed_direction := rl.Vector3Transform(direction, model_transform)
        direction = transformed_direction - transformed_origin
    }
    return rl.Vector3Normalize(direction)
}

apply_cel_style_to_shader :: proc(
    shader: rl.Shader,
    bindings: ^Cel_Shader_Bindings,
    style: ^Cel_Style,
    camera: rl.Camera3D,
    model_transform: rl.Matrix,
) {
    light_direction := compute_world_cel_light_direction(
        style,
        camera,
        model_transform,
    )
    brightness: [MAX_CEL_BANDS]f32
    tint_mix: [MAX_CEL_BANDS]f32
    for band_index := 0; band_index < MAX_CEL_BANDS; band_index += 1 {
        brightness[band_index] = style.bands[band_index].brightness
        tint_mix[band_index] = style.bands[band_index].tint_mix
    }
    alpha_mode := c.int(style.alpha_mode)
    view_position := camera.position
    rim_enabled := c.int(0)
    if style.rim.enabled {
        rim_enabled = 1
    }
    highlight_enabled := c.int(0)
    if style.highlight.enabled {
        highlight_enabled = 1
    }

    rl.SetShaderValue(shader, bindings.light_direction, &light_direction, .VEC3)
    rl.SetShaderValue(shader, bindings.wrap_lighting, &style.wrap_lighting, .FLOAT)
    rl.SetShaderValueV(
        shader,
        bindings.band_brightness,
        raw_data(brightness[:]),
        .FLOAT,
        MAX_CEL_BANDS,
    )
    rl.SetShaderValueV(
        shader,
        bindings.band_tint_mix,
        raw_data(tint_mix[:]),
        .FLOAT,
        MAX_CEL_BANDS,
    )
    rl.SetShaderValue(shader, bindings.alpha_mode, &alpha_mode, .INT)
    rl.SetShaderValue(shader, bindings.alpha_cutoff, &style.alpha_cutoff, .FLOAT)
    rl.SetShaderValue(shader, bindings.view_position, &view_position, .VEC3)
    rl.SetShaderValue(shader, bindings.rim_enabled, &rim_enabled, .INT)
    rl.SetShaderValue(shader, bindings.rim_color, &style.rim.color, .VEC3)
    rl.SetShaderValue(shader, bindings.rim_threshold, &style.rim.threshold, .FLOAT)
    rl.SetShaderValue(shader, bindings.rim_strength, &style.rim.strength, .FLOAT)
    rl.SetShaderValue(
        shader,
        bindings.highlight_enabled,
        &highlight_enabled,
        .INT,
    )
    rl.SetShaderValue(shader, bindings.highlight_color, &style.highlight.color, .VEC3)
    rl.SetShaderValue(
        shader,
        bindings.highlight_threshold,
        &style.highlight.threshold,
        .FLOAT,
    )
    rl.SetShaderValue(
        shader,
        bindings.highlight_strength,
        &style.highlight.strength,
        .FLOAT,
    )
}

destroy_cel_style_file :: proc(style_file: ^Cel_Style_File) {
    if len(style_file.name) > 0 {
        delete(style_file.name)
    }
    if len(style_file.light.space) > 0 {
        delete(style_file.light.space)
    }
    if len(style_file.alpha.mode) > 0 {
        delete(style_file.alpha.mode)
    }
    delete(style_file.bands)
    style_file^ = {}
}

parse_cel_light_space :: proc(value: string) -> (Cel_Light_Space, bool) {
    if value == "world"  { return .WORLD, true }
    if value == "camera" { return .CAMERA, true }
    if value == "model"  { return .MODEL, true }
    return {}, false
}

cel_light_space_string :: proc(value: Cel_Light_Space) -> string {
    switch value {
    case .WORLD:  return "world"
    case .CAMERA: return "camera"
    case .MODEL:  return "model"
    }
    return "world"
}

parse_cel_alpha_mode :: proc(value: string) -> (Cel_Alpha_Mode, bool) {
    if value == "opaque" { return .OPAQUE, true }
    if value == "mask"   { return .MASK, true }
    return {}, false
}

cel_alpha_mode_string :: proc(value: Cel_Alpha_Mode) -> string {
    if value == .OPAQUE {
        return "opaque"
    }
    return "mask"
}

cel_accent_from_file :: proc(value: Cel_Style_File_Accent) -> Cel_Accent {
    return {
        enabled = value.enabled,
        color = {value.color[0], value.color[1], value.color[2]},
        threshold = value.threshold,
        strength = value.strength,
        preserve_samples = value.preserve_samples,
    }
}

cel_accent_to_file :: proc(value: Cel_Accent) -> Cel_Style_File_Accent {
    return {
        enabled = value.enabled,
        color = {value.color.x, value.color.y, value.color.z},
        threshold = value.threshold,
        strength = value.strength,
        preserve_samples = value.preserve_samples,
    }
}

cel_style_from_file :: proc(style_file: ^Cel_Style_File) -> (
    Cel_Style,
    Cel_Style_Error,
) {
    if style_file.schema_version != CEL_STYLE_SCHEMA_VERSION {
        return {}, .INVALID_SCHEMA
    }
    light_space, light_space_valid := parse_cel_light_space(style_file.light.space)
    if !light_space_valid {
        return {}, .INVALID_LIGHT_SPACE
    }
    alpha_mode, alpha_mode_valid := parse_cel_alpha_mode(style_file.alpha.mode)
    if !alpha_mode_valid {
        return {}, .INVALID_ALPHA_MODE
    }

    style := Cel_Style{
        name = strings.clone(style_file.name),
        name_owned = true,
        light_space = light_space,
        light_direction = {
            style_file.light.direction[0],
            style_file.light.direction[1],
            style_file.light.direction[2],
        },
        wrap_lighting = style_file.light.wrap,
        band_count = len(style_file.bands),
        alpha_mode = alpha_mode,
        alpha_cutoff = style_file.alpha.cutoff,
        rim = cel_accent_from_file(style_file.rim),
        highlight = cel_accent_from_file(style_file.highlight),
        outline = {
            width = style_file.outline.width,
            color = {
                style_file.outline.color[0],
                style_file.outline.color[1],
                style_file.outline.color[2],
                style_file.outline.color[3],
            },
            coverage_threshold = style_file.outline.coverage_threshold,
        },
        revision = 1,
    }
    if style.band_count <= MAX_CEL_BANDS {
        for band, band_index in style_file.bands {
            style.bands[band_index] = {
                upper_bound = band.upper_bound,
                brightness = band.brightness,
                tint = {band.tint[0], band.tint[1], band.tint[2]},
                tint_mix = band.tint_mix,
            }
        }
    }
    if validation_error := validate_cel_style(&style);
       validation_error != .NONE {
        destroy_cel_style(&style)
        return {}, validation_error
    }
    return style, .NONE
}

load_cel_style :: proc(path: string) -> (Cel_Style, Cel_Style_Error) {
    file_data, read_error := os.read_entire_file(path, context.allocator)
    if read_error != nil {
        return {}, .READ_FAILED
    }
    defer delete(file_data)

    style_file: Cel_Style_File
    unmarshal_error := json.unmarshal(file_data, &style_file, spec = .JSON)
    if unmarshal_error != nil {
        destroy_cel_style_file(&style_file)
        return {}, .PARSE_FAILED
    }
    defer destroy_cel_style_file(&style_file)
    return cel_style_from_file(&style_file)
}

cel_style_to_file :: proc(style: ^Cel_Style) -> Cel_Style_File {
    style_file := Cel_Style_File{
        schema_version = CEL_STYLE_SCHEMA_VERSION,
        name = style.name,
        light = {
            space = cel_light_space_string(style.light_space),
            direction = {
                style.light_direction.x,
                style.light_direction.y,
                style.light_direction.z,
            },
            wrap = style.wrap_lighting,
        },
        alpha = {
            mode = cel_alpha_mode_string(style.alpha_mode),
            cutoff = style.alpha_cutoff,
        },
        rim = cel_accent_to_file(style.rim),
        highlight = cel_accent_to_file(style.highlight),
        outline = {
            width = style.outline.width,
            color = {
                style.outline.color.r,
                style.outline.color.g,
                style.outline.color.b,
                style.outline.color.a,
            },
            coverage_threshold = style.outline.coverage_threshold,
        },
    }
    for band_index := 0; band_index < style.band_count; band_index += 1 {
        band := style.bands[band_index]
        append(&style_file.bands, Cel_Style_File_Band{
            upper_bound = band.upper_bound,
            brightness = band.brightness,
            tint = {band.tint.x, band.tint.y, band.tint.z},
            tint_mix = band.tint_mix,
        })
    }
    return style_file
}

save_cel_style :: proc(path: string, style: ^Cel_Style) -> Cel_Style_Error {
    if validation_error := validate_cel_style(style); validation_error != .NONE {
        return validation_error
    }
    style_file := cel_style_to_file(style)
    defer delete(style_file.bands)
    encoded, marshal_error := json.marshal(
        style_file,
        {spec = .JSON, pretty = true, use_spaces = true, spaces = 2},
    )
    if marshal_error != nil {
        return .WRITE_FAILED
    }
    defer delete(encoded)
    if write_error := os.write_entire_file(path, encoded); write_error != nil {
        return .WRITE_FAILED
    }
    return .NONE
}

replace_cel_style :: proc(destination: ^Cel_Style, replacement: Cel_Style) {
    next_revision := destination.revision + 1
    destroy_cel_style(destination)
    destination^ = replacement
    destination.revision = max(replacement.revision, next_revision)
}
