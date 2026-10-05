//
// server.odin - Core WebSocket Server Implementation
//
// This file contains the main server implementation including:
// - Server startup, shutdown, and lifecycle management
// - Multi-threaded architecture with worker thread coordination
// - Signal handling for graceful shutdown
// - Connection acceptance and initial routing to worker threads
// - Main application entry point
//
package main

import "base:runtime"

import "core:c/libc"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import "core:thread"
import "core:time"

import "btree"
import "byte_pool"
import nbio "nbio/poly"
import "persistence"
import pr "protocol"
import "spsc"
import "ulid"

// Suppress unused import warnings when ODIN_DEBUG is false.
_ :: mem.tracking_allocator_init

thread_count := 2
server_port := 8080
runtime_storage_layout: Storage_Layout_Manifest

PENDING_QUEUE_CAPACITY :: 16384

NRC_Server :: struct {
	sock:                     net.TCP_Socket,
	threads:                  []^thread.Thread,
	closing:                  bool,
	fatal_storage_error:      bool,
	shutdown_requested:       bool, // For SIGINT edge detection (first vs second signal)
	main_thread:              int,
	wg:                       sync.Wait_Group,
	// The queue will hold socket descriptors for handoff.
	pending_connections:      []Pending_Connection_Queue,
	worker_startup:           chan.Chan(bool),
	shard_compaction_jobs:    chan.Chan(Shard_Compaction_Job),
	// One compactor producer and one owning-worker consumer per result queue.
	// Main drains leftovers only after the wait group synchronizes completion.
	shard_compaction_results: []^spsc.Queue(Shard_Compaction_Result),
	shard_compactor_thread:   ^thread.Thread,
}

Server_State :: enum {
	Running,
	Closing,
	Closed,
}

default_worker_thread_count :: proc(available_cpu_count: int) -> int {
	return clamp(available_cpu_count - 1, 1, MAX_SERVER_WORKER_COUNT)
}

configured_thread_count :: proc(default_count: int) -> int {
	thread_count_env := os.get_env_alloc("NRC_THREAD_COUNT", context.allocator)
	defer delete(thread_count_env)
	if thread_count_env == "" {
		return default_count
	}

	parsed, ok := strconv.parse_int(thread_count_env)
	if !ok || parsed <= 0 {
		return default_count
	}

	return int(parsed)
}

configured_service_cpu :: proc() -> (int, bool) {
	service_cpu_env := os.get_env_alloc("NRC_SERVICE_CPU", context.allocator)
	defer delete(service_cpu_env)
	if service_cpu_env == "" do return -1, false
	parsed, ok := strconv.parse_int(service_cpu_env)
	if !ok || parsed < 0 {
		log.warnf("Invalid NRC_SERVICE_CPU %q; using automatic service-core selection", service_cpu_env)
		return -1, false
	}
	return int(parsed), true
}

configured_server_port :: proc(default_port: int) -> int {
	port_env := os.get_env_alloc("NRC_PORT", context.allocator)
	defer delete(port_env)
	if port_env == "" {
		return default_port
	}

	parsed, ok := strconv.parse_int(port_env)
	if !ok || parsed <= 0 || parsed > int(max(u16)) {
		return default_port
	}

	return int(parsed)
}

Worker_Thread_Data :: struct {
	server:       ^NRC_Server,
	thread_index: int,
}

MAX_CONNECTIONS_PER_THREAD :: 65535

// DM_Participants stores the two participants of a DM conversation
DM_Participants :: struct {
	user_a: string, // alphabetically first (interned)
	user_b: string, // alphabetically second (interned)
}

Note_Sort_Key :: struct {
	updated_at: i64,
	asset_id:   pr.AssetID,
}

Task_Sort_Key :: struct {
	sort_at: i64,
	task_id: pr.TaskID,
}

Task_Query_Key :: struct {
	number:      i64,
	text:        []byte,
	due_missing: bool,
	task_id:     pr.TaskID,
}

Task_Query_Index_Set :: struct {
	// Priority ascending is the canonical membership/count tree. Other orders
	// are materialized on first use and then kept current by mutations.
	trees:       [8][2]btree.BTreeG(Task_Query_Key),
	initialized: [8][2]bool,
}

Task_Query_Secondary_Index :: struct {
	key:     string,
	indexes: Task_Query_Index_Set,
}

Room_Mapping_State :: struct {
	conv_id:  pr.ConversationID,
	asset_id: pr.AssetID,
}

// Conversation_State holds all per-conversation data in a single allocation.
// Entity maps expose borrowed read-only pointers. Production mutations must use
// task_store_*, asset_store_* or edge_store_* so ownership and indexes stay in
// sync. Only initialization/teardown and isolated index test fixtures bypass them.
Conversation_State :: struct {
	subscriber_entries:        [dynamic]Subscriber_Entry, // dense socket/handle list for broadcast fanout
	subscriber_index:          map[net.TCP_Socket]int, // socket -> index in subscriber_entries
	subscribers_dirty:         bool, // dense list needs optional re-sort by handle index
	agenda:                    string, // agenda content (cloned, owned)
	tasks:                     map[pr.TaskID]^pr.Task, // task_id -> task
	task_index:                btree.BTreeG(Task_Sort_Key), // task ordering index for keyset pagination
	task_index_keys:           map[pr.TaskID]Task_Sort_Key, // task_id -> current sort key
	task_query_indexes:        Task_Query_Index_Set, // all sortable task query orders
	task_status_indexes:       [4]Task_Query_Index_Set, // status-filtered sortable indexes
	task_project_indexes:      map[string]^Task_Query_Secondary_Index,
	task_assignee_indexes:     map[string]^Task_Query_Secondary_Index,
	task_blockers:             btree.BTreeG(Entity_Reference_Key), // blocker task -> blocked tasks
	calendar_index:            btree.BTreeG(pr.CalendarKey),
	calendar_reminder_keys:    map[pr.AssetID]pr.CalendarKey,
	calendar_appointments:     btree.BTreeG(Appointment_Index_Key),
	calendar_appointment_keys: map[pr.AssetID]Appointment_Index_Key,
	calendar_ready:            bool,
	assets:                    map[pr.AssetID]^pr.Asset, // asset_id -> asset
	note_index:                btree.BTreeG(Note_Sort_Key), // note ordering index for pagination
	note_index_keys:           map[pr.AssetID]Note_Sort_Key, // asset_id -> current note sort key
	note_project_assets:       map[string]^Note_Secondary_Index, // project name -> sorted note index
	note_tag_assets:           map[string]^Note_Secondary_Index, // tag name -> sorted note index
	asset_parents:             btree.BTreeG(Entity_Reference_Key), // parent kind/id -> child assets
	edges:                     map[pr.EdgeID]^pr.Edge, // edge_id -> edge (knowledge graph links)
	edges_by_entity:           map[Edge_Entity_Key][dynamic]pr.EdgeID, // entity -> incident edge IDs (for O(1) lookup)
	dm_participants:           ^DM_Participants, // nil for regular rooms, set for DM conversations
}

// Edge_Entity_Key identifies an entity (asset or task) for edge adjacency lookup
Edge_Entity_Key :: struct {
	target_type: pr.TargetType,
	target_id:   u64,
}

// Workspace_State holds all per-workspace data
Workspace_State :: struct {
	conversations:                       map[pr.ConversationID]^Conversation_State, // conversation-scoped data
	room_mappings:                       map[string]Room_Mapping_State, // normalized room name -> room mapping registry entry
	user_dms:                            map[string][dynamic]pr.ConversationID, // username -> list of DM conv_ids user is in
	user_connection_head:                map[string]Connection_Handle, // username -> active-connection list head for DM targeting
	user_connection_next:                map[Connection_Handle]Connection_Handle, // links only additional devices; singleton users need no entry
	user_connection_count:               map[string]int, // username -> count of active connections (for online detection)
	user_authenticated_connection_count: map[string]int, // username -> count of authenticated active connections
	user_last_seen:                      map[string]u64, // username -> unix timestamp of last disconnect
}

// Maximum socket file descriptor value (ulimit -n on Linux)
// Used for O(1) socket-to-connection lookup via direct array indexing
MAX_SOCK_FD :: 524288

Server_Thread :: struct {
	using td:                  Worker_Thread_Data,
	connection_handles:        [MAX_SOCK_FD]Connection_Handle, // Socket FD -> generational connection handle (O(1) direct index)
	connections_by_handle:     Connection_Map, // Owns worker connections with stable handles/pointers
	active_sockets:            map[net.TCP_Socket]struct{}, // Set of active sockets for iteration (O(1) add/remove)
	connection_count:          int, // Track active connection count
	retained_connection_count: int, // Handle-map allocations, including physically closed connections retained by I/O
	state:                     Server_State,
	io:                        nbio.IO,

	// Reference to this thread's pending handoff queue
	my_pending_queue:          Pending_Connection_Queue,

	// Consolidated workspace state (replaces 6 separate maps)
	workspaces:                map[string]^Workspace_State,

	// Thread-safe parent heap for infrastructure and cross-thread job ownership.
	backing_allocator:         mem.Allocator,

	// Thread-local send buffer pool
	spool:                     ^byte_pool.BufferPool,

	// Thread-local cache for batch writev metadata (reduces heap churn)
	batch_state_pool:          Batch_State_Pool,
	shared_fanout_depth:       int,
	draining_presence_updates: bool,
	deferred_presence_updates: [dynamic]Deferred_Presence_Update,
	collect_presence_updates:  bool,
	presence_batches:          [PRESENCE_BATCH_ROOMS]Presence_Batch,
	presence_batch_count:      int,

	// Normal fanout is collected during a callback wave and published afterwards
	// in bounded batches, allowing priority ACKs to reach io_uring first. The
	// depth supports nested fanout scopes. Each connection appears at most once
	// in the fixed-capacity deferred_outbox_handles ring, guarded by
	// conn.outbox_pump_deferred.
	defer_normal_outbox_pumps: int,
	deferred_outbox_handles:   queue.Queue(Connection_Handle),
	input_budget_active:       bool,
	input_frames_remaining:    int,
	deferred_input_handles:    queue.Queue(Connection_Handle),
	deferred_input_bytes:      uint,
	input_budget_yields:       u64,
	input_pressure_yields:     u64,
	input_pressure_handle:     Connection_Handle, // Weak hint; recheck backlog each turn

	// Dense index of connections that currently own an incomplete transport
	// send. This makes the send watchdog O(in-flight sends), rather than scanning
	// every connection. conn.send_watchdog_slot is its O(1) reverse index.
	inflight_send_handles:     [dynamic]Connection_Handle,

	// Idle maintenance advances through the fixed socket-to-handle table in a
	// bounded slice each tick. The independent deadline runs the less frequent
	// stalled-send scan from the same maintenance timer.
	idle_scan_cursor:          int,
	next_send_watchdog_at:     time.Time,

	// Monotonic task ID generator (thread-local, no atomics needed)
	task_seq:                  u64,

	// This worker's active logical-shard WAL writers.
	shard_writers:             Shard_Writer_Registry,
	message_stores:            Message_Store_Registry,

	// Monotonic asset ID generator (thread-local, no atomics needed)
	asset_seq:                 u64,

	// Monotonic edge ID generator (thread-local, no atomics needed)
	edge_seq:                  u64,

	// Workspace string interning pool (reduces duplicate allocations)
	workspace_intern:          strings.Intern,

	// Performance metric caches
	last_rss_update:           time.Time,
	cached_rss_mb:             u32,

	// Runtime adapter configuration. Empty means production defaults.
	persistence_data_dir:      string,

	// Shared idle-scan/send-watchdog timer, retained so shutdown can cancel it
	// before connection and worker-owned storage is released.
	maintenance_completion:    ^nbio.Completion,
}

BUILD_VERSION :: "dev-2026-10:249e2a7c"
PROTOCOL_VERSION :: 8 // Calendar appointment rows carry an explicit time interval.

jwt_auth_secret: string
jwt_expected_issuer: string
jwt_expected_audience: string
workspace_access_enabled: bool

bot_auth_secret: string

@(thread_local)
td: Server_Thread

@(thread_local)
// Test/diagnostic marker set when persistent_mutation_failed is reached.
// Server shutdown itself is driven by td.server.closing.
persistent_mutation_failure_seen: bool

parse_log_level :: proc(value: string) -> (log.Level, bool) {
	switch value {
	case "debug", "DEBUG", "Debug":
		return .Debug, true
	case "info", "INFO", "Info":
		return .Info, true
	case "warn", "WARN", "Warn", "warning", "WARNING", "Warning":
		return .Warning, true
	case "error", "ERROR", "Error":
		return .Error, true
	case "fatal", "FATAL", "Fatal":
		return .Fatal, true
	}

	return .Info, false
}

main :: proc() {
	defer jwt_validation_scratch_destroy()
	gc_options, gc_requested, gc_args_ok := attachment_gc_parse_command(os.args)
	if gc_requested && !gc_args_ok {
		attachment_gc_print_usage()
		os.exit(2)
	}
	if gc_requested && gc_options.help {
		attachment_gc_print_usage()
		return
	}

	// Use one affinity snapshot for both the automatic worker count and role
	// placement. A concurrent cgroup/cpuset change must not make those disagree.
	cpu_topology := detect_cpu_topology()
	available_cpu_count := cpu_topology.entry_count
	if available_cpu_count == 0 do available_cpu_count = os.get_processor_core_count()
	available_worker_cores := available_cpu_count
	if cpu_topology.complete && cpu_topology.physical_core_count > 0 do available_worker_cores = cpu_topology.physical_core_count
	thread_count = configured_thread_count(default_worker_thread_count(available_worker_cores))
	server_port = configured_server_port(server_port)

	// Authentication for users is validated from proxy-issued JWTs in X-NRC-Auth.

	log_level := log.Level.Info
	log_level_env := os.get_env_alloc("NRC_LOG_LEVEL", context.allocator)
	defer delete(log_level_env)
	if log_level_env != "" {
		parsed_level, ok := parse_log_level(log_level_env)
		if ok {
			log_level = parsed_level
		}
	}

	logger := log.create_console_logger(log_level)
	context.logger = logger
	if log_level_env != "" {
		_, ok := parse_log_level(log_level_env)
		if !ok {
			log.warnf("Invalid NRC_LOG_LEVEL %q, using info", log_level_env)
		}
	}

	service_cpu_override, has_service_cpu_override := configured_service_cpu()
	cpu_role_plan = build_topology_cpu_role_plan(&cpu_topology, thread_count, service_cpu_override)
	if has_service_cpu_override && cpu_role_plan.service_cpu != service_cpu_override {
		log.warnf("NRC_SERVICE_CPU %d is outside the allowed CPU set; using CPU %d", service_cpu_override, cpu_role_plan.service_cpu)
	}
	if cpu_role_plan.allowed_cpu_count > 0 {
		log.infof(
			"CPU roles: %d logical CPUs, %d physical cores, %d NUMA nodes, %d P-cores, %d E-cores; %d worker CPUs, service CPU %d, dedicated service core: %v, topology-aware: %v",
			cpu_role_plan.allowed_cpu_count,
			cpu_role_plan.physical_core_count,
			cpu_role_plan.numa_node_count,
			cpu_role_plan.performance_cores,
			cpu_role_plan.efficiency_cores,
			cpu_role_plan.worker_cpu_count,
			cpu_role_plan.service_cpu,
			cpu_role_plan.dedicated_service_core,
			cpu_role_plan.topology_aware,
		)
	}

	// Initialize ULID time package (logs TSC availability)
	ulid.init()

	bot_auth_secret = os.get_env_alloc("NRC_BOT_SECRET", context.allocator)
	if bot_auth_secret == "" {
		bot_auth_secret = "change-me-in-production"
		log.warnf("NRC_BOT_SECRET not set, using default (NOT SAFE FOR PRODUCTION)")
	}

	jwt_auth_secret = os.get_env_alloc("NRC_JWT_SECRET", context.allocator)
	if jwt_auth_secret == "" {
		jwt_auth_secret = "dev-insecure-nrc-jwt-secret"
		log.warnf("NRC_JWT_SECRET not set, using default (NOT SAFE FOR PRODUCTION)")
	}

	jwt_expected_issuer = os.get_env_alloc("NRC_JWT_ISSUER", context.allocator)
	jwt_expected_audience = os.get_env_alloc("NRC_JWT_AUDIENCE", context.allocator)

	workspace_access_config := os.get_env_alloc("NRC_WORKSPACE_ACCESS", context.allocator)
	workspace_access_enabled = workspace_access_config_enabled(workspace_access_config)
	delete(workspace_access_config)
	if workspace_access_enabled && jwt_auth_secret == "dev-insecure-nrc-jwt-secret" {
		log.error("NRC_WORKSPACE_ACCESS requires a non-default NRC_JWT_SECRET")
		os.exit(1)
	}

	log.infof("running with thread_count: %d", thread_count)

	when ODIN_DEBUG {
		init_debug_logger()

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	init_cpu_info()
	if gc_requested {
		storage_lock, locked := acquire_data_directory_lock(persistence.DATA_DIR)
		if !locked {
			log.error("Attachment GC requires exclusive storage access; stop the WebSocket server before running it")
			os.exit(1)
		}
		defer release_data_directory_lock(&storage_lock)
		manifest, found, valid := load_storage_layout_manifest(persistence.DATA_DIR)
		if !found || !valid || !active_sharded_generation_structure_is_valid(persistence.DATA_DIR, manifest.generation) {
			log.error("Attachment GC refused to run because the sharded storage layout is absent or invalid")
			os.exit(1)
		}
		runtime_storage_layout = manifest
		if !run_attachment_gc(gc_options) do os.exit(1)
		return
	}
	storage_lock, storage_ok := sharded_storage_layout_gate(persistence.DATA_DIR, thread_count)
	if !storage_ok {
		log.error("Sharded storage layout validation failed. Migrate legacy data with the pinned 70d3da1 server image before starting this version")
		os.exit(1)
	}
	defer release_data_directory_lock(&storage_lock)
	runtime_storage_layout, _, storage_ok = load_storage_layout_manifest(persistence.DATA_DIR)
	if !storage_ok do os.exit(1)
	if !start_server() do os.exit(1)
}

on_interrupt_server: ^NRC_Server
on_interrupt_context: runtime.Context

// Registers a signal handler to shutdown the server gracefully on interrupt signal.
// Can only be called once in the lifetime of the program because of a hacky interaction with libc.
server_shutdown_on_interrupt :: proc(s: ^NRC_Server) {
	on_interrupt_server = s
	on_interrupt_context = context

	// Ignore SIGPIPE to prevent crashes when writing to closed sockets
	SIGPIPE :: 13
	SIG_IGN := transmute(proc "cdecl" (_: i32))uintptr(1)
	libc.signal(SIGPIPE, SIG_IGN)

	libc.signal(
		libc.SIGINT,
		proc "cdecl" (_: i32) {
			context = on_interrupt_context

			// First SIGINT: request graceful shutdown
			// Second SIGINT: force exit
			// Note: We use shutdown_requested instead of td.state because td is thread-local
			// and the signal handler can execute on any thread.
			if sync.atomic_exchange(&on_interrupt_server.shutdown_requested, true) {
				os.exit(1)
			}

			server_shutdown(on_interrupt_server)
		},
	)
}

start_server :: proc() -> bool {
	server: ^NRC_Server = new(NRC_Server)
	server.main_thread = sync.current_thread_id()
	// Note: td (thread-local) for the *main* thread is not fully initialized
	// as a worker thread here. The main thread doesn't run the worker_thread loop.
	defer free(server)

	server_shutdown_on_interrupt(server)

	// --- Initialize pending connection channels ---
	server.pending_connections = make([]Pending_Connection_Queue, thread_count)
	for i in 0 ..< thread_count {
		err: runtime.Allocator_Error
		server.pending_connections[i], err = pending_queue_create(PENDING_QUEUE_CAPACITY)
		if err != .None {
			log.fatalf("Failed to allocate channel for thread %d: %v", i, err)
			return false
		}
	}
	defer {
		for pending_queue in server.pending_connections do pending_queue_destroy(pending_queue)
		delete(server.pending_connections)
	}

	{
		err: runtime.Allocator_Error
		server.worker_startup, err = chan.create_buffered(chan.Chan(bool), thread_count, context.allocator)
		if err != .None {
			log.fatalf("Failed to allocate worker startup channel: %v", err)
			return false
		}
	}
	defer chan.destroy(server.worker_startup)
	{
		err: runtime.Allocator_Error
		server.shard_compaction_jobs, err = chan.create_buffered(chan.Chan(Shard_Compaction_Job), LOGICAL_SHARD_COUNT, context.allocator)
		if err != .None {
			log.fatalf("Failed to allocate shard compaction job channel: %v", err)
			return false
		}
	}
	defer chan.destroy(server.shard_compaction_jobs)
	server.shard_compaction_results = make([]^spsc.Queue(Shard_Compaction_Result), thread_count)
	defer delete(server.shard_compaction_results)
	defer {
		for result_queue in server.shard_compaction_results {
			// Allocation can fail before every worker's queue is initialized.
			if result_queue != nil do spsc.destroy(result_queue)
		}
	}
	for i in 0 ..< thread_count {
		err: runtime.Allocator_Error
		// At most one shard compaction and one retained seal per logical shard.
		server.shard_compaction_results[i], err = spsc.create(Shard_Compaction_Result, 2 * LOGICAL_SHARD_COUNT, context.allocator)
		if err != .None {
			log.fatalf("Failed to allocate shard compaction result queue for worker %d: %v", i, err)
			return false
		}
	}

	// Main thread's nbio for accepting connections
	errno := nbio.init(&td.io)
	td.thread_index = -1 // main thread
	fmt.assertf(errno == linux.Errno.NONE, "Failed to initialize main thread IO: %v", errno)

	// Initialize provided buffer ring for main thread (HTTP processing)
	if init_err := nbio.pbuf_ring_init(&td.io); init_err != linux.Errno.NONE {
		log.fatalf("Failed to initialize buffer ring for main thread: %v", init_err)
		os.exit(1)
	}

	// Start worker threads
	log.infof("Starting server with %d worker threads...", thread_count)
	sync.wait_group_add(&server.wg, thread_count + 1)
	server.shard_compactor_thread = thread.create_and_start_with_poly_data(Shard_Compactor_Thread_Data{server}, shard_compactor_thread, context)
	server.threads = make([]^thread.Thread, thread_count)
	for i in 0 ..< thread_count {
		worker_data := Worker_Thread_Data {
			server       = server,
			thread_index = i,
		}

		server.threads[i] = thread.create_and_start_with_poly_data(worker_data, worker_thread, context)
	}
	// Children inherit the broad allowed mask and narrow themselves to their
	// assigned role. Pin main only after creation so a failed child affinity call
	// falls back to the allowed set rather than the service-only CPU.
	if !cpu_affinity_disabled() && cpu_role_plan.service_cpu >= 0 {
		set_thread_cpu_affinity(cpu_role_plan.service_cpu)
	}
	workers_ready := true
	for _ in 0 ..< thread_count {
		ready, received := chan.recv(server.worker_startup)
		if !received || !ready do workers_ready = false
	}
	if !workers_ready {
		log.error("Worker persistence startup failed before listener publication")
		server_shutdown(server)
	} else {
		sock, err := nbio.open_and_listen_tcp(&td.io, net.Endpoint{address = net.IP4_Any, port = server_port})
		fmt.assertf(err == nil, "Error opening and listening on port %d: %v", server_port, err)
		server.sock = sock
		log.infof("Listening on 0.0.0.0:%d (socket fd=%d)", server_port, sock)
		// Start single multishot accept only after every worker has published readiness.
		nbio.accept(&td.io, server.sock, server, on_accept, true)
	}

	_ = false // shutdown_started tracking removed
	for {
		errno = nbio.tick(&td.io, 100 * time.Millisecond)
		if errno != linux.Errno.NONE {
			log.errorf("Main thread nbio tick error: %v", errno)
			break
		}

		if sync.atomic_load(&server.closing) {
			break
		}
	}

	log.info("Waiting for worker threads...")

	// Wait for all worker threads to finish.
	sync.wait(&server.wg)
	discard_queued_pending_connections(server)
	// A worker can race the compactor's shutdown drain after cloning a job
	// path but before publishing it. Once every producer has joined, this final
	// drain closes that ownership window before the channel is destroyed.
	discard_queued_shard_compaction_jobs(server)
	discard_queued_shard_compaction_results(server)
	log.debug("server threads are done, shutting down")

	for t in server.threads do thread.destroy(t)
	delete(server.threads)
	thread.destroy(server.shard_compactor_thread)
	return workers_ready && !sync.atomic_load(&server.fatal_storage_error)
}

discard_queued_pending_connections :: proc(server: ^NRC_Server) {
	for pending_queue in server.pending_connections {
		for {
			pending, ok := pending_queue_try_recv(pending_queue)
			if !ok do break
			if pending.upgrade == nil do continue
			net.close(pending.upgrade.sock)
			http_temp_connection_free(pending.upgrade)
		}
	}
}

server_shutdown :: proc(s: ^NRC_Server) {
	sync.atomic_store(&s.closing, true)
}

server_shutdown_after_storage_error :: proc(s: ^NRC_Server) {
	sync.atomic_store(&s.fatal_storage_error, true)
	server_shutdown(s)
}

persistent_mutation_failed :: proc(domain: string, op: string, workspace_id: string) {
	if consume_shard_append_deferred() do return
	persistent_mutation_failure_seen = true
	if consume_shard_append_backpressure() {
		log.warnf("[T%d] Persistent %s %s deferred by shard storage backpressure for workspace %s", td.thread_index, domain, op, workspace_id)
		return
	}
	log.errorf(
		"[T%d] Persistent %s %s rejected by WAL for workspace %s; shutting down to preserve persistence/RAM consistency",
		td.thread_index,
		domain,
		op,
		workspace_id,
	)
	if td.server != nil {
		server_shutdown_after_storage_error(td.server)
	}
}

// --- on_accept (Runs on Main Thread with multishot semantics) ---
// Creates temporary Echo_Connection, calls nbio.recv_provided with on_recv_http_upgrade
on_accept :: proc(server: ^NRC_Server, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
	if err != nil {
		fmt.println(reflect.union_variant_typeid(err))
		log.errorf("[T%d Main] Error accepting a connection: %v", server.main_thread, err)
		// Multishot accept encountered a terminal error, re-arm if not shutting down
		if !sync.atomic_load(&server.closing) {
			time.sleep(100 * time.Millisecond)
			log.infof("[T%d Main] Re-arming multishot accept after error", server.main_thread)
			nbio.accept(&td.io, server.sock, server, on_accept, true)
		}
		return
	}

	// If shutting down, reject new connections immediately
	if sync.atomic_load(&server.closing) {
		when ODIN_DEBUG do debug_log("[T%d Main] Shutting down - closing newly accepted socket %v", server.main_thread, client)
		net.close(client)
		return
	}

	when ODIN_DEBUG do debug_log("[T%d Main] Accepted connection from %v:%v (socket %v)", server.main_thread, source.address, source.port, client)

	// Create temporary HTTP upgrade connection struct
	c := new(HTTP_Upgrade_Connection)
	c.allocator = context.allocator
	c.server = server
	c.sock = client
	c.state = .New
	c.http_received = 0 // Initialize HTTP tracking

	nbio.recv_provided(&td.io, client, c, on_recv_http_upgrade)
}
