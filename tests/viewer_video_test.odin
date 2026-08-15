package tests

// Viewer video tests cover frame-range authority, duration retiming, CLI
// conflicts, and exact source-pose sampling independently of FFmpeg execution.

import "core:math"
import "core:testing"

@(test)
viewer_video_options_accept_composite_animation_range :: proc(t: ^testing.T) {
    capture := Capture_Options{
        enabled = true,
        video_output = "artifacts/report/viewer-test.mp4",
        target = .COMPOSITE,
        frame_range_set = true,
        frame_range_start = 0,
        frame_range_end = 119,
        frame_range_step = 1,
    }
    testing.expect_value(
        t,
        validate_viewer_video_options(&capture),
        Viewer_Video_Options_Error.NONE,
    )
    testing.expect_value(t, viewer_video_expected_frame_count(&capture), u64(120))

    capture.video_frame_count = 300
    testing.expect_value(t, viewer_video_expected_frame_count(&capture), u64(300))
    testing.expect_value(t, viewer_video_pose_frame(&capture, 0), f32(0))
    testing.expect(
        t,
        math.abs(viewer_video_pose_frame(&capture, 150) - f32(59.698997)) <
        0.0001,
    )
    testing.expect_value(t, viewer_video_pose_frame(&capture, 299), f32(119))
}

@(test)
viewer_video_options_reject_invalid_and_conflicting_requests :: proc(t: ^testing.T) {
    capture := Capture_Options{
        enabled = true,
        video_output = "artifacts/report/viewer-test.mov",
        target = .COMPOSITE,
    }

    duration_only := Capture_Options{video_frame_count = 300}
    testing.expect_value(
        t,
        validate_viewer_video_options(&duration_only),
        Viewer_Video_Options_Error.DURATION_WITHOUT_OUTPUT,
    )
    testing.expect_value(
        t,
        validate_viewer_video_options(&capture),
        Viewer_Video_Options_Error.INVALID_OUTPUT,
    )

    capture.video_output = "artifacts/report/viewer-test.mp4"
    testing.expect_value(
        t,
        validate_viewer_video_options(&capture),
        Viewer_Video_Options_Error.MISSING_FRAME_RANGE,
    )

    capture.frame_range_set = true
    capture.frame_range_step = 1
    capture.target = .SCENE
    testing.expect_value(
        t,
        validate_viewer_video_options(&capture),
        Viewer_Video_Options_Error.INVALID_TARGET,
    )

    capture.target = .COMPOSITE
    capture.output_path_explicit = true
    testing.expect_value(
        t,
        validate_viewer_video_options(&capture),
        Viewer_Video_Options_Error.CONFLICTING_CAPTURE_OUTPUT,
    )
}

@(test)
capture_parser_accepts_viewer_video_output :: proc(t: ^testing.T) {
    result := parse_capture_options([]string{
        "--capture-case", "viewer-video",
        "--capture-model", "assets/CesiumMan.glb",
        "--capture-frame-range", "0:119",
        "--viewer-video-output", "artifacts/report/viewer-test.mp4",
        "--viewer-video-duration", "5",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.NONE)
    testing.expect_value(
        t,
        result.options.video_output,
        "artifacts/report/viewer-test.mp4",
    )
    testing.expect_value(t, result.options.output_path, "")
    testing.expect_value(
        t,
        viewer_video_expected_frame_count(&result.options),
        u64(300),
    )
}

@(test)
capture_parser_rejects_non_mp4_viewer_video_output :: proc(t: ^testing.T) {
    result := parse_capture_options([]string{
        "--capture-case", "viewer-video",
        "--capture-frame-range", "0:45",
        "--viewer-video-output", "artifacts/report/viewer-test.mov",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(
        t,
        result.error,
        Capture_Parse_Error.INVALID_VIDEO_OUTPUT,
    )
}

@(test)
capture_parser_rejects_viewer_duration_between_60_fps_frames :: proc(
    t: ^testing.T,
) {
    result := parse_capture_options([]string{
        "--capture-case", "viewer-video",
        "--capture-frame-range", "0:45",
        "--viewer-video-output", "artifacts/report/viewer-test.mp4",
        "--viewer-video-duration", "1.001",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(
        t,
        result.error,
        Capture_Parse_Error.INVALID_VIDEO_DURATION,
    )
}
