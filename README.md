# Lab0

Lab0 is an Odin + raylib model viewer for inspecting cel-shaded, pixel-downsampled 3D assets.

## Run interactively

```sh
odin run .
```

Run commands from the repository root because model and shader paths are relative to the working directory.

### Keyboard shortcuts

Press `F1` or `?` for the complete in-app shortcut reference. `Tab` and
`Shift+Tab` move keyboard focus through every visible interactive control;
focused buttons and checkboxes use `Enter`/`Space`, while sliders, spinners,
combos, lists, and color channels use the arrow keys. Hold `Shift` for coarse
numeric or color adjustment. `Escape` closes the active search, dropdown,
color picker, or shortcut reference, and `Cmd+Q`/`Ctrl+Q` exits the viewer.

Global accelerators include:

| Area | Shortcuts |
| --- | --- |
| Model and inspector | `Cmd/Ctrl+F` search; `Cmd/Ctrl+1..4` toggle inspector sections; `PageUp/PageDown` scroll |
| Lens and camera | `1/2/3` lens modes; `G` grid; `P` export; `X/Y/Z/I` views; `-`/`=` downscale |
| Animation | `Space` play/pause; `Home` first frame; `,/.` step; `[/]` clip; `L` loop; `K` sampled playback |
| Cel style | `C` toggle; `Alt+1..3` preset; `Cmd/Ctrl+R` reload; `Cmd/Ctrl+S` save; `Cmd/Ctrl+Shift+R` reset |
| Background | `B` color picker; `Shift+B` reset to black |

Live shortcuts are disabled in non-interactive capture mode. Modified commands
are consumed before camera input, so combinations such as `Cmd/Ctrl+S` never
leak into WASD camera movement.

Press `G` to toggle the pixel grid over the lens. The camera controls panel
shows whether the grid is currently on or off.

Use the **Downscale level** spinner in **Camera Controls** to adjust the pixel
downscale from 1× through 32×. The output-grid readout updates to show the
active render-target resolution; the default remains 10× (128×72).

The **Edge AA** selector beside it switches the low-resolution silhouette
resolve between **Hard** and **Coverage**. Hard preserves the original binary
alpha output. Coverage keeps the representative cel color while using the
deterministic 4×4 occupancy mask as fractional alpha, with outlines composited
behind partially covered fill pixels. The default remains Hard.

The right-side **Inspector** keeps model, camera, cel shading, and background
controls in one scrollable stack. Each section is independently collapsible;
**Cel Shading** starts collapsed, and `C` toggles it and scrolls it into view.
Its nested sections control light space and direction, two through eight diffuse
bands, alpha masking, band brightness and tint, hard rim/highlight accents, and
a zero-through-three-pixel silhouette outline. Edits apply immediately. Presets
are stored as versioned JSON files in `styles/`; the bundled presets are
**Classic**, **Anime**, and **Noir**.

The outline is evaluated at the active downsample resolution and is therefore
measured in output pixels. It appears in the pixelated/blended lens and exported
downsample PNG, while the full-resolution scene target remains unoutlined.

## Visual-test Scene Editor

Scene Editor is a separate visual-test authoring mode. It does not export to or
share data with Game mode. Open the bundled all-primitives, fixed-pose, and
multi-light fixture with:

```sh
odin run . -- \
  --mode scene-editor \
  --scene scenes/primitive-light-grid.json
```

Omit `--scene` to start from an empty default scene. The left hierarchy adds
imported models, cube, sphere, plane, triangle, cylinder, cone, torus, point
lights, and spot lights. Select an item in the hierarchy or viewport and edit
its exact transform, color, visibility, light values, or fixed animation pose
in the right inspector. The pinned directional-light panel controls its
enabled state, azimuth, elevation, color, and intensity without giving it a
scene position. Right-drag orbits the serialized camera, middle-drag pans, the
wheel dollies, `W`/`E`/`R` select world-axis translate/rotate/scale gizmos, `F`
frames the selection, `Delete` removes it, and `Cmd/Ctrl+S` saves.

Scene files are schema-versioned strict JSON. They use repository-relative
model and style paths, canonical two-space formatting, globally unique stable
IDs, and an atomic sibling-temporary-file save. The editor rejects comments,
trailing commas, non-finite numbers, invalid transforms or light values,
missing assets, and unsupported schema versions.

Scene Editor also uses the deterministic capture path while excluding editor
panels and overlays:

```sh
odin run . -- \
  --mode scene-editor \
  --scene scenes/primitive-light-grid.json \
  --capture-case primitive-light-grid \
  --capture-target composite \
  --capture-output artifacts/scene-editor/primitive-light-grid.png
```

Supported targets are `composite` and `scene` at 1280x720, plus `downsample`
and `coverage-mask` at the dimensions selected by the scene's downscale level.

### Scene Editor video report

Scene Editor video reports preserve every authored object, light, and fixed
animation pose while moving the serialized camera through one deterministic
orbit around its target. The default report streams 300 raw 1280x720 RGBA
frames directly to FFmpeg at 60 fps, covers 0 through 358.8 degrees without a
duplicated endpoint, and does not create an intermediate PNG sequence:

```sh
scripts/test-scene-editor.sh \
  --video-report artifacts/scene-editor-test-report-demo
```

Use `--scene path/to/scene.json` to select another scene. The runner executes
the complete Odin suite, builds a fresh binary, requires two serialized-scene
PNG captures to be byte-identical, and creates `scene-editor-test.mp4`,
`contact-sheet.png`, `report.md`, the deterministic composite PNG, and logs.

The underlying streaming command is also available directly:

```sh
odin run . -- \
  --mode scene-editor \
  --scene scenes/primitive-light-grid.json \
  --scene-video-output artifacts/scene-editor/orbit.mp4 \
  --scene-video-duration 5 \
  --capture-case primitive-light-grid-video \
  --capture-target composite
```

`--scene-video-output` requires `--scene`, `--capture-case`, and the
`composite` target and cannot be combined with `--capture-output`. Durations
must resolve to an exact whole frame count at 60 fps.

The complete file schema, lighting equations, limits, and deterministic render
contract are in
[`docs/scene-editor-v1-spec.md`](docs/scene-editor-v1-spec.md).

## Traversal prototype

The existing model viewer remains the default application. Start the separate
room-based traversal prototype with:

```sh
odin run . -- --mode game
```

The prototype is a handcrafted seven-room forest loop rendered through the same
cel-shading, coverage, downsample, and outline stages as the viewer. Explore
with screen-relative eight-directional movement, cross short gaps with a
fixed-distance dash, evade the undead, reach the overlook, and return to the
start forest.

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Move | `WASD` or arrows | Left stick or D-pad |
| Dash | `Space` | South face button |
| Reset current room | `R` | Back/View button |
| Debug overlay | `F3` | — |
| Quit | `Cmd/Ctrl+Q` | — |

R02 contains one roaming zombie and the optional R03 grove contains a
six-enemy evasion arena. Zombies shamble between authored patrol points, detect the
player through an unobstructed field of view, hear nearby dashes, and pursue the
last detected position. Their committed lunge has a bright ground telegraph;
dash across the lane during the windup to evade it. A lunge hit returns the
player and that room's zombies to their room spawns, while the HUD retains the
hit count.

Start directly in a room for inspection with `--game-room R00` through
`--game-room R06`. Game captures are deterministic at the selected room spawn:

```sh
odin run . -- \
  --mode game \
  --game-room R04 \
  --capture-case traversal-ravine \
  --capture-target composite \
  --capture-output artifacts/traversal/ravine.png
```

Game capture supports `composite` (1280×720), `scene` (1280×720),
`downsample` (256×144, including the outline), and `coverage-mask` (256×144).
Viewer capture defaults and output dimensions are unchanged. The complete
prototype scope and tuning values are recorded in
[`docs/traversal-prototype-spec.md`](docs/traversal-prototype-spec.md).

### Occlusion test scene

Use the isolated `T00` scene to inspect the player/tree visibility detector
without the authored route, transitions, hazards, or nearby props:

```sh
odin run . -- --mode game --game-room T00
```

Walk forward and backward through the single tree with `W` and `S`. The tree
keeps its normal green texture while the detector reports clear and switches to
a flat hot-pink diagnostic material while it reports that the tree occludes the
player. The yellow/hot-pink rectangle is the actual tree model bound projected
through the active camera, the cyan rectangle is the projected player model
bound, and the white rectangle is their overlap. The cyan ground ray shows the
separate depth-order check. Use `A` and `D` behind the tree to sweep across the
projected canopy edge.

The fixed replays exercise the center crossing and edge sweep and can produce a
video report with:

```sh
scripts/test-game.sh \
  --video-report artifacts/occlusion-test-report \
  --replay replays/tree-occlusion-debug.json
```

Replace the replay path with `replays/tree-occlusion-edge-debug.json` for the
edge-boundary sweep.

### Automated gameplay checks

Gameplay rules run at a fixed 60 Hz in `game_fixed_update`, independently of a
window, GPU, or physical input device. The Odin suite includes a bot-driven
walk through the full seven-room route, exact input-record/replay comparison,
the ravine and one-way-drop checks, and a 10,000-tick fixed-seed invariant run:

```sh
odin test .
```

From a logged-in graphical macOS session, the all-in-one runner also builds a
fresh binary, captures the same dynamic tick twice through the real GPU
pipeline, checks dimensions and asset warnings, and requires byte-identical
PNGs:

```sh
scripts/test-game.sh
```

For a remote, human-reviewable run, add `--video-report` and a new output
directory. This renders all 180 fixed replay ticks through the normal GPU
pipeline, streams raw RGBA frames directly to FFmpeg, creates a 1280×720 MP4
and contact sheet, and writes a Markdown summary with hashes and links to the
detailed logs:

```sh
scripts/test-game.sh --video-report artifacts/game-test-report-demo
```

Select a different deterministic replay with `--replay`. For example, this
report visibly crosses the R00 east exit and finishes in R01:

```sh
scripts/test-game.sh \
  --video-report artifacts/game-test-report-room-transition \
  --replay replays/room-transition-smoke.json
```

The generated directory contains `game-test.mp4`, `contact-sheet.png`,
`report.md`, the repeated fixed-tick determinism PNG, and the test and capture
logs. It does not contain a full PNG frame sequence. `ffmpeg` and `ffprobe` must
be available. The versioned replay and repeated fixed-tick PNG capture remain
the regression source of truth; the MP4 is optimized for remote review.

Versioned replay JSON stores compact fixed-tick input segments. Use the bundled
dash replay to render the exact same dynamic state on every run; capture ticks
are one-based:

```sh
odin run . -- \
  --mode game \
  --game-replay replays/traversal-dash-smoke.json \
  --game-capture-tick 5 \
  --capture-case traversal-dash-tick-5 \
  --capture-target composite \
  --capture-output artifacts/traversal/dash-tick-5.png
```

The zombie encounter fixture approaches the first R03 zombie, baits its lunge,
and dodges across the committed lane:

```sh
odin run . -- \
  --mode game \
  --game-replay replays/zombie-encounter-smoke.json \
  --game-capture-tick 50 \
  --capture-case zombie-windup-tick-50 \
  --capture-target composite \
  --capture-output artifacts/traversal/zombie-windup-tick-50.png
```

For a longer stress run, `zombie-gauntlet-30s.json` drives 1,800 fixed ticks
through the six-zombie R03 arena. It performs 39 dashes, triggers group chases,
and intentionally records three room resets:

```sh
scripts/test-game.sh \
  --video-report artifacts/zombie-gauntlet-report \
  --replay replays/zombie-gauntlet-30s.json
```

The replay's `start_room` owns the initial state. Supplying a conflicting
`--game-room` is an error. `--game-capture-tick` requires both a replay and a
capture case and fails before opening a window when the tick is out of range.
`--game-record-dir` requires a replay and capture case and exports one
`frame-%06d.png` for every fixed simulation tick in a single process.
`--game-video-output` requires a replay and capture case, supports only the
`composite` target, and streams one raw RGBA frame per fixed simulation tick to
an FFmpeg child process without creating intermediate PNG files.

## Non-interactive capture mode

Capture mode initializes a hidden graphics window, fixes the requested render state, renders a small number of warmup frames, exports an internal render texture to PNG, and exits. It does not use desktop screenshots or live mouse and keyboard input.

```sh
odin run . -- \
  --capture-case cube-isometric \
  --capture-model builtin:cube \
  --capture-view isometric \
  --capture-mode pixelated \
  --capture-target composite
```

The default output is `captures/<case-name>.png`. Give every concurrent worker a unique path:

```sh
odin run . -- \
  --capture-case runner-frame-24 \
  --capture-model assets/CesiumMan.glb \
  --capture-style styles/anime.json \
  --capture-frame 24 \
  --capture-target lens \
  --capture-output artifacts/worker-2/runner-frame-24.png
```

### PNG sequence capture

Use an inclusive integer frame range to capture multiple animation poses in one
process. The output template must contain exactly one `%d` or zero-padded
`%0Nd` token. The token is replaced by the animation frame number.

```sh
odin run . -- \
  --capture-case cesium-walk \
  --capture-model assets/CesiumMan.glb \
  --capture-frame-range 0:24:2 \
  --capture-view isometric \
  --capture-target scene \
  --capture-output "captures/cesium-walk/frame-%04d.png"
```

The range syntax is `start:end[:step]`; `step` defaults to `1`. Warmup frames
are rendered once before the first export, then each requested pose is rendered
and exported on the next frame. Without `--capture-output`, sequence files use
`captures/<case-name>-%04d.png`.

### Viewer video report

Use the same inclusive animation frame range with `--viewer-video-output` to
stream the Viewer composite directly to FFmpeg as raw RGBA. Each selected pose
becomes one frame in a 1280×720, 60 fps H.264 MP4; no intermediate PNG sequence
is created.

```sh
odin run . -- \
  --capture-case cesium-viewer-video \
  --capture-model assets/CesiumMan.glb \
  --capture-style styles/anime.json \
  --capture-frame-range 0:119 \
  --capture-view isometric \
  --capture-edge-aa coverage \
  --capture-target composite \
  --viewer-video-output artifacts/cesium-viewer-video.mp4 \
  --viewer-video-duration 5
```

The video option requires `--capture-frame-range` and the `composite` target,
accepts only `.mp4`, and cannot be combined with `--capture-output`. For a full
duration, `--viewer-video-duration` retimes the selected range across the output
frames exactly once and must map to a whole number of 60 fps frames. It never
wraps to the first pose. Without it, the range is streamed once. For a full
automated report with unit tests, a repeated deterministic still, MP4 metadata
checks, a contact sheet, and Markdown report, use a new output directory:

```sh
scripts/test-viewer.sh --video-report artifacts/viewer-test-report-demo
```

Available options:

```text
--capture-case <name>          Enable capture mode and name the case
--capture-output <path.png>    Output path or sequence template
--capture-model <source>       Exact asset path or builtin:cube|sphere|triangle
--capture-style <path.json>    Cel style preset (default: built-in Classic)
--viewer-video-output <mp4>    Stream a Viewer frame range through FFmpeg
--viewer-video-duration <sec>  Retime the range once to an exact duration
--capture-view <view>          default|x|y|z|isometric
--capture-mode <mode>          pixelated|blended|coverage-mask
--capture-edge-aa <mode>       hard|coverage (default: hard)
--capture-target <target>      composite|lens|scene|downsample|coverage-mask
--capture-frame <frame>        Fixed animation frame (default: 0)
--capture-frame-range <range>  Inclusive start:end[:step] pose sequence
--capture-warmup <frames>      Frames rendered before export (default: 2)
--capture-show-window          Show the otherwise hidden capture window
--capture-help                 Print capture help without opening a window
```

Capture targets:

| Target | Output |
| --- | --- |
| `composite` | 1280×720 scene, active lens, overlays, and control panels; excludes the cursor-dependent magnifier |
| `lens` | 400×400 crop of the active lens as shown in the composite |
| `scene` | 1280×720 raw scene render target |
| `downsample` | 128×72 final pixel-downsample target, including the configured outline |
| `coverage-mask` | 128×72 raw coverage-mask target |

Capture mode still requires a working raylib graphics context; it is non-interactive, not a software renderer. On macOS, run it from a logged-in graphical session. For parallel workers, use isolated source directories and distinct output paths. Shader hot reload and desktop input are disabled during a capture.

Exit status is `0` for a successful capture, `1` for a render/export failure, and `2` for invalid capture arguments or state.
