package main

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:testing"
import pr "protocol"

@(test)
test_chronicle_subject_config :: proc(t: ^testing.T) {
	for config in ([]string{"", "{}", `{"ws":[]}`, `{"ws":["worker","human"]}`}) {
		value, ok := chronicle_parse_subjects(config)
		testing.expectf(t, ok, "valid config: %s", config)
		json.destroy_value(value)
	}
	for config in ([]string{"null", "[]", " ", `{"ws":null}`, `{"ws":"worker"}`, `{"ws":[1]}`, `{"ws":[null]}`, `{"ws":[""]}`, `{"ws":[" "]}`, `{"":[]}`, `{ws:[]}`, `{"ws":[],}`, `{} garbage`}) {
		value, ok := chronicle_parse_subjects(config)
		testing.expectf(t, !ok, "invalid config: %s", config)
		if ok do json.destroy_value(value)
	}
	value, ok := chronicle_parse_subjects(`{"ws":["worker"]}`)
	testing.expect(t, ok)
	defer json.destroy_value(value)
	testing.expect(t, chronicle_subject_allowed(value, "ws", "worker"))
	testing.expect(t, !chronicle_subject_allowed(value, "other", "worker"))
	testing.expect(t, !chronicle_subject_allowed(value, "ws", "Worker"))
	testing.expect(t, !chronicle_subject_allowed(value, "ws", ""))
}

@(test)
test_chronicle_jwt_upgrade_capabilities :: proc(t: ^testing.T) {
	sync.mutex_lock(&jwt_auth_test_mu)
	defer sync.mutex_unlock(&jwt_auth_test_mu)
	old_service := chronicle_service_subjects
	old_delete := chronicle_delete_subjects
	old_secret := jwt_auth_secret
	old_issuer := jwt_expected_issuer
	old_audience := jwt_expected_audience
	old_workspace := workspace_access_enabled
	defer {
		json.destroy_value(chronicle_service_subjects)
		json.destroy_value(chronicle_delete_subjects)
		chronicle_service_subjects = old_service
		chronicle_delete_subjects = old_delete
		jwt_auth_secret = old_secret
		jwt_expected_issuer = old_issuer
		jwt_expected_audience = old_audience
		workspace_access_enabled = old_workspace
	}
	service_ok, delete_ok: bool
	chronicle_service_subjects, service_ok = chronicle_parse_subjects(`{"ws":["worker"]}`)
	chronicle_delete_subjects, delete_ok = chronicle_parse_subjects(`{"ws":["human","worker"]}`)
	testing.expect(t, service_ok && delete_ok)
	jwt_auth_secret = "chronicle-unit-signing-key"
	jwt_expected_issuer = ""
	jwt_expected_audience = ""
	workspace_access_enabled = false
	for tc in ([]struct {
			payload: string,
			allowed: bool,
			access:  u8,
		}{{`{"sub":"worker","user_type":"bot","capability":"chronicle","workspace":"ws","exp":4102444800}`, true, pr.CHRONICLE_ACCESS_READ | pr.CHRONICLE_ACCESS_SERVICE}, {`{"sub":"worker","user_type":"bot","capability":"chronicle","exp":4102444800}`, false, 0}, {`{"sub":"worker","user_type":"bot","capability":"chronicle","workspace":"other","exp":4102444800}`, false, 0}, {`{"sub":"stranger","user_type":"bot","capability":"chronicle","workspace":"ws","exp":4102444800}`, false, 0}, {`{"sub":"worker","user_type":"admin","capability":"chronicle","workspace":"ws","exp":4102444800}`, false, 0}, {`{"sub":"worker","capability":"chronicle","workspace":"ws","exp":4102444800}`, false, 0}, {`{"sub":"worker","user_type":"bot","workspace":"ws","exp":4102444800}`, true, pr.CHRONICLE_ACCESS_READ}, {`{"sub":"human","workspace":"ws","exp":4102444800}`, true, pr.CHRONICLE_ACCESS_READ | pr.CHRONICLE_ACCESS_DELETE}, {`{"sub":"human","user_type":"bot","workspace":"ws","exp":4102444800}`, true, pr.CHRONICLE_ACCESS_READ}, {`{"sub":"human","user_type":"system","workspace":"ws","exp":4102444800}`, true, pr.CHRONICLE_ACCESS_READ}, {`{"sub":"stranger","workspace":"ws","exp":4102444800}`, true, pr.CHRONICLE_ACCESS_READ}, {`{"sub":"worker","user_type":"bot","capability":"chronicle","workspace":"ws","exp":1}`, false, 0}}) {
		token, built := build_test_jwt(tc.payload, jwt_auth_secret)
		testing.expect(t, built)
		// Spoofed legacy admin headers must never expand service-JWT rights.
		request := fmt.aprintf(
			"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-Auth: %s\r\nX-NRC-User-Type: admin\r\nX-NRC-Bot-Secret: legacy-key\r\nX-NRC-Bot-Nickname: worker\r\n\r\n",
			token,
		)
		decision := parse_http_upgrade_decision(request, "legacy-key", 1)
		testing.expectf(t, (decision.kind == .Accept) == tc.allowed, "upgrade: %s", tc.payload)
		testing.expect_value(t, decision.chronicle_access, tc.access)
		if tc.access & pr.CHRONICLE_ACCESS_SERVICE != 0 do testing.expect_value(t, decision.user_type, pr.User_Type.Bot)
		delete(decision.verified_subject)
		if decision.verified_username_owned do delete(decision.verified_username)
		delete(request)
		delete(token)
	}
	for auth_header in ([]string{"", "X-NRC-Auth: \r\n", "X-NRC-Auth: malformed\r\n"}) {
		request := fmt.aprintf(
			"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n%sX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: legacy-key\r\nX-NRC-Bot-Nickname: worker\r\n\r\n",
			auth_header,
		)
		decision := parse_http_upgrade_decision(request, "legacy-key", 1)
		testing.expect_value(t, decision.chronicle_access, u8(0))
		testing.expect_value(t, decision.kind == .Accept, auth_header == "")
		delete(request)
	}
}

@(test)
test_chronicle_service_opcode_restrictions :: proc(t: ^testing.T) {
	for opcode in pr.Opcode {
		testing.expect_value(t, chronicle_service_opcode_allowed(pr.CHRONICLE_ACCESS_SERVICE, opcode), opcode == .C_Chronicle || opcode == .C_Ping)
		testing.expect(t, chronicle_service_opcode_allowed(pr.CHRONICLE_ACCESS_READ, opcode))
	}
}
