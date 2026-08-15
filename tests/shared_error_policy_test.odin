package tests

// These tests pin the shared package's error-policy conventions without
// requiring a GPU context. Operational GPU success paths remain covered by the
// repository's hidden-window capture checks.

import "core:testing"
import shared "../src/shared"

@test
shared_error_messages_use_empty_text_for_none :: proc(t: ^testing.T) {
    testing.expect_value(t, shared.capture_parse_error_message(.NONE), "")
    testing.expect_value(t, shared.capture_export_error_message(.NONE), "")
    testing.expect_value(t, shared.cel_style_error_message(.NONE), "")
    testing.expect_value(t, shared.scene_error_message(.NONE), "")
    testing.expect_value(t, shared.scene_resource_error_message(.NONE), "")
    testing.expect_value(t, shared.scene_renderer_error_message(.NONE), "")
    testing.expect_value(t, shared.scene_capture_error_message(.NONE), "")
    testing.expect_value(t, shared.shader_preprocess_error_message(.NONE), "")
    testing.expect_value(t, shared.shader_load_error_message(.NONE), "")
    testing.expect_value(t, shared.game_video_options_error_message(.NONE), "")
    testing.expect_value(t, shared.video_stream_start_error_message(.NONE), "")
    testing.expect_value(t, shared.video_stream_write_error_message(.NONE), "")
    testing.expect_value(t, shared.video_stream_finish_error_message(.NONE), "")
    testing.expect_value(t, shared.model_load_error_message(.NONE), "")
}

@test
shared_fallible_apis_return_typed_failures :: proc(t: ^testing.T) {
    renderer_error := shared.scene_renderer_init(nil, nil, 1)
    testing.expect_value(
        t,
        renderer_error,
        shared.Scene_Renderer_Error.INVALID_RENDER_STATE,
    )

    _, capture_error := shared.scene_renderer_capture_texture(nil, .COMPOSITE)
    testing.expect_value(
        t,
        capture_error,
        shared.Scene_Capture_Error.TARGET_UNAVAILABLE,
    )

    encoder: shared.Video_Stream_Encoder
    write_error := shared.video_stream_encoder_write_render_texture(&encoder, {})
    testing.expect_value(
        t,
        write_error,
        shared.Video_Stream_Write_Error.ENCODER_NOT_RUNNING,
    )
    finish_error := shared.video_stream_encoder_finish(&encoder, "unused.mp4", 0, "test")
    testing.expect_value(
        t,
        finish_error,
        shared.Video_Stream_Finish_Error.ENCODER_NOT_RUNNING,
    )

    model_assets: shared.Model_Assets
    _, model_error := shared.model_source_load(&model_assets, 0)
    testing.expect_value(
        t,
        model_error,
        shared.Model_Load_Error.INVALID_SOURCE_INDEX,
    )

    animation_result := shared.animation_playback_load({}, "", .CUBE)
    testing.expect_value(
        t,
        animation_result.status,
        shared.Animation_Playback_Load_Status.NOT_APPLICABLE,
    )
}

@test
shader_preprocess_returns_a_typed_read_failure :: proc(t: ^testing.T) {
    result := shared.shader_file_preprocess(
        "/tmp/lab0-shared-error-policy-missing-shader.fs",
    )
    defer shared.shader_preprocessed_source_destroy(&result.source)
    testing.expect_value(
        t,
        result.error,
        shared.Shader_Preprocess_Error.SOURCE_READ_FAILED,
    )
}
