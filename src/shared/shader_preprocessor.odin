package shared

// This module expands local #include directives before handing GLSL source to
// raylib. It also records every transitive dependency so the interactive viewer
// can hot-reload a shader when any included file changes.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Shader_Source_Dependency snapshots existence and modification time at load.
// Missing files are tracked too, allowing their later creation to trigger reload.
Shader_Source_Dependency :: struct {
	path:              string,
	exists:            bool,
	modification_time: time.Time,
}

// Preprocessed_Shader_Source owns expanded code and cloned dependency paths.
Preprocessed_Shader_Source :: struct {
	code:         string,
	dependencies: [dynamic]Shader_Source_Dependency,
}

// Preprocessed_Shader_Program_Source groups independently expanded shader stages.
Preprocessed_Shader_Program_Source :: struct {
	vertex:   Preprocessed_Shader_Source,
	fragment: Preprocessed_Shader_Source,
}

// destroy_preprocessed_shader_source releases expanded code, cloned paths, and
// dynamic storage, then clears the value to make repeated destruction harmless.
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

// destroy_preprocessed_shader_program_source destroys both program stages.
destroy_preprocessed_shader_program_source :: proc(
	preprocessed_program: ^Preprocessed_Shader_Program_Source,
) {
	destroy_preprocessed_shader_source(&preprocessed_program.vertex)
	destroy_preprocessed_shader_source(&preprocessed_program.fragment)
}

// shader_source_dependencies_changed compares current file metadata with the
// load snapshot. Either an existence transition or mtime change requests reload.
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

// preprocess_shader_file_recursive appends one expanded file to output_builder.
// include_stack detects cycles, while dependencies deduplicates files reached by
// multiple branches. All file buffers and temporary normalized paths are owned
// within the recursion level that created them.
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

	// Track this dependency inline while avoiding duplicates from shared includes.
	dependency_already_tracked := false
	for dependency in dependencies^ {
		if dependency.path == path {
			dependency_already_tracked = true
			break
		}
	}
	if !dependency_already_tracked {
		dependency := Shader_Source_Dependency{
			path = strings.clone(path),
		}
		if file_info, stat_error := os.stat(
			path,
			context.temp_allocator,
		); stat_error == nil {
			dependency.exists = true
			dependency.modification_time = file_info.modification_time
		}
		append(dependencies, dependency)
	}
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

		// Parse include syntax inline before recursively expanding the line.
		include_path: string
		is_include := false
		include_is_valid := true
		trimmed := strings.trim_space(line)
		keyword :: "#include"
		if strings.has_prefix(trimmed, keyword) {
			directive_has_separator := len(trimmed) == len(keyword)
			if len(trimmed) > len(keyword) {
				directive_separator := trimmed[len(keyword)]
				directive_has_separator = directive_separator == ' ' ||
				                          directive_separator == '\t'
			}
			if directive_has_separator {
				is_include = true
				remainder := strings.trim_space(trimmed[len(keyword):])
				if len(remainder) < 3 || remainder[0] != '"' {
					include_is_valid = false
				} else {
					closing_offset := strings.index_byte(remainder[1:], '"')
					if closing_offset < 0 {
						include_is_valid = false
					} else {
						closing_index := closing_offset + 1
						include_path = remainder[1:closing_index]
						trailing := strings.trim_space(
							remainder[closing_index + 1:],
						)
						include_is_valid = include_path != "" &&
							(trailing == "" || strings.has_prefix(trailing, "//"))
					}
				}
			}
		}
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

// preprocess_shader_file normalizes the root path, initializes recursion state,
// and returns owned expanded source even when dependency data accompanies a
// preprocessing failure for later cleanup.
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
