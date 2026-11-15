package main

import "core:encoding/json"
import "core:mem"
import "core:strings"
import pr "protocol"

CUSTOMER_READ_DEFAULT_LIMIT :: 50
CUSTOMER_READ_MAX_LIMIT :: 250

Customer_Preview :: struct {
	version:      int,
	title:        string,
	archived:     bool,
	number:       string,
	sector:       string,
	account_type: string,
	city:         string,
	address:      string,
	website:      string,
	assignee:     string,
	role:         string,
	email:        string,
	phone:        string,
}

// Historical customer search uses the permissive struct decoder. Do not
// conflate it with the newsletter's stricter active-contact contract below.
customer_preview :: proc(asset: ^pr.Asset, allocator := context.allocator) -> (m: Customer_Preview, ok: bool) {
	if asset == nil || json.unmarshal(asset.preview, &m, allocator = allocator) != nil do return
	ok = m.version == 1 && len(m.title) > 0
	return
}

customer_preview_is_active_contact :: proc(preview: []byte, allocator: mem.Allocator) -> bool {
	fields, object, valid := json_metadata_fields(preview, [?]string{"version", "title", "email", "archived"}, allocator)
	// Unlike struct decoding, numeric strings and floats are not versions.
	if !valid || !object || fields[0].kind != .Integer || fields[0].text != "1" || fields[1].kind != .String do return false
	if len(strings.trim_space(json_metadata_string(fields[1], allocator))) == 0 do return false
	if fields[2].kind != .Invalid && fields[2].kind != .Null && fields[2].kind != .String do return false
	return fields[3].kind == .Invalid || fields[3].kind == .Null || fields[3].kind == .False
}
