package protocol

import "core:fmt"

si_offer :: proc(from, to, iq_id, sid, filename: string, size: i64, allocator := context.allocator) -> string {
	return fmt.aprintf("<iq type=\"set\" id=\"%s\" to=\"%s\" from=\"%s\"><si xmlns=\"%s\" id=\"%s\" profile=\"%s\"><file xmlns=\"%s\" name=\"%s\" size=\"%d\"/><feature xmlns=\"%s\"><x xmlns=\"%s\" type=\"form\"><field var=\"stream-method\" type=\"list-single\"><option><value>%s</value></option></field></x></feature></si></iq>", escape(iq_id, context.temp_allocator), escape(to, context.temp_allocator), escape(from, context.temp_allocator), SI_NAMESPACE, escape(sid, context.temp_allocator), FILE_TRANSFER_NAMESPACE, FILE_TRANSFER_NAMESPACE, escape(filename, context.temp_allocator), size, FEATURE_NEG_NAMESPACE, DATA_FORM_NAMESPACE, BYTESTREAMS_NAMESPACE, allocator=allocator)
}

si_accept :: proc(from, to, iq_id: string, allocator := context.allocator) -> string {
	return fmt.aprintf("<iq type=\"result\" id=\"%s\" to=\"%s\" from=\"%s\"><si xmlns=\"%s\"><feature xmlns=\"%s\"><x xmlns=\"%s\" type=\"submit\"><field var=\"stream-method\"><value>%s</value></field></x></feature></si></iq>", escape(iq_id, context.temp_allocator), escape(to, context.temp_allocator), escape(from, context.temp_allocator), SI_NAMESPACE, FEATURE_NEG_NAMESPACE, DATA_FORM_NAMESPACE, BYTESTREAMS_NAMESPACE, allocator=allocator)
}

si_reject :: proc(from, to, iq_id: string, allocator := context.allocator) -> string {
	return fmt.aprintf("<iq type=\"error\" id=\"%s\" to=\"%s\" from=\"%s\"><error code=\"403\" type=\"cancel\"><forbidden xmlns=\"%s\"/><text xmlns=\"%s\">Offer Declined</text></error></iq>", escape(iq_id, context.temp_allocator), escape(to, context.temp_allocator), escape(from, context.temp_allocator), STANZA_ERROR_NAMESPACE, STANZA_ERROR_NAMESPACE, allocator=allocator)
}

bytestream_offer :: proc(from, to, iq_id, sid, streamhost_jid, host: string, port: u16, allocator := context.allocator) -> string {
	return fmt.aprintf("<iq type=\"set\" id=\"%s\" to=\"%s\" from=\"%s\"><query xmlns=\"%s\" sid=\"%s\" mode=\"tcp\"><streamhost jid=\"%s\" host=\"%s\" port=\"%d\"/></query></iq>", escape(iq_id, context.temp_allocator), escape(to, context.temp_allocator), escape(from, context.temp_allocator), BYTESTREAMS_NAMESPACE, escape(sid, context.temp_allocator), escape(streamhost_jid, context.temp_allocator), escape(host, context.temp_allocator), port, allocator=allocator)
}

bytestream_used :: proc(from, to, iq_id, sid, jid: string, allocator := context.allocator) -> string {
	return fmt.aprintf("<iq type=\"result\" id=\"%s\" to=\"%s\" from=\"%s\"><query xmlns=\"%s\" sid=\"%s\"><streamhost-used jid=\"%s\"/></query></iq>", escape(iq_id, context.temp_allocator), escape(to, context.temp_allocator), escape(from, context.temp_allocator), BYTESTREAMS_NAMESPACE, escape(sid, context.temp_allocator), escape(jid, context.temp_allocator), allocator=allocator)
}
