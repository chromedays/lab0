---
name: lab0-video-report
description: Run Lab0's deterministic Viewer or Game automation through the real GPU pipeline, stream raw frames to an MP4, create a contact sheet, inspect the artifacts, and report them in chat. Use for remote Viewer or gameplay verification, automated visual test reports, MP4 evidence, animation reviews, replay reviews, or requests to test Lab0 without a person driving the app.
---

# Lab0 Video Report

Create evidence that combines headless rule checks with a human-reviewable video.

## Run

1. Work from the Lab0 repository root so asset and shader paths resolve.
2. Choose a new report directory under `artifacts/`; never reuse an existing directory.
3. Choose the runner that matches the requested mode.

   Viewer animation report:

   ```sh
   scripts/test-viewer.sh --video-report artifacts/viewer-test-report-<unique-label>
   ```

   Game replay report:

   ```sh
   scripts/test-game.sh --video-report artifacts/game-test-report-<unique-label>
   ```

   Add `--replay replays/<name>.json` when the request names a specific route or
   behavior. Use `replays/room-transition-smoke.json` to demonstrate R00→R01.

4. On macOS, use the active graphical session if the hidden raylib window cannot initialize in the sandbox. Do not use desktop input or screenshots.

Both runners execute the Odin suite, build a fresh uniquely named binary, and
check a repeated PNG capture for byte determinism. The Viewer runner streams
the full selected animation range exactly once, retimed across 5 seconds (300
raw frames at 60 fps, with no wrap), and creates `viewer-test.mp4`; the Game runner
streams every replay tick and creates `game-test.mp4`. Both create
`contact-sheet.png`, `report.md`, and logs without creating a full PNG sequence.

## Inspect

Before reporting success:

- Require the runner to exit with status 0.
- Read `report.md` and confirm the reported test count, frame count, dimensions, duration, and SHA-256.
- Inspect `contact-sheet.png` with the local image viewer.
- Use `ffprobe` when any video metadata is missing or suspect.
- Require the encoded frame count to equal 300 for the default 5-second Viewer report or the Game replay fixed-tick count, and confirm that the report directory has no `frames/` directory.
- Treat asset image warnings, missing frames, dimension mismatches, or unequal deterministic PNGs as failures.
- Keep the repeated fixed-pose/fixed-tick PNG capture, plus the versioned replay for Game, as regression truth; MP4 is a review artifact because video encoding can vary.

## Report in chat

Lead with PASS or FAIL. Include the test count, model and frame range for Viewer
or replay name for Game, video duration and dimensions, deterministic-capture
result, and any warnings. Link absolute local paths so the user can open artifacts directly:

```markdown
[MP4](/absolute/path/viewer-test.mp4) · [report](/absolute/path/report.md) · [preview](/absolute/path/contact-sheet.png)
```

Display the contact sheet in chat when supported. If the run fails, link the relevant log and describe the first actionable failure instead of presenting a partial MP4 as passing evidence.
