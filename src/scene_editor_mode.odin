package main

// Top-level lifecycle and CLI contract for shared.Scene Editor. The mode loads its
// complete CPU state before opening a window, then owns separate GPU resources
// and deterministic capture behavior.

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import shared "./shared"
import rl "vendor:raylib"
import rgl "vendor:raylib/rlgl"

// shared.Scene-specific CLI state is parsed separately from shared shared.Capture_Options.
// Paths borrow argument storage; no field in this value requires destruction.
Scene_Run_Options :: struct {
    scene_path:         string,
    scene_path_set:     bool,
    help_requested:     bool,
    video_output:       string,
    video_frame_count:  u64,
    video_duration_set: bool,
}

scene_editor_mode_requested :: proc(arguments: []string) -> bool {
    for argument, index in arguments {
        if argument == "--mode" && index + 1 < len(arguments) {
            return arguments[index + 1] == "scene-editor"
        }
    }
    return false
}

// Consume only shared.Scene mode flags and reject other mode namespaces eagerly. The
// shared capture parser independently validates --capture-* syntax.
parse_scene_run_options :: proc(arguments: []string) -> (
    options: Scene_Run_Options,
    valid: bool,
    error_argument: string,
) {
    options.video_frame_count = SCENE_VIDEO_DEFAULT_FRAME_COUNT
    valid = true
    index := 0
    for index < len(arguments) {
        argument := arguments[index]
        index += 1
        if argument == "--scene-help" {
            options.help_requested = true
            continue
        }
        if argument == "--scene" {
            if index >= len(arguments) {
                return options, false, argument
            }
            options.scene_path = arguments[index]
            options.scene_path_set = true
            index += 1
            if len(options.scene_path) == 0 ||
               !strings.equal_fold(os.ext(options.scene_path), ".json") {
                return options, false, argument
            }
            continue
        }
        if argument == "--scene-video-output" {
            if index >= len(arguments) {
                return options, false, argument
            }
            options.video_output = arguments[index]
            index += 1
            if len(options.video_output) == 0 {
                return options, false, argument
            }
            continue
        }
        if argument == "--scene-video-duration" {
            if index >= len(arguments) {
                return options, false, argument
            }
            duration_value := arguments[index]
            index += 1
            frame_count, duration_valid :=
                scene_video_duration_frame_count(duration_value)
            if !duration_valid {
                return options, false, duration_value
            }
            options.video_frame_count = frame_count
            options.video_duration_set = true
            continue
        }
        if argument == "--mode" {
            if index >= len(arguments) || arguments[index] != "scene-editor" {
                return options, false, argument
            }
            index += 1
            continue
        }
        if strings.has_prefix(argument, "--scene-") ||
           strings.has_prefix(argument, "--game-") {
            return options, false, argument
        }
    }
    return
}

print_scene_editor_usage :: proc() {
    fmt.println("Lab0 shared.Scene Editor")
    fmt.println("")
    fmt.println("Usage:")
    fmt.println("  lab0 --mode scene-editor [options]")
    fmt.println("")
    fmt.println("Options:")
    fmt.println("  -h, --help                  Print help for shared.Scene Editor")
    fmt.println("  --mode scene-editor          Run the visual-test scene editor")
    fmt.println("  --scene <path.json>          Open a strict-JSON scene file")
    fmt.println("  --scene-video-output <mp4>  Stream one camera orbit through FFmpeg")
    fmt.println("  --scene-video-duration <s>  Orbit duration at 60 fps (default: 5)")
    fmt.println("  --scene-help                 Print shared.Scene Editor help")
    fmt.println("")
    fmt.println("Capture options:")
    fmt.println("  --capture-case <name>        Enable deterministic scene capture")
    fmt.println("  --capture-output <path.png>  Select the PNG output path")
    fmt.println("  --capture-target <target>    composite|scene|downsample|coverage-mask")
    fmt.println("  --capture-warmup <frames>    Frames rendered before export (default: 2)")
    fmt.println("  --capture-show-window        Show the otherwise hidden capture window")
    fmt.println("  --capture-help               Print the complete Viewer capture reference")
}

// A serialized scene owns camera, model, style, and low-resolution settings.
// Reject Viewer/Game overrides so a capture has one authoritative render state.
validate_scene_capture_options :: proc(
    arguments: []string,
    run_options: ^Scene_Run_Options,
    capture: ^shared.Capture_Options,
) -> bool {
    if !capture.enabled { return true }
    if !run_options.scene_path_set {
        return false
    }
    if capture.target == .LENS ||
       capture.frame_range_set ||
       capture.animation_frame_set ||
       capture.view != .DEFAULT ||
       capture.lens_mode != .PIXELATED ||
       len(capture.model_source) > 0 ||
       len(capture.style_path) > 0 ||
       len(capture.video_output) > 0 ||
       capture.video_frame_count > 0 ||
        shared.cli_argument_is_present(arguments, "--capture-edge-aa") {
        return false
    }
    return true
}

// Establish all CPU-owned scene/style state before opening the native window;
// then create GPU resources in dependency order. Defers unwind the reverse
// ownership order on every validation, capture, and interactive exit path.
run_scene_editor_mode :: proc(arguments: []string) -> int {
    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    if shared.cli_help_is_requested(arguments) ||
       shared.cli_argument_is_present(arguments, "--scene-help") {
        print_scene_editor_usage()
        return 0
    }

    run_options, run_options_valid, bad_scene_argument :=
        parse_scene_run_options(arguments)
    if !run_options_valid {
        log.errorf("Invalid shared.Scene Editor argument: %s", bad_scene_argument)
        print_scene_editor_usage()
        return 2
    }

    capture_result := shared.capture_options_parse(arguments)
    defer shared.capture_options_destroy(&capture_result.options)
    if run_options.help_requested || capture_result.options.help_requested {
        print_scene_editor_usage()
        if capture_result.options.help_requested {
            fmt.println("")
            shared.cli_capture_usage_print()
        }
        return 0
    }
    if capture_result.error != .NONE {
        log.errorf("Invalid shared.Scene Editor capture argument: %s", capture_result.error_argument)
        print_scene_editor_usage()
        return 2
    }
    capture := &capture_result.options
    if !validate_scene_capture_options(arguments, &run_options, capture) {
        log.error("shared.Scene Editor capture requires --scene and accepts only scene-owned render state plus composite, scene, downsample, or coverage-mask targets")
        return 2
    }
    video_options_error := validate_scene_video_options(&run_options, capture)
    if video_options_error != .NONE {
        log.error(scene_video_options_error_message(video_options_error))
        return 2
    }
    video_enabled := len(run_options.video_output) > 0

    scene: shared.Scene
    scene_error: shared.Scene_Error
    if run_options.scene_path_set {
        scene, scene_error = shared.scene_load(run_options.scene_path)
    } else {
        scene = shared.scene_make_default()
    }
    defer shared.scene_destroy(&scene)
    if scene_error != .NONE {
        log.errorf(
            "Failed to load scene %s: %s",
            run_options.scene_path,
            shared.scene_error_message(scene_error),
        )
        return 2
    }

    style, style_error := shared.cel_style_load(scene.style_path)
    defer shared.cel_style_destroy(&style)
    if style_error != .NONE {
        log.errorf(
            "Failed to load scene cel style %s: %s",
            scene.style_path,
            shared.cel_style_error_message(style_error),
        )
        return 2
    }

    if capture.enabled {
        if capture.hide_window {
            rl.SetConfigFlags({.WINDOW_ALWAYS_RUN, .WINDOW_HIDDEN})
        } else {
            rl.SetConfigFlags({.WINDOW_ALWAYS_RUN})
        }
    } else {
        rl.SetConfigFlags({.WINDOW_TOPMOST})
    }
    rl.InitWindow(shared.SCENE_SCREEN_WIDTH, shared.SCENE_SCREEN_HEIGHT, "Lab0 - shared.Scene Editor")
    defer rl.CloseWindow()
    rl.SetExitKey(.KEY_NULL)
    if capture.enabled {
        rl.SetMouseOffset(-100000, -100000)
    }
    rgl.SetClipPlanes(0.001, 100000.0)
    rl.SetTargetFPS(60)

    renderer: shared.Scene_Renderer
    if !shared.scene_renderer_init(&renderer, &style, scene.render.downscale_level) {
        shared.scene_renderer_destroy(&renderer)
        return 1
    }
    defer shared.scene_renderer_destroy(&renderer)

    resources, resource_error := shared.scene_resources_load(&scene)
    defer shared.scene_resources_destroy(&resources)
    if resource_error != .NONE {
        log.errorf("Failed to load scene resources: %s", shared.scene_error_message(resource_error))
        return 2
    }

    editor_ui: Scene_Editor_UI_State
    scene_editor_ui_init(&editor_ui, run_options.scene_path)

    if capture.enabled {
        if video_enabled {
            video_encoder: shared.Video_Stream_Encoder
            defer shared.video_stream_encoder_destroy(&video_encoder)
            video_start_error := shared.video_stream_encoder_start(
                &video_encoder,
                run_options.video_output,
                SCENE_VIDEO_WIDTH,
                SCENE_VIDEO_HEIGHT,
                SCENE_VIDEO_FRAMES_PER_SECOND,
            )
            if video_start_error == .FFMPEG_NOT_FOUND { return 2 }
            if video_start_error != .NONE { return 1 }

            // Warmup renders the authored pose but is not part of the stream.
            // Every output camera is then derived from this immutable snapshot,
            // avoiding incremental orbit drift across hundreds of frames.
            authored_camera := scene.camera
            for _ in 0 ..< capture.warmup_frames {
                if !shared.scene_renderer_render(&renderer, &resources, &scene, &style) {
                    return 1
                }
            }
            for frame_index: u64 = 0;
                frame_index < run_options.video_frame_count;
                frame_index += 1 {
                scene.camera = scene_video_orbit_camera(
                    authored_camera,
                    frame_index,
                    run_options.video_frame_count,
                )
                if !shared.scene_renderer_render(&renderer, &resources, &scene, &style) {
                    return 1
                }
                if !shared.video_stream_encoder_write_render_texture(
                    &video_encoder,
                    renderer.composite_target.texture,
                ) {
                    log.errorf(
                        "Failed to stream shared.Scene Editor case %s at orbit frame %d",
                        capture.case_name,
                        int(frame_index),
                    )
                    return 1
                }
            }
            if !shared.video_stream_encoder_finish(
                &video_encoder,
                run_options.video_output,
                run_options.video_frame_count,
                "scene-orbit",
            ) {
                return 1
            }
            log.infof(
                "Streamed shared.Scene camera orbit %.3f through %.3f degrees exactly once across %d output frames",
                scene_video_orbit_degrees(0, run_options.video_frame_count),
                scene_video_orbit_degrees(
                    run_options.video_frame_count - 1,
                    run_options.video_frame_count,
                ),
                int(run_options.video_frame_count),
            )
            return 0
        }
        for frame_index := 0; frame_index <= capture.warmup_frames; frame_index += 1 {
            if !shared.scene_renderer_render(&renderer, &resources, &scene, &style) {
                return 1
            }
        }
        texture := shared.scene_renderer_capture_texture(&renderer, capture.target)
        if !rl.IsTextureValid(texture) {
            return 1
        }
        if !shared.capture_render_texture_export_png(texture, capture.output_path) {
            log.errorf(
                "Failed to capture shared.Scene Editor case %s to %s",
                capture.case_name,
                capture.output_path,
            )
            return 1
        }
        log.infof(
            "Captured shared.Scene Editor case %s to %s",
            capture.case_name,
            capture.output_path,
        )
        return 0
    }

    // Resolve deferred New/Open requests before input and rendering so a frame
    // never mixes UI state from one scene with resources from another.
    for !rl.WindowShouldClose() && !editor_ui.exit_requested {
        if editor_ui.new_requested {
            editor_ui.new_requested = false
            if scene_editor_new_default(
                &scene,
                &style,
                &renderer,
                &resources,
            ) {
                editor_ui.selection = {.NONE, -1}
                editor_ui.item_name_target = {.NONE, -1}
                scene_ui_buffer_set(editor_ui.scene_path[:], "scenes/untitled.json")
                editor_ui.status = .NEW_SCENE
            } else {
                editor_ui.status = .LOAD_FAILED
            }
        }
        if editor_ui.load_requested {
            editor_ui.load_requested = false
            if scene_editor_open_path(
                scene_ui_buffer_string(editor_ui.scene_path[:]),
                &scene,
                &style,
                &renderer,
                &resources,
            ) {
                editor_ui.selection = {.NONE, -1}
                editor_ui.item_name_target = {.NONE, -1}
                editor_ui.status = .LOADED
            } else {
                editor_ui.status = .LOAD_FAILED
            }
        }
        modal_active := editor_ui.pending_action != .NONE || editor_ui.save_as_open
        if !modal_active {
            scene_editor_update_viewport_input(&editor_ui, &scene, &resources)
            if rl.IsKeyPressed(.DELETE) {
                if scene_selection_valid(editor_ui.selection, &scene) {
                    editor_ui.pending_action = .DELETE
                }
            }
            if game_quit_requested() {
                if scene.dirty {
                    editor_ui.pending_action = .EXIT
                } else {
                    editor_ui.exit_requested = true
                }
            }
        }
        primary_down := rl.IsKeyDown(.LEFT_CONTROL) ||
                        rl.IsKeyDown(.RIGHT_CONTROL) ||
                        rl.IsKeyDown(.LEFT_SUPER) ||
                        rl.IsKeyDown(.RIGHT_SUPER)
        if !modal_active && primary_down && rl.IsKeyPressed(.S) {
            shift_down := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
            if shift_down {
                scene_editor_request_save_as(&editor_ui)
            } else {
                save_error := shared.scene_save(
                    scene_ui_buffer_string(editor_ui.scene_path[:]),
                    &scene,
                )
                if save_error == .NONE {
                    scene.dirty = false
                    editor_ui.status = .SAVED
                } else {
                    editor_ui.status = .SAVE_FAILED
                }
            }
        }
        if !shared.scene_renderer_render(&renderer, &resources, &scene, &style) {
            return 1
        }
        rl.BeginDrawing()
            scene_editor_draw_ui(
                &editor_ui,
                &scene,
                &style,
                &renderer,
                &resources,
            )
        rl.EndDrawing()
    }
    return 0
}
