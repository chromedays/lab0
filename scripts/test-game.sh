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
capture_a="${output_dir}/determinism-a.png"
capture_b="${output_dir}/determinism-b.png"
log_a="${output_dir}/determinism-a.log"
log_b="${output_dir}/determinism-b.log"
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

run_determinism_check() {
    determinism_tick=$1
    "$binary" \
        --mode game \
        --game-replay "$replay_path" \
        --game-capture-tick "$determinism_tick" \
        --capture-case replay-determinism-a \
        --capture-target composite \
        --capture-output "$capture_a" >"$log_a" 2>&1
    "$binary" \
        --mode game \
        --game-replay "$replay_path" \
        --game-capture-tick "$determinism_tick" \
        --capture-case replay-determinism-b \
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

    cmp -s "$capture_a" "$capture_b"
    shasum -a 256 "$capture_a" "$capture_b"
}

if [ "$video_report" = false ]; then
    echo "[3/4] Repeated replay capture at fixed tick 5"
    run_determinism_check 5
    echo "[4/4] Byte determinism passed"
    echo "Game automation passed. Artifacts: $output_dir"
fi

if [ "$video_report" = true ]; then
    if ! command -v ffmpeg >/dev/null 2>&1 ||
       ! command -v ffprobe >/dev/null 2>&1; then
        echo "error: --video-report requires ffmpeg and ffprobe" >&2
        exit 2
    fi

    recording_log="${report_dir}/recording.log"
    video_path="${report_dir}/game-test.mp4"
    contact_sheet="${report_dir}/contact-sheet.png"
    report_path="${report_dir}/report.md"
    mkdir -p "$report_dir"

    echo "[video 1/4] Stream every deterministic replay tick to FFmpeg"
    if "$binary" \
        --mode game \
        --game-replay "$replay_path" \
        --game-video-output "$video_path" \
        --capture-case traversal-video-report \
        --capture-target composite >"$recording_log" 2>&1; then
        :
    else
        sed -n '1,240p' "$recording_log" >&2
        exit 1
    fi

    if rg -q "WARNING: IMAGE|Game asset could not be loaded" "$recording_log"; then
        echo "error: recording log contains an asset-image warning" >&2
        exit 1
    fi
    if [ -d "${report_dir}/frames" ]; then
        echo "error: streaming video report unexpectedly created a frames directory" >&2
        exit 1
    fi
    streamed_frame_count=$(rg -o "Streamed [0-9]+ fixed-tick frames" "$recording_log" | tail -n 1 | rg -o '[0-9]+' || true)
    case "$streamed_frame_count" in
        ''|*[!0-9]*) echo "error: recording log has no streamed frame count" >&2; exit 1 ;;
    esac
    if [ "$streamed_frame_count" -le 0 ]; then
        echo "error: replay streamed no video frames" >&2
        exit 1
    fi

    total_metric=$(rg '^GAME_REPLAY_TOTAL_METRIC ' "$recording_log" | tail -n 1 || true)
    if [ -z "$total_metric" ]; then
        echo "error: recording log has no replay completion metrics" >&2
        exit 1
    fi
    metric_value() {
        metric_key=$1
        printf '%s\n' "$total_metric" | awk -v key="$metric_key" '{
            for (field_index = 2; field_index <= NF; field_index += 1) {
                split($field_index, pair, "=")
                if (pair[1] == key) {
                    print pair[2]
                    exit
                }
            }
        }'
    }
    replay_completed=$(metric_value completed)
    completion_tick=$(metric_value completion_tick)
    completion_seconds=$(metric_value completion_seconds)
    total_dashes=$(metric_value dashes)
    total_hits=$(metric_value hits)
    total_resets=$(metric_value resets)
    determinism_tick=$streamed_frame_count
    if [ "$replay_completed" = true ] && [ "$completion_tick" -gt 0 ]; then
        determinism_tick=$completion_tick
    fi

    echo "[video 2/4] Repeated deterministic capture at tick $determinism_tick"
    run_determinism_check "$determinism_tick"

    video_dimensions=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$video_path")
    video_frame_rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$video_path")
    frame_count=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 "$video_path")
    video_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_path")
    if [ "$video_dimensions" != "1280x720" ]; then
        echo "error: unexpected video dimensions: $video_dimensions" >&2
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

    echo "[video 3/4] Build visual summary and room metrics"
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
    png_sha_line=$(shasum -a 256 "$capture_a")
    png_sha=${png_sha_line%% *}
    test_summary=$(rg "Finished [0-9]+ tests" "$unit_log" | tail -n 1)
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    room_metrics_markdown="${output_dir}/room-metrics.md"
    awk '
        $1 == "GAME_REPLAY_ROOM_METRIC" {
            for (field_index = 2; field_index <= NF; field_index += 1) {
                split($field_index, pair, "=")
                value[pair[1]] = pair[2]
            }
            printf "| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` |\n", \
                value["code"], value["ticks"], value["seconds"], \
                value["dashes"], value["hits"], value["resets"]
        }
    ' "$recording_log" >"$room_metrics_markdown"
    if [ ! -s "$room_metrics_markdown" ]; then
        echo "error: recording log has no per-room replay metrics" >&2
        exit 1
    fi

    cp "$unit_log" "${report_dir}/odin-test.log"
    cp "$log_a" "${report_dir}/determinism-a.log"
    cp "$log_b" "${report_dir}/determinism-b.log"
    cp "$capture_a" "${report_dir}/deterministic-completion.png"

    {
        printf '# Lab0 automated game-test report\n\n'
        printf -- '- Result: **PASS**\n'
        printf -- '- Generated: `%s`\n' "$generated_at"
        printf -- '- Unit/scenario suite: `%s`\n' "$test_summary"
        printf -- '- Recorded replay: `%s`\n' "$replay_path"
        printf -- '- Video encoding: `raw RGBA streamed through FFmpeg stdin`\n'
        printf -- '- Replay fixed ticks: `%s`\n' "$streamed_frame_count"
        printf -- '- Video: `%s`, `%s seconds`, `%s frames at 60 fps`\n' "$video_dimensions" "$video_duration" "$frame_count"
        printf -- '- MP4 SHA-256: `%s`\n' "$video_sha"
        printf -- '- Replay completed: **%s**\n' "$replay_completed"
        printf -- '- Total completion time: **%s seconds** at tick `%s`\n' "$completion_seconds" "$completion_tick"
        printf -- '- Totals: `%s dashes`, `%s hits`, `%s resets`\n' "$total_dashes" "$total_hits" "$total_resets"
        printf -- '- Fixed-tick PNG determinism at tick `%s`: **byte-identical**\n' "$determinism_tick"
        printf -- '- Deterministic PNG SHA-256: `%s`\n' "$png_sha"
        printf -- '- Asset image warnings: **none**\n\n'
        printf '## Per-room completion metrics\n\n'
        printf '| Room | Ticks | Seconds | Dashes | Hits | Resets |\n'
        printf '| --- | ---: | ---: | ---: | ---: | ---: |\n'
        sed -n '1,120p' "$room_metrics_markdown"
        printf '\nTicks are charged to the room active at the start of each fixed update and stop at the first completed tick.\n\n'
        printf '[Open MP4](./game-test.mp4)\n\n'
        printf '[Open deterministic completion PNG](./deterministic-completion.png)\n\n'
        printf '![Route-quartile contact sheet](./contact-sheet.png)\n\n'
        printf 'Detailed logs: [Odin tests](./odin-test.log), [recording](./recording.log), [capture A](./determinism-a.log), [capture B](./determinism-b.log).\n'
    } >"$report_path"

    echo "[video 4/4] Streaming video report passed"
    echo "MP4: $video_path"
    echo "Preview: $contact_sheet"
    echo "Report: $report_path"
fi
