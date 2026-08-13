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

Preprocessed_Shader_Program_Source :: struct {
	vertex:   Preprocessed_Shader_Source,
	fragment: Preprocessed_Shader_Source,
}

destroy_preprocessed_shader_source :: proc(
	preprocessed_source: ^Preprocessed_Shader_Source,
) {
	delete(preprocessed_source.code)
	for dependency in preprocessed_source.dependencies {
		delete(dependency.path)
	}
	delete(preprocessed_source.dependencies)
	preprocessed_source^ = {}
}

destroy_preprocessed_shader_program_source :: proc(
	preprocessed_program: ^Preprocessed_Shader_Program_Source,
) {
	destroy_preprocessed_shader_source(&preprocessed_program.vertex)
	destroy_preprocessed_shader_source(&preprocessed_program.fragment)
}

shader_source_dependencies_changed :: proc(
	preprocessed_source: ^Preprocessed_Shader_Source,
) -> bool {
	for dependency in preprocessed_source.dependencies {
		file_info, stat_error := os.stat(
			dependency.path,
			context.temp_allocator,
		)
		dependency_exists := stat_error == nil
		if dependency_exists != dependency.exists {
			return true
		}
		if dependency_exists &&
		   file_info.modification_time != dependency.modification_time {
			return true
		}
	}
	return false
}

shader_program_source_dependencies_changed :: proc(
	preprocessed_program: ^Preprocessed_Shader_Program_Source,
) -> bool {
	return shader_source_dependencies_changed(&preprocessed_program.vertex) ||
	       shader_source_dependencies_changed(&preprocessed_program.fragment)
}

track_shader_dependency :: proc(
	dependencies: ^[dynamic]Shader_Source_Dependency,
	dependency_path: string,
) {
	for dependency in dependencies^ {
		if dependency.path == dependency_path {
			return
		}
	}

	dependency := Shader_Source_Dependency{
		path = strings.clone(dependency_path),
	}
	if file_info, stat_error := os.stat(
		dependency_path,
		context.temp_allocator,
	); stat_error == nil {
		dependency.exists = true
		dependency.modification_time = file_info.modification_time
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
		directive_separator := trimmed[len(keyword)]
		if directive_separator != ' ' && directive_separator != '\t' {
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
	output_builder: ^strings.Builder,
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
	shader_source_bytes, read_error := os.read_entire_file(
		path,
		context.allocator,
	)
	if read_error != nil {
		log.error("Failed to read shader source %s: %v", path, read_error)
		return false
	}
	defer delete(shader_source_bytes)

	append(include_stack, path)
	defer pop(include_stack)

	shader_contents := string(shader_source_bytes)
	line_number := 0
	for line in strings.split_lines_iterator(&shader_contents) {
		line_number += 1
		include_path, is_include, include_is_valid := parse_shader_include(line)
		if !is_include {
			strings.write_string(output_builder, line)
			strings.write_byte(output_builder, '\n')
			continue
		}
		if !include_is_valid {
			log.error("Malformed shader include in %s:%d", path, line_number)
			return false
		}

		include_candidate := include_path
		include_candidate_is_owned := false
		if !filepath.is_abs(include_path) {
			joined_path, join_error := filepath.join({filepath.dir(path), include_path})
			if join_error != nil {
				log.error(
					"Failed to resolve shader include %s from %s: %v",
					include_path,
					path,
					join_error,
				)
				return false
			}
			include_candidate = joined_path
			include_candidate_is_owned = true
		}

		resolved_path, normalization_error := filepath.clean(include_candidate)
		if include_candidate_is_owned {
			delete(include_candidate)
		}
		if normalization_error != nil {
			log.error(
				"Failed to normalize shader include %s from %s: %v",
				include_path,
				path,
				normalization_error,
			)
			return false
		}

		include_preprocessing_succeeded := preprocess_shader_file_recursive(
			resolved_path,
			output_builder,
			dependencies,
			include_stack,
		)
		delete(resolved_path)
		if !include_preprocessing_succeeded {
			return false
		}
	}
	return true
}

preprocess_shader_file :: proc(path: string) -> (
	preprocessed_source: Preprocessed_Shader_Source,
	preprocessing_succeeded: bool,
) {
	normalized_path, normalization_error := filepath.clean(path)
	if normalization_error != nil {
		log.error(
			"Failed to normalize shader path %s: %v",
			path,
			normalization_error,
		)
		return {}, false
	}
	defer delete(normalized_path)

	output_builder := strings.builder_make()
	defer strings.builder_destroy(&output_builder)
	include_stack: [dynamic]string
	defer delete(include_stack)

	preprocessing_succeeded = preprocess_shader_file_recursive(
		normalized_path,
		&output_builder,
		&preprocessed_source.dependencies,
		&include_stack,
	)
	if preprocessing_succeeded {
		preprocessed_source.code = strings.clone(
			strings.to_string(output_builder),
		)
	}
	return preprocessed_source, preprocessing_succeeded
}

preprocess_shader_program :: proc(vertex_path, fragment_path: string) -> (
	preprocessed_program: Preprocessed_Shader_Program_Source,
	preprocessing_succeeded: bool,
) {
	vertex_preprocessing_succeeded, fragment_preprocessing_succeeded: bool
	preprocessed_program.vertex, vertex_preprocessing_succeeded =
		preprocess_shader_file(vertex_path)
	preprocessed_program.fragment, fragment_preprocessing_succeeded =
		preprocess_shader_file(fragment_path)
	return preprocessed_program,
	       vertex_preprocessing_succeeded && fragment_preprocessing_succeeded
}
