#!/bin/sh

# Run from the repository root. This keeps all asset and shader paths identical
# to normal play while putting disposable binaries and PNGs under /tmp. Pass
# --video-report [output-directory] to also create an MP4 and Markdown report.
set -eu

if [ ! -f main.odin ] || [ ! -f replays/traversal-dash-smoke.json ]; then
    echo "error: run scripts/test-game.sh from the Lab0 repository root" >&2
    exit 2
fi

video_report=false
report_dir=""
replay_path="replays/traversal-dash-smoke.json"
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
        --replay)
            shift
            if [ "$#" -eq 0 ]; then
                echo "error: --replay requires a JSON path" >&2
                exit 2
            fi
            replay_path=$1
            shift
            ;;
        *)
            echo "usage: scripts/test-game.sh [--video-report [output-directory]] [--replay path.json]" >&2
            exit 2
            ;;
    esac
done

if [ ! -f "$replay_path" ]; then
    echo "error: replay does not exist: $replay_path" >&2
    exit 2
fi

run_id=$$
binary="/tmp/lab0-game-autotest-${run_id}"
output_dir="/tmp/lab0-game-autotest-${run_id}-captures"
capture_a="${output_dir}/dash-tick-5-a.png"
capture_b="${output_dir}/dash-tick-5-b.png"
log_a="${output_dir}/dash-tick-5-a.log"
log_b="${output_dir}/dash-tick-5-b.log"
unit_log="${output_dir}/odin-test.log"

if [ "$video_report" = true ] && [ -z "$report_dir" ]; then
    report_dir="artifacts/game-test-report-${run_id}"
fi
if [ "$video_report" = true ] && [ -e "$report_dir" ]; then
    echo "error: video report directory already exists: $report_dir" >&2
    exit 2
fi

mkdir -p "$output_dir"

echo "[1/4] Headless rules, scenario, replay, and invariant tests"
if odin test . >"$unit_log" 2>&1; then
    sed -n '1,200p' "$unit_log"
else
    sed -n '1,240p' "$unit_log" >&2
    exit 1
fi

echo "[2/4] Fresh game binary"
odin build . -out:"$binary"

echo "[3/4] Repeated replay capture at fixed tick 5"
"$binary" \
    --mode game \
    --game-replay "$replay_path" \
    --game-capture-tick 5 \
    --capture-case traversal-dash-tick-5-a \
    --capture-target composite \
    --capture-output "$capture_a" >"$log_a" 2>&1
"$binary" \
    --mode game \
    --game-replay "$replay_path" \
    --game-capture-tick 5 \
    --capture-case traversal-dash-tick-5-b \
    --capture-target composite \
    --capture-output "$capture_b" >"$log_b" 2>&1

if rg -q "WARNING: IMAGE|Game asset could not be loaded" "$log_a" "$log_b"; then
    echo "error: capture log contains an asset-image warning" >&2
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
echo "Game automation passed. Artifacts: $output_dir"

if [ "$video_report" = true ]; then
    if ! command -v ffmpeg >/dev/null 2>&1 ||
       ! command -v ffprobe >/dev/null 2>&1; then
        echo "error: --video-report requires ffmpeg and ffprobe" >&2
        exit 2
    fi

    frames_dir="${report_dir}/frames"
    recording_log="${report_dir}/recording.log"
    video_path="${report_dir}/game-test.mp4"
    contact_sheet="${report_dir}/contact-sheet.png"
    report_path="${report_dir}/report.md"
    mkdir -p "$frames_dir"

    echo "[video 1/4] Record every deterministic replay tick"
    "$binary" \
        --mode game \
        --game-replay "$replay_path" \
        --game-record-dir "$frames_dir" \
        --capture-case traversal-video-report \
        --capture-target composite >"$recording_log" 2>&1

    if rg -q "WARNING: IMAGE|Game asset could not be loaded" "$recording_log"; then
        echo "error: recording log contains an asset-image warning" >&2
        exit 1
    fi
    frame_count=$(find "$frames_dir" -type f -name 'frame-*.png' | wc -l | tr -d ' ')
    if [ "$frame_count" -le 0 ]; then
        echo "error: replay recording produced no PNG frames" >&2
        exit 1
    fi

    echo "[video 2/4] Encode review MP4"
    ffmpeg -hide_banner -loglevel error -y \
        -framerate 60 \
        -start_number 1 \
        -i "${frames_dir}/frame-%06d.png" \
        -c:v libx264 \
        -preset medium \
        -crf 18 \
        -pix_fmt yuv420p \
        -movflags +faststart \
        "$video_path"

    echo "[video 3/4] Build visual summary"
    sample_1=$((frame_count / 3))
    sample_2=$((frame_count * 2 / 3))
    sample_3=$((frame_count - 1))
    ffmpeg -hide_banner -loglevel error -y \
        -i "$video_path" \
        -vf "select='eq(n,0)+eq(n,${sample_1})+eq(n,${sample_2})+eq(n,${sample_3})',scale=360:-1,tile=4x1:padding=4:margin=4:color=202020" \
        -frames:v 1 \
        "$contact_sheet"

    video_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_path")
    video_dimensions=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$video_path")
    video_sha_line=$(shasum -a 256 "$video_path")
    video_sha=${video_sha_line%% *}
    test_summary=$(rg "Finished [0-9]+ tests" "$unit_log" | tail -n 1)
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    cp "$unit_log" "${report_dir}/odin-test.log"
    cp "$log_a" "${report_dir}/determinism-a.log"
    cp "$log_b" "${report_dir}/determinism-b.log"
    cp "$capture_a" "${report_dir}/dash-tick-5.png"

    {
        printf '# Lab0 automated game-test report\n\n'
        printf -- '- Result: **PASS**\n'
        printf -- '- Generated: `%s`\n' "$generated_at"
        printf -- '- Unit/scenario suite: `%s`\n' "$test_summary"
        printf -- '- Recorded replay: `%s`\n' "$replay_path"
        printf -- '- Video: `%s`, `%s seconds`, `%s frames at 60 fps`\n' "$video_dimensions" "$video_duration" "$frame_count"
        printf -- '- MP4 SHA-256: `%s`\n' "$video_sha"
        printf -- '- Fixed-tick PNG determinism: **byte-identical**\n'
        printf -- '- Asset image warnings: **none**\n\n'
        printf '[Open MP4](./game-test.mp4)\n\n'
        printf '![One-second interval contact sheet](./contact-sheet.png)\n\n'
        printf 'Detailed logs: [Odin tests](./odin-test.log), [recording](./recording.log), [capture A](./determinism-a.log), [capture B](./determinism-b.log).\n'
    } >"$report_path"

    echo "[video 4/4] Video report passed"
    echo "MP4: $video_path"
    echo "Preview: $contact_sheet"
    echo "Report: $report_path"
fi
