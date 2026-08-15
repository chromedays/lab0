package tests

// Shader hot-reload result tests stay GPU-independent by covering unchanged
// metadata without entering raylib's shader compilation path.

import "core:os"
import "core:testing"
import shared "../src/shared"
import rl "vendor:raylib"

@test
shader_reload_result_reports_unchanged_dependencies :: proc(
    t: ^testing.T,
) {
    path := "/tmp/lab0-shader-reload-result.fs"
    source_text := "#version 330\nvoid main() {}\n"
    write_error := os.write_entire_file(path, transmute([]byte)source_text)
    if !testing.expect(t, write_error == nil) {
        return
    }
    defer os.remove(path)

    preprocess_result := shared.shader_file_preprocess(path)
    source := preprocess_result.source
    defer shared.shader_preprocessed_source_destroy(&source)
    if !testing.expect_value(
        t,
        preprocess_result.error,
        shared.Shader_Preprocess_Error.NONE,
    ) {
        return
    }

    shader: rl.Shader
    unchanged := shared.shader_fragment_reload_with_includes(
        path,
        &shader,
        &source,
    )
    testing.expect_value(t, unchanged.status, shared.Shader_Reload_Status.UNCHANGED)
    testing.expect_value(t, unchanged.error, shared.Shader_Load_Error.NONE)
}
