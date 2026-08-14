package main

// Game video reports stream the normal composite RenderTexture directly to an
// ffmpeg child process. PNG capture remains a separate deterministic regression
// path; this module owns only the lossy, human-reviewable MP4 artifact.

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rl "vendor:raylib"

GAME_VIDEO_WIDTH                :: GAME_SCREEN_WIDTH
GAME_VIDEO_HEIGHT               :: GAME_SCREEN_HEIGHT
GAME_VIDEO_FRAMES_PER_SECOND    :: 60
GAME_VIDEO_BYTES_PER_PIXEL      :: 4
GAME_VIDEO_FFMPEG_COMMAND_COUNT :: 29

Game_Video_Options_Error :: enum {
    NONE,
    INVALID_OUTPUT,
    MISSING_REPLAY,
    MISSING_CAPTURE,
    INVALID_TARGET,
    CONFLICTING_RECORD_DIRECTORY,
    CONFLICTING_CAPTURE_TICK,
    CONFLICTING_CAPTURE_OUTPUT,
}

Game_Video_Start_Error :: enum {
    NONE,
    OUTPUT_SETUP_FAILED,
    PIPE_FAILED,
    FFMPEG_NOT_FOUND,
    PROCESS_FAILED,
}

Game_Video_Encoder :: struct {
    process:        os.Process,
    stdin:          ^os.File,
    temporary_path: string,
    frames_written: u64,
    started:        bool,
}

game_video_output_path_valid :: proc(path: string) -> bool {
    return len(path) > len(".mp4") && strings.equal_fold(os.ext(path), ".mp4")
}

validate_game_video_options :: proc(
    run_options: ^Game_Run_Options,
    capture: ^Capture_Options,
) -> Game_Video_Options_Error {
    if len(run_options.video_output) == 0 {
        return .NONE
    }
    if !game_video_output_path_valid(run_options.video_output) {
        return .INVALID_OUTPUT
    }
    if len(run_options.replay_path) == 0 {
        return .MISSING_REPLAY
    }
    if !capture.enabled {
        return .MISSING_CAPTURE
    }
    if capture.target != .COMPOSITE {
        return .INVALID_TARGET
    }
    if len(run_options.record_directory) > 0 {
        return .CONFLICTING_RECORD_DIRECTORY
    }
    if run_options.capture_tick_set {
        return .CONFLICTING_CAPTURE_TICK
    }
    if capture.output_path_explicit {
        return .CONFLICTING_CAPTURE_OUTPUT
    }
    return .NONE
}

game_video_options_error_message :: proc(error: Game_Video_Options_Error) -> string {
    switch error {
    case .NONE:
        return "no error"
    case .INVALID_OUTPUT:
        return "--game-video-output requires a non-empty .mp4 path"
    case .MISSING_REPLAY:
        return "--game-video-output requires --game-replay"
    case .MISSING_CAPTURE:
        return "--game-video-output requires --capture-case"
    case .INVALID_TARGET:
        return "--game-video-output supports only --capture-target composite"
    case .CONFLICTING_RECORD_DIRECTORY:
        return "--game-video-output cannot be combined with --game-record-dir"
    case .CONFLICTING_CAPTURE_TICK:
        return "--game-video-output cannot be combined with --game-capture-tick"
    case .CONFLICTING_CAPTURE_OUTPUT:
        return "--game-video-output cannot be combined with --capture-output"
    }
    return "unknown game video option error"
}

game_video_frame_byte_count :: proc(width, height: int) -> int {
    if width <= 0 || height <= 0 {
        return 0
    }
    return width * height * GAME_VIDEO_BYTES_PER_PIXEL
}

// The temporary name keeps incomplete files out of the final report path and
// preserves the .mp4 suffix so ffmpeg selects the correct muxer.
game_video_temporary_output_path :: proc(output_path: string, run_id: int) -> string {
    base := output_path[:len(output_path) - len(".mp4")]
    return fmt.aprintf("%s.partial-%d.mp4", base, run_id)
}

game_video_ffmpeg_command :: proc(temporary_path: string) -> [GAME_VIDEO_FFMPEG_COMMAND_COUNT]string {
    return {
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-f", "rawvideo",
        "-pixel_format", "rgba",
        "-video_size", "1280x720",
        "-framerate", "60",
        "-i", "pipe:0",
        "-vf", "vflip",
        "-an",
        "-c:v", "libx264",
        "-preset", "medium",
        "-crf", "18",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        "-y",
        temporary_path,
    }
}

game_video_remove_temporary_output :: proc(encoder: ^Game_Video_Encoder) {
    if len(encoder.temporary_path) > 0 && os.exists(encoder.temporary_path) {
        if remove_error := os.remove(encoder.temporary_path); remove_error != nil {
            log.warnf(
                "Failed to remove incomplete game video %s: %v",
                encoder.temporary_path,
                remove_error,
            )
        }
    }
}

game_video_prepare_pipe_writes :: proc() -> bool {
    when ODIN_OS == .Windows {
        return true
    } else {
        if posix.sigignore(.SIGPIPE) != .OK {
            log.error("Failed to ignore SIGPIPE for FFmpeg streaming")
            return false
        }
        return true
    }
}

start_game_video_encoder :: proc(
    encoder: ^Game_Video_Encoder,
    output_path: string,
) -> Game_Video_Start_Error {
    if !game_video_prepare_pipe_writes() {
        return .PIPE_FAILED
    }
    if !ensure_capture_output_directory(output_path) {
        return .OUTPUT_SETUP_FAILED
    }

    encoder.temporary_path = game_video_temporary_output_path(
        output_path,
        os.get_pid(),
    )
    game_video_remove_temporary_output(encoder)

    read_end, write_end, pipe_error := os.pipe()
    if pipe_error != nil {
        log.errorf("Failed to create FFmpeg input pipe: %v", pipe_error)
        return .PIPE_FAILED
    }

    command := game_video_ffmpeg_command(encoder.temporary_path)
    process, process_error := os.process_start({
        command = command[:],
        stdin = read_end,
        stderr = os.stderr,
    })
    _ = os.close(read_end)
    if process_error != nil {
        _ = os.close(write_end)
        if process_error == .Not_Exist {
            log.error("FFmpeg was not found in PATH; install ffmpeg to create a game video")
            return .FFMPEG_NOT_FOUND
        }
        log.errorf("Failed to start FFmpeg: %v", process_error)
        return .PROCESS_FAILED
    }

    encoder.process = process
    encoder.stdin = write_end
    encoder.started = true
    return .NONE
}

game_video_write_all :: proc(file: ^os.File, data: []byte) -> bool {
    bytes_written := 0
    for bytes_written < len(data) {
        count, write_error := os.write(file, data[bytes_written:])
        if count > 0 {
            bytes_written += count
        }
        if write_error != nil {
            log.errorf(
                "Failed to stream RGBA frame to FFmpeg after %d of %d bytes: %v",
                bytes_written,
                len(data),
                write_error,
            )
            return false
        }
        if count == 0 {
            log.errorf(
                "FFmpeg input pipe accepted 0 of %d remaining frame bytes",
                len(data) - bytes_written,
            )
            return false
        }
    }
    return true
}

game_video_write_render_texture :: proc(
    encoder: ^Game_Video_Encoder,
    texture: rl.Texture2D,
) -> bool {
    texture_readback := rl.LoadImageFromTexture(texture)
    if texture_readback.data == nil {
        log.error("Failed to read game video texture from the GPU")
        return false
    }
    defer rl.UnloadImage(texture_readback)

    if int(texture_readback.width) != GAME_VIDEO_WIDTH ||
       int(texture_readback.height) != GAME_VIDEO_HEIGHT {
        log.errorf(
            "Unexpected game video frame dimensions: %dx%d",
            int(texture_readback.width),
            int(texture_readback.height),
        )
        return false
    }

    // RenderTexture readback is vertically inverted. Keep the raw pixels as-is
    // here and let FFmpeg's vflip filter correct the video orientation.
    rl.ImageFormat(&texture_readback, .UNCOMPRESSED_R8G8B8A8)
    if texture_readback.data == nil ||
       texture_readback.format != .UNCOMPRESSED_R8G8B8A8 {
        log.error("Failed to convert game video frame to RGBA8")
        return false
    }

    frame_bytes := game_video_frame_byte_count(
        int(texture_readback.width),
        int(texture_readback.height),
    )
    pixels := ([^]byte)(texture_readback.data)[:frame_bytes]
    if !game_video_write_all(encoder.stdin, pixels) {
        return false
    }
    encoder.frames_written += 1
    return true
}

game_video_encoder_abort :: proc(encoder: ^Game_Video_Encoder) {
    if encoder.stdin != nil {
        _ = os.close(encoder.stdin)
        encoder.stdin = nil
    }
    if encoder.started {
        process_state, wait_error := os.process_wait(encoder.process, timeout = 0)
        if wait_error != nil || !process_state.exited {
            _ = os.process_kill(encoder.process)
            _, _ = os.process_wait(encoder.process)
        }
        encoder.started = false
    }
    game_video_remove_temporary_output(encoder)
}

finish_game_video_encoder :: proc(
    encoder: ^Game_Video_Encoder,
    output_path: string,
    expected_frames: u64,
) -> bool {
    if encoder.stdin == nil || !encoder.started {
        log.error("FFmpeg encoder was not running at video completion")
        return false
    }

    close_error := os.close(encoder.stdin)
    encoder.stdin = nil
    if close_error != nil {
        log.errorf("Failed to close FFmpeg input stream: %v", close_error)
        return false
    }

    process_state, wait_error := os.process_wait(encoder.process)
    if wait_error != nil {
        log.errorf("Failed while waiting for FFmpeg: %v", wait_error)
        return false
    }
    encoder.started = false
    if !process_state.exited || process_state.exit_code != 0 {
        log.errorf("FFmpeg exited with status %d", process_state.exit_code)
        return false
    }
    if encoder.frames_written != expected_frames {
        log.errorf(
            "Game video frame count mismatch: streamed %d, expected %d",
            int(encoder.frames_written),
            int(expected_frames),
        )
        return false
    }

    file_info, stat_error := os.stat(
        encoder.temporary_path,
        context.temp_allocator,
    )
    if stat_error != nil || file_info.size <= 0 {
        log.errorf(
            "FFmpeg did not create a non-empty MP4 at %s",
            encoder.temporary_path,
        )
        return false
    }
    if rename_error := os.rename(encoder.temporary_path, output_path);
       rename_error != nil {
        log.errorf(
            "Failed to finalize game video %s: %v",
            output_path,
            rename_error,
        )
        return false
    }

    log.infof(
        "Streamed %d fixed-tick frames through FFmpeg to %s",
        int(encoder.frames_written),
        output_path,
    )
    return true
}

destroy_game_video_encoder :: proc(encoder: ^Game_Video_Encoder) {
    game_video_encoder_abort(encoder)
    if len(encoder.temporary_path) > 0 {
        delete(encoder.temporary_path)
    }
    encoder^ = {}
}
