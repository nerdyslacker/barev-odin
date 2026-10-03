package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

import barev "barev:barev"

print_help :: proc() {
	fmt.println("commands:")
	fmt.println("  listen")
	fmt.println("  add <nick@ipv6|nick@[ipv6]:port>")
	fmt.println("  remove <peer-id>")
	fmt.println("  list")
	fmt.println("  connect <peer-id>")
	fmt.println("  disconnect <peer-id>")
	fmt.println("  message <peer-id> <text>")
	fmt.println("  rich <peer-id> <plain-token> <xhtml-fragment>")
	fmt.println("  typing <peer-id> <active|inactive|gone|composing|paused>")
	fmt.println("  avatar <image/png|image/jpeg|image/gif> <path>")
	fmt.println("  avatar-clear")
	fmt.println("  offer <peer-id> <path>")
	fmt.println("  accept <transfer-id> <directory>")
	fmt.println("  reject <transfer-id>")
	fmt.println("  cancel <transfer-id>")
	fmt.println("  status <available|away|xa|dnd|offline> [text]")
	fmt.println("  load <path>")
	fmt.println("  save <path>")
	fmt.println("  quit")
}

parse_peer_id :: proc(value: string) -> (u64, bool) {
	parsed, ok := strconv.parse_uint(value, 10)
	return u64(parsed), ok && parsed > 0
}

parse_presence :: proc(value: string) -> (barev.Presence, bool) {
	switch value {
	case "available": return .Available, true
	case "away":      return .Away, true
	case "xa":        return .Extended_Away, true
	case "dnd", "busy": return .Busy, true
	case "offline":   return .Offline, true
	}
	return .Offline, false
}

parse_chat_state :: proc(value: string) -> (barev.Chat_State, bool) {
	switch value {
	case "active":    return .Active, true
	case "inactive":  return .Inactive, true
	case "gone":      return .Gone, true
	case "composing": return .Composing, true
	case "paused":    return .Paused, true
	}
	return .None, false
}

print_peers :: proc(client: ^barev.Client) {
	for ordinal in 0 ..< barev.client_peer_count(client^) {
		peer, ok := barev.client_peer_at(client, ordinal)
		if !ok {
			continue
		}
		endpoint := barev.format_endpoint(peer.endpoint, include_default_port=true, allocator=context.temp_allocator)
		fmt.printf("%d  %s  connection=%v presence=%v status=%s\n", peer.id, endpoint, peer.connection, peer.presence, peer.status_text)
	}
}

handle_command :: proc(client: ^barev.Client, line: string) -> bool {
	fields := strings.fields(line)
	defer delete(fields)
	if len(fields) == 0 {
		return true
	}
	switch fields[0] {
	case "help":
		print_help()
	case "listen":
		fmt.printf("listening on [::]:%d\n", barev.client_port(client^))
	case "add":
		if len(fields) != 2 {
			fmt.println("usage: add <endpoint>")
			break
		}
		peer_id, err := barev.client_add_peer(client, fields[1])
		if err != .None {
			fmt.printf("add failed: %v\n", err)
		} else {
			fmt.printf("added peer %d\n", peer_id)
		}
	case "remove":
		if len(fields) != 2 {
			fmt.println("usage: remove <peer-id>")
			break
		}
		peer_id, ok := parse_peer_id(fields[1])
		if !ok {
			fmt.println("invalid peer id")
			break
		}
		fmt.printf("remove: %v\n", barev.client_remove_peer(client, peer_id))
	case "list":
		print_peers(client)
	case "connect", "disconnect":
		if len(fields) != 2 {
			fmt.printf("usage: %s <peer-id>\n", fields[0])
			break
		}
		peer_id, ok := parse_peer_id(fields[1])
		if !ok {
			fmt.println("invalid peer id")
			break
		}
		err := barev.client_connect(client, peer_id) if fields[0] == "connect" else barev.client_disconnect(client, peer_id)
		fmt.printf("%s: %v\n", fields[0], err)
	case "message", "msg":
		if len(fields) < 3 {
			fmt.println("usage: message <peer-id> <text>")
			break
		}
		peer_id, ok := parse_peer_id(fields[1])
		if !ok {
			fmt.println("invalid peer id")
			break
		}
		body := strings.join(fields[2:], " ")
		defer delete(body)
		fmt.printf("message: %v\n", barev.client_send_message(client, peer_id, body))
	case "rich":
		if len(fields) != 4 {
			fmt.println("usage: rich <peer-id> <plain-token> <xhtml-fragment>")
			break
		}
		peer_id, ok := parse_peer_id(fields[1])
		if !ok {
			fmt.println("invalid peer id")
			break
		}
		fmt.printf("rich: %v\n", barev.client_send_formatted_message(client, peer_id, fields[2], fields[3]))
	case "typing":
		if len(fields) != 3 {
			fmt.println("usage: typing <peer-id> <state>")
			break
		}
		peer_id, peer_ok := parse_peer_id(fields[1])
		state, state_ok := parse_chat_state(fields[2])
		if !peer_ok || !state_ok {
			fmt.println("invalid peer id or chat state")
			break
		}
		fmt.printf("typing: %v\n", barev.client_send_chat_state(client, peer_id, state))
	case "avatar":
		if len(fields) != 3 {
			fmt.println("usage: avatar <mime> <path>")
			break
		}
		data, read_err := os.read_entire_file(fields[2], context.allocator)
		if read_err != nil {
			fmt.println("avatar: IO")
			break
		}
		defer delete(data)
		fmt.printf("avatar: %v\n", barev.client_set_avatar(client, data, fields[1]))
	case "avatar-clear":
		fmt.printf("avatar-clear: %v\n", barev.client_clear_avatar(client))
	case "offer":
		if len(fields) != 3 {
			fmt.println("usage: offer <peer-id> <path>")
			break
		}
		peer_id, ok := parse_peer_id(fields[1])
		if !ok {
			fmt.println("invalid peer id")
			break
		}
		transfer_id, err := barev.client_offer_file(client, peer_id, fields[2])
		fmt.printf("offer: %v transfer=%d\n", err, transfer_id)
	case "accept":
		if len(fields) != 3 {
			fmt.println("usage: accept <transfer-id> <directory>")
			break
		}
		transfer_id, ok := parse_peer_id(fields[1])
		if !ok {
			fmt.println("invalid transfer id")
			break
		}
		fmt.printf("accept: %v\n", barev.client_accept_file(client, transfer_id, fields[2]))
	case "reject", "cancel":
		if len(fields) != 2 {
			fmt.printf("usage: %s <transfer-id>\n", fields[0])
			break
		}
		transfer_id, ok := parse_peer_id(fields[1])
		if !ok {
			fmt.println("invalid transfer id")
			break
		}
		err := barev.client_reject_file(client, transfer_id) if fields[0] == "reject" else barev.client_cancel_transfer(client, transfer_id)
		fmt.printf("%s: %v\n", fields[0], err)
	case "status":
		if len(fields) < 2 {
			fmt.println("usage: status <value> [text]")
			break
		}
		presence, ok := parse_presence(fields[1])
		if !ok {
			fmt.println("invalid presence")
			break
		}
		status := ""
		if len(fields) > 2 {
			status = strings.join(fields[2:], " ")
			defer delete(status)
		}
		fmt.printf("status: %v\n", barev.client_set_presence(client, presence, status))
	case "load", "save":
		if len(fields) != 2 {
			fmt.printf("usage: %s <path>\n", fields[0])
			break
		}
		err := barev.client_load_contacts(client, fields[1]) if fields[0] == "load" else barev.client_save_contacts(client^, fields[1])
		fmt.printf("%s: %v\n", fields[0], err)
	case "quit", "exit":
		return false
	case:
		fmt.println("unknown command; type help")
	}
	return true
}

print_events :: proc(client: ^barev.Client) {
	for {
		event, ok := barev.client_poll_event(client)
		if !ok {
			return
		}
		switch event.kind {
		case .Connected:    fmt.printf("peer %d connected\n", event.peer_id)
		case .Disconnected: fmt.printf("peer %d disconnected\n", event.peer_id)
		case .Message:      fmt.printf("message from %d: %s\n", event.peer_id, event.text)
		case .Presence:     fmt.printf("presence from %d: %v %s\n", event.peer_id, event.presence, event.text)
		case .Chat_State:   fmt.printf("chat state from %d: %v\n", event.peer_id, event.chat_state)
		case .Avatar_Update: fmt.printf("avatar update from %d: %s\n", event.peer_id, event.text)
		case .Avatar:       fmt.printf("avatar from %d: %s %d bytes\n", event.peer_id, event.mime, len(event.data))
		case .Transfer_Offered: fmt.printf("file offer from %d: transfer=%d name=%s size=%d\n", event.peer_id, event.transfer_id, event.text, event.size)
		case .Transfer_Accepted: fmt.printf("transfer %d accepted\n", event.transfer_id)
		case .Transfer_Progress: fmt.printf("transfer %d progress=%d/%d\n", event.transfer_id, event.transferred, event.size)
		case .Transfer_Completed: fmt.printf("transfer %d completed\n", event.transfer_id)
		case .Transfer_Rejected: fmt.printf("transfer %d rejected\n", event.transfer_id)
		case .Transfer_Cancelled: fmt.printf("transfer %d cancelled\n", event.transfer_id)
		case .Transfer_Failed: fmt.printf("transfer %d failed: %v\n", event.transfer_id, event.error)
		case .Error:        fmt.printf("peer %d error: %v\n", event.peer_id, event.error)
		case .Log:          fmt.printf("log: %s\n", event.text)
		}
		barev.destroy_event(&event)
	}
}

main :: proc() {
	if len(os.args) < 3 || len(os.args) > 4 {
		fmt.eprintf("usage: %s <nick> <bind-ipv6> [port]\n", os.args[0])
		os.exit(2)
	}
	options := barev.default_options(os.args[1], os.args[2])
	if len(os.args) == 4 {
		port, ok := strconv.parse_int(os.args[3], 10)
		if !ok || port < 1 || port > 65535 {
			fmt.eprintln("invalid port")
			os.exit(2)
		}
		options.port = u16(port)
	}
	client: barev.Client
	if err := barev.client_init(&client, options); err != .None {
		fmt.eprintf("initialization failed: %v\n", err)
		os.exit(1)
	}
	defer barev.client_destroy(&client)
	if err := barev.client_start(&client); err != .None {
		fmt.eprintf("listener failed: %v\n", err)
		os.exit(1)
	}
	fmt.printf("barev %s@%s listening on port %d\n", options.nick, options.bind_ipv6, barev.client_port(client))
	print_help()
	input := make([dynamic]u8, 0, 4096)
	defer delete(input)
	running := true
	for running {
		process_err := barev.client_process(&client)
		if process_err != .None && process_err != .Queue_Full {
			fmt.eprintf("process error: %v\n", process_err)
		}
		print_events(&client)
		poll_fds := [1]linux.Poll_Fd{{fd=linux.Fd(os.fd(os.stdin)), events={.IN, .HUP}}}
		count, poll_err := linux.poll(poll_fds[:], 20)
		if poll_err != .NONE {
			continue
		}
		if count > 0 && (.IN in poll_fds[0].revents || .HUP in poll_fds[0].revents) {
			buffer: [4096]u8
			read, read_err := os.read(os.stdin, buffer[:])
			if read_err != nil || read == 0 {
				break
			}
			append(&input, ..buffer[:read])
			for {
				newline := strings.index(string(input[:]), "\n")
				if newline < 0 {
					break
				}
				line := strings.trim_space(string(input[:newline]))
				running = handle_command(&client, line)
				remaining := len(input) - newline - 1
				copy(input[:remaining], input[newline + 1:])
				resize(&input, remaining)
				if !running {
					break
				}
			}
		}
	}
	barev.client_stop(&client)
}
