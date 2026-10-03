package protocol

import "core:fmt"
import "core:strings"

STREAM_NAMESPACE :: "http://etherx.jabber.org/streams"
CLIENT_NAMESPACE :: "jabber:client"
PING_NAMESPACE :: "urn:xmpp:ping"

Presence :: enum {
	Offline,
	Available,
	Away,
	Extended_Away,
	Busy,
}

escape :: proc(text: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	for byte in transmute([]u8)text {
		switch byte {
		case '&': strings.write_string(&builder, "&amp;")
		case '<': strings.write_string(&builder, "&lt;")
		case '>': strings.write_string(&builder, "&gt;")
		case '\"': strings.write_string(&builder, "&quot;")
		case '\'': strings.write_string(&builder, "&apos;")
		case: strings.write_byte(&builder, byte)
		}
	}
	return strings.clone(strings.to_string(builder), allocator)
}

stream_header :: proc(from, to: string, allocator := context.allocator) -> string {
	escaped_from := escape(from, context.temp_allocator)
	escaped_to := escape(to, context.temp_allocator)
	return fmt.aprintf("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<stream:stream xmlns=\"%s\" xmlns:stream=\"%s\" from=\"%s\" to=\"%s\">", CLIENT_NAMESPACE, STREAM_NAMESPACE, escaped_from, escaped_to, allocator=allocator)
}

stream_end :: proc(allocator := context.allocator) -> string {
	return strings.clone("</stream:stream>", allocator)
}

message :: proc(from, to, body: string, allocator := context.allocator) -> string {
	escaped_from := escape(from, context.temp_allocator)
	escaped_to := escape(to, context.temp_allocator)
	escaped_body := escape(body, context.temp_allocator)
	return fmt.aprintf("<message to=\"%s\" from=\"%s\" type=\"chat\"><body>%s</body></message>", escaped_to, escaped_from, escaped_body, allocator=allocator)
}

presence_show :: proc(value: Presence) -> string {
	switch value {
	case .Away:          return "away"
	case .Extended_Away: return "xa"
	case .Busy:          return "dnd"
	case .Offline, .Available: return ""
	}
	return ""
}

presence :: proc(value: Presence, status := "", to := "", from := "", allocator := context.allocator) -> string {
	if value == .Offline {
		if len(to) == 0 && len(from) == 0 {
			return strings.clone("<presence type=\"unavailable\"/>", allocator)
		}
		builder := strings.builder_make(allocator)
		defer strings.builder_destroy(&builder)
		strings.write_string(&builder, "<presence type=\"unavailable\"")
		if len(to) > 0 {
			fmt.sbprintf(&builder, " to=\"%s\"", escape(to, context.temp_allocator))
		}
		if len(from) > 0 {
			fmt.sbprintf(&builder, " from=\"%s\"", escape(from, context.temp_allocator))
		}
		strings.write_string(&builder, "/>")
		return strings.clone(strings.to_string(builder), allocator)
	}
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "<presence")
	if len(to) > 0 {
		escaped_to := escape(to, context.temp_allocator)
		fmt.sbprintf(&builder, " to=\"%s\"", escaped_to)
	}
	if len(from) > 0 {
		escaped_from := escape(from, context.temp_allocator)
		fmt.sbprintf(&builder, " from=\"%s\"", escaped_from)
	}
	strings.write_string(&builder, ">")
	if show := presence_show(value); len(show) > 0 {
		fmt.sbprintf(&builder, "<show>%s</show>", show)
	}
	if len(status) > 0 {
		escaped_status := escape(status, context.temp_allocator)
		fmt.sbprintf(&builder, "<status>%s</status>", escaped_status)
	}
	strings.write_string(&builder, "</presence>")
	return strings.clone(strings.to_string(builder), allocator)
}

ping :: proc(from, to, id: string, allocator := context.allocator) -> string {
	escaped_from := escape(from, context.temp_allocator)
	escaped_to := escape(to, context.temp_allocator)
	escaped_id := escape(id, context.temp_allocator)
	return fmt.aprintf("<iq type=\"get\" id=\"%s\" from=\"%s\" to=\"%s\"><ping xmlns=\"%s\"/></iq>", escaped_id, escaped_from, escaped_to, PING_NAMESPACE, allocator=allocator)
}

pong :: proc(from, to, id: string, allocator := context.allocator) -> string {
	escaped_from := escape(from, context.temp_allocator)
	escaped_to := escape(to, context.temp_allocator)
	escaped_id := escape(id, context.temp_allocator)
	return fmt.aprintf("<iq type=\"result\" id=\"%s\" to=\"%s\" from=\"%s\"/>", escaped_id, escaped_to, escaped_from, allocator=allocator)
}
