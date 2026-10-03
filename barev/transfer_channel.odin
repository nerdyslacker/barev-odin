#+private
package barev

import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"

import avatar "barev:internal/avatar"
import session "barev:internal/session"
import transfer "barev:internal/transfer"
import transport "barev:internal/transport"

Transfer_Channel_State :: enum {
	Server_Accept,
	Server_Greeting,
	Server_Request,
	Client_Connect,
	Client_Method,
	Client_Reply,
	Sending,
	Receiving,
	Draining,
	Done,
}

Transfer_Channel :: struct {
	transfer_id: u64,
	peer_index: int,
	state: Transfer_Channel_State,
	listener: transport.Listener,
	socket: transport.Socket,
	handshake: [dynamic]u8,
	expected_hash: string,
	request_id: string,
	streamhost_jid: string,
	created_at: time.Time,
	emitted: bool,
}

destroy_transfer_channel :: proc(channel: ^Transfer_Channel) {
	transport.close_listener(&channel.listener)
	transport.close_socket(&channel.socket)
	delete(channel.handshake)
	delete(channel.expected_hash)
	delete(channel.request_id)
	delete(channel.streamhost_jid)
	channel^ = {}
}

transfer_hash :: proc(stream_id, initiator, target: string) -> string {
	joined := strings.concatenate({stream_id, initiator, target}, context.temp_allocator)
	return avatar.hash(transmute([]u8)joined)
}

queue_transfer_status :: proc(client: ^Client, kind: Event_Kind, value: ^transfer.Transfer, err: Error = .None) {
	_ = queue_event(client, Event{kind=kind, peer_id=value.peer_id, text=strings.clone(value.filename), transfer_id=value.id, size=value.size, transferred=value.transferred, error=err, timestamp=time.now()})
}

fail_transfer_channel :: proc(client: ^Client, channel: ^Transfer_Channel, err: Error) {
	value := transfer.find(&client.transfers, channel.transfer_id)
	if value != nil {
		_ = transfer.cancel(&client.transfers, value.id)
		value.state = .Failed
		queue_transfer_status(client, .Transfer_Failed, value, err)
	}
	destroy_transfer_channel(channel)
	channel.state = .Done
}

start_outgoing_channel :: proc(client: ^Client, value: ^transfer.Transfer, peer_index: int) -> Error {
	listener, listen_err := transport.listen(client.engine.bind_ip, 0)
	if listen_err != .None {
		return .Transport
	}
	client.transfer_sequence += 1
	delete(value.bytestream_request_id)
	request_id := session_transfer_request_id(client.transfer_sequence)
	value.bytestream_request_id = strings.clone(request_id)
	host := net.to_string(client.engine.bind_ip, context.temp_allocator)
	if send_err := session.send_bytestream_offer(&client.engine, peer_index, request_id, value.stream_id, client.engine.local_jid, host, listener.port); send_err != .None {
		transport.close_listener(&listener)
		delete(request_id)
		return session_error(send_err)
	}
	expected := transfer_hash(value.stream_id, client.engine.local_jid, client.engine.peers[peer_index].jid)
	append(&client.transfer_channels, Transfer_Channel{transfer_id=value.id, peer_index=peer_index, state=.Server_Accept, listener=listener, handshake=make([dynamic]u8), expected_hash=expected, request_id=request_id, created_at=time.now()})
	return .None
}

session_transfer_request_id :: proc(sequence: u64) -> string {
	return fmt.aprintf("odin-bs-%d", sequence)
}

start_incoming_channel :: proc(client: ^Client, value: ^transfer.Transfer, peer_index: int, host: string, port: u16, request_id, streamhost_jid: string) -> Error {
	ip, ok := net.parse_ip6_address(host)
	if !ok || ip != client.engine.peers[peer_index].ip || !session.same_jid(streamhost_jid, client.engine.peers[peer_index].jid) {
		return .Protocol
	}
	socket, dial_err := transport.dial(ip, port, client.engine.max_write_queue)
	if dial_err != .None {
		return .Transport
	}
	expected := transfer_hash(value.stream_id, client.engine.peers[peer_index].jid, client.engine.local_jid)
	append(&client.transfer_channels, Transfer_Channel{transfer_id=value.id, peer_index=peer_index, state=.Client_Connect, socket=socket, handshake=make([dynamic]u8), expected_hash=expected, request_id=strings.clone(request_id), streamhost_jid=strings.clone(streamhost_jid), created_at=time.now()})
	return .None
}

receive_handshake :: proc(channel: ^Transfer_Channel) -> transport.Error {
	buffer: [256]u8
	count, receive_err := transport.receive(&channel.socket, buffer[:])
	if receive_err != .None {
		return receive_err
	}
	if len(channel.handshake) + count > 256 {
		return .Invalid
	}
	append(&channel.handshake, ..buffer[:count])
	return .None
}

consume_handshake :: proc(channel: ^Transfer_Channel, count: int) {
	remaining := len(channel.handshake) - count
	copy(channel.handshake[:remaining], channel.handshake[count:])
	resize(&channel.handshake, remaining)
}

process_transfer_channel :: proc(client: ^Client, channel: ^Transfer_Channel) {
	value := transfer.find(&client.transfers, channel.transfer_id)
	if value == nil || value.state == .Cancelled || value.state == .Rejected || value.state == .Failed {
		destroy_transfer_channel(channel)
		channel.state = .Done
		return
	}
	if channel.state != .Sending && channel.state != .Receiving && channel.state != .Draining && time.since(channel.created_at) > client.engine.connect_timeout {
		fail_transfer_channel(client, channel, .Timeout)
		return
	}
	switch channel.state {
	case .Server_Accept:
		socket, remote_ip, accept_err := transport.accept(channel.listener, client.engine.max_write_queue)
		if accept_err == .Would_Block {
			return
		}
		if accept_err != .None || remote_ip != client.engine.peers[channel.peer_index].ip {
			if socket.valid { transport.close_socket(&socket) }
			fail_transfer_channel(client, channel, .Transport)
			return
		}
		transport.close_listener(&channel.listener)
		channel.socket = socket
		channel.state = .Server_Greeting
	case .Client_Connect:
		connect_err := transport.finish_connect(&channel.socket)
		if connect_err == .Would_Block { return }
		if connect_err != .None {
			fail_transfer_channel(client, channel, .Transport)
			return
		}
		_ = transport.queue(&channel.socket, []u8{5, 1, 0})
		channel.state = .Client_Method
	case .Server_Greeting, .Server_Request, .Client_Method, .Client_Reply, .Sending, .Receiving, .Draining, .Done:
		if channel.state == .Done { return }
	}
	flush_err := transport.flush(&channel.socket)
	if flush_err != .None && flush_err != .Would_Block {
		fail_transfer_channel(client, channel, .Transport)
		return
	}
	if channel.state == .Server_Greeting || channel.state == .Server_Request || channel.state == .Client_Method || channel.state == .Client_Reply {
		receive_err := receive_handshake(channel)
		if receive_err != .None && receive_err != .Would_Block {
			fail_transfer_channel(client, channel, .Transport)
			return
		}
	}
	if channel.state == .Server_Greeting && len(channel.handshake) >= 3 {
		if channel.handshake[0] != 5 || channel.handshake[1] != 1 || channel.handshake[2] != 0 {
			fail_transfer_channel(client, channel, .Protocol)
			return
		}
		consume_handshake(channel, 3)
		_ = transport.queue(&channel.socket, []u8{5, 0})
		channel.state = .Server_Request
	}
	if channel.state == .Client_Method && len(channel.handshake) >= 2 {
		if channel.handshake[0] != 5 || channel.handshake[1] != 0 {
			fail_transfer_channel(client, channel, .Protocol)
			return
		}
		consume_handshake(channel, 2)
		request := make([]u8, 47, context.temp_allocator)
		copy(request[:5], []u8{5, 1, 0, 3, 40})
		copy(request[5:45], transmute([]u8)channel.expected_hash)
		_ = transport.queue(&channel.socket, request)
		channel.state = .Client_Reply
	}
	if channel.state == .Server_Request && len(channel.handshake) >= 47 {
		if channel.handshake[0] != 5 || channel.handshake[1] != 1 || channel.handshake[2] != 0 || channel.handshake[3] != 3 || channel.handshake[4] != 40 || string(channel.handshake[5:45]) != channel.expected_hash {
			fail_transfer_channel(client, channel, .Protocol)
			return
		}
		consume_handshake(channel, 47)
		reply := make([]u8, 47, context.temp_allocator)
		copy(reply[:5], []u8{5, 0, 0, 3, 40})
		copy(reply[5:45], transmute([]u8)channel.expected_hash)
		_ = transport.queue(&channel.socket, reply)
		if begin_err := transfer.begin_outgoing(&client.transfers, value.id); begin_err != .None {
			fail_transfer_channel(client, channel, transfer_error(begin_err))
			return
		}
		channel.state = .Sending
	}
	if channel.state == .Client_Reply && len(channel.handshake) >= 47 {
		if channel.handshake[0] != 5 || channel.handshake[1] != 0 || channel.handshake[3] != 3 || channel.handshake[4] != 40 || string(channel.handshake[5:45]) != channel.expected_hash {
			fail_transfer_channel(client, channel, .Protocol)
			return
		}
		consume_handshake(channel, 47)
		if send_err := session.send_bytestream_used(&client.engine, channel.peer_index, channel.request_id, value.stream_id, channel.streamhost_jid); send_err != .None {
			fail_transfer_channel(client, channel, session_error(send_err))
			return
		}
		channel.state = .Receiving
		queue_transfer_status(client, .Transfer_Accepted, value)
	}
	if channel.state == .Sending {
		buffer: [transport.READ_BUFFER_SIZE]u8
		if transport.queued_bytes(channel.socket) < transport.READ_BUFFER_SIZE {
			count, read_err := transfer.read_chunk(&client.transfers, value.id, buffer[:])
			if read_err != .None || count > 0 && transport.queue(&channel.socket, buffer[:count]) != .None {
				fail_transfer_channel(client, channel, .IO)
				return
			}
			queue_transfer_status(client, .Transfer_Progress, value)
			if value.state == .Completed {
				channel.state = .Draining
			}
		}
	}
	if channel.state == .Draining && transport.queued_bytes(channel.socket) == 0 {
		queue_transfer_status(client, .Transfer_Completed, value)
		destroy_transfer_channel(channel)
		channel.state = .Done
	}
	if channel.state == .Receiving {
		if value.state == .Completed {
			queue_transfer_status(client, .Transfer_Completed, value)
			destroy_transfer_channel(channel)
			channel.state = .Done
			return
		}
		if len(channel.handshake) > 0 {
			if transfer.write_chunk(&client.transfers, value.id, channel.handshake[:]) != .None {
				fail_transfer_channel(client, channel, .IO)
				return
			}
			clear(&channel.handshake)
			queue_transfer_status(client, .Transfer_Progress, value)
			if value.state == .Completed {
				queue_transfer_status(client, .Transfer_Completed, value)
				destroy_transfer_channel(channel)
				channel.state = .Done
				return
			}
		}
		buffer: [transport.READ_BUFFER_SIZE]u8
		count, receive_err := transport.receive(&channel.socket, buffer[:])
		if receive_err == .Would_Block { return }
		if receive_err != .None || transfer.write_chunk(&client.transfers, value.id, buffer[:count]) != .None {
			fail_transfer_channel(client, channel, .IO)
			return
		}
		queue_transfer_status(client, .Transfer_Progress, value)
		if value.state == .Completed {
			queue_transfer_status(client, .Transfer_Completed, value)
			destroy_transfer_channel(channel)
			channel.state = .Done
		}
	}
}

process_transfer_channels :: proc(client: ^Client) {
	for &channel in client.transfer_channels {
		if channel.state != .Done {
			process_transfer_channel(client, &channel)
		}
	}
}
