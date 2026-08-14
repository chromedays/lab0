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

Available options:

```text
--capture-case <name>          Enable capture mode and name the case
--capture-output <path.png>    Output path or sequence template
--capture-model <source>       Exact asset path or builtin:cube|sphere|triangle
--capture-style <path.json>    Cel style preset (default: built-in Classic)
--capture-view <view>          default|x|y|z|isometric
--capture-mode <mode>          pixelated|blended|coverage-mask
--capture-target <target>      composite|lens|scene|downsample|coverage-mask
--capture-frame <frame>        Fixed animation frame (default: 0)
--capture-frame-range <range>  Inclusive start:end[:step] PNG sequence
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
