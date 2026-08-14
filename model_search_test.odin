package main

// These tests specify fuzzy asset search independently of raygui. They cover
// delimiter tolerance, ranking quality, and preservation of canonical source IDs.

import "core:strings"
import "core:testing"

// Queries match both path-like asset names and human-readable built-in labels.
@test
model_search_matches_asset_names_and_primitives :: proc(t: ^testing.T) {
    _, case_insensitive_match := fuzzy_model_score(
        "cesiumman",
        "assets/CesiumMan.glb",
    )
    testing.expect(
        t,
        case_insensitive_match,
        "asset model search should be case-insensitive",
    )

    _, separated_words_match := fuzzy_model_score(
        "female run",
        "assets/Female_Female Poses_OBJ_Female_Running.glb",
    )
    testing.expect(
        t,
        separated_words_match,
        "spaces in the query should match separated filename words",
    )

    _, primitive_abbreviation_match := fuzzy_model_score("cbe", "builtin:cube")
    testing.expect(
        t,
        primitive_abbreviation_match,
        "built-in primitives should support fuzzy abbreviations",
    )

    _, unrelated_match := fuzzy_model_score("spaceship", "builtin:cube")
    testing.expect(
        t,
        !unrelated_match,
        "unrelated model names should not match",
    )
}

// Consecutive boundary matches outrank candidates with larger intervening gaps.
@test
model_search_prefers_tighter_matches :: proc(t: ^testing.T) {
    direct_score, direct_match := fuzzy_model_score(
        "tree",
        "assets/tree_1.glb",
    )
    loose_score, loose_match := fuzzy_model_score(
        "tree",
        "assets/environment/dead_tree_1.glb",
    )
    testing.expect(t, direct_match && loose_match, "both tree paths should match")
    testing.expect(
        t,
        direct_score > loose_score,
        "the shorter, tighter filename match should rank first",
    )
}

// Sorting/filtering must not replace canonical source indices with result positions.
@test
model_search_results_keep_source_indices :: proc(t: ^testing.T) {
    model_assets: Model_Assets
    append(&model_assets.paths, strings.clone("assets/tree_1.glb"))
    append(&model_assets.labels, strings.clone_to_cstring("tree_1.glb"))
    append(&model_assets.kinds, Model_Source_Kind.ASSET)
    append(&model_assets.paths, strings.clone("builtin:cube"))
    append(&model_assets.labels, strings.clone_to_cstring("Built-in / Cube"))
    append(&model_assets.kinds, Model_Source_Kind.CUBE)
    defer destroy_model_assets(&model_assets)

    browser := Model_Browser_State{active_index = -1, focus_index = -1}
    defer destroy_model_browser_state(&browser)
    browser.search_text[0] = 'c'
    browser.search_text[1] = 'b'
    browser.search_text[2] = 'e'

    rebuild_model_search_results(&model_assets, &browser)
    testing.expect_value(t, len(browser.results), 1)
    testing.expect_value(t, browser.results[0].source_index, 1)
    testing.expect_value(t, string(browser.result_labels[0]), "Built-in / Cube")
}
