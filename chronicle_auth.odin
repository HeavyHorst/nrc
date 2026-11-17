package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import pr "protocol"

// Published once by main before any workers start. Never mutated at runtime.
chronicle_service_subjects: json.Value
chronicle_delete_subjects: json.Value

// Odin's JSON parser accepts trailing commas/data and drops empty object keys.
// Check these explicitly before decoding the operator's fail-closed policy.
chronicle_config_tokens_valid :: proc(input: string) -> bool {
	if strings.index_byte(input, 0) >= 0 do return false
	tokenizer := json.make_tokenizer(input, .JSON)
	previous := json.Token_Kind.EOF
	depth := 0
	finished := false
	for {
		token, err := json.get_token(&tokenizer)
		if err == .EOF do return finished
		if err != nil || finished do return false
		if token.kind == .String && token.text == `""` do return false
		if token.kind == .Close_Brace || token.kind == .Close_Bracket {
			if previous == .Comma do return false
			depth -= 1
			if depth == 0 do finished = true
		} else if token.kind == .Open_Brace || token.kind == .Open_Bracket {
			depth += 1
		}
		previous = token.kind
	}
}

chronicle_parse_subjects :: proc(config: string) -> (value: json.Value, ok: bool) {
	input := config == "" ? "{}" : config
	if !chronicle_config_tokens_valid(input) do return {}, false
	if json.unmarshal(transmute([]byte)input, &value, spec = .JSON) != nil {
		json.destroy_value(value)
		return {}, false
	}
	object, is_object := value.(json.Object)
	valid := is_object
	if is_object {
		for workspace, subjects in object {
			if strings.trim_space(workspace) == "" {valid = false; break}
			array, is_array := subjects.(json.Array)
			if !is_array {valid = false; break}
			for subject in array {
				name, is_string := subject.(json.String)
				if !is_string || strings.trim_space(string(name)) == "" {valid = false; break}
			}
			if !valid do break
		}
	}
	if !valid {json.destroy_value(value); return {}, false}
	return value, true
}

chronicle_auth_init :: proc() -> bool {
	service_config := os.get_env_alloc("NRC_CHRONICLE_SERVICE_SUBJECTS", context.allocator)
	defer delete(service_config)
	delete_config := os.get_env_alloc("NRC_CHRONICLE_DELETE_SUBJECTS", context.allocator)
	defer delete(delete_config)
	service, service_ok := chronicle_parse_subjects(service_config)
	if !service_ok do return false
	deletion, delete_ok := chronicle_parse_subjects(delete_config)
	if !delete_ok {json.destroy_value(service); return false}
	chronicle_service_subjects = service
	chronicle_delete_subjects = deletion
	return true
}

chronicle_auth_destroy :: proc() {
	json.destroy_value(chronicle_service_subjects)
	json.destroy_value(chronicle_delete_subjects)
	chronicle_service_subjects = {}
	chronicle_delete_subjects = {}
}

chronicle_subject_allowed :: proc(value: json.Value, workspace, subject: string) -> bool {
	if workspace == "" || subject == "" do return false
	object, ok := value.(json.Object)
	if !ok do return false
	subjects, exists := object[workspace]
	if !exists do return false
	array, is_array := subjects.(json.Array)
	if !is_array do return false
	for entry in array {
		name, is_string := entry.(json.String)
		if is_string && string(name) == subject do return true
	}
	return false
}

// Called only after signature, expiry, issuer and audience validation.
chronicle_claim_access :: proc(claims: JWT_Claims, workspace: string) -> (u8, bool) {
	if claims.capability != "" {
		if claims.capability != "chronicle" ||
		   claims.user_type != "bot" ||
		   claims.workspace == "" ||
		   claims.workspace != workspace ||
		   !chronicle_subject_allowed(chronicle_service_subjects, workspace, claims.sub) {
			return 0, false
		}
		return pr.CHRONICLE_ACCESS_READ | pr.CHRONICLE_ACCESS_SERVICE, true
	}
	access := pr.CHRONICLE_ACCESS_READ
	// Unknown/system/bot classifications are not verified humans.
	if (claims.user_type == "" || strings.equal_fold(claims.user_type, "user") || strings.equal_fold(claims.user_type, "admin")) &&
	   chronicle_subject_allowed(chronicle_delete_subjects, workspace, claims.sub) {
		access |= pr.CHRONICLE_ACCESS_DELETE
	}
	return access, true
}

chronicle_service_opcode_allowed :: proc(access: u8, opcode: pr.Opcode) -> bool {
	return access & pr.CHRONICLE_ACCESS_SERVICE == 0 || opcode == .C_Chronicle || opcode == .C_Ping
}
