package transport

import "core:net"
import "core:sys/linux"

DEFAULT_MAX_WRITE_QUEUE :: 1 << 20
READ_BUFFER_SIZE :: 16 << 10

Error :: enum {
	None,
	Would_Block,
	Closed,
	Queue_Full,
	Invalid,
	System,
}

Socket :: struct {
	fd:           linux.Fd,
	valid:        bool,
	connecting:   bool,
	write_queue:  [dynamic]u8,
	write_offset: int,
	max_queue:    int,
}

Listener :: struct {
	fd:    linux.Fd,
	valid: bool,
	port:  u16,
}

socket_address :: proc(ip: net.IP6_Address, port: u16) -> linux.Sock_Addr_In6 {
	return {
		sin6_family = .INET6,
		sin6_port = u16be(port),
		sin6_addr = transmute([16]u8)ip,
	}
}

set_common_options :: proc(fd: linux.Fd) {
	reuse: i32 = 1
	no_delay: i32 = 1
	_ = linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &reuse)
	_ = linux.setsockopt(fd, linux.SOL_TCP, linux.Socket_TCP_Option.NODELAY, &no_delay)
}

listen :: proc(ip: net.IP6_Address, port: u16, backlog: i32 = 10) -> (listener: Listener, err: Error) {
	fd, socket_err := linux.socket(.INET6, .STREAM, {.CLOEXEC, .NONBLOCK}, .TCP)
	if socket_err != .NONE {
		return {}, .System
	}
	set_common_options(fd)
	address := socket_address(ip, port)
	if bind_err := linux.bind(fd, &address); bind_err != .NONE {
		_ = linux.close(fd)
		return {}, .System
	}
	if listen_err := linux.listen(fd, backlog); listen_err != .NONE {
		_ = linux.close(fd)
		return {}, .System
	}
	bound: linux.Sock_Addr_Any
	if name_err := linux.getsockname(fd, &bound); name_err != .NONE {
		_ = linux.close(fd)
		return {}, .System
	}
	listener = {fd=fd, valid=true, port=u16(bound.ipv6.sin6_port)}
	return
}

close_listener :: proc(listener: ^Listener) {
	if listener.valid {
		_ = linux.close(listener.fd)
	}
	listener^ = {}
}

init_socket :: proc(fd: linux.Fd, connecting: bool, max_queue: int = DEFAULT_MAX_WRITE_QUEUE) -> Socket {
	return {
		fd = fd,
		valid = true,
		connecting = connecting,
		write_queue = make([dynamic]u8, 0, 4096),
		max_queue = max_queue,
	}
}

accept :: proc(listener: Listener, max_queue: int = DEFAULT_MAX_WRITE_QUEUE) -> (socket: Socket, remote_ip: net.IP6_Address, err: Error) {
	if !listener.valid {
		return {}, {}, .Invalid
	}
	address: linux.Sock_Addr_In6
	fd, accept_err := linux.accept(listener.fd, &address, {.CLOEXEC, .NONBLOCK})
	if accept_err == .EAGAIN {
		return {}, {}, .Would_Block
	}
	if accept_err != .NONE {
		return {}, {}, .System
	}
	set_common_options(fd)
	return init_socket(fd, false, max_queue), transmute(net.IP6_Address)address.sin6_addr, .None
}

dial :: proc(ip: net.IP6_Address, port: u16, max_queue: int = DEFAULT_MAX_WRITE_QUEUE) -> (socket: Socket, err: Error) {
	fd, socket_err := linux.socket(.INET6, .STREAM, {.CLOEXEC, .NONBLOCK}, .TCP)
	if socket_err != .NONE {
		return {}, .System
	}
	set_common_options(fd)
	address := socket_address(ip, port)
	connect_err := linux.connect(fd, &address)
	if connect_err != .NONE && connect_err != .EINPROGRESS {
		_ = linux.close(fd)
		return {}, .System
	}
	return init_socket(fd, connect_err == .EINPROGRESS, max_queue), .None
}

close_socket :: proc(socket: ^Socket) {
	if socket.valid {
		_ = linux.shutdown(socket.fd, .RDWR)
		_ = linux.close(socket.fd)
	}
	delete(socket.write_queue)
	socket^ = {}
}

poll_events :: proc(socket: Socket, wanted: linux.Fd_Poll_Events) -> (events: linux.Fd_Poll_Events, err: Error) {
	if !socket.valid {
		return {}, .Invalid
	}
	fds := [1]linux.Poll_Fd{{fd=socket.fd, events=wanted}}
	count, poll_err := linux.poll(fds[:], 0)
	if poll_err == .EINTR || count == 0 {
		return {}, .Would_Block
	}
	if poll_err != .NONE {
		return {}, .System
	}
	return fds[0].revents, .None
}

finish_connect :: proc(socket: ^Socket) -> Error {
	if !socket.valid {
		return .Invalid
	}
	if !socket.connecting {
		return .None
	}
	events, poll_err := poll_events(socket^, {.OUT, .ERR, .HUP})
	if poll_err != .None {
		return poll_err
	}
	if .OUT not_in events && .ERR not_in events && .HUP not_in events {
		return .Would_Block
	}
	result: i32
	_, option_err := linux.getsockopt_base(socket.fd, int(linux.SOL_SOCKET), linux.Socket_Option.ERROR, &result)
	if option_err != .NONE || result != 0 {
		return .System
	}
	socket.connecting = false
	return .None
}

queued_bytes :: proc(socket: Socket) -> int {
	return len(socket.write_queue) - socket.write_offset
}

queue :: proc(socket: ^Socket, data: []u8) -> Error {
	if !socket.valid {
		return .Invalid
	}
	if len(data) > socket.max_queue - queued_bytes(socket^) {
		return .Queue_Full
	}
	if socket.write_offset > 0 {
		remaining := queued_bytes(socket^)
		copy(socket.write_queue[:remaining], socket.write_queue[socket.write_offset:])
		resize(&socket.write_queue, remaining)
		socket.write_offset = 0
	}
	append(&socket.write_queue, ..data)
	return .None
}

flush :: proc(socket: ^Socket) -> Error {
	if !socket.valid {
		return .Invalid
	}
	if socket.connecting {
		return .Would_Block
	}
	for socket.write_offset < len(socket.write_queue) {
		written, send_err := linux.send(socket.fd, socket.write_queue[socket.write_offset:], {.NOSIGNAL})
		if send_err == .EAGAIN || send_err == .EINTR {
			return .Would_Block
		}
		if send_err != .NONE {
			return .Closed
		}
		if written <= 0 {
			return .Closed
		}
		socket.write_offset += written
	}
	clear(&socket.write_queue)
	socket.write_offset = 0
	return .None
}

receive :: proc(socket: ^Socket, buffer: []u8) -> (count: int, err: Error) {
	if !socket.valid || len(buffer) == 0 {
		return 0, .Invalid
	}
	receive_err: linux.Errno
	count, receive_err = linux.recv(socket.fd, buffer, {})
	if receive_err == .EAGAIN || receive_err == .EINTR {
		return 0, .Would_Block
	}
	if receive_err != .NONE || count == 0 {
		return 0, .Closed
	}
	return count, .None
}
