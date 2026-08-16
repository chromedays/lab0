package tests

// These tests specify the semantic keyboard layer without polling real input.
// They protect exact modifiers, focus suppression, fallback focus, registry
// uniqueness, and command-side bounds enforcement.

import "core:c"
import "core:testing"
import rl "vendor:raylib"

// Shortcut matches require exact modifiers rather than accepting accidental extras.
@(test)
shortcut_binding_requires_exact_modifiers :: proc(t: ^testing.T) {
    save_binding := UI_Shortcut_Binding{.CEL_SAVE, .S, UI_MOD_PRIMARY}

    testing.expect(
        t,
        ui_shortcut_modifiers_match(save_binding, UI_MOD_PRIMARY, false),
        "primary+S should match save",
    )
    testing.expect(
        t,
        !ui_shortcut_modifiers_match(save_binding, 0, false),
        "bare S must not match save",
    )
    testing.expect(
        t,
        !ui_shortcut_modifiers_match(
            save_binding,
            UI_MOD_PRIMARY | UI_MOD_SHIFT,
            false,
        ),
        "primary+shift+S must not fall through to save",
    )
}

// Focus suppression blocks plain commands but preserves modified commands and global help.
@(test)
focused_control_only_suppresses_unmodified_accelerators :: proc(t: ^testing.T) {
    lens_binding := UI_Shortcut_Binding{.LENS_PIXELATED, .ONE, 0}
    save_binding := UI_Shortcut_Binding{.CEL_SAVE, .S, UI_MOD_PRIMARY}
    help_binding := UI_Shortcut_Binding{.TOGGLE_HELP, .F1, 0}

    testing.expect(
        t,
        !ui_shortcut_modifiers_match(lens_binding, 0, true),
        "focused controls should own bare keys",
    )
    testing.expect(
        t,
        ui_shortcut_modifiers_match(save_binding, UI_MOD_PRIMARY, true),
        "modified accelerators should remain available",
    )
    testing.expect(
        t,
        ui_shortcut_modifiers_match(help_binding, 0, true),
        "help remains globally reachable",
    )
}

// No two registry entries may claim the same key and modifier combination.
@(test)
shortcut_registry_has_no_conflicting_bindings :: proc(t: ^testing.T) {
    for left, left_index in UI_SHORTCUT_BINDINGS {
        for right, right_index in UI_SHORTCUT_BINDINGS {
            if right_index <= left_index {
                continue
            }
            if left.key == right.key && left.modifiers == right.modifiers {
                testing.expect_value(t, left.command, right.command)
            }
        }
    }
}

// Focus from a hidden child resolves to the nearest still-visible section header.
@(test)
hidden_controls_fall_back_to_their_section_header :: proc(t: ^testing.T) {
    testing.expect_value(
        t,
        ui_focus_fallback(.ANIMATION_NEXT_CLIP),
        UI_Focus_ID.ANIMATION_CLIP,
    )
    testing.expect_value(
        t,
        ui_focus_fallback(.CEL_BAND_BRIGHTNESS),
        UI_Focus_ID.CEL_BANDS_HEADER,
    )
    testing.expect_value(
        t,
        ui_focus_fallback(.BACKGROUND_PICKER),
        UI_Focus_ID.BACKGROUND_HEADER,
    )
    testing.expect_value(
        t,
        ui_focus_fallback(.CAMERA_DOWNSCALE),
        UI_Focus_ID.CAMERA_HEADER,
    )
    testing.expect_value(
        t,
        ui_focus_fallback(.CAMERA_EDGE_AA),
        UI_Focus_ID.CAMERA_HEADER,
    )
}

// Semantic command dispatch clamps downscale and inspector scrolling at both limits.
@(test)
command_dispatch_clamps_downscale_and_scroll :: proc(t: ^testing.T) {
    quit_requested := false
    help_open := false
    export_requested := false
    lens_mode := Lens_Mode.PIXELATED
    lens_grid_visible := true
    downscale_level := c.int(MIN_DOWNSCALE_LEVEL)
    inspector: Inspector_UI_State
    model_browser: Model_Browser_State
    cel_ui: Cel_Style_UI_State
    cel_style: Cel_Style
    animation: Animation_Playback
    camera: rl.Camera3D
    background := rl.BLACK
    background_picker_open := false
    command_context := App_UI_Command_Context{
        quit_requested = &quit_requested,
        shortcuts_help_open = &help_open,
        export_requested = &export_requested,
        lens_mode = &lens_mode,
        lens_grid_visible = &lens_grid_visible,
        downscale_level = &downscale_level,
        inspector = &inspector,
        inspector_max_scroll = 500,
        model_browser = &model_browser,
        cel_ui = &cel_ui,
        cel_style = &cel_style,
        animation = &animation,
        camera = &camera,
        background_color = &background,
        background_picker_open = &background_picker_open,
    }

    execute_ui_command(.DOWNSCALE_DECREASE, &command_context)
    testing.expect_value(t, downscale_level, c.int(MIN_DOWNSCALE_LEVEL))

    downscale_level = c.int(MAX_DOWNSCALE_LEVEL)
    execute_ui_command(.DOWNSCALE_INCREASE, &command_context)
    testing.expect_value(t, downscale_level, c.int(MAX_DOWNSCALE_LEVEL))

    inspector.scroll_y = 490
    execute_ui_command(.INSPECTOR_PAGE_DOWN, &command_context)
    testing.expect_value(t, inspector.scroll_y, f32(500))
    execute_ui_command(.INSPECTOR_HOME, &command_context)
    testing.expect_value(t, inspector.scroll_y, f32(0))
}
