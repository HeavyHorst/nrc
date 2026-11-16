package main

import "core:encoding/json"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import mon "monitoring"
import pr "protocol"

Monitor_Config :: struct {
	version:                       int,
	name, evaluator:               string,
	enabled:                       bool,
	interval_ns, timeout_ns:       i64,
	failures, recoveries, missing: u32,
	webhooks:                      []string, // Immutable/versioned route references; no secrets or URLs.
}

parse_monitor_config :: proc(a: ^pr.Asset, allocator: mem.Allocator) -> (config: Monitor_Config, policy: mon.Policy, valid: bool) {
	if a.asset_type != .Monitor || a.parent_type != .None || a.parent_id != 0 || len(a.attachments) != 0 || a.payload_encoding != .Plain || a.payload_raw_len != u32(len(a.payload)) do return
	fields, object, ok := json_metadata_fields(
		a.preview,
		{"version", "name", "evaluator", "enabled", "interval_ns", "timeout_ns", "failures", "recoveries", "missing", "webhooks"},
		allocator,
		true,
	)
	if !object || !ok || (fields[3].kind != .True && fields[3].kind != .False) do return
	for index in ([6]int{0, 4, 5, 6, 7, 8}) {if fields[index].kind != .Integer do return config, policy, false}
	// JSON unmarshal casts integers to u32 without checking their range.
	for index in 6 ..< 9 {
		value, integer := json_metadata_integer(fields[index].text)
		if !integer || value < 1 || value > i64(max(u32)) do return
	}
	if json.unmarshal(a.preview, &config, allocator = allocator) != nil do return
	if len(config.webhooks) > 8 do return
	for route, i in config.webhooks {
		if !pr.valid_monitor_route(route) do return
		for previous in config.webhooks[:i] {if previous == route do return config, policy, false}
	}
	if config.version != 1 || len(strings.trim_space(config.name)) == 0 || len(config.name) > 256 || len(config.evaluator) == 0 || len(config.evaluator) > pr.MAX_OWNER_LENGTH do return
	policy, valid = mon.default_policy(config.interval_ns, config.timeout_ns)
	if !valid do return
	policy.failures, policy.recoveries, policy.missing = config.failures, config.recoveries, config.missing
	// Adapter-owned check definition. The sidecar will validate its typed fields.
	_, object, ok = json_metadata_fields(a.payload, {"kind", "source_id", "source_revision"}, allocator, bound_integers = false)
	if !object || !ok do return config, policy, false
	ref: Monitor_Source_Ref
	if json.unmarshal(a.payload, &ref, allocator = allocator) != nil do return config, policy, false
	if ref.kind == "victoriametrics" || ref.kind == "victorialogs" {
		for text in ([2]string{ref.source_id, ref.source_revision}) {
			for c in text {if c < '0' || c > '9' do return config, policy, false}
		}
		id, id_ok := strconv.parse_u64(ref.source_id)
		revision, rev_ok := strconv.parse_i64(ref.source_revision)
		if !id_ok || !rev_ok || id == 0 || revision <= 0 do return config, policy, false
	}
	return config, policy, true
}

Monitor_Source_Ref :: struct {
	kind, source_id, source_revision: string,
}
Monitor_Source_Config :: struct {
	version:                                     int,
	name, kind, base_url, secret_ref, retention: string,
	insecure_tls:                                bool,
}

parse_monitor_source :: proc(a: ^pr.Asset, allocator: mem.Allocator) -> (config: Monitor_Source_Config, valid: bool) {
	if a.asset_type != .MonitorSource || a.parent_type != .None || a.parent_id != 0 || len(a.attachments) != 0 || a.payload_encoding != .Plain || a.payload_raw_len != 0 || len(a.payload) != 0 do return
	fields, object, ok := json_metadata_fields(a.preview, {"version", "name", "kind", "base_url", "secret_ref", "retention", "insecure_tls"}, allocator, true)
	if !object || !ok || fields[0].kind != .Integer || json.unmarshal(a.preview, &config, allocator = allocator) != nil do return
	if config.version != 1 || len(strings.trim_space(config.name)) == 0 || len(config.name) > 256 || (config.kind != "victoriametrics" && config.kind != "victorialogs" && config.kind != "webhook") || len(config.base_url) > 2048 || len(config.retention) > 256 || len(config.secret_ref) > 64 do return
	if config.kind == "webhook" && config.retention != "" do return
	if !monitor_source_url_valid(config.base_url) do return
	for c in config.secret_ref {if !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '_' do return config, false}
	return config, true
}

// Route asset IDs identify immutable destinations, including while an old lane drains.
monitoring_is_webhook_route :: proc(a: ^pr.Asset) -> bool {
	if a.asset_type != .MonitorSource do return false
	config, valid := parse_monitor_source(a, context.allocator)
	return valid && config.kind == "webhook"
}

// Match protocol-go's source URL contract, including explicit numeric ports.
monitor_source_url_valid :: proc(url: string) -> bool {
	if !strings.has_prefix(url, "http://") && !strings.has_prefix(url, "https://") do return false
	for c, i in url {
		if c <= ' ' || c == 127 || c == '@' || c == '?' || c == '#' || c == '\\' do return false
		if c == '%' {
			if i + 2 >= len(url) do return false
			for digit in url[i + 1:i + 3] {
				if !(digit >= '0' && digit <= '9' || digit >= 'a' && digit <= 'f' || digit >= 'A' && digit <= 'F') do return false
			}
		}
	}
	authority := url[strings.index(url, "://") + 3:]
	if slash := strings.index_byte(authority, '/'); slash >= 0 {authority = authority[:slash]}
	if len(authority) == 0 do return false
	host, suffix := authority, ""
	if authority[0] == '[' {
		end := strings.index_byte(authority, ']')
		if end < 0 do return false
		host, suffix = authority[1:end], authority[end + 1:]
		// Odin's IPv4 parser also accepts abbreviated aton forms. An IPv6
		// dotted tail must instead have four complete, canonical octets.
		if strings.contains(host, ".") {
			tail := host[strings.last_index_byte(host, ':') + 1:]
			if strings.has_suffix(tail, ".") do return false
			count := 0
			for part in strings.split_iterator(&tail, ".") {
				if len(part) == 0 || len(part) > 3 || (len(part) > 1 && part[0] == '0') do return false
				for c in part {if c < '0' || c > '9' do return false}
				value, ok := strconv.parse_u64(part)
				if !ok || value > 255 do return false
				count += 1
			}
			if count != 4 do return false
		}
		if _, ok := net.parse_ip6_address(host); !ok do return false
	} else {
		if colon := strings.index_byte(authority, ':'); colon >= 0 {host, suffix = authority[:colon], authority[colon:]}
		if len(host) == 0 do return false
		for c in host {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_') do return false
		}
	}
	if len(suffix) > 0 {
		if suffix[0] != ':' || len(suffix) == 1 do return false
		for c in suffix[1:] {if c < '0' || c > '9' do return false}
		port, ok := strconv.parse_u64(suffix[1:])
		if !ok || port == 0 || port > 65535 do return false
	}
	return true
}

// Technical state is machine-owned. Human actions will use dedicated commands.
monitoring_asset_mutation_valid :: proc(a: ^pr.Asset, allocator: mem.Allocator) -> bool {
	if a.asset_type == .Incident do return false
	if a.asset_type == .MonitorSource {_, valid := parse_monitor_source(a, allocator); return valid}
	if a.asset_type != .Monitor do return true
	_, _, valid := parse_monitor_config(a, allocator)
	return valid
}

Incident_Record :: struct {
	version:                                       int,
	title:                                         string,
	monitor_id, instance_id, episode:              string,
	status:                                        string,
	opened_at, closed_at:                          string,
	acknowledged_by, acknowledged_at, assigned_to: string,
}
