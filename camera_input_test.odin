package main

import "core:testing"

@(test)
camera_input_hover_only_captures_mouse :: proc(t: ^testing.T) {
    input := camera_input_permissions(true, false, true)

    testing.expect(t, input.keyboard, "UI hover should not block camera keyboard input")
    testing.expect(t, !input.mouse, "UI hover should block camera mouse input")
}

@(test)
camera_input_active_ui_capture_blocks_both_sources :: proc(t: ^testing.T) {
    input := camera_input_permissions(true, true, false)

    testing.expect(t, !input.keyboard, "active UI capture should own keyboard input")
    testing.expect(t, !input.mouse, "active UI capture should own mouse input")
}

@(test)
camera_input_unfocused_window_blocks_both_sources :: proc(t: ^testing.T) {
    input := camera_input_permissions(false, false, false)

    testing.expect(t, !input.keyboard, "an unfocused window should ignore keyboard input")
    testing.expect(t, !input.mouse, "an unfocused window should ignore mouse input")
}
