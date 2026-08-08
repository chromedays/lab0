package main

import "core:fmt"
import "core:os"
import "core:time"
import "core:log"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"
import mu "vendor:microui"
// import cgltf "vendor:cgltf"

Vertex :: struct {
    pos: [3]f32,
    color: [4]f32,
}

FS_PATH :: "shaders/custom.fs"
GLB_PATH :: "assets/Meshy_AI_lowpoly_man_rigged_biped_Meshy_AI_Meshy_Merged_Animations.glb"

// inspect_glb :: proc(path: string) -> bool {
//     options := cgltf.options{}
//     path_cstr := strings.clone_to_cstring(path, context.temp_allocator);

//     data, parse_result := cgltf.parse_file(options, path_cstr);
//     if parse_result != .success {
//         log.error("Failed to parse GLB file: ", path);
//         return false;
//     }
//     defer cgltf.free(data);

//     load_result := cgltf.load_buffers(options, data, path_cstr);
//     if load_result != .success {
//         log.error("Failed to load buffers for GLB file: ", path);
//         return false;
//     }

//     validate_result := cgltf.validate(data);
//     if validate_result != .success {
//         log.error("Failed to validate GLB file: ", path);
//         return false;
//     }

//     log.info("Successfully loaded and validated GLB file: ", path);
//     log.info("=== glb inspection result ===");
//     log.info("meshes:     ", len(data.meshes));
//     log.info("materials:  ", len(data.materials));
//     log.info("textures:   ", len(data.textures));
//     log.info("images:     ", len(data.images));
//     log.info("nodes:      ", len(data.nodes));
//     log.info("skins:      ", len(data.skins));
//     log.info("animations: ", len(data.animations));

//     return true;
// }

import "core:c"

get_file_mod_time :: proc(filepath: string) -> (mod_time: time.Time, ok: bool) {
    info, err := os.stat(filepath, context.temp_allocator);
    if err != nil {
        log.error("Error occurred while fetching file info for %s: %v", filepath, err);
        return {}, false;
    }
    return info.modification_time, true;
}

render_microui :: proc(muctx: ^mu.Context, atlas_texture: rl.Texture2D) {
	cmd: ^mu.Command
	for mu.next_command(muctx, &cmd) {
		#partial switch variant in cmd.variant {
		case ^mu.Command_Rect:
			rl.DrawRectangle(
				variant.rect.x, variant.rect.y,
				variant.rect.w, variant.rect.h,
				rl.Color{variant.color.r, variant.color.g, variant.color.b, variant.color.a},
			)
		case ^mu.Command_Text:
			pos := [2]i32{variant.pos.x, variant.pos.y}
			for ch in variant.str {
				r := min(int(ch), 127)
				rect := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + r]
				rl.DrawTextureRec(
					atlas_texture,
					rl.Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)},
					rl.Vector2{f32(pos.x), f32(pos.y)},
					rl.Color{variant.color.r, variant.color.g, variant.color.b, variant.color.a},
				)
				pos.x += rect.w
			}
		case ^mu.Command_Icon:
			rect := mu.default_atlas[int(variant.id)]
			x := variant.rect.x + (variant.rect.w - rect.w) / 2
			y := variant.rect.y + (variant.rect.h - rect.h) / 2
			rl.DrawTextureRec(
				atlas_texture,
				rl.Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)},
				rl.Vector2{f32(x), f32(y)},
				rl.Color{variant.color.r, variant.color.g, variant.color.b, variant.color.a},
			)
		case ^mu.Command_Clip:
			rl.EndScissorMode()
			rl.BeginScissorMode(variant.rect.x, variant.rect.y, variant.rect.w, variant.rect.h)
		}
	}
	rl.EndScissorMode()
}

handle_microui_input :: proc(muctx: ^mu.Context) {
	buf := make([]byte, 1024 * 10, context.temp_allocator)
	text_len := 0
	for {
		ch := rl.GetCharPressed()
		if ch == 0 do break
		bytes, width := utf8.encode_rune(ch)
		if text_len + width <= len(buf) {
			copy(buf[text_len:], bytes[:width])
			text_len += width
		} else {
			break
		}
	}
	if text_len > 0 {
		mu.input_text(muctx, string(buf[:text_len]))
	}

	mouse_x := rl.GetMouseX()
	mouse_y := rl.GetMouseY()
	mu.input_mouse_move(muctx, mouse_x, mouse_y)
	mu.input_scroll(muctx, 0, i32(rl.GetMouseWheelMove()) * -30)

	buttons := [?]struct {
		rl_btn: rl.MouseButton,
		mu_btn: mu.Mouse,
	}{
		{.LEFT, .LEFT},
		{.RIGHT, .RIGHT},
		{.MIDDLE, .MIDDLE},
	}
	for b in buttons {
		if rl.IsMouseButtonPressed(b.rl_btn) {
			mu.input_mouse_down(muctx, mouse_x, mouse_y, b.mu_btn)
		} else if rl.IsMouseButtonReleased(b.rl_btn) {
			mu.input_mouse_up(muctx, mouse_x, mouse_y, b.mu_btn)
		}
	}

	keys := [?]struct {
		rl_key: rl.KeyboardKey,
		mu_key: mu.Key,
	}{
		{.LEFT_SHIFT, .SHIFT}, {.RIGHT_SHIFT, .SHIFT},
		{.LEFT_CONTROL, .CTRL}, {.RIGHT_CONTROL, .CTRL},
		{.LEFT_ALT, .ALT}, {.RIGHT_ALT, .ALT},
		{.ENTER, .RETURN}, {.KP_ENTER, .RETURN},
		{.BACKSPACE, .BACKSPACE},
	}
	for k in keys {
		if rl.IsKeyPressed(k.rl_key) {
			mu.input_key_down(muctx, k.mu_key)
		} else if rl.IsKeyReleased(k.rl_key) {
			mu.input_key_up(muctx, k.mu_key)
		}
	}
}

main :: proc() {
    logger := log.create_console_logger()
    defer log.destroy_console_logger(logger)
    context.logger = logger

    rl.SetTraceLogLevel(.WARNING);
    // inspect_glb(GLB_PATH);

    rl.SetConfigFlags({.WINDOW_TOPMOST});
    rl.InitWindow(800, 600, "Lab0");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    arena: mem.Arena;
    mem.arena_init(&arena, make([]byte, 1024 * 1024 * 10)); // 10 MB arena
    defer delete(arena.data);

    arena_allocator := mem.arena_allocator(&arena);

    muctx := new(mu.Context, arena_allocator);
    defer free(muctx, arena_allocator);
    mu.init(muctx);
    muctx.text_width = mu.default_atlas_text_width;
    muctx.text_height = mu.default_atlas_text_height;

    // Setup microui default atlas texture
    pixels := make([][4]u8, mu.DEFAULT_ATLAS_WIDTH * mu.DEFAULT_ATLAS_HEIGHT, context.temp_allocator)
    for alpha, i in mu.default_atlas_alpha {
        pixels[i] = {255, 255, 255, alpha}
    }
    atlas_image := rl.Image {
        data    = raw_data(pixels),
        width   = mu.DEFAULT_ATLAS_WIDTH,
        height  = mu.DEFAULT_ATLAS_HEIGHT,
        mipmaps = 1,
        format  = .UNCOMPRESSED_R8G8B8A8,
    }
    atlas_texture := rl.LoadTextureFromImage(atlas_image)
    defer rl.UnloadTexture(atlas_texture)

    fs_last_time, ok := get_file_mod_time(FS_PATH);
    shader := rl.LoadShader(nil, FS_PATH);
    u_time_loc := rl.GetShaderLocation(shader, "u_time");
    defer rl.UnloadShader(shader);
    assert(ok);
    log.info("Initial fragment shader modification time: %s", fs_last_time);

    model := rl.LoadModel(GLB_PATH);
    // log.info(rl.IsModelValid(model));
    // assert(rl.IsModelValid(model));
    defer rl.UnloadModel(model);

	bounds := rl.GetModelBoundingBox(model);
	log.infof("Model bounding box: min(%f, %f, %f), max(%f, %f, %f)", bounds.min.x, bounds.min.y, bounds.min.z, bounds.max.x, bounds.max.y, bounds.max.z);
	center := rl.Vector3{
		bounds.min.x + (bounds.max.x - bounds.min.x) * 0.5,
		bounds.min.y + (bounds.max.y - bounds.min.y) * 0.5,
		bounds.min.z + (bounds.max.z - bounds.min.z) * 0.5,
	}
	size := rl.Vector3{
		bounds.max.x - bounds.min.x,
		bounds.max.y - bounds.min.y,
		bounds.max.z - bounds.min.z,
	}
	max_size := max(size.x, max(size.y, size.z));
	camera := rl.Camera3D{
		target = center,
		position = {center.x + max_size * 1.5, center.y + max_size * 0.7, center.z + max_size * 1.5},
		up = {0, 1, 0},
		fovy = 45,
		projection = .PERSPECTIVE,
	}

    animation_count: i32
    animations := rl.LoadModelAnimations(GLB_PATH, &animation_count);
    assert(animations != nil);
    defer rl.UnloadModelAnimations(animations, animation_count);

    for !rl.WindowShouldClose() {

        handle_microui_input(muctx)

        if rl.IsWindowFocused() {
            rl.SetWindowOpacity(1.0);
        } else {
            rl.SetWindowOpacity(0.5);
        }

        mu.begin(muctx);

        // if mu.window(muctx, "In-Game Text Editor", {50, 50, 500, 350}) {
		// }

        mu.end(muctx);

        fs_curr_time, ok := get_file_mod_time(FS_PATH);
        assert(ok);
        if fs_curr_time != fs_last_time {
            log.info("Fragment shader modified at: %s", fs_curr_time);
            fs_last_time = fs_curr_time;

            new_shader := rl.LoadShader(nil, FS_PATH);
            if rl.IsShaderValid(new_shader) {
                rl.UnloadShader(shader);
                shader = new_shader;
                u_time_loc = rl.GetShaderLocation(shader, "u_time");
            } else {
                log.error("Failed to reload shader. Keeping the old shader.");
                rl.UnloadShader(new_shader);
            }
        }

        time_val := f32(rl.GetTime());
        rl.SetShaderValue(shader, u_time_loc, &time_val, .FLOAT);

        rl.BeginDrawing();
            rl.ClearBackground(rl.GRAY);
            rl.BeginShaderMode(shader);
                rl.DrawRectangle(20, 20, 60, 60, rl.RED);
            rl.EndShaderMode();

			rl.BeginMode3D(camera);
				// rl.DrawModel(model, rl.Vector3{0, 0, 0}, 1.0, rl.WHITE);
				rl.DrawModelWires(model, rl.Vector3{0, 0, 0}, 1.0, rl.YELLOW);
			rl.EndMode3D()

            render_microui(muctx, atlas_texture)
        rl.EndDrawing();
    }
}