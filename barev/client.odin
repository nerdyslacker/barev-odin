package barev

import "core:fmt"
import "core:strings"
import "core:time"

import avatar "barev:internal/avatar"
import contacts "barev:internal/contacts"
import session "barev:internal/session"
import transfer "barev:internal/transfer"

Client :: struct {
	engine:       session.Engine,
	peers:        [dynamic]Peer,
	events:       [dynamic]Event,
	event_head:   int,
	max_events:   int,
	next_peer_id: u64,
	listen_port:  u16,
	max_avatar_bytes: int,
	transfers:    transfer.Manager,
	transfer_channels: [dynamic]Transfer_Channel,
	transfer_sequence: u64,
	initialized:  bool,
	started:      bool,
}

@(private)
session_error :: proc(err: session.Error) -> Error {
	switch err {
	case .None:              return .None
	case .Invalid:           return .Not_Connected
	case .Unknown_Peer:      return .Unknown_Peer
	case .Already_Connected: return .Already_Connected
	case .Transport:         return .Transport
	case .Protocol:          return .Protocol
	case .Timeout:           return .Timeout
	}
	return .Transport
}

@(private)
valid_options :: proc(options: Client_Options) -> bool {
	return len(options.nick) > 0 && len(options.bind_ipv6) > 0 &&
	       options.connect_timeout > 0 && options.ping_interval > 0 && options.ping_timeout > 0 &&
	       options.max_ping_failures > 0 && options.max_stanza_bytes > 0 &&
	       options.max_receive_bytes >= options.max_stanza_bytes && options.max_queued_bytes > 0 &&
	       options.max_queued_events > 0 && options.max_avatar_bytes > 0 &&
	       options.max_transfer_bytes > 0 && options.max_concurrent_transfers > 0
}

client_init :: proc(client: ^Client, options: Client_Options) -> Error {
	if client.initialized || !valid_options(options) {
		return .Invalid_Options
	}
	local_text := fmt.aprintf("%s@%s", options.nick, options.bind_ipv6)
	defer delete(local_text)
	local_jid, jid_err := parse_jid(local_text)
	if jid_err != .None {
		return .Invalid_Address
	}
	defer destroy_jid(&local_jid)
	canonical := format_jid(local_jid)
	defer delete(canonical)
	client^ = {
		peers = make([dynamic]Peer),
		events = make([dynamic]Event),
		max_events = options.max_queued_events,
		next_peer_id = 1,
		listen_port = options.port,
		max_avatar_bytes = options.max_avatar_bytes,
		initialized = true,
		transfer_channels = make([dynamic]Transfer_Channel),
	}
	transfer.init(&client.transfers, options.max_transfer_bytes, options.max_concurrent_transfers)
	session.init(
		&client.engine,
		canonical,
		local_jid.ip,
		connect_timeout=options.connect_timeout,
		max_receive=options.max_receive_bytes,
		max_stanza=options.max_stanza_bytes,
		max_write_queue=options.max_queued_bytes,
		ping_interval=options.ping_interval,
		ping_timeout=options.ping_timeout,
		max_ping_failures=options.max_ping_failures,
	)
	return .None
}

destroy_event :: proc(event: ^Event) {
	delete(event.text)
	delete(event.formatted)
	delete(event.mime)
	delete(event.data)
	event^ = {}
}

@(private)
clear_client_events :: proc(client: ^Client) {
	for index in client.event_head ..< len(client.events) {
		destroy_event(&client.events[index])
	}
	delete(client.events)
	client.events = nil
	client.event_head = 0
}

client_destroy :: proc(client: ^Client) {
	if !client.initialized {
		return
	}
	session.destroy(&client.engine)
	for &channel in client.transfer_channels {
		destroy_transfer_channel(&channel)
	}
	delete(client.transfer_channels)
	transfer.destroy(&client.transfers)
	for &peer in client.peers {
		if peer.id != 0 {
			destroy_endpoint(&peer.endpoint)
			delete(peer.status_text)
			delete(peer.avatar_hash)
			delete(peer.avatar_mime)
			delete(peer.avatar_data)
		}
	}
	delete(client.peers)
	clear_client_events(client)
	client^ = {}
}

client_start :: proc(client: ^Client) -> Error {
	if !client.initialized {
		return .Invalid_Options
	}
	if client.started {
		return .Already_Started
	}
	if err := session.start(&client.engine, client.listen_port); err != .None {
		return session_error(err)
	}
	client.started = true
	return .None
}

client_stop :: proc(client: ^Client) {
	if !client.initialized || !client.started {
		return
	}
	session.stop(&client.engine)
	for &channel in client.transfer_channels {
		if channel.state != .Done {
			_ = transfer.cancel(&client.transfers, channel.transfer_id)
			destroy_transfer_channel(&channel)
			channel.state = .Done
		}
	}
	for &value in client.transfers.transfers {
		if value.state == .Offered || value.state == .Accepted || value.state == .Transferring {
			_ = transfer.cancel(&client.transfers, value.id)
		}
	}
	client.started = false
	for &peer in client.peers {
		if peer.id != 0 {
			peer.connection = .Disconnected
			peer.presence = .Offline
		}
	}
}

client_port :: proc(client: Client) -> u16 {
	return session.port(client.engine)
}

@(private)
find_peer_slot :: proc(client: Client, peer_id: u64) -> int {
	for peer, index in client.peers {
		if peer.id == peer_id && peer_id != 0 {
			return index
		}
	}
	return -1
}

@(private)
find_peer_jid :: proc(client: Client, jid: string) -> int {
	for peer, index in client.peers {
		if peer.id == 0 {
			continue
		}
		formatted := format_jid(peer.endpoint.jid, context.temp_allocator)
		if formatted == jid {
			return index
		}
	}
	return -1
}

client_add_peer :: proc(client: ^Client, endpoint_text: string) -> (peer_id: u64, err: Error) {
	if !client.initialized {
		return 0, .Invalid_Options
	}
	endpoint, parse_err := parse_endpoint(endpoint_text)
	if parse_err != .None {
		return 0, .Invalid_Address
	}
	jid := format_jid(endpoint.jid)
	defer delete(jid)
	if find_peer_jid(client^, jid) >= 0 {
		destroy_endpoint(&endpoint)
		return 0, .Invalid_Options
	}
	peer_id = client.next_peer_id
	client.next_peer_id += 1
	append(&client.peers, Peer{
		id = peer_id,
		endpoint = endpoint,
		presence = .Offline,
		connection = .Disconnected,
	})
	_ = session.add_peer(&client.engine, jid, endpoint.jid.ip, endpoint.port)
	return peer_id, .None
}

client_remove_peer :: proc(client: ^Client, peer_id: u64) -> Error {
	index := find_peer_slot(client^, peer_id)
	if index < 0 {
		return .Unknown_Peer
	}
	if client.engine.peers[index].active >= 0 {
		return .Already_Started
	}
	destroy_endpoint(&client.peers[index].endpoint)
	delete(client.peers[index].status_text)
	delete(client.peers[index].avatar_hash)
	delete(client.peers[index].avatar_mime)
	delete(client.peers[index].avatar_data)
	client.peers[index] = {}
	delete(client.engine.peers[index].jid)
	client.engine.peers[index].jid = ""
	return .None
}

client_get_peer :: proc(client: ^Client, peer_id: u64) -> (^Peer, bool) {
	index := find_peer_slot(client^, peer_id)
	if index < 0 {
		return nil, false
	}
	return &client.peers[index], true
}

client_peer_count :: proc(client: Client) -> int {
	count := 0
	for peer in client.peers {
		if peer.id != 0 {
			count += 1
		}
	}
	return count
}

client_peer_at :: proc(client: ^Client, ordinal: int) -> (^Peer, bool) {
	seen := 0
	for &peer in client.peers {
		if peer.id == 0 {
			continue
		}
		if seen == ordinal {
			return &peer, true
		}
		seen += 1
	}
	return nil, false
}

client_connect :: proc(client: ^Client, peer_id: u64) -> Error {
	index := find_peer_slot(client^, peer_id)
	if index < 0 {
		return .Unknown_Peer
	}
	return session_error(session.connect_peer(&client.engine, index))
}

client_disconnect :: proc(client: ^Client, peer_id: u64) -> Error {
	index := find_peer_slot(client^, peer_id)
	if index < 0 {
		return .Unknown_Peer
	}
	return session_error(session.disconnect_peer(&client.engine, index))
}

client_send_message :: proc(client: ^Client, peer_id: u64, body: string) -> Error {
	index := find_peer_slot(client^, peer_id)
	if index < 0 {
		return .Unknown_Peer
	}
	return session_error(session.send_message(&client.engine, index, body))
}

client_send_formatted_message :: proc(client: ^Client, peer_id: u64, body, xhtml_fragment: string) -> Error {
	index := find_peer_slot(client^, peer_id)
	if index < 0 {
		return .Unknown_Peer
	}
	return session_error(session.send_formatted_message(&client.engine, index, body, xhtml_fragment))
}

client_send_chat_state :: proc(client: ^Client, peer_id: u64, state: Chat_State) -> Error {
	index := find_peer_slot(client^, peer_id)
	if index < 0 {
		return .Unknown_Peer
	}
	return session_error(session.send_chat_state(&client.engine, index, state))
}

@(private)
transfer_error :: proc(err: transfer.Error) -> Error {
	switch err {
	case .None:        return .None
	case .Unsafe_Name: return .Unsafe_Path
	case .Too_Large:   return .Too_Large
	case .Too_Many:    return .Too_Many_Transfers
	case .Exists:      return .File_Exists
	case .IO:          return .IO
	case .Overflow:    return .Protocol
	case .Invalid:     return .Invalid_Options
	}
	return .IO
}

client_offer_file :: proc(client: ^Client, peer_id: u64, path: string) -> (transfer_id: u64, err: Error) {
	peer_index := find_peer_slot(client^, peer_id)
	if peer_index < 0 {
		return 0, .Unknown_Peer
	}
	offer_err: transfer.Error
	transfer_id, offer_err = transfer.offer_file(&client.transfers, peer_id, path)
	if offer_err != .None {
		return 0, transfer_error(offer_err)
	}
	value := transfer.find(&client.transfers, transfer_id)
	client.transfer_sequence += 1
	value.request_id = fmt.aprintf("odin-si-%d", client.transfer_sequence)
	value.stream_id = fmt.aprintf("odin-transfer-%d", client.transfer_sequence)
	if send_err := session.send_transfer_offer(&client.engine, peer_index, value.request_id, value.stream_id, value.filename, value.size); send_err != .None {
		_ = transfer.cancel(&client.transfers, transfer_id)
		return transfer_id, session_error(send_err)
	}
	return transfer_id, .None
}

client_accept_file :: proc(client: ^Client, transfer_id: u64, directory: string) -> Error {
	value := transfer.find(&client.transfers, transfer_id)
	if value == nil || value.direction != .Incoming {
		return .Invalid_Options
	}
	peer_index := find_peer_slot(client^, value.peer_id)
	if peer_index < 0 {
		return .Unknown_Peer
	}
	if accept_err := transfer.accept(&client.transfers, transfer_id, directory); accept_err != .None {
		return transfer_error(accept_err)
	}
	if send_err := session.send_transfer_accept(&client.engine, peer_index, value.request_id); send_err != .None {
		_ = transfer.cancel(&client.transfers, transfer_id)
		return session_error(send_err)
	}
	return .None
}

client_reject_file :: proc(client: ^Client, transfer_id: u64) -> Error {
	value := transfer.find(&client.transfers, transfer_id)
	if value == nil || value.direction != .Incoming {
		return .Invalid_Options
	}
	peer_index := find_peer_slot(client^, value.peer_id)
	if peer_index < 0 {
		return .Unknown_Peer
	}
	if send_err := session.send_transfer_reject(&client.engine, peer_index, value.request_id); send_err != .None {
		return session_error(send_err)
	}
	return transfer_error(transfer.reject(&client.transfers, transfer_id))
}

client_cancel_transfer :: proc(client: ^Client, transfer_id: u64) -> Error {
	value := transfer.find(&client.transfers, transfer_id)
	if value == nil {
		return .Invalid_Options
	}
	if cancel_err := transfer.cancel(&client.transfers, transfer_id); cancel_err != .None {
		return transfer_error(cancel_err)
	}
	for &channel in client.transfer_channels {
		if channel.transfer_id == transfer_id && channel.state != .Done {
			destroy_transfer_channel(&channel)
			channel.state = .Done
		}
	}
	queue_transfer_status(client, .Transfer_Cancelled, value)
	return .None
}

client_get_transfer :: proc(client: ^Client, transfer_id: u64) -> (info: Transfer_Info, ok: bool) {
	value := transfer.find(&client.transfers, transfer_id)
	if value == nil {
		return {}, false
	}
	return Transfer_Info{id=value.id, peer_id=value.peer_id, direction=value.direction, state=value.state, filename=value.filename, path=value.path, size=value.size, transferred=value.transferred}, true
}

@(private)
find_transfer_request :: proc(client: ^Client, peer_id: u64, request_id: string) -> ^transfer.Transfer {
	for &value in client.transfers.transfers {
		if value.peer_id == peer_id && value.request_id == request_id {
			return &value
		}
	}
	return nil
}

@(private)
find_transfer_stream :: proc(client: ^Client, peer_id: u64, stream_id: string) -> ^transfer.Transfer {
	for &value in client.transfers.transfers {
		if value.peer_id == peer_id && value.stream_id == stream_id {
			return &value
		}
	}
	return nil
}

client_set_avatar :: proc(client: ^Client, data: []u8, mime: string) -> Error {
	encoded, checksum, avatar_err := avatar.encode(data, mime, client.max_avatar_bytes)
	if avatar_err != .None {
		return .Invalid_Options
	}
	defer delete(encoded)
	defer delete(checksum)
	session.set_avatar(&client.engine, encoded, mime, checksum)
	return session_error(session.set_presence(&client.engine, client.engine.current_presence, client.engine.status_text))
}

client_clear_avatar :: proc(client: ^Client) -> Error {
	session.set_avatar(&client.engine, "", "", "")
	return session_error(session.set_presence(&client.engine, client.engine.current_presence, client.engine.status_text))
}

client_set_presence :: proc(client: ^Client, value: Presence, status := "") -> Error {
	return session_error(session.set_presence(&client.engine, value, status))
}

@(private)
queue_event :: proc(client: ^Client, value: Event) -> Error {
	if len(client.events) - client.event_head >= client.max_events {
		discarded := value
		destroy_event(&discarded)
		return .Queue_Full
	}
	append(&client.events, value)
	return .None
}

@(private)
connection_state :: proc(value: session.State) -> Connection_State {
	switch value {
	case .Disconnected:       return .Disconnected
	case .Connecting:         return .Connecting
	case .Stream_Negotiation: return .Stream_Negotiation
	case .Online:             return .Online
	}
	return .Disconnected
}

client_process :: proc(client: ^Client) -> Error {
	if !client.started {
		return .Not_Started
	}
	if process_err := session.process(&client.engine); process_err != .None {
		return session_error(process_err)
	}
	result := Error.None
	for source in client.engine.events {
		if source.peer_index < 0 || source.peer_index >= len(client.peers) || client.peers[source.peer_index].id == 0 {
			continue
		}
		peer := &client.peers[source.peer_index]
		peer.connection = connection_state(client.engine.peers[source.peer_index].state)
		peer.presence = client.engine.peers[source.peer_index].presence
		if source.kind == .Presence {
			delete(peer.status_text)
			peer.status_text = strings.clone(source.text)
		}
		if source.kind == .Avatar_Update {
			delete(peer.avatar_hash)
			peer.avatar_hash = strings.clone(source.text)
			if len(source.text) == 0 {
				delete(peer.avatar_mime)
				peer.avatar_mime = ""
				delete(peer.avatar_data)
				peer.avatar_data = nil
			}
		}
		kind := Event_Kind.Error
		error_value := Error.None
		data: []u8
		mime := source.mime
		event_transfer_id: u64
		event_size: i64
		event_transferred: i64
		switch source.kind {
		case .Connected:    kind = .Connected
		case .Disconnected: kind = .Disconnected
		case .Message:      kind = .Message
		case .Presence:     kind = .Presence
		case .Chat_State:   kind = .Chat_State
		case .Avatar_Update: kind = .Avatar_Update
		case .Avatar:
			decoded, checksum, avatar_err := avatar.decode(source.text, source.mime, client.max_avatar_bytes)
			if avatar_err != .None || len(peer.avatar_hash) > 0 && peer.avatar_hash != checksum {
				delete(decoded)
				delete(checksum)
				kind = .Error
				error_value = .Protocol
			} else {
				kind = .Avatar
				data = decoded
				delete(peer.avatar_data)
				peer.avatar_data = make([]u8, len(data))
				copy(peer.avatar_data, data)
				delete(peer.avatar_mime)
				peer.avatar_mime = strings.clone(source.mime)
				delete(peer.avatar_hash)
				peer.avatar_hash = checksum
			}
		case .Transfer_Offer:
			id, receive_err := transfer.receive_offer(&client.transfers, peer.id, source.text, source.size)
			if receive_err != .None {
				_ = session.send_transfer_reject(&client.engine, source.peer_index, source.request_id)
				kind = .Error
				error_value = transfer_error(receive_err)
			} else {
				value := transfer.find(&client.transfers, id)
				value.request_id = strings.clone(source.request_id)
				value.stream_id = strings.clone(source.transfer_id)
				kind = .Transfer_Offered
				event_transfer_id = id
				event_size = value.size
			}
		case .Transfer_Accepted:
			value := find_transfer_request(client, peer.id, source.request_id)
			if value == nil || value.direction != .Outgoing {
				kind = .Error
				error_value = .Protocol
			} else {
				if start_err := start_outgoing_channel(client, value, source.peer_index); start_err != .None {
					_ = transfer.cancel(&client.transfers, value.id)
					value.state = .Failed
					kind = .Transfer_Failed
					error_value = start_err
				} else {
					kind = .Transfer_Accepted
				}
				event_transfer_id = value.id
				event_size = value.size
			}
		case .Transfer_Rejected:
			value := find_transfer_request(client, peer.id, source.request_id)
			if value == nil {
				continue
			} else {
				_ = transfer.reject(&client.transfers, value.id)
				kind = .Transfer_Rejected
				event_transfer_id = value.id
				event_size = value.size
				event_transferred = value.transferred
			}
		case .Bytestream_Offer:
			value := find_transfer_stream(client, peer.id, source.transfer_id)
			if value == nil || value.direction != .Incoming || value.state != .Accepted && value.state != .Completed {
				kind = .Error
				error_value = .Protocol
			} else if start_err := start_incoming_channel(client, value, source.peer_index, source.host, source.port, source.request_id, source.mime); start_err != .None {
				_ = transfer.cancel(&client.transfers, value.id)
				value.state = .Failed
				kind = .Transfer_Failed
				error_value = start_err
			} else {
				continue
			}
			if value != nil {
				event_transfer_id = value.id
				event_size = value.size
				event_transferred = value.transferred
			}
		case .Bytestream_Used:
			continue
		case .Error:
			kind = .Error
			error_value = session_error(source.error)
		}
		value := Event{
			kind = kind,
			peer_id = peer.id,
			text = strings.clone(source.text),
			formatted = strings.clone(source.formatted),
			mime = strings.clone(mime),
			data = data,
			chat_state = source.chat_state,
			presence = source.presence,
			error = error_value,
			transfer_id = event_transfer_id,
			size = event_size,
			transferred = event_transferred,
			timestamp = time.now(),
		}
		if queue_err := queue_event(client, value); queue_err != .None {
			result = queue_err
		}
	}
	session.clear_events(&client.engine)
	process_transfer_channels(client)
	return result
}

client_poll_event :: proc(client: ^Client) -> (event: Event, ok: bool) {
	if client.event_head >= len(client.events) {
		if client.event_head > 0 {
			clear(&client.events)
			client.event_head = 0
		}
		return {}, false
	}
	event = client.events[client.event_head]
	client.events[client.event_head] = {}
	client.event_head += 1
	return event, true
}

client_save_contacts :: proc(client: Client, path: string) -> Error {
	records := make([dynamic]Endpoint, 0, client_peer_count(client), context.temp_allocator)
	for peer in client.peers {
		if peer.id != 0 {
			append(&records, peer.endpoint)
		}
	}
	if contacts.save(path, records[:]) != .None {
		return .Transport
	}
	return .None
}

client_load_contacts :: proc(client: ^Client, path: string) -> Error {
	records, load_err := contacts.load(path)
	if load_err != .None {
		return .Transport
	}
	defer contacts.destroy_all(&records)
	for record in records {
		formatted := format_endpoint(record, include_default_port=true, allocator=context.temp_allocator)
		_, add_err := client_add_peer(client, formatted)
		if add_err != .None {
			return add_err
		}
	}
	return .None
}
