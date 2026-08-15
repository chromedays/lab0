package shared

// Video reports stream a normal composite RenderTexture directly to an ffmpeg
// child process. PNG capture remains a separate deterministic regression path;
// this module owns the shared lossy, human-reviewable MP4 transport plus the
// Game-specific option contract.

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rl "vendor:raylib"

VIDEO_STREAM_BYTES_PER_PIXEL      :: 4
VIDEO_STREAM_FFMPEG_COMMAND_COUNT :: 29

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

Video_Stream_Start_Error :: enum {
    NONE,
    OUTPUT_SETUP_FAILED,
    PIPE_FAILED,
    FFMPEG_NOT_FOUND,
    PROCESS_FAILED,
}

Video_Stream_Write_Error :: enum {
    NONE,
    ENCODER_NOT_RUNNING,
    TEXTURE_READBACK_FAILED,
    FRAME_SIZE_MISMATCH,
    PIXEL_FORMAT_FAILED,
    PIPE_WRITE_FAILED,
}

Video_Stream_Finish_Error :: enum {
    NONE,
    ENCODER_NOT_RUNNING,
    PIPE_CLOSE_FAILED,
    PROCESS_WAIT_FAILED,
    PROCESS_EXIT_FAILED,
    FRAME_COUNT_MISMATCH,
    OUTPUT_MISSING,
    OUTPUT_FINALIZE_FAILED,
}

// Video_Stream_Encoder owns the child process, pipe write end, and allocated
// temporary path. started/stdin make abort and deferred destruction idempotent
// across partial initialization failures.
Video_Stream_Encoder :: struct {
    process:        os.Process,
    stdin:          ^os.File,
    temporary_path: string,
    width:          int,
    height:         int,
    frames_per_second: int,
    frames_written: u64,
    started:        bool,
}

video_stream_output_path_is_valid :: proc(path: string) -> bool {
    return len(path) > len(".mp4") && strings.equal_fold(os.ext(path), ".mp4")
}

game_video_options_validate :: proc(
    run_options: ^Game_Run_Options,
    capture: ^Capture_Options,
) -> Game_Video_Options_Error {
    if len(run_options.video_output) == 0 {
        return .NONE
    }
    if !video_stream_output_path_is_valid(run_options.video_output) {
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
        return ""
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

video_stream_start_error_message :: proc(error: Video_Stream_Start_Error) -> string {
    switch error {
    case .NONE:
        return ""
    case .OUTPUT_SETUP_FAILED:
        return "video output could not be prepared"
    case .PIPE_FAILED:
        return "FFmpeg input pipe could not be prepared"
    case .FFMPEG_NOT_FOUND:
        return "FFmpeg was not found in PATH; install ffmpeg to create a video report"
    case .PROCESS_FAILED:
        return "FFmpeg process could not be started"
    }
    return "unknown video stream start error"
}

video_stream_write_error_message :: proc(error: Video_Stream_Write_Error) -> string {
    switch error {
    case .NONE:
        return ""
    case .ENCODER_NOT_RUNNING:
        return "video encoder is not running"
    case .TEXTURE_READBACK_FAILED:
        return "video texture could not be read from the GPU"
    case .FRAME_SIZE_MISMATCH:
        return "video frame dimensions do not match the encoder"
    case .PIXEL_FORMAT_FAILED:
        return "video frame could not be converted to RGBA8"
    case .PIPE_WRITE_FAILED:
        return "video frame could not be written to FFmpeg"
    }
    return "unknown video stream write error"
}

video_stream_finish_error_message :: proc(error: Video_Stream_Finish_Error) -> string {
    switch error {
    case .NONE:
        return ""
    case .ENCODER_NOT_RUNNING:
        return "video encoder is not running"
    case .PIPE_CLOSE_FAILED:
        return "FFmpeg input stream could not be closed"
    case .PROCESS_WAIT_FAILED:
        return "FFmpeg process could not be joined"
    case .PROCESS_EXIT_FAILED:
        return "FFmpeg exited unsuccessfully"
    case .FRAME_COUNT_MISMATCH:
        return "video frame count does not match the expected count"
    case .OUTPUT_MISSING:
        return "FFmpeg did not create a non-empty video"
    case .OUTPUT_FINALIZE_FAILED:
        return "video output could not be finalized"
    }
    return "unknown video stream finish error"
}

video_stream_frame_byte_count :: proc(width, height: int) -> int {
    if width <= 0 || height <= 0 {
        return 0
    }
    return width * height * VIDEO_STREAM_BYTES_PER_PIXEL
}

// The temporary name keeps incomplete files out of the final report path and
// preserves the .mp4 suffix so ffmpeg selects the correct muxer.
video_stream_temporary_output_path :: proc(output_path: string, run_id: int) -> string {
    base := output_path[:len(output_path) - len(".mp4")]
    return fmt.aprintf("%s.partial-%d.mp4", base, run_id)
}

video_stream_ffmpeg_command_build :: proc(
    temporary_path, video_size, frame_rate: string,
) -> [VIDEO_STREAM_FFMPEG_COMMAND_COUNT]string {
    return {
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-f", "rawvideo",
        "-pixel_format", "rgba",
        "-video_size", video_size,
        "-framerate", frame_rate,
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

video_stream_temporary_output_remove :: proc(encoder: ^Video_Stream_Encoder) {
    if len(encoder.temporary_path) > 0 && os.exists(encoder.temporary_path) {
        if remove_error := os.remove(encoder.temporary_path); remove_error != nil {
            log.warnf(
                "Failed to remove incomplete video %s: %v",
                encoder.temporary_path,
                remove_error,
            )
        }
    }
}

// Ignore SIGPIPE on POSIX so an early FFmpeg exit becomes an ordinary write
// error that can run cleanup instead of terminating Lab0 asynchronously.
video_stream_pipe_writes_prepare :: proc() -> Video_Stream_Start_Error {
    when ODIN_OS == .Windows {
        return .NONE
    } else {
        if posix.sigignore(.SIGPIPE) != .OK {
            return .PIPE_FAILED
        }
        return .NONE
    }
}

// Start FFmpeg without a shell and retain only the parent's write end. Frames
// are published to a sibling temporary MP4 until finish validates the process,
// frame count, and non-empty output.
video_stream_encoder_start :: proc(
    encoder: ^Video_Stream_Encoder,
    output_path: string,
    width, height, frames_per_second: int,
) -> Video_Stream_Start_Error {
    if !video_stream_output_path_is_valid(output_path) ||
       width <= 0 || height <= 0 || frames_per_second <= 0 {
        return .OUTPUT_SETUP_FAILED
    }
    if pipe_prepare_error := video_stream_pipe_writes_prepare();
       pipe_prepare_error != .NONE {
        return pipe_prepare_error
    }
    if capture_output_directory_ensure(output_path) != .NONE {
        return .OUTPUT_SETUP_FAILED
    }

    encoder.temporary_path = video_stream_temporary_output_path(
        output_path,
        os.get_pid(),
    )
    video_stream_temporary_output_remove(encoder)

    read_end, write_end, pipe_error := os.pipe()
    if pipe_error != nil {
        return .PIPE_FAILED
    }

    video_size := fmt.tprintf("%dx%d", width, height)
    frame_rate := fmt.tprintf("%d", frames_per_second)
    command := video_stream_ffmpeg_command_build(
        encoder.temporary_path,
        video_size,
        frame_rate,
    )
    process, process_error := os.process_start({
        command = command[:],
        stdin = read_end,
        stderr = os.stderr,
    })
    _ = os.close(read_end)
    if process_error != nil {
        _ = os.close(write_end)
        if process_error == .Not_Exist {
            return .FFMPEG_NOT_FOUND
        }
        return .PROCESS_FAILED
    }

    encoder.process = process
    encoder.stdin = write_end
    encoder.width = width
    encoder.height = height
    encoder.frames_per_second = frames_per_second
    encoder.started = true
    return .NONE
}

// Pipe writes may be short even without an error. Keep writing the remaining
// suffix; accepting zero bytes would otherwise spin forever on a broken sink.
video_stream_pipe_write_all :: proc(
    file: ^os.File,
    data: []byte,
) -> Video_Stream_Write_Error {
    if file == nil {
        return .ENCODER_NOT_RUNNING
    }
    bytes_written := 0
    for bytes_written < len(data) {
        count, write_error := os.write(file, data[bytes_written:])
        if count > 0 {
            bytes_written += count
        }
        if write_error != nil {
            return .PIPE_WRITE_FAILED
        }
        if count == 0 {
            return .PIPE_WRITE_FAILED
        }
    }
    return .NONE
}

// Read one texture and release its CPU image before returning. No frame queue
// is retained, so memory use is constant with respect to replay duration.
video_stream_encoder_write_render_texture :: proc(
    encoder: ^Video_Stream_Encoder,
    texture: rl.Texture2D,
) -> Video_Stream_Write_Error {
    if encoder == nil || !encoder.started || encoder.stdin == nil {
        return .ENCODER_NOT_RUNNING
    }
    texture_readback := rl.LoadImageFromTexture(texture)
    if texture_readback.data == nil {
        return .TEXTURE_READBACK_FAILED
    }
    defer rl.UnloadImage(texture_readback)

    if int(texture_readback.width) != encoder.width ||
       int(texture_readback.height) != encoder.height {
        return .FRAME_SIZE_MISMATCH
    }

    // RenderTexture readback is vertically inverted. Keep the raw pixels as-is
    // here and let FFmpeg's vflip filter correct the video orientation.
    rl.ImageFormat(&texture_readback, .UNCOMPRESSED_R8G8B8A8)
    if texture_readback.data == nil ||
       texture_readback.format != .UNCOMPRESSED_R8G8B8A8 {
        return .PIXEL_FORMAT_FAILED
    }

    frame_bytes := video_stream_frame_byte_count(
        int(texture_readback.width),
        int(texture_readback.height),
    )
    pixels := ([^]byte)(texture_readback.data)[:frame_bytes]
    if write_error := video_stream_pipe_write_all(encoder.stdin, pixels);
       write_error != .NONE {
        return write_error
    }
    encoder.frames_written += 1
    return .NONE
}

// Abort is safe after any start phase: close stdin, reap or kill the child, and
// remove the incomplete artifact without ever creating the final output name.
video_stream_encoder_abort :: proc(encoder: ^Video_Stream_Encoder) {
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
    video_stream_temporary_output_remove(encoder)
}

// Closing stdin is the end-of-stream signal that lets FFmpeg flush its muxer.
// Rename is deliberately last, making the final path a success-only commit.
video_stream_encoder_finish :: proc(
    encoder: ^Video_Stream_Encoder,
    output_path: string,
    expected_frames: u64,
    frame_kind: string,
) -> Video_Stream_Finish_Error {
    if encoder == nil || encoder.stdin == nil || !encoder.started {
        return .ENCODER_NOT_RUNNING
    }

    close_error := os.close(encoder.stdin)
    encoder.stdin = nil
    if close_error != nil {
        return .PIPE_CLOSE_FAILED
    }

    process_state, wait_error := os.process_wait(encoder.process)
    if wait_error != nil {
        return .PROCESS_WAIT_FAILED
    }
    encoder.started = false
    if !process_state.exited || process_state.exit_code != 0 {
        return .PROCESS_EXIT_FAILED
    }
    if encoder.frames_written != expected_frames {
        return .FRAME_COUNT_MISMATCH
    }

    file_info, stat_error := os.stat(
        encoder.temporary_path,
        context.temp_allocator,
    )
    if stat_error != nil || file_info.size <= 0 {
        return .OUTPUT_MISSING
    }
    if rename_error := os.rename(encoder.temporary_path, output_path);
       rename_error != nil {
        return .OUTPUT_FINALIZE_FAILED
    }
    return .NONE
}

video_stream_encoder_destroy :: proc(encoder: ^Video_Stream_Encoder) {
    video_stream_encoder_abort(encoder)
    if len(encoder.temporary_path) > 0 {
        delete(encoder.temporary_path)
    }
    encoder^ = {}
}
