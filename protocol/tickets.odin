package protocol

import "core:encoding/endian"

// JSON carries metadata predicates and value cursors; assets retain the ordinary
// binary encoding (including attachments and compressed payloads).
TicketQueryRequest :: struct {
	correlation_id: u32,
	query:          []byte,
}

parseTicketQueryRequest :: proc(data: []byte) -> (r: TicketQueryRequest, err: ProtocolParseError) {
	if len(data) < 6 do return r, .TooShort
	if len(data) > 65536 do return r, .ContentLengthExceedsMax
	r.correlation_id, _ = endian.get_u32(data, .Big)
	r.query = data[4:]
	return
}

TicketPage :: struct {
	correlation_id: u32,
	metadata:       []byte,
	assets:         []Asset,
	full_content:   bool,
}

getSizeTicketPage :: proc(m: TicketPage) -> int {
	n := 13 + len(m.metadata)
	for asset in m.assets do n += m.full_content ? getSizeAsset(asset) : getSizeAssetHeader(asset)
	return n
}

serializeTicketPage :: proc(m: TicketPage, buf: []byte) -> int {
	if len(m.assets) > 65535 || len(buf) < getSizeTicketPage(m) do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_TicketPage))
	endian.put_u32(buf[2:], .Big, m.correlation_id)
	endian.put_u32(buf[6:], .Big, u32(len(m.metadata)))
	copy(buf[10:], m.metadata)
	o := 10 + len(m.metadata)
	endian.put_u16(buf[o:], .Big, u16(len(m.assets))); o += 2
	buf[o] = m.full_content ? 1 : 0; o += 1
	for asset in m.assets {
		n := m.full_content ? serializeAsset(asset, buf[o:]) : serializeAssetHeader(asset, buf[o:])
		if n < 0 do return -1
		o += n
	}
	return o
}
