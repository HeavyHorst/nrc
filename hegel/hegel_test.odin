package hegel

// Self-tests for the local Hegel property-testing harness. These verify drawing,
// shrinking, failure reporting, replay, and generated data helpers before other
// packages rely on Hegel for protocol, index, and integrated simulation checks.

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:testing"

@(test)
test_error_nil_values_are_not_errors :: proc(t: ^testing.T) {
	hegel_err: Hegel_Error = nil
	draw_err: Draw_Error = nil

	testing.expect_value(t, hegel_err, Hegel_Error.None)
	testing.expect_value(t, draw_err, Draw_Error.None)
}

@(test)
test_effective_test_case_budget :: proc(t: ^testing.T) {
	test_cases, multiplier, ok := effective_test_case_budget(0, "", false)
	testing.expect(t, ok)
	testing.expect_value(t, test_cases, 100)
	testing.expect_value(t, multiplier, 1)

	test_cases, multiplier, ok = effective_test_case_budget(25, " 4 ", true)
	testing.expect(t, ok)
	testing.expect_value(t, test_cases, 100)
	testing.expect_value(t, multiplier, 4)

	invalid_multipliers := [4]string{"", "0", "1001", "invalid"}
	for value in invalid_multipliers {
		_, _, invalid_ok := effective_test_case_budget(25, value, true)
		testing.expectf(t, !invalid_ok, "expected invalid multiplier %q to be rejected", value)
	}
	_, _, overflow_ok := effective_test_case_budget(max(int), "2", true)
	testing.expect(t, !overflow_ok, "expected overflowing test-case budget to be rejected")
}

@(test)
test_effective_seed :: proc(t: ^testing.T) {
	seed, ok := effective_seed(42, "invalid", true)
	testing.expect(t, ok, "explicit seed should take precedence over the environment")
	testing.expect_value(t, seed, u64(42))

	seed, ok = effective_seed(0, "", false)
	testing.expect(t, ok)
	testing.expect_value(t, seed, u64(0))

	seed, ok = effective_seed(0, " 12345 ", true)
	testing.expect(t, ok)
	testing.expect_value(t, seed, u64(12345))

	invalid_seeds := [4]string{"", "0", "-1", "invalid"}
	for value in invalid_seeds {
		_, invalid_ok := effective_seed(0, value, true)
		testing.expectf(t, !invalid_ok, "expected invalid seed %q to be rejected", value)
	}
}

@(test)
test_loaded_libhegel_matches_pinned_version :: proc(t: ^testing.T) {
	if !can_run() do return
	ctx := libhegel_symbols.hegel_context_new()
	defer libhegel_symbols.hegel_context_free(ctx)
	version: cstring
	result := libhegel_symbols.hegel_version(ctx, &version)
	testing.expect_value(t, result, Libhegel_Result.OK)
	testing.expect_value(t, string(version), LIBHEGEL_VERSION)
}

@(test)
test_libhegel_version_compatibility :: proc(t: ^testing.T) {
	testing.expect(t, libhegel_version_compatible(.OK, LIBHEGEL_VERSION))
	testing.expect(t, !libhegel_version_compatible(.OK, "0.23.2"))
	testing.expect(t, !libhegel_version_compatible(.OK, ""))
	testing.expect(t, !libhegel_version_compatible(.Backend, LIBHEGEL_VERSION))
}

@(test)
test_effective_database_is_versioned_and_respects_overrides :: proc(t: ^testing.T) {
	testing.expect_value(t, effective_database({}), ".hegel/examples/0.33.3/")
	testing.expect_value(t, effective_database({database = "/tmp/hegel-examples"}), "/tmp/hegel-examples")
	testing.expect_value(t, effective_database({database = "/tmp/hegel-examples", disable_database = true}), "")
}

@(test)
test_run_creates_explicit_example_database :: proc(t: ^testing.T) {
	if !can_run() do return
	database := fmt.tprintf("/tmp/nrc-hegel-test-%d", os.get_pid())
	defer os.remove_all(database)

	previous_logger := context.logger
	context.logger = log.nil_logger()
	result, err := run(prop_database_failure, nil, {test_cases = 1, seed = 1, database = database, database_key = "database-smoke"})
	context.logger = previous_logger
	testing.expectf(
		t,
		err == .Property_Failed,
		"database smoke run should find its expected failure: err=%v interesting=%v",
		err,
		result.interesting_test_cases,
	)
	info, stat_err := os.stat(database, context.temp_allocator)
	testing.expect(t, stat_err == nil && info.type == .Directory, "explicit Hegel database directory should be created")
}

prop_database_failure :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	_, err := draw_bool(tc)
	if err == .Stop_Test do return abort()
	if err != nil do return interesting("database draw failed")
	return interesting("expected database smoke failure")
}

@(test)
test_native_failure_shrinks_and_replays_across_draw_kinds :: proc(t: ^testing.T) {
	if !can_run() do return
	previous_logger := context.logger
	context.logger = log.nil_logger()
	result, err := run(prop_failure_across_draw_kinds, nil, {test_cases = 32, seed = 7, disable_database = true})
	context.logger = previous_logger
	testing.expect_value(t, err, Hegel_Error.Property_Failed)
	testing.expect_value(t, result.interesting_test_cases, i64(1))
}

prop_failure_across_draw_kinds :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	use_text, err := draw_bool(tc)
	if err == .Stop_Test do return abort()
	if err != nil do return interesting("branch draw failed")
	if use_text {
		value, text_err := draw_text(tc, 0, 32)
		if text_err == .Stop_Test do return abort()
		if text_err != nil do return interesting("text branch draw failed")
		delete(value)
	} else {
		_, integer_err := draw_i64(tc, -1_000, 1_000)
		if integer_err == .Stop_Test do return abort()
		if integer_err != nil do return interesting("integer branch draw failed")
	}
	return interesting("expected cross-draw-kind failure")
}

@(test)
test_draw_bool :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_draw_bool, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "draw_bool test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_draw_bool :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	b, draw_err := draw_bool(tc)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("draw_bool error")
	}
	if b != true && b != false {
		return interesting("boolean not boolean")
	}
	return valid()
}

@(test)
test_draw_bytes :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_draw_bytes, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "draw_bytes test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_draw_bytes :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	data, draw_err := draw_bytes(tc, 4, 16)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("draw_bytes error")
	}
	if len(data) < 4 || len(data) > 16 {
		return interesting("bytes length out of bounds")
	}
	delete(data)
	return valid()
}

@(test)
test_assume_auto_reject :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_assume_auto_reject, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "assume auto-reject test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_assume_auto_reject :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	n, draw_err := draw_i64(tc, 0, 100)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("draw_i64 error")
	}
	assume(tc, n % 2 == 0)
	if n % 2 != 0 && !tc.rejected {
		return interesting("assume did not set rejected")
	}
	return valid()
}

@(test)
test_assume_with_manual_invalid :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_assume_with_manual_invalid, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "assume manual-invalid test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_assume_with_manual_invalid :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	n, draw_err := draw_i64(tc, 0, 100)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("draw_i64 error")
	}
	assume(tc, n % 2 == 0)
	if tc.rejected {
		return invalid()
	}
	if n % 2 != 0 {
		return interesting("odd number passed assume")
	}
	return valid()
}

@(test)
test_note :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_note, nil, {test_cases = 10})
	testing.expectf(t, err == nil, "note test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_note :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	n, draw_err := draw_i64(tc, 0, 10)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("draw_i64 error")
	}
	note(tc, fmt.tprintf("drawn value: %d", n))
	return valid()
}

@(test)
test_draw_u32 :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_draw_u32, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "draw_u32 test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_draw_u32 :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	n, draw_err := draw_u32(tc, 0, 100)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("draw_u32 error")
	}
	if n > 100 {
		return interesting("u32 out of bounds")
	}
	return valid()
}

@(test)
test_draw_u64 :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_draw_u64, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "draw_u64 test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_draw_u64 :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	n, draw_err := draw_u64(tc, 0, 1_000_000)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("draw_u64 error")
	}
	if n > 1_000_000 {
		return interesting("u64 out of bounds")
	}
	return valid()
}

@(test)
test_draw_u64_above_i64_range :: proc(t: ^testing.T) {
	if !can_run() do return
	result, err := run(prop_draw_u64_above_i64_range, nil, {test_cases = 100, disable_database = true})
	testing.expectf(t, err == nil, "large draw_u64 test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_draw_u64_above_i64_range :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	min_value := u64(max(i64)) + 1
	n, draw_err := draw_u64(tc, min_value, max(u64))
	if draw_err == .Stop_Test do return abort()
	if draw_err != nil do return interesting("large draw_u64 error")
	if n < min_value do return interesting("large u64 below lower bound")
	return valid()
}

@(test)
test_draw_f64 :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_draw_f64, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "draw_f64 test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_draw_f64 :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	n, draw_err := draw_f64(tc, 0.0, 100.0)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("draw_f64 error")
	}
	if n < 0.0 || n > 100.0 {
		return interesting("f64 out of bounds")
	}
	return valid()
}

@(test)
test_draw_text :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_draw_text, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "draw_text test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_draw_text :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	s, draw_err := draw_text(tc, 0, 50)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("draw_text error")
	}
	defer delete(s)
	// len(s) counts UTF-8 bytes; server counts codepoints (up to 50).
	// Max 4 bytes per codepoint, so at most 200 bytes.
	if len(s) > 200 {
		return interesting("text length out of bounds")
	}
	return valid()
}

// ============================================================================
// Generator abstraction tests (steps 1-3)
// ============================================================================

// --- Server-backed tests ---

@(test)
test_gen_draw_basic_i64 :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_draw_basic_i64, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "gen_draw basic_i64 test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_draw_basic_i64 :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	int_gen := basic_i64(0, 100)

	n, draw_err := gen_draw(tc, int_gen)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("gen_draw basic_i64 error")
	}
	if n < 0 || n > 100 {
		return interesting("i64 out of range")
	}
	return valid()
}

@(test)
test_gen_draw_basic_bool :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_draw_basic_bool, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "gen_draw basic_bool test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_draw_basic_bool :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	bool_gen := basic_bool()

	b, draw_err := gen_draw(tc, bool_gen)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("gen_draw basic_bool error")
	}
	if b != true && b != false {
		return interesting("bool not boolean")
	}
	return valid()
}

@(test)
test_gen_draw_basic_text :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_draw_basic_text, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "gen_draw basic_text test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_draw_basic_text :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	text_gen := basic_text(1, 30)

	s, draw_err := gen_draw(tc, text_gen)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("gen_draw basic_text error")
	}
	defer delete(s)
	// len(s) counts UTF-8 bytes; the server counts codepoints (1..30).
	// Max 4 bytes per codepoint, so byte len is at most 120.
	if len(s) < 1 || len(s) > 120 {
		return interesting("text length out of bounds")
	}
	return valid()
}

// --- Composite generator tests ---

@(test)
test_gen_draw_composite_pair :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_draw_composite_pair, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "gen_draw composite pair test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_draw_composite_pair :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	pair_gen := composite([2]i64, proc(tc: ^Test_Case) -> ([2]i64, Draw_Error) {
		x, err := gen_draw(tc, basic_i64(0, 50))
		if err != nil {return {}, err}
		y, err_y := gen_draw(tc, basic_i64(0, 50))
		if err_y != nil {return {}, err_y}
		return [2]i64{x, y}, nil
	})

	pair, draw_err := gen_draw(tc, pair_gen)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("gen_draw composite pair error")
	}
	if pair.x < 0 || pair.x > 50 || pair.y < 0 || pair.y > 50 {
		return interesting("composite pair out of range")
	}
	return valid()
}

Test_Person :: struct {
	name: string,
	age:  i64,
}

@(test)
test_gen_draw_composite_struct :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_draw_composite_struct, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "gen_draw composite struct test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_draw_composite_struct :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	person_gen := composite(Test_Person, proc(tc: ^Test_Case) -> (Test_Person, Draw_Error) {
		name, err := gen_draw(tc, basic_text(1, 20))
		if err != nil {return {}, err}
		age, err_age := gen_draw(tc, basic_i64(0, 120))
		if err_age != nil {delete(name); return {}, err_age}
		return Test_Person{name = name, age = age}, nil
	})

	p, draw_err := gen_draw(tc, person_gen)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("gen_draw composite struct error")
	}
	defer delete(p.name)
	// len counts UTF-8 bytes; server counts codepoints (1..20).
	// Max 4 bytes per codepoint, so at most 80.
	if len(p.name) < 1 || len(p.name) > 80 {
		return interesting("person name length out of bounds")
	}
	if p.age < 0 || p.age > 120 {
		return interesting("person age out of bounds")
	}
	return valid()
}

// --- Construction / destruction tests (no server needed) ---

@(test)
test_gen_construction :: proc(t: ^testing.T) {
	// Test that basic_i64 produces a Gen(i64) of correct variant
	g := basic_i64(0, 100)

	#partial switch v in g {
	case Basic_Gen(i64):
		testing.expect(t, v.draw != nil, "basic_i64 draw proc should not be nil")
	case:
		testing.expect(t, false, "basic_i64 should produce Basic_Gen variant")
	}
}

@(test)
test_gen_composite_construction :: proc(t: ^testing.T) {
	// Test that composite produces a Gen of correct variant
	fn :: proc(tc: ^Test_Case) -> (i64, Draw_Error) {return 42, nil}
	g := composite(i64, fn)

	#partial switch v in g {
	case Composite_Gen(i64):
		testing.expect(t, v.fn != nil, "composite fn should not be nil")
	case:
		testing.expect(t, false, "composite should produce Composite_Gen variant")
	}
}

@(test)
test_gen_draw_composite_pure_function :: proc(t: ^testing.T) {
	// Composite with a pure function (no sub-generators) should work
	fn :: proc(tc: ^Test_Case) -> (i64, Draw_Error) {return 42, nil}
	g := composite(i64, fn)

	// Make a fake Test_Case
	tc: Test_Case
	val, err := gen_draw(&tc, g)
	testing.expect_value(t, err, Draw_Error.None)
	testing.expect_value(t, val, i64(42))
}

@(test)
test_gen_draw_composite_propagates_error :: proc(t: ^testing.T) {
	fn :: proc(tc: ^Test_Case) -> (i64, Draw_Error) {return 0, .Protocol_Error}
	g := composite(i64, fn)

	tc: Test_Case
	_, err := gen_draw(&tc, g)
	testing.expect_value(t, err, Draw_Error.Protocol_Error)
}

// ============================================================================
// Combinator tests (just, sampled_from, one_of, filter)
// ============================================================================

@(test)
test_gen_just :: proc(t: ^testing.T) {
	g := just(i64, 42)

	#partial switch v in g {
	case Just_Gen(i64):
		testing.expect_value(t, v.value, i64(42))
	case:
		testing.expect(t, false, "just should produce Just_Gen variant")
	}

	// Draw from a fake Test_Case (no server needed — just returns constant).
	tc: Test_Case
	val, err := gen_draw(&tc, g)
	testing.expect_value(t, err, Draw_Error.None)
	testing.expect_value(t, val, i64(42))
}

@(test)
test_gen_just_string :: proc(t: ^testing.T) {
	g := just(string, "hello")

	tc: Test_Case
	val, err := gen_draw(&tc, g)
	testing.expect_value(t, err, Draw_Error.None)
	testing.expect_value(t, val, "hello")
}

@(test)
test_gen_sampled_from :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_sampled_from, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "sampled_from test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_sampled_from :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	values := []i64{10, 20, 30, 40, 50}
	g := sampled_from(i64, values)

	val, draw_err := gen_draw(tc, g)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("sampled_from error")
	}
	// Check it's one of the valid values
	found := false
	for v in values {
		if val == v {
			found = true
			break
		}
	}
	if !found {
		return interesting("sampled_from returned unexpected value")
	}
	return valid()
}

@(test)
test_gen_one_of :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_one_of, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "one_of test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_one_of :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	gens := []Gen(i64){basic_i64(0, 10), basic_i64(100, 110)}
	g := one_of(i64, gens)

	val, draw_err := gen_draw(tc, g)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("one_of error")
	}
	if !(val >= 0 && val <= 10) && !(val >= 100 && val <= 110) {
		return interesting("one_of returned value outside all ranges")
	}
	return valid()
}

@(test)
test_gen_filter :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_filter, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "filter test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_filter :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	source := basic_i64(0, 100)
	always_true := proc(n: i64) -> bool {return true}
	g := filter(i64, source, always_true)
	defer gen_destroy(g)

	val, draw_err := gen_draw(tc, g)
	if draw_err == .Stop_Test {
		return abort()
	}
	if draw_err != nil {
		return interesting("filter error")
	}
	if val < 0 || val > 100 {
		return interesting("filter value out of range")
	}
	return valid()
}

@(test)
test_gen_filter_all_pass :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	// Filter with always-true predicate — every value is accepted.
	// Tests the filter infrastructure without rejection overhead.
	result, err := run(prop_gen_filter_all_pass, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "filter all_pass test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_filter_all_pass :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	source := basic_i64(0, 100)
	accept_all := proc(n: i64) -> bool {return true}
	g := filter(i64, source, accept_all)
	defer gen_destroy(g)

	val, draw_err := gen_draw(tc, g)
	if draw_err == .Stop_Test {return abort()}
	if draw_err != nil {return interesting("filter error")}
	if val < 0 || val > 100 {return interesting("range")}
	return valid()
}

@(test)
test_gen_filter_with_attempts_rejects_after_configured_limit :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_filter_with_attempts_rejects, nil, {test_cases = 5})
	testing.expectf(t, err == nil, "filter_with_attempts rejection test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_filter_with_attempts_rejects :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	source := basic_i64(0, 100)
	reject_all := proc(n: i64) -> bool {return false}
	g := filter_with_attempts(i64, source, reject_all, 2)
	defer gen_destroy(g)

	_, draw_err := gen_draw(tc, g)
	if draw_err != .Stop_Test || !tc.rejected {
		return interesting("filter_with_attempts did not reject after configured attempts")
	}
	return invalid()
}

// ============================================================================
// Vec_Gen tests (gen_draw_vec)
// ============================================================================

@(test)
test_gen_vec_construction :: proc(t: ^testing.T) {
	elem_gen := basic_i64(0, 100)
	vg := vectors(i64, elem_gen, 2, 5)

	// Vec_Gen is a standalone struct, just check fields
	testing.expect(t, vg.min_size == 2, "min_size should be 2")
	testing.expect(t, vg.max_size == 5, "max_size should be 5")
}

@(test)
test_gen_draw_vec :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_draw_vec, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "gen_draw_vec test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_draw_vec :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	elem_gen := basic_i64(0, 100)
	vg := vectors(i64, elem_gen, 2, 5)

	slice, draw_err := gen_draw_vec(tc, vg)
	if draw_err == .Stop_Test {return abort()}
	if draw_err != nil {return interesting("gen_draw_vec error")}
	if len(slice) < 2 || len(slice) > 5 {
		return interesting("slice length outside expected range")
	}
	for v, i in slice {
		if v < 0 || v > 100 {
			return interesting("element out of range")
		}
		_ = i
	}
	delete(slice)
	return valid()
}

@(test)
test_gen_draw_vec_in_composite :: proc(t: ^testing.T) {
	if !can_run() {
		return
	}

	result, err := run(prop_gen_draw_vec_in_composite, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "gen_draw_vec in composite test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_gen_draw_vec_in_composite :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	// Composite that draws a vector and sums its elements
	sum_gen := composite(i64, proc(tc: ^Test_Case) -> (i64, Draw_Error) {
		vg := vectors(i64, basic_i64(0, 50), 1, 3)
		items, err := gen_draw_vec(tc, vg)
		if err != nil {return 0, err}
		defer delete(items)
		sum: i64
		for v in items {sum += v}
		return sum, nil
	})

	sum, draw_err := gen_draw(tc, sum_gen)
	if draw_err == .Stop_Test {return abort()}
	if draw_err != nil {return interesting("composite gen_draw_vec error")}
	// With 1-3 elements each 0-50, sum is at most 150
	if sum < 0 || sum > 150 {
		return interesting("sum out of expected range")
	}
	return valid()
}

// ============================================================================
// Format generator tests
// ============================================================================

@(test)
test_gen_format_construction :: proc(t: ^testing.T) {
	// Verify each format constructor produces a Basic_Gen(string)
	check_gen :: proc(gen: Gen(string)) -> bool {
		#partial switch v in gen {
		case Basic_Gen(string):
			return v.draw != nil
		case:
			return false
		}
	}
	testing.expect(t, check_gen(emails()), "emails should be Basic_Gen")
	testing.expect(t, check_gen(urls()), "urls should be Basic_Gen")
	testing.expect(t, check_gen(domains()), "domains should be Basic_Gen")
	testing.expect(t, check_gen(ip_addresses()), "ip_addresses should be Basic_Gen")
	testing.expect(t, check_gen(ip_addresses_v4()), "ip_addresses_v4 should be Basic_Gen")
	testing.expect(t, check_gen(ip_addresses_v6()), "ip_addresses_v6 should be Basic_Gen")
	testing.expect(t, check_gen(dates()), "dates should be Basic_Gen")
	testing.expect(t, check_gen(times()), "times should be Basic_Gen")
	testing.expect(t, check_gen(datetimes()), "datetimes should be Basic_Gen")
}

// Each format test needs its own prop function (Odin procs don't capture).

@(test)
test_gen_emails :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_format_emails, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "emails test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_format_emails :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	val, err := gen_draw(tc, emails())
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("email error")}
	defer delete(val)
	if len(val) == 0 {return interesting("empty email")}
	return valid()
}

@(test)
test_gen_urls :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_format_urls, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "urls test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_format_urls :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	val, err := gen_draw(tc, urls())
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("url error")}
	defer delete(val)
	if len(val) == 0 {return interesting("empty url")}
	return valid()
}

@(test)
test_gen_domains :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_format_domains, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "domains test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_format_domains :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	val, err := gen_draw(tc, domains())
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("domain error")}
	defer delete(val)
	if len(val) == 0 {return interesting("empty domain")}
	return valid()
}

@(test)
test_gen_ip_addresses :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_format_ip_addrs, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "ip_addresses test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_format_ip_addrs :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	val, err := gen_draw(tc, ip_addresses())
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("ip_address error")}
	if len(val) == 0 {return interesting("empty ip_address")}
	return valid()
}

@(test)
test_gen_ip_v4 :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_format_ip_v4, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "ip_v4 test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_format_ip_v4 :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	val, err := gen_draw(tc, ip_addresses_v4())
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("ip_v4 error")}
	if len(val) == 0 {return interesting("empty ip_v4")}
	return valid()
}

@(test)
test_gen_ip_v6 :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_format_ip_v6, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "ip_v6 test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_format_ip_v6 :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	val, err := gen_draw(tc, ip_addresses_v6())
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("ip_v6 error")}
	if len(val) == 0 {return interesting("empty ip_v6")}
	return valid()
}

@(test)
test_gen_dates :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_format_dates, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "dates test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_format_dates :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	val, err := gen_draw(tc, dates())
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("date error")}
	if len(val) == 0 {return interesting("empty date")}
	return valid()
}

@(test)
test_gen_times :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_format_times, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "times test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_format_times :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	val, err := gen_draw(tc, times())
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("time error")}
	if len(val) == 0 {return interesting("empty time")}
	return valid()
}

@(test)
test_gen_datetimes :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_format_datetimes, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "datetimes test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_format_datetimes :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	val, err := gen_draw(tc, datetimes())
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("datetime error")}
	if len(val) == 0 {return interesting("empty datetime")}
	return valid()
}

// ============================================================================
// Rich text generator tests (Text_Generator + from_regex)
// ============================================================================

@(test)
test_text_gen_basic :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_text_gen_basic, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "text_gen basic test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_text_gen_basic :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	gen := text()
	gen = text_gen_min_size(gen, 3)
	gen = text_gen_max_size(gen, 15)
	val, err := text_gen_draw(tc, gen)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("text_gen basic error")}
	defer delete(val)
	if len(val) == 0 {return interesting("empty text_gen result")}
	return valid()
}

@(test)
test_text_gen_alphabet :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_text_gen_alphabet, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "text_gen alphabet test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_text_gen_alphabet :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	gen := text()
	gen = text_gen_min_size(gen, 5)
	gen = text_gen_max_size(gen, 10)
	gen = text_gen_alphabet(gen, "ACGT")
	val, err := text_gen_draw(tc, gen)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("text_gen alphabet error")}
	defer delete(val)
	if len(val) == 0 {return interesting("empty alphabet result")}
	for character in val {
		if character != 'A' && character != 'C' && character != 'G' && character != 'T' {
			return interesting("text_gen produced character outside alphabet")
		}
	}
	return valid()
}

@(test)
test_text_gen_codec :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_text_gen_codec, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "text_gen codec test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_text_gen_codec :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	gen := text()
	gen = text_gen_min_size(gen, 1)
	gen = text_gen_max_size(gen, 20)
	gen = text_gen_codec(gen, "ascii")
	val, err := text_gen_draw(tc, gen)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("text_gen codec error")}
	defer delete(val)
	if len(val) == 0 {return interesting("empty codec result")}
	return valid()
}

@(test)
test_from_regex :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_from_regex, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "from_regex test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_from_regex :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	gen := from_regex("[A-Z]{2}-[0-9]{4}", true)
	val, err := gen_draw(tc, gen)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("from_regex error")}
	defer delete(val)
	if len(val) < 1 {return interesting("empty regex result")}
	return valid()
}

// ============================================================================
// Map / FlatMap tests
// ============================================================================

@(test)
test_gen_map_construction :: proc(t: ^testing.T) {
	source := basic_i64(0, 100)
	double := proc(n: i64) -> i64 {return n * 2}
	m := Mapped(i64, i64) {
		source = source,
		fn     = double,
	}
	testing.expect(t, m.fn != nil, "map fn should not be nil")
}

@(test)
test_gen_map_i64_to_f64 :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_map_i64_to_f64, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "map i64->f64 test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_map_i64_to_f64 :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	source := basic_i64(0, 100)
	as_f64 := proc(n: i64) -> f64 {return f64(n)}
	gen := Mapped(i64, f64) {
		source = source,
		fn     = as_f64,
	}

	val, err := gen_draw_mapped(tc, gen)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("map error")}
	if val < 0.0 || val > 100.0 {return interesting("mapped value out of range")}
	return valid()
}

@(test)
test_gen_map_string_transform :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_map_string_transform, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "map string transform test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_map_string_transform :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	source := basic_text(1, 20)
	upper_len := proc(s: string) -> int {defer delete(s); return len(s)}
	gen := Mapped(string, int) {
		source = source,
		fn     = upper_len,
	}

	val, err := gen_draw_mapped(tc, gen)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("map string-int error")}
	if val < 1 || val > 80 {return interesting("string length out of expected byte range")}
	return valid()
}

@(test)
test_gen_flatmap_dependent :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_flatmap_dependent, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "flat_map test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_flatmap_dependent :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	// Draw a size N, then generate a string of length N
	source := basic_i64(1, 10)
	text_of_len := proc(n: i64) -> Gen(string) {
		return basic_text(int(n), int(n))
	}
	gen := FlatMapped(i64, string) {
		source = source,
		fn     = text_of_len,
	}

	val, err := gen_draw_flatmapped(tc, gen)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("flat_map error")}
	defer delete(val)
	// Expected length is 1..10 codepoints, byte length up to 40
	if len(val) < 1 {return interesting("empty flat_mapped string")}
	if len(val) > 40 {return interesting("flat_mapped string too long")}
	return valid()
}

@(test)
test_gen_map_inside_composite :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_map_inside_composite, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "map inside composite test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_map_inside_composite :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	// Use map inside composite — Mapped is recreated each draw
	sum_gen := composite(f64, proc(tc: ^Test_Case) -> (f64, Draw_Error) {
		halved := Mapped(i64, f64) {
			source = basic_i64(0, 100),
			fn = proc(n: i64) -> f64 {return f64(n) / 2.0},
		}
		a, err := gen_draw_mapped(tc, halved)
		if err != nil {return 0, err}
		b, err_b := gen_draw_mapped(tc, halved)
		if err_b != nil {return 0, err_b}
		return a + b, nil
	})

	val, err := gen_draw(tc, sum_gen)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("composite+map error")}
	if val < 0.0 || val > 100.0 {return interesting("composite+map sum out of range")}
	return valid()
}

// ============================================================================
// Opt / Pair / Triple tests
// ============================================================================

@(test)
test_opt_construction :: proc(t: ^testing.T) {
	source := basic_i64(0, 100)
	o := Opt(i64) {
		source = source,
	}
	_ = o
}

@(test)
test_opt_nil :: proc(t: ^testing.T) {
	// Opt with a no-draw source — tests the nil path.
	// We pass a fake Test_Case; the bool draw will fail (no server),
	// but we test the construction path at least.
	fn :: proc(tc: ^Test_Case) -> (i64, Draw_Error) {return 42, nil}
	source := composite(i64, fn)
	o := Opt(i64) {
		source = source,
	}
	_ = o
}

@(test)
test_pair_construction :: proc(t: ^testing.T) {
	first := basic_i64(0, 100)
	second := basic_text(1, 10)
	p := Pair(i64, string) {
		first  = first,
		second = second,
	}
	_ = p
}

@(test)
test_triple_construction :: proc(t: ^testing.T) {
	p := Triple(i64, string, bool) {
		first  = basic_i64(0, 100),
		second = basic_text(1, 10),
		third  = basic_bool(),
	}
	_ = p
}

@(test)
test_pair_gen_draw :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_pair_draw, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "pair draw test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_pair_draw :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	p := Pair(i64, string) {
		first  = basic_i64(0, 100),
		second = basic_text(1, 10),
	}
	a, b, err := gen_draw_pair(tc, p)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("pair draw error")}
	defer delete(b)
	if a < 0 || a > 100 {return interesting("first out of range")}
	if len(b) == 0 {return interesting("empty second")}
	return valid()
}

@(test)
test_triple_gen_draw :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_triple_draw, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "triple draw test failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_triple_draw :: proc(tc: ^Test_Case, _: rawptr) -> Body_Result {
	// A later draw can abort after allocating the string, without returning it.
	// Keep all intermediate values owned by this property invocation.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	t := Triple(i64, string, bool) {
		first  = basic_i64(0, 50),
		second = basic_text(1, 5),
		third  = basic_bool(),
	}
	a, b, c, err := gen_draw_triple(tc, t)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("triple draw error")}
	if a < 0 || a > 50 {return interesting("first out of range")}
	if len(b) == 0 {return interesting("empty second")}
	_ = c
	return valid()
}

@(test)
test_triple_abort_releases_property_arena :: proc(t: ^testing.T) {
	// No native randomness: force allocation followed by an abort on every run.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	tc: Test_Case
	gen := Triple(i64, string, bool) {
		first  = just(i64, 7),
		second = composite(string, proc(_: ^Test_Case) -> (string, Draw_Error) {
			return fmt.aprintf("owned intermediate %d", 19), nil
		}),
		third  = composite(bool, proc(_: ^Test_Case) -> (bool, Draw_Error) {
			return false, .Stop_Test
		}),
	}
	_, value, _, err := gen_draw_triple(&tc, gen)
	testing.expect_value(t, err, Draw_Error.Stop_Test)
	testing.expect_value(t, value, "")
	testing.expect(t, arena.current_block != nil && arena.bytes_left < arena.block_size)
}

// ============================================================================
// Settings tests (seed, derandomize)
// ============================================================================

Seed_Capture :: struct {
	values: [dynamic]i64,
}

@(test)
test_run_with_seed :: proc(t: ^testing.T) {
	if !can_run() {return}

	capture1 := Seed_Capture {
		values = make([dynamic]i64, 0, 10),
	}
	defer delete(capture1.values)
	capture2 := Seed_Capture {
		values = make([dynamic]i64, 0, 10),
	}
	defer delete(capture2.values)

	_, err1 := run(prop_seed_test, &capture1, {test_cases = 10, seed = 42})
	_, err2 := run(prop_seed_test, &capture2, {test_cases = 10, seed = 42})
	testing.expectf(t, err1 == nil, "seed run 1 failed: err=%v", err1)
	testing.expectf(t, err2 == nil, "seed run 2 failed: err=%v", err2)
	testing.expect_value(t, len(capture1.values), len(capture2.values))
	if len(capture1.values) == len(capture2.values) {
		for value, index in capture1.values {
			testing.expect_value(t, value, capture2.values[index])
		}
	}
}

prop_seed_test :: proc(tc: ^Test_Case, user_data: rawptr) -> Body_Result {
	val, err := draw_i64(tc, 0, 1000)
	if err == .Stop_Test {return abort()}
	if err != nil {return interesting("seed draw error")}
	if capture := (^Seed_Capture)(user_data); capture != nil {
		append(&capture.values, val)
	}
	return valid()
}

@(test)
test_run_with_derandomize :: proc(t: ^testing.T) {
	if !can_run() {return}
	result, err := run(prop_seed_test, nil, {test_cases = 10, derandomize = true})
	testing.expectf(t, err == nil, "derandomize run failed: err=%v interesting=%v", err, result.interesting_test_cases)
}
