package session

import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"

import address "barev:internal/address"
import protocol "barev:internal/protocol"
import transport "barev:internal/transport"
import xmlstream "barev:internal/xmlstream"

Direction :: enum {
	Incoming,
	Outgoing,
}

State :: enum {
	Disconnected,
	Connecting,
	Stream_Negotiation,
	Online,
}

Error :: enum {
	None,
	Invalid,
	Unknown_Peer,
	Already_Connected,
	Transport,
	Protocol,
	Timeout,
}

Event_Kind :: enum {
	Connected,
	Disconnected,
	Message,
	Presence,
	Chat_State,
	Avatar_Update,
	Avatar,
	Transfer_Offer,
	Transfer_Accepted,
	Transfer_Rejected,
	Bytestream_Offer,
	Bytestream_Used,
	Error,
}

Event :: struct {
	kind:      Event_Kind,
	peer_index: int,
	error:     Error,
	text:      string,
	formatted: string,
	mime:      string,
	request_id: string,
	transfer_id: string,
	host:      string,
	size:      i64,
	port:      u16,
	chat_state: protocol.Chat_State,
	presence:  protocol.Presence,
}

Peer :: struct {
	jid:       string,
	ip:        net.IP6_Address,
	port:      u16,
	state:     State,
	presence:  protocol.Presence,
	active:    int,
}

Candidate :: struct {
	socket:          transport.Socket,
	direction:       Direction,
	peer_index:      int,
	remote_ip:       net.IP6_Address,
	parser:          xmlstream.Parser,
	parser_ready:    bool,
	received_header: bool,
	sent_header:     bool,
	online_emitted:  bool,
	created_at:      time.Time,
	last_activity:   time.Time,
	ping_started_at: time.Time,
	ping_id:         string,
	ping_failures:   u8,
	avatar_request_id: string,
}

Engine :: struct {
	local_jid:       string,
	bind_ip:         net.IP6_Address,
	listener:        transport.Listener,
	peers:           [dynamic]Peer,
	candidates:      [dynamic]Candidate,
	events:          [dynamic]Event,
	connect_timeout: time.Duration,
	max_receive:     int,
	max_stanza:      int,
	max_write_queue: int,
	ping_interval:   time.Duration,
	ping_timeout:    time.Duration,
	max_ping_failures: u8,
	ping_sequence:   u64,
	avatar_sequence: u64,
	current_presence: protocol.Presence,
	status_text:     string,
	avatar_base64:   string,
	avatar_mime:     string,
	avatar_hash:     string,
	advertise_avatar: bool,
	started:         bool,
}

init :: proc(engine: ^Engine, local_jid: string, bind_ip: net.IP6_Address, connect_timeout := 10 * time.Second, max_receive := 1 << 20, max_stanza := 256 << 10, max_write_queue := 1 << 20, ping_interval := 30 * time.Second, ping_timeout := 10 * time.Second, max_ping_failures: u8 = 2) {
	engine^ = {
		local_jid = strings.clone(local_jid),
		bind_ip = bind_ip,
		peers = make([dynamic]Peer),
		candidates = make([dynamic]Candidate),
		events = make([dynamic]Event),
		connect_timeout = connect_timeout,
		max_receive = max_receive,
		max_stanza = max_stanza,
		max_write_queue = max_write_queue,
		ping_interval = ping_interval,
		ping_timeout = ping_timeout,
		max_ping_failures = max_ping_failures,
		current_presence = .Available,
	}
}

destroy_candidate :: proc(candidate: ^Candidate) {
	transport.close_socket(&candidate.socket)
	delete(candidate.ping_id)
	delete(candidate.avatar_request_id)
	if candidate.parser_ready {
		xmlstream.destroy(&candidate.parser)
	}
	candidate^ = {}
}

stop :: proc(engine: ^Engine) {
	for &candidate in engine.candidates {
		destroy_candidate(&candidate)
	}
	clear(&engine.candidates)
	transport.close_listener(&engine.listener)
	for &peer in engine.peers {
		peer.state = .Disconnected
		peer.active = -1
		peer.presence = .Offline
	}
	engine.started = false
}

destroy :: proc(engine: ^Engine) {
	stop(engine)
	for &peer in engine.peers {
		delete(peer.jid)
	}
	delete(engine.peers)
	delete(engine.candidates)
	clear_events(engine)
	delete(engine.events)
	delete(engine.local_jid)
	delete(engine.status_text)
	delete(engine.avatar_base64)
	delete(engine.avatar_mime)
	delete(engine.avatar_hash)
	engine^ = {}
}

start :: proc(engine: ^Engine, port: u16) -> Error {
	if engine.started {
		return .Invalid
	}
	listener, listen_err := transport.listen(engine.bind_ip, port)
	if listen_err != .None {
		return .Transport
	}
	engine.listener = listener
	engine.started = true
	return .None
}

port :: proc(engine: Engine) -> u16 {
	return engine.listener.port
}

add_peer :: proc(engine: ^Engine, jid: string, ip: net.IP6_Address, peer_port: u16) -> int {
	append(&engine.peers, Peer{
		jid = strings.clone(jid),
		ip = ip,
		port = peer_port,
		state = .Disconnected,
		presence = .Offline,
		active = -1,
	})
	return len(engine.peers) - 1
}

new_candidate :: proc(engine: ^Engine, socket: transport.Socket, direction: Direction, peer_index: int, remote_ip: net.IP6_Address) -> int {
	candidate := Candidate{
		socket = socket,
		direction = direction,
		peer_index = peer_index,
		remote_ip = remote_ip,
		parser_ready = true,
		created_at = time.now(),
		last_activity = time.now(),
	}
	xmlstream.init(&candidate.parser, engine.max_receive, engine.max_stanza)
	append(&engine.candidates, candidate)
	return len(engine.candidates) - 1
}

connect_peer :: proc(engine: ^Engine, peer_index: int) -> Error {
	if !engine.started || peer_index < 0 || peer_index >= len(engine.peers) {
		return .Invalid
	}
	if engine.peers[peer_index].active >= 0 {
		return .Already_Connected
	}
	peer := &engine.peers[peer_index]
	socket, dial_err := transport.dial(peer.ip, peer.port, engine.max_write_queue)
	if dial_err != .None {
		return .Transport
	}
	_ = new_candidate(engine, socket, .Outgoing, peer_index, peer.ip)
	peer.state = .Connecting
	return .None
}

queue_header :: proc(engine: ^Engine, candidate: ^Candidate) -> Error {
	if candidate.peer_index < 0 || candidate.peer_index >= len(engine.peers) {
		return .Unknown_Peer
	}
	header := protocol.stream_header(engine.local_jid, engine.peers[candidate.peer_index].jid)
	defer delete(header)
	if queue_err := transport.queue(&candidate.socket, transmute([]u8)header); queue_err != .None {
		return .Transport
	}
	candidate.sent_header = true
	return .None
}

same_jid :: proc(left, right: string) -> bool {
	left_jid, left_err := address.parse_jid(left)
	if left_err != .None {
		return false
	}
	defer address.destroy_jid(&left_jid)
	right_jid, right_err := address.parse_jid(right)
	if right_err != .None {
		return false
	}
	defer address.destroy_jid(&right_jid)
	return left_jid.nick == right_jid.nick && left_jid.ip == right_jid.ip
}

find_peer :: proc(engine: Engine, jid: string, ip: net.IP6_Address) -> int {
	for peer, index in engine.peers {
		if peer.ip == ip && same_jid(peer.jid, jid) {
			return index
		}
	}
	return -1
}

prefer_candidate_for_peer :: proc(engine: Engine, peer_index: int, current: Candidate, candidate: Candidate) -> bool {
	if candidate.received_header != current.received_header {
		return candidate.received_header
	}
	if candidate.direction == current.direction {
		return false
	}
	keep_outgoing := strings.compare(engine.local_jid, engine.peers[peer_index].jid) < 0
	return candidate.direction == .Outgoing && keep_outgoing || candidate.direction == .Incoming && !keep_outgoing
}

emit :: proc(engine: ^Engine, kind: Event_Kind, peer_index: int, err: Error = .None, text := "", formatted := "", mime := "", request_id := "", transfer_id := "", host := "", size: i64 = 0, port: u16 = 0, chat_state: protocol.Chat_State = .None, presence: protocol.Presence = .Offline) {
	append(&engine.events, Event{kind=kind, peer_index=peer_index, error=err, text=strings.clone(text), formatted=strings.clone(formatted), mime=strings.clone(mime), request_id=strings.clone(request_id), transfer_id=strings.clone(transfer_id), host=strings.clone(host), size=size, port=port, chat_state=chat_state, presence=presence})
}

clear_events :: proc(engine: ^Engine) {
	for &event in engine.events {
		delete(event.text)
		delete(event.formatted)
		delete(event.mime)
		delete(event.request_id)
		delete(event.transfer_id)
		delete(event.host)
	}
	clear(&engine.events)
}

close_candidate :: proc(engine: ^Engine, candidate_index: int, notify: bool) {
	if candidate_index < 0 || candidate_index >= len(engine.candidates) {
		return
	}
	candidate := &engine.candidates[candidate_index]
	if !candidate.socket.valid {
		return
	}
	peer_index := candidate.peer_index
	was_active := peer_index >= 0 && peer_index < len(engine.peers) &&
		engine.peers[peer_index].active == candidate_index
	destroy_candidate(candidate)
	if peer_index >= 0 && peer_index < len(engine.peers) {
		peer := &engine.peers[peer_index]
		has_other := false
		for other in engine.candidates {
			if other.socket.valid && other.peer_index == peer_index {
				has_other = true
				break
			}
		}
		if was_active || peer.active < 0 && !has_other {
			peer.active = -1
			peer.state = .Disconnected
			peer.presence = .Offline
			if notify {
				emit(engine, .Disconnected, peer_index)
			}
		}
	}
}

activate :: proc(engine: ^Engine, candidate_index: int) -> bool {
	candidate := &engine.candidates[candidate_index]
	peer_index := candidate.peer_index
	peer := &engine.peers[peer_index]
	if peer.active >= 0 && peer.active != candidate_index {
		current_index := peer.active
		current := engine.candidates[current_index]
		if prefer_candidate_for_peer(engine^, peer_index, current, candidate^) {
			close_candidate(engine, current_index, false)
		} else {
			close_candidate(engine, candidate_index, false)
			return false
		}
	}
	peer.active = candidate_index
	if candidate.sent_header && candidate.received_header && !candidate.online_emitted {
		candidate.online_emitted = true
		peer.state = .Online
		emit(engine, .Connected, peer_index)
		presence := protocol.presence(engine.current_presence, engine.status_text, from=engine.local_jid)
		if engine.advertise_avatar {
			delete(presence)
			presence = protocol.presence_with_avatar(engine.current_presence, engine.status_text, "", engine.local_jid, engine.avatar_hash)
		}
		defer delete(presence)
		if transport.queue(&candidate.socket, transmute([]u8)presence) != .None {
			close_candidate(engine, candidate_index, true)
			return false
		}
	} else if peer.state != .Online {
		peer.state = .Stream_Negotiation
	}
	return true
}

handle_stream_start :: proc(engine: ^Engine, candidate_index: int, event: xmlstream.Event) -> Error {
	from, has_from, from_err := xmlstream.top_level_attribute(event.xml, "from")
	to, has_to, to_err := xmlstream.top_level_attribute(event.xml, "to")
	if from_err != .None || to_err != .None || !has_from || !has_to || !same_jid(to, engine.local_jid) {
		return .Protocol
	}
	candidate := &engine.candidates[candidate_index]
	peer_index := find_peer(engine^, from, candidate.remote_ip)
	if peer_index < 0 || candidate.peer_index >= 0 && candidate.peer_index != peer_index {
		return .Unknown_Peer
	}
	candidate.peer_index = peer_index
	candidate.received_header = true
	if !candidate.sent_header {
		if header_err := queue_header(engine, candidate); header_err != .None {
			return header_err
		}
	}
	if !activate(engine, candidate_index) {
		return .None
	}
	return .None
}

handle_stanza :: proc(engine: ^Engine, candidate_index: int, event: xmlstream.Event) -> Error {
	candidate := &engine.candidates[candidate_index]
	if candidate.peer_index < 0 || !candidate.online_emitted {
		return .Protocol
	}
	stanza, decode_err := protocol.decode_stanza(event.xml, event.namespace, engine.max_stanza)
	defer protocol.destroy_stanza(&stanza)
	if decode_err != .None {
		return .Protocol
	}
	switch stanza.kind {
	case .Message:
		if stanza.message.body_present {
			emit(engine, .Message, candidate.peer_index, text=stanza.message.body, formatted=stanza.message.xhtml)
		}
		if stanza.message.chat_state != .None {
			emit(engine, .Chat_State, candidate.peer_index, chat_state=stanza.message.chat_state)
		}
	case .Presence:
		engine.peers[candidate.peer_index].presence = stanza.presence.presence
		emit(engine, .Presence, candidate.peer_index, presence=stanza.presence.presence, text=stanza.presence.status)
		if stanza.presence.avatar_update {
			emit(engine, .Avatar_Update, candidate.peer_index, text=stanza.presence.avatar_hash)
			if len(stanza.presence.avatar_hash) > 0 {
				engine.avatar_sequence += 1
				id := fmt.aprintf("odin-vcard-%d", engine.avatar_sequence)
				request := protocol.vcard_request(engine.local_jid, engine.peers[candidate.peer_index].jid, id)
				defer delete(request)
				if transport.queue(&candidate.socket, transmute([]u8)request) != .None {
					delete(id)
					return .Transport
				}
				delete(candidate.avatar_request_id)
				candidate.avatar_request_id = id
			}
		}
	case .IQ:
		if stanza.iq.iq_type == .Get && stanza.iq.ping {
			pong := protocol.pong(engine.local_jid, engine.peers[candidate.peer_index].jid, stanza.iq.id)
			defer delete(pong)
			if transport.queue(&candidate.socket, transmute([]u8)pong) != .None {
				return .Transport
			}
		} else if stanza.iq.iq_type == .Result && len(candidate.ping_id) > 0 && stanza.iq.id == candidate.ping_id {
			delete(candidate.ping_id)
			candidate.ping_id = ""
			candidate.ping_failures = 0
		} else if stanza.iq.vcard && stanza.iq.iq_type == .Get {
			result := protocol.vcard_result(engine.local_jid, engine.peers[candidate.peer_index].jid, stanza.iq.id, engine.avatar_mime, engine.avatar_base64)
			defer delete(result)
			if transport.queue(&candidate.socket, transmute([]u8)result) != .None {
				return .Transport
			}
		} else if stanza.iq.vcard && stanza.iq.iq_type == .Result && len(candidate.avatar_request_id) > 0 && stanza.iq.id == candidate.avatar_request_id {
			emit(engine, .Avatar, candidate.peer_index, text=stanza.iq.vcard_data, mime=stanza.iq.vcard_mime)
			delete(candidate.avatar_request_id)
			candidate.avatar_request_id = ""
		} else if stanza.iq.si && stanza.iq.iq_type == .Set {
			emit(engine, .Transfer_Offer, candidate.peer_index, text=stanza.iq.file_name, request_id=stanza.iq.id, transfer_id=stanza.iq.si_id, size=stanza.iq.file_size)
		} else if stanza.iq.si && stanza.iq.iq_type == .Result {
			emit(engine, .Transfer_Accepted, candidate.peer_index, request_id=stanza.iq.id)
		} else if stanza.iq.bytestream && stanza.iq.iq_type == .Set {
			emit(engine, .Bytestream_Offer, candidate.peer_index, request_id=stanza.iq.id, transfer_id=stanza.iq.bytestream_sid, host=stanza.iq.streamhost_host, mime=stanza.iq.streamhost_jid, port=stanza.iq.streamhost_port)
		} else if stanza.iq.bytestream && stanza.iq.iq_type == .Result && stanza.iq.streamhost_used {
			emit(engine, .Bytestream_Used, candidate.peer_index, request_id=stanza.iq.id, mime=stanza.iq.streamhost_jid)
		} else if stanza.iq.iq_type == .Error {
			emit(engine, .Transfer_Rejected, candidate.peer_index, request_id=stanza.iq.id)
		}
	case .Unknown:
	}
	return .None
}

read_candidate :: proc(engine: ^Engine, candidate_index: int) -> Error {
	candidate := &engine.candidates[candidate_index]
	buffer: [transport.READ_BUFFER_SIZE]u8
	for candidate.socket.valid {
		count, receive_err := transport.receive(&candidate.socket, buffer[:])
		if receive_err == .Would_Block {
			return .None
		}
		if receive_err != .None {
			return .Transport
		}
		candidate.last_activity = time.now()
		events := make([dynamic]xmlstream.Event)
		parse_err := xmlstream.feed(&candidate.parser, buffer[:count], &events)
		if parse_err != .None {
			xmlstream.destroy_events(&events)
			return .Protocol
		}
		for event in events {
			switch event.kind {
			case .Stream_Start:
				if event_err := handle_stream_start(engine, candidate_index, event); event_err != .None {
					xmlstream.destroy_events(&events)
					return event_err
				}
			case .Stanza:
				if event_err := handle_stanza(engine, candidate_index, event); event_err != .None {
					xmlstream.destroy_events(&events)
					return event_err
				}
			case .Stream_End:
				xmlstream.destroy_events(&events)
				return .Transport
			}
			if !engine.candidates[candidate_index].socket.valid {
				xmlstream.destroy_events(&events)
				return .None
			}
		}
		xmlstream.destroy_events(&events)
	}
	return .None
}

queue_ping :: proc(engine: ^Engine, candidate: ^Candidate) -> Error {
	engine.ping_sequence += 1
	id := fmt.aprintf("odin-ping-%d", engine.ping_sequence)
	ping := protocol.ping(engine.local_jid, engine.peers[candidate.peer_index].jid, id)
	defer delete(ping)
	if transport.queue(&candidate.socket, transmute([]u8)ping) != .None {
		delete(id)
		return .Transport
	}
	delete(candidate.ping_id)
	candidate.ping_id = id
	candidate.ping_started_at = time.now()
	return .None
}

maintain_keepalive :: proc(engine: ^Engine, candidate_index: int) -> Error {
	candidate := &engine.candidates[candidate_index]
	if !candidate.online_emitted || engine.ping_interval <= 0 || engine.ping_timeout <= 0 || engine.max_ping_failures == 0 {
		return .None
	}
	if len(candidate.ping_id) > 0 {
		if time.since(candidate.ping_started_at) < engine.ping_timeout {
			return .None
		}
		delete(candidate.ping_id)
		candidate.ping_id = ""
		candidate.ping_failures += 1
		if candidate.ping_failures >= engine.max_ping_failures {
			return .Timeout
		}
		return queue_ping(engine, candidate)
	}
	if time.since(candidate.last_activity) >= engine.ping_interval {
		return queue_ping(engine, candidate)
	}
	return .None
}

accept_pending :: proc(engine: ^Engine) -> Error {
	for {
		socket, remote_ip, accept_err := transport.accept(engine.listener, engine.max_write_queue)
		if accept_err == .Would_Block {
			return .None
		}
		if accept_err != .None {
			return .Transport
		}
		_ = new_candidate(engine, socket, .Incoming, -1, remote_ip)
	}
}

process :: proc(engine: ^Engine) -> Error {
	if !engine.started {
		return .Invalid
	}
	if accept_err := accept_pending(engine); accept_err != .None {
		return accept_err
	}
	count := len(engine.candidates)
	for candidate_index in 0 ..< count {
		candidate := &engine.candidates[candidate_index]
		if !candidate.socket.valid {
			continue
		}
		if time.since(candidate.created_at) > engine.connect_timeout && !candidate.online_emitted {
			peer_index := candidate.peer_index
			close_candidate(engine, candidate_index, true)
			emit(engine, .Error, peer_index, .Timeout)
			continue
		}
		if candidate.socket.connecting {
			connect_err := transport.finish_connect(&candidate.socket)
			if connect_err == .Would_Block {
				continue
			}
			if connect_err != .None {
				peer_index := candidate.peer_index
				close_candidate(engine, candidate_index, true)
				emit(engine, .Error, peer_index, .Transport)
				continue
			}
		}
		if candidate.direction == .Outgoing && !candidate.sent_header {
			if header_err := queue_header(engine, candidate); header_err != .None {
				close_candidate(engine, candidate_index, true)
				continue
			}
		}
		flush_err := transport.flush(&candidate.socket)
		if flush_err != .None && flush_err != .Would_Block {
			close_candidate(engine, candidate_index, true)
			continue
		}
		read_err := read_candidate(engine, candidate_index)
		if read_err != .None && candidate.socket.valid {
			peer_index := candidate.peer_index
			close_candidate(engine, candidate_index, true)
			emit(engine, .Error, peer_index, read_err)
			continue
		}
		if candidate.socket.valid {
			keepalive_err := maintain_keepalive(engine, candidate_index)
			if keepalive_err != .None {
				peer_index := candidate.peer_index
				close_candidate(engine, candidate_index, true)
				emit(engine, .Error, peer_index, keepalive_err)
			}
		}
	}
	return .None
}

send_message :: proc(engine: ^Engine, peer_index: int, body: string) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) || !online(engine^, peer_index) {
		return .Invalid
	}
	candidate := &engine.candidates[engine.peers[peer_index].active]
	message := protocol.message(engine.local_jid, engine.peers[peer_index].jid, body)
	defer delete(message)
	if transport.queue(&candidate.socket, transmute([]u8)message) != .None {
		return .Transport
	}
	return .None
}

send_formatted_message :: proc(engine: ^Engine, peer_index: int, body, xhtml_fragment: string) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) {
		return .Invalid
	}
	peer := &engine.peers[peer_index]
	if peer.active < 0 || peer.state != .Online {
		return .Invalid
	}
	message, valid := protocol.formatted_message(engine.local_jid, peer.jid, body, xhtml_fragment)
	if !valid {
		return .Protocol
	}
	defer delete(message)
	if transport.queue(&engine.candidates[peer.active].socket, transmute([]u8)message) != .None {
		return .Transport
	}
	return .None
}

send_chat_state :: proc(engine: ^Engine, peer_index: int, state: protocol.Chat_State) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) || state == .None {
		return .Invalid
	}
	peer := &engine.peers[peer_index]
	if peer.active < 0 || peer.state != .Online {
		return .Invalid
	}
	engine.ping_sequence += 1
	id := fmt.aprintf("odin-chat-%d", engine.ping_sequence, allocator=context.temp_allocator)
	message := protocol.chat_state_message(peer.jid, id, state, engine.local_jid)
	defer delete(message)
	if transport.queue(&engine.candidates[peer.active].socket, transmute([]u8)message) != .None {
		return .Transport
	}
	return .None
}

queue_peer_stanza :: proc(engine: ^Engine, peer_index: int, stanza: string) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) || !online(engine^, peer_index) {
		return .Invalid
	}
	active := engine.peers[peer_index].active
	if transport.queue(&engine.candidates[active].socket, transmute([]u8)stanza) != .None {
		return .Transport
	}
	return .None
}

send_transfer_offer :: proc(engine: ^Engine, peer_index: int, request_id, transfer_id, filename: string, size: i64) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) {
		return .Invalid
	}
	stanza := protocol.si_offer(engine.local_jid, engine.peers[peer_index].jid, request_id, transfer_id, filename, size)
	defer delete(stanza)
	return queue_peer_stanza(engine, peer_index, stanza)
}

send_transfer_accept :: proc(engine: ^Engine, peer_index: int, request_id: string) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) {
		return .Invalid
	}
	stanza := protocol.si_accept(engine.local_jid, engine.peers[peer_index].jid, request_id)
	defer delete(stanza)
	return queue_peer_stanza(engine, peer_index, stanza)
}

send_transfer_reject :: proc(engine: ^Engine, peer_index: int, request_id: string) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) {
		return .Invalid
	}
	stanza := protocol.si_reject(engine.local_jid, engine.peers[peer_index].jid, request_id)
	defer delete(stanza)
	return queue_peer_stanza(engine, peer_index, stanza)
}

send_bytestream_offer :: proc(engine: ^Engine, peer_index: int, request_id, transfer_id, host_jid, host: string, port: u16) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) {
		return .Invalid
	}
	stanza := protocol.bytestream_offer(engine.local_jid, engine.peers[peer_index].jid, request_id, transfer_id, host_jid, host, port)
	defer delete(stanza)
	return queue_peer_stanza(engine, peer_index, stanza)
}

send_bytestream_used :: proc(engine: ^Engine, peer_index: int, request_id, transfer_id, jid: string) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) {
		return .Invalid
	}
	stanza := protocol.bytestream_used(engine.local_jid, engine.peers[peer_index].jid, request_id, transfer_id, jid)
	defer delete(stanza)
	return queue_peer_stanza(engine, peer_index, stanza)
}

set_avatar :: proc(engine: ^Engine, base64_data, mime, hash: string) {
	delete(engine.avatar_base64)
	delete(engine.avatar_mime)
	delete(engine.avatar_hash)
	engine.avatar_base64 = strings.clone(base64_data)
	engine.avatar_mime = strings.clone(mime)
	engine.avatar_hash = strings.clone(hash)
	engine.advertise_avatar = true
}

set_presence :: proc(engine: ^Engine, value: protocol.Presence, status := "") -> Error {
	delete(engine.status_text)
	engine.status_text = strings.clone(status)
	engine.current_presence = value
	for &peer in engine.peers {
		if peer.active < 0 || peer.state != .Online {
			continue
		}
		candidate := &engine.candidates[peer.active]
		stanza := protocol.presence(value, status, to=peer.jid, from=engine.local_jid)
		if engine.advertise_avatar && value != .Offline {
			delete(stanza)
			stanza = protocol.presence_with_avatar(value, status, peer.jid, engine.local_jid, engine.avatar_hash)
		}
		queue_err := transport.queue(&candidate.socket, transmute([]u8)stanza)
		delete(stanza)
		if queue_err != .None {
			return .Transport
		}
	}
	return .None
}

disconnect_peer :: proc(engine: ^Engine, peer_index: int) -> Error {
	if peer_index < 0 || peer_index >= len(engine.peers) {
		return .Invalid
	}
	active := engine.peers[peer_index].active
	if active < 0 {
		return .Invalid
	}
	end := protocol.stream_end()
	_ = transport.queue(&engine.candidates[active].socket, transmute([]u8)end)
	_ = transport.flush(&engine.candidates[active].socket)
	delete(end)
	close_candidate(engine, active, true)
	return .None
}

online :: proc(engine: Engine, peer_index: int) -> bool {
	return peer_index >= 0 && peer_index < len(engine.peers) && engine.peers[peer_index].state == .Online
}

active_candidate_count :: proc(engine: Engine, peer_index: int) -> int {
	count := 0
	for candidate in engine.candidates {
		if candidate.socket.valid && candidate.peer_index == peer_index {
			count += 1
		}
	}
	return count
}
