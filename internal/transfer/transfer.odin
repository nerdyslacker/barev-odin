package transfer

import "core:os"
import "core:path/filepath"
import "core:strings"

Direction :: enum {
	Outgoing,
	Incoming,
}

State :: enum {
	Offered,
	Accepted,
	Transferring,
	Completed,
	Rejected,
	Cancelled,
	Failed,
}

Error :: enum {
	None,
	Invalid,
	Unsafe_Name,
	Too_Large,
	Too_Many,
	Exists,
	IO,
	Overflow,
}

Transfer :: struct {
	id:          u64,
	peer_id:     u64,
	direction:   Direction,
	state:       State,
	filename:    string,
	path:        string,
	size:        i64,
	transferred: i64,
	request_id:  string,
	stream_id:   string,
	bytestream_request_id: string,
	file:        ^os.File,
}

Manager :: struct {
	transfers:      [dynamic]Transfer,
	next_id:        u64,
	max_size:       i64,
	max_concurrent: int,
}

init :: proc(manager: ^Manager, max_size: i64, max_concurrent: int) {
	manager^ = {
		transfers = make([dynamic]Transfer),
		next_id = 1,
		max_size = max_size,
		max_concurrent = max_concurrent,
	}
}

close_file :: proc(value: ^Transfer) {
	if value.file != nil {
		os.close(value.file)
		value.file = nil
	}
}

destroy :: proc(manager: ^Manager) {
	for &value in manager.transfers {
		close_file(&value)
		delete(value.filename)
		delete(value.path)
		delete(value.request_id)
		delete(value.stream_id)
		delete(value.bytestream_request_id)
	}
	delete(manager.transfers)
	manager^ = {}
}

safe_filename :: proc(name: string) -> bool {
	if len(name) == 0 || name == "." || name == ".." || strings.contains(name, "/") || strings.contains(name, "\\") {
		return false
	}
	for byte in transmute([]u8)name {
		if byte == 0 || byte < 0x20 || byte == 0x7f {
			return false
		}
	}
	return true
}

active_count :: proc(manager: Manager) -> int {
	count := 0
	for value in manager.transfers {
		if value.state == .Offered || value.state == .Accepted || value.state == .Transferring {
			count += 1
		}
	}
	return count
}

find :: proc(manager: ^Manager, id: u64) -> ^Transfer {
	for &value in manager.transfers {
		if value.id == id {
			return &value
		}
	}
	return nil
}

offer_file :: proc(manager: ^Manager, peer_id: u64, path: string) -> (id: u64, err: Error) {
	if peer_id == 0 || active_count(manager^) >= manager.max_concurrent {
		return 0, .Too_Many
	}
	info, stat_err := os.stat(path, context.temp_allocator)
	if stat_err != nil || info.type != .Regular {
		return 0, .Invalid
	}
	if info.size < 0 || info.size > manager.max_size {
		return 0, .Too_Large
	}
	name := filepath.base(path)
	if !safe_filename(name) {
		return 0, .Unsafe_Name
	}
	file, open_err := os.open(path, os.O_RDONLY)
	if open_err != nil {
		return 0, .IO
	}
	id = manager.next_id
	manager.next_id += 1
	append(&manager.transfers, Transfer{id=id, peer_id=peer_id, direction=.Outgoing, state=.Offered, filename=strings.clone(name), path=strings.clone(path), size=info.size, file=file})
	return id, .None
}

receive_offer :: proc(manager: ^Manager, peer_id: u64, filename: string, size: i64) -> (id: u64, err: Error) {
	if peer_id == 0 || size < 0 {
		return 0, .Invalid
	}
	if !safe_filename(filename) {
		return 0, .Unsafe_Name
	}
	if size > manager.max_size {
		return 0, .Too_Large
	}
	if active_count(manager^) >= manager.max_concurrent {
		return 0, .Too_Many
	}
	id = manager.next_id
	manager.next_id += 1
	append(&manager.transfers, Transfer{id=id, peer_id=peer_id, direction=.Incoming, state=.Offered, filename=strings.clone(filename), size=size})
	return id, .None
}

accept :: proc(manager: ^Manager, id: u64, directory: string) -> Error {
	value := find(manager, id)
	if value == nil || value.direction != .Incoming || value.state != .Offered {
		return .Invalid
	}
	path, join_err := filepath.join({directory, value.filename})
	if join_err != nil {
		return .IO
	}
	file, open_err := os.open(path, os.File_Flags{.Write, .Create, .Excl}, os.perm(0o600))
	if open_err != nil {
		delete(path)
		return .Exists
	}
	value.path = path
	value.file = file
	value.state = .Accepted
	if value.size == 0 {
		close_file(value)
		value.state = .Completed
	}
	return .None
}

begin_outgoing :: proc(manager: ^Manager, id: u64) -> Error {
	value := find(manager, id)
	if value == nil || value.direction != .Outgoing || value.state != .Offered {
		return .Invalid
	}
	value.state = .Transferring
	if value.size == 0 {
		close_file(value)
		value.state = .Completed
	}
	return .None
}

read_chunk :: proc(manager: ^Manager, id: u64, buffer: []u8) -> (count: int, err: Error) {
	value := find(manager, id)
	if value == nil || value.direction != .Outgoing || value.state != .Transferring || len(buffer) == 0 {
		return 0, .Invalid
	}
	read_err: os.Error
	count, read_err = os.read(value.file, buffer)
	if read_err != nil && read_err != .EOF {
		value.state = .Failed
		close_file(value)
		return 0, .IO
	}
	value.transferred += i64(count)
	if value.transferred == value.size {
		value.state = .Completed
		close_file(value)
	} else if value.transferred > value.size || count == 0 {
		value.state = .Failed
		close_file(value)
		return count, .Overflow
	}
	return count, .None
}

write_chunk :: proc(manager: ^Manager, id: u64, data: []u8) -> Error {
	value := find(manager, id)
	if value == nil || value.direction != .Incoming || value.state != .Accepted && value.state != .Transferring {
		return .Invalid
	}
	if value.transferred + i64(len(data)) > value.size {
		value.state = .Failed
		close_file(value)
		return .Overflow
	}
	value.state = .Transferring
	if len(data) > 0 {
		written, write_err := os.write(value.file, data)
		if write_err != nil || written != len(data) {
			value.state = .Failed
			close_file(value)
			return .IO
		}
	}
	value.transferred += i64(len(data))
	if value.transferred == value.size {
		close_file(value)
		value.state = .Completed
	}
	return .None
}

reject :: proc(manager: ^Manager, id: u64) -> Error {
	value := find(manager, id)
	if value == nil || value.state != .Offered {
		return .Invalid
	}
	close_file(value)
	value.state = .Rejected
	return .None
}

cancel :: proc(manager: ^Manager, id: u64) -> Error {
	value := find(manager, id)
	if value == nil || value.state == .Completed || value.state == .Rejected || value.state == .Cancelled {
		return .Invalid
	}
	close_file(value)
	if value.direction == .Incoming && len(value.path) > 0 {
		_ = os.remove(value.path)
	}
	value.state = .Cancelled
	return .None
}
