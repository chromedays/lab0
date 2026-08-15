package shared

// This module owns the non-interactive capture command-line contract. It keeps
// parsing and PNG export deterministic so visual regression jobs exercise the
// same GPU pipeline as the interactive viewer without depending on user input.

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Capture_Target selects which internal RenderTexture is read back. Each target
// has a stable resolution documented in AGENTS.md and is suitable for a
// different layer of visual regression testing.
Capture_Target :: enum {
    COMPOSITE,
    LENS,
    SCENE,
    DOWNSAMPLE,
    COVERAGE_MASK,
}

// Capture_View names the reproducible camera presets available to capture jobs.
// DEFAULT preserves normal framing; the other values overwrite the camera pose.
Capture_View :: enum {
    DEFAULT,
    X,
    Y,
    Z,
    ISOMETRIC,
}

// Capture_Parse_Error is intentionally specific enough for CLI callers to
// distinguish malformed syntax from incompatible combinations of valid flags.
Capture_Parse_Error :: enum {
    NONE,
    MISSING_VALUE,
    UNKNOWN_ARGUMENT,
    MISSING_CASE,
    INVALID_CASE,
    INVALID_MODEL,
    INVALID_STYLE,
    INVALID_MODE,
    INVALID_EDGE_AA,
    INVALID_VIEW,
    INVALID_TARGET,
    INVALID_FRAME,
    INVALID_FRAME_RANGE,
    CONFLICTING_FRAME_OPTIONS,
    INVALID_WARMUP,
    INVALID_OUTPUT,
    INVALID_VIDEO_OUTPUT,
    INVALID_VIDEO_DURATION,
    INVALID_OUTPUT_TEMPLATE,
}

// Capture_Output_Template stores byte offsets into the original output path.
// token_end is exclusive and width is zero for an unpadded %d token.
Capture_Output_Template :: struct {
    token_start: int,
    token_end:   int,
    width:       int,
}

// Capture_Options is the fully validated render request consumed by main.
// output_path_owned records whether parsing allocated the path and therefore
// whether capture_options_destroy must release it.
Capture_Options :: struct {
    enabled:             bool,
    help_requested:      bool,
    case_name:           string,
    output_path:         string,
    output_path_owned:   bool,
    output_path_explicit: bool,
    model_source:        string,
    style_path:          string,
    video_output:        string,
    video_frame_count:   u64,
    lens_mode:           Lens_Mode,
    edge_aa_mode:        Edge_AA_Mode,
    view:                Capture_View,
    target:              Capture_Target,
    animation_frame:     f32,
    animation_frame_set: bool,
    frame_range_set:     bool,
    frame_range_start:   int,
    frame_range_end:     int,
    frame_range_step:    int,
    output_template:     Capture_Output_Template,
    warmup_frames:       int,
    hide_window:         bool,
}

// Capture_Parse_Result returns partial options alongside the first parse error,
// allowing the CLI to report the offending value without throwing away context.
Capture_Parse_Result :: struct {
    options:        Capture_Options,
    error:          Capture_Parse_Error,
    error_argument: string,
}

// capture_options_destroy releases parser-owned strings and clears the struct.
// Clearing prevents stale ownership flags from causing a later double free.
capture_options_destroy :: proc(options: ^Capture_Options) {
    if options.output_path_owned && len(options.output_path) > 0 {
        delete(options.output_path)
    }
    options^ = {}
}

// capture_sequence_output_path_format substitutes one validated frame token.
// The returned string is allocator-owned and must be deleted by the caller.
capture_sequence_output_path_format :: proc(
    output_path: string,
    output_template: Capture_Output_Template,
    animation_frame: int,
) -> string {
    prefix := output_path[:output_template.token_start]
    suffix := output_path[output_template.token_end:]
    if output_template.width > 0 {
        return fmt.aprintf(
            "%s%0*d%s",
            prefix,
            output_template.width,
            animation_frame,
            suffix,
        )
    }
    return fmt.aprintf("%s%d%s", prefix, animation_frame, suffix)
}

// capture_options_parse scans capture-specific CLI flags while ignoring normal
// application arguments. It applies defaults, validates cross-flag invariants,
// and allocates a deterministic default output path when none is supplied.
capture_options_parse :: proc(arguments: []string) -> Capture_Parse_Result {
    result: Capture_Parse_Result
    result.options.lens_mode = .PIXELATED
    result.options.view = .DEFAULT
    result.options.target = .COMPOSITE
    result.options.warmup_frames = 2
    result.options.hide_window = true

    capture_argument_seen := false
    argument_index := 0
    for argument_index < len(arguments) {
        argument := arguments[argument_index]
        argument_index += 1

        if argument == "--capture-help" {
            capture_argument_seen = true
            result.options.help_requested = true
            continue
        }
        if !strings.has_prefix(argument, "--capture-") &&
           argument != "--viewer-video-output" &&
           argument != "--viewer-video-duration" {
            continue
        }

        capture_argument_seen = true
        if argument == "--capture-show-window" {
            result.options.hide_window = false
            continue
        }

        if argument_index >= len(arguments) {
            result.error = .MISSING_VALUE
            result.error_argument = argument
            return result
        }
        value := arguments[argument_index]
        argument_index += 1

        switch argument {
        case "--capture-case":
            // Validate the case name here because this is its only consumer.
            case_name_valid := len(value) > 0
            if case_name_valid {
                for case_character in value {
                    if (case_character >= 'a' && case_character <= 'z') ||
                       (case_character >= 'A' && case_character <= 'Z') ||
                       (case_character >= '0' && case_character <= '9') ||
                       case_character == '-' || case_character == '_' {
                        continue
                    }
                    case_name_valid = false
                    break
                }
            }
            if !case_name_valid {
                result.error = .INVALID_CASE
                result.error_argument = value
                return result
            }
            result.options.case_name = value

        case "--capture-output":
            if len(value) == 0 || !strings.equal_fold(os.ext(value), ".png") {
                result.error = .INVALID_OUTPUT
                result.error_argument = value
                return result
            }
            result.options.output_path = value
            result.options.output_path_explicit = true

        case "--capture-model":
            if len(value) == 0 {
                result.error = .INVALID_MODEL
                result.error_argument = value
                return result
            }
            result.options.model_source = value

        case "--capture-style":
            if len(value) == 0 || !strings.equal_fold(os.ext(value), ".json") {
                result.error = .INVALID_STYLE
                result.error_argument = value
                return result
            }
            result.options.style_path = value

        case "--viewer-video-output":
            if !video_stream_output_path_is_valid(value) {
                result.error = .INVALID_VIDEO_OUTPUT
                result.error_argument = value
                return result
            }
            result.options.video_output = value

        case "--viewer-video-duration":
            duration_seconds, duration_valid := strconv.parse_f64(value)
            duration_frames := duration_seconds *
                               f64(VIEWER_VIDEO_FRAMES_PER_SECOND)
            rounded_duration_frames := math.round(duration_frames)
            if !duration_valid || math.is_nan(duration_seconds) ||
               math.is_inf(duration_seconds) || duration_seconds <= 0 ||
               duration_seconds > 600 || rounded_duration_frames < 1 ||
               math.abs(duration_frames - rounded_duration_frames) > 0.000001 {
                result.error = .INVALID_VIDEO_DURATION
                result.error_argument = value
                return result
            }
            result.options.video_frame_count = u64(rounded_duration_frames)

        case "--capture-mode":
            if value == "pixelated" {
                result.options.lens_mode = .PIXELATED
            } else if value == "blended" {
                result.options.lens_mode = .BLENDED
            } else if value == "coverage-mask" {
                result.options.lens_mode = .COVERAGE_MASK
            } else {
                result.error = .INVALID_MODE
                result.error_argument = value
                return result
            }

        case "--capture-edge-aa":
            if value == "hard" {
                result.options.edge_aa_mode = .HARD
            } else if value == "coverage" {
                result.options.edge_aa_mode = .COVERAGE
            } else {
                result.error = .INVALID_EDGE_AA
                result.error_argument = value
                return result
            }

        case "--capture-view":
            if value == "default" {
                result.options.view = .DEFAULT
            } else if value == "x" {
                result.options.view = .X
            } else if value == "y" {
                result.options.view = .Y
            } else if value == "z" {
                result.options.view = .Z
            } else if value == "isometric" {
                result.options.view = .ISOMETRIC
            } else {
                result.error = .INVALID_VIEW
                result.error_argument = value
                return result
            }

        case "--capture-target":
            if value == "composite" {
                result.options.target = .COMPOSITE
            } else if value == "lens" {
                result.options.target = .LENS
            } else if value == "scene" {
                result.options.target = .SCENE
            } else if value == "downsample" {
                result.options.target = .DOWNSAMPLE
            } else if value == "coverage-mask" {
                result.options.target = .COVERAGE_MASK
            } else {
                result.error = .INVALID_TARGET
                result.error_argument = value
                return result
            }

        case "--capture-frame":
            parsed_frame, parsed_frame_succeeded := strconv.parse_f32(value)
            if !parsed_frame_succeeded ||
               math.is_nan(parsed_frame) ||
               math.is_inf(parsed_frame) ||
               parsed_frame < 0 {
                result.error = .INVALID_FRAME
                result.error_argument = value
                return result
            }
            result.options.animation_frame = parsed_frame
            result.options.animation_frame_set = true

        case "--capture-frame-range":
            // Parse and bound the frame range inline at its sole call site.
            range_start, range_end, range_step := 0, 0, 1
            range_valid := false
            parts := strings.split(value, ":", context.temp_allocator)
            if len(parts) == 2 || len(parts) == 3 {
                start_valid, end_valid: bool
                range_start, start_valid = strconv.parse_int(parts[0])
                range_end, end_valid = strconv.parse_int(parts[1])
                step_valid := true
                if len(parts) == 3 {
                    range_step, step_valid = strconv.parse_int(parts[2])
                }
                range_valid = start_valid && end_valid && step_valid &&
                              range_start >= 0 && range_end >= range_start &&
                              range_step > 0
                if range_valid {
                    frame_intervals := (range_end - range_start) / range_step
                    range_valid = frame_intervals < 10000
                }
            }
            if !range_valid {
                result.error = .INVALID_FRAME_RANGE
                result.error_argument = value
                return result
            }
            result.options.frame_range_set = true
            result.options.frame_range_start = range_start
            result.options.frame_range_end = range_end
            result.options.frame_range_step = range_step

        case "--capture-warmup":
            parsed_warmup, parsed_warmup_succeeded := strconv.parse_int(value)
            if !parsed_warmup_succeeded || parsed_warmup < 1 || parsed_warmup > 600 {
                result.error = .INVALID_WARMUP
                result.error_argument = value
                return result
            }
            result.options.warmup_frames = parsed_warmup

        case:
            result.error = .UNKNOWN_ARGUMENT
            result.error_argument = argument
            return result
        }
    }

    if result.options.help_requested {
        return result
    }
    if capture_argument_seen && len(result.options.case_name) == 0 {
        result.error = .MISSING_CASE
        return result
    }
    if len(result.options.case_name) == 0 {
        return result
    }
    if result.options.animation_frame_set && result.options.frame_range_set {
        result.error = .CONFLICTING_FRAME_OPTIONS
        return result
    }

    result.options.enabled = true
    if len(result.options.output_path) == 0 &&
       len(result.options.video_output) == 0 {
        if result.options.frame_range_set {
            result.options.output_path = fmt.aprintf(
                "captures/%s-%%04d.png",
                result.options.case_name,
            )
        } else {
            result.options.output_path = fmt.aprintf(
                "captures/%s.png",
                result.options.case_name,
            )
        }
        result.options.output_path_owned = true
    }
    if result.options.frame_range_set && len(result.options.video_output) == 0 {
        // Locate and validate the one frame token where the template is used.
        output_template: Capture_Output_Template
        template_valid := true
        token_found := false
        path_index := 0
        output_path := result.options.output_path
        for path_index < len(output_path) {
            if output_path[path_index] != '%' {
                path_index += 1
                continue
            }
            if token_found || path_index + 1 >= len(output_path) {
                template_valid = false
                break
            }

            token_start := path_index
            path_index += 1
            token_width := 0
            if output_path[path_index] == 'd' {
                path_index += 1
            } else if output_path[path_index] == '0' {
                width_start := path_index + 1
                path_index = width_start
                for path_index < len(output_path) &&
                    output_path[path_index] >= '0' &&
                    output_path[path_index] <= '9' {
                    path_index += 1
                }
                if path_index == width_start ||
                   path_index >= len(output_path) ||
                   output_path[path_index] != 'd' {
                    template_valid = false
                    break
                }
                parsed_width, width_valid := strconv.parse_int(
                    output_path[width_start:path_index],
                )
                if !width_valid || parsed_width < 1 || parsed_width > 12 {
                    template_valid = false
                    break
                }
                token_width = parsed_width
                path_index += 1
            } else {
                template_valid = false
                break
            }

            output_template = {
                token_start = token_start,
                token_end   = path_index,
                width       = token_width,
            }
            token_found = true
        }
        template_valid = template_valid && token_found
        if !template_valid {
            result.error = .INVALID_OUTPUT_TEMPLATE
            result.error_argument = result.options.output_path
            result.options.enabled = false
            return result
        }
        result.options.output_template = output_template
    }
    return result
}

// cli_argument_is_present supports early, allocation-free checks for flags that
// must take effect before a mode parser or raylib initialization.
cli_argument_is_present :: proc(arguments: []string, requested: string) -> bool {
    for argument in arguments {
        if argument == requested { return true }
    }
    return false
}

// cli_help_is_requested recognizes the conventional process-wide aliases.
cli_help_is_requested :: proc(arguments: []string) -> bool {
    return cli_argument_is_present(arguments, "--help") ||
           cli_argument_is_present(arguments, "-h")
}

// cli_viewer_usage_print is the top-level help shown for the default Viewer mode.
// It advertises the alternate modes before appending the complete capture CLI.
cli_viewer_usage_print :: proc() {
    fmt.println("Lab0 model viewer")
    fmt.println("")
    fmt.println("Usage:")
    fmt.println("  lab0                              Open the interactive Viewer")
    fmt.println("  lab0 [capture options]            Run a deterministic Viewer capture")
    fmt.println("  lab0 --mode scene-editor [options]")
    fmt.println("  lab0 --mode game [options]")
    fmt.println("")
    fmt.println("Global options:")
    fmt.println("  -h, --help                        Print help for the selected mode")
    fmt.println("  --mode <viewer|scene-editor|game> Select the application mode")
    fmt.println("  --scene-help                      Print Scene Editor help")
    fmt.println("  --game-help                       Print traversal prototype help")
    fmt.println("")
    cli_capture_usage_print()
}

// cli_capture_usage_print writes the capture-only help text without initializing
// raylib, which keeps --capture-help usable in non-graphical environments.
cli_capture_usage_print :: proc() {
    fmt.println("Non-interactive capture mode")
    fmt.println("")
    fmt.println("  --capture-case <name>          Enable capture mode and name the case")
    fmt.println("  --capture-output <path.png>    Output path or sequence template")
    fmt.println("  --capture-model <source>       Exact asset path or builtin:cube|sphere|triangle")
    fmt.println("  --capture-style <path.json>    Cel style preset (default: built-in Classic)")
    fmt.println("  --viewer-video-output <mp4>    Stream a Viewer frame range through FFmpeg")
    fmt.println("  --viewer-video-duration <sec>  Retime the range once to an exact duration")
    fmt.println("  --capture-view <view>          default|x|y|z|isometric")
    fmt.println("  --capture-mode <mode>          pixelated|blended|coverage-mask")
    fmt.println("  --capture-edge-aa <mode>       hard|coverage (default: hard)")
    fmt.println("  --capture-target <target>      composite|lens|scene|downsample|coverage-mask")
    fmt.println("  --capture-frame <frame>        Fixed animation frame (default: 0)")
    fmt.println("  --capture-frame-range <range>  Inclusive start:end[:step] pose sequence")
    fmt.println("  --capture-warmup <frames>      Frames rendered before export (default: 2)")
    fmt.println("  --capture-show-window          Show the otherwise hidden capture window")
    fmt.println("  --capture-help                 Print this help without opening a window")
}

// capture_find_model_source resolves built-ins, repository-relative assets, and
// absolute paths to the canonical source index used by the model browser.
capture_find_model_source :: proc(
    model_assets: ^Model_Assets,
    requested_source: string,
) -> (source_index: int, source_found: bool) {
    requested_absolute_path := requested_source
    if !strings.has_prefix(requested_source, "builtin:") {
        if absolute_path, absolute_path_error := filepath.abs(
            requested_source,
            context.temp_allocator,
        ); absolute_path_error == nil {
            requested_absolute_path = absolute_path
        }
    }
    for model_path, model_index in model_assets.paths {
        if model_path == requested_source ||
           model_path == requested_absolute_path {
            return model_index, true
        }
    }
    return -1, false
}

// capture_output_directory_ensure creates all parent directories for a PNG.
// Existing directories are accepted to support concurrent capture workers.
capture_output_directory_ensure :: proc(output_path: string) -> bool {
    output_directory := filepath.dir(output_path)
    if output_directory == "" || output_directory == "." {
        return true
    }
    if directory_error := os.make_directory_all(output_directory);
       directory_error != nil {
        // Odin's make_directory_all reports .Exist when the final directory
        // already exists on some platforms. Another capture worker may also
        // create it between our call and this check, so accept either case.
        if os.is_directory(output_directory) {
            return true
        }
        log.errorf(
            "Failed to create capture output directory %s: %v",
            output_directory,
            directory_error,
        )
        return false
    }
    return true
}

// capture_render_texture_export_png reads an RGBA texture from the GPU, fixes the
// RenderTexture Y orientation, optionally crops it, and writes a PNG. The
// temporary raylib Image is always unloaded before the procedure returns.
capture_render_texture_export_png :: proc(
    texture: rl.Texture2D,
    output_path: string,
    crop_bounds: ^rl.Rectangle = nil,
) -> bool {
    if !capture_output_directory_ensure(output_path) {
        return false
    }

    texture_readback := rl.LoadImageFromTexture(texture)
    if texture_readback.data == nil {
        log.error("Failed to read capture texture from the GPU")
        return false
    }
    defer rl.UnloadImage(texture_readback)

    // All capture sources are RenderTexture attachments, whose readback is
    // vertically inverted relative to the logical viewport.
    rl.ImageFlipVertical(&texture_readback)
    if crop_bounds != nil {
        rl.ImageCrop(&texture_readback, crop_bounds^)
    }
    rl.ImageFormat(&texture_readback, .UNCOMPRESSED_R8G8B8A8)

    output_path_cstr := strings.clone_to_cstring(
        output_path,
        context.temp_allocator,
    )
    return rl.ExportImage(texture_readback, output_path_cstr)
}
