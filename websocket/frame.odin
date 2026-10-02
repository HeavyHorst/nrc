package websocket

import "core:encoding/endian"

MaxUint16 :: 1 << 16 - 1 // 65535

frame_error :: enum u8 {
	None,
	tooShort,
	protocolError,
}

frame_iterator_status :: enum u8 {
	Ok,
	Incomplete,
	Protocol_Error,
}

opcode :: enum u8 {
	opContinuation,
	opText,
	opBinary,
	// 3 - 7 are reserved for further non-control frames.
	_reserved_3,
	_reserved_4,
	_reserved_5,
	_reserved_6,
	_reserved_7,
	opClose,
	opPing,
	opPong,
	// 11-15 are reserved for further control frames.
	_reserved_11,
	_reserved_12,
	_reserved_13,
	_reserved_14,
	_reserved_15,
}

// header represents a WebSocket frame header.
// See https://tools.ietf.org/html/rfc6455#section-5.2.
header :: struct {
	fin:           bool,
	rsv1:          bool,
	rsv2:          bool,
	rsv3:          bool,
	opcode:        opcode,
	mask:          bool,
	payloadLength: u64,
	maskKey:       u32,
}

// writeFrameHeader serializes a header into a byte buffer.
// Returns the buffer containing the serialized header and the number of bytes written.
writeFrameHeader :: proc(h: header) -> ([14]byte, int) {
	buf: [14]byte

	b: byte
	if h.fin {
		b |= 1 << 7
	}
	if h.rsv1 {
		b |= 1 << 6
	}
	if h.rsv2 {
		b |= 1 << 5
	}
	if h.rsv3 {
		b |= 1 << 4
	}

	b |= byte(h.opcode)

	buf[0] = b

	lengthByte: byte
	if h.mask {
		lengthByte |= 1 << 7
	}

	size := 2 + ((h.payloadLength > 125) ? 2 : 0) + ((h.payloadLength > MaxUint16) ? 6 : 0)
	switch {
	case h.payloadLength > MaxUint16:
		lengthByte |= 127
		endian.put_u64(buf[2:], .Big, u64(h.payloadLength))
	case h.payloadLength > 125:
		lengthByte |= 126
		endian.put_u16(buf[2:], .Big, u16(h.payloadLength))
	case h.payloadLength >= 0:
		lengthByte |= byte(h.payloadLength)
	}

	buf[1] = lengthByte

	if h.mask {
		endian.put_u32(buf[size:], .Little, h.maskKey)
		size += 4
	}

	return buf, size
}

// readFrameHeader parses a frame header from the beginning of a byte slice.
// Returns the parsed header, the number of bytes consumed for the header, and an error if parsing failed.
readFrameHeader :: proc(b: []byte) -> (header, int, frame_error) {
	h := header{}

	// a valid header should have at least two bytes
	if len(b) < 2 {
		return h, 0, .tooShort
	}

	h.fin = b[0] & (1 << 7) != 0
	h.rsv1 = b[0] & (1 << 6) != 0
	h.rsv2 = b[0] & (1 << 5) != 0
	h.rsv3 = b[0] & (1 << 4) != 0

	h.opcode = opcode(b[0] & 0xf)

	h.mask = b[1] & (1 << 7) != 0
	h.payloadLength = u64(b[1] & 0x7F)

	// if there is no extended payloadLength then
	// the maskKey starts at the third byte
	maskKeyPos := 2

	if h.payloadLength == 126 {
		if len(b) < 4 {
			return h, 0, .tooShort
		}

		pl, ok := endian.get_u16(b[2:4], .Big)
		if ok {
			if pl <= 125 {
				return h, 0, .protocolError
			}
			maskKeyPos = 4
			h.payloadLength = u64(pl)
		}
	} else if h.payloadLength == 127 {
		if len(b) < 10 {
			return h, 0, .tooShort
		}

		pl, ok := endian.get_u64(b[2:10], .Big)
		if ok {
			if pl <= u64(MaxUint16) || (pl & (u64(1) << 63)) != 0 {
				return h, 0, .protocolError
			}
			maskKeyPos = 10
			h.payloadLength = pl
		}
	}

	size := maskKeyPos
	if h.mask {
		if len(b) < maskKeyPos + 4 {
			return h, 0, .tooShort
		}

		size += 4
		h.maskKey, _ = endian.get_u32(b[maskKeyPos:maskKeyPos + 4], .Little)
	}

	return h, size, nil
}

// frame_iterator attempts to read one full WebSocket frame from the beginning of the slice pointed to by s.
// If successful, it returns the frame header, a slice containing the *unmasked* payload data, and status = .Ok.
// It **updates** the slice `s^` to point to the data *after* the consumed frame.
// If the slice doesn't contain a full frame, it returns .Incomplete and leaves `s^` unchanged.
// If the header is malformed, it returns .Protocol_Error and leaves `s^` unchanged.
frame_iterator :: proc(s: ^[]byte) -> (h: header, data: []byte, status: frame_iterator_status) {
	// 1. Check if there's enough data for even a minimal header
	if len(s^) < 2 {
		status = .Incomplete
		return
	}

	// 2. Try to read the header
	_h, headerSize, headerErr := readFrameHeader(s^)
	if headerErr == .tooShort {
		status = .Incomplete
		return
	}
	if headerErr != nil {
		status = .Protocol_Error
		return
	}
	// Header read successfully, assign to return value
	h = _h

	// 3. Calculate the total size needed for this frame (header + payload)
	payloadLen := h.payloadLength

	// Validate payload length to prevent integer overflow
	if payloadLen > cast(u64)max(int) - cast(u64)headerSize {
		status = .Protocol_Error
		return
	}

	totalFrameSize := headerSize + cast(int)payloadLen

	// 4. Check if the buffer contains the *entire* frame (header + payload)
	if len(s^) < totalFrameSize {
		// Buffer has the header, but not the complete payload it describes.
		status = .Incomplete
		return
	}

	// 5. Extract the payload slice (potentially masked)
	payload_slice := s^[headerSize:totalFrameSize]

	// 6. Handle masking
	if h.mask {
		mask(payload_slice, h.maskKey)
	}

	data = payload_slice

	// 7. Advance the input slice pointer past the consumed frame
	s^ = s^[totalFrameSize:]

	// 8. Signal success
	status = .Ok
	return
}
