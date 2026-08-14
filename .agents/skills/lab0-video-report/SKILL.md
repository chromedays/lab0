---
name: lab0-video-report
description: Run Lab0's deterministic game-mode automation, record the replay through the real GPU pipeline, encode an MP4 and contact sheet, inspect the artifacts, and report them in chat. Use for remote gameplay verification, automated visual test reports, MP4 evidence, replay reviews, or requests to test Lab0 without a person driving the game.
---

# Lab0 Video Report

Create evidence that combines headless rule checks with a human-reviewable video.

## Run

1. Work from the Lab0 repository root so asset and shader paths resolve.
2. Choose a new report directory under `artifacts/`; never reuse an existing directory.
3. Run:

   ```sh
   scripts/test-game.sh --video-report artifacts/game-test-report-<unique-label>
   ```

   Add `--replay replays/<name>.json` when the request names a specific route or
   behavior. Use `replays/room-transition-smoke.json` to demonstrate R00→R01.

4. On macOS, use the active graphical session if the hidden raylib window cannot initialize in the sandbox. Do not use desktop input or screenshots.

The runner executes the Odin suite, builds a fresh uniquely named binary, checks a repeated fixed-tick capture for byte determinism, records every replay tick to PNG, encodes `game-test.mp4`, creates `contact-sheet.png`, and writes `report.md` plus logs.

## Inspect

Before reporting success:

- Require the runner to exit with status 0.
- Read `report.md` and confirm the reported test count, frame count, dimensions, duration, and SHA-256.
- Inspect `contact-sheet.png` with the local image viewer.
- Use `ffprobe` when any video metadata is missing or suspect.
- Treat asset image warnings, missing frames, dimension mismatches, or unequal deterministic PNGs as failures.
- Keep PNG frames as regression truth; MP4 is a review artifact because video encoding can vary.

## Report in chat

Lead with PASS or FAIL. Include the test count, replay name, video duration and dimensions, deterministic-capture result, and any warnings. Link absolute local paths so the user can open artifacts directly:

```markdown
[MP4](/absolute/path/game-test.mp4) · [report](/absolute/path/report.md) · [preview](/absolute/path/contact-sheet.png)
```

Display the contact sheet in chat when supported. If the run fails, link the relevant log and describe the first actionable failure instead of presenting a partial MP4 as passing evidence.
