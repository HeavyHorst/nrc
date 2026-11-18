package protocol

import "core:encoding/endian"
import "core:encoding/json"
import "core:mem"
import "core:unicode/utf8"

CHRONICLE_ACCESS_READ :: u8(1)
CHRONICLE_ACCESS_SERVICE :: u8(2)
CHRONICLE_ACCESS_DELETE :: u8(4)
CHRONICLE_CONSUMER_VERSION :: "chronicle-v1"

Chronicle_Request :: struct {
	op:             string `json:"op"`,
	consumer:       string `json:"consumer"`,
	note_id:        string `json:"note_id"`,
	cursor:         string `json:"cursor"`,
	newest_first:   bool `json:"newest_first,omitempty"`,
	epoch:          string `json:"epoch"`,
	generation:     string `json:"generation"`,
	limit:          u16 `json:"limit"`,
	sources:        []string `json:"sources,omitempty"`,
	field:          u8 `json:"field"`,
	offset:         u32 `json:"offset"`,
	length:         u16 `json:"length"`,
	input_tokens:   u32 `json:"input_tokens"`,
	output_tokens:  u32 `json:"output_tokens"`,
	outcome:        string `json:"outcome"`,
	summary:        string `json:"summary"`,
	model:          string `json:"model"`,
	prompt_version: string `json:"prompt_version"`,
	schema_version: string `json:"schema_version"`,
	reason:         string `json:"reason"`,
}

// Empty means absent. Zero is canonical; individual operations may forbid it.
chronicle_decimal :: proc(s: string) -> (value: u64, ok: bool) {
	if len(s) == 0 || len(s) > 20 || (len(s) > 1 && s[0] == '0') do return
	for c in s {
		if c < '0' || c > '9' do return 0, false
		d := u64(c - '0')
		if value > (max(u64) - d) / 10 do return 0, false
		value = value * 10 + d
	}
	return value, true
}

validateChronicleRequest :: proc(r: Chronicle_Request) -> bool {
	switch r.op {
	case "list", "claim", "chunk", "reserve", "commit", "retry", "status", "history", "gaps", "delete":
	case:
		return false
	}
	for s in ([?]string{r.note_id, r.cursor, r.epoch, r.generation}) {
		if s != "" {_, ok := chronicle_decimal(s); if !ok do return false}
	}
	for s in ([?]string{r.consumer, r.model, r.prompt_version, r.schema_version, r.outcome, r.reason}) {
		if len(s) > 128 || !utf8.valid_string(s) do return false
	}
	if len(r.summary) > 4096 || !utf8.valid_string(r.summary) || len(r.sources) > 32 do return false
	previous: u64
	for s in r.sources {
		n, ok := chronicle_decimal(s)
		if !ok || n <= previous do return false
		previous = n
	}
	return true
}

// Input excludes the opcode. This is a zero-allocation framing check; the
// authenticated request parser below validates JSON and field semantics.
parseChronicleEnvelope :: proc(data: []byte) -> (payload: []byte, correlation: u32, err: ProtocolParseError) {
	if len(data) > MAX_PROTOCOL_PAYLOAD_SIZE - 2 do return nil, 0, .ContentLengthExceedsMax
	if len(data) < 6 do return nil, 0, .TooShort
	payload = data[:len(data) - 4]
	correlation, _ = endian.get_u32(data[len(data) - 4:], .Big)
	return
}

// All allocations belong to the caller's scoped arena, including parse failure
// allocations. Destroy that arena after consuming the result; no data escapes it.
parseChronicleRequest :: proc(
	data: []byte,
	allocator: mem.Allocator = context.allocator,
) -> (
	result: Chronicle_Request,
	correlation: u32,
	err: ProtocolParseError,
) {
	payload: []byte
	payload, correlation, err = parseChronicleEnvelope(data)
	if err != .None do return
	if !utf8.valid_string(string(payload)) do return result, correlation, .InvalidValue
	// Bound nesting and array allocations before invoking the JSON allocator.
	tok := json.make_tokenizer(string(payload), .JSON, true)
	depth, elements := 0, 0
	fields := 0
	started := false
	for {
		t, e := json.get_token(&tok)
		if t.kind == .EOF && e == .EOF do break
		if e != .None do return result, correlation, .InvalidValue
		if depth == 0 && (started || t.kind != .Open_Brace) do return result, correlation, .InvalidValue
		started = true
		if depth == 2 && t.kind != .String && t.kind != .Comma && t.kind != .Close_Bracket do return result, correlation, .InvalidValue
		#partial switch t.kind {
		case .Open_Brace:
			if depth != 0 do return result, correlation, .InvalidValue
			depth += 1
		case .Open_Bracket:
			if depth != 1 do return result, correlation, .InvalidValue
			depth += 1; elements = 0
		case .Close_Brace, .Close_Bracket:
			depth -= 1
		case .String:
			if depth == 2 {elements += 1; if elements > 32 do return result, correlation, .TooMany}
		case .Colon:
			fields += 1
			if fields > 20 do return result, correlation, .TooMany
		case:
		}
	}
	if !json.is_valid(payload, .JSON, true) do return result, correlation, .InvalidValue
	v, je := json.parse(payload, .JSON, true, allocator)
	if je != .None do return result, correlation, .InvalidValue
	obj, object := v.(json.Object)
	if !object do return result, correlation, .InvalidValue
	for key, value in obj {
		switch key {
		case "newest_first":
			b, ok := value.(json.Boolean)
			if !ok do return result, correlation, .InvalidValue
			result.newest_first = bool(b)
		case "op", "consumer", "note_id", "cursor", "epoch", "generation", "outcome", "summary", "model", "prompt_version", "schema_version", "reason":
			s, ok := value.(json.String)
			if !ok do return result, correlation, .InvalidValue
			switch key {
			case "op":
				result.op = s
			case "consumer":
				result.consumer = s
			case "note_id":
				result.note_id = s
			case "cursor":
				result.cursor = s
			case "epoch":
				result.epoch = s
			case "generation":
				result.generation = s
			case "outcome":
				result.outcome = s
			case "summary":
				result.summary = s
			case "model":
				result.model = s
			case "prompt_version":
				result.prompt_version = s
			case "schema_version":
				result.schema_version = s
			case "reason":
				result.reason = s
			}
		case "limit", "field", "offset", "length", "input_tokens", "output_tokens":
			n, ok := value.(json.Integer)
			if !ok || n < 0 || n > i64(max(u32)) do return result, correlation, .InvalidValue
			switch key {
			case "limit", "length":
				if n > i64(max(u16)) do return result, correlation, .InvalidValue
				if key == "limit" {result.limit = u16(n)} else {result.length = u16(n)}
			case "field":
				if n > i64(max(u8)) do return result, correlation, .InvalidValue
				result.field = u8(n)
			case "offset":
				result.offset = u32(n)
			case "input_tokens":
				result.input_tokens = u32(n)
			case "output_tokens":
				result.output_tokens = u32(n)
			}
		case "sources":
			a, ok := value.(json.Array)
			if !ok || len(a) > 32 do return result, correlation, .InvalidValue
			result.sources = make([]string, len(a), allocator)
			for item, i in a {
				s, is_string := item.(json.String)
				if !is_string do return result, correlation, .InvalidValue
				result.sources[i] = s
			}
		case:
			return result, correlation, .InvalidValue
		}
	}
	if !validateChronicleRequest(result) do return result, correlation, .InvalidValue
	return
}

// Returns zero on invalid input, insufficient output space or marshal failure.
serializeChronicleRequest :: proc(request: Chronicle_Request, correlation: u32, buf: []byte) -> int {
	if !validateChronicleRequest(request) do return 0
	data, err := json.marshal(request, allocator = context.allocator)
	defer delete(data, context.allocator)
	if err != nil || len(data) + 6 > MAX_PROTOCOL_PAYLOAD_SIZE || len(buf) < len(data) + 6 do return 0
	endian.put_u16(buf, .Big, u16(Opcode.C_Chronicle))
	copy(buf[2:], data)
	endian.put_u32(buf[2 + len(data):], .Big, correlation)
	return len(data) + 6
}
