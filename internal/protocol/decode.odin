package protocol

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import xmlstream "barev:internal/xmlstream"

LEGACY_PING_NAMESPACE :: "urn:yggb:ping"

Decode_Error :: enum {
	None,
	Malformed_XML,
	Invalid_Entity,
	Missing_Namespace,
}

Stanza_Kind :: enum {
	Unknown,
	Message,
	Presence,
	IQ,
}

IQ_Type :: enum {
	Unknown,
	Get,
	Set,
	Result,
	Error,
}

Message_Stanza :: struct {
	from:         string,
	to:           string,
	message_type: string,
	body:         string,
	body_present: bool,
	xhtml:        string,
	chat_state:   Chat_State,
}

Presence_Stanza :: struct {
	from:        string,
	to:          string,
	presence:    Presence,
	show:        string,
	status:      string,
	unavailable: bool,
	avatar_update: bool,
	avatar_hash: string,
}

IQ_Stanza :: struct {
	from:           string,
	to:             string,
	id:             string,
	iq_type:        IQ_Type,
	ping:           bool,
	ping_namespace: string,
	vcard:          bool,
	vcard_mime:     string,
	vcard_data:     string,
	si:             bool,
	si_id:          string,
	file_name:      string,
	file_size:      i64,
	bytestream:     bool,
	bytestream_sid: string,
	streamhost_jid: string,
	streamhost_host: string,
	streamhost_port: u16,
	streamhost_used: bool,
}

Stanza :: struct {
	kind:      Stanza_Kind,
	name:      string,
	namespace: string,
	message:   Message_Stanza,
	presence:  Presence_Stanza,
	iq:        IQ_Stanza,
}

destroy_stanza :: proc(stanza: ^Stanza, allocator := context.allocator) {
	delete(stanza.name, allocator)
	delete(stanza.namespace, allocator)
	delete(stanza.message.from, allocator)
	delete(stanza.message.to, allocator)
	delete(stanza.message.message_type, allocator)
	delete(stanza.message.body, allocator)
	delete(stanza.message.xhtml, allocator)
	delete(stanza.presence.from, allocator)
	delete(stanza.presence.to, allocator)
	delete(stanza.presence.show, allocator)
	delete(stanza.presence.status, allocator)
	delete(stanza.presence.avatar_hash, allocator)
	delete(stanza.iq.from, allocator)
	delete(stanza.iq.to, allocator)
	delete(stanza.iq.id, allocator)
	delete(stanza.iq.ping_namespace, allocator)
	delete(stanza.iq.vcard_mime, allocator)
	delete(stanza.iq.vcard_data, allocator)
	delete(stanza.iq.si_id, allocator)
	delete(stanza.iq.file_name, allocator)
	delete(stanza.iq.bytestream_sid, allocator)
	delete(stanza.iq.streamhost_jid, allocator)
	delete(stanza.iq.streamhost_host, allocator)
	stanza^ = {}
}

valid_xml_rune :: proc(value: rune) -> bool {
	return value == 0x9 || value == 0xa || value == 0xd ||
	       value >= 0x20 && value <= 0xd7ff ||
	       value >= 0xe000 && value <= 0xfffd ||
	       value >= 0x10000 && value <= 0x10ffff
}

unescape :: proc(value: string, allocator := context.allocator) -> (decoded: string, err: Decode_Error) {
	if !utf8.valid_string(value) {
		return "", .Malformed_XML
	}
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	bytes := transmute([]u8)value
	for i := 0; i < len(bytes); {
		if bytes[i] != '&' {
			strings.write_byte(&builder, bytes[i])
			i += 1
			continue
		}
		semi := i + 1
		for semi < len(bytes) && semi - i <= 16 && bytes[semi] != ';' {
			semi += 1
		}
		if semi >= len(bytes) || bytes[semi] != ';' {
			return "", .Invalid_Entity
		}
		entity := string(bytes[i + 1:semi])
		switch entity {
		case "lt":   strings.write_byte(&builder, '<')
		case "gt":   strings.write_byte(&builder, '>')
		case "amp":  strings.write_byte(&builder, '&')
		case "quot": strings.write_byte(&builder, '\"')
		case "apos": strings.write_byte(&builder, '\'')
		case:
			base := 10
			digits := entity
			if strings.has_prefix(entity, "#x") || strings.has_prefix(entity, "#X") {
				base = 16
				digits = entity[2:]
			} else if strings.has_prefix(entity, "#") {
				digits = entity[1:]
			} else {
				return "", .Invalid_Entity
			}
			codepoint, ok := strconv.parse_int(digits, base)
			if !ok || !valid_xml_rune(rune(codepoint)) {
				return "", .Invalid_Entity
			}
			strings.write_rune(&builder, rune(codepoint))
		}
		i = semi + 1
	}
	return strings.clone(strings.to_string(builder), allocator), .None
}

decoded_attribute :: proc(data: []u8, name: xmlstream.Name_Range, end: int, wanted: string, allocator: runtime.Allocator) -> (value: string, found: bool, err: Decode_Error) {
	raw, present := xmlstream.attribute_value(data, name, end, wanted)
	if !present {
		return "", false, .None
	}
	value, err = unescape(raw, allocator)
	return value, true, err
}

namespace_for :: proc(data: []u8, name: xmlstream.Name_Range, end: int, parent_default: string, root_name: xmlstream.Name_Range, root_end: int, allocator: runtime.Allocator) -> (namespace: string, err: Decode_Error) {
	qualified := string(data[name.start:name.end])
	prefix := xmlstream.prefix_name(qualified)
	if len(prefix) == 0 {
		if declared, found, decode_err := decoded_attribute(data, name, end, "xmlns", allocator); decode_err != .None {
			return "", decode_err
		} else if found {
			return declared, .None
		}
		return strings.clone(parent_default, allocator), .None
	}
	wanted := fmt.aprintf("xmlns:%s", prefix, allocator=context.temp_allocator)
	if declared, found, decode_err := decoded_attribute(data, name, end, wanted, allocator); decode_err != .None {
		return "", decode_err
	} else if found {
		return declared, .None
	}
	if root_name.end > root_name.start {
		if declared, found, decode_err := decoded_attribute(data, root_name, root_end, wanted, allocator); decode_err != .None {
			return "", decode_err
		} else if found {
			return declared, .None
		}
	}
	return "", .Missing_Namespace
}

element_text :: proc(data: []u8, start, opening_end, finish: int, allocator: runtime.Allocator) -> (text: string, err: Decode_Error) {
	if xmlstream.self_closing(data, start, opening_end) {
		return strings.clone("", allocator), .None
	}
	closing := finish - 1
	for closing > opening_end && data[closing] != '<' {
		closing -= 1
	}
	if closing <= opening_end {
		return "", .Malformed_XML
	}
	for byte in data[opening_end + 1:closing] {
		if byte == '<' {
			return "", .Malformed_XML
		}
	}
	return unescape(string(data[opening_end + 1:closing]), allocator)
}

iq_type_from_string :: proc(value: string) -> IQ_Type {
	switch value {
	case "get":    return .Get
	case "set":    return .Set
	case "result": return .Result
	case "error":  return .Error
	case:           return .Unknown
	}
}

presence_from_show :: proc(show: string) -> Presence {
	switch show {
	case "away": return .Away
	case "xa":   return .Extended_Away
	case "dnd":  return .Busy
	case:         return .Available
	}
}

direct_child_range :: proc(data: []u8, opening_end, finish: int, wanted: string) -> (start, child_opening_end, child_finish: int, found: bool) {
	position := opening_end + 1
	for position < finish {
		for position < finish && xmlstream.is_space(data[position]) {
			position += 1
		}
		if position >= finish || data[position] != '<' || position + 1 < finish && data[position + 1] == '/' {
			return
		}
		end, _, tag_err := xmlstream.find_tag_end(data, position)
		if tag_err != .None {
			return
		}
		name, closing, name_err := xmlstream.tag_name(data, position, end)
		if name_err != .None || closing {
			return
		}
		child_end, complete, scan_err := xmlstream.scan_stanza(data, position, finish)
		if scan_err != .None || !complete {
			return
		}
		if xmlstream.local_name(string(data[name.start:name.end])) == wanted {
			return position, end, child_end, true
		}
		position = child_end
	}
	return
}

direct_child_text :: proc(data: []u8, opening_end, finish: int, wanted: string, allocator: runtime.Allocator) -> (text: string, found: bool, err: Decode_Error) {
	start, child_opening_end, child_finish, present := direct_child_range(data, opening_end, finish, wanted)
	if !present {
		return "", false, .None
	}
	text, err = element_text(data, start, child_opening_end, child_finish, allocator)
	return text, true, err
}

decode_stanza :: proc(xml: string, inherited_namespace := CLIENT_NAMESPACE, max_stanza := xmlstream.DEFAULT_MAX_STANZA, allocator := context.allocator) -> (stanza: Stanza, err: Decode_Error) {
	if xml_err := xmlstream.validate_stanza(xml, max_stanza); xml_err != .None {
		return {}, .Malformed_XML
	}
	data := transmute([]u8)xml
	root_end, _, root_end_err := xmlstream.find_tag_end(data, 0)
	if root_end_err != .None {
		return {}, .Malformed_XML
	}
	root_name, root_closing, root_name_err := xmlstream.tag_name(data, 0, root_end)
	if root_name_err != .None || root_closing {
		return {}, .Malformed_XML
	}
	qualified := string(data[root_name.start:root_name.end])
	stanza.name = strings.clone(xmlstream.local_name(qualified), allocator)
	stanza.namespace, err = namespace_for(data, root_name, root_end, inherited_namespace, {}, 0, allocator)
	if err != .None {
		destroy_stanza(&stanza, allocator)
		return {}, err
	}
	if stanza.namespace == CLIENT_NAMESPACE {
		switch stanza.name {
		case "message":  stanza.kind = .Message
		case "presence": stanza.kind = .Presence
		case "iq":       stanza.kind = .IQ
		case:             stanza.kind = .Unknown
		}
	}

	switch stanza.kind {
	case .Message:
		stanza.message.from, _, err = decoded_attribute(data, root_name, root_end, "from", allocator)
		if err == .None {
			stanza.message.to, _, err = decoded_attribute(data, root_name, root_end, "to", allocator)
		}
		if err == .None {
			stanza.message.message_type, _, err = decoded_attribute(data, root_name, root_end, "type", allocator)
		}
	case .Presence:
		stanza.presence.from, _, err = decoded_attribute(data, root_name, root_end, "from", allocator)
		if err == .None {
			stanza.presence.to, _, err = decoded_attribute(data, root_name, root_end, "to", allocator)
		}
		presence_type: string
		if err == .None {
			presence_type, _, err = decoded_attribute(data, root_name, root_end, "type", context.temp_allocator)
		}
		if presence_type == "unavailable" {
			stanza.presence.unavailable = true
			stanza.presence.presence = .Offline
		} else {
			stanza.presence.presence = .Available
		}
	case .IQ:
		stanza.iq.from, _, err = decoded_attribute(data, root_name, root_end, "from", allocator)
		if err == .None {
			stanza.iq.to, _, err = decoded_attribute(data, root_name, root_end, "to", allocator)
		}
		if err == .None {
			stanza.iq.id, _, err = decoded_attribute(data, root_name, root_end, "id", allocator)
		}
		iq_type_text: string
		if err == .None {
			iq_type_text, _, err = decoded_attribute(data, root_name, root_end, "type", context.temp_allocator)
			stanza.iq.iq_type = iq_type_from_string(iq_type_text)
		}
	case .Unknown:
	}
	if err != .None {
		destroy_stanza(&stanza, allocator)
		return {}, err
	}
	if xmlstream.self_closing(data, 0, root_end) {
		return stanza, .None
	}

	position := root_end + 1
	for position < len(data) {
		for position < len(data) && xmlstream.is_space(data[position]) {
			position += 1
		}
		if position >= len(data) || data[position] != '<' {
			destroy_stanza(&stanza, allocator)
			return {}, .Malformed_XML
		}
		if position + 1 < len(data) && data[position + 1] == '/' {
			break
		}
		child_end, _, child_tag_err := xmlstream.find_tag_end(data, position)
		if child_tag_err != .None {
			destroy_stanza(&stanza, allocator)
			return {}, .Malformed_XML
		}
		child_name, child_closing, child_name_err := xmlstream.tag_name(data, position, child_end)
		if child_name_err != .None || child_closing {
			destroy_stanza(&stanza, allocator)
			return {}, .Malformed_XML
		}
		finish, complete, child_scan_err := xmlstream.scan_stanza(data, position, len(data))
		if child_scan_err != .None || !complete {
			destroy_stanza(&stanza, allocator)
			return {}, .Malformed_XML
		}
		child_namespace, namespace_err := namespace_for(data, child_name, child_end, stanza.namespace, root_name, root_end, context.temp_allocator)
		if namespace_err != .None {
			destroy_stanza(&stanza, allocator)
			return {}, namespace_err
		}
		child_local := xmlstream.local_name(string(data[child_name.start:child_name.end]))
		if stanza.kind == .Message && child_local == "body" && child_namespace == CLIENT_NAMESPACE && !stanza.message.body_present {
			stanza.message.body, err = element_text(data, position, child_end, finish, allocator)
			stanza.message.body_present = err == .None
		} else if stanza.kind == .Message && child_local == "html" && child_namespace == XHTML_NAMESPACE && len(stanza.message.xhtml) == 0 {
			stanza.message.xhtml = strings.clone(string(data[position:finish]), allocator)
		} else if stanza.kind == .Message && child_namespace == CHAT_STATE_NAMESPACE {
			stanza.message.chat_state = chat_state_from_name(child_local)
		} else if stanza.kind == .Message && child_local == "x" && child_namespace == LEGACY_EVENT_NAMESPACE {
			_, _, _, composing := direct_child_range(data, child_end, finish, "composing")
			if composing {
				stanza.message.chat_state = .Composing
			}
		} else if stanza.kind == .Presence && child_namespace == CLIENT_NAMESPACE {
			if child_local == "show" && len(stanza.presence.show) == 0 {
				stanza.presence.show, err = element_text(data, position, child_end, finish, allocator)
				if err == .None && !stanza.presence.unavailable {
					stanza.presence.presence = presence_from_show(stanza.presence.show)
				}
			} else if child_local == "status" && len(stanza.presence.status) == 0 {
				stanza.presence.status, err = element_text(data, position, child_end, finish, allocator)
			}
		} else if stanza.kind == .Presence && child_local == "x" && child_namespace == VCARD_UPDATE_NAMESPACE {
			stanza.presence.avatar_hash, stanza.presence.avatar_update, err = direct_child_text(data, child_end, finish, "photo", allocator)
		} else if stanza.kind == .IQ && child_local == "ping" && (child_namespace == PING_NAMESPACE || child_namespace == LEGACY_PING_NAMESPACE) {
			stanza.iq.ping = true
			stanza.iq.ping_namespace = strings.clone(child_namespace, allocator)
		} else if stanza.kind == .IQ && child_local == "vCard" && child_namespace == VCARD_NAMESPACE {
			stanza.iq.vcard = true
			photo_start, photo_opening_end, photo_finish, has_photo := direct_child_range(data, child_end, finish, "PHOTO")
			_ = photo_start
			if has_photo {
				stanza.iq.vcard_mime, _, err = direct_child_text(data, photo_opening_end, photo_finish, "TYPE", allocator)
				if err == .None {
					stanza.iq.vcard_data, _, err = direct_child_text(data, photo_opening_end, photo_finish, "BINVAL", allocator)
				}
			}
		} else if stanza.kind == .IQ && child_local == "si" && child_namespace == SI_NAMESPACE {
			stanza.iq.si = true
			stanza.iq.si_id, _, err = decoded_attribute(data, child_name, child_end, "id", allocator)
			file_start, file_opening_end, _, has_file := direct_child_range(data, child_end, finish, "file")
			if err == .None && has_file {
				file_name, _, file_name_err := xmlstream.tag_name(data, file_start, file_opening_end)
				if file_name_err != .None {
					err = .Malformed_XML
				} else {
					stanza.iq.file_name, _, err = decoded_attribute(data, file_name, file_opening_end, "name", allocator)
					if err == .None {
						size_text, found_size, size_err := decoded_attribute(data, file_name, file_opening_end, "size", context.temp_allocator)
						parsed_size, size_ok := strconv.parse_int(size_text, 10)
						if size_err != .None || !found_size || !size_ok || parsed_size < 0 {
							err = .Malformed_XML
						} else {
							stanza.iq.file_size = i64(parsed_size)
						}
					}
				}
			}
		} else if stanza.kind == .IQ && child_local == "query" && child_namespace == BYTESTREAMS_NAMESPACE {
			stanza.iq.bytestream = true
			stanza.iq.bytestream_sid, _, err = decoded_attribute(data, child_name, child_end, "sid", allocator)
			stream_start, stream_opening_end, _, has_streamhost := direct_child_range(data, child_end, finish, "streamhost")
			used_start, used_opening_end, _, has_used := direct_child_range(data, child_end, finish, "streamhost-used")
			if err == .None && has_streamhost {
				stream_name, _, stream_name_err := xmlstream.tag_name(data, stream_start, stream_opening_end)
				if stream_name_err != .None {
					err = .Malformed_XML
				} else {
					stanza.iq.streamhost_jid, _, err = decoded_attribute(data, stream_name, stream_opening_end, "jid", allocator)
					if err == .None {
						stanza.iq.streamhost_host, _, err = decoded_attribute(data, stream_name, stream_opening_end, "host", allocator)
					}
					if err == .None {
						port_text, found_port, port_err := decoded_attribute(data, stream_name, stream_opening_end, "port", context.temp_allocator)
						parsed_port, port_ok := strconv.parse_int(port_text, 10)
						if port_err != .None || !found_port || !port_ok || parsed_port < 1 || parsed_port > 65535 {
							err = .Malformed_XML
						} else {
							stanza.iq.streamhost_port = u16(parsed_port)
						}
					}
				}
			} else if err == .None && has_used {
				used_name, _, used_name_err := xmlstream.tag_name(data, used_start, used_opening_end)
				if used_name_err != .None {
					err = .Malformed_XML
				} else {
					stanza.iq.streamhost_jid, _, err = decoded_attribute(data, used_name, used_opening_end, "jid", allocator)
					stanza.iq.streamhost_used = err == .None
				}
			}
		}
		if err != .None {
			destroy_stanza(&stanza, allocator)
			return {}, err
		}
		position = finish
	}
	return stanza, .None
}
