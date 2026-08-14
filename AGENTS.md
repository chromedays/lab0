# Lab0 agent instructions

## Project and working directory

Lab0 is an Odin + raylib model viewer. Run build, test, and capture commands
from the repository root because asset and shader paths are resolved relative
to the current working directory.

Preserve unrelated worktree changes. Multiple agents may share this worktree,
so coordinate source edits and never assume an unfamiliar modification is safe
to revert.

## Default visual-validation path

Use the non-interactive capture mode for render and in-app UI validation. It
renders through the normal GPU pipeline into internal raylib RenderTextures,
exports PNG files, and exits without live mouse or keyboard input.

Do not use System Events, synthetic desktop input, or full-screen screenshots
for routine visual tests. Those are reserved for explicit OS-integration checks
such as window placement, focus, native dialogs, display scaling, or interaction
with other applications.

Before a real render check, run the unit suite and build a fresh binary:

```sh
odin test .
odin build . -out:/tmp/lab0-capture-worker-a
```

Use a unique `/tmp` binary name for each concurrent worker.

## Single-frame captures

Basic graphics and capture smoke test:

```sh
/tmp/lab0-capture-worker-a \
  --capture-case cube-smoke \
  --capture-model builtin:cube \
  --capture-view isometric \
  --capture-mode pixelated \
  --capture-target composite \
  --capture-output /tmp/lab0-worker-a/cube-smoke.png
```

Fixed animation pose:

```sh
/tmp/lab0-capture-worker-a \
  --capture-case runner-frame-24 \
  --capture-model assets/CesiumMan.glb \
  --capture-frame 24 \
  --capture-view isometric \
  --capture-target scene \
  --capture-output /tmp/lab0-worker-a/runner-frame-24.png
```

Style preset capture:

```sh
/tmp/lab0-capture-worker-a \
  --capture-case anime-sphere \
  --capture-model builtin:sphere \
  --capture-style styles/anime.json \
  --capture-view isometric \
  --capture-target downsample \
  --capture-output /tmp/lab0-worker-a/anime-sphere.png
```

Without `--capture-style`, captures use the built-in Classic style. Invalid or
unreadable style files exit with status 2 before rendering.

Relative paths such as `assets/CesiumMan.glb` and exact absolute asset paths
are both supported.

## PNG sequence captures

Use `--capture-frame-range start:end[:step]` for multiple animation poses in
one process. The range uses non-negative integer frames, includes both ends when
reachable by the step, and defaults to a step of 1.

```sh
/tmp/lab0-capture-worker-a \
  --capture-case cesium-walk \
  --capture-model assets/CesiumMan.glb \
  --capture-frame-range 0:24:4 \
  --capture-view isometric \
  --capture-mode pixelated \
  --capture-target scene \
  --capture-output "/tmp/lab0-worker-a/cesium/frame-%04d.png"
```

Sequence output rules:

- The output path must contain exactly one `%d` or `%0Nd` token.
- `%04d` produces names such as `frame-0000.png` and `frame-0024.png`.
- Without `--capture-output`, the default is
  `captures/<case-name>-%04d.png`.
- Do not combine `--capture-frame` with `--capture-frame-range`.
- The model must have a playable animation, and the range end must not exceed
  its last animation keyframe.
- A sequence is limited to 10,000 outputs per invocation.
- Warmup frames are rendered once before the first export. Each subsequent pose
  is applied and rendered before its PNG is exported.

For a human-reviewable Viewer video report, use
`scripts/test-viewer.sh --video-report artifacts/<unique-report-name>`. It uses
the same deterministic animation-pose range but streams each 1280×720 composite
RenderTexture directly to FFmpeg with `--viewer-video-output`; it does not build
the MP4 from a PNG sequence. The runner creates `viewer-test.mp4`,
`contact-sheet.png`, and `report.md`, plus one repeated fixed-frame PNG used as
the regression truth. The default runner uses distinct source range 0:119
(excluding the duplicated terminal loop keyframe 120) and
`--viewer-video-duration 5` to retime that full range exactly once across 300
streamed frames at 60 fps, without wrapping to frame zero. Inspect and link all
three report artifacts by absolute local path.

## Capture targets and expected dimensions

| Target | Expected output |
| --- | --- |
| `composite` | 1280x720 scene, active lens, overlays, and control panels |
| `lens` | 400x400 crop of the active lens |
| `scene` | 1280x720 raw scene RenderTexture |
| `downsample` | 128x72 final pixel-downsample RenderTexture, including the configured outline |
| `coverage-mask` | 128x72 raw coverage-mask RenderTexture |

The composite deliberately excludes the cursor-dependent magnifier so captures
remain independent of desktop cursor state.

## Multi-agent execution

Parallel capture processes are supported. Follow these rules:

1. Give every worker a unique binary path, case name, and output filename or
   filename prefix.
2. Workers may share an existing parent output directory; directory creation is
   race-safe and existing directories are accepted.
3. Never let two workers write the same PNG path. Last-writer wins would hide
   test failures even though directory creation itself is safe.
4. Prefer dividing work by model, animation, camera, target, or disjoint frame
   range. Keep one continuous animation sequence in one process when temporal
   continuity is the property under test.
5. Put disposable smoke-test output under `/tmp`. Put requested review artifacts
   under `artifacts/<case-or-worker>/` so another agent can inspect them.

Example parallel partition:

```text
worker-a: model A, frames 0:24:4  -> artifacts/run/worker-a/frame-%04d.png
worker-b: model B, frames 0:24:4  -> artifacts/run/worker-b/frame-%04d.png
worker-c: model A, frames 28:52:4 -> artifacts/run/worker-c/frame-%04d.png
```

## Verification checklist

A successful capture command exits with status 0. Invalid arguments or invalid
capture state exit with status 2. GPU readback or PNG export failures exit with
status 1.

For every implementation change affecting capture behavior:

1. Run `odin test .`.
2. Build a fresh binary rather than relying on an older `/tmp` executable.
3. Run at least one real hidden-window capture.
4. Confirm the expected file count, PNG format, dimensions, and nonzero size.
5. Inspect representative first, middle, and last frames with the local image
   viewer. For a sequence, also check that frames expected to move do not all
   have the same hash.
6. Run the same short sequence twice and require corresponding outputs to be
   byte-identical when testing determinism.
7. When changing parallel behavior, run at least two capture processes
   concurrently with distinct output names in a shared directory.

Useful read-only checks:

```sh
file /tmp/lab0-worker-a/cesium/*.png
shasum -a 256 /tmp/lab0-worker-a/cesium/*.png
cmp -s run-a/frame-0000.png run-b/frame-0000.png
```

FFmpeg may be used to assemble a contact sheet for human review. PNG files, not
encoded video, remain the regression source of truth because video codecs can
introduce irrelevant differences.

## Scene Editor validation

Scene Editor is selected with `--mode scene-editor` and requires a strict-JSON
scene for non-interactive capture. Use the bundled all-primitives, fixed-pose,
and multi-light fixture for a representative check:

```sh
/tmp/lab0-capture-worker-a \
  --mode scene-editor \
  --scene scenes/primitive-light-grid.json \
  --capture-case primitive-light-grid \
  --capture-target composite \
  --capture-output /tmp/lab0-worker-a/primitive-light-grid.png
```

Scene captures support `composite`, `scene`, `downsample`, and
`coverage-mask`. Their low-resolution dimensions follow the scene's serialized
downscale level. Viewer model/style/view/frame options and Game replay options
are invalid because the scene owns all render state.

Use `scripts/test-scene-editor.sh --video-report
artifacts/<unique-report-name>` for a human-reviewable camera-orbit report. It
runs the unit suite, builds a fresh binary, checks two serialized-camera PNGs
for byte determinism, then streams 300 1280x720 composite RenderTextures
directly to FFmpeg over one five-second orbit at 60 fps. Frame zero is not
duplicated at the endpoint. The runner creates `scene-editor-test.mp4`,
`contact-sheet.png`, `report.md`, one deterministic composite PNG, and logs,
without creating a `frames/` directory. Inspect and link the MP4, report, and
contact sheet by absolute local path; retain the PNG and versioned scene JSON
as regression truth.

## Game-mode validation

The traversal prototype is a separate runtime path selected with `--mode game`.
The viewer remains the default, and its established capture outputs must remain
byte-identical when game code changes.

Use `--game-room R00` through `R06` to start from a deterministic room spawn.
Game captures reuse the normal capture case, output, style, warmup, window, and
target flags. They support `composite`, `scene`, `downsample`, and
`coverage-mask`; lens, animation-frame, sequence, capture-view, non-pixelated
capture-mode, and capture-model options are invalid in Game mode.

```sh
/tmp/lab0-capture-worker-a \
  --mode game \
  --game-room R04 \
  --capture-case traversal-ravine \
  --capture-target composite \
  --capture-output /tmp/lab0-worker-a/traversal-ravine.png
```

Game target dimensions are 1280×720 for `composite` and `scene`, and 256×144
for `downsample` and `coverage-mask`. Run representative R00, R02, and R04
captures after changes to game rendering or room composition. Re-run the same
room capture and require byte-identical output when validating determinism.

Game behavior tests call `game_fixed_update` directly with `Game_Input`; do not
use desktop keyboard automation. `game_scenario_test.odin` walks the authored
route through real collision and transition rules, records every input, and
replays it against an exact final-state checkpoint. The fixed-seed random test
adds 10,000 ticks of bounds, collision, timer, and finite-value invariants.

For a dynamic visual regression, drive capture from a versioned replay and name
the exact one-based simulation tick:

```sh
/tmp/lab0-capture-worker-a \
  --mode game \
  --game-replay replays/traversal-dash-smoke.json \
  --game-capture-tick 5 \
  --capture-case traversal-dash-tick-5 \
  --capture-target composite \
  --capture-output /tmp/lab0-worker-a/traversal-dash-tick-5.png
```

Repeat the command to a distinct path and require byte-identical PNGs. Replay
files use schema version 1 and compact input segments (`ticks`, `move`, and
`dash_on_first`); they are evaluated only by the fixed 60 Hz simulation.
`scripts/test-game.sh` runs the complete unit/build/double-capture check from
the repository root and leaves its uniquely named artifacts under `/tmp`.

Use `scripts/test-game.sh --video-report artifacts/<unique-report-name>` when
the user needs remote review evidence in chat. It renders every replay tick in
one process and streams raw RGBA frames directly to FFmpeg with
`--game-video-output`; it does not create a full PNG sequence. The runner creates
`game-test.mp4`, `contact-sheet.png`, and `report.md` plus logs. Inspect the
contact sheet, read the report, and link the MP4, report, and preview by absolute
local path in the final response. Never treat MP4 bytes as regression truth;
the repeated fixed-tick PNG captures and input replay remain authoritative.

## macOS graphics-session constraint

Non-interactive does not mean software-headless. raylib still initializes a
hidden native window and requires a working macOS WindowServer/OpenGL context.

In a restricted remote shell, initialization may hang or fail before
`InitWindow` with messages such as:

```text
Connection Invalid error for service com.apple.hiservices-xpcservice
GLFW: Failed to determine Monitor to center Window
SYSTEM: Failed to initialize platform
```

If that happens:

1. Stop the hung process instead of waiting indefinitely.
2. Confirm that the Mac has a logged-in, active graphical session.
3. Re-run the same hidden capture with permission to access the active GUI
   session. Wake the display briefly when necessary.
4. Do not replace this test with a desktop screenshot; the internal PNG remains
   the artifact being validated.

The capture is still non-interactive in this mode: no visible-window assertion,
desktop screenshot, mouse event, keyboard event, or System Events automation is
required. A truly display-independent CI environment would require a separate
software or offscreen rendering backend.

## Asset warnings

Bundled GLB and GLTF textures use image formats supported by the raylib build.
Treat `IMAGE` load warnings as validation failures even when geometry, animation,
and PNG export otherwise succeed: a white fallback texture can hide lost albedo.

## Local reports and artifacts

The `captures/` and `artifacts/` directories are intentionally gitignored.
Store generated PNG sequences, contact sheets, hashes, and one-off validation
reports there for local handoff, but do not depend on those files being present
in a fresh checkout. Durable instructions and regression logic belong in
`AGENTS.md`, `README.md`, and the Odin test suite.
