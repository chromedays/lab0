package main

import shared "./shared"

// Viewer video capture streams deterministic animation poses through the same
// composite RenderTexture used by still captures. The frame range remains the
// authoritative sequence contract; no intermediate PNG sequence is produced.

VIEWER_VIDEO_WIDTH             :: 1280
VIEWER_VIDEO_HEIGHT            :: 720
VIEWER_VIDEO_FRAMES_PER_SECOND :: 60

Viewer_Video_Options_Error :: enum {
    NONE,
    DURATION_WITHOUT_OUTPUT,
    DEBUG_WITHOUT_OUTPUT,
    INVALID_OUTPUT,
    MISSING_FRAME_RANGE,
    INVALID_TARGET,
    CONFLICTING_CAPTURE_OUTPUT,
}

validate_viewer_video_options :: proc(
    capture: ^shared.Capture_Options,
) -> Viewer_Video_Options_Error {
    if len(capture.video_output) == 0 {
        if capture.video_frame_count > 0 {
            return .DURATION_WITHOUT_OUTPUT
        }
        if capture.render_debug_video {
            return .DEBUG_WITHOUT_OUTPUT
        }
        return .NONE
    }
    if !shared.video_stream_output_path_is_valid(capture.video_output) {
        return .INVALID_OUTPUT
    }
    if !capture.frame_range_set {
        return .MISSING_FRAME_RANGE
    }
    if capture.target != .COMPOSITE {
        return .INVALID_TARGET
    }
    if capture.output_path_explicit {
        return .CONFLICTING_CAPTURE_OUTPUT
    }
    return .NONE
}

viewer_video_options_error_message :: proc(
    error: Viewer_Video_Options_Error,
) -> string {
    switch error {
    case .NONE:
        return "no error"
    case .DURATION_WITHOUT_OUTPUT:
        return "--viewer-video-duration requires --viewer-video-output"
    case .DEBUG_WITHOUT_OUTPUT:
        return "--viewer-debug-video requires --viewer-video-output"
    case .INVALID_OUTPUT:
        return "--viewer-video-output requires a non-empty .mp4 path"
    case .MISSING_FRAME_RANGE:
        return "--viewer-video-output requires --capture-frame-range"
    case .INVALID_TARGET:
        return "--viewer-video-output supports only --capture-target composite"
    case .CONFLICTING_CAPTURE_OUTPUT:
        return "--viewer-video-output cannot be combined with --capture-output"
    }
    return "unknown Viewer video option error"
}

viewer_video_expected_frame_count :: proc(capture: ^shared.Capture_Options) -> u64 {
    if capture.video_frame_count > 0 {
        return capture.video_frame_count
    }
    if !capture.frame_range_set || capture.frame_range_step <= 0 ||
       capture.frame_range_end < capture.frame_range_start {
        return 0
    }
    return u64(
        (capture.frame_range_end - capture.frame_range_start) /
        capture.frame_range_step + 1,
    )
}

// A duration retimes the selected source range across the requested output
// frame count exactly once. Without a duration, preserve the existing discrete
// start:end:step pose sequence.
viewer_video_pose_frame :: proc(
    capture: ^shared.Capture_Options,
    output_frame_index: u64,
) -> f32 {
    expected_frames := viewer_video_expected_frame_count(capture)
    if expected_frames == 0 {
        return f32(capture.frame_range_start)
    }
    clamped_index := min(output_frame_index, expected_frames - 1)
    if capture.video_frame_count > 0 {
        if expected_frames == 1 {
            return f32(capture.frame_range_start)
        }
        progress := f32(clamped_index) / f32(expected_frames - 1)
        return f32(capture.frame_range_start) +
               f32(capture.frame_range_end - capture.frame_range_start) *
               progress
    }
    return f32(capture.frame_range_start) +
           f32(capture.frame_range_step) * f32(clamped_index)
}
