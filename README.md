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

## Traversal prototype

The existing model viewer remains the default application. Start the separate
room-based traversal prototype with:

```sh
odin run . -- --mode game
```

The prototype is a handcrafted seven-room forest loop rendered through the same
cel-shading, coverage, downsample, and outline stages as the viewer. Gameplay is
kept intentionally narrow: explore with screen-relative eight-directional
movement, cross short gaps with a fixed-distance dash, reach the overlook, and
return to the start forest.

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Move | `WASD` or arrows | Left stick or D-pad |
| Dash | `Space` | South face button |
| Reset current room | `R` | Back/View button |
| Debug overlay | `F3` | — |
| Quit | `Cmd/Ctrl+Q` | — |

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
