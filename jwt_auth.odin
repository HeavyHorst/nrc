package main

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"

import pr "protocol"

JWT_Header :: struct {
	alg: string `json:"alg"`,
	typ: string `json:"typ"`,
}

JWT_Claims :: struct {
	sub:       string `json:"sub"`,
	username:  string `json:"username"`,
	workspace: string `json:"workspace"`,
	iss:       string `json:"iss"`,
	aud:       string `json:"aud"`,
	exp:       i64 `json:"exp"`,
	nbf:       i64 `json:"nbf"`,
	user_type: string `json:"user_type"`,
}

JWT_Identity :: struct {
	username:  string,
	user_type: pr.User_Type,
}

@(thread_local)
jwt_validation_scratch: virtual.Arena

@(thread_local)
jwt_validation_scratch_initialized: bool

jwt_validation_scratch_acquire :: proc() -> (^virtual.Arena, bool) {
	if !jwt_validation_scratch_initialized {
		if virtual.arena_init_growing(&jwt_validation_scratch) != nil {
			return nil, false
		}
		jwt_validation_scratch_initialized = true
	}
	return &jwt_validation_scratch, true
}

jwt_validation_scratch_destroy :: proc() {
	if !jwt_validation_scratch_initialized do return
	virtual.arena_destroy(&jwt_validation_scratch)
	jwt_validation_scratch = {}
	jwt_validation_scratch_initialized = false
}

// The proxy validates the policy. The server only needs to distinguish the
// absent/empty-object policy from configurations that require scoped JWTs.
workspace_access_config_enabled :: proc(config: string) -> bool {
	if config == "" do return false
	value := strings.trim_space(config)
	if len(value) < 2 || value[0] != '{' || value[len(value) - 1] != '}' do return true
	return strings.trim_space(value[1:len(value) - 1]) != ""
}

validate_nrc_jwt :: proc(token: string, workspace: string = "", require_workspace: bool = false) -> (identity: JWT_Identity, ok: bool, reason: string) {
	if token == "" {
		return {}, false, "missing token"
	}

	first_dot := strings.index_byte(token, '.')
	if first_dot <= 0 {
		return {}, false, "malformed token"
	}

	second_rel := strings.index_byte(token[first_dot + 1:], '.')
	if second_rel <= 0 {
		return {}, false, "malformed token"
	}

	second_dot := first_dot + 1 + second_rel
	if strings.index_byte(token[second_dot + 1:], '.') >= 0 {
		return {}, false, "malformed token"
	}

	header_segment := token[:first_dot]
	payload_segment := token[first_dot + 1:second_dot]
	signature_segment := strings.trim_space(token[second_dot + 1:])

	parent_allocator := context.allocator
	arena, arena_ok := jwt_validation_scratch_acquire()
	if !arena_ok {
		return {}, false, "jwt validation allocator init failed"
	}
	defer virtual.arena_free_all(arena)
	context.allocator = virtual.arena_allocator(arena)
	defer context.allocator = parent_allocator

	header_bytes, header_ok := decode_base64url_segment(header_segment)
	if !header_ok {
		return {}, false, "invalid token header encoding"
	}

	jwt_header: JWT_Header
	if json.unmarshal(header_bytes, &jwt_header) != nil {
		return {}, false, "invalid token header"
	}

	if !strings.equal_fold(jwt_header.alg, "HS256") {
		return {}, false, "unsupported jwt algorithm"
	}

	signing_input := token[:second_dot]
	derived_tag: [hash.MAX_DIGEST_SIZE]byte
	hmac.sum(hash.Algorithm.SHA256, derived_tag[:hash.DIGEST_SIZES[hash.Algorithm.SHA256]], transmute([]u8)signing_input, transmute([]u8)jwt_auth_secret)
	expected_signature_segment, enc_err := base64.encode(derived_tag[:hash.DIGEST_SIZES[hash.Algorithm.SHA256]], base64.ENC_URL_TABLE)
	if enc_err != nil {
		return {}, false, "failed to encode expected token signature"
	}
	expected_signature_segment = strings.trim_right(expected_signature_segment, "=")

	if crypto.compare_constant_time(transmute([]u8)expected_signature_segment, transmute([]u8)signature_segment) != 1 {
		return {}, false, "signature verification failed"
	}

	payload_bytes, payload_ok := decode_base64url_segment(payload_segment)
	if !payload_ok {
		return {}, false, "invalid token payload encoding"
	}

	claims: JWT_Claims
	if json.unmarshal(payload_bytes, &claims) != nil {
		return {}, false, "invalid token payload"
	}

	if claims.sub == "" {
		return {}, false, "missing sub claim"
	}

	if (require_workspace && claims.workspace == "") || (claims.workspace != "" && claims.workspace != workspace) {
		return {}, false, "workspace authorization mismatch"
	}

	now_unix := i64(nrc_time_unix_seconds())
	if claims.exp <= 0 || now_unix >= claims.exp {
		return {}, false, "token expired"
	}

	if claims.nbf > 0 && now_unix < claims.nbf {
		return {}, false, "token not yet valid"
	}

	if jwt_expected_issuer != "" && claims.iss != jwt_expected_issuer {
		return {}, false, "invalid issuer"
	}

	if jwt_expected_audience != "" && claims.aud != jwt_expected_audience {
		return {}, false, "invalid audience"
	}

	username := claims.username
	if username == "" {
		username = claims.sub
	}

	if username == "" {
		return {}, false, "missing username"
	}

	context.allocator = parent_allocator
	username = strings.clone(username)

	user_type := pr.User_Type.User
	if strings.equal_fold(claims.user_type, "admin") {
		user_type = .Admin
	} else if strings.equal_fold(claims.user_type, "bot") {
		user_type = .Bot
	} else if strings.equal_fold(claims.user_type, "system") {
		user_type = .System
	}

	return JWT_Identity{username = username, user_type = user_type}, true, ""
}

decode_base64url_segment :: proc(segment: string) -> (decoded: []u8, ok: bool) {
	if segment == "" {
		return nil, false
	}

	for i := 0; i < len(segment); i += 1 {
		switch segment[i] {
		case '-', '_', '=', 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9':
		// valid base64url character
		case:
			return nil, false
		}
	}

	out, err := base64.decode(segment, base64.DEC_URL_TABLE)
	if err != nil {
		return nil, false
	}

	return out, true
}
