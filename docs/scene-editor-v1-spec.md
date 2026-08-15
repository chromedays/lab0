# Scene Editor v1 specification

## Status

This document defines the first implementation of Lab0's visual-test-only Scene
Editor. The Scene Editor is not a game-authoring path and does not share scene
data with Game mode.

The following product decisions are fixed for v1:

- scene files use strict JSON;
- models may store one fixed animation clip and frame;
- the global directional light optionally casts pixel-hard shadows;
- point and spot lights do not cast shadows;
- one cel style applies to the complete scene;
- Viewer and Game behavior and capture output must remain unchanged.

## Goals

- Arrange multiple imported models and generated primitives in one scene.
- Place point and spot lights and edit one global directional light.
- Author exact object, light, camera, and render values through raygui controls.
- Save and reload the complete visual-test state from a versioned scene file.
- Render the same scene interactively and through deterministic capture mode.
- Produce byte-identical PNGs for repeated captures made by the same build and
  graphics environment.

## Non-goals

The first version does not provide:

- Game mode export or integration;
- physics, collision, navigation, triggers, or scripts;
- parent/child transforms or a scene graph;
- point/spot shadow maps, soft shadows, baked lighting, global illumination,
  or light cookies;
- per-object cel styles;
- animation playback, looping, blending, or a timeline;
- light or camera animation;
- local-axis gizmos, transform snapping, or undo/redo;
- an operating-system file dialog;
- an editor-UI capture target.

## Entry points

Interactive editing uses a separate top-level mode:

```sh
odin run src -- --mode scene-editor --scene scenes/lighting-test.json
```

When `--scene` is omitted, the editor opens a new unsaved scene using the
built-in defaults. A supplied scene must parse and pass all CPU-only validation
before the graphics window is initialized. Model, texture, animation, and shader
resource validation runs immediately after a graphics context exists and before
the first rendered frame.

The same mode participates in the existing non-interactive capture contract:

```sh
/tmp/lab0-scene-editor \
  --mode scene-editor \
  --scene scenes/lighting-test.json \
  --capture-case lighting-test \
  --capture-target composite \
  --capture-output artifacts/lighting-test.png
```

Capture mode hides the native window unless `--capture-show-window` is present,
does not accept desktop input, renders the serialized camera, excludes editor
chrome and overlays, exports the requested internal RenderTexture, and exits.

`--mode scene-editor` rejects Game-only options, Viewer model and animation
options, `--capture-view`, lens targets, non-pixelated capture modes, game
replays, and Viewer/Game video options. `--capture-style` is also rejected
because the scene file owns its cel-style path.

A human-reviewable video uses Scene Editor-specific options:

```sh
/tmp/lab0-scene-editor \
  --mode scene-editor \
  --scene scenes/lighting-test.json \
  --scene-video-output artifacts/lighting-test.mp4 \
  --scene-video-duration 5 \
  --capture-case lighting-test-video \
  --capture-target composite
```

Video capture holds the complete authored scene and every fixed model pose
constant. It rotates only the authored camera position around its target and
normalized up axis, preserving radius, target, projection, and up. The default
five-second report streams 300 1280x720 composite frames at 60 fps. Frame `i`
uses `360 * i / frame_count` degrees, so the final 358.8-degree frame does not
duplicate frame zero. Raw RenderTexture RGBA data is piped directly to FFmpeg;
no intermediate PNG sequence is created. The repeated serialized-camera PNG
remains regression truth because encoded MP4 bytes are not deterministic.

## Editor layout and interaction

The interactive window contains four persistent regions:

1. A top file bar with New, Open, Save, Save As, the current path, and a dirty
   marker.
2. A left hierarchy containing Models, Primitives, Point Lights, and Spot
   Lights.
3. A center viewport showing the serialized camera and final render.
4. A right inspector containing the selected object's properties and a pinned
   Global Directional Light section.

The internal scene render always uses the serialized 1280x720 resolution. The
editor scales that 16:9 render into the available center viewport with
letterboxing. Consequently the interactive preview and capture use the same
camera aspect ratio. Picking and gizmo input map the displayed rectangle back
to internal render coordinates.

### Hierarchy

The hierarchy supports:

- adding a model through the existing searchable asset browser;
- adding any supported primitive;
- adding a point or spot light while its type limit has not been reached;
- selecting, renaming, duplicating, and deleting an item;
- toggling renderable visibility or light enablement;
- showing the serialized array order without implying transform parenting.

New IDs use a monotonic per-kind suffix such as `model_001` and are not reused
within the current editor session. Duplication assigns a new ID and appends the
copy to its corresponding serialized array.

### Viewport and gizmos

Viewport controls are:

- left click: select the nearest model, primitive, or light icon;
- right drag: orbit the camera around its target;
- middle drag: pan the camera and target;
- mouse wheel: dolly or change orthographic height;
- `W`: translate gizmo;
- `E`: rotate gizmo;
- `R`: scale gizmo;
- `Delete`: delete the selection after confirmation;
- `Cmd+S`: save;
- `Cmd+Shift+S`: open the raygui Save As path modal;
- `F`: frame the selected renderable;
- `Esc`: cancel the active gizmo or modal operation.

Gizmos operate in world axes only. Models and primitives expose translation,
rotation, and scale. Point lights expose translation. Spot lights expose
translation and rotation. Light icons, selection outlines, bounding boxes,
grid, axes, and gizmos are editor overlays and are never drawn into capture
RenderTextures.

Selection uses a camera ray and the closest positive collision distance.
Imported models use mesh collision with their complete model transform;
primitives use their mesh or world bounding box; lights use a small screen-size
independent picking sphere.

### Inspector

All vector values have individual X/Y/Z numeric controls. A change made by a
gizmo or numeric field updates the same runtime value and marks the scene dirty.
Invalid intermediate text may remain in the focused control, but it must not
replace the validated runtime value until it parses and passes its field rules.

The Global Directional Light section is always available and is not a hierarchy
item. It contains Enabled, Azimuth, Elevation, Color, Intensity, and Reset
Direction controls. Azimuth and elevation are derived editor values; the scene
file stores only the normalized world-space direction. There is no directional
light position or translation gizmo.

New, Open, window close, and mode exit show a raygui confirmation modal when
unsaved changes exist. Save As uses an in-app path text box rather than an OS
file dialog.

## Runtime scene model

The runtime scene owns validated render values and GPU resources. It remains
distinct from its file representation so future schema versions do not leak
compatibility concerns into rendering code.

Conceptually the runtime data contains:

```text
Scene
  name
  source_path
  cel_style
  render_settings
  camera
  directional_light
  models[]
  primitives[]
  point_lights[]
  spot_lights[]
  dirty
```

Transient state such as selection, hierarchy expansion, open modals, focused
text boxes, gizmo mode, and hovered axes is owned by `Scene_Editor_UI_State` and
is not serialized.

### Limits

The loader enforces the following upper bounds before allocating GPU resources:

- 256 combined hierarchy items;
- 128 imported model instances;
- 8 point lights;
- 8 spot lights;
- exactly one directional-light record at the top level.

The light limits correspond to fixed-size GLSL uniform arrays. Disabled lights
still occupy a serialized array entry but do not contribute to the active
uniform count.

### Transforms

Every model and primitive stores:

```text
position:             [3]f32
rotation_euler_deg:   [3]f32
scale:                [3]f32
```

The transform order is fixed:

```text
M = Translation * Rz * Ry * Rx * Scale
```

Thus a vertex is scaled, rotated around local X, then Y, then Z, and finally
translated. Euler angles are serialized in degrees. Saving normalizes each
angle into `[-180, 180)`. Scale components must be finite and at least 0.001;
negative and zero scales are invalid in v1.

Point lights serialize only a position. Spot lights serialize a position and a
normalized emission direction. The editor may use Euler angles while rotating
a spot-light gizmo, but the file stores the resulting direction so there is no
roll or Euler-order ambiguity.

### Imported models and fixed poses

A model keeps its source material, textures, vertex color, and alpha. Its
serialized tint multiplies that original albedo.

An optional animation object selects exactly one zero-based clip index and one
non-negative integer keyframe. It is applied once after loading and again only
when the editor changes either value. There is no wall-clock animation update.
The loader rejects a missing clip, an incompatible animation, or a frame greater
than or equal to that animation's `frameCount`.

Each animated model instance owns independent mutable raylib model and
animation data because `UpdateModelAnimation` mutates mesh vertices. v1 may also
give static instances independent model ownership for a simple and unambiguous
unload contract. Primitive meshes are immutable and shared by shape.

### Primitives

v1 provides the following unit primitives:

- `cube`: 1x1x1, centered at the origin;
- `sphere`: radius 0.5, centered at the origin;
- `plane`: 1x1 on the XZ plane, centered at the origin;
- `triangle`: unit-radius three-sided polygon on the XZ plane;
- `cylinder`: radius 0.5 and height 1, centered on the Y axis;
- `cone`: base radius 0.5 and height 1, centered on the Y axis;
- `torus`: outer diameter 1, centered at the origin.

Raylib-generated cylinder and cone vertices are locally translated when needed
so their authoring pivot is the center rather than a base. Tessellation counts
are compile-time constants and are not serialized; changing them later is a
visual-output change that requires capture review. Instance scale supplies all
shape dimensions in v1.

Each primitive has an exact RGBA8 albedo. It is converted to normalized shader
input without color-space transformation, matching the current renderer.

## Lighting model

Scene Editor lighting uses a new multi-light shader pair. Viewer and Game keep
their current shader programs and single-directional-light calculations.

All Scene Editor lights are world-space direct lights. The directional light
may additionally use the editor's pixel-hard shadow pass. The complete scene
uses one global cel style for diffuse bands, wrap lighting, alpha rules, rim,
highlight, and outline settings.

### Direction conventions

- Directional `direction` points from the shaded surface toward the source.
- Spot `direction` points forward from the light into the illuminated cone.
- Point and spot surface-to-light vectors are calculated per fragment.
- Every serialized direction must be finite and have nonzero length; loading
  normalizes it.

The directional light has Enabled, Direction, Color, and Intensity values but
no position. It also stores Casts Shadows, Shadow Strength, Shadow Bias, and
Shadow Extent. Point lights add Position and Range. Spot lights add Position,
Range, Inner Angle, and Outer Angle.

Light colors use normalized linear RGB components in `[0, 1]`. Intensity is a
finite value in `[0, 16]`. Range is a finite value in `[0.001, 100000]`.
Spot-light angles obey:

```text
0 <= inner_angle_deg < outer_angle_deg <= 89
```

### Diffuse contribution

For a unit surface normal `N` and a unit surface-to-light vector `L`, the
existing global cel-style wrap value is applied independently to every light:

```text
wrapped_lambert = clamp(
  (dot(N, L) + wrap_lighting) / (1 + wrap_lighting),
  0,
  1
)
```

Directional attenuation is 1. For a point or spot light at distance `d` with
range `r`:

```text
x = clamp(d / r, 0, 1)
distance_attenuation = (1 - x*x) * (1 - x*x)
```

For a spot light, `theta` is the dot product of its normalized emission
direction and the normalized vector from the light to the fragment:

```text
cone_attenuation = smoothstep(
  cos(outer_angle),
  cos(inner_angle),
  theta
)
```

Each enabled light contributes:

```text
contribution_rgb =
  color * intensity * wrapped_lambert * distance_attenuation * cone_attenuation
```

Directional lights omit the last two factors and point lights omit only the
cone factor. The shader adds every contribution into `energy_rgb`, then selects
one cel band for the complete fragment:

```text
energy_peak = max(energy_rgb.r, energy_rgb.g, energy_rgb.b)
band_input = clamp(energy_peak, 0, 1)
light_hue = energy_rgb / energy_peak when energy_peak > epsilon, otherwise white
```

Using the peak channel means a saturated red, green, or blue light at intensity
1 can reach the top band instead of being artificially dimmed by luminance
weights. Intensity above 1 can move a fragment into a higher band; the band
input saturates at 1.

The shader applies the chosen cel band to material albedo exactly as the current
style specifies, multiplies that band result by `light_hue`, then adds rim and
highlight accents. When no light contributes, `band_input` is zero and the
bottom cel band remains visible with neutral hue.

### Accents and metadata

Rim classification remains view dependent and independent of light count.
Highlight evaluates a Blinn half vector for every contributing light and uses
the maximum intensity-, range-, and cone-weighted score. The global cel-style
threshold and accent color remain authoritative.

The parallel metadata shader performs the identical multi-light and shadow
calculation. It encodes one band ID, rim/highlight flags, and a binary shadow
classification in the previously reserved blue byte. The 4x4 downsampler votes
on that shadow state inside the winning band before color clustering, preserving
a hard logical-pixel edge. Viewer and Game continue to write zero to the reserved
byte and retain byte-identical captures.

### Pixel-hard directional shadows

When enabled, visible models and primitives both cast and receive a directional
shadow. The pass renders directly into a sampleable 1024x1024 depth texture
attached to a depth-only framebuffer. The receiver uses the exact view and
projection matrices installed for that depth pass, point filtering, clamp
addressing, one binary depth comparison, and no PCF or blur.

The orthographic light camera is centered on the serialized scene-camera target.
Its horizontal and vertical light-plane coordinates are rounded to exact shadow
texels before the view-projection matrix is built. `shadow_extent` is the square
world-space coverage and therefore defines one shadow texel as:

```text
world_units_per_shadow_texel = shadow_extent / 1024
```

`shadow_strength` is finite in `[0, 1]`, `shadow_bias` in `[0.00001, 0.01]`,
and `shadow_extent` in `[1, 1000]`. The binary visibility term affects only the
directional contribution; point and spot contributions can still illuminate a
directionally shadowed fragment. Alpha-masked material silhouettes use the same
global cel-style cutoff in the shadow-depth pass.

## Render pipeline

Scene Editor introduces separate scene color and cel-metadata shader programs,
for example:

```text
shaders/scene_multi_light.vs
shaders/scene_multi_light.fs
shaders/scene_multi_light_band.fs
shaders/scene_multi_light_common.glsl
shaders/scene_shadow_depth.vs
shaders/scene_shadow_depth.fs
```

The passes are:

1. If directional shadows are active, render alpha-tested geometry into the
   texel-snapped 1024x1024 depth texture and retain the exact light-pass matrix.
2. Render all visible models and primitives into the 1280x720 scene-color
   RenderTexture using the multi-light shader.
3. Render identical geometry and alpha rejection into the 1280x720 cel-metadata
   RenderTexture.
4. Downsample scene color using the metadata texture.
5. Downsample coverage.
6. Apply the existing low-resolution outline pass.
7. Composite the outlined low-resolution result over the serialized background
   and scale it across the complete 1280x720 frame with nearest filtering.

Opaque draw order follows file array order: models first, then primitives. This
order is part of the v1 render contract. Alpha masking is supported through the
global cel style; blended transparent materials remain outside v1.

Interactive editor overlays are drawn only after the final texture is scaled
into the native window. They never modify the internal render targets.

## Strict JSON scene format

Scene files use `.json`, are parsed and written with
`core:encoding/json` and an explicit `.JSON` specification, and normally live
under `scenes/`.

The file structs use plain Odin arrays, numbers, booleans, and strings rather
than raylib runtime types. Dynamic arrays in the file mirror the four hierarchy
groups. A representative schema-version-1 document is:

```json
{
  "schema_version": 1,
  "name": "Point and spot comparison",
  "style": "styles/classic.json",
  "render": {
    "background": [28, 30, 38, 255],
    "downscale_level": 10,
    "edge_aa": "coverage"
  },
  "camera": {
    "projection": "perspective",
    "position": [6.0, 4.0, 6.0],
    "target": [0.0, 1.0, 0.0],
    "up": [0.0, 1.0, 0.0],
    "vertical_fov_deg": 45.0,
    "ortho_height": 8.0
  },
  "directional_light": {
    "enabled": true,
    "direction": [0.35, 0.8, 0.55],
    "color": [1.0, 1.0, 1.0],
    "intensity": 0.7,
    "casts_shadows": true,
    "shadow_strength": 0.65,
    "shadow_bias": 0.00035,
    "shadow_extent": 20.0
  },
  "models": [
    {
      "id": "model_001",
      "name": "Runner",
      "visible": true,
      "source": "assets/CesiumMan.glb",
      "position": [0.0, 0.0, 0.0],
      "rotation_euler_deg": [0.0, 0.0, 0.0],
      "scale": [1.0, 1.0, 1.0],
      "tint": [255, 255, 255, 255],
      "animation": {
        "clip_index": 0,
        "frame": 24
      }
    }
  ],
  "primitives": [
    {
      "id": "primitive_001",
      "name": "Floor",
      "visible": true,
      "shape": "plane",
      "position": [0.0, 0.0, 0.0],
      "rotation_euler_deg": [0.0, 0.0, 0.0],
      "scale": [10.0, 1.0, 10.0],
      "albedo": [160, 170, 185, 255]
    }
  ],
  "point_lights": [
    {
      "id": "point_001",
      "name": "Red fill",
      "enabled": true,
      "position": [-2.0, 2.0, 1.0],
      "color": [1.0, 0.15, 0.1],
      "intensity": 1.2,
      "range": 6.0
    }
  ],
  "spot_lights": [
    {
      "id": "spot_001",
      "name": "Blue key",
      "enabled": true,
      "position": [3.0, 4.0, 3.0],
      "direction": [-0.55, -0.7, -0.45],
      "color": [0.2, 0.45, 1.0],
      "intensity": 1.5,
      "range": 10.0,
      "inner_angle_deg": 18.0,
      "outer_angle_deg": 30.0
    }
  ]
}
```

`vertical_fov_deg` and `ortho_height` are both written in a canonical file so
switching projection preserves the previous value. Perspective rendering uses
only the FOV, and orthographic rendering uses only the height.

The optional `animation` member is omitted for a model without a fixed pose.
The four directional-shadow members are also optional when loading older
schema-v1 files. If absent, shadows load disabled while strength, bias, and
extent receive their current defaults; the next save writes all four values.
Strict JSON comments, trailing commas, NaN, infinities, hexadecimal numbers,
and unquoted keys are rejected.

### Paths and stable output

Serialized asset and style paths use `/` separators and are resolved from the
repository root, matching Lab0's existing execution contract. Tracked scenes
must use repository-relative paths. The interactive editor may report an
external or absolute selection as nonportable, but Save rejects it for v1.

Saving uses a dedicated file representation and:

- writes fields in struct declaration order;
- preserves dynamic-array order;
- pretty prints with two spaces;
- never writes timestamps, selection, revision counters, absolute paths, or
  allocation-derived identifiers;
- writes a sibling temporary file and atomically renames it over the destination
  only after encoding and write completion;
- leaves the previous destination intact on failure.

Arbitrary user formatting is not preserved. Loading and saving a valid file
produces the canonical pretty-printed representation.

## Validation and failures

The loader parses into a temporary file struct, performs CPU-only schema, path,
and value validation, and converts it into a temporary runtime description.
Once a graphics context exists it loads and validates referenced models,
textures, animations, cel-style GPU data, and shaders into a temporary resource
set. The active scene is replaced only after both phases succeed. Open failure
leaves the previous scene and its dirty state untouched.

Validation includes:

- supported `schema_version`;
- non-empty scene and item names with bounded UTF-8 byte lengths;
- globally unique IDs matching `[A-Za-z][A-Za-z0-9_-]{0,63}`;
- all collection and light-count limits;
- finite camera, transform, light, angle, and render numbers;
- nondegenerate camera direction and up vectors;
- supported camera projection and edge-AA strings;
- downscale level in the existing supported range;
- scale, color, intensity, range, and cone limits;
- directional shadow strength, bias, and extent limits;
- normalized or normalizable direction vectors;
- supported primitive shape strings;
- repository-relative existing model and style paths;
- supported model extensions and successful model and texture loads;
- valid optional animation clip and frame;
- valid cel-style JSON and style invariants.

Asset image warnings are load failures, consistent with the repository capture
policy. A white fallback texture must not silently make a scene valid.

Invalid arguments or scene state exit with status 2 before rendering. GPU
initialization, shader, readback, and export failures exit with status 1. A
successful interactive exit or capture exits with status 0.

## Determinism and verification

Unit tests cover:

- default scene construction;
- strict-JSON-only parsing;
- canonical save/load/save round trips;
- every validation rule and collection limit;
- global ID uniqueness across separate arrays;
- transform matrix order and Euler normalization;
- light direction, distance attenuation, cone attenuation, and aggregation;
- directional shadow defaults, persistence, validation, and texel snapping;
- fixed animation clip/frame validation and pose application;
- editor mutations and dirty-state transitions;
- CLI compatibility and mode-specific option rejection.

GPU verification for the implementation includes:

1. Run `odin test tests`.
2. Build a fresh uniquely named `/tmp` binary.
3. Capture a scene containing every primitive, an imported textured model, a
   fixed animated pose, all three light types, and overlapping colored lights.
4. Verify PNG file type, dimensions, nonzero size, and absence of image-load
   warnings.
5. Inspect representative `scene`, `downsample`, `coverage-mask`, and
   `composite` targets.
6. Capture the same scene twice and require byte-identical corresponding PNGs.
7. Change a point position, spot direction, and directional azimuth separately
   and require a changed scene hash for each case.
8. Re-run the established Viewer and Game tests and require their existing
   deterministic capture paths to remain unchanged.
9. Run `scripts/test-scene-editor.sh --video-report <new-artifact-directory>`,
   verify 300 H.264 frames at 1280x720 and 60 fps, inspect its contact sheet,
   and require that no `frames/` directory or partial MP4 remains.

At minimum, durable fixtures should include:

- `scenes/primitive-light-grid.json` for shapes and all light types;
- `scenes/animated-model-pose.json` for fixed-pose model loading;
- one invalid-schema fixture per major validation category in unit-test data.

Generated PNGs remain local artifacts. Versioned scene JSON, style JSON, model
assets, and deterministic test logic are the regression sources of truth.

## Suggested implementation boundaries

The implementation should keep the new mode isolated behind small modules:

```text
src/scene_types.odin          validated runtime data and constants
src/scene_file.odin           strict JSON schema, validation, load, and save
src/scene_lighting.odin       CPU reference calculations and uniform packing
src/scene_renderer.odin       GPU resources and render passes
src/scene_video.odin          camera-orbit progression and video option contract
src/scene_editor_ui.odin      hierarchy, inspector, modal, and gizmo state
src/scene_editor_mode.odin    CLI parsing, lifecycle, capture, and main loop
```

`main` dispatches Scene Editor before initializing Viewer resources, in the
same way Game mode currently owns its separate startup path. The first change
should establish parsing and unit-testable file/runtime conversion before any
raygui or GPU implementation. The multi-light shader and deterministic capture
path should exist before interactive gizmos so every editor mutation can be
verified against the final renderer as it is added.
