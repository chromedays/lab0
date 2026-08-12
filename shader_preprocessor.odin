package main

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Shader_Source_Dependency :: struct {
	path:              string,
	exists:            bool,
	modification_time: time.Time,
}

Preprocessed_Shader_Source :: struct {
	code:         string,
	dependencies: [dynamic]Shader_Source_Dependency,
}

destroy_preprocessed_shader_source :: proc(source: ^Preprocessed_Shader_Source) {
	delete(source.code)
	for dependency in source.dependencies {
		delete(dependency.path)
	}
	delete(source.dependencies)
	source^ = {}
}

shader_source_dependencies_changed :: proc(source: ^Preprocessed_Shader_Source) -> bool {
	for dependency in source.dependencies {
		info, err := os.stat(dependency.path, context.temp_allocator)
		exists := err == nil
		if exists != dependency.exists {
			return true
		}
		if exists && info.modification_time != dependency.modification_time {
			return true
		}
	}
	return false
}

track_shader_dependency :: proc(
	dependencies: ^[dynamic]Shader_Source_Dependency,
	path: string,
) {
	for dependency in dependencies^ {
		if dependency.path == path {
			return
		}
	}

	dependency := Shader_Source_Dependency{path = strings.clone(path)}
	if info, err := os.stat(path, context.temp_allocator); err == nil {
		dependency.exists = true
		dependency.modification_time = info.modification_time
	}
	append(dependencies, dependency)
}

parse_shader_include :: proc(line: string) -> (
	include_path: string,
	is_include: bool,
	valid: bool,
) {
	trimmed := strings.trim_space(line)
	keyword :: "#include"
	if !strings.has_prefix(trimmed, keyword) {
		return "", false, true
	}
	if len(trimmed) > len(keyword) {
		next := trimmed[len(keyword)]
		if next != ' ' && next != '\t' {
			return "", false, true
		}
	}

	remainder := strings.trim_space(trimmed[len(keyword):])
	if len(remainder) < 3 || remainder[0] != '"' {
		return "", true, false
	}

	closing_offset := strings.index_byte(remainder[1:], '"')
	if closing_offset < 0 {
		return "", true, false
	}
	closing_index := closing_offset + 1
	include_path = remainder[1:closing_index]
	trailing := strings.trim_space(remainder[closing_index + 1:])
	if include_path == "" || (trailing != "" && !strings.has_prefix(trailing, "//")) {
		return "", true, false
	}
	return include_path, true, true
}

preprocess_shader_file_recursive :: proc(
	path: string,
	builder: ^strings.Builder,
	dependencies: ^[dynamic]Shader_Source_Dependency,
	include_stack: ^[dynamic]string,
) -> bool {
	for active_path in include_stack^ {
		if active_path == path {
			log.error("Cyclic shader include detected at %s", path)
			return false
		}
	}

	track_shader_dependency(dependencies, path)
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		log.error("Failed to read shader source %s: %v", path, read_err)
		return false
	}
	defer delete(data)

	append(include_stack, path)
	defer pop(include_stack)

	contents := string(data)
	line_number := 0
	for line in strings.split_lines_iterator(&contents) {
		line_number += 1
		include_path, is_include, valid := parse_shader_include(line)
		if !is_include {
			strings.write_string(builder, line)
			strings.write_byte(builder, '\n')
			continue
		}
		if !valid {
			log.error("Malformed shader include in %s:%d", path, line_number)
			return false
		}

		include_candidate := include_path
		candidate_is_allocated := false
		if !filepath.is_abs(include_path) {
			joined_path, join_err := filepath.join({filepath.dir(path), include_path})
			if join_err != nil {
				log.error("Failed to resolve shader include %s from %s: %v", include_path, path, join_err)
				return false
			}
			include_candidate = joined_path
			candidate_is_allocated = true
		}

		resolved_path, clean_err := filepath.clean(include_candidate)
		if candidate_is_allocated {
			delete(include_candidate)
		}
		if clean_err != nil {
			log.error("Failed to normalize shader include %s from %s: %v", include_path, path, clean_err)
			return false
		}

		included_ok := preprocess_shader_file_recursive(
			resolved_path,
			builder,
			dependencies,
			include_stack,
		)
		delete(resolved_path)
		if !included_ok {
			return false
		}
	}
	return true
}

preprocess_shader_file :: proc(path: string) -> (
	source: Preprocessed_Shader_Source,
	ok: bool,
) {
	normalized_path, path_err := filepath.clean(path)
	if path_err != nil {
		log.error("Failed to normalize shader path %s: %v", path, path_err)
		return {}, false
	}
	defer delete(normalized_path)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	include_stack: [dynamic]string
	defer delete(include_stack)

	ok = preprocess_shader_file_recursive(
		normalized_path,
		&builder,
		&source.dependencies,
		&include_stack,
	)
	if ok {
		source.code = strings.clone(strings.to_string(builder))
	}
	return source, ok
}
