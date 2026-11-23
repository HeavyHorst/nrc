package main

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:testing"

@(test)
test_portal_account_admin_key_rejects_reuse :: proc(t: ^testing.T) {
	key :: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	upper_key :: "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
	_, independent := portal_account_parse_admin_key(key, "bot", "jwt", "service")
	testing.expect(t, independent)
	_, matches_bot := portal_account_parse_admin_key(key, upper_key, "jwt", "service")
	testing.expect(t, !matches_bot)
	_, matches_jwt := portal_account_parse_admin_key(key, "bot", key, "service")
	testing.expect(t, !matches_jwt)
	_, matches_service := portal_account_parse_admin_key(key, "bot", "jwt", upper_key)
	testing.expect(t, !matches_service)
	_, malformed := portal_account_parse_admin_key("invalid", "bot", "jwt", "service")
	testing.expect(t, !malformed)
}

@(test)
test_portal_account_admin_requires_verified_proof :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)
	old_jwt, old_iss, old_aud := jwt_auth_secret, jwt_expected_issuer, jwt_expected_audience
	old_key, old_subjects := portal_account_admin_key, portal_account_admin_subjects
	defer {
		jwt_auth_secret, jwt_expected_issuer, jwt_expected_audience = old_jwt, old_iss, old_aud
		portal_account_admin_key, portal_account_admin_subjects = old_key, old_subjects
	}
	jwt_auth_secret, jwt_expected_issuer, jwt_expected_audience = "shared-test-jwt", "", ""
	key, key_ok := portal_account_parse_admin_key("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "", jwt_auth_secret, "")
	if !testing.expect(t, key_ok) do return
	portal_account_admin_key = key
	policy, policy_ok := chronicle_parse_subjects(`{"alpha":["alice@example.com","tag:ci"]}`)
	if !testing.expect(t, policy_ok) do return
	defer json.destroy_value(policy)
	portal_account_admin_subjects = policy

	build_proof_header :: proc(token: string, key: []byte) -> string {
		digest: [32]byte
		hmac.sum(hash.Algorithm.SHA256, digest[:], transmute([]byte)token, key)
		proof := hex.encode(digest[:])
		defer delete(proof)
		return fmt.aprintf("x-nrc-portal-admin-proof: %s\r\n", string(proof))
	}
	check :: proc(t: ^testing.T, token, proof_headers: string, want_admin: bool, message: string) {
		request := fmt.aprintf(
			"GET /alpha HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dummy\r\nSec-WebSocket-Version: 13\r\nX-NRC-Auth: %s\r\n%s\r\n",
			token,
			proof_headers,
		)
		defer delete(request)
		decision := parse_http_upgrade_decision(request, "legacy-key", 1)
		defer delete(decision.verified_subject)
		if decision.verified_username_owned do delete(decision.verified_username)
		testing.expect_value(t, decision.kind, HTTP_Upgrade_Decision_Kind.Accept)
		testing.expect(t, decision.portal_account_admin == want_admin, message)
	}

	token, jwt_ok := build_test_jwt(`{"sub":"alice@example.com","username":"alice","workspace":"alpha","exp":4102444800,"user_type":"admin"}`, jwt_auth_secret)
	if !testing.expect(t, jwt_ok) do return
	defer delete(token)
	proof := build_proof_header(token, key[:])
	defer delete(proof)
	check(t, token, "", false, "shared JWT signer alone cannot grant admin")
	check(t, token, proof, true, "valid proof and exact allowlisted subject grant admin")
	forged := build_proof_header(token, transmute([]byte)jwt_auth_secret)
	defer delete(forged)
	check(t, token, forged, false, "shared JWT key does not sign admin proofs")
	duplicate := fmt.aprintf("%s%s", proof, proof)
	defer delete(duplicate)
	check(t, token, duplicate, false, "duplicate proof headers do not grant admin")
	portal_account_admin_key = nil
	check(t, token, proof, false, "unconfigured admin key never grants admin")
	portal_account_admin_key = key

	other_payloads := [?]string {
		`{"sub":"alice@example.com","username":"altered","workspace":"alpha","exp":4102444800,"user_type":"admin"}`,
		`{"sub":"alice@example.com","workspace":"alpha","exp":4102444800,"user_type":"bot"}`,
		`{"sub":"tag:ci","workspace":"alpha","exp":4102444800}`,
		`{"sub":"bob@example.com","workspace":"alpha","exp":4102444800}`,
		`{"sub":"alice@example.com","exp":4102444800}`,
	}
	for payload, i in other_payloads {
		other, ok := build_test_jwt(payload, jwt_auth_secret)
		if !testing.expect(t, ok) do return
		defer delete(other)
		if i == 0 {
			check(t, other, proof, false, "proof is bound to the exact raw token")
		} else {
			other_proof := build_proof_header(other, key[:])
			defer delete(other_proof)
			check(t, other, other_proof, false, "proof does not bypass human, workspace, or allowlist checks")
		}
	}
}
