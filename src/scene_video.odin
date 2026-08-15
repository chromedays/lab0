package main

// shared.Scene Editor video capture keeps the authored scene and fixed animation
// poses unchanged while moving only the serialized camera around its target.
// Frames stream directly from the composite RenderTexture through the shared
// FFmpeg encoder; PNGs remain the deterministic regression source of truth.

import "core:math"
import "core:strconv"
import shared "./shared"
import rl "vendor:raylib"

SCENE_VIDEO_WIDTH                 :: shared.SCENE_SCREEN_WIDTH
SCENE_VIDEO_HEIGHT                :: shared.SCENE_SCREEN_HEIGHT
SCENE_VIDEO_FRAMES_PER_SECOND     :: 60
SCENE_VIDEO_DEFAULT_DURATION      :: 5
SCENE_VIDEO_DEFAULT_FRAME_COUNT   :: u64(
    SCENE_VIDEO_FRAMES_PER_SECOND * SCENE_VIDEO_DEFAULT_DURATION,
)
SCENE_VIDEO_MAX_DURATION_SECONDS  :: 600

Scene_Video_Options_Error :: enum {
    NONE,
    DURATION_WITHOUT_OUTPUT,
    INVALID_OUTPUT,
    MISSING_SCENE,
    MISSING_CAPTURE,
    INVALID_TARGET,
    CONFLICTING_CAPTURE_OUTPUT,
}

scene_video_duration_frame_count :: proc(value: string) -> (
    frame_count: u64,
    valid: bool,
) {
    duration_seconds, parsed := strconv.parse_f64(value)
    if !parsed || math.is_nan(duration_seconds) ||
       math.is_inf(duration_seconds) || duration_seconds <= 0 ||
       duration_seconds > SCENE_VIDEO_MAX_DURATION_SECONDS {
        return 0, false
    }
    frame_value := duration_seconds * f64(SCENE_VIDEO_FRAMES_PER_SECOND)
    rounded_frames := math.round(frame_value)
    if rounded_frames < 1 ||
       math.abs(frame_value - rounded_frames) > 0.000001 {
        return 0, false
    }
    return u64(rounded_frames), true
}

validate_scene_video_options :: proc(
    run_options: ^Scene_Run_Options,
    capture: ^shared.Capture_Options,
) -> Scene_Video_Options_Error {
    if len(run_options.video_output) == 0 {
        if run_options.video_duration_set {
            return .DURATION_WITHOUT_OUTPUT
        }
        return .NONE
    }
    if !shared.video_stream_output_path_is_valid(run_options.video_output) {
        return .INVALID_OUTPUT
    }
    if !run_options.scene_path_set {
        return .MISSING_SCENE
    }
    if !capture.enabled {
        return .MISSING_CAPTURE
    }
    if capture.target != .COMPOSITE {
        return .INVALID_TARGET
    }
    if capture.output_path_explicit {
        return .CONFLICTING_CAPTURE_OUTPUT
    }
    return .NONE
}

scene_video_options_error_message :: proc(
    error: Scene_Video_Options_Error,
) -> string {
    switch error {
    case .NONE:
        return "no error"
    case .DURATION_WITHOUT_OUTPUT:
        return "--scene-video-duration requires --scene-video-output"
    case .INVALID_OUTPUT:
        return "--scene-video-output requires a non-empty .mp4 path"
    case .MISSING_SCENE:
        return "--scene-video-output requires --scene"
    case .MISSING_CAPTURE:
        return "--scene-video-output requires --capture-case"
    case .INVALID_TARGET:
        return "--scene-video-output supports only --capture-target composite"
    case .CONFLICTING_CAPTURE_OUTPUT:
        return "--scene-video-output cannot be combined with --capture-output"
    }
    return "unknown shared.Scene Editor video option error"
}

// The last output frame stops one frame interval before 360 degrees, avoiding
// a duplicate of frame zero while still covering one complete orbit at 60 Hz.
scene_video_orbit_degrees :: proc(
    output_frame_index, frame_count: u64,
) -> f32 {
    if frame_count == 0 { return 0 }
    clamped_index := min(output_frame_index, frame_count - 1)
    return 360 * f32(clamped_index) / f32(frame_count)
}

scene_video_orbit_camera :: proc(
    authored_camera: shared.Scene_Camera,
    output_frame_index, frame_count: u64,
) -> shared.Scene_Camera {
    result := authored_camera
    if frame_count == 0 { return result }
    axis := shared.scene_direction_normalize_stable(authored_camera.up)
    offset := authored_camera.position - authored_camera.target
    angle_radians := scene_video_orbit_degrees(
        output_frame_index,
        frame_count,
    ) * f32(math.PI / 180)
    result.position = authored_camera.target +
                      rl.Vector3RotateByAxisAngle(offset, axis, angle_radians)
    return result
}
