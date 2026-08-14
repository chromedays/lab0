# Lab0

Lab0 is an Odin + raylib model viewer for inspecting cel-shaded, pixel-downsampled 3D assets.

## Run interactively

```sh
odin run .
```

Run commands from the repository root because model and shader paths are relative to the working directory.

Press `G` to toggle the pixel grid over the lens. The camera controls panel
shows whether the grid is currently on or off.

Use the **Downscale level** spinner in **Camera Controls** to adjust the pixel
downscale from 1× through 32×. The output-grid readout updates to show the
active render-target resolution; the default remains 10× (128×72).

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
| `downsample` | 128×72 raw pixel-downsample target |
| `coverage-mask` | 128×72 raw coverage-mask target |

Capture mode still requires a working raylib graphics context; it is non-interactive, not a software renderer. On macOS, run it from a logged-in graphical session. For parallel workers, use isolated source directories and distinct output paths. Shader hot reload and desktop input are disabled during a capture.

Exit status is `0` for a successful capture, `1` for a render/export failure, and `2` for invalid capture arguments or state.
