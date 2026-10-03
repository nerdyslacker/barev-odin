package address

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

DEFAULT_PORT :: 5299

Error :: enum {
	None,
	Empty,
	Invalid_Nick,
	Missing_Separator,
	Invalid_IPv6,
	Invalid_Endpoint,
	Invalid_Port,
}

JID :: struct {
	nick:    string,
	address: string,
	ip:      net.IP6_Address,
}

Endpoint :: struct {
	jid:  JID,
	port: u16,
}

valid_nick :: proc(nick: string) -> bool {
	if len(nick) == 0 {
		return false
	}
	for byte in transmute([]u8)nick {
		if byte <= ' ' || byte == 0x7f || byte == '@' || byte == '/' || byte == '[' || byte == ']' {
			return false
		}
	}
	return true
}

parse_parts :: proc(input: string) -> (nick, address: string, ip: net.IP6_Address, err: Error) {
	if len(input) == 0 {
		err = .Empty
		return
	}
	at := strings.index(input, "@")
	if at < 0 {
		err = .Missing_Separator
		return
	}
	if strings.last_index(input, "@") != at {
		err = .Invalid_Nick
		return
	}
	nick = input[:at]
	address = input[at + 1:]
	if !valid_nick(nick) {
		err = .Invalid_Nick
		return
	}
	if len(address) == 0 || address[0] == '[' || strings.contains(address, "]") || strings.contains(address, "%") {
		err = .Invalid_IPv6
		return
	}
	parsed, ok := net.parse_ip6_address(address)
	if !ok {
		err = .Invalid_IPv6
		return
	}
	ip = parsed
	return
}

parse_jid :: proc(input: string, allocator := context.allocator) -> (jid: JID, err: Error) {
	nick, _, ip, parse_err := parse_parts(input)
	if parse_err != .None {
		err = parse_err
		return
	}
	canonical := net.to_string(ip)
	jid.nick = strings.clone(nick, allocator)
	jid.address = strings.clone(canonical, allocator)
	jid.ip = ip
	return
}

parse_endpoint :: proc(input: string, default_port: u16 = DEFAULT_PORT, allocator := context.allocator) -> (endpoint: Endpoint, err: Error) {
	at := strings.index(input, "@")
	if at < 0 {
		err = .Missing_Separator
		return
	}
	if at + 1 >= len(input) {
		err = .Invalid_IPv6
		return
	}
	tail := input[at + 1:]
	port := default_port
	jid_input := input
	if tail[0] == '[' {
		close := strings.index(tail, "]")
		if close < 0 || close + 2 > len(tail) || close + 1 >= len(tail) || tail[close + 1] != ':' {
			err = .Invalid_Endpoint
			return
		}
		parsed_port, ok := strconv.parse_int(tail[close + 2:], 10)
		if !ok || parsed_port < 1 || parsed_port > 65535 {
			err = .Invalid_Port
			return
		}
		if close + 2 >= len(tail) {
			err = .Invalid_Port
			return
		}
		port = u16(parsed_port)
		jid_input = fmt.aprintf("%s@%s", input[:at], tail[1:close], allocator=context.temp_allocator)
	} else if strings.contains(tail, "]") || strings.contains(tail, "[") {
		err = .Invalid_Endpoint
		return
	}
	jid, jid_err := parse_jid(jid_input, allocator)
	if jid_err != .None {
		err = jid_err
		return
	}
	endpoint = Endpoint{jid=jid, port=port}
	return
}

destroy_jid :: proc(jid: ^JID, allocator := context.allocator) {
	delete(jid.nick, allocator)
	delete(jid.address, allocator)
	jid^ = {}
}

destroy_endpoint :: proc(endpoint: ^Endpoint, allocator := context.allocator) {
	destroy_jid(&endpoint.jid, allocator)
	endpoint^ = {}
}

format_jid :: proc(jid: JID, allocator := context.allocator) -> string {
	return fmt.aprintf("%s@%s", jid.nick, jid.address, allocator=allocator)
}

format_endpoint :: proc(endpoint: Endpoint, include_default_port := false, allocator := context.allocator) -> string {
	if endpoint.port == DEFAULT_PORT && !include_default_port {
		return format_jid(endpoint.jid, allocator)
	}
	return fmt.aprintf("%s@[%s]:%d", endpoint.jid.nick, endpoint.jid.address, endpoint.port, allocator=allocator)
}

is_yggdrasil :: proc(ip: net.IP6_Address) -> bool {
	first := u16(ip[0])
	return first >= 0x0200 && first <= 0x03ff
}

error_string :: proc(err: Error) -> string {
	switch err {
	case .None:              return "none"
	case .Empty:             return "empty input"
	case .Invalid_Nick:      return "invalid nickname"
	case .Missing_Separator: return "missing @ separator"
	case .Invalid_IPv6:      return "invalid IPv6 address"
	case .Invalid_Endpoint:  return "invalid endpoint syntax"
	case .Invalid_Port:      return "invalid port"
	}
	return "unknown address error"
}
