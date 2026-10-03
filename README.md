# Barev Odin Library

An Odin implementation of the Barev protocol: simplified peer-to-peer messaging over Yggdrasil IPv6 networks.

## Overview

Barev connects peers directly without a central server, using one TCP connection per peer.

- **JID format:** `nick@yggdrasil_ipv6_address`
- **Endpoint format:** `nick@[yggdrasil_ipv6_address]:port`
- **Default port:** `5299`, configurable through `Client_Options`
- **Transport:** nonblocking TCP over IPv6
- **Security:** transport encryption is provided by Yggdrasil; peer names are not cryptographic identities

The library supports messages, presence and status text, chat states, XHTML-IM fallback, avatars, contact files, ping/pong, and explicitly accepted file transfers. Incoming transfers can target either a directory or an explicit file path, with overwrite disabled unless the caller opts in.

## Project structure

```text
barev/                 Public client API
internal/              Protocol, session, transport, contacts, avatars, and transfers
cmd/barev-cli/         Interactive command-line client
```

Applications should import only `barev:barev`; packages below `internal/` are implementation details.

## Requirements

- Odin `dev-2026-09` or a compatible newer version
- GNU Make
- Linux with IPv6 support
- A running Yggdrasil node for communication outside loopback development

## Building

```sh
make build
```

This creates `build/barev-cli`. Other useful commands are:

```sh
make check
make run
```

To use the package from another Odin project, point a collection at the directory containing this README:

```sh
odin build . -collection:barev=/path/to/barev-odin
```

Then import the public package:

```odin
import barev "barev:barev"
```

## Usage

```odin
package main

import "core:fmt"
import "core:time"

import barev "barev:barev"

main :: proc() {
	options := barev.default_options("alice", "201:db8::1")
	client: barev.Client

	if barev.client_init(&client, options) != .None {
		return
	}
	defer barev.client_destroy(&client)

	if barev.client_start(&client) != .None {
		return
	}
	defer barev.client_stop(&client)

	peer_id, err := barev.client_add_peer(&client, "bob@[201:db8::2]:5299")
	if err == .None {
		_ = barev.client_connect(&client, peer_id)
	}

	for {
		_ = barev.client_process(&client)
		for {
			event, ok := barev.client_poll_event(&client)
			if !ok {
				break
			}
			if event.kind == .Message {
				fmt.printf("peer %d: %s\n", event.peer_id, event.text)
			}
			barev.destroy_event(&event)
		}
		time.sleep(16 * time.Millisecond)
	}
}
```

`client_process` is nonblocking and must be called regularly. Every event returned by `client_poll_event` is owned by the caller and must be released with `destroy_event`.

## Command-line client

Start the CLI with a nickname, local Yggdrasil IPv6 address, and optional port:

```sh
./build/barev-cli alice 201:db8::1
./build/barev-cli alice 201:db8::1 5299
```

Type `help` to list commands. The CLI can add and remove peers, connect, exchange messages and presence, manage avatars and contacts, and handle file transfers.

## Contact files

Contact files contain one endpoint per line. Empty lines and lines beginning with `#` are ignored.

```text
# Barev contacts
alice@201:db8::1
bob@[201:db8::2]:5300
```
