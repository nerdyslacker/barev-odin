package protocol

import "core:fmt"
import "core:strings"

import xmlstream "barev:internal/xmlstream"

XHTML_NAMESPACE :: "http://www.w3.org/1999/xhtml"
CHAT_STATE_NAMESPACE :: "http://jabber.org/protocol/chatstates"
LEGACY_EVENT_NAMESPACE :: "jabber:x:event"
VCARD_NAMESPACE :: "vcard-temp"
VCARD_UPDATE_NAMESPACE :: "vcard-temp:x:update"
SI_NAMESPACE :: "http://jabber.org/protocol/si"
FILE_TRANSFER_NAMESPACE :: "http://jabber.org/protocol/si/profile/file-transfer"
FEATURE_NEG_NAMESPACE :: "http://jabber.org/protocol/feature-neg"
DATA_FORM_NAMESPACE :: "jabber:x:data"
BYTESTREAMS_NAMESPACE :: "http://jabber.org/protocol/bytestreams"
STANZA_ERROR_NAMESPACE :: "urn:ietf:params:xml:ns:xmpp-stanzas"

Chat_State :: enum {
	None,
	Active,
	Inactive,
	Gone,
	Composing,
	Paused,
}

chat_state_name :: proc(state: Chat_State) -> string {
	switch state {
	case .Active:    return "active"
	case .Inactive:  return "inactive"
	case .Gone:      return "gone"
	case .Composing: return "composing"
	case .Paused:    return "paused"
	case .None:      return ""
	}
	return ""
}

chat_state_from_name :: proc(name: string) -> Chat_State {
	switch name {
	case "active":    return .Active
	case "inactive":  return .Inactive
	case "gone":      return .Gone
	case "composing": return .Composing
	case "paused":    return .Paused
	}
	return .None
}

chat_state_message :: proc(to, id: string, state: Chat_State, from := "", allocator := context.allocator) -> string {
	name := chat_state_name(state)
	if len(name) == 0 {
		return ""
	}
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	fmt.sbprintf(&builder, "<message type=\"chat\" to=\"%s\"", escape(to, context.temp_allocator))
	if len(from) > 0 {
		fmt.sbprintf(&builder, " from=\"%s\"", escape(from, context.temp_allocator))
	}
	if len(id) > 0 {
		fmt.sbprintf(&builder, " id=\"%s\"", escape(id, context.temp_allocator))
	}
	fmt.sbprintf(&builder, "><%s xmlns=\"%s\"/></message>", name, CHAT_STATE_NAMESPACE)
	return strings.clone(strings.to_string(builder), allocator)
}

formatted_message :: proc(from, to, body, xhtml_fragment: string, allocator := context.allocator) -> (xml: string, valid: bool) {
	wrapper := fmt.aprintf("<body xmlns=\"%s\">%s</body>", XHTML_NAMESPACE, xhtml_fragment, allocator=context.temp_allocator)
	if xmlstream.validate_stanza(wrapper) != .None {
		return "", false
	}
	escaped_from := escape(from, context.temp_allocator)
	escaped_to := escape(to, context.temp_allocator)
	escaped_body := escape(body, context.temp_allocator)
	xml = fmt.aprintf("<message to=\"%s\" from=\"%s\" type=\"chat\"><body>%s</body><html xmlns=\"%s\"><body>%s</body></html><x xmlns=\"%s\"><composing/></x></message>", escaped_to, escaped_from, escaped_body, XHTML_NAMESPACE, xhtml_fragment, LEGACY_EVENT_NAMESPACE, allocator=allocator)
	return xml, true
}

presence_with_avatar :: proc(value: Presence, status, to, from, avatar_hash: string, allocator := context.allocator) -> string {
	base := presence(value, status, to, from, context.temp_allocator)
	if value == .Offline {
		return strings.clone(base, allocator)
	}
	closing := strings.last_index(base, "</presence>")
	if closing < 0 {
		return strings.clone(base, allocator)
	}
	escaped_hash := escape(avatar_hash, context.temp_allocator)
	return fmt.aprintf("%s<x xmlns=\"%s\"><photo>%s</photo></x></presence>", base[:closing], VCARD_UPDATE_NAMESPACE, escaped_hash, allocator=allocator)
}

vcard_request :: proc(from, to, id: string, allocator := context.allocator) -> string {
	return fmt.aprintf("<iq type=\"get\" id=\"%s\" from=\"%s\" to=\"%s\"><vCard xmlns=\"%s\"/></iq>", escape(id, context.temp_allocator), escape(from, context.temp_allocator), escape(to, context.temp_allocator), VCARD_NAMESPACE, allocator=allocator)
}

vcard_result :: proc(from, to, id, mime, base64_data: string, allocator := context.allocator) -> string {
	if len(base64_data) == 0 {
		return fmt.aprintf("<iq type=\"result\" id=\"%s\" from=\"%s\" to=\"%s\"><vCard xmlns=\"%s\"/></iq>", escape(id, context.temp_allocator), escape(from, context.temp_allocator), escape(to, context.temp_allocator), VCARD_NAMESPACE, allocator=allocator)
	}
	return fmt.aprintf("<iq type=\"result\" id=\"%s\" from=\"%s\" to=\"%s\"><vCard xmlns=\"%s\"><PHOTO><TYPE>%s</TYPE><BINVAL>%s</BINVAL></PHOTO></vCard></iq>", escape(id, context.temp_allocator), escape(from, context.temp_allocator), escape(to, context.temp_allocator), VCARD_NAMESPACE, escape(mime, context.temp_allocator), escape(base64_data, context.temp_allocator), allocator=allocator)
}
