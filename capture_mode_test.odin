package main

// These tests define the capture CLI contract and filesystem-facing edge cases.
// Parsing tests avoid GPU initialization; asset-format and directory tests guard the
// assumptions required before a real hidden-window capture begins.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Ordinary application arguments leave capture mode disabled and defaults intact.
@test
capture_options_are_disabled_without_capture_arguments :: proc(t: ^testing.T) {
    result := parse_capture_options({})
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.NONE)
    testing.expect(t, !result.options.enabled)
}

// A case without an explicit output receives a stable single-frame PNG path.
@test
capture_options_build_a_deterministic_default_output :: proc(t: ^testing.T) {
    result := parse_capture_options({"--capture-case", "smoke"})
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.NONE)
    testing.expect(t, result.options.enabled)
    testing.expect_value(t, result.options.case_name, "smoke")
    testing.expect_value(t, result.options.output_path, "captures/smoke.png")
    testing.expect_value(t, result.options.target, Capture_Target.COMPOSITE)
    testing.expect_value(t, result.options.view, Capture_View.DEFAULT)
    testing.expect_value(t, result.options.lens_mode, Lens_Mode.PIXELATED)
    testing.expect_value(t, result.options.edge_aa_mode, Edge_AA_Mode.HARD)
    testing.expect_value(t, result.options.warmup_frames, 2)
    testing.expect(t, result.options.hide_window)
}

// Every explicit model/style/view/mode/target/frame/warmup option maps to runtime state.
@test
capture_options_parse_explicit_render_state :: proc(t: ^testing.T) {
    result := parse_capture_options({
        "--capture-case", "cesium-walk",
        "--capture-output", "artifacts/cesium-walk.png",
        "--capture-model", "assets/CesiumMan.glb",
        "--capture-style", "styles/anime.json",
        "--capture-view", "isometric",
        "--capture-mode", "coverage-mask",
        "--capture-edge-aa", "coverage",
        "--capture-target", "lens",
        "--capture-frame", "12.5",
        "--capture-warmup", "4",
        "--capture-show-window",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.NONE)
    testing.expect_value(t, result.options.output_path, "artifacts/cesium-walk.png")
    testing.expect_value(t, result.options.style_path, "styles/anime.json")
    testing.expect_value(t, result.options.view, Capture_View.ISOMETRIC)
    testing.expect_value(t, result.options.lens_mode, Lens_Mode.COVERAGE_MASK)
    testing.expect_value(t, result.options.edge_aa_mode, Edge_AA_Mode.COVERAGE)
    testing.expect_value(t, result.options.target, Capture_Target.LENS)
    testing.expect_value(t, result.options.animation_frame, f32(12.5))
    testing.expect_value(t, result.options.warmup_frames, 4)
    testing.expect(t, !result.options.hide_window)
}

// Edge AA accepts only the two viewer resolve modes.
@test
capture_options_reject_an_invalid_edge_aa_mode :: proc(t: ^testing.T) {
    result := parse_capture_options({
        "--capture-case", "smoke",
        "--capture-edge-aa", "fxaa",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.INVALID_EDGE_AA)
    testing.expect(t, !result.options.enabled)
}

// Style inputs must be non-empty JSON paths before any file access occurs.
@test
capture_options_reject_an_invalid_style_path :: proc(t: ^testing.T) {
    result := parse_capture_options({
        "--capture-case", "smoke",
        "--capture-style", "styles/anime.txt",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.INVALID_STYLE)
    testing.expect(t, !result.options.enabled)
}

// Model-source flags reject empty values rather than falling back silently.
@test
capture_options_reject_an_empty_model_source :: proc(t: ^testing.T) {
    result := parse_capture_options({
        "--capture-case", "smoke",
        "--capture-model", "",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.INVALID_MODEL)
    testing.expect(t, !result.options.enabled)
}

// Any capture-specific flag requires an explicit case name for deterministic reporting.
@test
capture_options_reject_capture_flags_without_a_case :: proc(t: ^testing.T) {
    result := parse_capture_options({"--capture-mode", "blended"})
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.MISSING_CASE)
    testing.expect(t, !result.options.enabled)
}

// Unknown capture-prefixed flags fail fast instead of being ignored as app arguments.
@test
capture_options_reject_unknown_capture_arguments :: proc(t: ^testing.T) {
    result := parse_capture_options({"--capture-case", "smoke", "--capture-magic", "yes"})
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.UNKNOWN_ARGUMENT)
    testing.expect_value(t, result.error_argument, "--capture-magic")
}

// NaN and infinity are rejected even though they are parseable floating-point values.
@test
capture_options_reject_non_finite_animation_frames :: proc(t: ^testing.T) {
    result := parse_capture_options({
        "--capture-case", "smoke",
        "--capture-frame", "NaN",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.INVALID_FRAME)
}

// Inclusive start/end/step ranges populate sequence state and output-token metadata.
@test
capture_options_parse_frame_sequence :: proc(t: ^testing.T) {
    result := parse_capture_options({
        "--capture-case", "running",
        "--capture-frame-range", "0:12:3",
        "--capture-output", "captures/running/frame-%04d.png",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.NONE)
    testing.expect(t, result.options.enabled)
    testing.expect(t, result.options.frame_range_set)
    testing.expect_value(t, result.options.frame_range_start, 0)
    testing.expect_value(t, result.options.frame_range_end, 12)
    testing.expect_value(t, result.options.frame_range_step, 3)

    frame_path := format_capture_sequence_output_path(
        result.options.output_path,
        result.options.output_template,
        12,
    )
    defer delete(frame_path)
    testing.expect_value(t, frame_path, "captures/running/frame-0012.png")
}

// Sequence mode synthesizes a zero-padded frame token when output is omitted.
@test
capture_options_build_a_default_sequence_template :: proc(t: ^testing.T) {
    result := parse_capture_options({
        "--capture-case", "running",
        "--capture-frame-range", "4:8",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(t, result.error, Capture_Parse_Error.NONE)
    testing.expect_value(t, result.options.output_path, "captures/running-%04d.png")

    frame_path := format_capture_sequence_output_path(
        result.options.output_path,
        result.options.output_template,
        4,
    )
    defer delete(frame_path)
    testing.expect_value(t, frame_path, "captures/running-0004.png")
}

// Malformed, descending, zero-step, negative, and oversized ranges are rejected.
@test
capture_options_reject_invalid_frame_ranges :: proc(t: ^testing.T) {
    invalid_ranges := []string{
        "",
        "0",
        "4:0",
        "0:4:0",
        "0:4:-1",
        "0.5:4",
        "0:4:1:1",
        "0:999999999:1",
    }
    for invalid_range in invalid_ranges {
        result := parse_capture_options({
            "--capture-case", "running",
            "--capture-frame-range", invalid_range,
        })
        testing.expect_value(
            t,
            result.error,
            Capture_Parse_Error.INVALID_FRAME_RANGE,
        )
        destroy_capture_options(&result.options)
    }
}

// A single-frame pose and a frame range cannot be requested simultaneously.
@test
capture_options_reject_conflicting_frame_modes :: proc(t: ^testing.T) {
    result := parse_capture_options({
        "--capture-case", "running",
        "--capture-frame", "2",
        "--capture-frame-range", "0:4:2",
    })
    defer destroy_capture_options(&result.options)

    testing.expect_value(
        t,
        result.error,
        Capture_Parse_Error.CONFLICTING_FRAME_OPTIONS,
    )
}

// Explicit sequence outputs must contain exactly one supported integer token.
@test
capture_options_require_a_sequence_output_token :: proc(t: ^testing.T) {
    invalid_templates := []string{
        "captures/running/frame.png",
        "captures/running/frame-%04d-%d.png",
        "captures/running/frame-%00d.png",
    }
    for invalid_template in invalid_templates {
        result := parse_capture_options({
            "--capture-case", "running",
            "--capture-frame-range", "0:4:2",
            "--capture-output", invalid_template,
        })
        testing.expect_value(
            t,
            result.error,
            Capture_Parse_Error.INVALID_OUTPUT_TEMPLATE,
        )
        destroy_capture_options(&result.options)
    }
}

// Relative asset paths resolve to the same canonical source as scanned absolute paths.
@test
capture_model_source_accepts_a_relative_asset_path :: proc(t: ^testing.T) {
    relative_model_path := "assets/CesiumMan.glb"
    absolute_model_path, path_error := filepath.abs(relative_model_path)
    if !testing.expectf(
        t,
        path_error == nil,
        "failed to build absolute model path: %v",
        path_error,
    ) {
        return
    }
    defer delete(absolute_model_path)

    model_assets: Model_Assets
    append(&model_assets.paths, absolute_model_path)
    defer delete(model_assets.paths)

    source_index, source_found := find_capture_model_source(
        &model_assets,
        relative_model_path,
    )
    testing.expect(t, source_found)
    testing.expect_value(t, source_index, 0)
}

// Bundled glTF images use embedded PNG data so raylib does not fall back to white textures.
@test
bundled_textured_models_use_supported_embedded_pngs :: proc(t: ^testing.T) {
    model_paths := []string{
        "assets/CesiumMan.glb",
        "assets/CesiumMan.gltf",
        "assets/godotman.glb",
    }
    for model_path in model_paths {
        model_bytes, read_error := os.read_entire_file(
            model_path,
            context.allocator,
        )
        if !testing.expectf(
            t,
            read_error == nil,
            "failed to read bundled model %s: %v",
            model_path,
            read_error,
        ) {
            continue
        }

        model_contents := string(model_bytes)
        testing.expectf(
            t,
            strings.contains(model_contents, "image/png"),
            "%s must embed its texture as PNG",
            model_path,
        )
        testing.expectf(
            t,
            !strings.contains(model_contents, "image/jpeg"),
            "%s must not embed an unsupported JPEG texture",
            model_path,
        )
        delete(model_bytes)
    }
}

// Output directory creation succeeds both initially and when the directory already exists.
@test
capture_output_directory_can_be_reused :: proc(t: ^testing.T) {
    temporary_directory, temporary_error := os.make_directory_temp(
        "",
        "lab0-capture-directory-test-*",
        context.allocator,
    )
    if !testing.expectf(
        t,
        temporary_error == nil,
        "failed to create temporary directory: %v",
        temporary_error,
    ) {
        return
    }
    defer delete(temporary_directory)
    defer {
        cleanup_error := os.remove_all(temporary_directory)
        testing.expectf(
            t,
            cleanup_error == nil,
            "failed to remove temporary directory: %v",
            cleanup_error,
        )
    }

    output_path, path_error := filepath.join({
        temporary_directory,
        "reused",
        "capture.png",
    })
    if !testing.expectf(
        t,
        path_error == nil,
        "failed to build capture output path: %v",
        path_error,
    ) {
        return
    }
    defer delete(output_path)

    testing.expect(t, ensure_capture_output_directory(output_path))
    testing.expect(t, ensure_capture_output_directory(output_path))
}
