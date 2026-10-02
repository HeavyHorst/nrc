package main

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

import pr "protocol"

jwt_auth_test_mu: sync.Mutex

build_test_jwt :: proc(payload_json: string, secret: string) -> (token: string, ok: bool) {
	header_json := `{"alg":"HS256","typ":"JWT"}`

	header_segment, header_err := base64.encode(transmute([]u8)header_json, base64.ENC_URL_TABLE)
	if header_err != nil {
		return "", false
	}
	defer delete(header_segment)
	header_segment = strings.trim_right(header_segment, "=")

	payload_segment, payload_err := base64.encode(transmute([]u8)payload_json, base64.ENC_URL_TABLE)
	if payload_err != nil {
		return "", false
	}
	defer delete(payload_segment)
	payload_segment = strings.trim_right(payload_segment, "=")

	signing_input := fmt.aprintf("%s.%s", header_segment, payload_segment)
	defer delete(signing_input)

	derived_tag: [hash.MAX_DIGEST_SIZE]byte
	hmac.sum(hash.Algorithm.SHA256, derived_tag[:hash.DIGEST_SIZES[hash.Algorithm.SHA256]], transmute([]u8)signing_input, transmute([]u8)secret)
	signature_segment, signature_err := base64.encode(derived_tag[:hash.DIGEST_SIZES[hash.Algorithm.SHA256]], base64.ENC_URL_TABLE)
	if signature_err != nil {
		return "", false
	}
	defer delete(signature_segment)
	signature_segment = strings.trim_right(signature_segment, "=")

	token = fmt.aprintf("%s.%s", signing_input, signature_segment)
	ok = true
	return
}

@(test)
test_validate_nrc_jwt_accepts_valid_proxy_token :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)

	old_secret := jwt_auth_secret
	old_issuer := jwt_expected_issuer
	old_audience := jwt_expected_audience
	defer {
		jwt_auth_secret = old_secret
		jwt_expected_issuer = old_issuer
		jwt_expected_audience = old_audience
	}

	jwt_auth_secret = "jwt-unit-test-secret"
	jwt_expected_issuer = "nrc-proxy"
	jwt_expected_audience = "nrc"

	token, token_ok := build_test_jwt(
		`{"sub":"user-123","username":"alice","iss":"nrc-proxy","aud":"nrc","exp":4102444800,"nbf":1,"user_type":"admin"}`,
		jwt_auth_secret,
	)
	testing.expect(t, token_ok, "token build should succeed")
	defer delete(token)

	identity, ok, reason := validate_nrc_jwt(token)
	if len(identity.username) > 0 {
		defer delete(identity.username)
	}
	testing.expect(t, ok, "valid token should pass validation")
	testing.expect(t, reason == "", "valid token should not return failure reason")
	testing.expect(t, identity.username == "alice", "username should come from claims.username")
	testing.expect_value(t, identity.user_type, pr.User_Type.Admin)
}

@(test)
test_validate_nrc_jwt_reuses_scratch_without_borrowing_identity :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)

	jwt_validation_scratch_destroy()
	defer jwt_validation_scratch_destroy()

	old_secret := jwt_auth_secret
	old_issuer := jwt_expected_issuer
	old_audience := jwt_expected_audience
	defer {
		jwt_auth_secret = old_secret
		jwt_expected_issuer = old_issuer
		jwt_expected_audience = old_audience
	}

	jwt_auth_secret = "jwt-unit-test-secret"
	jwt_expected_issuer = ""
	jwt_expected_audience = ""

	alice_token, alice_token_ok := build_test_jwt(`{"sub":"alice-id","username":"alice","exp":4102444800}`, jwt_auth_secret)
	testing.expect(t, alice_token_ok, "first token build should succeed")
	defer delete(alice_token)

	alice, alice_ok, alice_reason := validate_nrc_jwt(alice_token)
	testing.expect(t, alice_ok, "first token should validate")
	testing.expect(t, alice_reason == "", "first token should not return failure reason")
	defer delete(alice.username)
	testing.expect(t, jwt_validation_scratch_initialized, "first validation should initialize reusable scratch")
	first_block := jwt_validation_scratch.curr_block
	testing.expect(t, first_block != nil, "reusable scratch should retain its first block")

	bob_token, bob_token_ok := build_test_jwt(`{"sub":"bob-id","username":"bob","exp":4102444800}`, jwt_auth_secret)
	testing.expect(t, bob_token_ok, "second token build should succeed")
	defer delete(bob_token)

	bob, bob_ok, bob_reason := validate_nrc_jwt(bob_token)
	testing.expect(t, bob_ok, "second token should validate")
	testing.expect(t, bob_reason == "", "second token should not return failure reason")
	defer delete(bob.username)
	testing.expect(t, jwt_validation_scratch.curr_block == first_block, "validations should reuse the first arena block")
	testing.expect(t, alice.username == "alice", "returned identity must survive reuse of validation scratch")
	testing.expect(t, bob.username == "bob", "second identity should come from second token")
}

@(test)
test_validate_nrc_jwt_rejects_invalid_signature :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)

	old_secret := jwt_auth_secret
	old_issuer := jwt_expected_issuer
	old_audience := jwt_expected_audience
	defer {
		jwt_auth_secret = old_secret
		jwt_expected_issuer = old_issuer
		jwt_expected_audience = old_audience
	}

	jwt_auth_secret = "jwt-unit-test-secret"
	jwt_expected_issuer = ""
	jwt_expected_audience = ""

	token, token_ok := build_test_jwt(`{"sub":"user-456","username":"bob","exp":4102444800}`, jwt_auth_secret)
	testing.expect(t, token_ok, "token build should succeed")
	defer delete(token)

	tampered_token := fmt.aprintf("%sx", token)
	defer delete(tampered_token)

	_, ok, reason := validate_nrc_jwt(tampered_token)
	testing.expect(t, !ok, "tampered token must fail validation")
	testing.expect(t, reason == "signature verification failed", "tampered token should fail signature verification")
}

@(test)
test_validate_nrc_jwt_rejects_expired_token :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)

	old_secret := jwt_auth_secret
	old_issuer := jwt_expected_issuer
	old_audience := jwt_expected_audience
	defer {
		jwt_auth_secret = old_secret
		jwt_expected_issuer = old_issuer
		jwt_expected_audience = old_audience
	}

	jwt_auth_secret = "jwt-unit-test-secret"
	jwt_expected_issuer = ""
	jwt_expected_audience = ""

	token, token_ok := build_test_jwt(`{"sub":"user-789","username":"carol","exp":1}`, jwt_auth_secret)
	testing.expect(t, token_ok, "token build should succeed")
	defer delete(token)

	_, ok, reason := validate_nrc_jwt(token)
	testing.expect(t, !ok, "expired token must fail validation")
	testing.expect(t, reason == "token expired", "expired token should return token expired reason")
}

@(test)
test_validate_nrc_jwt_rejects_wrong_issuer_and_audience :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)

	old_secret := jwt_auth_secret
	old_issuer := jwt_expected_issuer
	old_audience := jwt_expected_audience
	defer {
		jwt_auth_secret = old_secret
		jwt_expected_issuer = old_issuer
		jwt_expected_audience = old_audience
	}

	jwt_auth_secret = "jwt-unit-test-secret"
	jwt_expected_issuer = "expected-issuer"
	jwt_expected_audience = "expected-audience"

	wrong_issuer_token, issuer_ok := build_test_jwt(
		`{"sub":"iss-user","username":"issuer-user","iss":"wrong-issuer","aud":"expected-audience","exp":4102444800}`,
		jwt_auth_secret,
	)
	testing.expect(t, issuer_ok, "issuer test token build should succeed")
	defer delete(wrong_issuer_token)

	_, ok_issuer, reason_issuer := validate_nrc_jwt(wrong_issuer_token)
	testing.expect(t, !ok_issuer, "token with wrong issuer must fail validation")
	testing.expect(t, reason_issuer == "invalid issuer", "wrong issuer should return invalid issuer reason")

	wrong_audience_token, audience_ok := build_test_jwt(
		`{"sub":"aud-user","username":"audience-user","iss":"expected-issuer","aud":"wrong-audience","exp":4102444800}`,
		jwt_auth_secret,
	)
	testing.expect(t, audience_ok, "audience test token build should succeed")
	defer delete(wrong_audience_token)

	_, ok_audience, reason_audience := validate_nrc_jwt(wrong_audience_token)
	testing.expect(t, !ok_audience, "token with wrong audience must fail validation")
	testing.expect(t, reason_audience == "invalid audience", "wrong audience should return invalid audience reason")
}

@(test)
test_validate_nrc_jwt_rejects_not_yet_valid_and_missing_sub :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)

	old_secret := jwt_auth_secret
	old_issuer := jwt_expected_issuer
	old_audience := jwt_expected_audience
	defer {
		jwt_auth_secret = old_secret
		jwt_expected_issuer = old_issuer
		jwt_expected_audience = old_audience
	}

	jwt_auth_secret = "jwt-unit-test-secret"
	jwt_expected_issuer = ""
	jwt_expected_audience = ""

	future_token, future_ok := build_test_jwt(`{"sub":"future-user","username":"future-user","exp":4102448400,"nbf":4102444800}`, jwt_auth_secret)
	testing.expect(t, future_ok, "future nbf token build should succeed")
	defer delete(future_token)

	_, future_valid, future_reason := validate_nrc_jwt(future_token)
	testing.expect(t, !future_valid, "token with future nbf must fail validation")
	testing.expect(t, future_reason == "token not yet valid", "future nbf token should return token not yet valid reason")

	missing_sub_token, missing_sub_ok := build_test_jwt(`{"sub":"","username":"no-sub","exp":4102444800}`, jwt_auth_secret)
	testing.expect(t, missing_sub_ok, "missing sub token build should succeed")
	defer delete(missing_sub_token)

	_, missing_sub_valid, missing_sub_reason := validate_nrc_jwt(missing_sub_token)
	testing.expect(t, !missing_sub_valid, "token with empty sub must fail validation")
	testing.expect(t, missing_sub_reason == "missing sub claim", "missing sub token should return missing sub claim reason")
}

@(test)
test_decode_base64url_segment_rejects_invalid_character :: proc(t: ^testing.T) {
	decoded, ok := decode_base64url_segment("abc$")
	if decoded != nil {
		delete(decoded)
	}
	testing.expect(t, !ok, "segment with invalid characters must fail decoding")
}

@(test)
test_workspace_scoped_jwt_upgrade :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)
	old_secret := jwt_auth_secret
	old_issuer := jwt_expected_issuer
	old_audience := jwt_expected_audience
	old_enabled := workspace_access_enabled
	defer {
		jwt_auth_secret = old_secret
		jwt_expected_issuer = old_issuer
		jwt_expected_audience = old_audience
		workspace_access_enabled = old_enabled
	}
	jwt_auth_secret = "workspace-test-signing-key"
	jwt_expected_issuer = ""
	jwt_expected_audience = ""
	workspace_access_enabled = true
	token, token_ok := build_test_jwt(`{"sub":"alice@example.com","username":"alice","workspace":"alice-private","exp":4102444800}`, jwt_auth_secret)
	testing.expect(t, token_ok)
	defer delete(token)
	legacy_token, legacy_ok := build_test_jwt(`{"sub":"alice@example.com","username":"alice","exp":4102444800}`, jwt_auth_secret)
	testing.expect(t, legacy_ok)
	defer delete(legacy_token)
	cases := []struct {
		workspace, token: string,
		enabled, allowed: bool,
	} {
		{"alice-private", token, true, true},
		{"bob-private", token, true, false},
		{"workspace1", token, true, false},
		{"alice-private", legacy_token, true, false},
		{"workspace1", legacy_token, false, true},
		{"bob-private", token, false, false},
	}
	for test_case in cases {
		workspace_access_enabled = test_case.enabled
		request := fmt.aprintf(
			"GET /%s HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-Auth: %s\r\n\r\n",
			test_case.workspace,
			test_case.token,
		)
		decision := parse_http_upgrade_decision(request, "internal-service-secret", 1)
		delete(request)
		testing.expect_value(t, decision.kind == .Accept, test_case.allowed)
		if decision.verified_username_owned do delete(decision.verified_username)
	}
	// Search and Sullivan's internal authenticated service connections remain
	// supported even when end-user tokens must carry a workspace authorization.
	workspace_access_enabled = true
	service_request := "GET /alice-private HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: internal-service-secret\r\nX-NRC-Bot-Nickname: sullivan-ai\r\n\r\n"
	service_decision := parse_http_upgrade_decision(service_request, "internal-service-secret", 1)
	testing.expect_value(t, service_decision.kind, HTTP_Upgrade_Decision_Kind.Accept)
}

@(test)
test_workspace_access_empty_policy :: proc(t: ^testing.T) {
	empty := []string{"", "{}", " \n{\t }\r "}
	for config in empty {
		testing.expect(t, !workspace_access_config_enabled(config), "empty policy keeps legacy authentication")
	}
	non_empty := []string{"null", "[]", " ", "{}{}", `{"private":{"owner":"alice@example.com"}}`}
	for config in non_empty {
		testing.expect(t, workspace_access_config_enabled(config), "non-empty or malformed policy must not disable scoped authentication")
	}
}
