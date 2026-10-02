package hegel

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

Hegel_Error :: enum {
	None,
	Protocol_Error,
	Server_Error,
	Property_Failed,
	Missing_Libhegel,
	Native_Error,
}

Draw_Error :: enum {
	None,
	Stop_Test,
	Server_Error,
	Protocol_Error,
}

Case_Status :: enum {
	Valid,
	Invalid,
	Interesting,
	Aborted,
}

Body_Result :: struct {
	status: Case_Status,
	origin: string,
}

Run_Options :: struct {
	test_cases:       int,
	seed:             u64,
	derandomize:      bool,
	database:         string,
	database_key:     string,
	disable_database: bool,
}

Run_Result :: struct {
	passed:                 bool,
	interesting_test_cases: i64,
	executed_test_cases:    i64,
}

Test_Body :: proc(tc: ^Test_Case, user_data: rawptr) -> Body_Result

Test_Case :: struct {
	native:    ^Native_Run_State,
	native_tc: Libhegel_Test_Case,
	is_final:  bool,
	aborted:   bool,
	rejected:  bool,
}

LIBHEGEL_PATH_ENV :: "HEGEL_LIBHEGEL_PATH"
LIBHEGEL_VERSION :: "0.33.3"
LIBHEGEL_CACHE_PATH :: ".hegel/libhegel-" + LIBHEGEL_VERSION + "/libhegel-linux-amd64.so"
HEGEL_DEFAULT_DATABASE :: ".hegel/examples/" + LIBHEGEL_VERSION + "/"
HEGEL_TEST_CASE_MULTIPLIER_ENV :: "HEGEL_TEST_CASE_MULTIPLIER"
HEGEL_SEED_ENV :: "HEGEL_SEED"
HEGEL_MAX_TEST_CASE_MULTIPLIER :: 1_000
HEGEL_REQUIRED :: #config(HEGEL_REQUIRED, false)

Libhegel_Result :: enum i32 {
	OK               = 0,
	Stop_Test        = -1,
	Assume           = -2,
	Backend          = -3,
	Invalid_Handle   = -4,
	Invalid_Arg      = -5,
	Already_Complete = -6,
	Not_Complete     = -7,
	Internal         = -8,
	Concurrent_Use   = -9,
	Retry            = -10,
}

// C ABI values from the pinned libhegel version; these are not Case_Status ordinals.
Libhegel_Status :: enum i32 {
	Valid       = 0,
	Invalid     = 1,
	Overrun     = 2,
	Interesting = 3,
}

#assert(i32(Libhegel_Status.Valid) == 0)
#assert(i32(Libhegel_Status.Invalid) == 1)
#assert(i32(Libhegel_Status.Overrun) == 2)
#assert(i32(Libhegel_Status.Interesting) == 3)

Libhegel_Run_Status :: enum i32 {
	Passed                  = 0,
	Failed                  = 1,
	Error                   = 2,
	Failed_Nondeterministic = 3,
}

Libhegel_Context :: distinct rawptr
Libhegel_Settings :: distinct rawptr
Libhegel_Run :: distinct rawptr
Libhegel_Test_Case :: distinct rawptr
Libhegel_Run_Result :: distinct rawptr
Libhegel_Failure :: distinct rawptr
Libhegel_String_Generator :: distinct rawptr

Libhegel_Bytes_Result :: struct {
	data: ^u8,
	len:  uint,
}

Libhegel_String_Result :: struct {
	data: ^u8,
	len:  uint,
}

Libhegel_Date :: struct {
	year:  i32,
	month: u8,
	day:   u8,
}

Libhegel_Time :: struct {
	hour:        u8,
	minute:      u8,
	second:      u8,
	microsecond: u32,
}

Libhegel_Datetime :: struct {
	date: Libhegel_Date,
	time: Libhegel_Time,
}

#assert(size_of(Libhegel_Bytes_Result) == 16)
#assert(align_of(Libhegel_Bytes_Result) == 8)
#assert(offset_of(Libhegel_Bytes_Result, len) == 8)
#assert(size_of(Libhegel_String_Result) == 16)
#assert(align_of(Libhegel_String_Result) == 8)
#assert(offset_of(Libhegel_String_Result, len) == 8)
#assert(size_of(Libhegel_Date) == 8)
#assert(align_of(Libhegel_Date) == 4)
#assert(offset_of(Libhegel_Date, month) == 4)
#assert(offset_of(Libhegel_Date, day) == 5)
#assert(size_of(Libhegel_Time) == 8)
#assert(align_of(Libhegel_Time) == 4)
#assert(offset_of(Libhegel_Time, minute) == 1)
#assert(offset_of(Libhegel_Time, second) == 2)
#assert(offset_of(Libhegel_Time, microsecond) == 4)
#assert(size_of(Libhegel_Datetime) == 16)
#assert(align_of(Libhegel_Datetime) == 4)
#assert(offset_of(Libhegel_Datetime, time) == 8)

Libhegel_Output_Callback :: proc "c" (user_data: rawptr, line: cstring, len: uint)

Libhegel_Symbols :: struct {
	__handle:                                 dynlib.Library,
	hegel_context_new:                        proc "c" () -> Libhegel_Context,
	hegel_context_free:                       proc "c" (ctx: Libhegel_Context) -> Libhegel_Result,
	hegel_context_last_error:                 proc "c" (ctx: Libhegel_Context) -> cstring,
	hegel_settings_new:                       proc "c" (ctx: Libhegel_Context, out_settings: ^Libhegel_Settings) -> Libhegel_Result,
	hegel_settings_free:                      proc "c" (ctx: Libhegel_Context, settings: Libhegel_Settings) -> Libhegel_Result,
	hegel_settings_set_test_cases:            proc "c" (ctx: Libhegel_Context, settings: Libhegel_Settings, test_cases: u64) -> Libhegel_Result,
	hegel_settings_set_seed:                  proc "c" (ctx: Libhegel_Context, settings: Libhegel_Settings, seed: u64, has_seed: bool) -> Libhegel_Result,
	hegel_settings_set_derandomize:           proc "c" (ctx: Libhegel_Context, settings: Libhegel_Settings, derandomize: bool) -> Libhegel_Result,
	hegel_settings_set_database:              proc "c" (ctx: Libhegel_Context, settings: Libhegel_Settings, database: cstring) -> Libhegel_Result,
	hegel_settings_set_database_key:          proc "c" (ctx: Libhegel_Context, settings: Libhegel_Settings, key: cstring) -> Libhegel_Result,
	hegel_settings_set_suppress_health_check: proc "c" (ctx: Libhegel_Context, settings: Libhegel_Settings, checks: u32) -> Libhegel_Result,
	hegel_run_start:                          proc "c" (
		ctx: Libhegel_Context,
		settings: Libhegel_Settings,
		callback: Libhegel_Output_Callback,
		user_data: rawptr,
		out_run: ^Libhegel_Run,
	) -> Libhegel_Result,
	hegel_next_test_case:                     proc "c" (ctx: Libhegel_Context, run: Libhegel_Run, out_test_case: ^Libhegel_Test_Case) -> Libhegel_Result,
	hegel_run_result:                         proc "c" (ctx: Libhegel_Context, run: Libhegel_Run, out_result: ^Libhegel_Run_Result) -> Libhegel_Result,
	hegel_run_result_free:                    proc "c" (ctx: Libhegel_Context, result: Libhegel_Run_Result) -> Libhegel_Result,
	hegel_run_free:                           proc "c" (ctx: Libhegel_Context, run: Libhegel_Run) -> Libhegel_Result,
	hegel_test_case_from_blob:                proc "c" (
		ctx: Libhegel_Context,
		settings: Libhegel_Settings,
		blob: cstring,
		callback: Libhegel_Output_Callback,
		user_data: rawptr,
		out_test_case: ^Libhegel_Test_Case,
	) -> Libhegel_Result,
	hegel_test_case_free:                     proc "c" (ctx: Libhegel_Context, test_case: Libhegel_Test_Case) -> Libhegel_Result,
	hegel_generate_boolean:                   proc "c" (
		ctx: Libhegel_Context,
		test_case: Libhegel_Test_Case,
		probability: f64,
		forced: bool,
		has_forced: bool,
		out_value: ^bool,
	) -> Libhegel_Result,
	hegel_generate_integer:                   proc "c" (
		ctx: Libhegel_Context,
		test_case: Libhegel_Test_Case,
		min_value, max_value: i64,
		out_value: ^i64,
	) -> Libhegel_Result,
	hegel_generate_integer_big:               proc "c" (
		ctx: Libhegel_Context,
		test_case: Libhegel_Test_Case,
		min_value: ^u8,
		min_value_len: uint,
		max_value: ^u8,
		max_value_len: uint,
		out_value: ^u8,
		out_value_cap: uint,
		out_value_len: ^uint,
	) -> Libhegel_Result,
	hegel_generate_float:                     proc "c" (
		ctx: Libhegel_Context,
		test_case: Libhegel_Test_Case,
		width: u32,
		min_value, max_value: f64,
		allow_nan, allow_infinity, exclude_min, exclude_max: bool,
		smallest_nonzero_magnitude: f64,
		out_value: ^f64,
	) -> Libhegel_Result,
	hegel_generate_bytes:                     proc "c" (
		ctx: Libhegel_Context,
		test_case: Libhegel_Test_Case,
		min_size, max_size: u64,
		out_result: ^Libhegel_Bytes_Result,
	) -> Libhegel_Result,
	hegel_generate_bytes_result_free:         proc "c" (ctx: Libhegel_Context, result: ^Libhegel_Bytes_Result) -> Libhegel_Result,
	hegel_string_generator_text:              proc "c" (
		ctx: Libhegel_Context,
		min_size, max_size: u64,
		codec: cstring,
		min_codepoint, max_codepoint: u32,
		categories: ^cstring,
		categories_len: uint,
		exclude_categories: ^cstring,
		exclude_categories_len: uint,
		include_characters: ^u8,
		include_characters_len: uint,
		exclude_characters: ^u8,
		exclude_characters_len: uint,
		out_generator: ^Libhegel_String_Generator,
	) -> Libhegel_Result,
	hegel_string_generator_regex:             proc "c" (
		ctx: Libhegel_Context,
		pattern: cstring,
		fullmatch: bool,
		alphabet: Libhegel_String_Generator,
		out_generator: ^Libhegel_String_Generator,
	) -> Libhegel_Result,
	hegel_string_generator_email:             proc "c" (ctx: Libhegel_Context, out_generator: ^Libhegel_String_Generator) -> Libhegel_Result,
	hegel_string_generator_url:               proc "c" (ctx: Libhegel_Context, out_generator: ^Libhegel_String_Generator) -> Libhegel_Result,
	hegel_string_generator_domain:            proc "c" (ctx: Libhegel_Context, max_length: u64, out_generator: ^Libhegel_String_Generator) -> Libhegel_Result,
	hegel_string_generator_free:              proc "c" (ctx: Libhegel_Context, generator: Libhegel_String_Generator) -> Libhegel_Result,
	hegel_generate_string:                    proc "c" (
		ctx: Libhegel_Context,
		test_case: Libhegel_Test_Case,
		generator: Libhegel_String_Generator,
		out_result: ^Libhegel_String_Result,
	) -> Libhegel_Result,
	hegel_generate_string_result_free:        proc "c" (ctx: Libhegel_Context, result: ^Libhegel_String_Result) -> Libhegel_Result,
	hegel_generate_date:                      proc "c" (
		ctx: Libhegel_Context,
		test_case: Libhegel_Test_Case,
		min_value, max_value: Libhegel_Date,
		out_value: ^Libhegel_Date,
	) -> Libhegel_Result,
	hegel_generate_time:                      proc "c" (
		ctx: Libhegel_Context,
		test_case: Libhegel_Test_Case,
		min_value, max_value: Libhegel_Time,
		out_value: ^Libhegel_Time,
	) -> Libhegel_Result,
	hegel_generate_datetime:                  proc "c" (
		ctx: Libhegel_Context,
		test_case: Libhegel_Test_Case,
		min_value, max_value: Libhegel_Datetime,
		out_value: ^Libhegel_Datetime,
	) -> Libhegel_Result,
	hegel_generate_ipv4:                      proc "c" (ctx: Libhegel_Context, test_case: Libhegel_Test_Case, out_bytes: ^u8) -> Libhegel_Result,
	hegel_generate_ipv6:                      proc "c" (ctx: Libhegel_Context, test_case: Libhegel_Test_Case, out_bytes: ^u8) -> Libhegel_Result,
	hegel_mark_complete:                      proc "c" (ctx: Libhegel_Context, test_case: Libhegel_Test_Case, status: u32, origin: cstring) -> Libhegel_Result,
	hegel_run_result_status:                  proc "c" (
		ctx: Libhegel_Context,
		result: Libhegel_Run_Result,
		out_status: ^Libhegel_Run_Status,
	) -> Libhegel_Result,
	hegel_run_result_error:                   proc "c" (ctx: Libhegel_Context, result: Libhegel_Run_Result, out_error: ^cstring) -> Libhegel_Result,
	hegel_run_result_failure_count:           proc "c" (ctx: Libhegel_Context, result: Libhegel_Run_Result, out_count: ^uint) -> Libhegel_Result,
	hegel_run_result_failure:                 proc "c" (
		ctx: Libhegel_Context,
		result: Libhegel_Run_Result,
		index: uint,
		out_failure: ^Libhegel_Failure,
	) -> Libhegel_Result,
	hegel_failure_free:                       proc "c" (ctx: Libhegel_Context, failure: Libhegel_Failure) -> Libhegel_Result,
	hegel_failure_origin:                     proc "c" (ctx: Libhegel_Context, failure: Libhegel_Failure, out_origin: ^cstring) -> Libhegel_Result,
	hegel_failure_reproduction_blob:          proc "c" (ctx: Libhegel_Context, failure: Libhegel_Failure, out_blob: ^cstring) -> Libhegel_Result,
	hegel_version:                            proc "c" (ctx: Libhegel_Context, out_version: ^cstring) -> Libhegel_Result,
}

Native_Run_State :: struct {
	ctx:      Libhegel_Context,
	settings: Libhegel_Settings,
	run:      Libhegel_Run,
}

@(private)
libhegel_symbols: Libhegel_Symbols
@(private)
libhegel_load_mutex: sync.Mutex
@(private)
libhegel_run_mutex: sync.Mutex
@(private)
libhegel_load_attempted: bool
@(private)
libhegel_loaded: bool

// --- Generator abstraction ---
//
// Basic_Gen(T) wraps a server-side schema.  Construct with basic_*().
// Composite_Gen(T) wraps imperative code that can propagate draw errors.
// Construct with composite().
// Both are first-class values; use gen_draw() to draw from them.
//
// Example:
//   int_gen  := basic_i64(0, 100)
//   text_gen := basic_text(0, 50)
//   pair_gen := composite([2]i64, proc(tc: ^Test_Case) -> ([2]i64, Draw_Error) {
//       x, err := gen_draw(tc, int_gen)
//       if err != nil { return {}, err }
//       y, err := gen_draw(tc, basic_i64(0, 100))
//       if err != nil { return {}, err }
//       return [2]i64{x, y}, nil
//   })
//   age := gen_draw(tc, int_gen)

// Parameter data for basic generators, stored on the heap.
Basic_I64_Params :: struct {
	min_val: i64,
	max_val: i64,
}
Basic_U32_Params :: struct {
	min_val: u32,
	max_val: u32,
}
Basic_U64_Params :: struct {
	min_val: u64,
	max_val: u64,
}
Basic_F64_Params :: struct {
	min_val: f64,
	max_val: f64,
}
Basic_Text_Params :: struct {
	min_size: int,
	max_size: int,
}
Basic_Bytes_Params :: struct {
	min_size: int,
	max_size: int,
}

// --- Gen ---
// A tagged union of all generator types.  Both variants are parameterized
// on the same $T, so the switch in gen_draw dispatches safely.
//
// Drawn-value ownership follows the source generator, not T:
// - Text, regex, email, URL, and domain draws allocate with context.allocator.
// - Date, time, datetime, and IP draws use context.temp_allocator.
// - just/sampled_from values are borrowed; composite draws define their own ownership.
// gen_destroy frees generator configuration, not drawn values. Transforms must
// release owned inputs they consume. Combinators cannot generically destroy T;
// a later failed draw or rejected filter can discard earlier owned values.
// Use a property-scoped arena for those draws, and do not retain its values
// beyond that property's invocation.
Gen :: union($T: typeid) {
	Basic_Gen(T),
	Composite_Gen(T),
	Just_Gen(T),
	Sampled_Gen(T),
	OneOf_Gen(T),
	Filtered_Gen(T),
}

GEN_PARAMS_SIZE :: 32

// Basic_Gen wraps a schema-backed draw procedure.
// Parameters are stored inline in params[] to avoid heap allocation.
Basic_Gen :: struct($T: typeid) {
	draw:   proc(data: rawptr, tc: ^Test_Case) -> (T, Draw_Error),
	params: [GEN_PARAMS_SIZE]byte,
}

// Composite_Gen wraps an imperative generator function.
Composite_Gen :: struct($T: typeid) {
	fn: proc(tc: ^Test_Case) -> (T, Draw_Error),
}

// Just_Gen always produces the same value.
Just_Gen :: struct($T: typeid) {
	value: T,
}

// Sampled_Gen picks uniformly from a fixed set of values.
Sampled_Gen :: struct($T: typeid) {
	values: []T,
}

// OneOf_Gen chooses a sub-generator and draws from it.
OneOf_Gen :: struct($T: typeid) {
	generators: []Gen(T),
}

// Filtered_Gen retains values matching a predicate.
// source_ptr points to a heap-allocated Gen(T).
Filtered_Gen :: struct($T: typeid) {
	source_ptr:   rawptr,
	pred:         proc(_: T) -> bool,
	max_attempts: int,
}

// --- Vec_Gen (standalone, not in Gen union) ---
// Vec_Gen(T) is parameterized on the ELEMENT type. gen_draw_vec produces []T.
Vec_Gen :: struct($T: typeid) {
	elements: Gen(T),
	min_size: int,
	max_size: int,
}

// gen_draw_vec draws a slice of elements from a Vec_Gen.
// The element type T is inferred from Vec_Gen(T); the return is []T.
gen_draw_vec :: proc(tc: ^Test_Case, gen: Vec_Gen($T)) -> ([]T, Draw_Error) {
	len_val, err := draw_i64(tc, i64(gen.min_size), i64(gen.max_size))
	if err != nil {return nil, err}
	result := make([dynamic]T, 0, int(len_val))
	for _ in 0 ..< int(len_val) {
		val, draw_err := gen_draw(tc, gen.elements)
		if draw_err != nil {
			delete(result)
			return nil, draw_err
		}
		append(&result, val)
	}
	return result[:], nil
}

// --- Mapped (standalone, not in Gen union) ---
// Mapped(U, T) transforms Gen(U) into a Gen(T) via fn: U -> T.
Mapped :: struct($U: typeid, $T: typeid) {
	source: Gen(U),
	fn:     proc(_: U) -> T,
}

// gen_draw_mapped draws from source and applies the transform.
gen_draw_mapped :: proc(tc: ^Test_Case, gen: Mapped($U, $T)) -> (T, Draw_Error) {
	val, err := gen_draw(tc, gen.source)
	if err != nil {return {}, err}
	return gen.fn(val), nil
}

// --- FlatMapped (standalone, not in Gen union) ---
// FlatMapped(U, T) chains generators: fn(U) -> Gen(T).
FlatMapped :: struct($U: typeid, $T: typeid) {
	source: Gen(U),
	fn:     proc(_: U) -> Gen(T),
}

// gen_draw_flatmapped draws from source, calls fn to get the next generator,
// then draws from that generator.
gen_draw_flatmapped :: proc(tc: ^Test_Case, gen: FlatMapped($U, $T)) -> (T, Draw_Error) {
	val, err := gen_draw(tc, gen.source)
	if err != nil {return {}, err}
	next := gen.fn(val)
	return gen_draw(tc, next)
}

// --- Text_Generator (builder API for rich text) ---
// Use text() to create, chain builder methods, call text_gen_draw(tc, gen).
//
// Example:
//   s, _ := text_gen_draw(tc, text()
//       .min_size(10).max_size(100)
//       .alphabet("ACGT")
//   )

Text_Generator :: struct {
	min_size: Maybe(int),
	max_size: Maybe(int),
	alphabet: Maybe(string),
	codec:    Maybe(string),
}

text :: proc() -> Text_Generator {return {}}

text_gen_min_size :: proc(g: Text_Generator, n: int) -> Text_Generator {
	r := g
	r.min_size = n
	return r
}

text_gen_max_size :: proc(g: Text_Generator, n: int) -> Text_Generator {
	r := g
	r.max_size = n
	return r
}

text_gen_alphabet :: proc(g: Text_Generator, chars: string) -> Text_Generator {
	r := g
	r.alphabet = chars
	return r
}

text_gen_codec :: proc(g: Text_Generator, name: string) -> Text_Generator {
	r := g
	r.codec = name
	return r
}

// text_gen_draw builds a native text generator and draws one value from it.
text_gen_draw :: proc(tc: ^Test_Case, gen: Text_Generator) -> (string, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return "", .Stop_Test
	}
	min_size := 0
	max_size := 0
	if gen.min_size != nil do min_size = gen.min_size.?
	if gen.max_size != nil do max_size = gen.max_size.?
	if min_size < 0 || max_size < 0 || min_size > max_size {
		return "", .Protocol_Error
	}

	codec: cstring
	if gen.codec != nil {
		codec = strings.clone_to_cstring(gen.codec.?, context.temp_allocator)
		defer delete(codec, context.temp_allocator)
	}
	include: []byte
	categories: ^cstring
	if gen.alphabet != nil {
		include = transmute([]byte)gen.alphabet.?
		// A non-nil empty category list starts with an empty alphabet; the
		// explicitly included characters then become the complete alphabet.
		empty_categories: [1]cstring
		categories = &empty_categories[0]
		codec = nil
	}
	generator: Libhegel_String_Generator
	result := libhegel_symbols.hegel_string_generator_text(
		tc.native.ctx,
		u64(min_size),
		u64(max_size),
		codec,
		0,
		max(u32),
		categories,
		0,
		nil,
		0,
		raw_data(include),
		uint(len(include)),
		nil,
		0,
		&generator,
	)
	if result != .OK {
		return "", native_draw_error(tc, "string_generator_text", result)
	}
	defer libhegel_symbols.hegel_string_generator_free(tc.native.ctx, generator)
	return draw_native_string(tc, generator)
}

// --- from_regex ---
// from_regex generates strings matching a regular expression.
// Params (pattern + fullmatch) fit in Basic_Gen's 32-byte inline buffer.

Regex_Params :: struct {
	pattern:   string,
	fullmatch: bool,
}

draw_regex :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	p := (^Regex_Params)(data)
	return draw_regex_impl(tc, p.pattern, p.fullmatch)
}

draw_regex_impl :: proc(tc: ^Test_Case, pattern: string, fullmatch: bool) -> (string, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return "", .Stop_Test
	}

	pattern_cstr := strings.clone_to_cstring(pattern, context.temp_allocator)
	defer delete(pattern_cstr, context.temp_allocator)
	generator: Libhegel_String_Generator
	result := libhegel_symbols.hegel_string_generator_regex(tc.native.ctx, pattern_cstr, fullmatch, nil, &generator)
	if result != .OK {
		return "", native_draw_error(tc, "string_generator_regex", result)
	}
	defer libhegel_symbols.hegel_string_generator_free(tc.native.ctx, generator)
	return draw_native_string(tc, generator)
}

from_regex :: proc(pattern: string, fullmatch: bool) -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_regex
	p := (^Regex_Params)(&g.params[0])
	p^ = {
		pattern   = pattern,
		fullmatch = fullmatch,
	}
	result: Gen(string) = g
	return result
}

// --- Opt (standalone) ---
// Opt(T) either produces nil (50% chance) or a value from source.
Opt :: struct($T: typeid) {
	source: Gen(T),
}

// gen_draw_opt draws a bool to decide presence, then optionally draws from source.
gen_draw_opt :: proc(tc: ^Test_Case, gen: Opt($T)) -> (Maybe(T), Draw_Error) {
	present, err := draw_bool(tc)
	if err != nil {return nil, err}
	if !present {return nil, nil}
	val, err := gen_draw(tc, gen.source)
	if err != nil {return nil, err}
	return val, nil
}

// --- Pair (standalone) ---
// Pair(T, U) draws two values from two generators and returns them.
Pair :: struct($T: typeid, $U: typeid) {
	first:  Gen(T),
	second: Gen(U),
}

// gen_draw_pair draws from first and second, returning both values.
gen_draw_pair :: proc(tc: ^Test_Case, gen: Pair($T, $U)) -> (T, U, Draw_Error) {
	a, e1 := gen_draw(tc, gen.first)
	if e1 != nil {return {}, {}, e1}
	b, e2 := gen_draw(tc, gen.second)
	if e2 != nil {return {}, {}, e2}
	return a, b, nil
}

// --- tuples (variadic) ---
// tuples draws from each generator in order and returns values as []any.
// Uses ..any so generators of different types can be mixed.
// --- Triple (standalone) ---
// Triple(T, U, V) draws three values from three generators.
Triple :: struct($T: typeid, $U: typeid, $V: typeid) {
	first:  Gen(T),
	second: Gen(U),
	third:  Gen(V),
}

gen_draw_triple :: proc(tc: ^Test_Case, gen: Triple($T, $U, $V)) -> (T, U, V, Draw_Error) {
	a, e1 := gen_draw(tc, gen.first)
	if e1 != nil {return {}, {}, {}, e1}
	b, e2 := gen_draw(tc, gen.second)
	if e2 != nil {return {}, {}, {}, e2}
	c, e3 := gen_draw(tc, gen.third)
	if e3 != nil {return {}, {}, {}, e3}
	return a, b, c, nil
}

// gen_destroy frees heap allocations made by filter().
// Basic_Gen stores params inline so no heap allocation needs freeing.
gen_destroy :: proc(gen: Gen($T)) {
	#partial switch g in gen {
	case Filtered_Gen(T):
		if g.source_ptr != nil {
			free(g.source_ptr)
		}
	case:
	}
}


// --- Draw functions for basic generators ---
draw_basic_i64 :: proc(data: rawptr, tc: ^Test_Case) -> (i64, Draw_Error) {
	p := (^Basic_I64_Params)(data)
	return draw_i64(tc, p.min_val, p.max_val)
}

draw_basic_u32 :: proc(data: rawptr, tc: ^Test_Case) -> (u32, Draw_Error) {
	p := (^Basic_U32_Params)(data)
	return draw_u32(tc, p.min_val, p.max_val)
}

draw_basic_u64 :: proc(data: rawptr, tc: ^Test_Case) -> (u64, Draw_Error) {
	p := (^Basic_U64_Params)(data)
	return draw_u64(tc, p.min_val, p.max_val)
}

draw_basic_bool :: proc(data: rawptr, tc: ^Test_Case) -> (bool, Draw_Error) {
	return draw_bool(tc)
}

draw_basic_f64 :: proc(data: rawptr, tc: ^Test_Case) -> (f64, Draw_Error) {
	p := (^Basic_F64_Params)(data)
	return draw_f64(tc, p.min_val, p.max_val)
}

draw_basic_text :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	p := (^Basic_Text_Params)(data)
	return draw_text(tc, p.min_size, p.max_size)
}

draw_basic_bytes :: proc(data: rawptr, tc: ^Test_Case) -> ([]byte, Draw_Error) {
	p := (^Basic_Bytes_Params)(data)
	return draw_bytes(tc, p.min_size, p.max_size)
}

// --- Format generators ---
draw_format :: proc(tc: ^Test_Case, type_name: string) -> (string, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return "", .Stop_Test
	}
	generator: Libhegel_String_Generator
	result: Libhegel_Result
	switch type_name {
	case "email":
		result = libhegel_symbols.hegel_string_generator_email(tc.native.ctx, &generator)
	case "url":
		result = libhegel_symbols.hegel_string_generator_url(tc.native.ctx, &generator)
	case "domain":
		result = libhegel_symbols.hegel_string_generator_domain(tc.native.ctx, 255, &generator)
	case "date":
		return draw_native_date(tc)
	case "time":
		return draw_native_time(tc)
	case "datetime":
		return draw_native_datetime(tc)
	case "ip_address":
		v4, err := draw_bool(tc)
		if err != nil do return "", err
		if v4 do return draw_native_ip(tc, 4)
		return draw_native_ip(tc, 6)
	case:
		return "", .Protocol_Error
	}
	if result != .OK {
		return "", native_draw_error(tc, "string_generator_format", result)
	}
	defer libhegel_symbols.hegel_string_generator_free(tc.native.ctx, generator)
	return draw_native_string(tc, generator)
}

draw_format_version :: proc(tc: ^Test_Case, type_name: string, version: i64) -> (string, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return "", .Stop_Test
	}
	if type_name != "ip_address" {
		return "", .Protocol_Error
	}
	return draw_native_ip(tc, version)
}

// Format draw procs — each wraps draw_format with the correct type name.
draw_format_emails :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	return draw_format(tc, "email")
}

draw_format_urls :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	return draw_format(tc, "url")
}

draw_format_domains :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	return draw_format(tc, "domain")
}

draw_format_dates :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	return draw_format(tc, "date")
}

draw_format_times :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	return draw_format(tc, "time")
}

draw_format_datetimes :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	return draw_format(tc, "datetime")
}

draw_format_ip_v4 :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	return draw_format_version(tc, "ip_address", 4)
}

draw_format_ip_v6 :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	return draw_format_version(tc, "ip_address", 6)
}

// Format generator constructors — each creates a Basic_Gen(string) with the
// corresponding draw proc. The params buffer is unused (nil data pointer).

emails :: proc() -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_format_emails
	result: Gen(string) = g
	return result
}

urls :: proc() -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_format_urls
	result: Gen(string) = g
	return result
}

domains :: proc() -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_format_domains
	result: Gen(string) = g
	return result
}

dates :: proc() -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_format_dates
	result: Gen(string) = g
	return result
}

times :: proc() -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_format_times
	result: Gen(string) = g
	return result
}

datetimes :: proc() -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_format_datetimes
	result: Gen(string) = g
	return result
}

draw_format_ip :: proc(data: rawptr, tc: ^Test_Case) -> (string, Draw_Error) {
	if tc != nil && tc.native != nil && tc.native_tc != nil {
		v4, err := draw_bool(tc)
		if err != nil {
			return "", err
		}
		if v4 {
			return draw_format_version(tc, "ip_address", 4)
		}
		return draw_format_version(tc, "ip_address", 6)
	}
	return draw_format(tc, "ip_address")
}

ip_addresses :: proc() -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_format_ip
	result: Gen(string) = g
	return result
}

ip_addresses_v4 :: proc() -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_format_ip_v4
	result: Gen(string) = g
	return result
}

ip_addresses_v6 :: proc() -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_format_ip_v6
	result: Gen(string) = g
	return result
}

// --- Basic generator constructors ---
// Parameters are written into the inline params buffer, then the draw
// proc receives a pointer to that buffer via gen_draw().

basic_i64 :: proc(min_val, max_val: i64) -> Gen(i64) {
	g: Basic_Gen(i64)
	g.draw = draw_basic_i64
	p := (^Basic_I64_Params)(&g.params[0])
	p^ = {
		min_val = min_val,
		max_val = max_val,
	}
	result: Gen(i64) = g
	return result
}

basic_u32 :: proc(min_val, max_val: u32) -> Gen(u32) {
	g: Basic_Gen(u32)
	g.draw = draw_basic_u32
	p := (^Basic_U32_Params)(&g.params[0])
	p^ = {
		min_val = min_val,
		max_val = max_val,
	}
	result: Gen(u32) = g
	return result
}

basic_u64 :: proc(min_val, max_val: u64) -> Gen(u64) {
	g: Basic_Gen(u64)
	g.draw = draw_basic_u64
	p := (^Basic_U64_Params)(&g.params[0])
	p^ = {
		min_val = min_val,
		max_val = max_val,
	}
	result: Gen(u64) = g
	return result
}

basic_bool :: proc() -> Gen(bool) {
	g: Basic_Gen(bool)
	g.draw = draw_basic_bool
	result: Gen(bool) = g
	return result
}

basic_bytes :: proc(min_size, max_size: int) -> Gen([]byte) {
	g: Basic_Gen([]byte)
	g.draw = draw_basic_bytes
	p := (^Basic_Bytes_Params)(&g.params[0])
	p^ = {
		min_size = min_size,
		max_size = max_size,
	}
	result: Gen([]byte) = g
	return result
}

basic_f64 :: proc(min_val, max_val: f64) -> Gen(f64) {
	g: Basic_Gen(f64)
	g.draw = draw_basic_f64
	p := (^Basic_F64_Params)(&g.params[0])
	p^ = {
		min_val = min_val,
		max_val = max_val,
	}
	result: Gen(f64) = g
	return result
}

basic_text :: proc(min_size, max_size: int) -> Gen(string) {
	g: Basic_Gen(string)
	g.draw = draw_basic_text
	p := (^Basic_Text_Params)(&g.params[0])
	p^ = {
		min_size = min_size,
		max_size = max_size,
	}
	result: Gen(string) = g
	return result
}

// --- composite ---
// composite builds a Gen from imperative code. The function receives a
// Test_Case, draws from other generators via gen_draw(), and must return any
// draw error instead of ignoring it.
//
// Example:
//   pair_gen := composite([2]i64, proc(tc: ^Test_Case) -> ([2]i64, Draw_Error) {
//       x, err := gen_draw(tc, basic_i64(0, 100))
//       if err != nil { return {}, err }
//       y, err := gen_draw(tc, basic_i64(0, 100))
//       if err != nil { return {}, err }
//       return [2]i64{x, y}, nil
//   })
composite :: proc($T: typeid, fn: proc(tc: ^Test_Case) -> (T, Draw_Error)) -> Gen(T) {
	result: Gen(T)
	result = Composite_Gen(T) {
		fn = fn,
	}
	return result
}

// --- just ---
// just returns a generator that always produces value.
just :: proc($T: typeid, value: T) -> Gen(T) {
	result: Gen(T)
	result = Just_Gen(T) {
		value = value,
	}
	return result
}

// --- sampled_from ---
// sampled_from picks uniformly from values.
sampled_from :: proc($T: typeid, values: []T) -> Gen(T) {
	result: Gen(T)
	result = Sampled_Gen(T) {
		values = values,
	}
	return result
}

// --- one_of ---
// one_of chooses a sub-generator at random and draws from it.
one_of :: proc($T: typeid, generators: []Gen(T)) -> Gen(T) {
	result: Gen(T)
	result = OneOf_Gen(T) {
		generators = generators,
	}
	return result
}

// --- filter ---
// filter retains only values from source that satisfy pred.
filter :: proc($T: typeid, source: Gen(T), pred: proc(_: T) -> bool) -> Gen(T) {
	return filter_with_attempts(T, source, pred, 100)
}

// filter_with_attempts retries up to max_attempts before rejecting the test.
filter_with_attempts :: proc($T: typeid, source: Gen(T), pred: proc(_: T) -> bool, max_attempts: int) -> Gen(T) {
	sp := new(Gen(T))
	sp^ = source
	g: Filtered_Gen(T)
	g.source_ptr = sp
	g.pred = pred
	g.max_attempts = max_attempts
	result: Gen(T) = g
	return result
}

// --- vectors ---
// vectors produces a Vec_Gen that draws from elements.
// Use gen_draw_vec() to draw from it.
vectors :: proc($T: typeid, elements: Gen(T), min_size, max_size: int) -> Vec_Gen(T) {
	return Vec_Gen(T){elements = elements, min_size = min_size, max_size = max_size}
}

// --- gen_draw ---
// gen_draw produces a value from any generator.
gen_draw :: proc(tc: ^Test_Case, gen: Gen($T)) -> (T, Draw_Error) {
	#partial switch g in gen {
	case Basic_Gen(T):
		bg := g
		return bg.draw(&bg.params[0], tc)
	case Composite_Gen(T):
		return g.fn(tc)
	case Just_Gen(T):
		return g.value, nil
	case Sampled_Gen(T):
		if len(g.values) == 0 {
			return {}, .Protocol_Error
		}
		idx, err := draw_i64(tc, 0, i64(len(g.values) - 1))
		if err != nil {return {}, err}
		return g.values[idx], nil
	case OneOf_Gen(T):
		if len(g.generators) == 0 {
			return {}, .Protocol_Error
		}
		idx, err := draw_i64(tc, 0, i64(len(g.generators) - 1))
		if err != nil {return {}, err}
		return gen_draw(tc, g.generators[idx])
	case Filtered_Gen(T):
		sp := (^Gen(T))(g.source_ptr)
		max_attempts := g.max_attempts
		if max_attempts <= 0 do max_attempts = 1
		for _ in 0 ..< max_attempts {
			val, err := gen_draw(tc, sp^)
			if err != nil {return {}, err}
			if g.pred(val) {return val, nil}
		}
		tc.rejected = true
		return {}, .Stop_Test
	}
	return {}, .Protocol_Error
}

can_run :: proc() -> bool {
	if libhegel_load() {
		return true
	}
	if HEGEL_REQUIRED {
		panic("libhegel is required but could not be loaded; run test/fetch_libhegel.sh or set HEGEL_LIBHEGEL_PATH")
	}
	return false
}

libhegel_path :: proc() -> string {
	path, found := os.lookup_env(LIBHEGEL_PATH_ENV, context.temp_allocator)
	if found && path != "" {
		return path
	}
	if regular_file(LIBHEGEL_CACHE_PATH) {
		return LIBHEGEL_CACHE_PATH
	}
	return ""
}

regular_file :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return false
	}
	return info.type == .Regular
}

libhegel_version_compatible :: proc(result: Libhegel_Result, version: string) -> bool {
	return result == .OK && version == LIBHEGEL_VERSION
}

effective_database :: proc(options: Run_Options) -> string {
	if options.disable_database {
		return ""
	}
	if options.database != "" {
		return options.database
	}
	return HEGEL_DEFAULT_DATABASE
}

libhegel_load :: proc() -> bool {
	sync.mutex_lock(&libhegel_load_mutex)
	defer sync.mutex_unlock(&libhegel_load_mutex)

	if libhegel_load_attempted {
		return libhegel_loaded
	}
	libhegel_load_attempted = true

	path := libhegel_path()
	if path == "" {
		if HEGEL_REQUIRED {
			log.errorf("libhegel load failed: no library found; checked %s and %s; run test/fetch_libhegel.sh", LIBHEGEL_PATH_ENV, LIBHEGEL_CACHE_PATH)
		}
		return false
	}

	symbol_count, ok := dynlib.initialize_symbols(&libhegel_symbols, path)
	if !ok {
		if HEGEL_REQUIRED {
			log.errorf("libhegel load failed: path=%s error=%s", path, dynlib.last_error())
		}
		return false
	}

	libhegel_loaded =
		libhegel_symbols.hegel_context_new != nil &&
		libhegel_symbols.hegel_context_free != nil &&
		libhegel_symbols.hegel_context_last_error != nil &&
		libhegel_symbols.hegel_settings_new != nil &&
		libhegel_symbols.hegel_settings_free != nil &&
		libhegel_symbols.hegel_settings_set_test_cases != nil &&
		libhegel_symbols.hegel_settings_set_seed != nil &&
		libhegel_symbols.hegel_settings_set_derandomize != nil &&
		libhegel_symbols.hegel_settings_set_database != nil &&
		libhegel_symbols.hegel_settings_set_database_key != nil &&
		libhegel_symbols.hegel_run_start != nil &&
		libhegel_symbols.hegel_next_test_case != nil &&
		libhegel_symbols.hegel_run_result != nil &&
		libhegel_symbols.hegel_run_result_free != nil &&
		libhegel_symbols.hegel_run_free != nil &&
		libhegel_symbols.hegel_test_case_from_blob != nil &&
		libhegel_symbols.hegel_test_case_free != nil &&
		libhegel_symbols.hegel_generate_boolean != nil &&
		libhegel_symbols.hegel_generate_integer != nil &&
		libhegel_symbols.hegel_generate_integer_big != nil &&
		libhegel_symbols.hegel_generate_float != nil &&
		libhegel_symbols.hegel_generate_bytes != nil &&
		libhegel_symbols.hegel_generate_bytes_result_free != nil &&
		libhegel_symbols.hegel_string_generator_text != nil &&
		libhegel_symbols.hegel_string_generator_regex != nil &&
		libhegel_symbols.hegel_string_generator_email != nil &&
		libhegel_symbols.hegel_string_generator_url != nil &&
		libhegel_symbols.hegel_string_generator_domain != nil &&
		libhegel_symbols.hegel_string_generator_free != nil &&
		libhegel_symbols.hegel_generate_string != nil &&
		libhegel_symbols.hegel_generate_string_result_free != nil &&
		libhegel_symbols.hegel_generate_date != nil &&
		libhegel_symbols.hegel_generate_time != nil &&
		libhegel_symbols.hegel_generate_datetime != nil &&
		libhegel_symbols.hegel_generate_ipv4 != nil &&
		libhegel_symbols.hegel_generate_ipv6 != nil &&
		libhegel_symbols.hegel_mark_complete != nil &&
		libhegel_symbols.hegel_run_result_status != nil &&
		libhegel_symbols.hegel_run_result_error != nil &&
		libhegel_symbols.hegel_run_result_failure_count != nil &&
		libhegel_symbols.hegel_run_result_failure != nil &&
		libhegel_symbols.hegel_failure_free != nil &&
		libhegel_symbols.hegel_failure_origin != nil &&
		libhegel_symbols.hegel_failure_reproduction_blob != nil &&
		libhegel_symbols.hegel_version != nil
	if libhegel_loaded {
		ctx := libhegel_symbols.hegel_context_new()
		version: cstring
		version_result := libhegel_symbols.hegel_version(ctx, &version)
		libhegel_symbols.hegel_context_free(ctx)
		actual_version := "<unavailable>"
		if version != nil do actual_version = string(version)
		if !libhegel_version_compatible(version_result, actual_version) {
			if HEGEL_REQUIRED {
				log.errorf("libhegel version mismatch: path=%s expected=%s actual=%s", path, LIBHEGEL_VERSION, actual_version)
			}
			libhegel_loaded = false
		}
	}
	if !libhegel_loaded && HEGEL_REQUIRED {
		log.errorf("libhegel symbol initialization failed: path=%s loaded_symbols=%d error=%s", path, symbol_count, dynlib.last_error())
	}
	return libhegel_loaded
}

libhegel_error_log :: proc(ctx: Libhegel_Context, op: string, result: Libhegel_Result) {
	if ctx == nil || libhegel_symbols.hegel_context_last_error == nil {
		log.errorf("hegel native %s failed: result=%v", op, result)
		return
	}
	message := string(libhegel_symbols.hegel_context_last_error(ctx))
	if message == "" {
		log.errorf("hegel native %s failed: result=%v", op, result)
	} else {
		log.errorf("hegel native %s failed: result=%v message=%s", op, result, message)
	}
}

libhegel_ok :: proc(ctx: Libhegel_Context, op: string, result: Libhegel_Result) -> bool {
	if result == .OK {
		return true
	}
	libhegel_error_log(ctx, op, result)
	return false
}

valid :: proc() -> Body_Result {
	return {status = .Valid}
}

invalid :: proc() -> Body_Result {
	return {status = .Invalid}
}

interesting :: proc(origin: string) -> Body_Result {
	return {status = .Interesting, origin = origin}
}

abort :: proc() -> Body_Result {
	return {status = .Aborted}
}

diagnostics_enabled :: proc() -> bool {
	value, found := os.lookup_env("HEGEL_DIAGNOSTICS", context.temp_allocator)
	if !found {
		return false
	}
	return value != "" && value != "0" && value != "false" && value != "FALSE"
}

effective_test_case_budget :: proc(requested: int, multiplier_value: string, multiplier_found: bool) -> (test_cases, multiplier: int, ok: bool) {
	test_cases = requested
	if test_cases <= 0 {
		test_cases = 100
	}
	multiplier = 1
	if multiplier_found {
		parsed, parse_ok := strconv.parse_int(strings.trim_space(multiplier_value))
		if !parse_ok || parsed < 1 || parsed > HEGEL_MAX_TEST_CASE_MULTIPLIER {
			return 0, 0, false
		}
		multiplier = parsed
	}
	if test_cases > max(int) / multiplier {
		return 0, 0, false
	}
	return test_cases * multiplier, multiplier, true
}

effective_seed :: proc(requested: u64, seed_value: string, seed_found: bool) -> (u64, bool) {
	if requested != 0 {
		return requested, true
	}
	if !seed_found {
		return 0, true
	}
	seed, ok := strconv.parse_u64(strings.trim_space(seed_value))
	if !ok || seed == 0 {
		return 0, false
	}
	return seed, true
}

diagnostics_elapsed_seconds :: proc(started_at: time.Time) -> f64 {
	return time.duration_seconds(time.since(started_at))
}

diagnostics_finish :: proc(loc: runtime.Source_Code_Location, started_at: time.Time, result: Run_Result, err: Hegel_Error) {
	fmt.eprintf(
		"[hegel diag] finish pid=%d caller=%s elapsed=%.3fs executed=%d interesting=%d passed=%v err=%v\n",
		os.get_pid(),
		loc.procedure,
		diagnostics_elapsed_seconds(started_at),
		result.executed_test_cases,
		result.interesting_test_cases,
		result.passed,
		err,
	)
}

run :: proc(body: Test_Body, user_data: rawptr = nil, options := Run_Options{}, loc := #caller_location) -> (Run_Result, Hegel_Error) {
	if body == nil {
		return {}, .Protocol_Error
	}
	if !libhegel_load() {
		return {}, .Missing_Libhegel
	}
	// Odin executes tests concurrently, but simultaneous native Hegel runs can
	// starve input generation and corrupt libhegel process-global state. Keep
	// each run atomic while allowing a property body to create worker threads.
	sync.mutex_lock(&libhegel_run_mutex)
	defer sync.mutex_unlock(&libhegel_run_mutex)
	multiplier_value, multiplier_found := os.lookup_env(HEGEL_TEST_CASE_MULTIPLIER_ENV, context.temp_allocator)
	test_cases, multiplier, budget_ok := effective_test_case_budget(options.test_cases, multiplier_value, multiplier_found)
	if !budget_ok {
		log.errorf(
			"invalid %s=%q: expected an integer in 1..=%d without test-case overflow",
			HEGEL_TEST_CASE_MULTIPLIER_ENV,
			multiplier_value,
			HEGEL_MAX_TEST_CASE_MULTIPLIER,
		)
		return {}, .Protocol_Error
	}
	seed_value, seed_found := os.lookup_env(HEGEL_SEED_ENV, context.temp_allocator)
	seed, seed_ok := effective_seed(options.seed, seed_value, seed_found)
	if !seed_ok {
		log.errorf("invalid %s=%q: expected a non-zero unsigned integer", HEGEL_SEED_ENV, seed_value)
		return {}, .Protocol_Error
	}
	database := effective_database(options)
	database_key := options.database_key
	if database != "" && database_key == "" {
		database_key = fmt.tprintf("%s:%s", filepath.base(loc.file_path), loc.procedure)
	}
	diagnostics := diagnostics_enabled()
	started_at := time.now()
	if diagnostics {
		fmt.eprintf(
			"[hegel diag] start pid=%d caller=%s %s:%d requested_test_cases=%d multiplier=%d test_cases=%d seed=%d derandomize=%v database=%q database_key=%q\n",
			os.get_pid(),
			loc.procedure,
			loc.file_path,
			loc.line,
			options.test_cases,
			multiplier,
			test_cases,
			seed,
			options.derandomize,
			database,
			database_key,
		)
	}

	ctx := libhegel_symbols.hegel_context_new()
	if ctx == nil {
		return {}, .Native_Error
	}
	defer libhegel_symbols.hegel_context_free(ctx)

	settings: Libhegel_Settings
	if !libhegel_ok(ctx, "settings_new", libhegel_symbols.hegel_settings_new(ctx, &settings)) {
		if diagnostics {
			diagnostics_finish(loc, started_at, {}, Hegel_Error.Native_Error)
		}
		return {}, .Native_Error
	}
	defer libhegel_symbols.hegel_settings_free(ctx, settings)

	if !libhegel_ok(ctx, "settings_set_test_cases", libhegel_symbols.hegel_settings_set_test_cases(ctx, settings, u64(test_cases))) {
		if diagnostics {
			diagnostics_finish(loc, started_at, {}, Hegel_Error.Native_Error)
		}
		return {}, .Native_Error
	}
	if libhegel_symbols.hegel_settings_set_suppress_health_check != nil {
		HEGEL_HC_FILTER_TOO_MUCH :: u32(1 << 0)
		HEGEL_HC_TEST_CASES_TOO_LARGE :: u32(1 << 2)
		HEGEL_HC_LARGE_INITIAL_TEST_CASE :: u32(1 << 3)
		suppressed_health_checks := HEGEL_HC_FILTER_TOO_MUCH | HEGEL_HC_TEST_CASES_TOO_LARGE | HEGEL_HC_LARGE_INITIAL_TEST_CASE
		if !libhegel_ok(
			ctx,
			"settings_set_suppress_health_check",
			libhegel_symbols.hegel_settings_set_suppress_health_check(ctx, settings, suppressed_health_checks),
		) {
			if diagnostics {
				diagnostics_finish(loc, started_at, {}, Hegel_Error.Native_Error)
			}
			return {}, .Native_Error
		}
	}
	if seed != 0 {
		if !libhegel_ok(ctx, "settings_set_seed", libhegel_symbols.hegel_settings_set_seed(ctx, settings, seed, true)) {
			if diagnostics {
				diagnostics_finish(loc, started_at, {}, Hegel_Error.Native_Error)
			}
			return {}, .Native_Error
		}
	}
	if options.derandomize {
		if !libhegel_ok(ctx, "settings_set_derandomize", libhegel_symbols.hegel_settings_set_derandomize(ctx, settings, true)) {
			if diagnostics {
				diagnostics_finish(loc, started_at, {}, Hegel_Error.Native_Error)
			}
			return {}, .Native_Error
		}
	}
	if database != "" || options.disable_database {
		database_cstr := strings.clone_to_cstring(database, context.temp_allocator)
		defer delete(database_cstr, context.temp_allocator)
		if !libhegel_ok(ctx, "settings_set_database", libhegel_symbols.hegel_settings_set_database(ctx, settings, database_cstr)) {
			if diagnostics {
				diagnostics_finish(loc, started_at, {}, Hegel_Error.Native_Error)
			}
			return {}, .Native_Error
		}
	}
	if database_key != "" {
		database_key_cstr := strings.clone_to_cstring(database_key, context.temp_allocator)
		defer delete(database_key_cstr, context.temp_allocator)
		if !libhegel_ok(ctx, "settings_set_database_key", libhegel_symbols.hegel_settings_set_database_key(ctx, settings, database_key_cstr)) {
			if diagnostics {
				diagnostics_finish(loc, started_at, {}, Hegel_Error.Native_Error)
			}
			return {}, .Native_Error
		}
	}

	native_run: Libhegel_Run
	if !libhegel_ok(ctx, "run_start", libhegel_symbols.hegel_run_start(ctx, settings, nil, nil, &native_run)) {
		if diagnostics {
			diagnostics_finish(loc, started_at, {}, Hegel_Error.Native_Error)
		}
		return {}, .Native_Error
	}
	defer libhegel_symbols.hegel_run_free(ctx, native_run)

	state := Native_Run_State {
		ctx      = ctx,
		settings = settings,
		run      = native_run,
	}
	result, err := run_native_event_loop(&state, body, user_data, loc, started_at, diagnostics)
	if err != nil {
		if diagnostics {
			diagnostics_finish(loc, started_at, {}, err)
		}
		return result, err
	}
	if result.interesting_test_cases > 0 {
		if diagnostics {
			diagnostics_finish(loc, started_at, result, Hegel_Error.Property_Failed)
		}
		return result, .Property_Failed
	}
	if diagnostics {
		diagnostics_finish(loc, started_at, result, nil)
	}
	return result, nil
}

run_native_event_loop :: proc(
	state: ^Native_Run_State,
	body: Test_Body,
	user_data: rawptr,
	loc: runtime.Source_Code_Location,
	started_at: time.Time,
	diagnostics: bool,
) -> (
	Run_Result,
	Hegel_Error,
) {
	result: Run_Result
	last_progress_at := started_at

	for {
		test_case: Libhegel_Test_Case
		if !libhegel_ok(state.ctx, "next_test_case", libhegel_symbols.hegel_next_test_case(state.ctx, state.run, &test_case)) {
			return result, .Native_Error
		}
		if test_case == nil {
			break
		}

		if diagnostics {
			now := time.now()
			if result.executed_test_cases == 0 || result.executed_test_cases % 25 == 0 || time.since(last_progress_at) >= 5 * time.Second {
				fmt.eprintf(
					"[hegel diag] case-start pid=%d caller=%s elapsed=%.3fs executed=%d\n",
					os.get_pid(),
					loc.procedure,
					diagnostics_elapsed_seconds(started_at),
					result.executed_test_cases,
				)
				last_progress_at = now
			}
		}

		case_err := run_native_one_case(state, test_case, false, body, user_data)
		libhegel_symbols.hegel_test_case_free(state.ctx, test_case)
		if case_err != nil {
			return result, case_err
		}
		result.executed_test_cases += 1
	}

	native_result: Libhegel_Run_Result
	if !libhegel_ok(state.ctx, "run_result", libhegel_symbols.hegel_run_result(state.ctx, state.run, &native_result)) {
		return result, .Native_Error
	}
	defer libhegel_symbols.hegel_run_result_free(state.ctx, native_result)

	status: Libhegel_Run_Status
	if !libhegel_ok(state.ctx, "run_result_status", libhegel_symbols.hegel_run_result_status(state.ctx, native_result, &status)) {
		return result, .Native_Error
	}

	switch status {
	case .Passed:
		result.passed = true
		return result, nil

	case .Failed:
		failure_count: uint
		if !libhegel_ok(state.ctx, "run_result_failure_count", libhegel_symbols.hegel_run_result_failure_count(state.ctx, native_result, &failure_count)) {
			return result, .Native_Error
		}
		result.interesting_test_cases = i64(failure_count)
		for i: uint = 0; i < failure_count; i += 1 {
			if err := replay_native_failure(state, native_result, i, body, user_data, loc, started_at, diagnostics); err != nil {
				return result, err
			}
		}
		return result, nil

	case .Error:
		error_message: cstring
		if libhegel_ok(state.ctx, "run_result_error", libhegel_symbols.hegel_run_result_error(state.ctx, native_result, &error_message)) &&
		   error_message != nil {
			log.errorf("hegel native run error: %s", string(error_message))
		}
		return result, .Native_Error

	case .Failed_Nondeterministic:
		log.error("hegel native run failed nondeterministically; deterministic NRC properties cannot replay this result")
		return result, .Native_Error
	}

	return result, .Native_Error
}

replay_native_failure :: proc(
	state: ^Native_Run_State,
	native_result: Libhegel_Run_Result,
	index: uint,
	body: Test_Body,
	user_data: rawptr,
	loc: runtime.Source_Code_Location,
	started_at: time.Time,
	diagnostics: bool,
) -> Hegel_Error {
	failure: Libhegel_Failure
	if !libhegel_ok(state.ctx, "run_result_failure", libhegel_symbols.hegel_run_result_failure(state.ctx, native_result, index, &failure)) {
		return .Native_Error
	}
	defer libhegel_symbols.hegel_failure_free(state.ctx, failure)
	origin: cstring
	if libhegel_ok(state.ctx, "failure_origin", libhegel_symbols.hegel_failure_origin(state.ctx, failure, &origin)) && origin != nil {
		log.errorf("hegel native failure origin: %s", string(origin))
	}
	blob: cstring
	if !libhegel_ok(state.ctx, "failure_reproduction_blob", libhegel_symbols.hegel_failure_reproduction_blob(state.ctx, failure, &blob)) {
		return .Native_Error
	}
	if blob == nil {
		return .Native_Error
	}
	if diagnostics {
		fmt.eprintf("[hegel diag] reproduction caller=%s final_index=%d blob=%s\n", loc.procedure, index, string(blob))
	}

	test_case: Libhegel_Test_Case
	if !libhegel_ok(state.ctx, "test_case_from_blob", libhegel_symbols.hegel_test_case_from_blob(state.ctx, state.settings, blob, nil, nil, &test_case)) {
		return .Native_Error
	}
	if test_case == nil {
		return .Native_Error
	}
	defer libhegel_symbols.hegel_test_case_free(state.ctx, test_case)

	if diagnostics {
		fmt.eprintf(
			"[hegel diag] final-case-start pid=%d caller=%s elapsed=%.3fs final_index=%d\n",
			os.get_pid(),
			loc.procedure,
			diagnostics_elapsed_seconds(started_at),
			index,
		)
	}
	return run_native_one_case(state, test_case, true, body, user_data)
}

run_native_one_case :: proc(state: ^Native_Run_State, native_tc: Libhegel_Test_Case, is_final: bool, body: Test_Body, user_data: rawptr) -> Hegel_Error {
	tc := Test_Case {
		native    = state,
		native_tc = native_tc,
		is_final  = is_final,
	}

	body_result := body(&tc, user_data)
	status := Libhegel_Status.Valid
	origin := body_result.origin
	if tc.aborted || body_result.status == .Aborted {
		status = .Overrun
	} else if tc.rejected {
		status = .Invalid
		origin = "assume"
	} else {
		switch body_result.status {
		case .Valid:
			status = .Valid
		case .Invalid:
			status = .Invalid
		case .Interesting:
			status = .Interesting
		case .Aborted:
			status = .Overrun
		}
	}

	origin_cstr: cstring
	if origin != "" {
		origin_cstr = strings.clone_to_cstring(origin, context.temp_allocator)
		defer delete(origin_cstr, context.temp_allocator)
	}
	if !libhegel_ok(state.ctx, "mark_complete", libhegel_symbols.hegel_mark_complete(state.ctx, native_tc, u32(status), origin_cstr)) {
		return .Native_Error
	}
	return nil
}

draw_i64 :: proc(tc: ^Test_Case, min_value, max_value: i64) -> (i64, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return 0, .Stop_Test
	}
	if min_value > max_value {
		return 0, .Protocol_Error
	}
	value: i64
	result := libhegel_symbols.hegel_generate_integer(tc.native.ctx, tc.native_tc, min_value, max_value, &value)
	if result != .OK {
		return 0, native_draw_error(tc, "generate_integer", result)
	}
	return value, nil
}

draw_bool :: proc(tc: ^Test_Case) -> (bool, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return false, .Stop_Test
	}
	value: bool
	result := libhegel_symbols.hegel_generate_boolean(tc.native.ctx, tc.native_tc, 0.5, false, false, &value)
	if result != .OK {
		return false, native_draw_error(tc, "generate_boolean", result)
	}
	return value, nil
}

draw_bytes :: proc(tc: ^Test_Case, min_size, max_size: int) -> ([]byte, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return nil, .Stop_Test
	}
	if min_size < 0 || max_size < 0 || min_size > max_size {
		return nil, .Protocol_Error
	}
	native_result: Libhegel_Bytes_Result
	result := libhegel_symbols.hegel_generate_bytes(tc.native.ctx, tc.native_tc, u64(min_size), u64(max_size), &native_result)
	if result != .OK {
		return nil, native_draw_error(tc, "generate_bytes", result)
	}
	defer libhegel_symbols.hegel_generate_bytes_result_free(tc.native.ctx, &native_result)
	value := make([]byte, int(native_result.len))
	if native_result.len > 0 {
		copy(value, ([^]byte)(native_result.data)[:native_result.len])
	}
	return value, nil
}

draw_u32 :: proc(tc: ^Test_Case, min_value, max_value: u32) -> (u32, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return 0, .Stop_Test
	}
	if min_value > max_value {
		return 0, .Protocol_Error
	}
	value, err := draw_i64(tc, i64(min_value), i64(max_value))
	if err != nil do return 0, err
	return u32(value), nil
}

draw_u64 :: proc(tc: ^Test_Case, min_value, max_value: u64) -> (u64, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return 0, .Stop_Test
	}
	if min_value > max_value {
		return 0, .Protocol_Error
	}
	min_bytes := u64_twos_complement(min_value)
	max_bytes := u64_twos_complement(max_value)
	out_bytes: [9]u8
	out_len: uint
	result := libhegel_symbols.hegel_generate_integer_big(
		tc.native.ctx,
		tc.native_tc,
		&min_bytes[0],
		uint(len(min_bytes)),
		&max_bytes[0],
		uint(len(max_bytes)),
		&out_bytes[0],
		uint(len(out_bytes)),
		&out_len,
	)
	if result != .OK {
		return 0, native_draw_error(tc, "generate_integer_big", result)
	}
	value: u64
	for i in 0 ..< 8 {
		value |= u64(out_bytes[i]) << (8 * u64(i))
	}
	return value, nil
}

draw_f64 :: proc(tc: ^Test_Case, min_value, max_value: f64) -> (f64, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return 0, .Stop_Test
	}
	if min_value > max_value {
		return 0, .Protocol_Error
	}
	value: f64
	result := libhegel_symbols.hegel_generate_float(tc.native.ctx, tc.native_tc, 64, min_value, max_value, false, false, false, false, 5e-324, &value)
	if result != .OK {
		return 0, native_draw_error(tc, "generate_float", result)
	}
	return value, nil
}

draw_text :: proc(tc: ^Test_Case, min_size, max_size: int) -> (string, Draw_Error) {
	if tc == nil || tc.aborted || tc.rejected {
		return "", .Stop_Test
	}
	if min_size < 0 || max_size < 0 || min_size > max_size {
		return "", .Protocol_Error
	}
	gen := text_gen_min_size(text(), min_size)
	gen = text_gen_max_size(gen, max_size)
	return text_gen_draw(tc, gen)
}

assume :: proc(tc: ^Test_Case, condition: bool) {
	if tc == nil || tc.aborted || tc.rejected {
		return
	}
	if !condition {
		tc.rejected = true
	}
}

note :: proc(tc: ^Test_Case, message: string) {
	if tc == nil || tc.aborted || tc.rejected {
		return
	}
	if tc.is_final {
		log.infof("[hegel note] %s", message)
	}
}

native_draw_error :: proc(tc: ^Test_Case, operation: string, result: Libhegel_Result) -> Draw_Error {
	#partial switch result {
	case .Stop_Test:
		tc.aborted = true
		return .Stop_Test
	case .Assume:
		tc.rejected = true
		return .Stop_Test
	case:
		libhegel_error_log(tc.native.ctx, operation, result)
		return .Server_Error
	}
}

draw_native_string :: proc(tc: ^Test_Case, generator: Libhegel_String_Generator) -> (string, Draw_Error) {
	native_result: Libhegel_String_Result
	result := libhegel_symbols.hegel_generate_string(tc.native.ctx, tc.native_tc, generator, &native_result)
	if result != .OK {
		return "", native_draw_error(tc, "generate_string", result)
	}
	defer libhegel_symbols.hegel_generate_string_result_free(tc.native.ctx, &native_result)
	if native_result.len == 0 {
		return "", nil
	}
	return strings.clone(string(([^]byte)(native_result.data)[:native_result.len])), nil
}

u64_twos_complement :: proc(value: u64) -> [9]u8 {
	result: [9]u8
	for i in 0 ..< 8 {
		result[i] = u8(value >> (8 * u64(i)))
	}
	return result
}

draw_native_date_value :: proc(tc: ^Test_Case) -> (Libhegel_Date, Draw_Error) {
	value: Libhegel_Date
	result := libhegel_symbols.hegel_generate_date(
		tc.native.ctx,
		tc.native_tc,
		Libhegel_Date{year = 1, month = 1, day = 1},
		Libhegel_Date{year = 9999, month = 12, day = 31},
		&value,
	)
	if result != .OK {
		return {}, native_draw_error(tc, "generate_date", result)
	}
	return value, nil
}

draw_native_time_value :: proc(tc: ^Test_Case) -> (Libhegel_Time, Draw_Error) {
	value: Libhegel_Time
	result := libhegel_symbols.hegel_generate_time(
		tc.native.ctx,
		tc.native_tc,
		Libhegel_Time{},
		Libhegel_Time{hour = 23, minute = 59, second = 59, microsecond = 999_999},
		&value,
	)
	if result != .OK {
		return {}, native_draw_error(tc, "generate_time", result)
	}
	return value, nil
}

draw_native_date :: proc(tc: ^Test_Case) -> (string, Draw_Error) {
	value, err := draw_native_date_value(tc)
	if err != nil do return "", err
	return fmt.tprintf("%04d-%02d-%02d", value.year, value.month, value.day), nil

}

draw_native_time :: proc(tc: ^Test_Case) -> (string, Draw_Error) {
	value, err := draw_native_time_value(tc)
	if err != nil do return "", err
	return fmt.tprintf("%02d:%02d:%02d.%06d", value.hour, value.minute, value.second, value.microsecond), nil

}

draw_native_datetime :: proc(tc: ^Test_Case) -> (string, Draw_Error) {
	value: Libhegel_Datetime
	result := libhegel_symbols.hegel_generate_datetime(
		tc.native.ctx,
		tc.native_tc,
		Libhegel_Datetime{date = {year = 1, month = 1, day = 1}},
		Libhegel_Datetime{date = {year = 9999, month = 12, day = 31}, time = {hour = 23, minute = 59, second = 59, microsecond = 999_999}},
		&value,
	)
	if result != .OK {
		return "", native_draw_error(tc, "generate_datetime", result)
	}
	return fmt.tprintf(
			"%04d-%02d-%02dT%02d:%02d:%02d.%06d",
			value.date.year,
			value.date.month,
			value.date.day,
			value.time.hour,
			value.time.minute,
			value.time.second,
			value.time.microsecond,
		),
		nil
}

draw_native_ip :: proc(tc: ^Test_Case, version: i64) -> (string, Draw_Error) {
	bytes: [16]u8
	result: Libhegel_Result
	if version == 4 {
		result = libhegel_symbols.hegel_generate_ipv4(tc.native.ctx, tc.native_tc, &bytes[0])
	} else if version == 6 {
		result = libhegel_symbols.hegel_generate_ipv6(tc.native.ctx, tc.native_tc, &bytes[0])
	} else {
		return "", .Protocol_Error
	}
	if result != .OK {
		return "", native_draw_error(tc, "generate_ip", result)
	}
	if version == 4 {
		return fmt.tprintf("%d.%d.%d.%d", bytes[0], bytes[1], bytes[2], bytes[3]), nil
	}
	return fmt.tprintf(
			"%x:%x:%x:%x:%x:%x:%x:%x",
			u16(bytes[0]) << 8 | u16(bytes[1]),
			u16(bytes[2]) << 8 | u16(bytes[3]),
			u16(bytes[4]) << 8 | u16(bytes[5]),
			u16(bytes[6]) << 8 | u16(bytes[7]),
			u16(bytes[8]) << 8 | u16(bytes[9]),
			u16(bytes[10]) << 8 | u16(bytes[11]),
			u16(bytes[12]) << 8 | u16(bytes[13]),
			u16(bytes[14]) << 8 | u16(bytes[15]),
		),
		nil
}
