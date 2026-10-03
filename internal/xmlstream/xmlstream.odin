package xmlstream

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

DEFAULT_MAX_BUFFER :: 1 << 20
DEFAULT_MAX_STANZA :: 256 << 10
MAX_DEPTH :: 64
MAX_ATTRIBUTES :: 64

Error :: enum {
	None,
	Buffer_Limit,
	Stanza_Limit,
	Malformed,
	Forbidden_Declaration,
	Depth_Limit,
	Attribute_Limit,
	Invalid_UTF8,
	Closed,
	Failed,
}

Event_Kind :: enum {
	Stream_Start,
	Stanza,
	Stream_End,
}

Event :: struct {
	kind: Event_Kind,
	name: string,
	namespace: string,
	xml:  string,
}

Parser :: struct {
	buffer:      [dynamic]u8,
	max_buffer:  int,
	max_stanza:  int,
	stream_open: bool,
	closed:      bool,
	failed:      bool,
	default_namespace: string,
	stream_namespace:  string,
	allocator:         runtime.Allocator,
}

Name_Range :: struct {
	start: int,
	end:   int,
}

init :: proc(parser: ^Parser, max_buffer := DEFAULT_MAX_BUFFER, max_stanza := DEFAULT_MAX_STANZA, allocator := context.allocator) {
	parser^ = {
		buffer = make([dynamic]u8, 0, min(max_buffer, 4096), allocator),
		max_buffer = max_buffer,
		max_stanza = max_stanza,
		allocator = allocator,
	}
}

destroy :: proc(parser: ^Parser) {
	delete(parser.default_namespace, parser.allocator)
	delete(parser.stream_namespace, parser.allocator)
	delete(parser.buffer)
	parser^ = {}
}

destroy_events :: proc(events: ^[dynamic]Event) {
	for &event in events {
		delete(event.name)
		delete(event.namespace)
		delete(event.xml)
	}
	delete(events^)
	events^ = nil
}

is_space :: proc(byte: u8) -> bool {
	return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n'
}

is_name_byte :: proc(byte: u8) -> bool {
	return byte >= 'a' && byte <= 'z' || byte >= 'A' && byte <= 'Z' || byte >= '0' && byte <= '9' || byte == ':' || byte == '_' || byte == '-' || byte == '.'
}

is_name_start :: proc(byte: u8) -> bool {
	return byte >= 'a' && byte <= 'z' || byte >= 'A' && byte <= 'Z' || byte == '_'
}

starts_with :: proc(data: []u8, at: int, value: string) -> bool {
	bytes := transmute([]u8)value
	if at < 0 || at + len(bytes) > len(data) {
		return false
	}
	for byte, i in bytes {
		if data[at + i] != byte {
			return false
		}
	}
	return true
}

find_sequence :: proc(data: []u8, at: int, value: string) -> int {
	for i := at; i + len(value) <= len(data); i += 1 {
		if starts_with(data, i, value) {
			return i
		}
	}
	return -1
}

find_tag_end :: proc(data: []u8, at: int) -> (end: int, complete: bool, err: Error) {
	quote: u8
	for i := at + 1; i < len(data); i += 1 {
		byte := data[i]
		if quote != 0 {
			if byte == quote {
				quote = 0
			}
			continue
		}
		if byte == '\'' || byte == '\"' {
			quote = byte
		} else if byte == '>' {
			return i, true, .None
		} else if byte == '<' {
			return 0, false, .Malformed
		}
	}
	return 0, false, .None
}

tag_name :: proc(data: []u8, at, end: int) -> (name: Name_Range, closing: bool, err: Error) {
	i := at + 1
	if i < end && data[i] == '/' {
		closing = true
		i += 1
	}
	start := i
	if i >= end || !is_name_start(data[i]) {
		err = .Malformed
		return
	}
	for i < end && is_name_byte(data[i]) {
		i += 1
	}
	if i == start {
		err = .Malformed
		return
	}
	name = {start=start, end=i}
	return
}

validate_tag_attributes :: proc(data: []u8, name: Name_Range, closing: bool, end: int) -> Error {
	i := name.end
	if closing {
		for i < end && is_space(data[i]) {
			i += 1
		}
		if i != end {
			return .Malformed
		}
		return .None
	}
	names: [MAX_ATTRIBUTES]Name_Range
	count := 0
	for {
		for i < end && is_space(data[i]) {
			i += 1
		}
		if i == end {
			return .None
		}
		if data[i] == '/' {
			if i + 1 == end {
				return .None
			}
			return .Malformed
		}
		if count == MAX_ATTRIBUTES || !is_name_start(data[i]) {
			if count == MAX_ATTRIBUTES {
				return .Attribute_Limit
			}
			return .Malformed
		}
		start := i
		for i < end && is_name_byte(data[i]) {
			i += 1
		}
		attribute_name := Name_Range{start=start, end=i}
		for previous in names[:count] {
			if same_name(data, previous, attribute_name) {
				return .Malformed
			}
		}
		names[count] = attribute_name
		count += 1
		for i < end && is_space(data[i]) {
			i += 1
		}
		if i >= end || data[i] != '=' {
			return .Malformed
		}
		i += 1
		for i < end && is_space(data[i]) {
			i += 1
		}
		if i >= end || data[i] != '\'' && data[i] != '\"' {
			return .Malformed
		}
		quote := data[i]
		i += 1
		for i < end && data[i] != quote {
			if data[i] == '<' {
				return .Malformed
			}
			if data[i] == '&' {
				next, ok := valid_entity(data, i, end)
				if !ok {
					return .Malformed
				}
				i = next
				continue
			}
			i += 1
		}
		if i >= end {
			return .Malformed
		}
		i += 1
		if i < end && !is_space(data[i]) && data[i] != '/' {
			return .Malformed
		}
	}
}

attribute_value :: proc(data: []u8, name: Name_Range, end: int, wanted: string) -> (value: string, found: bool) {
	i := name.end
	for i < end {
		for i < end && is_space(data[i]) {
			i += 1
		}
		if i >= end || data[i] == '/' {
			return
		}
		start := i
		for i < end && is_name_byte(data[i]) {
			i += 1
		}
		attribute_name := string(data[start:i])
		for i < end && is_space(data[i]) {
			i += 1
		}
		i += 1
		for i < end && is_space(data[i]) {
			i += 1
		}
		quote := data[i]
		i += 1
		value_start := i
		for i < end && data[i] != quote {
			i += 1
		}
		if attribute_name == wanted {
			return string(data[value_start:i]), true
		}
		i += 1
	}
	return
}

local_name :: proc(qualified: string) -> string {
	if colon := strings.last_index(qualified, ":"); colon >= 0 {
		return qualified[colon + 1:]
	}
	return qualified
}

prefix_name :: proc(qualified: string) -> string {
	if colon := strings.last_index(qualified, ":"); colon >= 0 {
		return qualified[:colon]
	}
	return ""
}

same_name :: proc(data: []u8, left, right: Name_Range) -> bool {
	if left.end - left.start != right.end - right.start {
		return false
	}
	for i in 0 ..< left.end - left.start {
		if data[left.start + i] != data[right.start + i] {
			return false
		}
	}
	return true
}

self_closing :: proc(data: []u8, at, end: int) -> bool {
	i := end - 1
	for i > at && is_space(data[i]) {
		i -= 1
	}
	return data[i] == '/'
}

valid_entity :: proc(data: []u8, at, end: int) -> (next: int, ok: bool) {
	semi := at + 1
	for semi < end && semi - at <= 16 && data[semi] != ';' {
		semi += 1
	}
	if semi >= end || data[semi] != ';' {
		return at, false
	}
	body := data[at + 1:semi]
	if len(body) == 2 && body[0] == 'l' && body[1] == 't' ||
	   len(body) == 2 && body[0] == 'g' && body[1] == 't' ||
	   len(body) == 3 && body[0] == 'a' && body[1] == 'm' && body[2] == 'p' ||
	   len(body) == 4 && body[0] == 'q' && body[1] == 'u' && body[2] == 'o' && body[3] == 't' ||
	   len(body) == 4 && body[0] == 'a' && body[1] == 'p' && body[2] == 'o' && body[3] == 's' {
		return semi + 1, true
	}
	if len(body) >= 2 && body[0] == '#' {
		start := 1
		hex := false
		if len(body) >= 3 && (body[1] == 'x' || body[1] == 'X') {
			start = 2
			hex = true
		}
		if start >= len(body) {
			return at, false
		}
		for byte in body[start:] {
			decimal_digit := byte >= '0' && byte <= '9'
			hex_digit := decimal_digit || byte >= 'a' && byte <= 'f' || byte >= 'A' && byte <= 'F'
			if hex && !hex_digit || !hex && !decimal_digit {
				return at, false
			}
		}
		return semi + 1, true
	}
	return at, false
}

scan_stanza :: proc(data: []u8, start, max_stanza: int) -> (finish: int, complete: bool, err: Error) {
	stack: [MAX_DEPTH]Name_Range
	depth := 0
	i := start
	for i < len(data) {
		if i - start > max_stanza {
			return 0, false, .Stanza_Limit
		}
		if data[i] == '&' {
			next, ok := valid_entity(data, i, len(data))
			if !ok {
				if find_sequence(data, i, ";") < 0 && len(data) - i <= 16 {
					return 0, false, .None
				}
				return 0, false, .Malformed
			}
			i = next
			continue
		}
		if data[i] != '<' {
			i += 1
			continue
		}
		if starts_with(data, i, "<!") || starts_with(data, i, "<?") {
			return 0, false, .Forbidden_Declaration
		}
		end, tag_complete, tag_err := find_tag_end(data, i)
		if tag_err != .None {
			return 0, false, tag_err
		}
		if !tag_complete {
			return 0, false, .None
		}
		name, closing, name_err := tag_name(data, i, end)
		if name_err != .None {
			return 0, false, name_err
		}
		if attribute_err := validate_tag_attributes(data, name, closing, end); attribute_err != .None {
			return 0, false, attribute_err
		}
		if closing {
			if depth == 0 || !same_name(data, stack[depth - 1], name) {
				return 0, false, .Malformed
			}
			depth -= 1
		} else if !self_closing(data, i, end) {
			if depth == MAX_DEPTH {
				return 0, false, .Depth_Limit
			}
			stack[depth] = name
			depth += 1
		}
		i = end + 1
		if depth == 0 {
			return i, true, .None
		}
	}
	if len(data) - start > max_stanza {
		return 0, false, .Stanza_Limit
	}
	return 0, false, .None
}

append_event :: proc(events: ^[dynamic]Event, kind: Event_Kind, data: []u8, name: Name_Range, namespace: string, start, finish: int) {
	name_value := strings.clone(local_name(string(data[name.start:name.end])))
	namespace_value := strings.clone(namespace)
	xml_value := strings.clone(string(data[start:finish]))
	append(events, Event{kind=kind, name=name_value, namespace=namespace_value, xml=xml_value})
}

feed_internal :: proc(parser: ^Parser, data: []u8, events: ^[dynamic]Event) -> Error {
	if parser.closed {
		return .Closed
	}
	if len(parser.buffer) + len(data) > parser.max_buffer {
		return .Buffer_Limit
	}
	append(&parser.buffer, ..data)
	consumed := 0
	for {
		i := consumed
		for i < len(parser.buffer) && is_space(parser.buffer[i]) {
			i += 1
		}
		if i == len(parser.buffer) {
			consumed = i
			break
		}
		if starts_with(parser.buffer[:], i, "<?xml") {
			end := find_sequence(parser.buffer[:], i + 5, "?>")
			if end < 0 {
				break
			}
			consumed = end + 2
			continue
		}
		if starts_with(parser.buffer[:], i, "<!") {
			return .Forbidden_Declaration
		}
		if parser.stream_open && starts_with(parser.buffer[:], i, "</stream:stream>") {
			name := Name_Range{start=i + 2, end=i + 15}
			finish := i + len("</stream:stream>")
			append_event(events, .Stream_End, parser.buffer[:], name, parser.stream_namespace, i, finish)
			parser.stream_open = false
			parser.closed = true
			consumed = finish
			break
		}
		end, tag_complete, tag_err := find_tag_end(parser.buffer[:], i)
		if tag_err != .None {
			return tag_err
		}
		if !tag_complete {
			break
		}
		name, closing, name_err := tag_name(parser.buffer[:], i, end)
		if name_err != .None || closing {
			return .Malformed
		}
		if attribute_err := validate_tag_attributes(parser.buffer[:], name, closing, end); attribute_err != .None {
			return attribute_err
		}
		name_text := string(parser.buffer[name.start:name.end])
		if name_text == "stream:stream" {
			if parser.stream_open || self_closing(parser.buffer[:], i, end) {
				return .Malformed
			}
			default_namespace, default_found := attribute_value(parser.buffer[:], name, end, "xmlns")
			stream_namespace, stream_found := attribute_value(parser.buffer[:], name, end, "xmlns:stream")
			if !default_found || !stream_found || strings.contains(default_namespace, "&") || strings.contains(stream_namespace, "&") {
				return .Malformed
			}
			parser.default_namespace = strings.clone(default_namespace, parser.allocator)
			parser.stream_namespace = strings.clone(stream_namespace, parser.allocator)
			if !utf8.valid_string(string(parser.buffer[i:end + 1])) {
				return .Invalid_UTF8
			}
			append_event(events, .Stream_Start, parser.buffer[:], name, parser.stream_namespace, i, end + 1)
			parser.stream_open = true
			consumed = end + 1
			continue
		}
		if !parser.stream_open {
			return .Malformed
		}
		finish, complete, stanza_err := scan_stanza(parser.buffer[:], i, parser.max_stanza)
		if stanza_err != .None {
			return stanza_err
		}
		if !complete {
			break
		}
		if !utf8.valid_string(string(parser.buffer[i:finish])) {
			return .Invalid_UTF8
		}
		qualified_name := string(parser.buffer[name.start:name.end])
		namespace := parser.default_namespace
		if prefix := prefix_name(qualified_name); len(prefix) > 0 {
			wanted := fmt.aprintf("xmlns:%s", prefix, allocator=context.temp_allocator)
			if declared, found := attribute_value(parser.buffer[:], name, end, wanted); found {
				namespace = declared
			} else if prefix == "stream" {
				namespace = parser.stream_namespace
			} else {
				return .Malformed
			}
		} else if declared, found := attribute_value(parser.buffer[:], name, end, "xmlns"); found {
			namespace = declared
		}
		append_event(events, .Stanza, parser.buffer[:], name, namespace, i, finish)
		consumed = finish
	}
	if consumed > 0 {
		remaining := len(parser.buffer) - consumed
		copy(parser.buffer[:remaining], parser.buffer[consumed:])
		resize(&parser.buffer, remaining)
	}
	if len(parser.buffer) > parser.max_stanza {
		return .Stanza_Limit
	}
	return .None
}

feed :: proc(parser: ^Parser, data: []u8, events: ^[dynamic]Event) -> Error {
	if parser.failed {
		return .Failed
	}
	err := feed_internal(parser, data, events)
	if err != .None && err != .Closed {
		parser.failed = true
	}
	return err
}

validate_stanza :: proc(xml: string, max_stanza := DEFAULT_MAX_STANZA) -> Error {
	if !utf8.valid_string(xml) {
		return .Invalid_UTF8
	}
	data := transmute([]u8)xml
	if len(data) == 0 || data[0] != '<' {
		return .Malformed
	}
	finish, complete, err := scan_stanza(data, 0, max_stanza)
	if err != .None {
		return err
	}
	if !complete || finish != len(data) {
		return .Malformed
	}
	return .None
}

top_level_attribute :: proc(xml, wanted: string) -> (value: string, found: bool, err: Error) {
	data := transmute([]u8)xml
	if len(data) == 0 || data[0] != '<' {
		return "", false, .Malformed
	}
	end, complete, tag_err := find_tag_end(data, 0)
	if tag_err != .None || !complete {
		if tag_err == .None {
			tag_err = .Malformed
		}
		return "", false, tag_err
	}
	name, closing, name_err := tag_name(data, 0, end)
	if name_err != .None || closing {
		return "", false, .Malformed
	}
	if attribute_err := validate_tag_attributes(data, name, false, end); attribute_err != .None {
		return "", false, attribute_err
	}
	value, found = attribute_value(data, name, end, wanted)
	return value, found, .None
}
