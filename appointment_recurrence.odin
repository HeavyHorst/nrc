package main

import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:time"
import dt "core:time/datetime"
import tz "core:time/timezone"
import pr "protocol"

APPOINTMENT_DAY :: i64(86400 * 1000000000)
Appointment_Exception :: struct {
	at, start_at, end_at:                            i64,
	cancelled, has_start, has_end, has_participants: bool,
	participants:                                    []string,
}

appointment_people_valid :: proc(people: []string) -> bool {
	if len(people) > 64 do return false
	for p, i in people {
		if p == "" || strings.trim_space(p) != p || len(p) > pr.MAX_USERNAME_LENGTH do return false
		for q in people[:i] do if p == q do return false
		for c in p do if c < 32 || c == 127 do return false
	}
	return true
}

appointment_zone :: proc(name: string, allocator: mem.Allocator) -> (^dt.TZ_Region, bool) {
	if name == "" || len(name) > 128 || name == "local" || name[0] == '/' || strings.contains(name, "..") || strings.contains(name, "\\") do return nil, false
	for c in name do if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '/' || c == '_' || c == '-' || c == '+') do return nil, false
	return tz.region_load(name, allocator)
}

appointment_date :: proc(s: string) -> (d: dt.Date, ok: bool) {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' do return
	for c, i in s {if i == 4 || i == 7 do continue; if c < '0' || c > '9' do return}
	y, a := json_metadata_integer(s[:4]); m, b := json_metadata_integer(s[5:7]); day, c := json_metadata_integer(s[8:])
	if !a || !b || !c || dt.validate_year_month_day(y, m, day) != .None do return
	return dt.Date{y, i8(m), i8(day)}, true
}

// Resolve by testing all offsets and round-tripping. Gaps have no candidate;
// folds select the earliest absolute instant, independent of TZ library guesses.
appointment_local_instant :: proc(local: dt.DateTime, zone: ^dt.TZ_Region) -> (at: i64, ok: bool) {
	ordinal, err := dt.date_to_ordinal(local.date); if err != .None do return
	epoch, _ := dt.components_to_ordinal(1970, 1, 1)
	seconds := (i64(ordinal) - i64(epoch)) * 86400 + i64(local.hour) * 3600 + i64(local.minute) * 60 + i64(local.second)
	best := max(i64)
	count := zone == nil ? 1 : len(zone.records) + 2
	for i in 0 ..< count {
		offset: i64
		if zone != nil do offset = i < len(zone.records) ? zone.records[i].utc_offset : (i == len(zone.records) ? zone.rrule.std_offset : zone.rrule.dst_offset)
		if offset > 172800 || offset < -172800 do continue
		candidate_seconds := seconds - offset
		if candidate_seconds < 0 || candidate_seconds > max(i64) / 1000000000 do continue
		if candidate_seconds == max(i64) / 1000000000 && i64(local.nano) > max(i64) % 1000000000 do continue
		candidate := candidate_seconds * 1000000000 + i64(local.nano)
		if candidate <= 0 do continue
		if appointment_offset(candidate, zone) == offset do best = min(best, candidate)
	}
	return best, best != max(i64)
}

appointment_local :: proc(at: i64, zone: ^dt.TZ_Region) -> dt.DateTime {
	u, _ := time.time_to_datetime(time.unix(0, at))
	l, _ := dt.add_delta_to_datetime(u, dt.Delta{seconds = appointment_offset(at, zone)})
	return l
}

// The parsed TZif POSIX footer stores the DST-entry rule in std_date and
// DST-exit rule in dst_date. Interpret transitions in the preceding local offset.
appointment_transition :: proc(year: i64, rule: dt.TZ_Transition_Date) -> i64 {
	date := dt.Date{year, 1, 1}
	days: i64
	if rule.type == .Month_Week_Day {
		date.month = i8(rule.month)
		ordinal, _ := dt.date_to_ordinal(date)
		days = (i64(rule.day) - i64(dt.day_of_week(ordinal)) + 7) % 7 + 7 * i64(rule.week - 1)
		last, _ := dt.last_day_of_month(year, date.month)
		if days >= i64(last) do days -= 7
	} else {
		days = i64(rule.day)
		if rule.type == .No_Leap {days -= 1; if dt.is_leap_year(year) && rule.day >= 60 do days += 1}
	}
	ordinal, _ := dt.date_to_ordinal(date)
	epoch, _ := dt.components_to_ordinal(1970, 1, 1)
	return (i64(ordinal) - i64(epoch) + days) * 86400 + rule.time
}

appointment_offset :: proc(at: i64, zone: ^dt.TZ_Region) -> i64 {
	if zone == nil do return 0
	seconds := at / 1000000000
	if len(zone.records) > 0 && seconds <= zone.records[len(zone.records) - 1].time {
		left, right := 0, len(zone.records)
		for left < right {mid := (left + right) / 2; if zone.records[mid].time <= seconds {left = mid + 1} else {right = mid}}
		return zone.records[max(0, left - 1)].utc_offset
	}
	r := zone.rrule
	if !r.has_dst do return r.std_offset
	date, _ := time.time_to_datetime(time.unix(0, at))
	enter := appointment_transition(date.year, r.std_date) - r.std_offset
	exit := appointment_transition(date.year, r.dst_date) - r.dst_offset
	active := enter < exit ? seconds >= enter && seconds < exit : seconds >= enter || seconds < exit
	return active ? r.dst_offset : r.std_offset
}

appointment_occurrence :: proc(r: Appointment_Record, at: i64, zone: ^dt.TZ_Region) -> bool {
	if r.repeat == "" || at < r.start_at do return false
	anchor := appointment_local(r.start_at, zone); local := appointment_local(at, zone)
	if local.time != anchor.time do return false
	if r.until !=
	   "" {until, _ := appointment_date(r.until); a, _ := dt.date_to_ordinal(local.date); b, _ := dt.date_to_ordinal(until); if a > b do return false}
	if r.repeat == "monthly" && local.day != anchor.day do return false
	if r.repeat == "weekly" {
		ordinal, _ := dt.date_to_ordinal(local.date); weekday := int(dt.day_of_week(ordinal)); if weekday == 0 do weekday = 7
		found := false; for d in r.weekdays do if d == weekday do found = true
		if !found do return false
	}
	resolved, ok := appointment_local_instant(local, zone)
	return ok && resolved == at
}

parse_appointment_v2 :: proc(data: []byte, allocator: mem.Allocator) -> (r: Appointment_Record, ok: bool) {
	f, object, valid := json_metadata_fields(
		data,
		[?]string {
			"version",
			"title",
			"start_at",
			"end_at",
			"description",
			"assignee",
			"project",
			"url",
			"timezone",
			"repeat",
			"weekdays",
			"until",
			"participants",
			"conference",
			"exceptions",
		},
		allocator,
		true,
	)
	if !valid || !object || f[0].kind != .Integer || f[0].text != "2" do return
	r.version = 2
	outs := [?]^[]byte{&r.title, &r.description, &r.assignee, &r.project, &r.url}
	indices := [?]int{1, 4, 5, 6, 7}
	limits := [?]int {
		pr.MAX_TASK_TITLE_LENGTH,
		pr.MAX_APPOINTMENT_DESCRIPTION_LENGTH,
		pr.MAX_ASSIGNEE_LENGTH,
		pr.MAX_PROJECT_LENGTH,
		pr.MAX_APPOINTMENT_URL_LENGTH,
	}
	for out, i in outs {
		t := f[indices[i]]; if t.kind == .Invalid && i != 0 do continue
		if t.kind != .String do return r, false
		out^ = transmute([]byte)json_metadata_string(t, allocator)
		if len(out^) > limits[i] do return r, false
	}
	if strings.trim_space(string(r.title)) == "" || f[2].kind != .String do return r, false
	r.start_at, ok = json_metadata_integer(json_metadata_string(f[2], allocator)); if !ok || r.start_at <= 0 || r.start_at == max(i64) do return r, false
	if f[3].kind != .Invalid {
		if f[3].kind != .String do return r, false
		s := json_metadata_string(f[3], allocator)
		if s != "" {r.end_at, ok = json_metadata_integer(s); if !ok || r.end_at <= r.start_at do return r, false}
	}
	string_indices := [?]int{8, 9, 11, 13}
	for out, i in ([?]^string{&r.timezone, &r.repeat, &r.until, &r.conference}) {
		t := f[string_indices[i]]
		if t.kind != .String do return r, false
		out^ = json_metadata_string(t, allocator)
	}
	if r.repeat != "" && r.repeat != "daily" && r.repeat != "weekly" && r.repeat != "monthly" do return r, false
	if r.conference != "none" && r.conference != "external" && r.conference != "nrc" do return r, false
	zone, loaded := appointment_zone(r.timezone, allocator); if !loaded do return r, false
	defer if zone != nil do tz.region_destroy(zone, allocator)
	if r.repeat != "" {first, good := appointment_local_instant(appointment_local(r.start_at, zone), zone); if !good || first != r.start_at do return r, false}
	if f[10].kind != .Open_Bracket || json.unmarshal_string(f[10].text, &r.weekdays, allocator = allocator) != nil do return r, false
	if f[12].kind != .Open_Bracket || json.unmarshal_string(f[12].text, &r.participants, allocator = allocator) != nil || !appointment_people_valid(r.participants) do return r, false
	if len(r.weekdays) > 7 || (r.repeat == "weekly") != (len(r.weekdays) > 0) do return r, false
	for day, i in r.weekdays {if day < 1 || day > 7 do return r, false; for previous in r.weekdays[:i] do if day == previous do return r, false}
	if r.repeat != "" && r.end_at != 0 && r.end_at - r.start_at > APPOINTMENT_DAY do return r, false
	if r.until != "" {
		d, good := appointment_date(r.until); if !good || r.repeat == "" do return r, false
		a, _ := dt.date_to_ordinal(d); b, _ := dt.date_to_ordinal(appointment_local(r.start_at, zone).date); if a < b do return r, false
	}
	// Extract validated object spans without losing optional-field presence.
	if f[14].kind != .Open_Bracket do return r, false
	tokenizer := json.make_tokenizer(f[14].text, .JSON, true)
	depth, begin := 0, 0
	for {
		t, e := json.get_token(&tokenizer)
		if t.kind == .EOF do break
		if e != nil do return r, false
		if depth == 0 && t.kind != .Open_Brace && t.kind != .Comma && t.kind != .Close_Bracket && !(t.kind == .Open_Bracket && t.offset == 0) do return r, false
		if t.kind == .Open_Brace {if depth == 0 do begin = t.offset; depth += 1}
		if t.kind != .Close_Brace do continue
		depth -= 1; if depth != 0 do continue
		if len(r.exceptions) >= 32 || r.repeat == "" do return r, false
		x, obj, good := json_metadata_fields(
			transmute([]byte)f[14].text[begin:t.offset + 1],
			[?]string{"at", "cancelled", "start_at", "end_at", "participants"},
			allocator,
			true,
		)
		if !obj || !good || x[0].kind != .String || (x[1].kind != .True && x[1].kind != .False) do return r, false
		ex: Appointment_Exception
		ex.at, good = json_metadata_integer(json_metadata_string(x[0], allocator)); if !good || !appointment_occurrence(r, ex.at, zone) do return r, false
		for previous in r.exceptions do if previous.at == ex.at do return r, false
		ex.cancelled = x[1].kind == .True
		ex.has_start = x[2].kind != .Invalid; ex.has_end = x[3].kind != .Invalid; ex.has_participants = x[4].kind != .Invalid
		if ex.cancelled && (ex.has_start || ex.has_end || ex.has_participants) do return r, false
		ex.start_at = ex.at
		if ex.has_start {if x[2].kind != .String do return r, false; ex.start_at, good = json_metadata_integer(json_metadata_string(x[2], allocator)); if !good || ex.start_at <= 0 || ex.start_at == max(i64) do return r, false}
		duration := r.end_at == 0 ? 0 : r.end_at - r.start_at
		if ex.start_at > max(i64) - duration do return r, false
		ex.end_at = duration == 0 ? 0 : ex.start_at + duration
		if ex.has_end {
			if x[3].kind != .String do return r, false
			text := json_metadata_string(x[3], allocator)
			ex.end_at = 0
			if text != "" {ex.end_at, good = json_metadata_integer(text); if !good || ex.end_at <= ex.start_at do return r, false}
		}
		if ex.end_at != 0 && ex.end_at - ex.start_at > APPOINTMENT_DAY do return r, false
		if ex.has_participants {if x[4].kind != .Open_Bracket || json.unmarshal_string(x[4].text, &ex.participants, allocator = allocator) != nil || !appointment_people_valid(ex.participants) do return r, false}
		append_exception := make(
			[]Appointment_Exception,
			len(r.exceptions) + 1,
			allocator,
		); copy(append_exception, r.exceptions); append_exception[len(r.exceptions)] = ex; r.exceptions = append_exception
	}
	// Reject collisions so the public (displayed start, kind, id) cursor is unique,
	// even when the query begins inside a rescheduled occurrence.
	for ex in r.exceptions {
		if ex.cancelled do continue
		finish := ex.end_at == 0 ? min(max(i64), ex.start_at + 1) : ex.end_at
		nearby := appointment_expand(r, max(1, ex.start_at - APPOINTMENT_DAY), min(max(i64) - APPOINTMENT_DAY, finish) + APPOINTMENT_DAY, zone, allocator)
		for other in nearby {
			if other.at == ex.at do continue
			other_end := other.end_at == 0 ? other.start_at + 1 : other.end_at
			if ex.start_at < other_end && other.start_at < finish do return r, false
		}
	}
	if !appointment_base_intervals_valid(r, zone, allocator) do return r, false
	return r, true
}

appointment_mutation_allowed :: proc(asset: ^pr.Asset, preview: []byte, username: string) -> bool {
	if asset == nil || asset.asset_type != .Appointment || string(asset.owner) == username do return true
	arena: virtual.Arena; if virtual.arena_init_growing(&arena) != nil do return false
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	old, _ := parse_appointment_preview(asset.preview, allocator)
	next, _ := parse_appointment_preview(preview, allocator)
	return old.version != 2 && next.version != 2
}

Appointment_Occurrence :: struct {
	at, start_at, end_at: i64,
	participants:         []string,
}

// Work is proportional to the bounded query, never the age of the series.
appointment_expand :: proc(r: Appointment_Record, start, end: i64, zone: ^dt.TZ_Region, allocator: mem.Allocator) -> [dynamic]Appointment_Occurrence {
	result := make([dynamic]Appointment_Occurrence, 0, 72, allocator)
	anchor := appointment_local(r.start_at, zone)
	first := appointment_local(max(1, start - min(start - 1, 2 * APPOINTMENT_DAY)), zone)
	last := appointment_local(min(max(i64) - 2 * APPOINTMENT_DAY, end) + 2 * APPOINTMENT_DAY, zone)
	a, _ := dt.date_to_ordinal(first.date); b, _ := dt.date_to_ordinal(last.date)
	duration := r.end_at == 0 ? 0 : r.end_at - r.start_at
	for day := a; day <= b; day += 1 {
		date, err := dt.ordinal_to_date(day); if err != .None do continue
		local := dt.DateTime {
			date = date,
			time = anchor.time,
		}
		at, good := appointment_local_instant(local, zone)
		if !good || !appointment_occurrence(r, at, zone) || at > max(i64) - duration do continue
		overridden := false; for ex in r.exceptions do if ex.at == at do overridden = true
		if overridden do continue
		finish := duration == 0 ? 0 : at + duration
		if at >= end || (finish == 0 ? at < start : finish <= start) do continue
		append(&result, Appointment_Occurrence{at, at, finish, r.participants})
	}
	for ex in r.exceptions {
		if ex.cancelled || ex.start_at >= end || (ex.end_at == 0 ? ex.start_at < start : ex.end_at <= start) do continue
		append(&result, Appointment_Occurrence{ex.at, ex.start_at, ex.end_at, ex.has_participants ? ex.participants : r.participants})
	}
	return result
}

appointment_person_matches :: proc(r: Appointment_Record, owner: []byte, participants: []string, person: []byte) -> bool {
	if len(person) == 0 || string(person) == string(r.assignee) do return true
	if r.version != 2 do return false
	if string(person) == string(owner) do return true
	for p in participants do if p == string(person) do return true
	return false
}

appointment_envelope :: proc(r: Appointment_Record) -> (start, end: i64) {
	start, end = r.start_at, r.end_at
	if r.repeat == "" do return
	end = max(i64)
	if r.until != "" {
		d, _ := appointment_date(r.until)
		t, good := time.datetime_to_time(dt.DateTime{date = d})
		if good {n := time.to_unix_nanoseconds(t); if n > 0 && n < max(i64) - 3 * APPOINTMENT_DAY do end = n + 3 * APPOINTMENT_DAY}
	}
	for ex in r.exceptions {if ex.cancelled do continue; start = min(start, ex.start_at); end = max(end, max(ex.start_at + 1, ex.end_at))}
	return
}

appointment_transition_intervals_valid :: proc(r: Appointment_Record, seconds: i64, zone: ^dt.TZ_Region, allocator: mem.Allocator) -> bool {
	if seconds <= 0 || seconds > (max(i64) - 3 * APPOINTMENT_DAY) / 1000000000 do return true
	at := seconds * 1000000000
	if at + 3 * APPOINTMENT_DAY < r.start_at do return true
	_, envelope_end := appointment_envelope(r); if at - 3 * APPOINTMENT_DAY >= envelope_end do return true
	nearby := appointment_expand(r, max(1, at - 3 * APPOINTMENT_DAY), at + 3 * APPOINTMENT_DAY, zone, allocator)
	for a, i in nearby {
		for b in nearby[:i] {
			if a.start_at < (b.end_at == 0 ? b.start_at + 1 : b.end_at) && b.start_at < (a.end_at == 0 ? a.start_at + 1 : a.end_at) do return false
		}
	}
	return true
}

// A 24-hour interval can overlap its successor on a short DST day. Check only
// forward offset transitions (including POSIX-footer years), not historical days.
appointment_base_intervals_valid :: proc(r: Appointment_Record, zone: ^dt.TZ_Region, allocator: mem.Allocator) -> bool {
	if r.repeat == "" || r.end_at == 0 || zone == nil do return true
	duration := r.end_at - r.start_at
	for record, i in zone.records {
		if i == 0 do continue
		jump := record.utc_offset - zone.records[i - 1].utc_offset
		if jump <= 0 || duration <= APPOINTMENT_DAY - jump * 1000000000 do continue
		if !appointment_transition_intervals_valid(r, record.time, zone, allocator) do return false
	}
	footer := zone.rrule
	if !footer.has_dst do return true
	jump := abs(footer.dst_offset - footer.std_offset)
	if duration <= APPOINTMENT_DAY - jump * 1000000000 do return true
	first_year := appointment_local(r.start_at, zone).year
	if len(zone.records) >
	   0 {last, _ := time.time_to_datetime(time.unix(zone.records[len(zone.records) - 1].time, 0)); first_year = max(first_year, last.year)}
	last_year: i64 = 2262
	if r.until != "" {until, _ := appointment_date(r.until); last_year = min(last_year, until.year)}
	for year := first_year; year <= last_year; year += 1 {
		enter := appointment_transition(year, footer.std_date) - footer.std_offset
		exit := appointment_transition(year, footer.dst_date) - footer.dst_offset
		if !appointment_transition_intervals_valid(r, enter, zone, allocator) || !appointment_transition_intervals_valid(r, exit, zone, allocator) do return false
	}
	return true
}
