#!/bin/sh

# Run from the repository root. The report path streams the deterministic
# Viewer animation range directly from the composite RenderTexture to FFmpeg;
# it never materializes a PNG sequence.
set -eu

model_path="assets/CesiumMan.glb"
style_path="styles/anime.json"
frame_range="0:119"
video_duration_seconds="5"
determinism_frame="24"
expected_video_frames="300"

if [ ! -f src/main.odin ] || [ ! -f "$model_path" ] || [ ! -f "$style_path" ]; then
    echo "error: run scripts/test-viewer.sh from the Lab0 repository root" >&2
    exit 2
fi

video_report=false
report_dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --video-report)
            video_report=true
            shift
            if [ "$#" -gt 0 ]; then
                case "$1" in
                    --*) ;;
                    *) report_dir=$1; shift ;;
                esac
            fi
            ;;
        *)
            echo "usage: scripts/test-viewer.sh [--video-report [output-directory]]" >&2
            exit 2
            ;;
    esac
done

run_id=$$
binary="/tmp/lab0-viewer-autotest-${run_id}"
output_dir="/tmp/lab0-viewer-autotest-${run_id}-captures"
capture_a="${output_dir}/animation-frame-${determinism_frame}-a.png"
capture_b="${output_dir}/animation-frame-${determinism_frame}-b.png"
log_a="${output_dir}/animation-frame-${determinism_frame}-a.log"
log_b="${output_dir}/animation-frame-${determinism_frame}-b.log"
unit_log="${output_dir}/odin-test.log"

if [ "$video_report" = true ] && [ -z "$report_dir" ]; then
    report_dir="artifacts/viewer-test-report-${run_id}"
fi
if [ "$video_report" = true ] && [ -e "$report_dir" ]; then
    echo "error: video report directory already exists: $report_dir" >&2
    exit 2
fi

mkdir -p "$output_dir"

echo "[1/4] Viewer unit and render-contract tests"
if odin test tests >"$unit_log" 2>&1; then
    sed -n '1,200p' "$unit_log"
else
    sed -n '1,240p' "$unit_log" >&2
    exit 1
fi

echo "[2/4] Fresh Viewer binary"
odin build src -out:"$binary"

echo "[3/4] Repeated animation capture at frame $determinism_frame"
"$binary" \
    --mode viewer \
    --capture-case viewer-frame-${determinism_frame}-a \
    --capture-model "$model_path" \
    --capture-style "$style_path" \
    --capture-frame "$determinism_frame" \
    --capture-view isometric \
    --capture-mode pixelated \
    --capture-edge-aa coverage \
    --capture-target composite \
    --capture-output "$capture_a" >"$log_a" 2>&1
"$binary" \
    --mode viewer \
    --capture-case viewer-frame-${determinism_frame}-b \
    --capture-model "$model_path" \
    --capture-style "$style_path" \
    --capture-frame "$determinism_frame" \
    --capture-view isometric \
    --capture-mode pixelated \
    --capture-edge-aa coverage \
    --capture-target composite \
    --capture-output "$capture_b" >"$log_b" 2>&1

if rg -q "WARNING: IMAGE|Failed to load initial model|Failed to load capture cel style" "$log_a" "$log_b"; then
    echo "error: capture log contains an asset-image or Viewer load warning" >&2
    exit 1
fi

file_a=$(file "$capture_a")
file_b=$(file "$capture_b")
case "$file_a" in
    *"PNG image data, 1280 x 720"*) ;;
    *) echo "error: unexpected first capture: $file_a" >&2; exit 1 ;;
esac
case "$file_b" in
    *"PNG image data, 1280 x 720"*) ;;
    *) echo "error: unexpected second capture: $file_b" >&2; exit 1 ;;
esac

echo "[4/4] Byte determinism"
cmp -s "$capture_a" "$capture_b"
shasum -a 256 "$capture_a" "$capture_b"
echo "Viewer automation passed. Artifacts: $output_dir"

if [ "$video_report" = true ]; then
    if ! command -v ffmpeg >/dev/null 2>&1 ||
       ! command -v ffprobe >/dev/null 2>&1; then
        echo "error: --video-report requires ffmpeg and ffprobe" >&2
        exit 2
    fi

    recording_log="${report_dir}/recording.log"
    video_path="${report_dir}/viewer-test.mp4"
    contact_sheet="${report_dir}/contact-sheet.png"
    report_path="${report_dir}/report.md"
    mkdir -p "$report_dir"

    echo "[video 1/3] Stream the deterministic Viewer pose range to FFmpeg"
    if "$binary" \
        --mode viewer \
        --capture-case viewer-video-report \
        --capture-model "$model_path" \
        --capture-style "$style_path" \
        --capture-frame-range "$frame_range" \
        --capture-view isometric \
        --capture-mode pixelated \
        --capture-edge-aa coverage \
        --capture-target composite \
        --viewer-video-output "$video_path" \
        --viewer-video-duration "$video_duration_seconds" >"$recording_log" 2>&1; then
        :
    else
        sed -n '1,240p' "$recording_log" >&2
        exit 1
    fi

    if rg -q "WARNING: IMAGE|Failed to load initial model|Failed to load capture cel style" "$recording_log"; then
        echo "error: recording log contains an asset-image or Viewer load warning" >&2
        exit 1
    fi
    if [ -d "${report_dir}/frames" ]; then
        echo "error: streaming video report unexpectedly created a frames directory" >&2
        exit 1
    fi
    if find "$report_dir" -name '*.partial-*.mp4' -print -quit | rg -q .; then
        echo "error: streaming video report left an incomplete MP4" >&2
        exit 1
    fi
    streamed_frame_count=$(rg -o "Streamed [0-9]+ animation frames" "$recording_log" | tail -n 1 | rg -o '[0-9]+' || true)
    case "$streamed_frame_count" in
        ''|*[!0-9]*) echo "error: recording log has no streamed animation frame count" >&2; exit 1 ;;
    esac
    if [ "$streamed_frame_count" != "$expected_video_frames" ]; then
        echo "error: streamed $streamed_frame_count Viewer frames; expected $expected_video_frames" >&2
        exit 1
    fi
    if ! rg -q "Streamed Viewer source frames 0.000 through 119.000 exactly once across 300 output frames" "$recording_log"; then
        echo "error: recording did not confirm one-pass 0:119 source progression" >&2
        exit 1
    fi

    video_dimensions=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$video_path")
    video_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_path")
    video_frame_rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$video_path")
    frame_count=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 "$video_path")
    video_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_path")
    if [ "$video_dimensions" != "1280x720" ]; then
        echo "error: unexpected video dimensions: $video_dimensions" >&2
        exit 1
    fi
    if [ "$video_codec" != "h264" ]; then
        echo "error: unexpected video codec: $video_codec" >&2
        exit 1
    fi
    if [ "$video_frame_rate" != "60/1" ]; then
        echo "error: unexpected video frame rate: $video_frame_rate" >&2
        exit 1
    fi
    if [ "$frame_count" != "$streamed_frame_count" ]; then
        echo "error: encoded frame count $frame_count does not match streamed count $streamed_frame_count" >&2
        exit 1
    fi
    if ! awk -v duration="$video_duration" -v frames="$frame_count" 'BEGIN {
        expected = frames / 60.0
        delta = duration - expected
        if (delta < 0) delta = -delta
        exit(delta <= (1.0 / 60.0 + 0.000001) ? 0 : 1)
    }'; then
        echo "error: video duration $video_duration does not match $frame_count frames at 60 fps" >&2
        exit 1
    fi

    echo "[video 2/3] Build visual summary"
    sample_1=$((frame_count / 3))
    sample_2=$((frame_count * 2 / 3))
    sample_3=$((frame_count - 1))
    ffmpeg -hide_banner -loglevel error -y \
        -i "$video_path" \
        -vf "select='eq(n,0)+eq(n,${sample_1})+eq(n,${sample_2})+eq(n,${sample_3})',scale=360:-1,tile=4x1:padding=4:margin=4:color=202020" \
        -frames:v 1 \
        "$contact_sheet"

    video_sha_line=$(shasum -a 256 "$video_path")
    video_sha=${video_sha_line%% *}
    test_summary=$(rg "Finished [0-9]+ tests" "$unit_log" | tail -n 1)
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    cp "$unit_log" "${report_dir}/odin-test.log"
    cp "$log_a" "${report_dir}/determinism-a.log"
    cp "$log_b" "${report_dir}/determinism-b.log"
    cp "$capture_a" "${report_dir}/animation-frame-${determinism_frame}.png"

    {
        printf '# Lab0 automated Viewer-test report\n\n'
        printf -- '- Result: **PASS**\n'
        printf -- '- Generated: `%s`\n' "$generated_at"
        printf -- '- Unit suite: `%s`\n' "$test_summary"
        printf -- '- Recorded model: `%s`\n' "$model_path"
        printf -- '- Cel style: `%s`\n' "$style_path"
        printf -- '- Animation frame range: `%s` (inclusive)\n' "$frame_range"
        printf -- '- Animation range playback: `retimed once to %s seconds; no loop`\n' "$video_duration_seconds"
        printf -- '- Edge AA: `coverage`\n'
        printf -- '- Video encoding: `raw RGBA streamed through FFmpeg stdin`\n'
        printf -- '- Video: `%s` H.264, `%s seconds`, `%s frames at 60 fps`\n' "$video_dimensions" "$video_duration" "$frame_count"
        printf -- '- MP4 SHA-256: `%s`\n' "$video_sha"
        printf -- '- Animation-frame PNG determinism: **byte-identical**\n'
        printf -- '- Intermediate PNG sequence: **not created**\n'
        printf -- '- Asset image warnings: **none**\n\n'
        printf '[Open MP4](./viewer-test.mp4)\n\n'
        printf '![Animation contact sheet](./contact-sheet.png)\n\n'
        printf 'Detailed logs: [Odin tests](./odin-test.log), [recording](./recording.log), [capture A](./determinism-a.log), [capture B](./determinism-b.log).\n'
    } >"$report_path"

    echo "[video 3/3] Streaming Viewer video report passed"
    echo "MP4: $video_path"
    echo "Preview: $contact_sheet"
    echo "Report: $report_path"
fi
