package contacts

import "core:fmt"
import "core:os"
import "core:strings"

import address "barev:internal/address"

Error :: enum {
	None,
	Read,
	Write,
	Parse,
}

destroy_all :: proc(records: ^[dynamic]address.Endpoint) {
	for &record in records {
		address.destroy_endpoint(&record)
	}
	delete(records^)
	records^ = nil
}

load :: proc(path: string) -> (records: [dynamic]address.Endpoint, err: Error) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return nil, .Read
	}
	defer delete(data)
	records = make([dynamic]address.Endpoint)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' {
			continue
		}
		endpoint, parse_err := address.parse_endpoint(trimmed)
		if parse_err != .None {
			destroy_all(&records)
			return nil, .Parse
		}
		append(&records, endpoint)
	}
	return records, .None
}

save :: proc(path: string, records: []address.Endpoint) -> Error {
	builder := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "# barev-odin contacts\n")
	for record in records {
		formatted := address.format_endpoint(record, include_default_port=true, allocator=context.temp_allocator)
		strings.write_string(&builder, formatted)
		strings.write_byte(&builder, '\n')
	}
	temporary := fmt.aprintf("%s.tmp.%d", path, os.get_pid())
	defer delete(temporary)
	if write_err := os.write_entire_file(temporary, strings.to_string(builder)); write_err != nil {
		return .Write
	}
	if rename_err := os.rename(temporary, path); rename_err != nil {
		_ = os.remove(temporary)
		return .Write
	}
	return .None
}
