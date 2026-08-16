package shared

// This module centralizes application commands, shortcut matching, keyboard
// focus traversal, and raygui wrappers. Mouse and keyboard activation therefore
// share one state machine instead of each panel implementing its own rules.

import "core:c"
import rl "vendor:raylib"

UI_MOD_SHIFT   :: u8(1 << 0)
UI_MOD_ALT     :: u8(1 << 1)
UI_MOD_PRIMARY :: u8(1 << 2)

UI_MAX_FOCUSABLE_CONTROLS :: 128

// UI_Command is the semantic action layer between raw keys and application
// mutation. Commands are dispatched in main after modal/focus conflict checks.
UI_Command :: enum {
    NONE,
    TOGGLE_HELP,
    QUIT,
    FOCUS_MODEL_SEARCH,
    TOGGLE_MODEL_SECTION,
    TOGGLE_CAMERA_SECTION,
    TOGGLE_CEL_SECTION,
    TOGGLE_BACKGROUND_SECTION,
    INSPECTOR_PAGE_UP,
    INSPECTOR_PAGE_DOWN,
    INSPECTOR_HOME,
    INSPECTOR_END,
    LENS_PIXELATED,
    LENS_BLENDED,
    LENS_COVERAGE,
    TOGGLE_LENS_GRID,
    EXPORT_PNG,
    CAMERA_X,
    CAMERA_Y,
    CAMERA_Z,
    CAMERA_ISOMETRIC,
    DOWNSCALE_DECREASE,
    DOWNSCALE_INCREASE,
    ANIMATION_PLAY_PAUSE,
    ANIMATION_FIRST_FRAME,
    ANIMATION_PREVIOUS_FRAME,
    ANIMATION_NEXT_FRAME,
    ANIMATION_PREVIOUS_CLIP,
    ANIMATION_NEXT_CLIP,
    ANIMATION_TOGGLE_LOOP,
    ANIMATION_TOGGLE_SAMPLED,
    CEL_PRESET_CLASSIC,
    CEL_PRESET_ANIME,
    CEL_PRESET_NOIR,
    CEL_RELOAD,
    CEL_SAVE,
    CEL_RESET,
    TOGGLE_BACKGROUND_PICKER,
    RESET_BACKGROUND,
}

// UI_Shortcut_Binding requires an exact normalized modifier mask.
UI_Shortcut_Binding :: struct {
    command:   UI_Command,
    key:       rl.KeyboardKey,
    modifiers: u8,
}

// UI_SHORTCUT_BINDINGS is ordered for deterministic first-match dispatch. Any
// duplicate key/modifier pair would make the later binding unreachable.
UI_SHORTCUT_BINDINGS :: [?]UI_Shortcut_Binding{
    {.TOGGLE_HELP,                 .F1,            0},
    {.TOGGLE_HELP,                 .SLASH,         UI_MOD_SHIFT},
    {.QUIT,                        .Q,             UI_MOD_PRIMARY},
    {.FOCUS_MODEL_SEARCH,          .F,             UI_MOD_PRIMARY},
    {.TOGGLE_MODEL_SECTION,        .ONE,           UI_MOD_PRIMARY},
    {.TOGGLE_CAMERA_SECTION,       .TWO,           UI_MOD_PRIMARY},
    {.TOGGLE_CEL_SECTION,          .THREE,         UI_MOD_PRIMARY},
    {.TOGGLE_BACKGROUND_SECTION,   .FOUR,          UI_MOD_PRIMARY},
    {.INSPECTOR_PAGE_UP,           .PAGE_UP,       0},
    {.INSPECTOR_PAGE_DOWN,         .PAGE_DOWN,     0},
    {.INSPECTOR_HOME,              .HOME,          UI_MOD_PRIMARY},
    {.INSPECTOR_END,               .END,           UI_MOD_PRIMARY},
    {.LENS_PIXELATED,              .ONE,           0},
    {.LENS_PIXELATED,              .KP_1,          0},
    {.LENS_BLENDED,                .TWO,           0},
    {.LENS_BLENDED,                .KP_2,          0},
    {.LENS_COVERAGE,               .THREE,         0},
    {.LENS_COVERAGE,               .KP_3,          0},
    {.TOGGLE_LENS_GRID,            .G,             0},
    {.EXPORT_PNG,                  .P,             0},
    {.CAMERA_X,                    .X,             0},
    {.CAMERA_Y,                    .Y,             0},
    {.CAMERA_Z,                    .Z,             0},
    {.CAMERA_ISOMETRIC,            .I,             0},
    {.DOWNSCALE_DECREASE,          .MINUS,         0},
    {.DOWNSCALE_DECREASE,          .KP_SUBTRACT,   0},
    {.DOWNSCALE_INCREASE,          .EQUAL,         0},
    {.DOWNSCALE_INCREASE,          .KP_ADD,        0},
    {.ANIMATION_PLAY_PAUSE,        .SPACE,         0},
    {.ANIMATION_FIRST_FRAME,       .HOME,          0},
    {.ANIMATION_PREVIOUS_FRAME,    .COMMA,         0},
    {.ANIMATION_NEXT_FRAME,        .PERIOD,        0},
    {.ANIMATION_PREVIOUS_CLIP,     .LEFT_BRACKET,  0},
    {.ANIMATION_NEXT_CLIP,         .RIGHT_BRACKET, 0},
    {.ANIMATION_TOGGLE_LOOP,       .L,             0},
    {.ANIMATION_TOGGLE_SAMPLED,    .K,             0},
    {.TOGGLE_CEL_SECTION,          .C,             0},
    {.CEL_PRESET_CLASSIC,          .ONE,           UI_MOD_ALT},
    {.CEL_PRESET_ANIME,            .TWO,           UI_MOD_ALT},
    {.CEL_PRESET_NOIR,             .THREE,         UI_MOD_ALT},
    {.CEL_RELOAD,                  .R,             UI_MOD_PRIMARY},
    {.CEL_SAVE,                    .S,             UI_MOD_PRIMARY},
    {.CEL_RESET,                   .R,             UI_MOD_PRIMARY | UI_MOD_SHIFT},
    {.TOGGLE_BACKGROUND_PICKER,    .B,             0},
    {.RESET_BACKGROUND,            .B,             UI_MOD_SHIFT},
}

// UI_Focus_ID gives every keyboard-focusable widget a stable identity across
// frames, even when scrolling or collapsed sections change registration order.
UI_Focus_ID :: enum {
    NONE,
    LENS_PIXELATED,
    LENS_BLENDED,
    LENS_COVERAGE,
    LENS_GRID,
    EXPORT_PNG,
    ANIMATION_PREVIOUS_CLIP,
    ANIMATION_CLIP,
    ANIMATION_NEXT_CLIP,
    ANIMATION_FIRST,
    ANIMATION_PREVIOUS,
    ANIMATION_PLAY,
    ANIMATION_NEXT,
    ANIMATION_TIMELINE,
    ANIMATION_SPEED,
    ANIMATION_LOOP,
    ANIMATION_SAMPLED,
    ANIMATION_SAMPLE_COUNT,
    MODEL_HEADER,
    MODEL_SEARCH,
    MODEL_CLEAR,
    MODEL_LIST,
    LENS_HEADER,
    LENS_DOWNSCALE,
    LENS_EDGE_AA,
    CAMERA_HEADER,
    CAMERA_X,
    CAMERA_Y,
    CAMERA_Z,
    CAMERA_ISOMETRIC,
    CEL_HEADER,
    CEL_PRESET,
    CEL_RELOAD,
    CEL_SAVE,
    CEL_RESET,
    CEL_LIGHT_HEADER,
    CEL_LIGHT_SPACE,
    CEL_LIGHT_AZIMUTH,
    CEL_LIGHT_ELEVATION,
    CEL_LIGHT_WRAP,
    CEL_BANDS_HEADER,
    CEL_BAND_SELECT,
    CEL_BAND_ADD,
    CEL_BAND_REMOVE,
    CEL_BAND_UPPER_BOUND,
    CEL_BAND_BRIGHTNESS,
    CEL_BAND_TINT_MIX,
    CEL_BAND_TINT_SWATCH,
    CEL_BAND_TINT_PICKER,
    CEL_ALPHA_MODE,
    CEL_ALPHA_CUTOFF,
    CEL_ACCENTS_HEADER,
    CEL_RIM_ENABLED,
    CEL_RIM_THRESHOLD,
    CEL_RIM_STRENGTH,
    CEL_RIM_SAMPLES,
    CEL_RIM_SWATCH,
    CEL_RIM_PICKER,
    CEL_HIGHLIGHT_ENABLED,
    CEL_HIGHLIGHT_THRESHOLD,
    CEL_HIGHLIGHT_STRENGTH,
    CEL_HIGHLIGHT_SAMPLES,
    CEL_HIGHLIGHT_SWATCH,
    CEL_HIGHLIGHT_PICKER,
    CEL_OUTLINE_HEADER,
    CEL_OUTLINE_WIDTH,
    CEL_OUTLINE_COVERAGE,
    CEL_OUTLINE_SWATCH,
    CEL_OUTLINE_PICKER,
    CEL_OUTLINE_ALPHA,
    BACKGROUND_HEADER,
    BACKGROUND_PICKER_TOGGLE,
    BACKGROUND_RESET,
    BACKGROUND_PICKER,
    INSPECTOR_SCROLLBAR,
    HELP_CLOSE,
}

// UI_Keyboard_State retains the previous frame's traversal order and builds the
// next one during drawing. clip_bounds excludes scrolled-out inspector controls.
UI_Keyboard_State :: struct {
    enabled:        bool,
    focused:        UI_Focus_ID,
    current_order:  [UI_MAX_FOCUSABLE_CONTROLS]UI_Focus_ID,
    current_count:  int,
    previous_order: [UI_MAX_FOCUSABLE_CONTROLS]UI_Focus_ID,
    previous_count: int,
    color_channel:  c.int,
    clip_active:    bool,
    clip_bounds:    rl.Rectangle,
}

// ui_primary_modifier_is_down treats Control and Command/Super as one portable
// primary modifier so shortcuts behave naturally on macOS and other platforms.
ui_primary_modifier_is_down :: proc() -> bool {
    return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) ||
           rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)
}

// ui_modifier_mask snapshots exact Shift, Alt, and primary-modifier state.
ui_modifier_mask :: proc() -> u8 {
    modifiers: u8
    if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
        modifiers |= UI_MOD_SHIFT
    }
    if rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT) {
        modifiers |= UI_MOD_ALT
    }
    if ui_primary_modifier_is_down() {
        modifiers |= UI_MOD_PRIMARY
    }
    return modifiers
}

// ui_find_focus_index searches the active prefix of a fixed control array and
// returns -1 when the focused ID is not registered in that frame.
ui_find_focus_index :: proc(
    controls: [^]UI_Focus_ID,
    count: int,
    focused: UI_Focus_ID,
) -> int {
    for control_index := 0; control_index < count; control_index += 1 {
        if controls[control_index] == focused {
            return control_index
        }
    }
    return -1
}

// ui_focus_fallback maps hidden child controls to the nearest visible section
// header after a picker closes or a subsection collapses.
ui_focus_fallback :: proc(focused: UI_Focus_ID) -> UI_Focus_ID {
    #partial switch focused {
    case .ANIMATION_PREVIOUS_CLIP, .ANIMATION_NEXT_CLIP:
        return .ANIMATION_CLIP
    case .MODEL_SEARCH, .MODEL_CLEAR, .MODEL_LIST:
        return .MODEL_HEADER
    case .LENS_DOWNSCALE, .LENS_EDGE_AA:
        return .LENS_HEADER
    case .CAMERA_X, .CAMERA_Y, .CAMERA_Z, .CAMERA_ISOMETRIC:
        return .CAMERA_HEADER
    case .CEL_PRESET, .CEL_RELOAD, .CEL_SAVE, .CEL_RESET,
         .CEL_LIGHT_HEADER, .CEL_BANDS_HEADER, .CEL_ACCENTS_HEADER,
         .CEL_OUTLINE_HEADER:
        return .CEL_HEADER
    case .CEL_LIGHT_SPACE, .CEL_LIGHT_AZIMUTH, .CEL_LIGHT_ELEVATION,
         .CEL_LIGHT_WRAP:
        return .CEL_LIGHT_HEADER
    case .CEL_BAND_SELECT, .CEL_BAND_ADD, .CEL_BAND_REMOVE,
         .CEL_BAND_UPPER_BOUND, .CEL_BAND_BRIGHTNESS,
         .CEL_BAND_TINT_MIX, .CEL_BAND_TINT_SWATCH,
         .CEL_BAND_TINT_PICKER, .CEL_ALPHA_MODE, .CEL_ALPHA_CUTOFF:
        return .CEL_BANDS_HEADER
    case .CEL_RIM_ENABLED, .CEL_RIM_THRESHOLD, .CEL_RIM_STRENGTH,
         .CEL_RIM_SAMPLES, .CEL_RIM_SWATCH, .CEL_RIM_PICKER,
         .CEL_HIGHLIGHT_ENABLED, .CEL_HIGHLIGHT_THRESHOLD,
         .CEL_HIGHLIGHT_STRENGTH, .CEL_HIGHLIGHT_SAMPLES,
         .CEL_HIGHLIGHT_SWATCH, .CEL_HIGHLIGHT_PICKER:
        return .CEL_ACCENTS_HEADER
    case .CEL_OUTLINE_WIDTH, .CEL_OUTLINE_COVERAGE,
         .CEL_OUTLINE_SWATCH, .CEL_OUTLINE_PICKER, .CEL_OUTLINE_ALPHA:
        return .CEL_OUTLINE_HEADER
    case .BACKGROUND_PICKER_TOGGLE, .BACKGROUND_RESET, .BACKGROUND_PICKER:
        return .BACKGROUND_HEADER
    }
    return .NONE
}

// ui_keyboard_begin_frame resets the visible-control registry and applies Tab
// traversal using the order retained from the previous frame.
ui_keyboard_begin_frame :: proc(
    keyboard: ^UI_Keyboard_State,
    enabled: bool,
    trap_tab: bool,
) {
    keyboard.enabled = enabled
    keyboard.current_count = 0
    if !enabled {
        keyboard.focused = .NONE
        return
    }
    if trap_tab || !rl.IsKeyPressed(.TAB) || keyboard.previous_count <= 0 {
        return
    }

    focused_index := ui_find_focus_index(
        &keyboard.previous_order[0],
        keyboard.previous_count,
        keyboard.focused,
    )
    move_backward := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
    if move_backward {
        if focused_index < 0 {
            focused_index = keyboard.previous_count - 1
        } else {
            focused_index = (focused_index - 1 + keyboard.previous_count) %
                            keyboard.previous_count
        }
    } else {
        focused_index = (focused_index + 1) % keyboard.previous_count
    }
    keyboard.focused = keyboard.previous_order[focused_index]
}

// ui_keyboard_end_frame validates focus against the controls drawn this frame
// and retains their traversal order for the next frame.
ui_keyboard_end_frame :: proc(keyboard: ^UI_Keyboard_State) {
    if !keyboard.enabled {
        return
    }
    if keyboard.focused != .NONE &&
       ui_find_focus_index(
           &keyboard.current_order[0],
           keyboard.current_count,
           keyboard.focused,
       ) < 0 {
        fallback := ui_focus_fallback(keyboard.focused)
        if fallback != .NONE &&
           ui_find_focus_index(
               &keyboard.current_order[0],
               keyboard.current_count,
               fallback,
           ) >= 0 {
            keyboard.focused = fallback
        } else {
            keyboard.focused = .NONE
        }
    }
    keyboard.previous_count = keyboard.current_count
    for control_index := 0;
        control_index < keyboard.current_count;
        control_index += 1 {
        keyboard.previous_order[control_index] =
            keyboard.current_order[control_index]
    }
}

// ui_keyboard_clip_set limits focus registration to one visible UI region.
ui_keyboard_clip_set :: proc(
    keyboard: ^UI_Keyboard_State,
    bounds: rl.Rectangle,
) {
    keyboard.clip_active = true
    keyboard.clip_bounds = bounds
}

// ui_keyboard_clip_clear restores focus registration for the full UI.
ui_keyboard_clip_clear :: proc(keyboard: ^UI_Keyboard_State) {
    keyboard.clip_active = false
}

// ui_keyboard_focus_clear relinquishes keyboard ownership without altering order.
ui_keyboard_focus_clear :: proc(keyboard: ^UI_Keyboard_State) {
    keyboard.focused = .NONE
}

// ui_keyboard_focus_set transfers keyboard ownership to a known control ID.
ui_keyboard_focus_set :: proc(
    keyboard: ^UI_Keyboard_State,
    focused: UI_Focus_ID,
) {
    keyboard.focused = focused
}

// ui_keyboard_focused_id returns the control that currently owns keyboard focus.
ui_keyboard_focused_id :: proc(keyboard: ^UI_Keyboard_State) -> UI_Focus_ID {
    return keyboard.focused
}

// ui_keyboard_has_focus reports whether navigation is enabled and non-empty.
ui_keyboard_has_focus :: proc(keyboard: ^UI_Keyboard_State) -> bool {
    return keyboard.enabled && keyboard.focused != .NONE
}

// ui_control_register appends a visible widget to this frame's traversal order,
// updates focus on a mouse press, and returns whether the widget owns focus.
ui_control_register :: proc(
    keyboard: ^UI_Keyboard_State,
    id: UI_Focus_ID,
    bounds: rl.Rectangle,
) -> bool {
    if !keyboard.enabled || id == .NONE {
        return false
    }
    if keyboard.clip_active &&
       !rl.CheckCollisionRecs(bounds, keyboard.clip_bounds) {
        return false
    }
    if keyboard.current_count < UI_MAX_FOCUSABLE_CONTROLS {
        keyboard.current_order[keyboard.current_count] = id
        keyboard.current_count += 1
    }
    if !rl.GuiIsLocked() && rl.IsMouseButtonPressed(.LEFT) &&
       rl.CheckCollisionPointRec(rl.GetMousePosition(), bounds) {
        keyboard.focused = id
    }
    return keyboard.focused == id
}

// ui_focus_draw paints the shared high-contrast focus ring outside widget bounds.
ui_focus_draw :: proc(bounds: rl.Rectangle, focused: bool) {
    if focused {
        rl.DrawRectangleLinesEx(
            {bounds.x - 2, bounds.y - 2, bounds.width + 4, bounds.height + 4},
            2,
            rl.Color{255, 214, 64, 255},
        )
    }
}

// ui_key_is_pressed_or_repeating unifies the initial key edge with raylib repeat events.
ui_key_is_pressed_or_repeating :: proc(key: rl.KeyboardKey) -> bool {
    return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key)
}

// ui_activation_is_pressed recognizes unmodified Enter, keypad Enter, or Space.
ui_activation_is_pressed :: proc() -> bool {
    return ui_modifier_mask() == 0 &&
           (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) ||
            rl.IsKeyPressed(.SPACE))
}

// ui_gui_button layers keyboard focus and activation over a standard raygui button.
ui_gui_button :: proc(
    keyboard: ^UI_Keyboard_State,
    id: UI_Focus_ID,
    bounds: rl.Rectangle,
    text: cstring,
) -> bool {
    focused := ui_control_register(keyboard, id, bounds)
    activated := rl.GuiButton(bounds, text) ||
                 (focused && ui_activation_is_pressed())
    ui_focus_draw(bounds, focused)
    return activated
}

// ui_gui_toggle adds keyboard focus and activation to a persistent raygui
// toggle. Callers can compose multiple toggles into a radio-style mode picker
// while retaining a distinct Tab stop and visible selected state for each item.
ui_gui_toggle :: proc(
    keyboard: ^UI_Keyboard_State,
    id: UI_Focus_ID,
    bounds: rl.Rectangle,
    text: cstring,
    active: ^bool,
) -> bool {
    focused := ui_control_register(keyboard, id, bounds)
    previous := active^
    _ = rl.GuiToggle(bounds, text, active)
    if focused && ui_activation_is_pressed() {
        active^ = !active^
    }
    ui_focus_draw(bounds, focused)
    return active^ != previous
}

// ui_gui_check_box supports Space toggling and returns an actual value change,
// independent of whether the mouse or keyboard produced it.
ui_gui_check_box :: proc(
    keyboard: ^UI_Keyboard_State,
    id: UI_Focus_ID,
    bounds: rl.Rectangle,
    text: cstring,
    checked: ^bool,
) -> bool {
    focused := ui_control_register(keyboard, id, bounds)
    previous := checked^
    rl.GuiCheckBox(bounds, text, checked)
    if focused && ui_modifier_mask() == 0 && rl.IsKeyPressed(.SPACE) {
        checked^ = !checked^
    }
    ui_focus_draw(bounds, focused)
    return checked^ != previous
}

// ui_gui_slider_bar adds stepped arrow/Home/End control to a continuous raygui
// slider while preserving direct mouse edits and coarse Shift adjustments.
ui_gui_slider_bar :: proc(
    keyboard: ^UI_Keyboard_State,
    id: UI_Focus_ID,
    bounds: rl.Rectangle,
    left_text, right_text: cstring,
    value: ^f32,
    minimum, maximum, step, coarse_step: f32,
) -> bool {
    focused := ui_control_register(keyboard, id, bounds)
    previous := value^
    rl.GuiSliderBar(bounds, left_text, right_text, value, minimum, maximum)
    if focused && !ui_primary_modifier_is_down() &&
       !(rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)) {
        // Apply keyboard slider adjustments inline at their only call site.
        adjustment := step
        if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
            adjustment = coarse_step
        }
        if ui_key_is_pressed_or_repeating(.LEFT) || ui_key_is_pressed_or_repeating(.DOWN) {
            value^ -= adjustment
        }
        if ui_key_is_pressed_or_repeating(.RIGHT) || ui_key_is_pressed_or_repeating(.UP) {
            value^ += adjustment
        }
        if rl.IsKeyPressed(.HOME) {
            value^ = minimum
        }
        if rl.IsKeyPressed(.END) {
            value^ = maximum
        }
        value^ = clamp(value^, minimum, maximum)
    }
    ui_focus_draw(bounds, focused)
    return value^ != previous
}

// ui_int_adjust applies bounded integer keyboard edits with normal/coarse steps.
ui_int_adjust :: proc(
    value: ^c.int,
    minimum, maximum, step, coarse_step: c.int,
) -> bool {
    previous := value^
    adjustment := step
    if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
        adjustment = coarse_step
    }
    if ui_key_is_pressed_or_repeating(.LEFT) || ui_key_is_pressed_or_repeating(.DOWN) {
        value^ -= adjustment
    }
    if ui_key_is_pressed_or_repeating(.RIGHT) || ui_key_is_pressed_or_repeating(.UP) {
        value^ += adjustment
    }
    if rl.IsKeyPressed(.HOME) {
        value^ = minimum
    }
    if rl.IsKeyPressed(.END) {
        value^ = maximum
    }
    value^ = clamp(value^, minimum, maximum)
    return value^ != previous
}

// ui_gui_spinner combines raygui editing with deterministic keyboard adjustment.
ui_gui_spinner :: proc(
    keyboard: ^UI_Keyboard_State,
    id: UI_Focus_ID,
    bounds: rl.Rectangle,
    text: cstring,
    value: ^c.int,
    minimum, maximum, step, coarse_step: c.int,
    edit_mode: bool,
) -> bool {
    focused := ui_control_register(keyboard, id, bounds)
    previous := value^
    rl.GuiSpinner(bounds, text, value, minimum, maximum, edit_mode)
    if focused && !ui_primary_modifier_is_down() &&
       !(rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)) {
        _ = ui_int_adjust(value, minimum, maximum, step, coarse_step)
    }
    ui_focus_draw(bounds, focused)
    return value^ != previous
}

// ui_gui_combo_box clamps arrow-driven selection to the supplied item count.
ui_gui_combo_box :: proc(
    keyboard: ^UI_Keyboard_State,
    id: UI_Focus_ID,
    bounds: rl.Rectangle,
    text: cstring,
    active: ^c.int,
    item_count: c.int,
) -> bool {
    focused := ui_control_register(keyboard, id, bounds)
    previous := active^
    rl.GuiComboBox(bounds, text, active)
    if focused && !ui_primary_modifier_is_down() &&
       !(rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)) {
        _ = ui_int_adjust(active, 0, max(item_count - 1, 0), 1, 1)
    }
    ui_focus_draw(bounds, focused)
    return active^ != previous
}

// ui_gui_color_picker adds keyboard channel selection and byte adjustment to
// raygui's mouse picker. color_channel persists when focus moves between pickers.
ui_gui_color_picker :: proc(
    keyboard: ^UI_Keyboard_State,
    id: UI_Focus_ID,
    bounds: rl.Rectangle,
    color: ^rl.Color,
    include_alpha: bool,
) -> bool {
    focused := ui_control_register(keyboard, id, bounds)
    previous := color^
    rl.GuiColorPicker(bounds, nil, color)
    channel_count: c.int = 3
    if include_alpha {
        channel_count = 4
    }
    keyboard.color_channel = clamp(
        keyboard.color_channel,
        c.int(0),
        channel_count - 1,
    )
    if focused && !ui_primary_modifier_is_down() &&
       !(rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)) {
        if ui_key_is_pressed_or_repeating(.UP) {
            keyboard.color_channel =
                (keyboard.color_channel - 1 + channel_count) % channel_count
        }
        if ui_key_is_pressed_or_repeating(.DOWN) {
            keyboard.color_channel =
                (keyboard.color_channel + 1) % channel_count
        }
        adjustment: i32 = 1
        if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
            adjustment = 10
        }
        component: ^u8
        channel_name: cstring = "R"
        switch keyboard.color_channel {
        case 0:
            component = &color.r
            channel_name = "R"
        case 1:
            component = &color.g
            channel_name = "G"
        case 2:
            component = &color.b
            channel_name = "B"
        case 3:
            component = &color.a
            channel_name = "A"
        }
        component_value := i32(component^)
        if ui_key_is_pressed_or_repeating(.LEFT) {
            component_value -= adjustment
        }
        if ui_key_is_pressed_or_repeating(.RIGHT) {
            component_value += adjustment
        }
        component^ = u8(clamp(component_value, i32(0), i32(255)))
        rl.DrawRectangle(
            c.int(bounds.x + 4),
            c.int(bounds.y + bounds.height - 22),
            72,
            18,
            rl.Color{20, 20, 20, 220},
        )
        rl.DrawText(
            rl.TextFormat("%s %d", channel_name, component^),
            c.int(bounds.x + 8),
            c.int(bounds.y + bounds.height - 20),
            14,
            rl.RAYWHITE,
        )
    }
    ui_focus_draw(bounds, focused)
    return color^ != previous
}

// ui_shortcut_modifiers_match enforces exact modifiers and optionally suppresses plain
// accelerators while a text-like control owns focus; help remains globally usable.
ui_shortcut_modifiers_match :: proc(
    binding: UI_Shortcut_Binding,
    modifiers: u8,
    suppress_unmodified: bool,
) -> bool {
    if binding.modifiers != modifiers {
        return false
    }
    return !suppress_unmodified || modifiers != 0 ||
           binding.command == .TOGGLE_HELP
}

UI_SHORTCUT_HELP_LEFT :: [?]cstring{
    "GENERAL",
    "F1 / ?       Shortcut help",
    "Tab          Next control",
    "Shift+Tab    Previous control",
    "Esc          Close active editor",
    "Mod+Q        Quit",
    "",
    "MODEL & INSPECTOR",
    "Mod+F        Search models",
    "Mod+1..4     Toggle inspector sections",
    "PgUp/PgDn    Scroll inspector",
    "Mod+Home/End Inspector top / bottom",
    "",
    "LENS & CAMERA",
    "1 / 2 / 3    Lens modes",
    "G            Toggle lens grid",
    "P            Export PNG",
    "X / Y / Z    Axis views",
    "I            Isometric view",
    "- / =        Downscale level",
    "WASD/QE      Pan / zoom",
}

UI_SHORTCUT_HELP_RIGHT :: [?]cstring{
    "ANIMATION",
    "Space        Play / pause",
    "Home         First frame",
    ", / .        Previous / next frame",
    "[ / ]        Previous / next clip",
    "L            Toggle loop",
    "K            Toggle sampled playback",
    "",
    "CEL & BACKGROUND",
    "C            Toggle Cel Shading",
    "Alt+1..3     Classic / Anime / Noir",
    "Mod+R        Reload preset",
    "Mod+S        Save preset",
    "Mod+Shift+R  Reset Classic",
    "B            Toggle background picker",
    "Shift+B      Reset background to black",
    "",
    "FOCUSED CONTROLS",
    "Enter/Space  Activate / toggle",
    "Arrows       Adjust or select",
    "Shift+Arrow  Coarse adjustment",
    "Home/End     Minimum / maximum",
    "Color: Up/Down channel, Left/Right value",
}
