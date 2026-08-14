package main

// This module contains cel-style editor state and reusable editor widgets.
// Rendering mutates the supplied style immediately; callers use the returned
// height calculations to integrate the editor into a clipped inspector.

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

// Cel_Style_UI_Status drives short-lived feedback shown beneath the editor.
Cel_Style_UI_Status :: enum {
    NONE,
    LOADED,
    SAVED,
    RESET,
    LOAD_FAILED,
    SAVE_FAILED,
}

// Cel_Color_Target identifies the one expanded color picker. Keeping this
// mutually exclusive prevents overlapping modal controls in a narrow inspector.
Cel_Color_Target :: enum {
    NONE,
    BAND_TINT,
    RIM,
    HIGHLIGHT,
    OUTLINE,
}

// Cel_Style_UI_State stores presentation state separately from Cel_Style so UI
// expansion, focus, and transient status never leak into saved presets.
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

// Inspector_UI_State tracks scrolling and the non-cel section expansion flags.
Inspector_UI_State :: struct {
    scroll_y:              f32,
    scrollbar_dragging:    bool,
    scrollbar_drag_offset: f32,
    model_open:            bool,
    camera_open:           bool,
    background_open:       bool,
}

// set_cel_style_ui_status records both the message category and its start time.
set_cel_style_ui_status :: proc(
    state: ^Cel_Style_UI_State,
    status: Cel_Style_UI_Status,
) {
    state.status = status
    state.status_time = rl.GetTime()
}

// sync_cel_style_light_angles converts the normalized direction vector to
// degrees for the azimuth/elevation controls after loading or resetting a style.
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

// update_cel_style_direction_from_angles reconstructs a unit direction from the
// editor's degree values after either angular slider changes.
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

// cel_vector_color_to_raylib encodes normalized runtime RGB for raygui widgets.
cel_vector_color_to_raylib :: proc(color: rl.Vector3) -> rl.Color {
    return {
        cel_color_component_to_byte(color.x),
        cel_color_component_to_byte(color.y),
        cel_color_component_to_byte(color.z),
        255,
    }
}

// cel_raylib_color_to_vector decodes raygui byte RGB back to normalized runtime RGB.
cel_raylib_color_to_vector :: proc(color: rl.Color) -> rl.Vector3 {
    return {
        f32(color.r) / 255,
        f32(color.g) / 255,
        f32(color.b) / 255,
    }
}

// load_selected_cel_style_preset replaces the active style only after a complete
// successful load, then resets selection, dirty state, and derived light angles.
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

// save_selected_cel_style_preset persists the current style to the selected
// bundled path and updates status without discarding unsaved state on failure.
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

// reset_cel_style_to_classic installs the allocation-free built-in defaults and
// resets modal editor state while marking the result as an unsaved edit.
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

// add_cel_band_after splits the selected diffuse interval in half. It shifts
// following bands and refuses splits that violate the one-byte threshold gap.
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

// remove_cel_band merges the selected interval into a neighbor and compacts the
// fixed array. At least two bands are retained to preserve style validity.
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

// draw_collapsible_header renders a keyboard-focusable section header and
// toggles the supplied expansion flag on mouse or keyboard activation.
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

// draw_cel_style_slider combines a label, focus-aware slider, and numeric readout.
// step/coarse_step define deterministic keyboard adjustments.
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

// draw_cel_color_swatch toggles the requested color picker and transfers focus
// to the correct picker control while always displaying the encoded RGB value.
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

// Height helpers mirror the exact vertical increments used by drawing code.
// Keeping them pure lets inspector scrolling remain correct before controls draw.
cel_style_light_content_height :: proc() -> f32 {
    return 146
}

// cel_style_bands_content_height includes conditional threshold, tint picker,
// and alpha-cutoff rows for the currently selected band and alpha mode.
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

// cel_accent_block_height includes the optional expanded picker for one accent.
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

// cel_style_accents_content_height combines rim/highlight blocks and their divider.
cel_style_accents_content_height :: proc(state: ^Cel_Style_UI_State) -> f32 {
    return cel_accent_block_height(state, .RIM) +
           cel_accent_block_height(state, .HIGHLIGHT) + 8
}

// cel_style_outline_content_height accounts for the optional RGBA picker area.
cel_style_outline_content_height :: proc(state: ^Cel_Style_UI_State) -> f32 {
    height: f32 = 32 + 28 + 32 + 28
    if state.color_target == .OUTLINE {
        height += 168
    }
    return height
}

// cel_subsection_height adds header and padding only when content is expanded.
cel_subsection_height :: proc(open: bool, content_height: f32) -> f32 {
    if !open {
        return CEL_SUBSECTION_HEADER_HEIGHT
    }
    return CEL_SUBSECTION_HEADER_HEIGHT + 8 + content_height + 8
}

// cel_style_editor_height predicts the complete editor extent from current UI
// and style state; draw code must keep its row increments synchronized with it.
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

// draw_cel_accent_content renders the common rim/highlight controls. Focus IDs
// are selected from target so both blocks share layout logic without collisions.
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

// draw_cel_subsection renders the panel chrome and delegates expansion behavior
// to the shared collapsible-header control.
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
