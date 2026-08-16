package tests

// These tests protect state transitions shared by the Viewer timeline and its
// keyboard shortcuts without requiring a live raylib window.

import "core:c"
import "core:testing"

@test
animation_clip_selection_resets_and_stops_playback :: proc(t: ^testing.T) {
    playback := Animation_Playback{
        active_index = 0,
        current_frame = 24,
        is_playing = true,
    }
    append(&playback.valid_indices, c.int(0), c.int(1))
    defer delete(playback.valid_indices)

    changed := animation_playback_select_clip(&playback, 1)
    testing.expect(t, changed)
    testing.expect_value(t, playback.active_index, c.int(1))
    testing.expect_value(t, playback.current_frame, f32(0))
    testing.expect(t, !playback.is_playing)
    testing.expect(t, playback.pose_dirty)

    playback.pose_dirty = false
    changed = animation_playback_select_clip(&playback, 1)
    testing.expect(t, !changed)
    testing.expect(t, !playback.pose_dirty)

    changed = animation_playback_select_clip(&playback, 2)
    testing.expect(t, !changed)
    testing.expect_value(t, playback.active_index, c.int(1))
}
