package barev

import "core:time"

import address "barev:internal/address"
import protocol "barev:internal/protocol"
import transfer "barev:internal/transfer"

DEFAULT_PORT :: address.DEFAULT_PORT

JID :: address.JID
Endpoint :: address.Endpoint
Presence :: protocol.Presence
Chat_State :: protocol.Chat_State
Transfer_Direction :: transfer.Direction
Transfer_State :: transfer.State
Address_Error :: address.Error
Decode_Error :: protocol.Decode_Error
Stanza :: protocol.Stanza
Stanza_Kind :: protocol.Stanza_Kind
IQ_Type :: protocol.IQ_Type

parse_jid :: address.parse_jid
parse_endpoint :: address.parse_endpoint
destroy_jid :: address.destroy_jid
destroy_endpoint :: address.destroy_endpoint
format_jid :: address.format_jid
format_endpoint :: address.format_endpoint
is_yggdrasil :: address.is_yggdrasil

encode_stream_header :: protocol.stream_header
encode_stream_end :: protocol.stream_end
encode_message :: protocol.message
encode_presence :: protocol.presence
encode_ping :: protocol.ping
encode_pong :: protocol.pong
decode_stanza :: protocol.decode_stanza
destroy_stanza :: protocol.destroy_stanza

Connection_State :: enum {
	Disconnected,
	Connecting,
	Accepted,
	Stream_Negotiation,
	Online,
	Closing,
}

Event_Kind :: enum {
	Connected,
	Disconnected,
	Message,
	Presence,
	Chat_State,
	Avatar_Update,
	Avatar,
	Transfer_Offered,
	Transfer_Accepted,
	Transfer_Progress,
	Transfer_Completed,
	Transfer_Rejected,
	Transfer_Cancelled,
	Transfer_Failed,
	Error,
	Log,
}

Error :: enum {
	None,
	Invalid_Options,
	Invalid_Address,
	Not_Started,
	Already_Started,
	Already_Connected,
	Unknown_Peer,
	Not_Connected,
	Queue_Full,
	Protocol,
	Transport,
	Timeout,
	Unsafe_Path,
	Too_Large,
	Too_Many_Transfers,
	File_Exists,
	IO,
}

Client_Options :: struct {
	nick:                string,
	bind_ipv6:           string,
	port:                u16,
	connect_timeout:     time.Duration,
	ping_interval:       time.Duration,
	ping_timeout:        time.Duration,
	max_ping_failures:   u8,
	max_stanza_bytes:    int,
	max_receive_bytes:   int,
	max_queued_bytes:    int,
	max_queued_events:   int,
	max_avatar_bytes:    int,
	max_transfer_bytes:  i64,
	max_concurrent_transfers: int,
}

Peer :: struct {
	id:              u64,
	endpoint:        Endpoint,
	presence:        Presence,
	status_text:     string,
	connection:      Connection_State,
	identity_verified: bool,
	avatar_hash:     string,
	avatar_mime:     string,
	avatar_data:     []u8,
}

Event :: struct {
	kind:      Event_Kind,
	peer_id:   u64,
	text:      string,
	formatted: string,
	mime:      string,
	data:      []u8,
	chat_state: Chat_State,
	presence:  Presence,
	error:     Error,
	transfer_id: u64,
	size:      i64,
	transferred: i64,
	timestamp: time.Time,
}

Transfer_Info :: struct {
	id:          u64,
	peer_id:     u64,
	direction:   Transfer_Direction,
	state:       Transfer_State,
	filename:    string,
	path:        string,
	size:        i64,
	transferred: i64,
}

default_options :: proc(nick, bind_ipv6: string) -> Client_Options {
	return {
		nick = nick,
		bind_ipv6 = bind_ipv6,
		port = DEFAULT_PORT,
		connect_timeout = 10 * time.Second,
		ping_interval = 30 * time.Second,
		ping_timeout = 10 * time.Second,
		max_ping_failures = 2,
		max_stanza_bytes = 256 << 10,
		max_receive_bytes = 1 << 20,
		max_queued_bytes = 1 << 20,
		max_queued_events = 1024,
		max_avatar_bytes = 1 << 20,
		max_transfer_bytes = 1 << 30,
		max_concurrent_transfers = 4,
	}
}
