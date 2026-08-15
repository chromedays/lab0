#!/bin/sh

# Validate Scene Editor through the normal GPU path. With --video-report the
# authored camera performs one deterministic orbit and each composite
# RenderTexture is streamed directly to FFmpeg; no PNG sequence is created.
set -eu

scene_path="scenes/primitive-light-grid.json"
video_duration_seconds="5"
video_report=false
report_dir=""

if [ ! -f src/main.odin ]; then
    echo "error: run scripts/test-scene-editor.sh from the Lab0 repository root" >&2
    exit 2
fi

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
        --scene)
            shift
            if [ "$#" -eq 0 ]; then
                echo "error: --scene requires a strict-JSON scene path" >&2
                exit 2
            fi
            scene_path=$1
            shift
            ;;
        --video-duration)
            shift
            if [ "$#" -eq 0 ]; then
                echo "error: --video-duration requires a positive whole number of seconds" >&2
                exit 2
            fi
            video_duration_seconds=$1
            shift
            ;;
        *)
            echo "usage: scripts/test-scene-editor.sh [--scene path.json] [--video-duration seconds] [--video-report [output-directory]]" >&2
            exit 2
            ;;
    esac
done

case "$video_duration_seconds" in
    ''|*[!0-9]*)
        echo "error: --video-duration requires a positive whole number of seconds" >&2
        exit 2
        ;;
esac
if [ "$video_duration_seconds" -le 0 ]; then
    echo "error: --video-duration requires a positive whole number of seconds" >&2
    exit 2
fi
expected_video_frames=$((video_duration_seconds * 60))
expected_last_orbit_angle=$(awk -v frames="$expected_video_frames" 'BEGIN {
    printf "%.3f", 360.0 * (frames - 1) / frames
}')

if [ ! -f "$scene_path" ]; then
    echo "error: scene does not exist: $scene_path" >&2
    exit 2
fi

run_id=$$
binary="/tmp/lab0-scene-editor-autotest-${run_id}"
output_dir="/tmp/lab0-scene-editor-autotest-${run_id}-captures"
capture_a="${output_dir}/scene-composite-a.png"
capture_b="${output_dir}/scene-composite-b.png"
log_a="${output_dir}/scene-composite-a.log"
log_b="${output_dir}/scene-composite-b.log"
unit_log="${output_dir}/odin-test.log"

if [ "$video_report" = true ] && [ -z "$report_dir" ]; then
    report_dir="artifacts/scene-editor-test-report-${run_id}"
fi
if [ "$video_report" = true ] && [ -e "$report_dir" ]; then
    echo "error: video report directory already exists: $report_dir" >&2
    exit 2
fi

mkdir -p "$output_dir"

echo "[1/4] Scene schema, editor, lighting, and render-contract tests"
if odin test tests >"$unit_log" 2>&1; then
    sed -n '1,200p' "$unit_log"
else
    sed -n '1,240p' "$unit_log" >&2
    exit 1
fi

echo "[2/4] Fresh Scene Editor binary"
odin build src -out:"$binary"

echo "[3/4] Repeated serialized-scene composite capture"
"$binary" \
    --mode scene-editor \
    --scene "$scene_path" \
    --capture-case scene-editor-determinism-a \
    --capture-target composite \
    --capture-output "$capture_a" >"$log_a" 2>&1
"$binary" \
    --mode scene-editor \
    --scene "$scene_path" \
    --capture-case scene-editor-determinism-b \
    --capture-target composite \
    --capture-output "$capture_b" >"$log_b" 2>&1

if rg -q "WARNING: IMAGE|Failed to load scene|Failed to load scene resources|Failed to load scene cel style" "$log_a" "$log_b"; then
    echo "error: capture log contains a Scene Editor asset warning" >&2
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
echo "Scene Editor automation passed. Artifacts: $output_dir"

if [ "$video_report" = true ]; then
    if ! command -v ffmpeg >/dev/null 2>&1 ||
       ! command -v ffprobe >/dev/null 2>&1; then
        echo "error: --video-report requires ffmpeg and ffprobe" >&2
        exit 2
    fi

    recording_log="${report_dir}/recording.log"
    video_path="${report_dir}/scene-editor-test.mp4"
    contact_sheet="${report_dir}/contact-sheet.png"
    report_path="${report_dir}/report.md"
    mkdir -p "$report_dir"

    echo "[video 1/3] Stream one deterministic camera orbit to FFmpeg"
    if "$binary" \
        --mode scene-editor \
        --scene "$scene_path" \
        --scene-video-output "$video_path" \
        --scene-video-duration "$video_duration_seconds" \
        --capture-case scene-editor-video-report \
        --capture-target composite >"$recording_log" 2>&1; then
        :
    else
        sed -n '1,240p' "$recording_log" >&2
        exit 1
    fi

    if rg -q "WARNING: IMAGE|Failed to load scene|Failed to load scene resources|Failed to load scene cel style" "$recording_log"; then
        echo "error: recording log contains a Scene Editor asset warning" >&2
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

    streamed_frame_count=$(rg -o "Streamed [0-9]+ scene-orbit frames" "$recording_log" | tail -n 1 | rg -o '[0-9]+' || true)
    if [ "$streamed_frame_count" != "$expected_video_frames" ]; then
        echo "error: streamed ${streamed_frame_count:-0} Scene Editor frames; expected $expected_video_frames" >&2
        exit 1
    fi
    if ! rg -q "Streamed Scene camera orbit 0.000 through ${expected_last_orbit_angle} degrees exactly once across ${expected_video_frames} output frames" "$recording_log"; then
        echo "error: recording did not confirm a one-pass non-duplicated camera orbit" >&2
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
    capture_sha_line=$(shasum -a 256 "$capture_a")
    capture_sha=${capture_sha_line%% *}
    test_summary=$(rg "Finished [0-9]+ tests" "$unit_log" | tail -n 1)
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    cp "$unit_log" "${report_dir}/odin-test.log"
    cp "$log_a" "${report_dir}/determinism-a.log"
    cp "$log_b" "${report_dir}/determinism-b.log"
    cp "$capture_a" "${report_dir}/scene-composite.png"

    {
        printf '# Lab0 automated Scene Editor test report\n\n'
        printf -- '- Result: **PASS**\n'
        printf -- '- Generated: `%s`\n' "$generated_at"
        printf -- '- Unit suite: `%s`\n' "$test_summary"
        printf -- '- Scene: `%s`\n' "$scene_path"
        printf -- '- Camera motion: `one deterministic 360-degree orbit; duplicated endpoint omitted`\n'
        printf -- '- Authored fixed animation poses: `preserved`\n'
        printf -- '- Video encoding: `raw RGBA streamed through FFmpeg stdin`\n'
        printf -- '- Video: `%s` H.264, `%s seconds`, `%s frames at 60 fps`\n' "$video_dimensions" "$video_duration" "$frame_count"
        printf -- '- MP4 SHA-256: `%s`\n' "$video_sha"
        printf -- '- Composite PNG SHA-256: `%s`\n' "$capture_sha"
        printf -- '- Serialized-scene PNG determinism: **byte-identical**\n'
        printf -- '- Intermediate PNG sequence: **not created**\n'
        printf -- '- Asset image warnings: **none**\n\n'
        printf '[Open MP4](./scene-editor-test.mp4)\n\n'
        printf '![Scene orbit contact sheet](./contact-sheet.png)\n\n'
        printf 'Detailed logs: [Odin tests](./odin-test.log), [recording](./recording.log), [capture A](./determinism-a.log), [capture B](./determinism-b.log).\n'
    } >"$report_path"

    echo "[video 3/3] Streaming Scene Editor video report passed"
    echo "MP4: $video_path"
    echo "Preview: $contact_sheet"
    echo "Report: $report_path"
fi
