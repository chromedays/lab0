package tests

// These tests specify camera/UI input ownership without opening a window. They
// model press, hold, crossing, and release frames explicitly because regressions
// usually appear at transitions rather than in steady state.

import "core:testing"

// Hovering UI blocks a new mouse gesture but leaves unfocused keyboard control available.
@(test)
camera_input_hover_only_captures_mouse :: proc(t: ^testing.T) {
    input := camera_input_permissions(true, false, true, false, false)

    testing.expect(t, input.keyboard, "UI hover should not block camera keyboard input")
    testing.expect(t, !input.mouse, "UI hover should block camera mouse input")
}

// An active/modal UI interaction must suppress both camera input channels.
@(test)
camera_input_active_ui_capture_blocks_both_sources :: proc(t: ^testing.T) {
    input := camera_input_permissions(true, true, false, false, false)

    testing.expect(t, !input.keyboard, "active UI capture should own keyboard input")
    testing.expect(t, !input.mouse, "active UI capture should own mouse input")
}

// A window without focus cannot retain keyboard or mouse camera ownership.
@(test)
camera_input_unfocused_window_blocks_both_sources :: proc(t: ^testing.T) {
    input := camera_input_permissions(false, false, false, true, true)

    testing.expect(t, !input.keyboard, "an unfocused window should ignore keyboard input")
    testing.expect(t, !input.mouse, "an unfocused window should ignore mouse input")
}

// A drag begun in the scene remains camera-owned after crossing UI bounds.
@(test)
camera_drag_keeps_mouse_when_crossing_ui :: proc(t: ^testing.T) {
    input := camera_input_permissions(true, false, true, true, true)

    testing.expect(t, input.keyboard, "UI hover should not block camera keyboard input")
    testing.expect(t, input.mouse, "an active camera drag should keep mouse ownership")
}

// A button held from a UI press cannot start camera motion merely by leaving the UI.
@(test)
ui_drag_does_not_leak_into_camera_after_leaving_ui :: proc(t: ^testing.T) {
    input := camera_input_permissions(true, false, false, false, true)

    testing.expect(t, input.keyboard, "a UI pointer drag should not block keyboard input")
    testing.expect(t, !input.mouse, "a UI-originated drag should keep mouse ownership")
}

// Orbit ownership persists through release, then clears before the following frame.
@(test)
camera_drag_owns_press_hold_and_release_frames :: proc(t: ^testing.T) {
    press_drag, active_drag := camera_mouse_drag_for_frame(
        .NONE,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
    )
    testing.expect_value(t, press_drag, Camera_Mouse_Drag.ORBIT)
    testing.expect_value(t, active_drag, Camera_Mouse_Drag.ORBIT)

    hover_drag, next_active_drag := camera_mouse_drag_for_frame(
        active_drag,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
    )
    active_drag = next_active_drag
    testing.expect_value(t, hover_drag, Camera_Mouse_Drag.ORBIT)
    testing.expect_value(t, active_drag, Camera_Mouse_Drag.ORBIT)

    release_drag, released_active_drag := camera_mouse_drag_for_frame(
        active_drag,
        true,
        false,
        true,
        false,
        false,
        false,
        false,
    )
    active_drag = released_active_drag
    testing.expect_value(t, release_drag, Camera_Mouse_Drag.ORBIT)
    testing.expect_value(t, active_drag, Camera_Mouse_Drag.NONE)

    next_drag, _ := camera_mouse_drag_for_frame(
        active_drag,
        true,
        false,
        true,
        false,
        false,
        false,
        false,
    )
    testing.expect_value(t, next_drag, Camera_Mouse_Drag.NONE)
}

// Scene drag selection refuses left/middle presses that originate over UI.
@(test)
camera_drag_cannot_begin_over_ui :: proc(t: ^testing.T) {
    frame_drag, next_drag := camera_mouse_drag_for_frame(
        .NONE,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
    )

    testing.expect_value(t, frame_drag, Camera_Mouse_Drag.NONE)
    testing.expect_value(t, next_drag, Camera_Mouse_Drag.NONE)
}
