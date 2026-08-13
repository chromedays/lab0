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

## Capture targets and expected dimensions

| Target | Expected output |
| --- | --- |
| `composite` | 1280x720 scene, active lens, overlays, and control panels |
| `lens` | 400x400 crop of the active lens |
| `scene` | 1280x720 raw scene RenderTexture |
| `downsample` | 128x72 raw pixel-downsample RenderTexture |
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
