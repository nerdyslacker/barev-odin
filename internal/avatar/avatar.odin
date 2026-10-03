package avatar

import "base:runtime"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/hex"

Error :: enum {
	None,
	Empty,
	Too_Large,
	Invalid_Mime,
	Invalid_Base64,
}

valid_mime :: proc(value: string) -> bool {
	return value == "image/png" || value == "image/jpeg" || value == "image/gif"
}

hash :: proc(data: []u8, allocator := context.allocator) -> string {
	if len(data) == 0 {
		return ""
	}
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, data)
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	encoded, encode_err := hex.encode(digest[:], allocator)
	if encode_err != nil {
		return ""
	}
	return transmute(string)encoded
}

encode :: proc(data: []u8, mime: string, max_bytes: int, allocator := context.allocator) -> (encoded, checksum: string, err: Error) {
	if len(data) == 0 {
		return "", "", .Empty
	}
	if len(data) > max_bytes {
		return "", "", .Too_Large
	}
	if !valid_mime(mime) {
		return "", "", .Invalid_Mime
	}
	alloc_err: runtime.Allocator_Error
	encoded, alloc_err = base64.encode(data, allocator=allocator)
	if alloc_err != nil {
		return "", "", .Too_Large
	}
	checksum = hash(data, allocator)
	return encoded, checksum, .None
}

decode :: proc(encoded, mime: string, max_bytes: int, allocator := context.allocator) -> (data: []u8, checksum: string, err: Error) {
	if len(encoded) == 0 {
		return nil, "", .Empty
	}
	if !valid_mime(mime) {
		return nil, "", .Invalid_Mime
	}
	if len(encoded) > (max_bytes + 2) / 3 * 4 + 4 {
		return nil, "", .Too_Large
	}
	decoded, decode_err := base64.decode(encoded, allocator=allocator)
	if decode_err != nil {
		return nil, "", .Invalid_Base64
	}
	if len(decoded) == 0 || len(decoded) > max_bytes {
		delete(decoded, allocator)
		return nil, "", .Too_Large
	}
	checksum = hash(decoded, allocator)
	return decoded, checksum, .None
}
