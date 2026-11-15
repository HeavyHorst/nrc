package main

import "core:encoding/json"
import "core:mem"
import "core:strings"

// Invalid documents or wrongly typed metadata publish no partial facets.
// Missing/null fields are empty; decoded values are trimmed and tags deduplicated.
json_note_metadata_fields :: proc(data: []byte, tags: ^[dynamic]string, allocator: mem.Allocator) -> string {
	fields, object, valid := json_metadata_fields(data, [?]string{"project", "tags"}, allocator)
	if !valid || !object do return ""
	if fields[0].kind != .Invalid && fields[0].kind != .Null && fields[0].kind != .String do return ""
	if fields[1].kind != .Invalid && fields[1].kind != .Null && fields[1].kind != .Open_Bracket do return ""
	start := len(tags^)
	if fields[1].kind == .Open_Bracket {
		tok := json.make_tokenizer(fields[1].text, .JSON, true)
		_, _ = json.get_token(&tok) // Opening bracket; the full grammar is already validated.
		for {
			token, _ := json.get_token(&tok)
			if token.kind == .Close_Bracket do break
			if token.kind == .Comma do continue
			if token.kind != .String {
				resize(tags, start)
				return ""
			}
			value := strings.trim_space(json_metadata_string(token, allocator))
			if value != "" && !note_metadata_has_tag(tags[:], value) {
				if _, err := append(tags, value); err != nil do panic("failed to append note metadata tag")
			}
		}
	}
	return strings.trim_space(json_metadata_string(fields[0], allocator))
}

note_metadata_has_tag :: proc(tags: []string, tag: string) -> bool {
	for existing in tags {
		if existing == tag {
			return true
		}
	}
	return false
}
