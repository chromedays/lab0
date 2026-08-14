# Cel Shading Customization v1

## Goals

- Preserve the current three-band cel-shaded appearance as the `Classic`
  default for opaque models.
- Make cel lighting editable without modifying GLSL.
- Keep the color pass and metadata pass on exactly the same band
  classification path.
- Make every style reproducible in non-interactive capture mode.
- Support two through eight diffuse bands, band tinting, alpha masking, hard
  rim light, hard highlights, and low-resolution silhouette outlines.
- Preserve the selected style across successful shader hot reloads.

## Non-goals

- Per-material style overrides.
- Correct order-independent rendering of translucent meshes.
- Depth/normal crease outlines.
- Cast-shadow maps.
- External image-authored ramps or a node shader editor.

## Render pipeline

1. `Cel_Style` is validated and converted to a 256x1 RGBA8 cel ramp.
2. The scene color pass samples the model material and cel ramp.
3. The cel metadata pass uses the same material, alpha rule, lighting inputs,
   ramp, and accent classification.
4. The existing 4x4 downsample pass chooses the dominant diffuse band, then
   preserves eligible highlight or rim samples before color clustering.
5. The coverage pass resolves the visible metadata mask.
6. A low-resolution outline pass combines the downsampled color and coverage
   mask for the pixelated lens and PNG export.

The full-resolution `scene` capture contains band shading, rim, and highlight,
but not the low-resolution outline. `coverage-mask` remains an unoutlined debug
target. `downsample` means the final outlined low-resolution result; with an
outline width of zero it is identical to the raw downsample result.

## Style data

The runtime supports at most eight diffuse bands and a 256-entry ramp.

```odin
MAX_CEL_BANDS :: 8
CEL_RAMP_WIDTH :: 256

Cel_Light_Space :: enum { WORLD, CAMERA, MODEL }
Cel_Alpha_Mode  :: enum { OPAQUE, MASK }

Cel_Band :: struct {
    upper_bound: f32,
    brightness:  f32,
    tint:        rl.Vector3,
    tint_mix:    f32,
}

Cel_Accent :: struct {
    enabled:          bool,
    color:            rl.Vector3,
    threshold:        f32,
    strength:         f32,
    preserve_samples: int,
}

Cel_Outline :: struct {
    width:              int,
    color:              rl.Color,
    coverage_threshold: f32,
}

Cel_Style :: struct {
    name:            string,
    light_space:     Cel_Light_Space,
    light_direction: rl.Vector3,
    wrap_lighting:   f32,
    band_count:      int,
    bands:           [MAX_CEL_BANDS]Cel_Band,
    alpha_mode:      Cel_Alpha_Mode,
    alpha_cutoff:    f32,
    rim:             Cel_Accent,
    highlight:       Cel_Accent,
    outline:         Cel_Outline,
    revision:        u64,
}
```

`Classic` defaults:

- world-space direction `{0.35, 0.80, 0.55}` and wrap `0`;
- thresholds `0.25` and `0.65`;
- brightness values `0.32`, `0.62`, and `1.0`;
- tint mixes `0`;
- masked alpha with cutoff `0.5`;
- disabled rim and highlight;
- outline width `0`.

## Band classification and ramp

The shared lighting input is:

```glsl
float raw_diffuse = dot(normalize(normal), normalize(light_direction));
float diffuse = clamp(
    (raw_diffuse + wrap_lighting) / (1.0 + wrap_lighting),
    0.0,
    1.0
);
```

The ramp index is `round(diffuse * 255)`, fetched with `texelFetch`. Ramp RGB
stores the band tint. Ramp alpha stores `(band_id + 1) / 255`; byte zero is
reserved for the background. A band owns values up to and including its
`upper_bound`; the final band has no upper bound. Adjacent boundaries must be
at least `1/255` apart.

Scene color is:

```glsl
vec3 multiplied = albedo.rgb * band_brightness;
vec3 tinted = band_tint * band_brightness;
vec3 cel_color = mix(multiplied, tinted, band_tint_mix);
```

## Shader bindings and hot reload

The scene and metadata shaders have independent `Cel_Shader_Bindings` location
caches. A successful reload resolves fresh locations and reapplies the whole
style. A failed reload keeps both the prior shader and prior bindings.

Static style uniforms are applied when the style revision or shader generation
changes. View position and world-resolved light direction are applied every
frame because camera-space and model-space lights can move.

## Alpha contract

`OPAQUE` ignores material alpha. `MASK` samples
`texture0 * colDiffuse * fragColor`, discards fragments below `alpha_cutoff` in
both passes, and makes surviving fragments opaque. Translucent blending is not
supported in v1.

The metadata draw copies each mesh's source material and changes only its
shader, so material texture and diffuse tint match the scene pass.

## Metadata contract

The metadata target stores exact RGBA8 values:

- R: `(diffuse_band_id + 1) / 255`;
- G: accent flags divided by 255 (`bit 0 = rim`, `bit 1 = highlight`);
- B: reserved;
- A: one for visible geometry and zero for the cleared background.

After selecting the dominant diffuse band, the downsampler chooses highlight
when its matching sample count reaches `highlight.preserve_samples`; otherwise
it chooses rim when its matching sample count reaches `rim.preserve_samples`;
otherwise it chooses base samples. Highlight has priority. Color clustering is
then restricted to the selected feature class.

## Accents

Rim uses `1 - max(dot(N, V), 0)` and a hard threshold. Highlight uses
`max(dot(N, normalize(L + V)), 0)` and a hard threshold. The scene adds rim,
then highlight, and the render target clamps the result. Disabled accents or
zero strength must not affect the output.

## Outline

The outline pass operates at the active downsample resolution. A model pixel
keeps its source color. A background pixel becomes outline color when any
coverage sample within the configured Chebyshev radius exceeds the coverage
threshold. Width is zero through three low-resolution pixels. Width zero is a
copy operation.

## JSON presets

Tracked presets live in `styles/`. The schema is versioned and stores a light,
two through eight complete band records, alpha settings, both accents, and
outline settings. Invalid versions, non-finite numbers, invalid ranges, a zero
light vector, unordered band boundaries, and invalid counts reject the complete
preset without mutating the active style.

Required presets are `styles/classic.json`, `styles/anime.json`, and
`styles/noir.json`.

## Interactive UI

The regular right-side UI is a single vertically scrollable `INSPECTOR` rather
than a collection of mutually exclusive modes. Its top-level sections are
`MODEL ASSETS`, `CAMERA CONTROLS`, `CEL SHADING`, and `SCENE BACKGROUND`.
Every section is independently collapsible, and the inspector remembers its
open state for the current run. `CEL SHADING` starts collapsed so the default
viewer stays compact; opening it never hides the model, camera, animation, or
background controls.

`CEL SHADING` contains the preset controls and a compact ramp preview followed
by independently collapsible `LIGHT`, `BANDS & ALPHA`, `ACCENTS`, and `OUTLINE`
subsections. Color values are represented by compact swatches; a picker is
shown inline only for the active swatch. Edits apply immediately and mark the
style dirty. Band add splits a selected interval; band remove merges it with a
neighbor. The count remains in `[2, 8]`. Preset load failure preserves the
current style. Save uses project-relative paths and no native file dialog.

`C` toggles the `CEL SHADING` inspector section. When it opens, the inspector
scrolls the section into view and synchronizes the editable light angles. It is
not a UI mode: camera manipulation is blocked only while the pointer is over
the inspector or while an actually modal editor state such as a color picker,
dropdown, or text field is active.

## Capture mode

`--capture-style <path.json>` selects a style. Without it, capture always uses
the built-in `Classic` default rather than any interactive state. An empty or
invalid path, read failure, parse failure, or validation failure exits with
status 2. Style loading should happen before graphics initialization whenever
possible.

## Completion criteria

1. Unit tests cover defaults, validation, ramp boundaries, JSON loading, and
   capture argument parsing.
2. Both shaders compile, share classifications, and retain style state after a
   successful hot reload.
3. Cutout holes agree in scene, metadata, coverage, and downsample output.
4. Two- and eight-band captures work and contain expected distinct bands.
5. Thin rim/highlight samples survive according to their preservation counts.
6. Outline width is exactly one through three low-resolution pixels and width
   zero preserves prior output.
7. The full Odin test suite passes, a fresh binary builds, real hidden-window
   captures have the expected PNG dimensions and nonzero size, representative
   frames are visually inspected, and repeated deterministic captures are
   byte-identical.
