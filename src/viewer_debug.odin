package main

// Viewer render-pass debugging is deliberately drawn only in the native window
// pass. It can replace the interactive presentation without becoming part of
// composite captures or changing any authoritative RenderTexture output.

import "core:c"
import shared "./shared"
import rl "vendor:raylib"

VIEWER_DEBUG_FS_PATH :: "shaders/viewer_debug.fs"

Viewer_Render_Debug_Pass :: enum {
    SCENE_COLOR,
    CEL_BANDS,
    RAW_DOWNSAMPLE,
    COVERAGE,
    OUTLINED,
    COMPOSITE,
}

VIEWER_RENDER_DEBUG_PASSES := [?]Viewer_Render_Debug_Pass{
    .SCENE_COLOR,
    .CEL_BANDS,
    .RAW_DOWNSAMPLE,
    .COVERAGE,
    .OUTLINED,
    .COMPOSITE,
}

Viewer_Render_Debug_Display_Mode :: enum c.int {
    RGBA_CHECKERBOARD,
    CEL_METADATA,
    COVERAGE,
}

Viewer_Render_Debug_State :: struct {
    open:                 bool,
    selected:             Viewer_Render_Debug_Pass,
    pixel_grid_visible:   bool,
    frozen:               bool,
    resume_playback:      bool,
    sample_valid:         bool,
    sample_x:             c.int,
    sample_y:             c.int,
    sample_color:         rl.Color,
}

Viewer_Render_Debug_Frame :: struct {
    scene_color:   rl.Texture2D,
    cel_bands:     rl.Texture2D,
    raw_downsample: rl.Texture2D,
    coverage:      rl.Texture2D,
    outlined:      rl.Texture2D,
    composite:     rl.Texture2D,
}

viewer_render_debug_state_make :: proc() -> Viewer_Render_Debug_State {
    return {
        selected = .SCENE_COLOR,
        pixel_grid_visible = true,
    }
}

viewer_render_debug_pass_name :: proc(pass: Viewer_Render_Debug_Pass) -> cstring {
    switch pass {
    case .SCENE_COLOR:    return "Scene Color"
    case .CEL_BANDS:      return "Cel Bands"
    case .RAW_DOWNSAMPLE: return "Raw Downsample"
    case .COVERAGE:       return "Coverage"
    case .OUTLINED:       return "Outlined"
    case .COMPOSITE:      return "Composite"
    }
    return "Unknown"
}

viewer_render_debug_pass_inputs :: proc(pass: Viewer_Render_Debug_Pass) -> cstring {
    switch pass {
    case .SCENE_COLOR:    return "Input: geometry + cel style"
    case .CEL_BANDS:      return "Input: geometry + band classifiers"
    case .RAW_DOWNSAMPLE: return "Inputs: scene color + cel bands"
    case .COVERAGE:       return "Input: cel-band alpha"
    case .OUTLINED:       return "Inputs: raw downsample + coverage"
    case .COMPOSITE:      return "Inputs: scene + outlined lens + UI"
    }
    return ""
}

viewer_render_debug_pass_texture :: proc(
    frame: ^Viewer_Render_Debug_Frame,
    pass: Viewer_Render_Debug_Pass,
) -> (texture: rl.Texture2D, display_mode: Viewer_Render_Debug_Display_Mode) {
    if frame == nil {
        return
    }
    switch pass {
    case .SCENE_COLOR:
        texture = frame.scene_color
    case .CEL_BANDS:
        texture = frame.cel_bands
        display_mode = .CEL_METADATA
    case .RAW_DOWNSAMPLE:
        texture = frame.raw_downsample
    case .COVERAGE:
        texture = frame.coverage
        display_mode = .COVERAGE
    case .OUTLINED:
        texture = frame.outlined
    case .COMPOSITE:
        texture = frame.composite
    }
    return
}

// Preserve the source aspect ratio for future non-16:9 diagnostic targets.
viewer_render_debug_preview_bounds :: proc(
    texture_width, texture_height, screen_width, screen_height: c.int,
) -> rl.Rectangle {
    if texture_width <= 0 || texture_height <= 0 ||
       screen_width <= 0 || screen_height <= 0 {
        return {}
    }
    source_aspect := f32(texture_width) / f32(texture_height)
    screen_aspect := f32(screen_width) / f32(screen_height)
    width := f32(screen_width)
    height := f32(screen_height)
    if source_aspect > screen_aspect {
        height = width / source_aspect
    } else {
        width = height * source_aspect
    }
    return {
        (f32(screen_width) - width) * 0.5,
        (f32(screen_height) - height) * 0.5,
        width,
        height,
    }
}

// Map a top-left-oriented preview position to a logical RenderTexture pixel.
// GPU readback remains vertically inverted and is corrected only at sampling.
viewer_render_debug_preview_pixel :: proc(
    point: rl.Vector2,
    preview: rl.Rectangle,
    texture_width, texture_height: c.int,
) -> (x, y: c.int, valid: bool) {
    if texture_width <= 0 || texture_height <= 0 ||
       preview.width <= 0 || preview.height <= 0 ||
       !rl.CheckCollisionPointRec(point, preview) {
        return
    }
    normalized_x := (point.x - preview.x) / preview.width
    normalized_y := (point.y - preview.y) / preview.height
    x = min(c.int(normalized_x * f32(texture_width)), texture_width - 1)
    y = min(c.int(normalized_y * f32(texture_height)), texture_height - 1)
    valid = x >= 0 && y >= 0
    return
}

viewer_render_debug_panel_bounds :: proc() -> rl.Rectangle {
    return {12, 12, 360, 558}
}

viewer_render_debug_close :: proc(
    state: ^Viewer_Render_Debug_State,
    animation: ^shared.Animation_Playback,
) {
    if state == nil {
        return
    }
    if state.frozen && animation != nil {
        animation.is_playing = state.resume_playback
    }
    state.open = false
    state.frozen = false
    state.resume_playback = false
    state.sample_valid = false
}

viewer_render_debug_freeze_toggle :: proc(
    state: ^Viewer_Render_Debug_State,
    animation: ^shared.Animation_Playback,
) {
    if state == nil || animation == nil {
        return
    }
    if state.frozen {
        animation.is_playing = state.resume_playback
        state.frozen = false
        state.resume_playback = false
    } else {
        state.resume_playback = animation.is_playing
        animation.is_playing = false
        state.frozen = true
    }
}

viewer_render_debug_cycle_pass :: proc(
    state: ^Viewer_Render_Debug_State,
    direction: int,
) {
    if state == nil || direction == 0 {
        return
    }
    selected_index := 0
    for pass, pass_index in VIEWER_RENDER_DEBUG_PASSES {
        if pass == state.selected {
            selected_index = pass_index
            break
        }
    }
    pass_count := len(VIEWER_RENDER_DEBUG_PASSES)
    selected_index = (selected_index + direction) % pass_count
    if selected_index < 0 {
        selected_index += pass_count
    }
    state.selected = VIEWER_RENDER_DEBUG_PASSES[selected_index]
    state.sample_valid = false
}

// Divide a deterministic video into equal contiguous pass segments. Multiplying
// before division distributes any remainder while keeping the first and last
// output frames pinned to the first and last debugger passes.
viewer_render_debug_video_pass :: proc(
    output_frame_index, total_frames: u64,
) -> Viewer_Render_Debug_Pass {
    if total_frames == 0 {
        return .SCENE_COLOR
    }
    clamped_index := min(output_frame_index, total_frames - 1)
    pass_count := len(VIEWER_RENDER_DEBUG_PASSES)
    pass_index := min(
        int(clamped_index * u64(pass_count) / total_frames),
        pass_count - 1,
    )
    return VIEWER_RENDER_DEBUG_PASSES[pass_index]
}

viewer_render_debug_sample :: proc(
    state: ^Viewer_Render_Debug_State,
    texture: rl.Texture2D,
    logical_x, logical_y: c.int,
) {
    if state == nil || !rl.IsTextureValid(texture) ||
       logical_x < 0 || logical_x >= texture.width ||
       logical_y < 0 || logical_y >= texture.height {
        return
    }
    image := rl.LoadImageFromTexture(texture)
    if image.data == nil {
        return
    }
    defer rl.UnloadImage(image)
    readback_y := image.height - 1 - logical_y
    state.sample_color = rl.GetImageColor(image, logical_x, readback_y)
    state.sample_x = logical_x
    state.sample_y = logical_y
    state.sample_valid = true
}

viewer_render_debug_draw_pixel_grid :: proc(
    preview: rl.Rectangle,
    texture_width, texture_height: c.int,
) {
    if texture_width <= 0 || texture_height <= 0 {
        return
    }
    cell_width := preview.width / f32(texture_width)
    cell_height := preview.height / f32(texture_height)
    if min(cell_width, cell_height) < 4 {
        return
    }
    line_color := rl.Color{255, 255, 255, 34}
    for column := c.int(0); column <= texture_width; column += 1 {
        x := preview.x + f32(column) * cell_width
        rl.DrawLineV(
            {x, preview.y},
            {x, preview.y + preview.height},
            line_color,
        )
    }
    for row := c.int(0); row <= texture_height; row += 1 {
        y := preview.y + f32(row) * cell_height
        rl.DrawLineV(
            {preview.x, y},
            {preview.x + preview.width, y},
            line_color,
        )
    }
}

viewer_render_debug_draw :: proc(
    state: ^Viewer_Render_Debug_State,
    frame: ^Viewer_Render_Debug_Frame,
    display_shader: rl.Shader,
    display_mode_location: c.int,
    animation: ^shared.Animation_Playback,
    input_enabled: bool,
) {
    if state == nil || frame == nil || !state.open {
        return
    }

    if input_enabled {
        if rl.IsKeyPressed(.LEFT) {
            viewer_render_debug_cycle_pass(state, -1)
        }
        if rl.IsKeyPressed(.RIGHT) {
            viewer_render_debug_cycle_pass(state, 1)
        }
        if rl.IsKeyPressed(.SPACE) {
            viewer_render_debug_freeze_toggle(state, animation)
        }
    }

    texture, display_mode := viewer_render_debug_pass_texture(frame, state.selected)
    if !rl.IsTextureValid(texture) {
        rl.ClearBackground(rl.Color{15, 15, 18, 255})
        rl.DrawText("Selected pass texture is unavailable", 24, 24, 20, rl.RED)
        return
    }

    screen_width := c.int(rl.GetScreenWidth())
    screen_height := c.int(rl.GetScreenHeight())
    preview := viewer_render_debug_preview_bounds(
        texture.width,
        texture.height,
        screen_width,
        screen_height,
    )
    source := rl.Rectangle{0, 0, f32(texture.width), -f32(texture.height)}
    rl.ClearBackground(rl.Color{10, 10, 13, 255})
    display_mode_value := c.int(display_mode)
    rl.SetShaderValue(
        display_shader,
        display_mode_location,
        &display_mode_value,
        .INT,
    )
    rl.BeginShaderMode(display_shader)
        rl.DrawTexturePro(texture, source, preview, {}, 0, rl.WHITE)
    rl.EndShaderMode()

    if state.pixel_grid_visible {
        viewer_render_debug_draw_pixel_grid(
            preview,
            texture.width,
            texture.height,
        )
    }

    panel := viewer_render_debug_panel_bounds()
    mouse := rl.GetMousePosition()
    hover_x, hover_y, hover_valid := viewer_render_debug_preview_pixel(
        mouse,
        preview,
        texture.width,
        texture.height,
    )
    if input_enabled && hover_valid && !rl.CheckCollisionPointRec(mouse, panel) &&
       rl.IsMouseButtonPressed(.RIGHT) {
        viewer_render_debug_sample(state, texture, hover_x, hover_y)
    }

    rl.DrawRectangle(0, 0, screen_width, 4, rl.Color{232, 151, 38, 255})
    rl.GuiPanel(panel, "RENDER PASS DEBUGGER")
    if rl.GuiButton({panel.x + panel.width - 34, panel.y + 4, 26, 22}, "X") {
        viewer_render_debug_close(state, animation)
        return
    }

    list_x := panel.x + 10
    list_y := panel.y + 34
    list_width := panel.width - 20
    row_height: f32 = 44
    row_gap: f32 = 4
    for pass, pass_index in VIEWER_RENDER_DEBUG_PASSES {
        row_bounds := rl.Rectangle{
            list_x,
            list_y + f32(pass_index) * (row_height + row_gap),
            list_width,
            row_height,
        }
        selected := pass == state.selected
        hovered := input_enabled && rl.CheckCollisionPointRec(mouse, row_bounds)
        row_background := rl.Color{235, 235, 238, 255}
        row_border := rl.Color{154, 154, 162, 255}
        if hovered {
            row_background = rl.Color{225, 236, 243, 255}
            row_border = rl.Color{95, 145, 175, 255}
        }
        if selected {
            row_background = rl.Color{255, 244, 221, 255}
            row_border = rl.Color{232, 151, 38, 255}
        }
        rl.DrawRectangleRec(row_bounds, row_background)
        rl.DrawRectangleLinesEx(row_bounds, 1, row_border)
        rl.DrawRectangleRec(
            {row_bounds.x, row_bounds.y, 4, row_bounds.height},
            selected ? rl.Color{232, 151, 38, 255} :
                       rl.Color{132, 132, 142, 255},
        )
        rl.DrawText(
            rl.TextFormat("%02d", pass_index + 1),
            c.int(row_bounds.x + 13),
            c.int(row_bounds.y + 13),
            14,
            selected ? rl.Color{180, 105, 12, 255} :
                       rl.Color{92, 92, 102, 255},
        )
        rl.DrawText(
            viewer_render_debug_pass_name(pass),
            c.int(row_bounds.x + 46),
            c.int(row_bounds.y + 5),
            16,
            rl.Color{42, 42, 48, 255},
        )
        rl.DrawText(
            viewer_render_debug_pass_inputs(pass),
            c.int(row_bounds.x + 46),
            c.int(row_bounds.y + 24),
            12,
            rl.Color{92, 92, 102, 255},
        )
        if hovered && rl.IsMouseButtonPressed(.LEFT) {
            state.selected = pass
            state.sample_valid = false
        }
    }

    button_width := (panel.width - 30) * 0.5
    controls_y := list_y +
                  f32(len(VIEWER_RENDER_DEBUG_PASSES)) *
                  (row_height + row_gap) - row_gap + 10
    freeze_label: cstring = "Freeze"
    if state.frozen {
        freeze_label = "Resume"
    }
    if rl.GuiButton({panel.x + 10, controls_y, button_width, 26}, freeze_label) {
        viewer_render_debug_freeze_toggle(state, animation)
    }
    grid_label: cstring = "Grid: Off"
    if state.pixel_grid_visible {
        grid_label = "Grid: On"
    }
    if rl.GuiButton(
        {panel.x + 20 + button_width, controls_y, button_width, 26},
        grid_label,
    ) {
        state.pixel_grid_visible = !state.pixel_grid_visible
    }

    info_y := c.int(controls_y + 38)
    rl.DrawText(
        viewer_render_debug_pass_name(state.selected),
        c.int(panel.x + 12),
        info_y,
        18,
        rl.Color{232, 151, 38, 255},
    )
    rl.DrawText(
        rl.TextFormat("Resolution: %d x %d", texture.width, texture.height),
        c.int(panel.x + 12),
        info_y + 24,
        14,
        rl.Color{62, 62, 68, 255},
    )
    if hover_valid && !rl.CheckCollisionPointRec(mouse, panel) {
        rl.DrawText(
            rl.TextFormat("Hover: %d, %d", hover_x, hover_y),
            c.int(panel.x + 12),
            info_y + 46,
            14,
            rl.Color{38, 38, 44, 255},
        )
    } else {
        rl.DrawText(
            "Hover the image to inspect coordinates",
            c.int(panel.x + 12),
            info_y + 46,
            14,
            rl.Color{98, 98, 108, 255},
        )
    }

    if state.sample_valid {
        color := state.sample_color
        rl.DrawText(
            rl.TextFormat(
                "Sample %d,%d: RGBA %d %d %d %d",
                state.sample_x,
                state.sample_y,
                color.r,
                color.g,
                color.b,
                color.a,
            ),
            c.int(panel.x + 12),
            info_y + 68,
            14,
            rl.Color{38, 38, 44, 255},
        )
        if state.selected == .CEL_BANDS {
            band_id := c.int(color.r) - 1
            accent_bits := c.int(color.g)
            accent_label: cstring = "none"
            if accent_bits & 3 == 3 {
                accent_label = "rim + highlight"
            } else if accent_bits & 2 != 0 {
                accent_label = "highlight"
            } else if accent_bits & 1 != 0 {
                accent_label = "rim"
            }
            if color.a == 0 {
                rl.DrawText(
                    "Decoded: background",
                    c.int(panel.x + 12),
                    info_y + 90,
                    14,
                    rl.Color{98, 98, 108, 255},
                )
            } else {
                rl.DrawText(
                    rl.TextFormat("Decoded: band %d, %s", band_id, accent_label),
                    c.int(panel.x + 12),
                    info_y + 90,
                    14,
                    rl.Color{25, 112, 170, 255},
                )
            }
        } else if state.selected == .COVERAGE {
            rl.DrawText(
                rl.TextFormat("Decoded coverage: %.4f", f32(color.a) / 255),
                c.int(panel.x + 12),
                info_y + 90,
                14,
                rl.Color{25, 112, 170, 255},
            )
        }
    } else {
        rl.DrawText(
            "Right-click the image to sample RGBA",
            c.int(panel.x + 12),
            info_y + 68,
            14,
            rl.Color{98, 98, 108, 255},
        )
    }

    rl.DrawText(
        "Left/Right: pass  Space: freeze  F2/Esc: close",
        c.int(panel.x + 12),
        c.int(panel.y + panel.height - 22),
        13,
        rl.Color{82, 82, 92, 255},
    )
}
