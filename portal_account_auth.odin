package main

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:os"
import "core:strings"

// Published before any workers start; the executor only reads these values.
portal_account_admin_subjects: json.Value
portal_account_service_key: string
portal_account_admin_key: Maybe([32]byte)

portal_account_key_valid :: proc(value: string) -> bool {
	if len(value) != 64 do return false
	for b in value {
		if !(b >= '0' && b <= '9') && !(b >= 'a' && b <= 'f') && !(b >= 'A' && b <= 'F') do return false
	}
	return true
}

portal_account_parse_admin_key :: proc(value, shared_bot_key, shared_jwt_key, service_key: string) -> (key: [32]byte, ok: bool) {
	if len(value) != 64 do return {}, false
	decoded, valid := hex.decode_into_buffer(transmute([]byte)value, key[:])
	if !valid do return {}, false
	shared_keys := [3]string{shared_bot_key, shared_jwt_key, service_key}
	for other in shared_keys {
		if strings.equal_fold(value, other) || transmute(string)decoded == other do return {}, false
	}
	return key, true
}

portal_account_auth_init :: proc(shared_bot_key, shared_jwt_key: string) -> bool {
	config := os.get_env_alloc("NRC_PORTAL_ACCOUNT_ADMIN_SUBJECTS", context.allocator)
	defer delete(config)
	service := os.get_env_alloc("NRC_PORTAL_ACCOUNT_SERVICE_KEY", context.allocator)
	if service != "" && (!portal_account_key_valid(service) || service == shared_bot_key) {
		delete(service)
		return false
	}
	admin_config := os.get_env_alloc("NRC_PORTAL_ACCOUNT_ADMIN_KEY", context.allocator)
	defer delete(admin_config)
	admin_key: Maybe([32]byte)
	if admin_config != "" {
		key, ok := portal_account_parse_admin_key(admin_config, shared_bot_key, shared_jwt_key, service)
		if !ok {
			delete(service)
			return false
		}
		admin_key = key
	}
	admins, ok := chronicle_parse_subjects(config)
	if !ok {
		delete(service)
		return false
	}
	portal_account_admin_subjects = admins
	portal_account_service_key = service
	portal_account_admin_key = admin_key
	return true
}

portal_account_auth_destroy :: proc() {
	json.destroy_value(portal_account_admin_subjects)
	delete(portal_account_service_key)
	portal_account_admin_subjects = {}
	portal_account_service_key = ""
	portal_account_admin_key = nil
}

// X-NRC-Portal-Admin-Proof is hex(HMAC-SHA256(hex_decode(key), raw JWT)).
portal_account_proof_valid :: proc(token, proof: string) -> bool {
	key, configured := portal_account_admin_key.?
	if !configured || len(proof) != 64 do return false
	provided, expected: [32]byte
	if _, ok := hex.decode_into_buffer(transmute([]byte)proof, provided[:]); !ok do return false
	hmac.sum(hash.Algorithm.SHA256, expected[:], transmute([]byte)token, key[:])
	return crypto.compare_constant_time(expected[:], provided[:]) == 1
}

portal_account_key_matches :: proc(configured, provided: string) -> bool {
	return len(configured) == 64 && len(provided) == 64 && crypto.compare_constant_time(transmute([]byte)configured, transmute([]byte)provided) == 1
}
