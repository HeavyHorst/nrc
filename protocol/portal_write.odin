package protocol

import "core:encoding/endian"

// Binary write proof: two big-endian uint64s and the 64-byte service key.
// Never serialized into an asset, review record, or response.
PORTAL_WRITE_PROOF_SIZE :: 80
Portal_Write_Proof :: struct {
	id, revision: u64,
	service_key:  string,
}

parse_portal_write_proof :: proc(data: []byte) -> Portal_Write_Proof {
	id, _ := endian.get_u64(data, .Big)
	revision, _ := endian.get_u64(data[8:], .Big)
	return {id, revision, string(data[16:PORTAL_WRITE_PROOF_SIZE])}
}
