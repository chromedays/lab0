package main

import "core:c"
import "core:log"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

CEL_STYLE_PRESET_OPTIONS :: "Classic;Anime;Noir"

CEL_STYLE_PRESET_PATHS := [?]string{
    "styles/classic.json",
    "styles/anime.json",
    "styles/noir.json",
}

INSPECTOR_SECTION_HEADER_HEIGHT :: f32(28)
INSPECTOR_SECTION_GAP           :: f32(6)
CEL_SUBSECTION_HEADER_HEIGHT    :: f32(26)

Cel_Style_UI_Status :: enum {
    NONE,
    LOADED,
    SAVED,
    RESET,
    LOAD_FAILED,
    SAVE_FAILED,
}

Cel_Color_Target :: enum {
    NONE,
    BAND_TINT,
    RIM,
    HIGHLIGHT,
    OUTLINE,
}

Cel_Style_UI_State :: struct {
    open:               bool,
    light_open:         bool,
    bands_open:         bool,
    accents_open:       bool,
    outline_open:       bool,
    color_target:       Cel_Color_Target,
    preset_index:       c.int,
    selected_band:      c.int,
    light_azimuth:      f32,
    light_elevation:    f32,
    light_angles_valid: bool,
    dirty:              bool,
    status:             Cel_Style_UI_Status,
    status_time:        f64,
}

Inspector_UI_State :: struct {
    scroll_y:              f32,
    scrollbar_dragging:    bool,
    scrollbar_drag_offset: f32,
    model_open:            bool,
    camera_open:           bool,
    background_open:       bool,
}

cel_style_ui_status_text :: proc(status: Cel_Style_UI_Status) -> cstring {
    switch status {
    case .NONE:        return "Changes apply immediately"
    case .LOADED:      return "Preset loaded"
    case .SAVED:       return "Preset saved"
    case .RESET:       return "Reset to built-in Classic"
    case .LOAD_FAILED: return "Preset load failed; current style kept"
    case .SAVE_FAILED: return "Preset save failed"
    }
    return ""
}

set_cel_style_ui_status :: proc(
    state: ^Cel_Style_UI_State,
    status: Cel_Style_UI_Status,
) {
    state.status = status
    state.status_time = rl.GetTime()
}

sync_cel_style_light_angles :: proc(
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) {
    direction := rl.Vector3Normalize(style.light_direction)
    radians_to_degrees := f32(180.0 / math.PI)
    state.light_azimuth = math.atan2(direction.z, direction.x) *
                          radians_to_degrees
    state.light_elevation = math.asin(clamp(direction.y, f32(-1), f32(1))) *
                            radians_to_degrees
    state.light_angles_valid = true
}

update_cel_style_direction_from_angles :: proc(
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) {
    degrees_to_radians := f32(math.PI / 180.0)
    azimuth := state.light_azimuth * degrees_to_radians
    elevation := state.light_elevation * degrees_to_radians
    elevation_cosine := math.cos(elevation)
    style.light_direction = {
        elevation_cosine * math.cos(azimuth),
        math.sin(elevation),
        elevation_cosine * math.sin(azimuth),
    }
}

cel_vector_color_to_raylib :: proc(color: rl.Vector3) -> rl.Color {
    return {
        cel_color_component_to_byte(color.x),
        cel_color_component_to_byte(color.y),
        cel_color_component_to_byte(color.z),
        255,
    }
}

cel_raylib_color_to_vector :: proc(color: rl.Color) -> rl.Vector3 {
    return {
        f32(color.r) / 255,
        f32(color.g) / 255,
        f32(color.b) / 255,
    }
}

mark_cel_style_edited :: proc(
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) {
    style.revision += 1
    state.dirty = true
    state.status = .NONE
}

load_selected_cel_style_preset :: proc(
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) -> bool {
    preset_index := clamp(int(state.preset_index), 0, len(CEL_STYLE_PRESET_PATHS) - 1)
    replacement, load_error := load_cel_style(CEL_STYLE_PRESET_PATHS[preset_index])
    if load_error != .NONE {
        log.errorf(
            "Failed to load cel style preset %s: %s",
            CEL_STYLE_PRESET_PATHS[preset_index],
            cel_style_error_message(load_error),
        )
        set_cel_style_ui_status(state, .LOAD_FAILED)
        return false
    }
    replace_cel_style(style, replacement)
    state.selected_band = 0
    state.dirty = false
    sync_cel_style_light_angles(state, style)
    set_cel_style_ui_status(state, .LOADED)
    return true
}

save_selected_cel_style_preset :: proc(
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) -> bool {
    preset_index := clamp(int(state.preset_index), 0, len(CEL_STYLE_PRESET_PATHS) - 1)
    save_error := save_cel_style(CEL_STYLE_PRESET_PATHS[preset_index], style)
    if save_error != .NONE {
        log.errorf(
            "Failed to save cel style preset %s: %s",
            CEL_STYLE_PRESET_PATHS[preset_index],
            cel_style_error_message(save_error),
        )
        set_cel_style_ui_status(state, .SAVE_FAILED)
        return false
    }
    state.dirty = false
    set_cel_style_ui_status(state, .SAVED)
    return true
}

reset_cel_style_to_classic :: proc(
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) {
    replacement := make_classic_cel_style()
    replace_cel_style(style, replacement)
    state.preset_index = 0
    state.selected_band = 0
    state.dirty = true
    state.color_target = .NONE
    sync_cel_style_light_angles(state, style)
    set_cel_style_ui_status(state, .RESET)
}

add_cel_band_after :: proc(style: ^Cel_Style, selected_band: int) -> bool {
    if style.band_count >= MAX_CEL_BANDS {
        return false
    }
    selected := clamp(selected_band, 0, style.band_count - 1)
    lower_bound := f32(0)
    if selected > 0 {
        lower_bound = style.bands[selected - 1].upper_bound
    }
    upper_bound := f32(1)
    if selected < style.band_count - 1 {
        upper_bound = style.bands[selected].upper_bound
    }
    split_bound := (lower_bound + upper_bound) * 0.5
    if split_bound - lower_bound < CEL_BOUNDARY_MINIMUM_GAP ||
       upper_bound - split_bound < CEL_BOUNDARY_MINIMUM_GAP {
        return false
    }

    original_band := style.bands[selected]
    for band_index := style.band_count; band_index > selected + 1; band_index -= 1 {
        style.bands[band_index] = style.bands[band_index - 1]
    }
    style.bands[selected].upper_bound = split_bound
    style.bands[selected + 1] = original_band
    style.band_count += 1
    return true
}

remove_cel_band :: proc(style: ^Cel_Style, selected_band: int) -> bool {
    if style.band_count <= 2 {
        return false
    }
    selected := clamp(selected_band, 0, style.band_count - 1)
    if selected > 0 && selected < style.band_count - 1 {
        style.bands[selected - 1].upper_bound =
            style.bands[selected].upper_bound
    }
    for band_index := selected; band_index < style.band_count - 1; band_index += 1 {
        style.bands[band_index] = style.bands[band_index + 1]
    }
    style.bands[style.band_count - 1] = {}
    style.band_count -= 1
    return true
}

draw_collapsible_header :: proc(
    id: UI_Focus_ID,
    bounds: rl.Rectangle,
    title: cstring,
    expanded: ^bool,
) {
    label: cstring
    if expanded^ {
        label = rl.TextFormat("-  %s", title)
    } else {
        label = rl.TextFormat("+  %s", title)
    }
    if ui_gui_button(
        id,
        {bounds.x + 3, bounds.y + 3, bounds.width - 6, bounds.height - 6},
        label,
    ) {
        expanded^ = !expanded^
    }
}

draw_cel_style_slider :: proc(
    id: UI_Focus_ID,
    x, y, width: f32,
    label: cstring,
    value: ^f32,
    minimum, maximum: f32,
    step, coarse_step: f32,
) -> bool {
    label_width := min(f32(104), width * 0.38)
    value_width: f32 = 48
    slider_x := x + label_width + 4
    slider_width := max(width - label_width - value_width - 8, f32(24))
    rl.GuiLabel({x, y, label_width, 20}, label)
    previous := value^
    changed := ui_gui_slider_bar(
        id,
        {slider_x, y, slider_width, 20},
        nil,
        nil,
        value,
        minimum,
        maximum,
        step,
        coarse_step,
    )
    rl.GuiLabel(
        {x + width - value_width, y, value_width, 20},
        rl.TextFormat("%.2f", value^),
    )
    return changed || value^ != previous
}

draw_cel_color_swatch :: proc(
    id: UI_Focus_ID,
    x, y, width: f32,
    label: cstring,
    color: rl.Color,
    target: Cel_Color_Target,
    state: ^Cel_Style_UI_State,
) {
    rl.GuiLabel({x, y, 104, 22}, label)
    swatch_bounds := rl.Rectangle{x + 108, y, 52, 22}
    if ui_gui_button(id, swatch_bounds, nil) {
        if state.color_target == target {
            state.color_target = .NONE
        } else {
            state.color_target = target
            switch target {
            case .BAND_TINT: ui_keyboard_set_focus(.CEL_BAND_TINT_PICKER)
            case .RIM:       ui_keyboard_set_focus(.CEL_RIM_PICKER)
            case .HIGHLIGHT: ui_keyboard_set_focus(.CEL_HIGHLIGHT_PICKER)
            case .OUTLINE:   ui_keyboard_set_focus(.CEL_OUTLINE_PICKER)
            case .NONE:
            }
        }
    }
    rl.DrawRectangleRec(
        {swatch_bounds.x + 3, swatch_bounds.y + 3, swatch_bounds.width - 6, swatch_bounds.height - 6},
        color,
    )
    rl.DrawRectangleLinesEx(swatch_bounds, 1, rl.GRAY)
    rl.GuiLabel(
        {x + 168, y, max(width - 168, f32(0)), 22},
        rl.TextFormat("%d %d %d", color.r, color.g, color.b),
    )
}

draw_cel_ramp_preview :: proc(bounds: rl.Rectangle, style: ^Cel_Style) {
    lower_bound := f32(0)
    for band_index := 0; band_index < style.band_count; band_index += 1 {
        band := style.bands[band_index]
        upper_bound := f32(1)
        if band_index < style.band_count - 1 {
            upper_bound = band.upper_bound
        }
        base := rl.Vector3{1, 1, 1} * band.brightness
        tinted := band.tint * band.brightness
        preview := base * (1 - band.tint_mix) + tinted * band.tint_mix
        color := rl.Color{
            cel_color_component_to_byte(preview.x),
            cel_color_component_to_byte(preview.y),
            cel_color_component_to_byte(preview.z),
            255,
        }
        band_x := bounds.x + lower_bound * bounds.width
        band_width := max((upper_bound - lower_bound) * bounds.width, f32(1))
        rl.DrawRectangleRec(
            {band_x, bounds.y, band_width, bounds.height},
            color,
        )
        lower_bound = upper_bound
    }
    rl.DrawRectangleLinesEx(bounds, 1, rl.GRAY)
}

cel_style_light_content_height :: proc() -> f32 {
    return 146
}

cel_style_bands_content_height :: proc(
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) -> f32 {
    height: f32 = 32 + 28
    selected := clamp(int(state.selected_band), 0, style.band_count - 1)
    if selected < style.band_count - 1 {
        height += 28
    }
    height += 28 + 28 + 28
    if state.color_target == .BAND_TINT {
        height += 158
    }
    height += 30
    if style.alpha_mode == .MASK {
        height += 28
    }
    return height
}

cel_accent_block_height :: proc(
    state: ^Cel_Style_UI_State,
    target: Cel_Color_Target,
) -> f32 {
    height: f32 = 22 + 28 + 28 + 30 + 32
    if state.color_target == target {
        height += 134
    }
    return height
}

cel_style_accents_content_height :: proc(state: ^Cel_Style_UI_State) -> f32 {
    return cel_accent_block_height(state, .RIM) +
           cel_accent_block_height(state, .HIGHLIGHT) + 8
}

cel_style_outline_content_height :: proc(state: ^Cel_Style_UI_State) -> f32 {
    height: f32 = 32 + 28 + 32 + 28
    if state.color_target == .OUTLINE {
        height += 168
    }
    return height
}

cel_subsection_height :: proc(open: bool, content_height: f32) -> f32 {
    if !open {
        return CEL_SUBSECTION_HEADER_HEIGHT
    }
    return CEL_SUBSECTION_HEADER_HEIGHT + 8 + content_height + 8
}

cel_style_editor_height :: proc(
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) -> f32 {
    if !state.open {
        return INSPECTOR_SECTION_HEADER_HEIGHT
    }

    height := INSPECTOR_SECTION_HEADER_HEIGHT + f32(90)
    height += cel_subsection_height(
        state.light_open,
        cel_style_light_content_height(),
    ) + INSPECTOR_SECTION_GAP
    height += cel_subsection_height(
        state.bands_open,
        cel_style_bands_content_height(state, style),
    ) + INSPECTOR_SECTION_GAP
    height += cel_subsection_height(
        state.accents_open,
        cel_style_accents_content_height(state),
    ) + INSPECTOR_SECTION_GAP
    height += cel_subsection_height(
        state.outline_open,
        cel_style_outline_content_height(state),
    ) + INSPECTOR_SECTION_GAP
    return height + 28
}

draw_cel_style_light_content :: proc(
    x, y, width: f32,
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) -> bool {
    changed := false
    cursor_y := y
    if !state.light_angles_valid {
        sync_cel_style_light_angles(state, style)
    }

    rl.GuiLabel({x, cursor_y, 104, 22}, "Light space")
    light_space := c.int(style.light_space)
    previous_light_space := light_space
    _ = ui_gui_combo_box(
        .CEL_LIGHT_SPACE,
        {x + 108, cursor_y, width - 108, 22},
        "World;Camera;Model",
        &light_space,
        3,
    )
    if light_space != previous_light_space {
        style.light_space = Cel_Light_Space(light_space)
        changed = true
    }
    cursor_y += 30
    if draw_cel_style_slider(
        .CEL_LIGHT_AZIMUTH,
        x, cursor_y, width, "Azimuth", &state.light_azimuth, -180, 180, 1, 10,
    ) {
        update_cel_style_direction_from_angles(state, style)
        changed = true
    }
    cursor_y += 28
    if draw_cel_style_slider(
        .CEL_LIGHT_ELEVATION,
        x, cursor_y, width, "Elevation", &state.light_elevation, -89, 89, 1, 10,
    ) {
        update_cel_style_direction_from_angles(state, style)
        changed = true
    }
    cursor_y += 28
    changed = draw_cel_style_slider(
        .CEL_LIGHT_WRAP,
        x, cursor_y, width, "Wrap lighting", &style.wrap_lighting, 0, 1, 0.01, 0.1,
    ) || changed
    cursor_y += 28
    rl.GuiLabel(
        {x, cursor_y, width, 32},
        "Direction points from the surface toward the light.",
    )
    return changed
}

draw_cel_style_bands_content :: proc(
    x, y, width: f32,
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) -> bool {
    changed := false
    cursor_y := y
    state.selected_band = clamp(
        state.selected_band,
        c.int(0),
        c.int(style.band_count - 1),
    )

    rl.GuiLabel({x, cursor_y, 38, 22}, "Band")
    selected_display := state.selected_band + 1
    _ = ui_gui_spinner(
        .CEL_BAND_SELECT,
        {x + 40, cursor_y, 62, 22},
        nil,
        &selected_display,
        1,
        c.int(style.band_count),
        1,
        1,
        false,
    )
    state.selected_band = selected_display - 1
    add_width := (width - 110) * 0.5
    if ui_gui_button(
        .CEL_BAND_ADD,
        {x + 108, cursor_y, add_width, 22},
        "Add after",
    ) {
        if add_cel_band_after(style, int(state.selected_band)) {
            state.selected_band += 1
            changed = true
        }
    }
    if ui_gui_button(
        .CEL_BAND_REMOVE,
        {x + 112 + add_width, cursor_y, width - 112 - add_width, 22},
        "Remove",
    ) {
        if remove_cel_band(style, int(state.selected_band)) {
            state.selected_band = min(
                state.selected_band,
                c.int(style.band_count - 1),
            )
            changed = true
        }
    }

    band_index := int(state.selected_band)
    band := &style.bands[band_index]
    cursor_y += 32
    rl.GuiLabel(
        {x, cursor_y, width, 20},
        rl.TextFormat("Editing band %d of %d", band_index + 1, style.band_count),
    )
    cursor_y += 28
    if band_index < style.band_count - 1 {
        lower_bound := f32(0)
        if band_index > 0 {
            lower_bound = style.bands[band_index - 1].upper_bound +
                          CEL_BOUNDARY_MINIMUM_GAP
        }
        upper_bound := f32(1) - CEL_BOUNDARY_MINIMUM_GAP
        if band_index < style.band_count - 2 {
            upper_bound = style.bands[band_index + 1].upper_bound -
                          CEL_BOUNDARY_MINIMUM_GAP
        }
        changed = draw_cel_style_slider(
            .CEL_BAND_UPPER_BOUND,
            x,
            cursor_y,
            width,
            "Upper bound",
            &band.upper_bound,
            lower_bound,
            upper_bound,
            0.01,
            0.1,
        ) || changed
        cursor_y += 28
    }
    changed = draw_cel_style_slider(
        .CEL_BAND_BRIGHTNESS,
        x, cursor_y, width, "Brightness", &band.brightness, 0, 2, 0.05, 0.25,
    ) || changed
    cursor_y += 28
    changed = draw_cel_style_slider(
        .CEL_BAND_TINT_MIX,
        x, cursor_y, width, "Tint mix", &band.tint_mix, 0, 1, 0.01, 0.1,
    ) || changed
    cursor_y += 28

    tint_color := cel_vector_color_to_raylib(band.tint)
    draw_cel_color_swatch(
        .CEL_BAND_TINT_SWATCH,
        x,
        cursor_y,
        width,
        "Tint",
        tint_color,
        .BAND_TINT,
        state,
    )
    cursor_y += 28
    if state.color_target == .BAND_TINT {
        previous_tint_color := tint_color
        _ = ui_gui_color_picker(
            .CEL_BAND_TINT_PICKER,
            {x, cursor_y, 150, 150},
            &tint_color,
            false,
        )
        if tint_color != previous_tint_color {
            band.tint = cel_raylib_color_to_vector(tint_color)
            changed = true
        }
        cursor_y += 158
    }

    rl.GuiLabel({x, cursor_y, 104, 22}, "Alpha")
    alpha_mode := c.int(style.alpha_mode)
    previous_alpha_mode := alpha_mode
    _ = ui_gui_combo_box(
        .CEL_ALPHA_MODE,
        {x + 108, cursor_y, width - 108, 22},
        "Opaque;Mask",
        &alpha_mode,
        2,
    )
    if alpha_mode != previous_alpha_mode {
        style.alpha_mode = Cel_Alpha_Mode(alpha_mode)
        changed = true
    }
    cursor_y += 30
    if style.alpha_mode == .MASK {
        changed = draw_cel_style_slider(
            .CEL_ALPHA_CUTOFF,
            x, cursor_y, width, "Cutoff", &style.alpha_cutoff, 0, 1, 0.01, 0.1,
        ) || changed
    }
    return changed
}

draw_cel_accent_content :: proc(
    x, y, width: f32,
    label: cstring,
    target: Cel_Color_Target,
    state: ^Cel_Style_UI_State,
    accent: ^Cel_Accent,
) -> bool {
    changed := false
    cursor_y := y
    enabled_focus := UI_Focus_ID.CEL_RIM_ENABLED
    threshold_focus := UI_Focus_ID.CEL_RIM_THRESHOLD
    strength_focus := UI_Focus_ID.CEL_RIM_STRENGTH
    samples_focus := UI_Focus_ID.CEL_RIM_SAMPLES
    swatch_focus := UI_Focus_ID.CEL_RIM_SWATCH
    picker_focus := UI_Focus_ID.CEL_RIM_PICKER
    if target == .HIGHLIGHT {
        enabled_focus = .CEL_HIGHLIGHT_ENABLED
        threshold_focus = .CEL_HIGHLIGHT_THRESHOLD
        strength_focus = .CEL_HIGHLIGHT_STRENGTH
        samples_focus = .CEL_HIGHLIGHT_SAMPLES
        swatch_focus = .CEL_HIGHLIGHT_SWATCH
        picker_focus = .CEL_HIGHLIGHT_PICKER
    }
    previous_enabled := accent.enabled
    _ = ui_gui_check_box(
        enabled_focus,
        {x, cursor_y + 2, 18, 18},
        nil,
        &accent.enabled,
    )
    rl.GuiLabel({x + 24, cursor_y, width - 24, 22}, label)
    changed = accent.enabled != previous_enabled
    cursor_y += 22
    changed = draw_cel_style_slider(
        threshold_focus,
        x, cursor_y, width, "Threshold", &accent.threshold, 0, 1, 0.01, 0.1,
    ) || changed
    cursor_y += 28
    changed = draw_cel_style_slider(
        strength_focus,
        x, cursor_y, width, "Strength", &accent.strength, 0, 2, 0.05, 0.25,
    ) || changed
    cursor_y += 28
    rl.GuiLabel({x, cursor_y, 104, 22}, "Keep samples")
    preserve_samples := c.int(accent.preserve_samples)
    previous_samples := preserve_samples
    _ = ui_gui_spinner(
        samples_focus,
        {x + 108, cursor_y, width - 108, 22},
        nil,
        &preserve_samples,
        1,
        16,
        1,
        4,
        false,
    )
    if preserve_samples != previous_samples {
        accent.preserve_samples = int(preserve_samples)
        changed = true
    }
    cursor_y += 30
    color := cel_vector_color_to_raylib(accent.color)
    draw_cel_color_swatch(
        swatch_focus,
        x,
        cursor_y,
        width,
        "Color",
        color,
        target,
        state,
    )
    cursor_y += 32
    if state.color_target == target {
        previous_color := color
        _ = ui_gui_color_picker(
            picker_focus,
            {x, cursor_y, 126, 126},
            &color,
            false,
        )
        if color != previous_color {
            accent.color = cel_raylib_color_to_vector(color)
            changed = true
        }
    }
    return changed
}

draw_cel_style_accents_content :: proc(
    x, y, width: f32,
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) -> bool {
    rim_changed := draw_cel_accent_content(
        x, y, width, "Rim light", .RIM, state, &style.rim,
    )
    highlight_y := y + cel_accent_block_height(state, .RIM) + 8
    rl.GuiLine({x, highlight_y - 6, width, 2}, nil)
    highlight_changed := draw_cel_accent_content(
        x,
        highlight_y,
        width,
        "Highlight",
        .HIGHLIGHT,
        state,
        &style.highlight,
    )
    return rim_changed || highlight_changed
}

draw_cel_style_outline_content :: proc(
    x, y, width: f32,
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) -> bool {
    changed := false
    cursor_y := y
    rl.GuiLabel({x, cursor_y, 104, 22}, "Width (pixels)")
    outline_width := c.int(style.outline.width)
    previous_width := outline_width
    _ = ui_gui_spinner(
        .CEL_OUTLINE_WIDTH,
        {x + 108, cursor_y, width - 108, 22},
        nil,
        &outline_width,
        0,
        3,
        1,
        1,
        false,
    )
    if outline_width != previous_width {
        style.outline.width = int(outline_width)
        changed = true
    }
    cursor_y += 32
    changed = draw_cel_style_slider(
        .CEL_OUTLINE_COVERAGE,
        x,
        cursor_y,
        width,
        "Coverage",
        &style.outline.coverage_threshold,
        0,
        1,
        0.01,
        0.1,
    ) || changed
    cursor_y += 28

    outline_color := style.outline.color
    draw_cel_color_swatch(
        .CEL_OUTLINE_SWATCH,
        x,
        cursor_y,
        width,
        "Color",
        outline_color,
        .OUTLINE,
        state,
    )
    cursor_y += 32
    if state.color_target == .OUTLINE {
        previous_color := outline_color
        _ = ui_gui_color_picker(
            .CEL_OUTLINE_PICKER,
            {x, cursor_y, 160, 160},
            &outline_color,
            false,
        )
        if outline_color != previous_color {
            style.outline.color.r = outline_color.r
            style.outline.color.g = outline_color.g
            style.outline.color.b = outline_color.b
            changed = true
        }
        cursor_y += 168
    }

    alpha := f32(style.outline.color.a) / 255
    previous_alpha := alpha
    changed = draw_cel_style_slider(
        .CEL_OUTLINE_ALPHA,
        x, cursor_y, width, "Alpha", &alpha, 0, 1, 0.01, 0.1,
    ) || changed
    if alpha != previous_alpha {
        style.outline.color.a = cel_color_component_to_byte(alpha)
    }
    return changed
}

draw_cel_subsection :: proc(
    id: UI_Focus_ID,
    x, y, width: f32,
    title: cstring,
    open: ^bool,
) {
    rl.GuiPanel({x, y, width, CEL_SUBSECTION_HEADER_HEIGHT}, nil)
    draw_collapsible_header(
        id,
        {x, y, width, CEL_SUBSECTION_HEADER_HEIGHT},
        title,
        open,
    )
}

draw_cel_style_editor :: proc(
    bounds: rl.Rectangle,
    state: ^Cel_Style_UI_State,
    style: ^Cel_Style,
) {
    rl.GuiPanel(bounds, nil)
    was_open := state.open
    draw_collapsible_header(
        .CEL_HEADER,
        {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
        "CEL SHADING [C]",
        &state.open,
    )
    if was_open && !state.open {
        state.color_target = .NONE
    }
    if !state.open {
        return
    }

    x := bounds.x + 12
    width := bounds.width - 24
    y := bounds.y + INSPECTOR_SECTION_HEADER_HEIGHT + 8

    combo_width := width * 0.38
    button_gap: f32 = 4
    reload_width: f32 = 56
    save_width: f32 = 44
    reset_width := width - combo_width - reload_width - save_width - button_gap * 3
    previous_preset := state.preset_index
    _ = ui_gui_combo_box(
        .CEL_PRESET,
        {x, y, combo_width, 24},
        CEL_STYLE_PRESET_OPTIONS,
        &state.preset_index,
        3,
    )
    if state.preset_index != previous_preset {
        _ = load_selected_cel_style_preset(state, style)
    }
    button_x := x + combo_width + button_gap
    if ui_gui_button(.CEL_RELOAD, {button_x, y, reload_width, 24}, "Reload") {
        _ = load_selected_cel_style_preset(state, style)
    }
    button_x += reload_width + button_gap
    if ui_gui_button(.CEL_SAVE, {button_x, y, save_width, 24}, "Save") {
        _ = save_selected_cel_style_preset(state, style)
    }
    button_x += save_width + button_gap
    if ui_gui_button(.CEL_RESET, {button_x, y, reset_width, 24}, "Reset") {
        reset_cel_style_to_classic(state, style)
    }
    y += 30

    title_suffix: cstring = ""
    if state.dirty {
        title_suffix = " *"
    }
    style_name_cstr := strings.clone_to_cstring(style.name, context.temp_allocator)
    rl.GuiLabel(
        {x, y, width, 20},
        rl.TextFormat("%s%s", style_name_cstr, title_suffix),
    )
    y += 22
    draw_cel_ramp_preview({x, y, width, 22}, style)
    y += 30

    changed := false

    light_was_open := state.light_open
    draw_cel_subsection(
        .CEL_LIGHT_HEADER,
        x,
        y,
        width,
        "LIGHT",
        &state.light_open,
    )
    if state.light_open {
        changed = draw_cel_style_light_content(
            x + 8,
            y + CEL_SUBSECTION_HEADER_HEIGHT + 8,
            width - 16,
            state,
            style,
        ) || changed
    }
    if !light_was_open && state.light_open && !state.light_angles_valid {
        sync_cel_style_light_angles(state, style)
    }
    y += cel_subsection_height(
        state.light_open,
        cel_style_light_content_height(),
    ) + INSPECTOR_SECTION_GAP

    bands_was_open := state.bands_open
    draw_cel_subsection(
        .CEL_BANDS_HEADER,
        x,
        y,
        width,
        "BANDS & ALPHA",
        &state.bands_open,
    )
    if bands_was_open && !state.bands_open && state.color_target == .BAND_TINT {
        state.color_target = .NONE
    }
    if state.bands_open {
        changed = draw_cel_style_bands_content(
            x + 8,
            y + CEL_SUBSECTION_HEADER_HEIGHT + 8,
            width - 16,
            state,
            style,
        ) || changed
    }
    y += cel_subsection_height(
        state.bands_open,
        cel_style_bands_content_height(state, style),
    ) + INSPECTOR_SECTION_GAP

    accents_was_open := state.accents_open
    draw_cel_subsection(
        .CEL_ACCENTS_HEADER,
        x,
        y,
        width,
        "ACCENTS",
        &state.accents_open,
    )
    if accents_was_open && !state.accents_open &&
       (state.color_target == .RIM || state.color_target == .HIGHLIGHT) {
        state.color_target = .NONE
    }
    if state.accents_open {
        changed = draw_cel_style_accents_content(
            x + 8,
            y + CEL_SUBSECTION_HEADER_HEIGHT + 8,
            width - 16,
            state,
            style,
        ) || changed
    }
    y += cel_subsection_height(
        state.accents_open,
        cel_style_accents_content_height(state),
    ) + INSPECTOR_SECTION_GAP

    outline_was_open := state.outline_open
    draw_cel_subsection(
        .CEL_OUTLINE_HEADER,
        x,
        y,
        width,
        "OUTLINE",
        &state.outline_open,
    )
    if outline_was_open && !state.outline_open && state.color_target == .OUTLINE {
        state.color_target = .NONE
    }
    if state.outline_open {
        changed = draw_cel_style_outline_content(
            x + 8,
            y + CEL_SUBSECTION_HEADER_HEIGHT + 8,
            width - 16,
            state,
            style,
        ) || changed
    }
    y += cel_subsection_height(
        state.outline_open,
        cel_style_outline_content_height(state),
    ) + INSPECTOR_SECTION_GAP

    if changed {
        mark_cel_style_edited(state, style)
    }

    status_text := cel_style_ui_status_text(state.status)
    if state.status == .NONE || rl.GetTime() - state.status_time < 5 {
        rl.GuiStatusBar({x, y, width, 20}, status_text)
    }
}
