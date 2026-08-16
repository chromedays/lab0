package main

// Viewer mode renders cel-shaded geometry into multiple intermediate textures,
// downsamples them into a configurable pixel grid, and presents both an
// interactive UI and a deterministic non-interactive capture path. This file
// owns Viewer orchestration, assets, animation, camera behavior, render-pass
// ordering, and the inlined UI composition.

import "core:fmt"
import "core:c"
import "core:os"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import shared "./shared"
import rl "vendor:raylib"
import rgl "vendor:raylib/rlgl"

// Vertex is the minimal position/color layout used by procedural debug geometry.
Vertex :: struct {
    position: [3]f32,
    color: [4]f32,
}

VS_PATH             :: "shaders/custom.vs"
FS_PATH             :: "shaders/custom.fs"
DOWNSCALE_FS_PATH   :: "shaders/downscale.fs"
CEL_BAND_FS_PATH    :: "shaders/cel_band.fs"
MASK_DOWNSCALE_FS_PATH :: "shaders/mask_downscale.fs"
OUTLINE_FS_PATH        :: "shaders/outline.fs"
ASSETS_PATH         :: "assets"
DEFAULT_MODEL_PATH  :: "assets/CesiumMan.glb"
ANIMATION_SAMPLE_FPS :: 60.0
GLTF_SKIN_SCALE_EPSILON :: f32(0.0001)

DEFAULT_DOWNSCALE_LEVEL :: 10
MIN_DOWNSCALE_LEVEL     :: 1
MAX_DOWNSCALE_LEVEL     :: 32
LENS_WIDTH              :: 400
LENS_HEIGHT             :: 400
DEFAULT_LENS_SIZE       :: f32(400)
MIN_LENS_SIZE           :: f32(320)
LENS_RESIZE_HANDLE_SIZE :: f32(10)
LENS_RESIZE_HIT_SIZE    :: f32(18)
LENS_LAYOUT_GAP         :: f32(10)
DEFAULT_COLOR_CLUSTER_THRESHOLD :: 0.10
MODEL_SEARCH_TEXT_CAPACITY :: 128
INSPECTOR_LENS_EXPANDED_HEIGHT :: f32(116)
INSPECTOR_CAMERA_EXPANDED_HEIGHT :: f32(174)
ANIMATION_TIMELINE_HEIGHT :: f32(90)
ANIMATION_TIMELINE_BOTTOM_MARGIN :: f32(10)
ANIMATION_CLIP_POPUP_ROW_HEIGHT :: f32(32)
LENS_CONTROL_BAR_HEIGHT :: f32(32)
LENS_CONTROL_BAR_GAP    :: f32(8)
LENS_UI_OPACITY         :: f32(0.8)

MAGNIFIER_SAMPLE_SIZE  :: 16
MAGNIFIER_DISPLAY_SCALE :: 8

SUPPORTED_MODEL_EXTENSIONS := [?]string{
    ".obj",
    ".iqm",
    ".gltf",
    ".glb",
    ".vox",
    ".m3d",
}

// lens_mode_replaces_scene reports whether the lens should hide the full-resolution
// scene beneath its transparent low-resolution texture. Only Blended intentionally
// preserves the scene as a comparison layer.
lens_mode_replaces_scene :: proc(lens_mode: shared.Lens_Mode) -> bool {
    return lens_mode != .BLENDED
}

// shared.Lens_Mode selects how the low-resolution render is composited into the
// square lens: nearest pixels, a 50/50 blend, or raw subpixel coverage visualization.
get_model_center :: proc(model: rl.Model) -> rl.Vector3 {
    model_bounds := rl.GetModelBoundingBox(model)
    return {
        model_bounds.min.x + (model_bounds.max.x - model_bounds.min.x) * 0.5,
        model_bounds.min.y + (model_bounds.max.y - model_bounds.min.y) * 0.5,
        model_bounds.min.z + (model_bounds.max.z - model_bounds.min.z) * 0.5,
    }
}

// reset_camera_to_axis_view preserves a sensible orbit radius while replacing
// orientation and pivot with a reproducible axis or isometric view.
reset_camera_to_axis_view :: proc(
    camera: ^rl.Camera3D,
    pivot: rl.Vector3,
    axis: rl.Vector3,
    up: rl.Vector3,
    scene_size: f32,
) {
    // Orthographic projection does not use the orbit radius for framing, but
    // retaining it keeps the near/far relationship stable after the reset.
    orbit_radius := rl.Vector3Length(camera.position - camera.target)
    if orbit_radius < 0.00001 {
        orbit_radius = max(scene_size * 3, 1)
    }

    camera.target = pivot
    camera.position = pivot + axis * orbit_radius
    camera.up = up
}

// viewer_isometric_camera_frame builds the shared initial Viewer camera and
// sizes its orthographic projection from the model's screen-space AABB extent.
// The +X/+Y/+Z direction gives each world axis equal weight in the first view.
viewer_isometric_camera_frame :: proc(
    model_center: rl.Vector3,
    model_dimensions: rl.Vector3,
    scene_size: f32,
    screen_height: f32,
) -> (camera: rl.Camera3D, projected_width, projected_height: f32) {
    isometric_axis := rl.Vector3Normalize(rl.Vector3{1, 1, 1})
    camera = rl.Camera3D{
        target     = model_center,
        position   = model_center + isometric_axis * max(scene_size * 3, 1),
        up         = {0, 1, 0},
        projection = .ORTHOGRAPHIC,
    }

    // Project all eight AABB corners without enumerating them. For a centered
    // box, its interval length along a unit axis is sum(abs(axis) * dimension).
    camera_forward := rl.GetCameraForward(&camera)
    camera_right := rl.GetCameraRight(&camera)
    camera_screen_up := rl.Vector3Normalize(
        rl.Vector3CrossProduct(camera_right, camera_forward),
    )
    projected_width =
        math.abs(camera_right.x) * model_dimensions.x +
        math.abs(camera_right.y) * model_dimensions.y +
        math.abs(camera_right.z) * model_dimensions.z
    projected_height =
        math.abs(camera_screen_up.x) * model_dimensions.x +
        math.abs(camera_screen_up.y) * model_dimensions.y +
        math.abs(camera_screen_up.z) * model_dimensions.z

    if projected_width <= 0 {
        projected_width = scene_size
    }
    if projected_height <= 0 {
        projected_height = scene_size
    }

    // raylib's orthographic fovy is the full screen height in world units.
    // Fit the projected model into the 400x400 lens with 10% padding per side.
    lens_fill: f32 = 0.8
    safe_screen_height := max(screen_height, 1)
    fovy_for_width :=
        projected_width * safe_screen_height / f32(LENS_WIDTH) / lens_fill
    fovy_for_height :=
        projected_height * safe_screen_height / f32(LENS_HEIGHT) / lens_fill
    camera.fovy = max(fovy_for_width, fovy_for_height)
    return
}

// frame_camera_to_model computes model bounds, chooses a lens-aware isometric
// camera, and returns the largest model dimension used as the movement scale.
frame_camera_to_model :: proc(
    model: rl.Model,
    camera: ^rl.Camera3D,
) -> f32 {
    model_bounds := rl.GetModelBoundingBox(model)
    model_center := rl.Vector3{
        model_bounds.min.x + (model_bounds.max.x - model_bounds.min.x) * 0.5,
        model_bounds.min.y + (model_bounds.max.y - model_bounds.min.y) * 0.5,
        model_bounds.min.z + (model_bounds.max.z - model_bounds.min.z) * 0.5,
    }
    model_dimensions := rl.Vector3{
        model_bounds.max.x - model_bounds.min.x,
        model_bounds.max.y - model_bounds.min.y,
        model_bounds.max.z - model_bounds.min.z,
    }
    scene_size := max(
        model_dimensions.x,
        max(model_dimensions.y, model_dimensions.z),
    )
    if scene_size <= 0 {
        scene_size = 1
    }

    projected_width, projected_height: f32
    camera^, projected_width, projected_height =
        viewer_isometric_camera_frame(
            model_center,
            model_dimensions,
            scene_size,
            f32(rl.GetScreenHeight()),
        )
    log.infof(
        "Isometric lens framing: projected(%f, %f), ortho fovy=%f",
        projected_width,
        projected_height,
        camera.fovy,
    )

    log.infof(
        "Model bounding box: min(%f, %f, %f), max(%f, %f, %f)",
        model_bounds.min.x,
        model_bounds.min.y,
        model_bounds.min.z,
        model_bounds.max.x,
        model_bounds.max.y,
        model_bounds.max.z,
    )
    return scene_size
}

// inspector_section_height collapses a section to the shared header height.
inspector_section_height :: proc(expanded: bool, expanded_height: f32) -> f32 {
    if expanded {
        return expanded_height
    }
    return INSPECTOR_SECTION_HEADER_HEIGHT
}

// inspector_lens_section_offset returns the Lens section's scroll-space Y.
inspector_lens_section_offset :: proc(state: ^Inspector_UI_State) -> f32 {
    return inspector_section_height(state.model_open, 310) +
           INSPECTOR_SECTION_GAP
}

// inspector_camera_section_offset returns the Camera section's scroll-space Y.
inspector_camera_section_offset :: proc(state: ^Inspector_UI_State) -> f32 {
    return inspector_lens_section_offset(state) +
           inspector_section_height(
               state.lens_open,
               INSPECTOR_LENS_EXPANDED_HEIGHT,
           ) +
           INSPECTOR_SECTION_GAP
}

// inspector_cel_section_offset computes the cel editor's scroll-space Y offset
// from the expansion state of the preceding model, lens, and camera sections.
inspector_cel_section_offset :: proc(state: ^Inspector_UI_State) -> f32 {
    return inspector_camera_section_offset(state) +
           inspector_section_height(
               state.camera_open,
               INSPECTOR_CAMERA_EXPANDED_HEIGHT,
           ) +
           INSPECTOR_SECTION_GAP
}

// inspector_content_height combines every section's current extent so scrolling
// and scrollbar geometry can be resolved before clipped controls are drawn.
inspector_content_height :: proc(
    state: ^Inspector_UI_State,
    cel_style_ui: ^Cel_Style_UI_State,
    cel_style: ^shared.Cel_Style,
) -> f32 {
    return inspector_cel_section_offset(state) +
           cel_style_editor_height(cel_style_ui, cel_style) +
           INSPECTOR_SECTION_GAP +
           inspector_section_height(state.background_open, 120)
}

// Camera_Input_Permissions separates keyboard and mouse eligibility because UI
// focus may block one input source without blocking an owned scene drag.
Camera_Input_Permissions :: struct {
    keyboard: bool,
    mouse:    bool,
}

// Camera_Mouse_Drag records which scene gesture owns a held mouse button.
Camera_Mouse_Drag :: enum {
    NONE,
    ORBIT,
    PAN,
}

// centered_lens_bounds preserves the Viewer's established screen-centered lens
// while allowing its one square dimension to change independently each frame.
centered_lens_bounds :: proc(
    screen_width, screen_height: c.int,
    size: f32,
) -> rl.Rectangle {
    return {
        (f32(screen_width) - size) * 0.5,
        (f32(screen_height) - size) * 0.5,
        size,
        size,
    }
}

// lens_layout_max_size keeps the centered lens handle clear of the inspector
// and the animation timeline (when present). The caller supplies the bottom UI
// boundary so non-animated models can use the additional vertical space.
lens_layout_max_size :: proc(
    screen_width, screen_height: c.int,
    inspector_left, lower_ui_top: f32,
) -> f32 {
    center_x := f32(screen_width) * 0.5
    center_y := f32(screen_height) * 0.5
    horizontal_size := 2 * (inspector_left - LENS_LAYOUT_GAP - center_x)
    vertical_size := 2 * (lower_ui_top - LENS_LAYOUT_GAP - center_y)
    return max(min(horizontal_size, vertical_size), MIN_LENS_SIZE)
}

// lens_resize_handle_bounds returns the generous hit region centered on the
// visible lower-right corner handle.
lens_resize_handle_bounds :: proc(lens_bounds: rl.Rectangle) -> rl.Rectangle {
    return {
        lens_bounds.x + lens_bounds.width - LENS_RESIZE_HIT_SIZE * 0.5,
        lens_bounds.y + lens_bounds.height - LENS_RESIZE_HIT_SIZE * 0.5,
        LENS_RESIZE_HIT_SIZE,
        LENS_RESIZE_HIT_SIZE,
    }
}

// lens_control_bar_bounds attaches the mode bar above the lens and its footer
// below it. A large lens moves the translucent footer just inside the crop
// before it can overlap lower UI such as the animation timeline.
lens_control_bar_bounds :: proc(
    lens_bounds: rl.Rectangle,
    lower_ui_top: f32,
) -> (mode_bar, footer: rl.Rectangle) {
    mode_bar = {
        lens_bounds.x,
        lens_bounds.y - LENS_CONTROL_BAR_HEIGHT - LENS_CONTROL_BAR_GAP,
        lens_bounds.width,
        LENS_CONTROL_BAR_HEIGHT,
    }
    footer = {
        lens_bounds.x,
        lens_bounds.y + lens_bounds.height + LENS_CONTROL_BAR_GAP,
        lens_bounds.width,
        LENS_CONTROL_BAR_HEIGHT,
    }
    if footer.y + footer.height > lower_ui_top - LENS_LAYOUT_GAP {
        footer.y = lens_bounds.y + lens_bounds.height - footer.height -
                   LENS_CONTROL_BAR_GAP
    }
    return
}

// lens_resize_size_for_pointer converts a corner position into a centered
// square size. Snapping to the current downscale level avoids changing size by
// fractions of a displayed low-resolution pixel.
lens_resize_size_for_pointer :: proc(
    pointer_x, pointer_y, center_x, center_y: f32,
    minimum_size, maximum_size, snap_step: f32,
) -> f32 {
    requested_size := 2 * max(pointer_x - center_x, pointer_y - center_y)
    result := clamp(requested_size, minimum_size, maximum_size)
    if snap_step > 0 {
        result = math.round(result / snap_step) * snap_step
        result = clamp(result, minimum_size, maximum_size)
    }
    return result
}

// lens_resize_drag_for_frame gives a handle-originated left drag stable
// ownership through its release frame, mirroring the camera drag contract.
lens_resize_drag_for_frame :: proc(
    previous_drag, window_focused, input_blocked, mouse_over_handle,
    left_pressed, left_down: bool,
) -> (frame_drag, next_drag: bool) {
    if !window_focused {
        return false, false
    }

    frame_drag = previous_drag
    if !frame_drag && !input_blocked && mouse_over_handle && left_pressed {
        frame_drag = true
    }

    next_drag = frame_drag && left_down
    return
}

// camera_mouse_drag_for_frame chooses drag ownership on the press frame and
// retains it through the release frame, preventing UI controls from stealing or
// inheriting a gesture after the pointer crosses their bounds.
camera_mouse_drag_for_frame :: proc(
    previous_drag: Camera_Mouse_Drag,
    window_focused: bool,
    ui_captures_input: bool,
    mouse_over_ui: bool,
    left_pressed: bool,
    middle_pressed: bool,
    left_down: bool,
    middle_down: bool,
) -> (frame_drag, next_drag: Camera_Mouse_Drag) {
    if !window_focused {
        return .NONE, .NONE
    }

    frame_drag = previous_drag
    if frame_drag == .NONE && !ui_captures_input && !mouse_over_ui {
        if left_pressed {
            frame_drag = .ORBIT
        } else if middle_pressed {
            frame_drag = .PAN
        }
    }

    // The release frame is still owned by the drag that began in the scene.
    // This prevents a raygui control under the release position from treating
    // that release as its own click.
    next_drag = frame_drag
    switch frame_drag {
    case .ORBIT:
        if !left_down {
            next_drag = .NONE
        }
    case .PAN:
        if !middle_down {
            next_drag = .NONE
        }
    case .NONE:
    }
    return
}

// camera_input_permissions applies focus, hover, and drag-ownership rules to
// derive the two input channels consumed by camera movement code.
camera_input_permissions :: proc(
    window_focused: bool,
    ui_captures_input: bool,
    mouse_over_ui: bool,
    camera_drag_owns_mouse: bool,
    camera_drag_button_down: bool,
) -> Camera_Input_Permissions {
    if !window_focused {
        return {}
    }

    // A drag keeps the owner chosen on its press frame. shared.Scene drags may cross
    // the UI without stopping, while UI-originated drags may leave the UI
    // without leaking their held button into the camera controls.
    return {
        keyboard = !ui_captures_input,
        mouse    = camera_drag_owns_mouse ||
                   (!ui_captures_input &&
                    !mouse_over_ui &&
                    !camera_drag_button_down),
    }
}

// App_UI_Command_Context groups pointers to every state slice a semantic command
// may mutate, keeping execute_ui_command independent of frame-local variables.
App_UI_Command_Context :: struct {
    keyboard:                ^shared.UI_Keyboard_State,
    quit_requested:          ^bool,
    shortcuts_help_open:     ^bool,
    render_debug:            ^Viewer_Render_Debug_State,
    export_requested:        ^bool,
    lens_mode:               ^shared.Lens_Mode,
    lens_grid_visible:       ^bool,
    downscale_level:         ^c.int,
    inspector:               ^Inspector_UI_State,
    inspector_max_scroll:    f32,
    model_browser:           ^shared.Model_Browser_State,
    cel_ui:                  ^Cel_Style_UI_State,
    cel_style:               ^shared.Cel_Style,
    animation:               ^shared.Animation_Playback,
    camera:                  ^rl.Camera3D,
    model_center:            rl.Vector3,
    scene_size:              f32,
    background_color:        ^rl.Color,
    background_picker_open:  ^bool,
}

// execute_ui_command applies one already-filtered semantic command. It also
// maintains modal exclusivity, focus transfer, scroll positioning, and bounds
// clamping so keyboard actions match their corresponding visible controls.
execute_ui_command :: proc(
    command: shared.UI_Command,
    command_context: ^App_UI_Command_Context,
) {
    #partial switch command {
    case .TOGGLE_HELP:
        command_context.shortcuts_help_open^ =
            !command_context.shortcuts_help_open^
        if command_context.shortcuts_help_open^ {
            shared.ui_keyboard_focus_set(command_context.keyboard, .HELP_CLOSE)
        } else {
            shared.ui_keyboard_focus_clear(command_context.keyboard)
        }
    case .TOGGLE_RENDER_DEBUG:
        if command_context.render_debug.open {
            viewer_render_debug_close(
                command_context.render_debug,
                command_context.animation,
            )
        } else {
            command_context.render_debug.open = true
            command_context.render_debug.sample_valid = false
            command_context.shortcuts_help_open^ = false
            command_context.background_picker_open^ = false
            command_context.animation.dropdown_open = false
            command_context.model_browser.search_editing = false
            command_context.cel_ui.color_target = .NONE
            shared.ui_keyboard_focus_clear(command_context.keyboard)
        }
    case .QUIT:
        command_context.quit_requested^ = true
    case .FOCUS_MODEL_SEARCH:
        command_context.inspector.model_open = true
        command_context.inspector.scroll_y = 0
        command_context.model_browser.search_editing = true
        command_context.animation.dropdown_open = false
        command_context.background_picker_open^ = false
        command_context.cel_ui.color_target = .NONE
        shared.ui_keyboard_focus_set(command_context.keyboard, .MODEL_SEARCH)
        // Prevent the shortcut key from becoming search text.
        for rl.GetCharPressed() != 0 {}
    case .TOGGLE_MODEL_SECTION:
        command_context.inspector.model_open =
            !command_context.inspector.model_open
        if command_context.inspector.model_open {
            command_context.inspector.scroll_y = 0
        }
        if !command_context.inspector.model_open {
            command_context.model_browser.search_editing = false
        }
    case .TOGGLE_CAMERA_SECTION:
        command_context.inspector.camera_open =
            !command_context.inspector.camera_open
        if command_context.inspector.camera_open {
            command_context.inspector.scroll_y = inspector_camera_section_offset(
                command_context.inspector,
            )
        }
    case .TOGGLE_CEL_SECTION:
        command_context.cel_ui.open = !command_context.cel_ui.open
        if command_context.cel_ui.open {
            command_context.background_picker_open^ = false
            command_context.animation.dropdown_open = false
            sync_cel_style_light_angles(
                command_context.cel_ui,
                command_context.cel_style,
            )
            command_context.inspector.scroll_y = inspector_cel_section_offset(
                command_context.inspector,
            )
            shared.ui_keyboard_focus_set(command_context.keyboard, .CEL_HEADER)
        } else {
            command_context.cel_ui.color_target = .NONE
        }
    case .TOGGLE_BACKGROUND_SECTION:
        command_context.inspector.background_open =
            !command_context.inspector.background_open
        if command_context.inspector.background_open {
            command_context.inspector.scroll_y =
                command_context.inspector_max_scroll
        }
        if !command_context.inspector.background_open {
            command_context.background_picker_open^ = false
        }
    case .INSPECTOR_PAGE_UP:
        command_context.inspector.scroll_y = max(
            command_context.inspector.scroll_y - 210,
            f32(0),
        )
    case .INSPECTOR_PAGE_DOWN:
        command_context.inspector.scroll_y = min(
            command_context.inspector.scroll_y + 210,
            command_context.inspector_max_scroll,
        )
    case .INSPECTOR_HOME:
        command_context.inspector.scroll_y = 0
    case .INSPECTOR_END:
        command_context.inspector.scroll_y = command_context.inspector_max_scroll
    case .LENS_PIXELATED:
        command_context.lens_mode^ = .PIXELATED
        log.info("Lens mode: pixelated")
    case .LENS_BLENDED:
        command_context.lens_mode^ = .BLENDED
        log.info("Lens mode: blended 50/50")
    case .LENS_COVERAGE:
        command_context.lens_mode^ = .COVERAGE_MASK
        log.info("Lens mode: 16-sample coverage mask")
    case .TOGGLE_LENS_GRID:
        command_context.lens_grid_visible^ =
            !command_context.lens_grid_visible^
        if command_context.lens_grid_visible^ {
            log.info("Lens grid: on")
        } else {
            log.info("Lens grid: off")
        }
    case .EXPORT_PNG:
        command_context.export_requested^ = true
    case .CAMERA_X:
        reset_camera_to_axis_view(
            command_context.camera,
            command_context.model_center,
            {1, 0, 0},
            {0, 1, 0},
            command_context.scene_size,
        )
    case .CAMERA_Y:
        reset_camera_to_axis_view(
            command_context.camera,
            command_context.model_center,
            {0, 1, 0},
            {0, 0, 1},
            command_context.scene_size,
        )
    case .CAMERA_Z:
        reset_camera_to_axis_view(
            command_context.camera,
            command_context.model_center,
            {0, 0, 1},
            {0, 1, 0},
            command_context.scene_size,
        )
    case .CAMERA_ISOMETRIC:
        reset_camera_to_axis_view(
            command_context.camera,
            command_context.model_center,
            rl.Vector3Normalize({1, 1, 1}),
            {0, 1, 0},
            command_context.scene_size,
        )
    case .DOWNSCALE_DECREASE:
        command_context.downscale_level^ = max(
            command_context.downscale_level^ - 1,
            c.int(MIN_DOWNSCALE_LEVEL),
        )
    case .DOWNSCALE_INCREASE:
        command_context.downscale_level^ = min(
            command_context.downscale_level^ + 1,
            c.int(MAX_DOWNSCALE_LEVEL),
        )
    case .ANIMATION_PLAY_PAUSE:
        if shared.animation_playback_has_playable_animations(command_context.animation) {
            command_context.animation.is_playing =
                !command_context.animation.is_playing
        }
    case .ANIMATION_FIRST_FRAME:
        if shared.animation_playback_has_playable_animations(command_context.animation) {
            shared.animation_playback_reset_to_first_frame(command_context.animation)
        }
    case .ANIMATION_PREVIOUS_FRAME:
        _ = shared.animation_playback_step_frame(command_context.animation, -1)
    case .ANIMATION_NEXT_FRAME:
        _ = shared.animation_playback_step_frame(command_context.animation, 1)
    case .ANIMATION_PREVIOUS_CLIP:
        _ = shared.animation_playback_cycle_clip(command_context.animation, -1)
    case .ANIMATION_NEXT_CLIP:
        _ = shared.animation_playback_cycle_clip(command_context.animation, 1)
    case .ANIMATION_TOGGLE_LOOP:
        if shared.animation_playback_has_playable_animations(command_context.animation) {
            command_context.animation.loop = !command_context.animation.loop
        }
    case .ANIMATION_TOGGLE_SAMPLED:
        if animation, found := shared.animation_playback_find_active_animation(command_context.animation);
           found {
            command_context.animation.sampled_playback =
                !command_context.animation.sampled_playback
            if command_context.animation.sampled_playback {
                command_context.animation.current_frame = shared.animation_playback_pose_frame(
                    command_context.animation,
                    animation,
                )
            }
            command_context.animation.pose_dirty = true
        }
    case .CEL_PRESET_CLASSIC, .CEL_PRESET_ANIME, .CEL_PRESET_NOIR:
        preset_index: c.int
        if command == .CEL_PRESET_ANIME {
            preset_index = 1
        } else if command == .CEL_PRESET_NOIR {
            preset_index = 2
        }
        command_context.cel_ui.preset_index = preset_index
        _ = load_selected_cel_style_preset(
            command_context.cel_ui,
            command_context.cel_style,
        )
    case .CEL_RELOAD:
        _ = load_selected_cel_style_preset(
            command_context.cel_ui,
            command_context.cel_style,
        )
    case .CEL_SAVE:
        _ = save_selected_cel_style_preset(
            command_context.cel_ui,
            command_context.cel_style,
        )
    case .CEL_RESET:
        reset_cel_style_to_classic(
            command_context.cel_ui,
            command_context.cel_style,
        )
    case .TOGGLE_BACKGROUND_PICKER:
        command_context.inspector.background_open = true
        command_context.background_picker_open^ =
            !command_context.background_picker_open^
        if command_context.background_picker_open^ {
            command_context.cel_ui.color_target = .NONE
            command_context.animation.dropdown_open = false
            shared.ui_keyboard_focus_set(command_context.keyboard, .BACKGROUND_PICKER)
        }
    case .RESET_BACKGROUND:
        command_context.background_color^ = rl.BLACK
    }
}

// run_viewer_mode owns every long-lived CPU/GPU resource and the complete Viewer loop.
// A single outer block preserves structured defer cleanup while allowing startup
// and capture failures to set exit codes: 0 success, 1 render/export failure,
// and 2 invalid capture configuration or state.
run_viewer_mode :: proc(arguments: []string) -> int {
    exit_code := 0
    // Keep inline startup and shutdown under one named cleanup scope.
    application_scope: {
        console_logger := log.create_console_logger()
        defer log.destroy_console_logger(console_logger)
        context.logger = console_logger

        capture_parse_result := shared.capture_options_parse(arguments)
        defer shared.capture_options_destroy(&capture_parse_result.options)
        if capture_parse_result.options.help_requested {
            shared.cli_capture_usage_print()
            exit_code = 0
            break application_scope
        }
        if capture_parse_result.error != .NONE {
            log.errorf(
                "%s: %s",
                shared.capture_parse_error_message(capture_parse_result.error),
                capture_parse_result.error_argument,
            )
            shared.cli_capture_usage_print()
            exit_code = 2
            break application_scope
        }
        capture_options := &capture_parse_result.options
        viewer_video_options_error := validate_viewer_video_options(
            capture_options,
        )
        if viewer_video_options_error != .NONE {
            log.error(
                viewer_video_options_error_message(viewer_video_options_error),
            )
            shared.cli_capture_usage_print()
            exit_code = 2
            break application_scope
        }
        viewer_video_enabled := len(capture_options.video_output) > 0
        viewer_video_encoder: shared.Video_Stream_Encoder
        defer shared.video_stream_encoder_destroy(&viewer_video_encoder)

        cel_style := shared.cel_style_make_classic()
        defer shared.cel_style_destroy(&cel_style)
        if capture_options.enabled && len(capture_options.style_path) > 0 {
            loaded_style, style_error := shared.cel_style_load(capture_options.style_path)
            if style_error != .NONE {
                log.errorf(
                    "Failed to load capture cel style %s: %s",
                    capture_options.style_path,
                    shared.cel_style_error_message(style_error),
                )
                exit_code = 2
                break application_scope
            }
            shared.cel_style_move_assign(&cel_style, &loaded_style)
        }

        // Scan and label model sources inline during the application's only startup.
        model_assets: shared.Model_Assets
        {
            directory_walker := os.walker_create(ASSETS_PATH)
            defer os.walker_destroy(&directory_walker)

            for asset_entry in os.walker_walk(&directory_walker) {
                if failed_path, walk_error := os.walker_error(&directory_walker);
                   walk_error != nil {
                    log.errorf(
                        "Failed to scan model asset %s: %v",
                        failed_path,
                        walk_error,
                    )
                    continue
                }
                model_path_supported := false
                model_extension := os.ext(asset_entry.fullpath)
                for supported_extension in SUPPORTED_MODEL_EXTENSIONS {
                    if strings.equal_fold(model_extension, supported_extension) {
                        model_path_supported = true
                        break
                    }
                }
                if asset_entry.type != .Regular || !model_path_supported {
                    continue
                }
                append(&model_assets.paths, strings.clone(asset_entry.fullpath))
            }

            slice.sort_by_key(
                model_assets.paths[:],
                proc(asset_path: string) -> string { return asset_path },
            )
            for asset_path in model_assets.paths {
                append(&model_assets.kinds, shared.Model_Source_Kind.ASSET)
                display_label := asset_path
                asset_marker := "/" + ASSETS_PATH + "/"
                if marker_index := strings.last_index(asset_path, asset_marker);
                   marker_index >= 0 {
                    display_label = asset_path[marker_index + len(asset_marker):]
                } else {
                    display_label = strings.trim_prefix(
                        asset_path,
                        ASSETS_PATH + "/",
                    )
                }
                if len(display_label) > 36 {
                    display_label = fmt.tprintf(
                        "%s...%s",
                        display_label[:14],
                        display_label[len(display_label) - 19:],
                    )
                }
                append(
                    &model_assets.labels,
                    strings.clone_to_cstring(display_label),
                )
            }

            for builtin_source in shared.BUILTIN_MODEL_SOURCES {
                append(&model_assets.paths, strings.clone(builtin_source.path))
                append(
                    &model_assets.labels,
                    strings.clone_to_cstring(builtin_source.label),
                )
                append(&model_assets.kinds, builtin_source.kind)
            }

            log.infof(
                "Found %d model assets under %s and added 3 built-in models",
                len(model_assets.paths) - 3,
                ASSETS_PATH,
            )
        }
        defer shared.model_assets_destroy(&model_assets)

        rl.SetTraceLogLevel(.WARNING);
        if capture_options.enabled {
            if capture_options.hide_window {
                rl.SetConfigFlags({.WINDOW_ALWAYS_RUN, .WINDOW_HIDDEN})
            } else {
                rl.SetConfigFlags({.WINDOW_ALWAYS_RUN})
            }
        } else {
            rl.SetConfigFlags({.WINDOW_TOPMOST})
        }
        rl.InitWindow(1280, 720, "Lab0")
        defer rl.CloseWindow();
        rl.SetExitKey(.KEY_NULL)
        if capture_options.enabled {
            // Keep raygui hover and the coverage probe independent of the desktop's
            // shared cursor while a deterministic capture is running.
            rl.SetMouseOffset(-100000, -100000)
        }
        rgl.SetClipPlanes(0.001, 1000.0)

        rl.SetTargetFPS(60);

        scene_shader_load := shared.shader_program_load_with_includes(VS_PATH, FS_PATH)
        scene_shader := scene_shader_load.shader
        scene_shader_source := scene_shader_load.program_source
        defer rl.UnloadShader(scene_shader)
        defer shared.shader_preprocessed_program_source_destroy(&scene_shader_source)
        if scene_shader_load.error != .NONE {
            log.errorf(
                "Failed to load Viewer scene shader: %s",
                shared.shader_load_error_message(scene_shader_load.error),
            )
            exit_code = 1
            break application_scope
        }
        scene_cel_bindings := shared.cel_shader_bindings_resolve(scene_shader)

        downscale_shader_load := shared.shader_fragment_load_with_includes(
            DOWNSCALE_FS_PATH,
        )
        downscale_shader := downscale_shader_load.shader
        downscale_shader_source := downscale_shader_load.source
        defer rl.UnloadShader(downscale_shader)
        defer shared.shader_preprocessed_source_destroy(&downscale_shader_source)
        if downscale_shader_load.error != .NONE {
            log.errorf(
                "Failed to load Viewer downscale shader: %s",
                shared.shader_load_error_message(downscale_shader_load.error),
            )
            exit_code = 1
            break application_scope
        }

        cel_band_shader_load := shared.shader_program_load_with_includes(
            VS_PATH,
            CEL_BAND_FS_PATH,
        )
        cel_band_shader := cel_band_shader_load.shader
        cel_band_shader_source := cel_band_shader_load.program_source
        defer shared.shader_preprocessed_program_source_destroy(&cel_band_shader_source)
        if cel_band_shader_load.error != .NONE {
            log.errorf(
                "Failed to load Viewer cel-band shader: %s",
                shared.shader_load_error_message(cel_band_shader_load.error),
            )
            exit_code = 1
            break application_scope
        }
        cel_band_bindings := shared.cel_shader_bindings_resolve(cel_band_shader)

        mask_shader_load := shared.shader_fragment_load_with_includes(
            MASK_DOWNSCALE_FS_PATH,
        )
        mask_downscale_shader := mask_shader_load.shader
        mask_downscale_shader_source := mask_shader_load.source
        defer rl.UnloadShader(mask_downscale_shader)
        defer shared.shader_preprocessed_source_destroy(&mask_downscale_shader_source)
        if mask_shader_load.error != .NONE {
            log.errorf(
                "Failed to load Viewer coverage shader: %s",
                shared.shader_load_error_message(mask_shader_load.error),
            )
            exit_code = 1
            break application_scope
        }

        outline_shader_load := shared.shader_fragment_load_with_includes(OUTLINE_FS_PATH)
        outline_shader := outline_shader_load.shader
        outline_shader_source := outline_shader_load.source
        defer rl.UnloadShader(outline_shader)
        defer shared.shader_preprocessed_source_destroy(&outline_shader_source)
        if outline_shader_load.error != .NONE {
            log.errorf(
                "Failed to load Viewer outline shader: %s",
                shared.shader_load_error_message(outline_shader_load.error),
            )
            exit_code = 1
            break application_scope
        }

        render_debug_shader_load := shared.shader_fragment_load_with_includes(
            VIEWER_DEBUG_FS_PATH,
        )
        render_debug_shader := render_debug_shader_load.shader
        render_debug_shader_source := render_debug_shader_load.source
        defer rl.UnloadShader(render_debug_shader)
        defer shared.shader_preprocessed_source_destroy(&render_debug_shader_source)
        if render_debug_shader_load.error != .NONE {
            log.errorf(
                "Failed to load Viewer render-debug shader: %s",
                shared.shader_load_error_message(render_debug_shader_load.error),
            )
            exit_code = 1
            break application_scope
        }

        // Build the ramp texture inline at its only creation site.
        cel_ramp_pixels := shared.cel_ramp_pixels_build(&cel_style)
        cel_ramp_image := rl.Image{
            data = raw_data(cel_ramp_pixels[:]),
            width = shared.CEL_RAMP_WIDTH,
            height = 1,
            mipmaps = 1,
            format = .UNCOMPRESSED_R8G8B8A8,
        }
        cel_ramp_texture := rl.LoadTextureFromImage(cel_ramp_image)
        if rl.IsTextureValid(cel_ramp_texture) {
            rl.SetTextureFilter(cel_ramp_texture, .POINT)
            rl.SetTextureWrap(cel_ramp_texture, .CLAMP)
        }
        defer rl.UnloadTexture(cel_ramp_texture)
        assert(rl.IsTextureValid(cel_ramp_texture))
        applied_cel_ramp_revision := cel_style.revision

        active_model: rl.Model
        animation_playback: shared.Animation_Playback
        defer {
            shared.animation_playback_destroy(&animation_playback)
            if shared.model_is_loaded(active_model) {
                rl.UnloadModel(active_model)
            }
        }

        render_camera := rl.Camera3D{
            position   = {1.5, 0.7, 1.5},
            target     = {},
            up         = {0, 1, 0},
            fovy       = 2.5,
            projection = .ORTHOGRAPHIC,
        }
        scene_size: f32 = 1
        model_center: rl.Vector3
        loaded_model_index: c.int = -1
        model_active_index: c.int = -1
        model_load_failed := false
        model_browser := shared.Model_Browser_State{
            active_index = -1,
            focus_index = -1,
        }
        defer shared.model_browser_state_destroy(&model_browser)
        shared.model_search_results_rebuild(&model_assets, &model_browser)

        if len(model_assets.paths) > 0 {
            initial_model_index := 0
            if capture_options.enabled && len(capture_options.model_source) > 0 {
                requested_model_index, requested_model_found :=
                    shared.capture_find_model_source(
                        &model_assets,
                        capture_options.model_source,
                    )
                if !requested_model_found {
                    log.errorf(
                        "Capture model source was not found: %s",
                        capture_options.model_source,
                    )
                    exit_code = 2
                    break application_scope
                }
                initial_model_index = requested_model_index
            } else {
                for model_path, model_index in model_assets.paths {
                    if model_path == DEFAULT_MODEL_PATH ||
                       strings.has_suffix(model_path, "/" + DEFAULT_MODEL_PATH) {
                        initial_model_index = model_index
                        break
                    }
                }
            }

            initial_model, initial_model_error := shared.model_source_load(
                &model_assets,
                initial_model_index,
            )
            if initial_model_error == .NONE {
                active_model = initial_model
                animation_load := shared.animation_playback_load(
                    active_model,
                    model_assets.paths[initial_model_index],
                    model_assets.kinds[initial_model_index],
                )
                animation_playback = animation_load.playback
                model_center = get_model_center(active_model)
                loaded_model_index = c.int(initial_model_index)
                model_active_index = loaded_model_index
                shared.model_browser_active_source_set(
                    &model_browser,
                    loaded_model_index,
                )
                scene_size = frame_camera_to_model(
                    active_model,
                    &render_camera,
                )
                if capture_options.enabled {
                    // Apply the requested fixed capture view at its only setup site.
                    switch capture_options.view {
                    // The initial camera is already isometric. Keep both
                    // spellings bit-identical instead of normalizing it again.
                    case .DEFAULT, .ISOMETRIC:
                    case .X:
                        reset_camera_to_axis_view(
                            &render_camera,
                            model_center,
                            {1, 0, 0},
                            {0, 1, 0},
                            scene_size,
                        )
                    case .Y:
                        reset_camera_to_axis_view(
                            &render_camera,
                            model_center,
                            {0, 1, 0},
                            {0, 0, 1},
                            scene_size,
                        )
                    case .Z:
                        reset_camera_to_axis_view(
                            &render_camera,
                            model_center,
                            {0, 0, 1},
                            {0, 1, 0},
                            scene_size,
                        )
                    }
                    animation_playback.is_playing = false
                    if capture_options.animation_frame_set ||
                       capture_options.frame_range_set {
                        capture_animation, capture_animation_found :=
                            shared.animation_playback_find_active_animation(&animation_playback)
                        if !capture_animation_found {
                            if capture_options.frame_range_set {
                                log.errorf(
                                    "Capture frame range %d:%d:%d was requested, but %s has no playable animation",
                                    capture_options.frame_range_start,
                                    capture_options.frame_range_end,
                                    capture_options.frame_range_step,
                                    model_assets.paths[initial_model_index],
                                )
                            } else {
                                log.errorf(
                                    "Capture frame %.3f was requested, but %s has no playable animation",
                                    capture_options.animation_frame,
                                    model_assets.paths[initial_model_index],
                                )
                            }
                            exit_code = 2
                            break application_scope
                        }
                        capture_last_frame := f32(max(
                            capture_animation.keyframeCount - 1,
                            0,
                        ))
                        requested_last_frame := capture_options.animation_frame
                        if capture_options.frame_range_set {
                            requested_last_frame = f32(capture_options.frame_range_end)
                        }
                        if requested_last_frame > capture_last_frame {
                            log.errorf(
                                "Capture frame %.3f exceeds the animation's last frame %.3f",
                                requested_last_frame,
                                capture_last_frame,
                            )
                            exit_code = 2
                            break application_scope
                        }
                        requested_first_frame := capture_options.animation_frame
                        if capture_options.frame_range_set {
                            requested_first_frame = f32(capture_options.frame_range_start)
                        }
                        animation_playback.current_frame = requested_first_frame
                        animation_playback.pose_dirty = true
                        shared.animation_playback_update(
                            &animation_playback,
                            active_model,
                            0,
                        )
                    }
                }
                log.infof(
                    "Loaded initial model: %s",
                    model_assets.paths[initial_model_index],
                )
            } else {
                model_load_failed = true
                log.errorf(
                    "Failed to load initial model %s: %s",
                    model_assets.paths[initial_model_index],
                    shared.model_load_error_message(initial_model_error),
                )
                if capture_options.enabled {
                    exit_code = 1
                    break application_scope
                }
            }
        }
        // Keep continuous input state separate from the quantized render camera.
        // Otherwise a sub-pixel drag would be rounded away every frame and could
        // never accumulate enough movement to cross the next pixel boundary.
        control_camera := render_camera

        screen_width := rl.GetScreenWidth()
        screen_height := rl.GetScreenHeight()
        scene_render_target := rl.LoadRenderTexture(screen_width, screen_height)
        defer rl.UnloadRenderTexture(scene_render_target)
        cel_band_render_target := rl.LoadRenderTexture(screen_width, screen_height)
        defer rl.UnloadRenderTexture(cel_band_render_target)
        rl.SetTextureFilter(cel_band_render_target.texture, .POINT)
        rl.SetTextureWrap(cel_band_render_target.texture, .CLAMP)

        downscale_level := c.int(DEFAULT_DOWNSCALE_LEVEL)
        applied_downscale_level := downscale_level
        downsample_width := shared.render_downsample_dimension(screen_width, downscale_level)
        downsample_height := shared.render_downsample_dimension(screen_height, downscale_level)
        downsample_render_target := rl.LoadRenderTexture(
            downsample_width,
            downsample_height,
        )
        rl.SetTextureFilter(downsample_render_target.texture, .POINT)
        coverage_mask_render_target := rl.LoadRenderTexture(
            downsample_width,
            downsample_height,
        )
        rl.SetTextureFilter(coverage_mask_render_target.texture, .POINT)
        outlined_render_target := rl.LoadRenderTexture(
            downsample_width,
            downsample_height,
        )
        rl.SetTextureFilter(outlined_render_target.texture, .POINT)
        defer {
            rl.UnloadRenderTexture(downsample_render_target)
            rl.UnloadRenderTexture(coverage_mask_render_target)
            rl.UnloadRenderTexture(outlined_render_target)
        }
        composite_render_target := rl.LoadRenderTexture(screen_width, screen_height)
        defer rl.UnloadRenderTexture(composite_render_target)
        rl.SetTextureFilter(composite_render_target.texture, .POINT)
        render_debug_video_target: rl.RenderTexture2D
        defer {
            if rl.IsRenderTextureValid(render_debug_video_target) {
                rl.UnloadRenderTexture(render_debug_video_target)
            }
        }
        if capture_options.render_debug_video {
            render_debug_video_target = rl.LoadRenderTexture(
                VIEWER_VIDEO_WIDTH,
                VIEWER_VIDEO_HEIGHT,
            )
            if !rl.IsRenderTextureValid(render_debug_video_target) {
                log.error("Failed to create Viewer render-debug video target")
                exit_code = 1
                break application_scope
            }
            rl.SetTextureFilter(render_debug_video_target.texture, .POINT)
        }
        if viewer_video_enabled {
            video_start_error := shared.video_stream_encoder_start(
                &viewer_video_encoder,
                capture_options.video_output,
                VIEWER_VIDEO_WIDTH,
                VIEWER_VIDEO_HEIGHT,
                VIEWER_VIDEO_FRAMES_PER_SECOND,
            )
            if video_start_error != .NONE {
                log.errorf(
                    "Failed to start Viewer video encoder for %s: %s",
                    capture_options.video_output,
                    shared.video_stream_start_error_message(video_start_error),
                )
                exit_code = 1
                if video_start_error == .FFMPEG_NOT_FOUND {
                    exit_code = 2
                }
                break application_scope
            }
        }

        scene_resolution := [2]f32{f32(screen_width), f32(screen_height)}
        downsample_resolution := [2]f32{
            f32(downsample_width),
            f32(downsample_height),
        }
        downscale_source_resolution_location := rl.GetShaderLocation(
            downscale_shader,
            "u_source_resolution",
        )
        downscale_target_resolution_location := rl.GetShaderLocation(
            downscale_shader,
            "u_target_resolution",
        )
        downscale_cel_band_texture_location := rl.GetShaderLocation(
            downscale_shader,
            "u_cel_band_texture",
        )
        downscale_color_cluster_threshold_location := rl.GetShaderLocation(
            downscale_shader,
            "u_color_cluster_threshold",
        )
        downscale_rim_preserve_samples_location := rl.GetShaderLocation(
            downscale_shader,
            "u_rim_preserve_samples",
        )
        downscale_highlight_preserve_samples_location := rl.GetShaderLocation(
            downscale_shader,
            "u_highlight_preserve_samples",
        )
        downscale_edge_aa_mode_location := rl.GetShaderLocation(
            downscale_shader,
            "u_edge_aa_mode",
        )
        mask_downscale_source_resolution_location := rl.GetShaderLocation(
            mask_downscale_shader,
            "u_source_resolution",
        )
        mask_downscale_target_resolution_location := rl.GetShaderLocation(
            mask_downscale_shader,
            "u_target_resolution",
        )
        color_cluster_threshold := f32(DEFAULT_COLOR_CLUSTER_THRESHOLD)
        outline_target_resolution_location := rl.GetShaderLocation(
            outline_shader,
            "u_target_resolution",
        )
        outline_coverage_texture_location := rl.GetShaderLocation(
            outline_shader,
            "u_coverage_texture",
        )
        outline_width_location := rl.GetShaderLocation(
            outline_shader,
            "u_outline_width",
        )
        outline_color_location := rl.GetShaderLocation(
            outline_shader,
            "u_outline_color",
        )
        outline_coverage_threshold_location := rl.GetShaderLocation(
            outline_shader,
            "u_coverage_threshold",
        )
        outline_edge_aa_mode_location := rl.GetShaderLocation(
            outline_shader,
            "u_edge_aa_mode",
        )
        render_debug_display_mode_location := rl.GetShaderLocation(
            render_debug_shader,
            "u_display_mode",
        )

        lens_mode := shared.Lens_Mode.PIXELATED
        edge_aa_mode := shared.Edge_AA_Mode.HARD
        if capture_options.enabled {
            lens_mode = capture_options.lens_mode
            edge_aa_mode = capture_options.edge_aa_mode
        }
        lens_grid_visible := true
        scene_background_color := rl.BLACK
        background_picker_open := false
        inspector_bounds := rl.Rectangle{
            f32(screen_width) - 340,
            10,
            330,
            f32(screen_height) - 20,
        }
        background_picker_bounds := rl.Rectangle{
            inspector_bounds.x - 230,
            360,
            220,
            212,
        }
        inspector_ui := Inspector_UI_State{
            model_open = true,
            lens_open = true,
            camera_open = true,
        }
        ui_keyboard: shared.UI_Keyboard_State
        cel_style_ui: Cel_Style_UI_State
        animation_timeline_bounds := rl.Rectangle{
            10,
            f32(screen_height) - ANIMATION_TIMELINE_HEIGHT -
                ANIMATION_TIMELINE_BOTTOM_MARGIN,
            inspector_bounds.x - 20,
            ANIMATION_TIMELINE_HEIGHT,
        }
        magnifier_bounds := rl.Rectangle{10, f32(screen_height) - 194, 148, 184}
        coverage_alpha: f32 = -1
        next_export_index := 1
        last_export_path: string
        defer {
            if len(last_export_path) > 0 {
                delete(last_export_path)
            }
        }
        last_export_succeeded := false
        last_export_time: f64 = -10
        capture_complete := false
        capture_succeeded := false
        rendered_capture_frames := 0
        capture_sequence_frame := capture_options.frame_range_start
        captured_sequence_frames := 0
        camera_mouse_drag := Camera_Mouse_Drag.NONE
        lens_size := DEFAULT_LENS_SIZE
        lens_resize_dragging := false
        quit_requested := false
        shortcuts_help_open := false
        render_debug := viewer_render_debug_state_make()
        render_debug_video := viewer_render_debug_state_make()
        render_debug_video.open = capture_options.render_debug_video

        for !rl.WindowShouldClose() && !capture_complete && !quit_requested {
            frame_delta_seconds := rl.GetFrameTime()
            if downscale_level != applied_downscale_level {
                requested_downscale_level := clamp(
                    downscale_level,
                    c.int(MIN_DOWNSCALE_LEVEL),
                    c.int(MAX_DOWNSCALE_LEVEL),
                )
                requested_width := shared.render_downsample_dimension(
                    screen_width,
                    requested_downscale_level,
                )
                requested_height := shared.render_downsample_dimension(
                    screen_height,
                    requested_downscale_level,
                )
                replacement_downsample_target := rl.LoadRenderTexture(
                    requested_width,
                    requested_height,
                )
                replacement_mask_target := rl.LoadRenderTexture(
                    requested_width,
                    requested_height,
                )
                replacement_outline_target := rl.LoadRenderTexture(
                    requested_width,
                    requested_height,
                )
                if rl.IsRenderTextureValid(replacement_downsample_target) &&
                   rl.IsRenderTextureValid(replacement_mask_target) &&
                   rl.IsRenderTextureValid(replacement_outline_target) {
                    rl.SetTextureFilter(replacement_downsample_target.texture, .POINT)
                    rl.SetTextureFilter(replacement_mask_target.texture, .POINT)
                    rl.SetTextureFilter(replacement_outline_target.texture, .POINT)
                    rl.UnloadRenderTexture(downsample_render_target)
                    rl.UnloadRenderTexture(coverage_mask_render_target)
                    rl.UnloadRenderTexture(outlined_render_target)
                    downsample_render_target = replacement_downsample_target
                    coverage_mask_render_target = replacement_mask_target
                    outlined_render_target = replacement_outline_target
                    downsample_width = requested_width
                    downsample_height = requested_height
                    downsample_resolution = {
                        f32(downsample_width),
                        f32(downsample_height),
                    }
                    downscale_level = requested_downscale_level
                    applied_downscale_level = requested_downscale_level
                    log.infof(
                        "Downscale level: %dx (%d x %d)",
                        applied_downscale_level,
                        downsample_width,
                        downsample_height,
                    )
                } else {
                    if rl.IsRenderTextureValid(replacement_downsample_target) {
                        rl.UnloadRenderTexture(replacement_downsample_target)
                    }
                    if rl.IsRenderTextureValid(replacement_mask_target) {
                        rl.UnloadRenderTexture(replacement_mask_target)
                    }
                    if rl.IsRenderTextureValid(replacement_outline_target) {
                        rl.UnloadRenderTexture(replacement_outline_target)
                    }
                    downscale_level = applied_downscale_level
                    log.errorf(
                        "Failed to create %d x %d downsample render targets; keeping level %d",
                        requested_width,
                        requested_height,
                        applied_downscale_level,
                    )
                }
            }

            window_focused := rl.IsWindowFocused()
            if capture_options.enabled {
                // A capture never consumes live desktop input, even when its
                // window is shown for debugging.
                window_focused = false
            } else {
                if window_focused {
                    rl.SetWindowOpacity(1.0)
                } else {
                    rl.SetWindowOpacity(0.5)
                }
            }

            export_requested := false
            active_modal := render_debug.open || shortcuts_help_open ||
                            background_picker_open ||
                            animation_playback.dropdown_open ||
                            model_browser.search_editing ||
                            cel_style_ui.color_target != .NONE
            shared.ui_keyboard_begin_frame(
                &ui_keyboard,
                window_focused,
                active_modal,
            )
            if render_debug.open {
                shared.ui_keyboard_focus_clear(&ui_keyboard)
            } else if shortcuts_help_open {
                shared.ui_keyboard_focus_set(&ui_keyboard, .HELP_CLOSE)
            } else if model_browser.search_editing {
                shared.ui_keyboard_focus_set(&ui_keyboard, .MODEL_SEARCH)
            } else if animation_playback.dropdown_open {
                shared.ui_keyboard_focus_set(&ui_keyboard, .ANIMATION_CLIP)
            } else if background_picker_open {
                shared.ui_keyboard_focus_set(&ui_keyboard, .BACKGROUND_PICKER)
            } else {
                switch cel_style_ui.color_target {
                case .BAND_TINT: shared.ui_keyboard_focus_set(&ui_keyboard, .CEL_BAND_TINT_PICKER)
                case .RIM:       shared.ui_keyboard_focus_set(&ui_keyboard, .CEL_RIM_PICKER)
                case .HIGHLIGHT: shared.ui_keyboard_focus_set(&ui_keyboard, .CEL_HIGHLIGHT_PICKER)
                case .OUTLINE:   shared.ui_keyboard_focus_set(&ui_keyboard, .CEL_OUTLINE_PICKER)
                case .NONE:
                }
            }

            if window_focused && rl.IsKeyPressed(.ESCAPE) {
                if render_debug.open {
                    viewer_render_debug_close(&render_debug, &animation_playback)
                } else if shortcuts_help_open {
                    shortcuts_help_open = false
                    shared.ui_keyboard_focus_clear(&ui_keyboard)
                } else if animation_playback.dropdown_open {
                    animation_playback.dropdown_open = false
                    shared.ui_keyboard_focus_set(&ui_keyboard, .ANIMATION_CLIP)
                } else if background_picker_open {
                    background_picker_open = false
                    shared.ui_keyboard_focus_set(&ui_keyboard, .BACKGROUND_PICKER_TOGGLE)
                } else if cel_style_ui.color_target != .NONE {
                    cel_style_ui.color_target = .NONE
                } else if !model_browser.search_editing {
                    shared.ui_keyboard_focus_clear(&ui_keyboard)
                }
            }

            // Resolve the active shortcut inline at its only dispatch point.
            shortcut_command := shared.UI_Command.NONE
            if window_focused {
                shortcut_modifiers := shared.ui_modifier_mask()
                for binding in shared.UI_SHORTCUT_BINDINGS {
                    if !shared.ui_shortcut_modifiers_match(binding, shortcut_modifiers, false) ||
                       !rl.IsKeyPressed(binding.key) {
                        continue
                    }
                    shortcut_command = binding.command
                    break
                }
            }

            // Check focused-control conflicts inline before dispatching the command.
            focused_id := shared.ui_keyboard_focused_id(&ui_keyboard)
            shortcut_conflicts_with_focus := false
            #partial switch shortcut_command {
            case .ANIMATION_PLAY_PAUSE:
                shortcut_conflicts_with_focus = focused_id != .NONE
            case .ANIMATION_FIRST_FRAME:
                #partial switch focused_id {
                case .ANIMATION_TIMELINE, .ANIMATION_SPEED,
                     .ANIMATION_SAMPLE_COUNT, .MODEL_LIST, .LENS_DOWNSCALE,
                     .LENS_EDGE_AA,
                     .CEL_PRESET, .CEL_LIGHT_SPACE, .CEL_LIGHT_AZIMUTH,
                     .CEL_LIGHT_ELEVATION, .CEL_LIGHT_WRAP, .CEL_BAND_SELECT,
                     .CEL_BAND_UPPER_BOUND, .CEL_BAND_BRIGHTNESS,
                     .CEL_BAND_TINT_MIX, .CEL_BAND_TINT_PICKER,
                     .CEL_ALPHA_MODE, .CEL_ALPHA_CUTOFF, .CEL_RIM_THRESHOLD,
                     .CEL_RIM_STRENGTH, .CEL_RIM_SAMPLES, .CEL_RIM_PICKER,
                     .CEL_HIGHLIGHT_THRESHOLD, .CEL_HIGHLIGHT_STRENGTH,
                     .CEL_HIGHLIGHT_SAMPLES, .CEL_HIGHLIGHT_PICKER,
                     .CEL_OUTLINE_WIDTH, .CEL_OUTLINE_COVERAGE,
                     .CEL_OUTLINE_PICKER, .CEL_OUTLINE_ALPHA,
                     .BACKGROUND_PICKER, .INSPECTOR_SCROLLBAR:
                    shortcut_conflicts_with_focus = true
                }
            case .INSPECTOR_PAGE_UP, .INSPECTOR_PAGE_DOWN:
                shortcut_conflicts_with_focus =
                    focused_id == .MODEL_LIST ||
                    focused_id == .INSPECTOR_SCROLLBAR
            }
            if shared.ui_keyboard_has_focus(&ui_keyboard) && shortcut_conflicts_with_focus {
                shortcut_command = .NONE
            }
            if render_debug.open &&
               shortcut_command != .TOGGLE_RENDER_DEBUG &&
               shortcut_command != .QUIT {
                shortcut_command = .NONE
            } else if active_modal && shortcut_command != .TOGGLE_HELP &&
               shortcut_command != .TOGGLE_RENDER_DEBUG &&
               shortcut_command != .QUIT {
                shortcut_command = .NONE
            }
            inspector_max_scroll := max(
                inspector_content_height(&inspector_ui, &cel_style_ui, &cel_style) -
                (inspector_bounds.height - 36),
                f32(0),
            )
            command_context := App_UI_Command_Context{
                keyboard = &ui_keyboard,
                quit_requested = &quit_requested,
                shortcuts_help_open = &shortcuts_help_open,
                render_debug = &render_debug,
                export_requested = &export_requested,
                lens_mode = &lens_mode,
                lens_grid_visible = &lens_grid_visible,
                downscale_level = &downscale_level,
                inspector = &inspector_ui,
                inspector_max_scroll = inspector_max_scroll,
                model_browser = &model_browser,
                cel_ui = &cel_style_ui,
                cel_style = &cel_style,
                animation = &animation_playback,
                camera = &control_camera,
                model_center = model_center,
                scene_size = scene_size,
                background_color = &scene_background_color,
                background_picker_open = &background_picker_open,
            }
            execute_ui_command(shortcut_command, &command_context)

            ui_mouse_position := rl.GetMousePosition()
            lens_has_animation := shared.animation_playback_has_playable_animations(
                &animation_playback,
            )
            lens_lower_ui_top := f32(screen_height)
            if lens_has_animation {
                lens_lower_ui_top = animation_timeline_bounds.y
            }
            lens_max_size := lens_layout_max_size(
                screen_width,
                screen_height,
                inspector_bounds.x,
                lens_lower_ui_top,
            )
            lens_size = clamp(lens_size, MIN_LENS_SIZE, lens_max_size)
            lens_bounds := centered_lens_bounds(
                screen_width,
                screen_height,
                lens_size,
            )
            lens_resize_hit_bounds := lens_resize_handle_bounds(lens_bounds)
            mouse_over_lens_resize_handle := !capture_options.enabled &&
                !render_debug.open &&
                rl.CheckCollisionPointRec(
                    ui_mouse_position,
                    lens_resize_hit_bounds,
                )
            mouse_over_inspector := rl.CheckCollisionPointRec(
                ui_mouse_position,
                inspector_bounds,
            )
            mouse_over_background_picker := background_picker_open &&
                rl.CheckCollisionPointRec(ui_mouse_position, background_picker_bounds)
            mouse_over_animation_timeline := lens_has_animation &&
                rl.CheckCollisionPointRec(
                ui_mouse_position,
                animation_timeline_bounds,
            )
            input_lens_mode_bar_bounds, input_lens_footer_bounds :=
                lens_control_bar_bounds(lens_bounds, lens_lower_ui_top)
            mouse_over_lens_controls := rl.CheckCollisionPointRec(
                ui_mouse_position,
                input_lens_mode_bar_bounds,
            ) || rl.CheckCollisionPointRec(
                ui_mouse_position,
                input_lens_footer_bounds,
            )
            mouse_over_ui := mouse_over_inspector ||
                             mouse_over_background_picker ||
                             mouse_over_animation_timeline ||
                             mouse_over_lens_resize_handle ||
                             mouse_over_lens_controls
            ui_captures_camera_input := render_debug.open ||
                                        shortcuts_help_open ||
                                        background_picker_open ||
                                        animation_playback.dropdown_open ||
                                        model_browser.search_editing ||
                                        cel_style_ui.color_target != .NONE
            left_mouse_pressed := rl.IsMouseButtonPressed(.LEFT)
            left_mouse_down := rl.IsMouseButtonDown(.LEFT)
            middle_mouse_down := rl.IsMouseButtonDown(.MIDDLE)
            lens_resize_for_frame, next_lens_resize_dragging :=
                lens_resize_drag_for_frame(
                    lens_resize_dragging,
                    window_focused,
                    ui_captures_camera_input || camera_mouse_drag != .NONE,
                    mouse_over_lens_resize_handle,
                    left_mouse_pressed,
                    left_mouse_down,
                )
            lens_resize_dragging = next_lens_resize_dragging
            if lens_resize_for_frame && left_mouse_down {
                lens_size = lens_resize_size_for_pointer(
                    ui_mouse_position.x,
                    ui_mouse_position.y,
                    f32(screen_width) * 0.5,
                    f32(screen_height) * 0.5,
                    MIN_LENS_SIZE,
                    lens_max_size,
                    f32(applied_downscale_level),
                )
                lens_bounds = centered_lens_bounds(
                    screen_width,
                    screen_height,
                    lens_size,
                )
                mouse_over_ui = true
            }
            if !capture_options.enabled {
                if lens_resize_for_frame ||
                   (mouse_over_lens_resize_handle && !ui_captures_camera_input) {
                    rl.SetMouseCursor(.RESIZE_NWSE)
                } else {
                    rl.SetMouseCursor(.DEFAULT)
                }
            }
            ui_captures_camera_input = ui_captures_camera_input ||
                                       lens_resize_for_frame
            camera_drag_for_frame, next_camera_mouse_drag :=
                camera_mouse_drag_for_frame(
                    camera_mouse_drag,
                    window_focused,
                    ui_captures_camera_input,
                    mouse_over_ui,
                    left_mouse_pressed,
                    rl.IsMouseButtonPressed(.MIDDLE),
                    left_mouse_down,
                    middle_mouse_down,
                )
            camera_mouse_drag = next_camera_mouse_drag
            camera_input := camera_input_permissions(
                window_focused,
                ui_captures_camera_input,
                mouse_over_ui,
                camera_drag_for_frame != .NONE,
                left_mouse_down || middle_mouse_down,
            )
            // Reserve primary/Alt-modified keys inline before camera handling.
            camera_shortcut_modifiers := shared.ui_modifier_mask()
            shortcut_uses_command_modifier :=
                camera_shortcut_modifiers & (shared.UI_MOD_PRIMARY | shared.UI_MOD_ALT) != 0
            if shared.ui_keyboard_has_focus(&ui_keyboard) || shortcut_uses_command_modifier {
                camera_input.keyboard = false
            }
            if !mouse_over_ui &&
               (rl.IsMouseButtonPressed(.LEFT) ||
                rl.IsMouseButtonPressed(.MIDDLE)) {
                shared.ui_keyboard_focus_clear(&ui_keyboard)
            }
            if camera_input.keyboard || camera_input.mouse {
                // Apply keyboard, orbit, pan, and zoom input inline at the sole update site.
                camera := &control_camera
                move_speed := scene_size * 2.0
                camera_forward := rl.GetCameraForward(camera)
                camera_right := rl.GetCameraRight(camera)
                camera_up := rl.Vector3Normalize(
                    rl.Vector3CrossProduct(camera_right, camera_forward),
                )

                if camera_input.keyboard {
                    if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
                        move_speed *= 4.0
                    }
                    move_distance := move_speed * frame_delta_seconds

                    // Translate in the visible plane; Q/E control orthographic zoom.
                    pan_delta: rl.Vector3
                    if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) {
                        pan_delta += camera_up * move_distance
                    }
                    if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN) {
                        pan_delta -= camera_up * move_distance
                    }
                    if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) {
                        pan_delta -= camera_right * move_distance
                    }
                    if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) {
                        pan_delta += camera_right * move_distance
                    }
                    if pan_delta.x != 0 || pan_delta.y != 0 || pan_delta.z != 0 {
                        camera.position += pan_delta
                        camera.target += pan_delta
                    }

                    keyboard_zoom_factor := 1.0 + frame_delta_seconds * 1.5
                    if rl.IsKeyDown(.Q) {
                        camera.fovy *= keyboard_zoom_factor
                    }
                    if rl.IsKeyDown(.E) {
                        camera.fovy = max(
                            camera.fovy / keyboard_zoom_factor,
                            scene_size * 0.05,
                        )
                    }
                }

                if camera_input.mouse {
                    mouse_delta := rl.GetMouseDelta()
                    if camera_drag_for_frame == .ORBIT &&
                       rl.IsMouseButtonDown(.LEFT) {
                        mouse_look_sensitivity: f32 = 0.003
                        yaw_delta := -mouse_delta.x * mouse_look_sensitivity
                        pitch_delta := -mouse_delta.y * mouse_look_sensitivity

                        // Keep turntable yaw on world Y and pitch on screen right.
                        world_up := rl.Vector3{0, 1, 0}
                        position_from_pivot := camera.position - model_center
                        target_from_pivot := camera.target - model_center

                        if yaw_delta != 0 {
                            position_from_pivot = rl.Vector3RotateByAxisAngle(
                                position_from_pivot,
                                world_up,
                                yaw_delta,
                            )
                            target_from_pivot = rl.Vector3RotateByAxisAngle(
                                target_from_pivot,
                                world_up,
                                yaw_delta,
                            )
                        }

                        if pitch_delta != 0 {
                            yawed_position := model_center + position_from_pivot
                            yawed_target := model_center + target_from_pivot
                            yawed_forward := rl.Vector3Normalize(
                                yawed_target - yawed_position,
                            )
                            orbit_camera_right := rl.Vector3CrossProduct(
                                yawed_forward,
                                world_up,
                            )
                            right_length := rl.Vector3Length(orbit_camera_right)

                            if right_length < 0.00001 {
                                orbit_camera_right = rl.GetCameraRight(camera)
                                orbit_camera_right.y = 0
                                right_length = rl.Vector3Length(orbit_camera_right)
                            }
                            if right_length >= 0.00001 {
                                orbit_camera_right /= right_length
                                max_elevation := f32(math.PI / 2 - 0.01)
                                elevation := math.asin(
                                    min(
                                        max(
                                            rl.Vector3DotProduct(
                                                yawed_forward,
                                                world_up,
                                            ),
                                            -1,
                                        ),
                                        1,
                                    ),
                                )
                                clamped_pitch := min(
                                    max(
                                        pitch_delta,
                                        -max_elevation - elevation,
                                    ),
                                    max_elevation - elevation,
                                )
                                position_from_pivot = rl.Vector3RotateByAxisAngle(
                                    position_from_pivot,
                                    orbit_camera_right,
                                    clamped_pitch,
                                )
                                target_from_pivot = rl.Vector3RotateByAxisAngle(
                                    target_from_pivot,
                                    orbit_camera_right,
                                    clamped_pitch,
                                )
                            }
                        }

                        camera.position = model_center + position_from_pivot
                        camera.target = model_center + target_from_pivot
                        final_forward := rl.Vector3Normalize(
                            camera.target - camera.position,
                        )
                        if math.abs(
                            rl.Vector3DotProduct(final_forward, world_up),
                        ) > 0.99995 {
                            fallback_up := camera.up - final_forward *
                                           rl.Vector3DotProduct(
                                               camera.up,
                                               final_forward,
                                           )
                            if rl.Vector3Length(fallback_up) < 0.00001 {
                                fallback_up = rl.Vector3CrossProduct(
                                    camera_right,
                                    final_forward,
                                )
                            }
                            camera.up = rl.Vector3Normalize(fallback_up)
                        } else {
                            camera.up = world_up
                        }
                    }

                    if camera_drag_for_frame == .PAN &&
                       rl.IsMouseButtonDown(.MIDDLE) {
                        pan_sensitivity := camera.fovy /
                                           f32(rl.GetScreenHeight())
                        mouse_pan_delta :=
                            camera_right * (-mouse_delta.x * pan_sensitivity) +
                            camera_up * (mouse_delta.y * pan_sensitivity)
                        camera.position += mouse_pan_delta
                        camera.target += mouse_pan_delta
                    }

                    wheel_delta := rl.GetMouseWheelMove()
                    if wheel_delta != 0 {
                        zoom_factor := 1.0 - wheel_delta * 0.1
                        camera.fovy = max(
                            camera.fovy * zoom_factor,
                            scene_size * 0.05,
                        )
                    }
                }
            }
            render_camera = control_camera

            // Quantize orthographic zoom and pan inline before the sole render view.
            if downsample_height > 0 && render_camera.fovy > 0 && scene_size > 0 {
                projected_pixels := scene_size * f32(downsample_height) /
                                    render_camera.fovy
                snapped_pixels := max(math.round(projected_pixels), 1)
                render_camera.fovy = scene_size * f32(downsample_height) /
                                     snapped_pixels
            }
            if downsample_height > 0 && render_camera.fovy > 0 {
                world_units_per_pixel := render_camera.fovy / f32(downsample_height)
                camera_forward := rl.GetCameraForward(&render_camera)
                camera_right := rl.GetCameraRight(&render_camera)
                // Rebuild the actual vertical screen axis after orbiting.
                camera_up := rl.Vector3Normalize(
                    rl.Vector3CrossProduct(camera_right, camera_forward),
                )
                pan_offset := render_camera.target - model_center
                pan_x := rl.Vector3DotProduct(pan_offset, camera_right)
                pan_y := rl.Vector3DotProduct(pan_offset, camera_up)
                snapped_x := math.round(pan_x / world_units_per_pixel) *
                             world_units_per_pixel
                snapped_y := math.round(pan_y / world_units_per_pixel) *
                             world_units_per_pixel
                snap_correction := camera_right * (snapped_x - pan_x) +
                                   camera_up * (snapped_y - pan_y)
                render_camera.position += snap_correction
                render_camera.target += snap_correction
            }

            shared.animation_playback_update(
                &animation_playback,
                active_model,
                frame_delta_seconds,
            )

            if !capture_options.enabled {
                scene_reload := shared.shader_program_reload_with_includes(
                    VS_PATH,
                    FS_PATH,
                    &scene_shader,
                    &scene_shader_source,
                )
                if scene_reload.status == .FAILED {
                    log.errorf(
                        "Failed to reload Viewer scene shader: %s",
                        shared.shader_load_error_message(scene_reload.error),
                    )
                } else if scene_reload.status == .RELOADED {
                    scene_cel_bindings = shared.cel_shader_bindings_resolve(scene_shader)
                }

                cel_band_reload := shared.shader_program_reload_with_includes(
                    VS_PATH,
                    CEL_BAND_FS_PATH,
                    &cel_band_shader,
                    &cel_band_shader_source,
                )
                if cel_band_reload.status == .FAILED {
                    log.errorf(
                        "Failed to reload Viewer cel-band shader: %s",
                        shared.shader_load_error_message(cel_band_reload.error),
                    )
                } else if cel_band_reload.status == .RELOADED {
                    cel_band_bindings = shared.cel_shader_bindings_resolve(cel_band_shader)
                }

                downscale_reload := shared.shader_fragment_reload_with_includes(
                    DOWNSCALE_FS_PATH,
                    &downscale_shader,
                    &downscale_shader_source,
                )
                if downscale_reload.status == .FAILED {
                    log.errorf(
                        "Failed to reload Viewer downscale shader: %s",
                        shared.shader_load_error_message(downscale_reload.error),
                    )
                } else if downscale_reload.status == .RELOADED {
                    downscale_source_resolution_location = rl.GetShaderLocation(
                        downscale_shader,
                        "u_source_resolution",
                    )
                    downscale_target_resolution_location = rl.GetShaderLocation(
                        downscale_shader,
                        "u_target_resolution",
                    )
                    downscale_cel_band_texture_location = rl.GetShaderLocation(
                        downscale_shader,
                        "u_cel_band_texture",
                    )
                    downscale_color_cluster_threshold_location = rl.GetShaderLocation(
                        downscale_shader,
                        "u_color_cluster_threshold",
                    )
                    downscale_rim_preserve_samples_location = rl.GetShaderLocation(
                        downscale_shader,
                        "u_rim_preserve_samples",
                    )
                    downscale_highlight_preserve_samples_location = rl.GetShaderLocation(
                        downscale_shader,
                        "u_highlight_preserve_samples",
                    )
                    downscale_edge_aa_mode_location = rl.GetShaderLocation(
                        downscale_shader,
                        "u_edge_aa_mode",
                    )
                }

                mask_reload := shared.shader_fragment_reload_with_includes(
                    MASK_DOWNSCALE_FS_PATH,
                    &mask_downscale_shader,
                    &mask_downscale_shader_source,
                )
                if mask_reload.status == .FAILED {
                    log.errorf(
                        "Failed to reload Viewer coverage shader: %s",
                        shared.shader_load_error_message(mask_reload.error),
                    )
                } else if mask_reload.status == .RELOADED {
                    mask_downscale_source_resolution_location = rl.GetShaderLocation(
                        mask_downscale_shader,
                        "u_source_resolution",
                    )
                    mask_downscale_target_resolution_location = rl.GetShaderLocation(
                        mask_downscale_shader,
                        "u_target_resolution",
                    )
                }

                outline_reload := shared.shader_fragment_reload_with_includes(
                    OUTLINE_FS_PATH,
                    &outline_shader,
                    &outline_shader_source,
                )
                if outline_reload.status == .FAILED {
                    log.errorf(
                        "Failed to reload Viewer outline shader: %s",
                        shared.shader_load_error_message(outline_reload.error),
                    )
                } else if outline_reload.status == .RELOADED {
                    outline_target_resolution_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_target_resolution",
                    )
                    outline_coverage_texture_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_coverage_texture",
                    )
                    outline_width_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_outline_width",
                    )
                    outline_color_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_outline_color",
                    )
                    outline_coverage_threshold_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_coverage_threshold",
                    )
                    outline_edge_aa_mode_location = rl.GetShaderLocation(
                        outline_shader,
                        "u_edge_aa_mode",
                    )
                }

                render_debug_reload := shared.shader_fragment_reload_with_includes(
                    VIEWER_DEBUG_FS_PATH,
                    &render_debug_shader,
                    &render_debug_shader_source,
                )
                if render_debug_reload.status == .FAILED {
                    log.errorf(
                        "Failed to reload Viewer render-debug shader: %s",
                        shared.shader_load_error_message(render_debug_reload.error),
                    )
                } else if render_debug_reload.status == .RELOADED {
                    render_debug_display_mode_location = rl.GetShaderLocation(
                        render_debug_shader,
                        "u_display_mode",
                    )
                }
            }

            if cel_style.revision != applied_cel_ramp_revision {
                // Upload revised ramp pixels inline at the sole update point.
                revised_cel_ramp_pixels := shared.cel_ramp_pixels_build(&cel_style)
                rl.UpdateTexture(
                    cel_ramp_texture,
                    raw_data(revised_cel_ramp_pixels[:]),
                )
                applied_cel_ramp_revision = cel_style.revision
            }
            rim_preserve_samples := c.int(cel_style.rim.preserve_samples)
            highlight_preserve_samples := c.int(
                cel_style.highlight.preserve_samples,
            )
            outline_width := c.int(cel_style.outline.width)
            edge_aa_mode_value := c.int(edge_aa_mode)
            outline_color := [4]f32{
                f32(cel_style.outline.color.r) / 255,
                f32(cel_style.outline.color.g) / 255,
                f32(cel_style.outline.color.b) / 255,
                f32(cel_style.outline.color.a) / 255,
            }

            rl.SetShaderValue(
                downscale_shader,
                downscale_source_resolution_location,
                &scene_resolution,
                .VEC2,
            )
            rl.SetShaderValue(
                downscale_shader,
                downscale_target_resolution_location,
                &downsample_resolution,
                .VEC2,
            )
            rl.SetShaderValue(
                downscale_shader,
                downscale_color_cluster_threshold_location,
                &color_cluster_threshold,
                .FLOAT,
            )
            rl.SetShaderValue(
                downscale_shader,
                downscale_rim_preserve_samples_location,
                &rim_preserve_samples,
                .INT,
            )
            rl.SetShaderValue(
                downscale_shader,
                downscale_highlight_preserve_samples_location,
                &highlight_preserve_samples,
                .INT,
            )
            rl.SetShaderValue(
                downscale_shader,
                downscale_edge_aa_mode_location,
                &edge_aa_mode_value,
                .INT,
            )
            rl.SetShaderValue(
                mask_downscale_shader,
                mask_downscale_source_resolution_location,
                &scene_resolution,
                .VEC2,
            )
            rl.SetShaderValue(
                outline_shader,
                outline_target_resolution_location,
                &downsample_resolution,
                .VEC2,
            )
            rl.SetShaderValue(
                outline_shader,
                outline_width_location,
                &outline_width,
                .INT,
            )
            rl.SetShaderValue(
                outline_shader,
                outline_color_location,
                &outline_color,
                .VEC4,
            )
            rl.SetShaderValue(
                outline_shader,
                outline_coverage_threshold_location,
                &cel_style.outline.coverage_threshold,
                .FLOAT,
            )
            rl.SetShaderValue(
                outline_shader,
                outline_edge_aa_mode_location,
                &edge_aa_mode_value,
                .INT,
            )
            rl.SetShaderValue(
                mask_downscale_shader,
                mask_downscale_target_resolution_location,
                &downsample_resolution,
                .VEC2,
            )

            rl.BeginTextureMode(scene_render_target)
                shared.cel_style_apply_to_shader(
                    scene_shader,
                    &scene_cel_bindings,
                    &cel_style,
                    render_camera,
                    active_model.transform,
                )
                // Draw the cel-shaded scene inline in its only render pass.
                {
                    shader := scene_shader
                    model := active_model
                    camera := render_camera
                    rl.ClearBackground(rl.BLANK)

                    rl.BeginMode3D(camera)
                        if shared.model_is_loaded(model) {
                            // Keep each mesh's textures and material tint, but replace its
                            // shader for this draw only. The model still owns its materials.
                            for mesh_index := 0; mesh_index < int(model.meshCount); mesh_index += 1 {
                                material_index := int(model.meshMaterial[mesh_index])
                                if material_index < 0 || material_index >= int(model.materialCount) {
                                    material_index = 0
                                }
                                mesh_material := model.materials[material_index]
                                mesh_material.shader = shader
                                mesh_material.maps[rl.MaterialMapIndex.EMISSION].texture =
                                    cel_ramp_texture
                                rl.DrawMesh(
                                    model.meshes[mesh_index],
                                    mesh_material,
                                    model.transform,
                                )
                            }
                        }
                        // rl.DrawModelWires(model, {}, 1.0, rl.YELLOW)
                    rl.EndMode3D()
                }
            rl.EndTextureMode()

            rl.BeginTextureMode(cel_band_render_target)
                shared.cel_style_apply_to_shader(
                    cel_band_shader,
                    &cel_band_bindings,
                    &cel_style,
                    render_camera,
                    active_model.transform,
                )
                // Draw band IDs inline in their only auxiliary render pass.
                {
                    model := active_model
                    camera := render_camera
                    rl.ClearBackground(rl.BLANK)
                    rl.BeginMode3D(camera)
                        if shared.model_is_loaded(model) {
                            for mesh_index := 0; mesh_index < int(model.meshCount); mesh_index += 1 {
                                material_index := int(model.meshMaterial[mesh_index])
                                if material_index < 0 || material_index >= int(model.materialCount) {
                                    material_index = 0
                                }
                                mesh_material := model.materials[material_index]
                                mesh_material.shader = cel_band_shader
                                mesh_material.maps[rl.MaterialMapIndex.EMISSION].texture =
                                    cel_ramp_texture
                                rl.DrawMesh(
                                    model.meshes[mesh_index],
                                    mesh_material,
                                    model.transform,
                                )
                            }
                        }
                    rl.EndMode3D()
                }
            rl.EndTextureMode()

            flipped_scene_source_bounds := rl.Rectangle{
                width  = f32(screen_width),
                height = -f32(screen_height),
            }

            rl.BeginTextureMode(downsample_render_target)
                rl.ClearBackground(rl.BLANK)
                // The fullscreen resolve writes straight RGBA directly. Blending
                // into the cleared target would premultiply fractional coverage.
                rgl.DisableColorBlend()
                rl.BeginShaderMode(downscale_shader)
                    rl.SetShaderValueTexture(
                        downscale_shader,
                        downscale_cel_band_texture_location,
                        cel_band_render_target.texture,
                    )
                    rl.DrawTexturePro(
                        scene_render_target.texture,
                        flipped_scene_source_bounds,
                        {0, 0, f32(downsample_width), f32(downsample_height)},
                        {},
                        0,
                        rl.WHITE,
                    )
                rl.EndShaderMode()
                rgl.EnableColorBlend()
            rl.EndTextureMode()

            rl.BeginTextureMode(coverage_mask_render_target)
                rl.ClearBackground(rl.BLANK)
                rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
                rl.BeginShaderMode(mask_downscale_shader)
                    rl.DrawTexturePro(
                        cel_band_render_target.texture,
                        flipped_scene_source_bounds,
                        {0, 0, f32(downsample_width), f32(downsample_height)},
                        {},
                        0,
                        rl.WHITE,
                    )
                rl.EndShaderMode()
                rl.EndBlendMode()
            rl.EndTextureMode()

            flipped_downsample_source_bounds := rl.Rectangle{
                width = f32(downsample_width),
                height = -f32(downsample_height),
            }
            rl.BeginTextureMode(outlined_render_target)
                rl.ClearBackground(rl.BLANK)
                // outline.fs performs fill-over-outline composition itself and
                // returns straight alpha suitable for both display and PNG export.
                rgl.DisableColorBlend()
                rl.BeginShaderMode(outline_shader)
                    rl.SetShaderValueTexture(
                        outline_shader,
                        outline_coverage_texture_location,
                        coverage_mask_render_target.texture,
                    )
                    rl.DrawTexturePro(
                        downsample_render_target.texture,
                        flipped_downsample_source_bounds,
                        {0, 0, f32(downsample_width), f32(downsample_height)},
                        {},
                        0,
                        rl.WHITE,
                    )
                rl.EndShaderMode()
                rgl.EnableColorBlend()
            rl.EndTextureMode()

            rl.BeginTextureMode(composite_render_target)
                composite_locks_gui := render_debug.open ||
                                       camera_drag_for_frame != .NONE ||
                                       lens_resize_for_frame ||
                                       shortcuts_help_open
                if composite_locks_gui {
                    rl.GuiLock()
                }
                rl.ClearBackground(scene_background_color)
                rl.DrawTexturePro(
                    scene_render_target.texture,
                    flipped_scene_source_bounds,
                    {0, 0, f32(screen_width), f32(screen_height)},
                    {},
                    0,
                    rl.WHITE,
                )

                lens_texture_source_bounds := rl.Rectangle{
                    x      = lens_bounds.x / f32(applied_downscale_level),
                    y      = f32(downsample_height) -
                             (lens_bounds.y + lens_bounds.height) /
                             f32(applied_downscale_level),
                    width  = lens_bounds.width / f32(applied_downscale_level),
                    height = -lens_bounds.height / f32(applied_downscale_level),
                }
                coverage_alpha = -1
                lens_mouse_position := rl.GetMousePosition()
                if lens_mode == .COVERAGE_MASK &&
                   rl.CheckCollisionPointRec(lens_mouse_position, lens_bounds) {
                    lens_column := c.int(
                        (lens_mouse_position.x - lens_bounds.x) /
                        f32(applied_downscale_level),
                    )
                    lens_row := c.int(
                        (lens_mouse_position.y - lens_bounds.y) /
                        f32(applied_downscale_level),
                    )
                    mask_pixel_x := c.int(
                        lens_bounds.x / f32(applied_downscale_level),
                    ) +
                                    lens_column
                    mask_pixel_y := c.int(
                        lens_bounds.y / f32(applied_downscale_level),
                    ) +
                                    lens_row
                    mask_readback := rl.LoadImageFromTexture(
                        coverage_mask_render_target.texture,
                    )
                    mask_readback_y := mask_readback.height - 1 - mask_pixel_y
                    coverage_pixel := rl.GetImageColor(
                        mask_readback,
                        mask_pixel_x,
                        mask_readback_y,
                    )
                    coverage_alpha = f32(coverage_pixel.a) / 255.0
                    rl.UnloadImage(mask_readback)
                }
                lens_tint := rl.WHITE
                if lens_mode == .BLENDED {
                    lens_tint.a = 128
                }
                active_lens_texture := outlined_render_target.texture
                if lens_mode == .COVERAGE_MASK {
                    active_lens_texture = coverage_mask_render_target.texture
                }
                if lens_mode_replaces_scene(lens_mode) {
                    rl.DrawRectangleRec(lens_bounds, scene_background_color)
                }
                if lens_mode == .COVERAGE_MASK {
                    rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
                        rl.DrawTexturePro(
                            active_lens_texture,
                            lens_texture_source_bounds,
                            lens_bounds,
                            {},
                            0,
                            lens_tint,
                        )
                    rl.EndBlendMode()
                } else {
                    rl.DrawTexturePro(
                        active_lens_texture,
                        lens_texture_source_bounds,
                        lens_bounds,
                        {},
                        0,
                        lens_tint,
                    )
                }
                // Draw the coordinate grid inline in its only overlay pass.
                {
                    camera := render_camera
                    model := active_model
                    grid_spacing := max(scene_size * 0.5, 0.0001)
                    grid_half_count := 10
                    grid_extent := grid_spacing * f32(grid_half_count)
                    grid_color := rl.Color{190, 190, 190, 105}

                    x_color := rl.Color{235, 70, 70, 255}
                    y_color := rl.Color{80, 220, 100, 255}
                    z_color := rl.Color{70, 135, 245, 255}

                    axis_length := max(scene_size * 1.5, 0.0003)
                    shaft_radius := max(scene_size * 0.008, 0.000002)
                    arrow_length := axis_length * 0.14
                    arrow_radius := shaft_radius * 3.2
                    shaft_end := axis_length - arrow_length

                    rl.BeginMode3D(camera)
                        // Seed only the final framebuffer's depth buffer so the overlay remains
                        // spatially legible around the model without re-drawing its color.
                        if shared.model_is_loaded(model) {
                            rl.DrawModel(model, {}, 1.0, rl.BLANK)
                        }

                        for grid_line_index := -grid_half_count;
                            grid_line_index <= grid_half_count;
                            grid_line_index += 1 {
                            // if grid_line_index == 0 {
                            //     continue
                            // }
                            grid_line_offset := f32(grid_line_index) * grid_spacing
                            rl.DrawLine3D(
                                {-grid_extent, 0, grid_line_offset},
                                { grid_extent, 0, grid_line_offset},
                                grid_color,
                            )
                            rl.DrawLine3D(
                                {grid_line_offset, 0, -grid_extent},
                                {grid_line_offset, 0,  grid_extent},
                                grid_color,
                            )
                        }

                        // Dim negative halves plus solid positive shafts and arrowheads make
                        // both the axis identity and positive direction immediately visible.
                        rl.DrawLine3D({-axis_length, 0, 0}, {}, rl.Color{150, 45, 45, 210})
                        rl.DrawLine3D({0, -axis_length, 0}, {}, rl.Color{45, 140, 65, 210})
                        rl.DrawLine3D({0, 0, -axis_length}, {}, rl.Color{45, 80, 155, 210})

                        rl.DrawCylinderEx({}, {shaft_end, 0, 0}, shaft_radius, shaft_radius, 8, x_color)
                        rl.DrawCylinderEx({shaft_end, 0, 0}, {axis_length, 0, 0}, arrow_radius, 0, 8, x_color)
                        rl.DrawCylinderEx({}, {0, shaft_end, 0}, shaft_radius, shaft_radius, 8, y_color)
                        rl.DrawCylinderEx({0, shaft_end, 0}, {0, axis_length, 0}, arrow_radius, 0, 8, y_color)
                        rl.DrawCylinderEx({}, {0, 0, shaft_end}, shaft_radius, shaft_radius, 8, z_color)
                        rl.DrawCylinderEx({0, 0, shaft_end}, {0, 0, axis_length}, arrow_radius, 0, 8, z_color)
                    rl.EndMode3D()

                    x_axis_label_position := rl.GetWorldToScreen({axis_length, 0, 0}, camera)
                    y_axis_label_position := rl.GetWorldToScreen({0, axis_length, 0}, camera)
                    z_axis_label_position := rl.GetWorldToScreen({0, 0, axis_length}, camera)
                    rl.DrawText(
                        "X",
                        c.int(x_axis_label_position.x + 6),
                        c.int(x_axis_label_position.y - 8),
                        18,
                        x_color,
                    )
                    rl.DrawText(
                        "Y",
                        c.int(y_axis_label_position.x + 6),
                        c.int(y_axis_label_position.y - 8),
                        18,
                        y_color,
                    )
                    rl.DrawText(
                        "Z",
                        c.int(z_axis_label_position.x + 6),
                        c.int(z_axis_label_position.y - 8),
                        18,
                        z_color,
                    )
                }
                // Draw pixel-snap diagnostics inline in their only overlay pass.
                {
                    camera := &render_camera
                    snap_anchor := model_center
                    pixel_target_height := downsample_height
                    pixel_scale := int(applied_downscale_level)
                    world_units_per_pixel := camera.fovy / f32(pixel_target_height)
                    camera_forward := rl.GetCameraForward(camera)
                    camera_right := rl.GetCameraRight(camera)
                    camera_up := rl.Vector3Normalize(
                        rl.Vector3CrossProduct(camera_right, camera_forward),
                    )

                    pan_offset := camera.target - snap_anchor
                    camera_grid_x := rl.Vector3DotProduct(pan_offset, camera_right) / world_units_per_pixel
                    camera_grid_y := rl.Vector3DotProduct(pan_offset, camera_up) / world_units_per_pixel
                    snapped_grid_x := math.round(camera_grid_x)
                    snapped_grid_y := math.round(camera_grid_y)
                    snapped_plane_x := snapped_grid_x * world_units_per_pixel
                    snapped_plane_y := snapped_grid_y * world_units_per_pixel

                    panel_height: f32 = 128
                    if lens_mode == .COVERAGE_MASK {
                        panel_height += 22
                    }
                    panel_bounds := rl.Rectangle{10, 10, 280, panel_height}
                    rl.GuiPanel(panel_bounds, "ORTHOGRAPHIC PIXEL SNAP")

                    label_x := panel_bounds.x + 12
                    label_y := panel_bounds.y + 30
                    label_width := panel_bounds.width - 24
                    label_height: f32 = 18
                    line_height: f32 = 22

                    rl.GuiLabel(
                        {label_x, label_y, label_width, label_height},
                        rl.TextFormat("world units/pixel: %.8f", world_units_per_pixel),
                    )
                    label_y += line_height
                    rl.GuiLabel(
                        {label_x, label_y, label_width, label_height},
                        rl.TextFormat("pan grid: (%.3f, %.3f)", camera_grid_x, camera_grid_y),
                    )
                    label_y += line_height
                    rl.GuiLabel(
                        {label_x, label_y, label_width, label_height},
                        rl.TextFormat("nearest snap: (%.0f, %.0f)", snapped_grid_x, snapped_grid_y),
                    )
                    label_y += line_height
                    rl.GuiLabel(
                        {label_x, label_y, label_width, label_height},
                        rl.TextFormat("snap plane: (%.6f, %.6f)", snapped_plane_x, snapped_plane_y),
                    )
                    if lens_mode == .COVERAGE_MASK {
                        label_y += line_height
                        if coverage_alpha >= 0 {
                            coverage_sample_count := i32(math.round(coverage_alpha * 16.0))
                            rl.GuiLabel(
                                {label_x, label_y, label_width, label_height},
                                rl.TextFormat(
                                    "coverage: %d/16  alpha: %.4f",
                                    coverage_sample_count,
                                    coverage_alpha,
                                ),
                            )
                        } else {
                            rl.GuiLabel(
                                {label_x, label_y, label_width, label_height},
                                "coverage: hover a lens pixel",
                            )
                        }
                    }

                    if lens_grid_visible {
                        grid_column_count := int(lens_bounds.width) / pixel_scale
                        grid_row_count := int(lens_bounds.height) / pixel_scale

                        for column_index := 0; column_index <= grid_column_count; column_index += 1 {
                            grid_line_x := lens_bounds.x + f32(column_index * pixel_scale)
                            grid_line_color := rl.Color{255, 255, 255, 45}
                            if column_index % 5 == 0 {
                                grid_line_color = rl.Color{255, 230, 80, 100}
                            }
                            rl.DrawLineV(
                                {grid_line_x, lens_bounds.y},
                                {grid_line_x, lens_bounds.y + lens_bounds.height},
                                grid_line_color,
                            )
                        }

                        for row_index := 0; row_index <= grid_row_count; row_index += 1 {
                            grid_line_y := lens_bounds.y + f32(row_index * pixel_scale)
                            grid_line_color := rl.Color{255, 255, 255, 45}
                            if row_index % 5 == 0 {
                                grid_line_color = rl.Color{255, 230, 80, 100}
                            }
                            rl.DrawLineV(
                                {lens_bounds.x, grid_line_y},
                                {lens_bounds.x + lens_bounds.width, grid_line_y},
                                grid_line_color,
                            )
                        }
                    }
                }
                rl.DrawRectangleLinesEx(lens_bounds, 2, rl.WHITE)

                // Keep the three available modes visible and directly attached
                // to the preview instead of hiding them in shortcut help.
                lens_mode_bar_bounds, lens_footer_bounds :=
                    lens_control_bar_bounds(lens_bounds, lens_lower_ui_top)
                rl.GuiSetAlpha(LENS_UI_OPACITY)
                rl.GuiPanel(lens_mode_bar_bounds, nil)
                lens_mode_content_x := lens_mode_bar_bounds.x + 4
                lens_mode_content_y := lens_mode_bar_bounds.y + 4
                lens_mode_label_width: f32 = 52
                lens_mode_button_gap: f32 = 4
                lens_mode_buttons_x := lens_mode_content_x + lens_mode_label_width +
                                       lens_mode_button_gap
                lens_mode_buttons_width := lens_mode_bar_bounds.width -
                                           lens_mode_label_width -
                                           lens_mode_button_gap - 8
                lens_mode_button_width := (
                    lens_mode_buttons_width - lens_mode_button_gap * 2
                ) / 3
                rl.GuiLabel(
                    {
                        lens_mode_content_x + 4,
                        lens_mode_content_y,
                        lens_mode_label_width - 4,
                        24,
                    },
                    "LENS",
                )

                pixelated_active := lens_mode == .PIXELATED
                if shared.ui_gui_toggle(
                    &ui_keyboard,
                    .LENS_PIXELATED,
                    {
                        lens_mode_buttons_x,
                        lens_mode_content_y,
                        lens_mode_button_width,
                        24,
                    },
                    "1  PIXELATED",
                    &pixelated_active,
                ) && pixelated_active {
                    lens_mode = .PIXELATED
                    log.info("Lens mode: pixelated")
                }
                blended_active := lens_mode == .BLENDED
                if shared.ui_gui_toggle(
                    &ui_keyboard,
                    .LENS_BLENDED,
                    {
                        lens_mode_buttons_x + lens_mode_button_width + lens_mode_button_gap,
                        lens_mode_content_y,
                        lens_mode_button_width,
                        24,
                    },
                    "2  BLENDED",
                    &blended_active,
                ) && blended_active {
                    lens_mode = .BLENDED
                    log.info("Lens mode: blended 50/50")
                }
                coverage_active := lens_mode == .COVERAGE_MASK
                if shared.ui_gui_toggle(
                    &ui_keyboard,
                    .LENS_COVERAGE,
                    {
                        lens_mode_buttons_x +
                            (lens_mode_button_width + lens_mode_button_gap) * 2,
                        lens_mode_content_y,
                        lens_mode_button_width,
                        24,
                    },
                    "3  COVERAGE",
                    &coverage_active,
                ) && coverage_active {
                    lens_mode = .COVERAGE_MASK
                    log.info("Lens mode: 16-sample coverage mask")
                }

                rl.GuiPanel(lens_footer_bounds, nil)
                lens_footer_content_x := lens_footer_bounds.x + 4
                lens_footer_content_y := lens_footer_bounds.y + 4
                grid_button_bounds := rl.Rectangle{
                    lens_footer_content_x,
                    lens_footer_content_y,
                    96,
                    24,
                }
                grid_active := lens_grid_visible
                if shared.ui_gui_toggle(
                    &ui_keyboard,
                    .LENS_GRID,
                    grid_button_bounds,
                    "GRID [G]",
                    &grid_active,
                ) {
                    lens_grid_visible = grid_active
                    if lens_grid_visible {
                        log.info("Lens grid: on")
                    } else {
                        log.info("Lens grid: off")
                    }
                }
                lens_export_width := c.int(math.round(
                    lens_bounds.width / f32(applied_downscale_level),
                ))
                lens_export_height := c.int(math.round(
                    lens_bounds.height / f32(applied_downscale_level),
                ))
                rl.GuiLabel(
                    {
                        lens_footer_content_x + 104,
                        lens_footer_content_y,
                        116,
                        24,
                    },
                    rl.TextFormat(
                        "%d x %d @ %dx",
                        lens_export_width,
                        lens_export_height,
                        applied_downscale_level,
                    ),
                )
                export_button_bounds := rl.Rectangle{
                    lens_footer_content_x + 224,
                    lens_footer_content_y,
                    lens_footer_bounds.width - 232,
                    24,
                }
                if shared.ui_gui_button(
                    &ui_keyboard,
                    .EXPORT_PNG,
                    export_button_bounds,
                    "EXPORT PNG [P]",
                ) {
                    export_requested = true
                }
                if rl.GetTime() - last_export_time < 5.0 {
                    export_status: cstring = "PNG export failed"
                    if last_export_succeeded {
                        last_export_path_cstr := strings.clone_to_cstring(
                            last_export_path,
                            context.temp_allocator,
                        )
                        export_status = rl.TextFormat("Saved: %s", last_export_path_cstr)
                    }
                    export_status_y := lens_footer_bounds.y +
                                       lens_footer_bounds.height + 2
                    if export_status_y + 18 > lens_lower_ui_top {
                        export_status_y = lens_footer_bounds.y - 20
                    }
                    rl.GuiLabel(
                        {
                            lens_bounds.x,
                            export_status_y,
                            lens_bounds.width,
                            18,
                        },
                        export_status,
                    )
                }
                rl.GuiSetAlpha(1.0)
                if !capture_options.enabled {
                    lens_resize_visual_bounds := rl.Rectangle{
                        lens_bounds.x + lens_bounds.width -
                            LENS_RESIZE_HANDLE_SIZE * 0.5,
                        lens_bounds.y + lens_bounds.height -
                            LENS_RESIZE_HANDLE_SIZE * 0.5,
                        LENS_RESIZE_HANDLE_SIZE,
                        LENS_RESIZE_HANDLE_SIZE,
                    }
                    lens_resize_handle_color := rl.WHITE
                    if lens_resize_for_frame || mouse_over_lens_resize_handle {
                        lens_resize_handle_color = rl.Color{255, 220, 70, 255}
                    }
                    rl.DrawRectangleRec(
                        lens_resize_visual_bounds,
                        lens_resize_handle_color,
                    )
                    rl.DrawRectangleLinesEx(
                        lens_resize_visual_bounds,
                        1,
                        rl.BLACK,
                    )
                }
                // Render animation controls inline in their only composite UI location.
                for {
                    bounds := animation_timeline_bounds
                    playback := &animation_playback
                    animation, animation_found := shared.animation_playback_find_active_animation(playback)
                    if !animation_found {
                        break
                    }

                    rl.GuiPanel(bounds, nil)

                    content_x := bounds.x + 10
                    content_width := bounds.width - 20
                    controls_y := bounds.y + 8
                    clip_region_width: f32 = 224
                    clip_label_width: f32 = 56
                    clip_label_gap: f32 = 4
                    clip_label_bounds := rl.Rectangle{
                        content_x,
                        controls_y,
                        clip_label_width,
                        24,
                    }
                    clip_group_bounds := rl.Rectangle{
                        clip_label_bounds.x + clip_label_bounds.width + clip_label_gap,
                        controls_y,
                        clip_region_width - clip_label_width - clip_label_gap,
                        24,
                    }
                    clip_step_width: f32 = 28
                    clip_previous_bounds := rl.Rectangle{
                        clip_group_bounds.x,
                        clip_group_bounds.y,
                        clip_step_width,
                        clip_group_bounds.height,
                    }
                    clip_selector_bounds := rl.Rectangle{
                        clip_previous_bounds.x + clip_previous_bounds.width,
                        clip_group_bounds.y,
                        clip_group_bounds.width - clip_step_width * 2,
                        clip_group_bounds.height,
                    }
                    clip_next_bounds := rl.Rectangle{
                        clip_selector_bounds.x + clip_selector_bounds.width,
                        clip_group_bounds.y,
                        clip_step_width,
                        clip_group_bounds.height,
                    }
                    transport_x := content_x + clip_region_width + 8
                    transport_width: f32 = 180
                    frame_x := transport_x + transport_width + 8
                    frame_width: f32 = 64
                    speed_x := frame_x + frame_width + 8
                    speed_width: f32 = 132
                    loop_x := speed_x + speed_width + 8
                    loop_width: f32 = 56
                    sampled_x := loop_x + loop_width + 8
                    sampled_width: f32 = 76
                    count_x := sampled_x + sampled_width + 8
                    count_width := content_x + content_width - count_x

                    clip_item_count := min(
                        c.int(len(playback.valid_indices)),
                        c.int(len(playback.clip_labels)),
                    )
                    active_clip_label: cstring = "Animation"
                    if playback.active_index >= 0 &&
                       playback.active_index < clip_item_count {
                        active_clip_label = playback.clip_labels[playback.active_index]
                    }
                    rl.GuiLabel(
                        clip_label_bounds,
                        rl.TextFormat(
                            "CLIP %d/%d",
                            playback.active_index + 1,
                            clip_item_count,
                        ),
                    )

                    clip_changed := false
                    can_select_previous_clip := playback.active_index > 0
                    if can_select_previous_clip {
                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .ANIMATION_PREVIOUS_CLIP,
                            clip_previous_bounds,
                            "<",
                        ) {
                            clip_changed = shared.animation_playback_select_clip(
                                playback,
                                playback.active_index - 1,
                            )
                        }
                    } else {
                        rl.GuiDisable()
                        _ = rl.GuiButton(clip_previous_bounds, "<")
                        rl.GuiEnable()
                    }
                    if clip_changed && playback.active_index >= 0 &&
                       playback.active_index < clip_item_count {
                        active_clip_label = playback.clip_labels[playback.active_index]
                    }

                    clip_focused := shared.ui_control_register(
                        &ui_keyboard,
                        .ANIMATION_CLIP,
                        clip_selector_bounds,
                    )
                    clip_opened_this_frame := false
                    clip_selector_text := rl.TextFormat(
                        "%.12s",
                        active_clip_label,
                    )
                    clip_toggled := rl.GuiButton(
                        clip_selector_bounds,
                        clip_selector_text,
                    )
                    if clip_focused && shared.ui_activation_is_pressed() {
                        clip_toggled = true
                    }
                    if clip_toggled {
                        playback.dropdown_open = !playback.dropdown_open
                        if playback.dropdown_open {
                            playback.dropdown_scroll_index = 0
                            playback.dropdown_focus_index = -1
                            clip_opened_this_frame = true
                            shared.ui_keyboard_focus_set(
                                &ui_keyboard,
                                .ANIMATION_CLIP,
                            )
                        }
                    }
                    shared.ui_focus_draw(clip_selector_bounds, clip_focused)

                    can_select_next_clip := playback.active_index >= 0 &&
                        playback.active_index < clip_item_count - 1
                    if can_select_next_clip {
                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .ANIMATION_NEXT_CLIP,
                            clip_next_bounds,
                            ">",
                        ) {
                            clip_changed = shared.animation_playback_select_clip(
                                playback,
                                playback.active_index + 1,
                            ) || clip_changed
                        }
                    } else {
                        rl.GuiDisable()
                        _ = rl.GuiButton(clip_next_bounds, ">")
                        rl.GuiEnable()
                    }
                    if clip_changed {
                        playback.dropdown_open = false
                        log.infof(
                            "Selected animation clip %d",
                            playback.active_index + 1,
                        )
                    }

                    lock_transport_controls := playback.dropdown_open && !rl.GuiIsLocked()
                    if lock_transport_controls {
                        rl.GuiLock()
                    }

                    button_gap: f32 = 4
                    reset_width: f32 = 32
                    step_width: f32 = 32
                    play_width: f32 = 72

                    if shared.ui_gui_button(
                        &ui_keyboard,
                        .ANIMATION_FIRST,
                        {transport_x, controls_y, reset_width, 24},
                        "|<",
                    ) {
                        shared.animation_playback_reset_to_first_frame(playback)
                    }
                    previous_button_x := transport_x + reset_width + button_gap
                    if shared.ui_gui_button(
                        &ui_keyboard,
                        .ANIMATION_PREVIOUS,
                        {previous_button_x, controls_y, step_width, 24},
                        "<",
                    ) {
                        _ = shared.animation_playback_step_frame(playback, -1)
                    }

                    play_button_x := previous_button_x + step_width + button_gap
                    play_label: cstring = "Play"
                    if playback.is_playing {
                        play_label = "Pause"
                    }
                    if shared.ui_gui_button(
                        &ui_keyboard,
                        .ANIMATION_PLAY,
                        {play_button_x, controls_y, play_width, 24},
                        play_label,
                    ) {
                        playback.is_playing = !playback.is_playing
                    }

                    next_button_x := play_button_x + play_width + button_gap
                    last_frame := f32(max(animation.keyframeCount - 1, 0))
                    if shared.ui_gui_button(
                        &ui_keyboard,
                        .ANIMATION_NEXT,
                        {next_button_x, controls_y, step_width, 24},
                        ">",
                    ) {
                        _ = shared.animation_playback_step_frame(playback, 1)
                    }

                    display_frame := shared.animation_playback_pose_frame(playback, animation)
                    rl.GuiLabel(
                        {frame_x, controls_y, frame_width, 24},
                        rl.TextFormat(
                            "%d / %d",
                            c.int(math.round(display_frame)),
                            animation.keyframeCount - 1,
                        ),
                    )
                    rl.GuiLabel({speed_x, controls_y, 34, 24}, "Speed")
                    _ = shared.ui_gui_slider_bar(
                        &ui_keyboard,
                        .ANIMATION_SPEED,
                        {speed_x + 36, controls_y + 3, 56, 18},
                        nil,
                        nil,
                        &playback.speed,
                        0.25,
                        2.0,
                        0.05,
                        0.25,
                    )
                    rl.GuiLabel(
                        {speed_x + 96, controls_y, 36, 24},
                        rl.TextFormat("%.2fx", playback.speed),
                    )
                    _ = shared.ui_gui_check_box(
                        &ui_keyboard,
                        .ANIMATION_LOOP,
                        {loop_x, controls_y + 4, 16, 16},
                        nil,
                        &playback.loop,
                    )
                    rl.GuiLabel({loop_x + 20, controls_y, 36, 24}, "Loop")

                    previous_sampled_playback := playback.sampled_playback
                    _ = shared.ui_gui_check_box(
                        &ui_keyboard,
                        .ANIMATION_SAMPLED,
                        {sampled_x, controls_y + 4, 16, 16},
                        nil,
                        &playback.sampled_playback,
                    )
                    rl.GuiLabel({sampled_x + 20, controls_y, 56, 24}, "Sampled")
                    rl.GuiLabel({count_x, controls_y, 38, 24}, "Count")
                    previous_sample_count := playback.sample_count
                    _ = shared.ui_gui_spinner(
                        &ui_keyboard,
                        .ANIMATION_SAMPLE_COUNT,
                        {count_x + 40, controls_y + 1, count_width - 40, 22},
                        nil,
                        &playback.sample_count,
                        1,
                        shared.animation_sample_count_max(animation),
                        1,
                        4,
                        false,
                    )
                    if playback.sampled_playback != previous_sampled_playback ||
                       playback.sample_count != previous_sample_count {
                        playback.sample_count = clamp(
                            playback.sample_count,
                            1,
                            shared.animation_sample_count_max(animation),
                        )
                        if playback.sampled_playback {
                            playback.current_frame = shared.animation_playback_pose_frame(
                                playback,
                                animation,
                            )
                        }
                        playback.pose_dirty = true
                    }

                    timeline_bounds := rl.Rectangle{
                        content_x,
                        bounds.y + 44,
                        content_width,
                        18,
                    }
                    previous_frame := playback.current_frame
                    _ = shared.ui_gui_slider_bar(
                        &ui_keyboard,
                        .ANIMATION_TIMELINE,
                        timeline_bounds,
                        nil,
                        nil,
                        &playback.current_frame,
                        0,
                        last_frame,
                        1,
                        10,
                    )
                    if playback.current_frame != previous_frame {
                        if playback.sampled_playback {
                            playback.current_frame = shared.animation_playback_pose_frame(
                                playback,
                                animation,
                            )
                        }
                        playback.is_playing = false
                        playback.pose_dirty = true
                    }
                    rl.GuiLabel(
                        {content_x, bounds.y + 66, 48, 18},
                        "0",
                    )
                    end_frame_label := rl.TextFormat(
                        "%d",
                        animation.keyframeCount - 1,
                    )
                    end_frame_label_width := f32(rl.MeasureText(end_frame_label, 10))
                    rl.GuiLabel(
                        {
                            content_x + content_width - end_frame_label_width,
                            bounds.y + 66,
                            end_frame_label_width,
                            18,
                        },
                        end_frame_label,
                    )

                    if lock_transport_controls {
                        rl.GuiUnlock()
                    }

                    if playback.dropdown_open && clip_item_count > 0 {
                        popup_height := f32(clip_item_count) *
                            ANIMATION_CLIP_POPUP_ROW_HEIGHT + 4
                        popup_bounds := rl.Rectangle{
                            clip_group_bounds.x,
                            bounds.y - popup_height - 4,
                            clip_region_width,
                            popup_height,
                        }
                        candidate_active_index := playback.active_index
                        _ = rl.GuiListViewEx(
                            popup_bounds,
                            raw_data(playback.clip_labels[:]),
                            clip_item_count,
                            &playback.dropdown_scroll_index,
                            &candidate_active_index,
                            &playback.dropdown_focus_index,
                        )
                        playback.dropdown_scroll_index = 0
                        if clip_focused && !shared.ui_primary_modifier_is_down() &&
                           !(rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)) {
                            _ = shared.ui_int_adjust(
                                &candidate_active_index,
                                0,
                                clip_item_count - 1,
                                1,
                                1,
                            )
                        }
                        if shared.animation_playback_select_clip(
                            playback,
                            candidate_active_index,
                        ) {
                            log.infof(
                                "Selected animation clip %d",
                                playback.active_index + 1,
                            )
                        }

                        popup_clicked := !rl.GuiIsLocked() &&
                            rl.CheckCollisionPointRec(rl.GetMousePosition(), popup_bounds) &&
                            rl.IsMouseButtonReleased(.LEFT) &&
                            playback.dropdown_focus_index >= 0
                        keyboard_confirmed := !clip_opened_this_frame && clip_focused &&
                            shared.ui_activation_is_pressed()
                        clicked_outside := !rl.GuiIsLocked() &&
                            rl.IsMouseButtonReleased(.LEFT) &&
                            !rl.CheckCollisionPointRec(rl.GetMousePosition(), popup_bounds) &&
                            !rl.CheckCollisionPointRec(rl.GetMousePosition(), clip_group_bounds)
                        if popup_clicked || keyboard_confirmed || clicked_outside {
                            playback.dropdown_open = false
                            shared.ui_keyboard_focus_set(
                                &ui_keyboard,
                                .ANIMATION_CLIP,
                            )
                        }
                    }
                    if playback.active_index >= clip_item_count {
                        playback.active_index = max(clip_item_count - 1, c.int(0))
                        playback.current_frame = 0
                        playback.is_playing = false
                        playback.pose_dirty = true
                    }
                    break
                }
                // Render the inspector inline in its only composite UI location.
                {
                    bounds := inspector_bounds
                    state := &inspector_ui
                    cel_style_ui_ptr := &cel_style_ui
                    cel_style_ptr := &cel_style
                    requested_source_index := &model_active_index
                    camera := &control_camera
                    downscale_level_ptr := &downscale_level
                    edge_aa_mode_ptr := &edge_aa_mode
                    background_color := &scene_background_color
                    background_picker_open_ptr := &background_picker_open
                rl.GuiPanel(bounds, "INSPECTOR")

                view := rl.Rectangle{
                    bounds.x + 8,
                    bounds.y + 28,
                    bounds.width - 16,
                    bounds.height - 36,
                }
                content_height := inspector_content_height(state, cel_style_ui_ptr, cel_style_ptr)
                max_scroll := max(content_height - view.height, f32(0))
                mouse_position := rl.GetMousePosition()
                mouse_over_view := rl.CheckCollisionPointRec(mouse_position, view)
                if mouse_over_view && !state.scrollbar_dragging {
                    wheel_delta := rl.GetMouseWheelMove()
                    if wheel_delta != 0 {
                        state.scroll_y -= wheel_delta * 42
                    }
                }
                state.scroll_y = clamp(state.scroll_y, f32(0), max_scroll)

                scrollbar_width: f32 = 0
                if content_height > view.height {
                    scrollbar_width = 14
                }
                content_width := view.width - scrollbar_width
                content_y := view.y - state.scroll_y

                content_was_locked := rl.GuiIsLocked()
                content_locked_here := !content_was_locked && !mouse_over_view
                if content_locked_here {
                    rl.GuiLock()
                }
                rl.BeginScissorMode(
                    c.int(view.x),
                    c.int(view.y),
                    c.int(view.width),
                    c.int(view.height),
                )
                    // Limit keyboard focus registration to the visible inspector viewport.
                    shared.ui_keyboard_clip_set(&ui_keyboard, view)
                    model_height := inspector_section_height(state.model_open, 310)
                    // Render the model browser inline in its only inspector location.
                    for {
                        bounds := rl.Rectangle{view.x, content_y, content_width, model_height}
                        expanded := &state.model_open
                        browser := &model_browser
                        loaded_index := loaded_model_index
                        load_failed := model_load_failed
                        rl.GuiPanel(bounds, nil)
                        was_expanded := expanded^
                        draw_collapsible_header(
                            &ui_keyboard,
                            .MODEL_HEADER,
                            {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
                            "MODEL ASSETS",
                            expanded,
                        )
                        if was_expanded && !expanded^ {
                            browser.search_editing = false
                        }
                        if !expanded^ {
                            break
                        }

                        search_bounds := rl.Rectangle{
                            bounds.x + 10,
                            bounds.y + 28,
                            bounds.width - 48,
                            24,
                        }
                        clear_bounds := rl.Rectangle{
                            search_bounds.x + search_bounds.width + 4,
                            search_bounds.y,
                            24,
                            24,
                        }
                        search_was_editing := browser.search_editing
                        // Run the focus-aware text box inline in its sole search field.
                        search_focused := shared.ui_control_register(
                            &ui_keyboard,
                            .MODEL_SEARCH,
                            search_bounds,
                        )
                        search_was_locked := rl.GuiIsLocked()
                        unlock_for_keyboard_edit := search_was_locked && search_focused &&
                                                    browser.search_editing
                        if unlock_for_keyboard_edit {
                            rl.GuiUnlock()
                        }
                        search_toggled := rl.GuiTextBox(
                            search_bounds,
                            cstring(&browser.search_text[0]),
                            MODEL_SEARCH_TEXT_CAPACITY,
                            browser.search_editing,
                        )
                        if unlock_for_keyboard_edit {
                            rl.GuiLock()
                        }
                        if search_focused && !browser.search_editing && shared.ui_modifier_mask() == 0 &&
                           (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) {
                            search_toggled = true
                        }
                        shared.ui_focus_draw(search_bounds, search_focused || browser.search_editing)
                        if search_toggled {
                            browser.search_editing = !browser.search_editing
                        }
                        search_query := string(cstring(&browser.search_text[0]))
                        if len(search_query) == 0 && !browser.search_editing {
                            rl.GuiLabel(
                                {
                                    search_bounds.x + 8,
                                    search_bounds.y,
                                    search_bounds.width - 12,
                                    search_bounds.height,
                                },
                                rl.GuiIconText(
                                    .ICON_ZOOM_SMALL,
                                    rl.TextFormat("Search %d models...", len(model_assets.paths)),
                                ),
                            )
                        }
                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .MODEL_CLEAR,
                            clear_bounds,
                            rl.GuiIconText(.ICON_CROSS_SMALL, nil),
                        ) {
                            browser.search_text = {}
                            browser.search_editing = true
                        }

                        search_keyboard_active := search_was_editing || browser.search_editing
                        list_has_keyboard_focus :=
                            shared.ui_keyboard_focused_id(&ui_keyboard) == .MODEL_LIST
                        enter_pressed := (search_keyboard_active || list_has_keyboard_focus) &&
                                         (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER))
                        if search_keyboard_active && rl.IsKeyPressed(.ESCAPE) {
                            if len(search_query) > 0 {
                                browser.search_text = {}
                            } else {
                                browser.search_editing = false
                            }
                        }
                        if browser.search_text != browser.previous_search_text {
                            shared.model_search_results_rebuild(&model_assets, browser)
                        }

                        if (search_keyboard_active || list_has_keyboard_focus) &&
                           len(browser.results) > 0 {
                            if rl.IsKeyPressed(.DOWN) {
                                browser.active_index = min(
                                    browser.active_index + 1,
                                    c.int(len(browser.results) - 1),
                                )
                            }
                            if rl.IsKeyPressed(.UP) {
                                browser.active_index = max(browser.active_index - 1, 0)
                            }

                            page_size: c.int = 8
                            if rl.IsKeyPressed(.PAGE_DOWN) {
                                browser.active_index = min(
                                    browser.active_index + page_size,
                                    c.int(len(browser.results) - 1),
                                )
                            }
                            if rl.IsKeyPressed(.PAGE_UP) {
                                browser.active_index = max(browser.active_index - page_size, 0)
                            }
                            if rl.IsKeyPressed(.HOME) {
                                browser.active_index = 0
                            }
                            if rl.IsKeyPressed(.END) {
                                browser.active_index = c.int(len(browser.results) - 1)
                            }

                            visible_result_count: c.int = 8
                            if browser.active_index < browser.scroll_index {
                                browser.scroll_index = browser.active_index
                            } else if browser.active_index >=
                                      browser.scroll_index + visible_result_count {
                                browser.scroll_index = browser.active_index - visible_result_count + 1
                            }
                        }

                        list_bounds := rl.Rectangle{
                            bounds.x + 10,
                            bounds.y + 58,
                            bounds.width - 20,
                            bounds.height - 92,
                        }
                        if len(browser.result_labels) > 0 {
                            list_focused := shared.ui_control_register(
                                &ui_keyboard,
                                .MODEL_LIST,
                                list_bounds,
                            )
                            rl.GuiListViewEx(
                                list_bounds,
                                raw_data(browser.result_labels[:]),
                                c.int(len(browser.result_labels)),
                                &browser.scroll_index,
                                &browser.active_index,
                                &browser.focus_index,
                            )
                            shared.ui_focus_draw(list_bounds, list_focused)
                            result_clicked := !rl.GuiIsLocked() && rl.CheckCollisionPointRec(
                                rl.GetMousePosition(),
                                list_bounds,
                            ) && rl.IsMouseButtonReleased(.LEFT) && browser.focus_index >= 0
                            if (result_clicked || enter_pressed) &&
                               browser.active_index >= 0 &&
                               int(browser.active_index) < len(browser.results) {
                                requested_source_index^ =
                                    browser.results[browser.active_index].source_index
                                if result_clicked {
                                    browser.search_editing = false
                                }
                            }
                        } else {
                            rl.GuiLabel(list_bounds, "No matching models")
                        }

                        status_bounds := rl.Rectangle{
                            bounds.x + 10,
                            bounds.y + bounds.height - 28,
                            bounds.width - 20,
                            20,
                        }
                        if load_failed {
                            rl.GuiLabel(status_bounds, "Load failed; previous model kept")
                        } else if loaded_index >= 0 &&
                                  int(loaded_index) < len(model_assets.labels) {
                            rl.GuiLabel(
                                status_bounds,
                                rl.TextFormat("Loaded: %s", model_assets.labels[loaded_index]),
                            )
                        }
                        break
                    }
                    content_y += model_height + INSPECTOR_SECTION_GAP

                    lens_height := inspector_section_height(
                        state.lens_open,
                        INSPECTOR_LENS_EXPANDED_HEIGHT,
                    )
                    // Keep render-resolution controls in their own Lens section;
                    // camera navigation remains a separate mental model below.
                    for {
                        bounds := rl.Rectangle{view.x, content_y, content_width, lens_height}
                        expanded := &state.lens_open
                        rl.GuiSetAlpha(LENS_UI_OPACITY)
                        rl.GuiPanel(bounds, nil)
                        draw_collapsible_header(
                            &ui_keyboard,
                            .LENS_HEADER,
                            {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
                            "LENS",
                            expanded,
                        )
                        if !expanded^ {
                            rl.GuiSetAlpha(1.0)
                            break
                        }

                        content_x := bounds.x + 12
                        content_y := bounds.y + 34
                        content_width := bounds.width - 24

                        downscale_label_width: f32 = 104
                        downscale_value_width: f32 = 40
                        downscale_slider_x := content_x + downscale_label_width + 4
                        downscale_slider_width := max(
                            content_width - downscale_label_width -
                                downscale_value_width - 12,
                            f32(24),
                        )
                        rl.GuiLabel(
                            {content_x, content_y, downscale_label_width, 22},
                            "Downscale level",
                        )
                        _ = shared.ui_gui_int_slider_bar(
                            &ui_keyboard,
                            .LENS_DOWNSCALE,
                            {
                                downscale_slider_x,
                                content_y + 2,
                                downscale_slider_width,
                                18,
                            },
                            nil,
                            nil,
                            downscale_level_ptr,
                            MIN_DOWNSCALE_LEVEL,
                            MAX_DOWNSCALE_LEVEL,
                            1,
                            4,
                        )
                        rl.GuiLabel(
                            {
                                content_x + content_width - downscale_value_width,
                                content_y,
                                downscale_value_width,
                                22,
                            },
                            rl.TextFormat("%dx", downscale_level_ptr^),
                        )
                        content_y += 24
                        rl.GuiLabel(
                            {content_x, content_y, content_width, 18},
                            rl.TextFormat(
                                "Output grid: %d x %d",
                                downsample_width,
                                downsample_height,
                            ),
                        )
                        content_y += 20

                        rl.GuiLabel({content_x, content_y, 104, 22}, "Edge AA")
                        edge_aa_mode_index := c.int(edge_aa_mode_ptr^)
                        previous_edge_aa_mode := edge_aa_mode_index
                        _ = shared.ui_gui_combo_box(
                            &ui_keyboard,
                            .LENS_EDGE_AA,
                            {content_x + 108, content_y, content_width - 108, 22},
                            "Hard;Coverage",
                            &edge_aa_mode_index,
                            2,
                        )
                        if edge_aa_mode_index != previous_edge_aa_mode {
                            edge_aa_mode_ptr^ = shared.Edge_AA_Mode(edge_aa_mode_index)
                            if edge_aa_mode_ptr^ == .COVERAGE {
                                log.info("Edge AA: coverage")
                            } else {
                                log.info("Edge AA: hard")
                            }
                        }
                        rl.GuiSetAlpha(1.0)
                        break
                    }
                    content_y += lens_height + INSPECTOR_SECTION_GAP

                    camera_height := inspector_section_height(
                        state.camera_open,
                        INSPECTOR_CAMERA_EXPANDED_HEIGHT,
                    )
                    // Render camera controls inline in their only inspector location.
                    for {
                        bounds := rl.Rectangle{view.x, content_y, content_width, camera_height}
                        expanded := &state.camera_open
                        rl.GuiPanel(bounds, nil)
                        draw_collapsible_header(
                            &ui_keyboard,
                            .CAMERA_HEADER,
                            {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
                            "CAMERA CONTROLS",
                            expanded,
                        )
                        if !expanded^ {
                            break
                        }

                        content_x := bounds.x + 12
                        content_y := bounds.y + 28
                        content_width := bounds.width - 24
                        line_height: f32 = 18

                        rl.GuiLabel(
                            {content_x, content_y, content_width, 18},
                            "Reset axis view (from positive axis)",
                        )
                        content_y += 22

                        button_gap: f32 = 6
                        button_width := (content_width - button_gap * 2) / 3
                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .CAMERA_X,
                            {content_x, content_y, button_width, 24},
                            "X",
                        ) {
                            reset_camera_to_axis_view(
                                camera,
                                model_center,
                                {1, 0, 0},
                                {0, 1, 0},
                                scene_size,
                            )
                            log.info("Camera reset to +X axis view")
                        }
                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .CAMERA_Y,
                            {content_x + button_width + button_gap, content_y, button_width, 24},
                            "Y",
                        ) {
                            reset_camera_to_axis_view(
                                camera,
                                model_center,
                                {0, 1, 0},
                                {0, 0, 1},
                                scene_size,
                            )
                            log.info("Camera reset to +Y axis view")
                        }
                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .CAMERA_Z,
                            {
                                content_x + (button_width + button_gap) * 2,
                                content_y,
                                button_width,
                                24,
                            },
                            "Z",
                        ) {
                            reset_camera_to_axis_view(
                                camera,
                                model_center,
                                {0, 0, 1},
                                {0, 1, 0},
                                scene_size,
                            )
                            log.info("Camera reset to +Z axis view")
                        }
                        content_y += 28

                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .CAMERA_ISOMETRIC,
                            {content_x, content_y, content_width, 24},
                            "Isometric [I]",
                        ) {
                            reset_camera_to_axis_view(
                                camera,
                                model_center,
                                rl.Vector3Normalize({1, 1, 1}),
                                {0, 1, 0},
                                scene_size,
                            )
                            log.info("Camera reset to isometric view")
                        }
                        content_y += 30

                        rl.GuiLabel({content_x, content_y, content_width, 18}, "LMB orbit | MMB drag pan")
                        content_y += line_height
                        rl.GuiLabel({content_x, content_y, content_width, 18}, "WASD / Arrows pan | Q / E zoom")
                        content_y += line_height
                        rl.GuiLabel({content_x, content_y, content_width, 18}, "Wheel zoom | Shift faster")
                        break
                    }
                    content_y += camera_height + INSPECTOR_SECTION_GAP

                    cel_height := cel_style_editor_height(cel_style_ui_ptr, cel_style_ptr)
                    // Render the complete cel-style editor inline in its only inspector location.
                    for {
                        bounds := rl.Rectangle{view.x, content_y, content_width, cel_height}
                        state := cel_style_ui_ptr
                        style := cel_style_ptr
                        rl.GuiPanel(bounds, nil)
                        was_open := state.open
                        draw_collapsible_header(
                            &ui_keyboard,
                            .CEL_HEADER,
                            {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
                            "CEL SHADING [C]",
                            &state.open,
                        )
                        if was_open && !state.open {
                            state.color_target = .NONE
                        }
                        if !state.open {
                            break
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
                        _ = shared.ui_gui_combo_box(
                            &ui_keyboard,
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
                        if shared.ui_gui_button(&ui_keyboard, .CEL_RELOAD, {button_x, y, reload_width, 24}, "Reload") {
                            _ = load_selected_cel_style_preset(state, style)
                        }
                        button_x += reload_width + button_gap
                        if shared.ui_gui_button(&ui_keyboard, .CEL_SAVE, {button_x, y, save_width, 24}, "Save") {
                            _ = save_selected_cel_style_preset(state, style)
                        }
                        button_x += save_width + button_gap
                        if shared.ui_gui_button(&ui_keyboard, .CEL_RESET, {button_x, y, reset_width, 24}, "Reset") {
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
                        // Draw the style ramp directly in its sole preview location.
                        ramp_bounds := rl.Rectangle{x, y, width, 22}
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
                                shared.cel_color_component_to_byte(preview.x),
                                shared.cel_color_component_to_byte(preview.y),
                                shared.cel_color_component_to_byte(preview.z),
                                255,
                            }
                            band_x := ramp_bounds.x + lower_bound * ramp_bounds.width
                            band_width := max(
                                (upper_bound - lower_bound) * ramp_bounds.width,
                                f32(1),
                            )
                            rl.DrawRectangleRec(
                                {band_x, ramp_bounds.y, band_width, ramp_bounds.height},
                                color,
                            )
                            lower_bound = upper_bound
                        }
                        rl.DrawRectangleLinesEx(ramp_bounds, 1, rl.GRAY)
                        y += 30

                        changed := false

                        light_was_open := state.light_open
                        draw_cel_subsection(
                            &ui_keyboard,
                            .CEL_LIGHT_HEADER,
                            x,
                            y,
                            width,
                            "LIGHT",
                            &state.light_open,
                        )
                        if state.light_open {
                            // Draw and apply the light controls inline in their only subsection.
                            content_x := x + 8
                            cursor_y := y + CEL_SUBSECTION_HEADER_HEIGHT + 8
                            content_width := width - 16
                            content_changed := false
                            if !state.light_angles_valid {
                                sync_cel_style_light_angles(state, style)
                            }

                            rl.GuiLabel({content_x, cursor_y, 104, 22}, "Light space")
                            light_space := c.int(style.light_space)
                            previous_light_space := light_space
                            _ = shared.ui_gui_combo_box(
                                &ui_keyboard,
                                .CEL_LIGHT_SPACE,
                                {content_x + 108, cursor_y, content_width - 108, 22},
                                "World;Camera;Model",
                                &light_space,
                                3,
                            )
                            if light_space != previous_light_space {
                                style.light_space = shared.Cel_Light_Space(light_space)
                                content_changed = true
                            }
                            cursor_y += 30
                            if draw_cel_style_slider(
                                &ui_keyboard,
                                .CEL_LIGHT_AZIMUTH,
                                content_x,
                                cursor_y,
                                content_width,
                                "Azimuth",
                                &state.light_azimuth,
                                -180,
                                180,
                                1,
                                10,
                            ) {
                                update_cel_style_direction_from_angles(state, style)
                                content_changed = true
                            }
                            cursor_y += 28
                            if draw_cel_style_slider(
                                &ui_keyboard,
                                .CEL_LIGHT_ELEVATION,
                                content_x,
                                cursor_y,
                                content_width,
                                "Elevation",
                                &state.light_elevation,
                                -89,
                                89,
                                1,
                                10,
                            ) {
                                update_cel_style_direction_from_angles(state, style)
                                content_changed = true
                            }
                            cursor_y += 28
                            content_changed = draw_cel_style_slider(
                                &ui_keyboard,
                                .CEL_LIGHT_WRAP,
                                content_x,
                                cursor_y,
                                content_width,
                                "Wrap lighting",
                                &style.wrap_lighting,
                                0,
                                1,
                                0.01,
                                0.1,
                            ) || content_changed
                            cursor_y += 28
                            rl.GuiLabel(
                                {content_x, cursor_y, content_width, 32},
                                "Direction points from the surface toward the light.",
                            )
                            changed = content_changed || changed
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
                            &ui_keyboard,
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
                            // Draw and apply band/alpha controls inline in their only subsection.
                            bands_x := x + 8
                            cursor_y := y + CEL_SUBSECTION_HEADER_HEIGHT + 8
                            bands_width := width - 16
                            bands_changed := false
                            state.selected_band = clamp(
                                state.selected_band,
                                c.int(0),
                                c.int(style.band_count - 1),
                            )

                            rl.GuiLabel({bands_x, cursor_y, 38, 22}, "Band")
                            selected_display := state.selected_band + 1
                            _ = shared.ui_gui_spinner(
                                &ui_keyboard,
                                .CEL_BAND_SELECT,
                                {bands_x + 40, cursor_y, 62, 22},
                                nil,
                                &selected_display,
                                1,
                                c.int(style.band_count),
                                1,
                                1,
                                false,
                            )
                            state.selected_band = selected_display - 1
                            add_width := (bands_width - 110) * 0.5
                            if shared.ui_gui_button(
                                &ui_keyboard,
                                .CEL_BAND_ADD,
                                {bands_x + 108, cursor_y, add_width, 22},
                                "Add after",
                            ) {
                                if add_cel_band_after(style, int(state.selected_band)) {
                                    state.selected_band += 1
                                    bands_changed = true
                                }
                            }
                            if shared.ui_gui_button(
                                &ui_keyboard,
                                .CEL_BAND_REMOVE,
                                {
                                    bands_x + 112 + add_width,
                                    cursor_y,
                                    bands_width - 112 - add_width,
                                    22,
                                },
                                "Remove",
                            ) {
                                if remove_cel_band(style, int(state.selected_band)) {
                                    state.selected_band = min(
                                        state.selected_band,
                                        c.int(style.band_count - 1),
                                    )
                                    bands_changed = true
                                }
                            }

                            band_index := int(state.selected_band)
                            band := &style.bands[band_index]
                            cursor_y += 32
                            rl.GuiLabel(
                                {bands_x, cursor_y, bands_width, 20},
                                rl.TextFormat(
                                    "Editing band %d of %d",
                                    band_index + 1,
                                    style.band_count,
                                ),
                            )
                            cursor_y += 28
                            if band_index < style.band_count - 1 {
                                band_lower_bound := f32(0)
                                if band_index > 0 {
                                    band_lower_bound = style.bands[band_index - 1].upper_bound +
                                                       shared.CEL_BOUNDARY_MINIMUM_GAP
                                }
                                band_upper_bound := f32(1) - shared.CEL_BOUNDARY_MINIMUM_GAP
                                if band_index < style.band_count - 2 {
                                    band_upper_bound = style.bands[band_index + 1].upper_bound -
                                                       shared.CEL_BOUNDARY_MINIMUM_GAP
                                }
                                bands_changed = draw_cel_style_slider(
                                    &ui_keyboard,
                                    .CEL_BAND_UPPER_BOUND,
                                    bands_x,
                                    cursor_y,
                                    bands_width,
                                    "Upper bound",
                                    &band.upper_bound,
                                    band_lower_bound,
                                    band_upper_bound,
                                    0.01,
                                    0.1,
                                ) || bands_changed
                                cursor_y += 28
                            }
                            bands_changed = draw_cel_style_slider(
                                &ui_keyboard,
                                .CEL_BAND_BRIGHTNESS,
                                bands_x,
                                cursor_y,
                                bands_width,
                                "Brightness",
                                &band.brightness,
                                0,
                                2,
                                0.05,
                                0.25,
                            ) || bands_changed
                            cursor_y += 28
                            bands_changed = draw_cel_style_slider(
                                &ui_keyboard,
                                .CEL_BAND_TINT_MIX,
                                bands_x,
                                cursor_y,
                                bands_width,
                                "Tint mix",
                                &band.tint_mix,
                                0,
                                1,
                                0.01,
                                0.1,
                            ) || bands_changed
                            cursor_y += 28

                            tint_color := cel_vector_color_to_raylib(band.tint)
                            draw_cel_color_swatch(
                                &ui_keyboard,
                                .CEL_BAND_TINT_SWATCH,
                                bands_x,
                                cursor_y,
                                bands_width,
                                "Tint",
                                tint_color,
                                .BAND_TINT,
                                state,
                            )
                            cursor_y += 28
                            if state.color_target == .BAND_TINT {
                                previous_tint_color := tint_color
                                _ = shared.ui_gui_color_picker(
                                    &ui_keyboard,
                                    .CEL_BAND_TINT_PICKER,
                                    {bands_x, cursor_y, 150, 150},
                                    &tint_color,
                                    false,
                                )
                                if tint_color != previous_tint_color {
                                    band.tint = cel_raylib_color_to_vector(tint_color)
                                    bands_changed = true
                                }
                                cursor_y += 158
                            }

                            rl.GuiLabel({bands_x, cursor_y, 104, 22}, "Alpha")
                            alpha_mode := c.int(style.alpha_mode)
                            previous_alpha_mode := alpha_mode
                            _ = shared.ui_gui_combo_box(
                                &ui_keyboard,
                                .CEL_ALPHA_MODE,
                                {bands_x + 108, cursor_y, bands_width - 108, 22},
                                "Opaque;Mask",
                                &alpha_mode,
                                2,
                            )
                            if alpha_mode != previous_alpha_mode {
                                style.alpha_mode = shared.Cel_Alpha_Mode(alpha_mode)
                                bands_changed = true
                            }
                            cursor_y += 30
                            if style.alpha_mode == .MASK {
                                bands_changed = draw_cel_style_slider(
                                    &ui_keyboard,
                                    .CEL_ALPHA_CUTOFF,
                                    bands_x,
                                    cursor_y,
                                    bands_width,
                                    "Cutoff",
                                    &style.alpha_cutoff,
                                    0,
                                    1,
                                    0.01,
                                    0.1,
                                ) || bands_changed
                            }
                            changed = bands_changed || changed
                        }
                        y += cel_subsection_height(
                            state.bands_open,
                            cel_style_bands_content_height(state, style),
                        ) + INSPECTOR_SECTION_GAP

                        accents_was_open := state.accents_open
                        draw_cel_subsection(
                            &ui_keyboard,
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
                            // Compose the two accent editors inline in their only subsection.
                            accents_x := x + 8
                            accents_y := y + CEL_SUBSECTION_HEADER_HEIGHT + 8
                            accents_width := width - 16
                            rim_changed := draw_cel_accent_content(
                                &ui_keyboard,
                                accents_x,
                                accents_y,
                                accents_width,
                                "Rim light",
                                .RIM,
                                state,
                                &style.rim,
                            )
                            highlight_y := accents_y + cel_accent_block_height(state, .RIM) + 8
                            rl.GuiLine({accents_x, highlight_y - 6, accents_width, 2}, nil)
                            highlight_changed := draw_cel_accent_content(
                                &ui_keyboard,
                                accents_x,
                                highlight_y,
                                accents_width,
                                "Highlight",
                                .HIGHLIGHT,
                                state,
                                &style.highlight,
                            )
                            changed = rim_changed || highlight_changed || changed
                        }
                        y += cel_subsection_height(
                            state.accents_open,
                            cel_style_accents_content_height(state),
                        ) + INSPECTOR_SECTION_GAP

                        outline_was_open := state.outline_open
                        draw_cel_subsection(
                            &ui_keyboard,
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
                            // Draw and apply outline controls inline in their only subsection.
                            outline_x := x + 8
                            cursor_y := y + CEL_SUBSECTION_HEADER_HEIGHT + 8
                            outline_width_available := width - 16
                            outline_changed := false
                            rl.GuiLabel({outline_x, cursor_y, 104, 22}, "Width (pixels)")
                            outline_width := c.int(style.outline.width)
                            previous_width := outline_width
                            _ = shared.ui_gui_spinner(
                                &ui_keyboard,
                                .CEL_OUTLINE_WIDTH,
                                {
                                    outline_x + 108,
                                    cursor_y,
                                    outline_width_available - 108,
                                    22,
                                },
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
                                outline_changed = true
                            }
                            cursor_y += 32
                            outline_changed = draw_cel_style_slider(
                                &ui_keyboard,
                                .CEL_OUTLINE_COVERAGE,
                                outline_x,
                                cursor_y,
                                outline_width_available,
                                "Coverage",
                                &style.outline.coverage_threshold,
                                0,
                                1,
                                0.01,
                                0.1,
                            ) || outline_changed
                            cursor_y += 28

                            outline_color := style.outline.color
                            draw_cel_color_swatch(
                                &ui_keyboard,
                                .CEL_OUTLINE_SWATCH,
                                outline_x,
                                cursor_y,
                                outline_width_available,
                                "Color",
                                outline_color,
                                .OUTLINE,
                                state,
                            )
                            cursor_y += 32
                            if state.color_target == .OUTLINE {
                                previous_color := outline_color
                                _ = shared.ui_gui_color_picker(
                                    &ui_keyboard,
                                    .CEL_OUTLINE_PICKER,
                                    {outline_x, cursor_y, 160, 160},
                                    &outline_color,
                                    false,
                                )
                                if outline_color != previous_color {
                                    style.outline.color.r = outline_color.r
                                    style.outline.color.g = outline_color.g
                                    style.outline.color.b = outline_color.b
                                    outline_changed = true
                                }
                                cursor_y += 168
                            }

                            alpha := f32(style.outline.color.a) / 255
                            previous_alpha := alpha
                            outline_changed = draw_cel_style_slider(
                                &ui_keyboard,
                                .CEL_OUTLINE_ALPHA,
                                outline_x,
                                cursor_y,
                                outline_width_available,
                                "Alpha",
                                &alpha,
                                0,
                                1,
                                0.01,
                                0.1,
                            ) || outline_changed
                            if alpha != previous_alpha {
                                style.outline.color.a = shared.cel_color_component_to_byte(alpha)
                            }
                            changed = outline_changed || changed
                        }
                        y += cel_subsection_height(
                            state.outline_open,
                            cel_style_outline_content_height(state),
                        ) + INSPECTOR_SECTION_GAP

                        if changed {
                            // Mark the style dirty where the editor is its only mutation aggregator.
                            style.revision += 1
                            state.dirty = true
                            state.status = .NONE
                        }

                        // Select the transient status copy directly before drawing it.
                        status_text: cstring
                        switch state.status {
                        case .NONE:        status_text = "Changes apply immediately"
                        case .LOADED:      status_text = "Preset loaded"
                        case .SAVED:       status_text = "Preset saved"
                        case .RESET:       status_text = "Reset to built-in Classic"
                        case .LOAD_FAILED: status_text = "Preset load failed; current style kept"
                        case .SAVE_FAILED: status_text = "Preset save failed"
                        }
                        if state.status == .NONE || rl.GetTime() - state.status_time < 5 {
                            rl.GuiStatusBar({x, y, width, 20}, status_text)
                        }
                        break
                    }
                    content_y += cel_height + INSPECTOR_SECTION_GAP

                    background_height := inspector_section_height(state.background_open, 120)
                    // Render background controls inline in their only inspector location.
                    for {
                        bounds := rl.Rectangle{view.x, content_y, content_width, background_height}
                        expanded := &state.background_open
                        picker_open := background_picker_open_ptr
                        rl.GuiPanel(bounds, nil)
                        was_expanded := expanded^
                        draw_collapsible_header(
                            &ui_keyboard,
                            .BACKGROUND_HEADER,
                            {bounds.x, bounds.y, bounds.width, INSPECTOR_SECTION_HEADER_HEIGHT},
                            "SCENE BACKGROUND",
                            expanded,
                        )
                        if was_expanded && !expanded^ {
                            picker_open^ = false
                        }
                        if !expanded^ {
                            break
                        }

                        swatch_bounds := rl.Rectangle{
                            bounds.x + 12,
                            bounds.y + 30,
                            54,
                            54,
                        }
                        rl.DrawRectangleRec(swatch_bounds, background_color^)
                        rl.DrawRectangleLinesEx(swatch_bounds, 2, rl.RAYWHITE)

                        button_x := swatch_bounds.x + swatch_bounds.width + 12
                        button_width := bounds.x + bounds.width - button_x - 12
                        picker_button_text: cstring = "Open color picker"
                        if picker_open^ {
                            picker_button_text = "Close color picker"
                        }
                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .BACKGROUND_PICKER_TOGGLE,
                            {button_x, bounds.y + 30, button_width, 25},
                            picker_button_text,
                        ) {
                            picker_open^ = !picker_open^
                            if picker_open^ {
                                shared.ui_keyboard_focus_set(&ui_keyboard, .BACKGROUND_PICKER)
                            }
                        }
                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .BACKGROUND_RESET,
                            {button_x, bounds.y + 59, button_width, 25},
                            "Reset to black",
                        ) {
                            background_color^ = rl.BLACK
                        }

                        rl.GuiLabel(
                            {bounds.x + 12, bounds.y + 88, bounds.width - 24, 18},
                            rl.TextFormat(
                                "RGB: %d, %d, %d",
                                c.int(background_color.r),
                                c.int(background_color.g),
                                c.int(background_color.b),
                            ),
                        )

                        break
                    }
                    // End the inspector's sole focus-clipping region.
                    shared.ui_keyboard_clip_clear(&ui_keyboard)
                rl.EndScissorMode()
                if content_locked_here {
                    rl.GuiUnlock()
                }

                // Draw and interact with the inspector scrollbar inline at its sole site.
                for {
                    if content_height <= view.height {
                        state.scrollbar_dragging = false
                        break
                    }

                    track := rl.Rectangle{
                        view.x + view.width - 10,
                        view.y,
                        10,
                        view.height,
                    }
                    max_scroll := content_height - view.height
                    thumb_height := max(f32(42), view.height * view.height / content_height)
                    thumb_travel := track.height - thumb_height
                    thumb_y := track.y
                    if max_scroll > 0 {
                        thumb_y += state.scroll_y / max_scroll * thumb_travel
                    }
                    thumb := rl.Rectangle{track.x + 2, thumb_y, track.width - 4, thumb_height}
                    mouse_position := rl.GetMousePosition()
                    scrollbar_focused := shared.ui_control_register(
                        &ui_keyboard,
                        .INSPECTOR_SCROLLBAR,
                        track,
                    )

                    if scrollbar_focused {
                        if shared.ui_key_is_pressed_or_repeating(.UP) {
                            state.scroll_y = max(state.scroll_y - 42, f32(0))
                        }
                        if shared.ui_key_is_pressed_or_repeating(.DOWN) {
                            state.scroll_y = min(state.scroll_y + 42, max_scroll)
                        }
                        if rl.IsKeyPressed(.PAGE_UP) {
                            state.scroll_y = max(state.scroll_y - 210, f32(0))
                        }
                        if rl.IsKeyPressed(.PAGE_DOWN) {
                            state.scroll_y = min(state.scroll_y + 210, max_scroll)
                        }
                        if rl.IsKeyPressed(.HOME) {
                            state.scroll_y = 0
                        }
                        if rl.IsKeyPressed(.END) {
                            state.scroll_y = max_scroll
                        }
                    }

                    if rl.IsMouseButtonPressed(.LEFT) {
                        if rl.CheckCollisionPointRec(mouse_position, thumb) {
                            state.scrollbar_dragging = true
                            state.scrollbar_drag_offset = mouse_position.y - thumb.y
                        } else if rl.CheckCollisionPointRec(mouse_position, track) {
                            state.scroll_y = clamp(
                                (mouse_position.y - track.y - thumb_height * 0.5) /
                                max(thumb_travel, f32(1)) * max_scroll,
                                f32(0),
                                max_scroll,
                            )
                        }
                    }
                    if state.scrollbar_dragging {
                        if rl.IsMouseButtonDown(.LEFT) {
                            state.scroll_y = clamp(
                                (mouse_position.y - track.y - state.scrollbar_drag_offset) /
                                max(thumb_travel, f32(1)) * max_scroll,
                                f32(0),
                                max_scroll,
                            )
                        } else {
                            state.scrollbar_dragging = false
                        }
                    }

                    rl.DrawRectangleRec(track, rl.Color{24, 24, 24, 210})
                    thumb_color := rl.Color{126, 126, 126, 255}
                    if rl.CheckCollisionPointRec(mouse_position, thumb) || state.scrollbar_dragging {
                        thumb_color = rl.Color{180, 180, 180, 255}
                    }
                    rl.DrawRectangleRec(thumb, thumb_color)
                    shared.ui_focus_draw(track, scrollbar_focused)
                    break
                }
                // Render the floating background picker inline at its only draw point.
                for {
                    picker_bounds := background_picker_bounds
                    picker_open := background_picker_open_ptr
                    if !picker_open^ {
                        break
                    }
                    if rl.GuiWindowBox(picker_bounds, "BACKGROUND COLOR") != 0 {
                        picker_open^ = false
                        break
                    }
                    _ = shared.ui_gui_color_picker(
                        &ui_keyboard,
                        .BACKGROUND_PICKER,
                        {
                            picker_bounds.x + 12,
                            picker_bounds.y + 34,
                            165,
                            165,
                        },
                        background_color,
                        false,
                    )
                    break
                }
                }
                if composite_locks_gui {
                    rl.GuiUnlock()
                }
                if shortcuts_help_open {
                    // Draw shortcut help inline in its only modal pass.
                    for {
                        bounds := rl.Rectangle{
                            (f32(screen_width) - 930) * 0.5,
                            (f32(screen_height) - 560) * 0.5,
                            930,
                            560,
                        }
                        open := &shortcuts_help_open
                        rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color{0, 0, 0, 170})
                        rl.GuiPanel(bounds, "KEYBOARD SHORTCUTS")
                        if shared.ui_gui_button(
                            &ui_keyboard,
                            .HELP_CLOSE,
                            {bounds.x + bounds.width - 34, bounds.y + 4, 28, 22},
                            "X",
                        ) {
                            open^ = false
                            shared.ui_keyboard_focus_clear(&ui_keyboard)
                            break
                        }

                        column_width := (bounds.width - 42) * 0.5
                        line_height: f32 = 22
                        left_x := bounds.x + 16
                        right_x := left_x + column_width + 10
                        start_y := bounds.y + 36
                        for line, line_index in shared.UI_SHORTCUT_HELP_LEFT {
                            color := rl.Color{45, 45, 45, 255}
                            if line == "GENERAL" || line == "MODEL & INSPECTOR" ||
                               line == "LENS & CAMERA" {
                                color = rl.Color{190, 110, 0, 255}
                            }
                            rl.DrawText(
                                line,
                                c.int(left_x),
                                c.int(start_y + f32(line_index) * line_height),
                                16,
                                color,
                            )
                        }
                        for line, line_index in shared.UI_SHORTCUT_HELP_RIGHT {
                            color := rl.Color{45, 45, 45, 255}
                            if line == "ANIMATION" || line == "CEL & BACKGROUND" ||
                               line == "FOCUSED CONTROLS" {
                                color = rl.Color{190, 110, 0, 255}
                            }
                            rl.DrawText(
                                line,
                                c.int(right_x),
                                c.int(start_y + f32(line_index) * line_height),
                                16,
                                color,
                            )
                        }
                        break
                    }
                }
                shared.ui_keyboard_end_frame(&ui_keyboard)
            rl.EndTextureMode()

            if viewer_video_enabled && capture_options.render_debug_video {
                expected_video_frames := viewer_video_expected_frame_count(
                    capture_options,
                )
                debug_pass := viewer_render_debug_video_pass(
                    u64(captured_sequence_frames),
                    expected_video_frames,
                )
                render_debug_frame := Viewer_Render_Debug_Frame{
                    scene_color = scene_render_target.texture,
                    cel_bands = cel_band_render_target.texture,
                    raw_downsample = downsample_render_target.texture,
                    coverage = coverage_mask_render_target.texture,
                    outlined = outlined_render_target.texture,
                    composite = composite_render_target.texture,
                }
                if render_debug_video.selected != debug_pass ||
                   !render_debug_video.sample_valid {
                    render_debug_video.selected = debug_pass
                    debug_texture, _ := viewer_render_debug_pass_texture(
                        &render_debug_frame,
                        debug_pass,
                    )
                    viewer_render_debug_sample(
                        &render_debug_video,
                        debug_texture,
                        debug_texture.width / 2,
                        debug_texture.height / 2,
                    )
                }
                rl.BeginTextureMode(render_debug_video_target)
                    viewer_render_debug_draw(
                        &render_debug_video,
                        &render_debug_frame,
                        render_debug_shader,
                        render_debug_display_mode_location,
                        &animation_playback,
                        false,
                    )
                rl.EndTextureMode()
            }

            if export_requested {
                if len(last_export_path) > 0 {
                    delete(last_export_path)
                    last_export_path = ""
                }
                // Crop and export the low-resolution lens inline on the sole request path.
                last_export_succeeded = false
                if applied_downscale_level > 0 {
                    texture_readback := rl.LoadImageFromTexture(
                        outlined_render_target.texture,
                    )
                    if texture_readback.data != nil {
                        // Convert the logical crop to vertically inverted readback space.
                        crop_x := c.int(
                            math.round(lens_bounds.x / f32(applied_downscale_level)),
                        )
                        logical_crop_y := c.int(
                            math.round(lens_bounds.y / f32(applied_downscale_level)),
                        )
                        crop_width := c.int(
                            math.round(
                                lens_bounds.width / f32(applied_downscale_level),
                            ),
                        )
                        crop_height := c.int(
                            math.round(
                                lens_bounds.height / f32(applied_downscale_level),
                            ),
                        )
                        crop_y := texture_readback.height - logical_crop_y -
                                  crop_height
                        crop_is_valid := crop_x >= 0 && crop_y >= 0 &&
                                         crop_width > 0 && crop_height > 0 &&
                                         crop_x + crop_width <= texture_readback.width &&
                                         crop_y + crop_height <= texture_readback.height
                        if !crop_is_valid {
                            log.errorf(
                                "Lens export crop is outside the downsample target: crop(%d, %d, %d, %d), target(%d, %d)",
                                crop_x,
                                crop_y,
                                crop_width,
                                crop_height,
                                texture_readback.width,
                                texture_readback.height,
                            )
                        } else {
                            rl.ImageCrop(
                                &texture_readback,
                                {
                                    f32(crop_x),
                                    f32(crop_y),
                                    f32(crop_width),
                                    f32(crop_height),
                                },
                            )
                            rl.ImageFlipVertical(&texture_readback)
                            rl.ImageFormat(
                                &texture_readback,
                                .UNCOMPRESSED_R8G8B8A8,
                            )

                            // Continue from the next unused sequence number.
                            for {
                                candidate_path := fmt.tprintf(
                                    "lens_downsample_%03d.png",
                                    next_export_index,
                                )
                                next_export_index += 1
                                candidate_path_cstr := strings.clone_to_cstring(
                                    candidate_path,
                                    context.temp_allocator,
                                )
                                if !rl.FileExists(candidate_path_cstr) {
                                    last_export_path = strings.clone(candidate_path)
                                    break
                                }
                            }
                            export_path_cstr := strings.clone_to_cstring(
                                last_export_path,
                                context.temp_allocator,
                            )
                            last_export_succeeded = rl.ExportImage(
                                texture_readback,
                                export_path_cstr,
                            )
                        }
                        rl.UnloadImage(texture_readback)
                    }
                }
                last_export_time = rl.GetTime()
                if last_export_succeeded {
                    log.infof("Exported transparent lens PNG: %s", last_export_path)
                } else {
                    log.error("Failed to export transparent lens PNG")
                }
            }

            rl.BeginDrawing()
                rl.ClearBackground(scene_background_color)
                if render_debug.open && !capture_options.enabled {
                    render_debug_frame := Viewer_Render_Debug_Frame{
                        scene_color = scene_render_target.texture,
                        cel_bands = cel_band_render_target.texture,
                        raw_downsample = downsample_render_target.texture,
                        coverage = coverage_mask_render_target.texture,
                        outlined = outlined_render_target.texture,
                        composite = composite_render_target.texture,
                    }
                    viewer_render_debug_draw(
                        &render_debug,
                        &render_debug_frame,
                        render_debug_shader,
                        render_debug_display_mode_location,
                        &animation_playback,
                        true,
                    )
                } else {
                    rl.DrawTexturePro(
                        composite_render_target.texture,
                        flipped_scene_source_bounds,
                        {0, 0, f32(screen_width), f32(screen_height)},
                        {},
                        0,
                        rl.WHITE,
                    )
                }
                // Draw the cursor magnifier inline at its only screen pass.
                // {
                //     bounds := magnifier_bounds
                //     source_texture := composite_render_target.texture
                //     mouse_position := rl.GetMousePosition()
                //     mouse_x := min(max(i32(mouse_position.x), 0), screen_width - 1)
                //     mouse_y := min(max(i32(mouse_position.y), 0), screen_height - 1)
                //     sample_x := min(
                //         max(mouse_x - MAGNIFIER_SAMPLE_SIZE / 2, 0),
                //         max(screen_width - MAGNIFIER_SAMPLE_SIZE, 0),
                //     )
                //     sample_y := min(
                //         max(mouse_y - MAGNIFIER_SAMPLE_SIZE / 2, 0),
                //         max(screen_height - MAGNIFIER_SAMPLE_SIZE, 0),
                //     )

                //     display_size := f32(MAGNIFIER_SAMPLE_SIZE * MAGNIFIER_DISPLAY_SCALE)
                //     magnified_image_bounds := rl.Rectangle{
                //         bounds.x + 10,
                //         bounds.y + 28,
                //         display_size,
                //         display_size,
                //     }
                //     texture_source_bounds := rl.Rectangle{
                //         f32(sample_x),
                //         f32(screen_height - sample_y - MAGNIFIER_SAMPLE_SIZE),
                //         f32(MAGNIFIER_SAMPLE_SIZE),
                //         -f32(MAGNIFIER_SAMPLE_SIZE),
                //     }

                //     rl.GuiPanel(bounds, "MAGNIFIER 16 x 16")
                //     rl.DrawTexturePro(
                //         source_texture,
                //         texture_source_bounds,
                //         magnified_image_bounds,
                //         {},
                //         0,
                //         rl.WHITE,
                //     )

                //     grid_color := rl.Color{0, 0, 0, 80}
                //     for grid_line_index := 0;
                //         grid_line_index <= MAGNIFIER_SAMPLE_SIZE;
                //         grid_line_index += 1 {
                //         grid_line_offset := f32(grid_line_index * MAGNIFIER_DISPLAY_SCALE)
                //         rl.DrawLineV(
                //             {
                //                 magnified_image_bounds.x + grid_line_offset,
                //                 magnified_image_bounds.y,
                //             },
                //             {
                //                 magnified_image_bounds.x + grid_line_offset,
                //                 magnified_image_bounds.y + magnified_image_bounds.height,
                //             },
                //             grid_color,
                //         )
                //         rl.DrawLineV(
                //             {
                //                 magnified_image_bounds.x,
                //                 magnified_image_bounds.y + grid_line_offset,
                //             },
                //             {
                //                 magnified_image_bounds.x + magnified_image_bounds.width,
                //                 magnified_image_bounds.y + grid_line_offset,
                //             },
                //             grid_color,
                //         )
                //     }

                //     // Keep the exact pixel under the cursor identifiable inside the 16x16 sample.
                //     cursor_column := mouse_x - sample_x
                //     cursor_row := mouse_y - sample_y
                //     cursor_pixel_bounds := rl.Rectangle{
                //         magnified_image_bounds.x + f32(cursor_column * MAGNIFIER_DISPLAY_SCALE),
                //         magnified_image_bounds.y + f32(cursor_row * MAGNIFIER_DISPLAY_SCALE),
                //         MAGNIFIER_DISPLAY_SCALE,
                //         MAGNIFIER_DISPLAY_SCALE,
                //     }
                //     rl.DrawRectangleLinesEx(cursor_pixel_bounds, 2, rl.YELLOW)
                //     rl.DrawRectangleLinesEx(magnified_image_bounds, 1, rl.RAYWHITE)
                //     rl.GuiLabel(
                //         {
                //             bounds.x + 10,
                //             magnified_image_bounds.y + magnified_image_bounds.height + 4,
                //             bounds.width - 20,
                //             18,
                //         },
                //         rl.TextFormat("Cursor: %d, %d", mouse_x, mouse_y),
                //     )
                // }
            rl.EndDrawing()

            if capture_options.enabled {
                rendered_capture_frames += 1
                if rendered_capture_frames >= capture_options.warmup_frames {
                    if viewer_video_enabled {
                        video_texture := composite_render_target.texture
                        if capture_options.render_debug_video {
                            video_texture = render_debug_video_target.texture
                        }
                        frame_stream_error := shared.video_stream_encoder_write_render_texture(
                            &viewer_video_encoder,
                            video_texture,
                        )
                        if frame_stream_error != .NONE {
                            log.errorf(
                                "Failed to stream Viewer case %s at animation frame %.3f: %s",
                                capture_options.case_name,
                                animation_playback.current_frame,
                                shared.video_stream_write_error_message(frame_stream_error),
                            )
                            capture_complete = true
                            capture_succeeded = false
                        } else {
                            captured_sequence_frames += 1
                            expected_video_frames :=
                                viewer_video_expected_frame_count(
                                    capture_options,
                                )
                            if u64(captured_sequence_frames) >=
                               expected_video_frames {
                                capture_complete = true
                                finish_error := shared.video_stream_encoder_finish(
                                    &viewer_video_encoder,
                                    capture_options.video_output,
                                    expected_video_frames,
                                    "animation",
                                )
                                capture_succeeded = finish_error == .NONE
                                if finish_error != .NONE {
                                    log.errorf(
                                        "Failed to finish Viewer video %s: %s",
                                        capture_options.video_output,
                                        shared.video_stream_finish_error_message(finish_error),
                                    )
                                }
                                if capture_succeeded {
                                    log.infof(
                                        "Streamed Viewer source frames %.3f through %.3f exactly once across %d output frames",
                                        viewer_video_pose_frame(capture_options, 0),
                                        viewer_video_pose_frame(
                                            capture_options,
                                            expected_video_frames - 1,
                                        ),
                                        int(expected_video_frames),
                                    )
                                    if capture_options.render_debug_video {
                                        log.infof(
                                            "Streamed Viewer render-pass debugger across %d passes and %d output frames",
                                            len(VIEWER_RENDER_DEBUG_PASSES),
                                            int(expected_video_frames),
                                        )
                                    }
                                }
                            } else {
                                animation_playback.current_frame =
                                    viewer_video_pose_frame(
                                        capture_options,
                                        u64(captured_sequence_frames),
                                    )
                                animation_playback.pose_dirty = true
                            }
                        }
                    } else {
                        capture_output_path := capture_options.output_path
                        capture_output_path_owned := false
                        if capture_options.frame_range_set {
                            capture_output_path = shared.capture_sequence_output_path_format(
                                capture_options.output_path,
                                capture_options.output_template,
                                capture_sequence_frame,
                            )
                            capture_output_path_owned = true
                        }
                        // Export the selected render target inline at the only capture point.
                        lens_crop_bounds := lens_bounds
                        capture_error: shared.Capture_Export_Error
                        switch capture_options.target {
                        case .COMPOSITE:
                            capture_error = shared.capture_render_texture_export_png(
                                composite_render_target.texture,
                                capture_output_path,
                            )
                        case .LENS:
                            capture_error = shared.capture_render_texture_export_png(
                                composite_render_target.texture,
                                capture_output_path,
                                &lens_crop_bounds,
                            )
                        case .SCENE:
                            capture_error = shared.capture_render_texture_export_png(
                                scene_render_target.texture,
                                capture_output_path,
                            )
                        case .DOWNSAMPLE:
                            capture_error = shared.capture_render_texture_export_png(
                                outlined_render_target.texture,
                                capture_output_path,
                            )
                        case .COVERAGE_MASK:
                            capture_error = shared.capture_render_texture_export_png(
                                coverage_mask_render_target.texture,
                                capture_output_path,
                            )
                        }
                        capture_succeeded = capture_error == .NONE
                        if capture_succeeded {
                            if capture_options.frame_range_set {
                                captured_sequence_frames += 1
                                log.infof(
                                    "Captured case %s frame %d to %s",
                                    capture_options.case_name,
                                    capture_sequence_frame,
                                    capture_output_path,
                                )
                            } else {
                                log.infof(
                                    "Captured case %s to %s",
                                    capture_options.case_name,
                                    capture_output_path,
                                )
                            }
                        } else {
                            log.errorf(
                                "Failed to capture case %s to %s: %s",
                                capture_options.case_name,
                                capture_output_path,
                                shared.capture_export_error_message(capture_error),
                            )
                        }
                        if capture_output_path_owned {
                            delete(capture_output_path)
                        }

                        if !capture_succeeded || !capture_options.frame_range_set {
                            capture_complete = true
                        } else if capture_options.frame_range_step <=
                                  capture_options.frame_range_end &&
                                  capture_sequence_frame <=
                                  capture_options.frame_range_end -
                                  capture_options.frame_range_step {
                            capture_sequence_frame += capture_options.frame_range_step
                            animation_playback.current_frame = f32(capture_sequence_frame)
                            animation_playback.pose_dirty = true
                        } else {
                            capture_complete = true
                            log.infof(
                                "Captured sequence case %s with %d frame(s)",
                                capture_options.case_name,
                                captured_sequence_frames,
                            )
                        }
                    }
                }
            }

            if model_active_index != loaded_model_index &&
               model_active_index >= 0 &&
                int(model_active_index) < len(model_assets.paths) {
                requested_model_index := int(model_active_index)
                requested_model_label := model_assets.labels[requested_model_index]
                requested_model, requested_model_error := shared.model_source_load(
                    &model_assets,
                    requested_model_index,
                )
                if requested_model_error == .NONE {
                    requested_animation_load := shared.animation_playback_load(
                        requested_model,
                        model_assets.paths[requested_model_index],
                        model_assets.kinds[requested_model_index],
                    )
                    shared.animation_playback_destroy(&animation_playback)
                    if shared.model_is_loaded(active_model) {
                        rl.UnloadModel(active_model)
                    }
                    active_model = requested_model
                    animation_playback = requested_animation_load.playback
                    model_center = get_model_center(active_model)
                    loaded_model_index = model_active_index
                    shared.model_browser_active_source_set(
                        &model_browser,
                        loaded_model_index,
                    )
                    scene_size = frame_camera_to_model(
                        active_model,
                        &render_camera,
                    )
                    control_camera = render_camera
                    model_load_failed = false
                    log.infof("Loaded model: %s", requested_model_label)
                } else {
                    model_active_index = loaded_model_index
                    shared.model_browser_active_source_set(
                        &model_browser,
                        loaded_model_index,
                    )
                    model_load_failed = true
                    log.errorf(
                        "Failed to load model %s: %s",
                        requested_model_label,
                        shared.model_load_error_message(requested_model_error),
                    )
                }
            }
        }

        if capture_options.enabled && (!capture_complete || !capture_succeeded) {
            exit_code = 1
            break application_scope
        }
        exit_code = 0
        break application_scope
    }
    return exit_code
}
