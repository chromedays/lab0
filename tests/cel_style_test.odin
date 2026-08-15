package tests

// These tests cover cel-style defaults, validation, byte-level ramp encoding,
// JSON persistence, bundled presets, editor mutations, and inspector layout.

import "core:os"
import "core:testing"

// Built-in Classic keeps its historical three-band thresholds and brightness values.
@test
classic_cel_style_preserves_the_original_three_bands :: proc(t: ^testing.T) {
    style := cel_style_make_classic()
    testing.expect_value(t, cel_style_validate(&style), Cel_Style_Error.NONE)
    testing.expect_value(t, style.band_count, 3)
    testing.expect_value(t, cel_diffuse_to_band_index(&style, 0.25), 0)
    testing.expect_value(t, cel_diffuse_to_band_index(&style, 0.2501), 1)
    testing.expect_value(t, cel_diffuse_to_band_index(&style, 0.65), 1)
    testing.expect_value(t, cel_diffuse_to_band_index(&style, 0.6501), 2)
}

// Validation rejects thresholds that overlap or collapse into one ramp byte.
@test
cel_style_rejects_unordered_band_boundaries :: proc(t: ^testing.T) {
    style := cel_style_make_classic()
    style.bands[1].upper_bound = style.bands[0].upper_bound
    testing.expect_value(
        t,
        cel_style_validate(&style),
        Cel_Style_Error.INVALID_BAND_BOUNDARY,
    )
}

// The generated lookup ramp stores exact tint bytes and one-based band IDs.
@test
cel_ramp_encodes_exact_band_bytes :: proc(t: ^testing.T) {
    style := cel_style_make_classic()
    pixels := cel_ramp_pixels_build(&style)
    testing.expect_value(t, pixels[0].a, u8(1))
    testing.expect_value(t, pixels[64].a, u8(2))
    testing.expect_value(t, pixels[166].a, u8(3))
    testing.expect_value(t, pixels[255].a, u8(3))
}

// Saving then loading a style preserves all runtime fields and ownership semantics.
@test
cel_style_json_round_trip_preserves_runtime_values :: proc(t: ^testing.T) {
    path := "/tmp/lab0-cel-style-round-trip.json"
    style := cel_style_make_classic()
    style.name = "Round Trip"
    style.rim.enabled = true
    style.outline.width = 2

    save_error := cel_style_save(path, &style)
    if !testing.expect_value(t, save_error, Cel_Style_Error.NONE) {
        return
    }
    defer os.remove(path)

    loaded, load_error := cel_style_load(path)
    defer cel_style_destroy(&loaded)
    testing.expect_value(t, load_error, Cel_Style_Error.NONE)
    testing.expect_value(t, loaded.name, "Round Trip")
    testing.expect_value(t, loaded.band_count, 3)
    testing.expect(t, loaded.rim.enabled)
    testing.expect_value(t, loaded.outline.width, 2)
    testing.expect_value(t, loaded.bands[1].brightness, f32(0.62))
}

// Every shipped JSON preset decodes and validates against the current schema.
@test
bundled_cel_style_presets_are_valid :: proc(t: ^testing.T) {
    for preset_path in CEL_STYLE_PRESET_PATHS {
        style, load_error := cel_style_load(preset_path)
        testing.expect_value(t, load_error, Cel_Style_Error.NONE)
        if load_error == .NONE {
            testing.expect_value(t, cel_style_validate(&style), Cel_Style_Error.NONE)
        }
        cel_style_destroy(&style)
    }
}

// Move assignment consumes its source, replaces the previous owner, and keeps
// the destination revision monotonic without making self-assignment destructive.
@test
cel_style_move_assignment_transfers_ownership_safely :: proc(t: ^testing.T) {
    destination, destination_error := cel_style_load(CEL_STYLE_PRESET_PATHS[0])
    defer cel_style_destroy(&destination)
    if !testing.expect_value(t, destination_error, Cel_Style_Error.NONE) {
        return
    }

    source, source_error := cel_style_load(CEL_STYLE_PRESET_PATHS[1])
    defer cel_style_destroy(&source)
    if !testing.expect_value(t, source_error, Cel_Style_Error.NONE) {
        return
    }

    destination.revision = 41
    cel_style_move_assign(&destination, &source)

    testing.expect(t, destination.name_owned)
    testing.expect(t, len(destination.name) > 0)
    testing.expect_value(t, destination.revision, u64(42))
    testing.expect_value(t, source.name, "")
    testing.expect(t, !source.name_owned)
    testing.expect_value(t, source.revision, u64(0))

    moved_name := destination.name
    moved_revision := destination.revision
    cel_style_move_assign(&destination, &destination)
    testing.expect_value(t, destination.name, moved_name)
    testing.expect_value(t, destination.revision, moved_revision)
}

// Editor add/remove operations cover the full supported band-count range safely.
@test
cel_band_editor_supports_two_through_eight_bands :: proc(t: ^testing.T) {
    style := cel_style_make_classic()
    for style.band_count < MAX_CEL_BANDS {
        testing.expect(t, add_cel_band_after(&style, style.band_count - 1))
    }
    testing.expect_value(t, style.band_count, MAX_CEL_BANDS)
    testing.expect_value(t, cel_style_validate(&style), Cel_Style_Error.NONE)
    testing.expect(t, !add_cel_band_after(&style, style.band_count - 1))

    for style.band_count > 2 {
        testing.expect(t, remove_cel_band(&style, style.band_count - 1))
    }
    testing.expect_value(t, style.band_count, 2)
    testing.expect_value(t, cel_style_validate(&style), Cel_Style_Error.NONE)
    testing.expect(t, !remove_cel_band(&style, 0))
}

// Predicted editor height grows only for the subsection that is opened.
@test
cel_style_inspector_is_compact_until_a_section_is_expanded :: proc(t: ^testing.T) {
    style := cel_style_make_classic()
    state: Cel_Style_UI_State

    testing.expect_value(
        t,
        cel_style_editor_height(&state, &style),
        INSPECTOR_SECTION_HEADER_HEIGHT,
    )

    state.open = true
    collapsed_subsections_height := cel_style_editor_height(&state, &style)
    testing.expect(t, collapsed_subsections_height > INSPECTOR_SECTION_HEADER_HEIGHT)

    state.bands_open = true
    bands_height := cel_style_editor_height(&state, &style)
    testing.expect(t, bands_height > collapsed_subsections_height)

    state.color_target = .BAND_TINT
    testing.expect(t, cel_style_editor_height(&state, &style) > bands_height)
}
