package main

import "clock"
import "core:mem"
import "core:sync"
import "core:sync/chan"
import "core:time"
import "spsc"
import "storage_io"

Storage_Service_Thread_Data :: struct {
	server:     ^NRC_Server,
	bulk_index: int,
}

// Retained maintenance uses bounded service queues.
// Workspace record compaction is not a storage-service operation.
Storage_Service_Job :: struct {
	allocator:     mem.Allocator, // Thread-safe backing allocator, never worker TLSF.
	owner_worker:  int,
	shard:         int,
	storage:       storage_io.Context,
	shard_dir:     string,
	lifecycle:     ^Storage_Lifecycle,
	using message: Message_Seal_Job,
}

Storage_Service_Result :: struct {
	allocator:     mem.Allocator,
	owner_worker:  int,
	shard:         int,
	ok:            bool,
	lifecycle:     ^Storage_Lifecycle,
	using message: Message_Seal_Result,
}

destroy_storage_service_job :: proc(job: ^Storage_Service_Job) {
	context.allocator = job.allocator.procedure != nil ? job.allocator : context.allocator
	destroy_storage_lifecycle(job.lifecycle)
	if job.shard_dir != "" do delete(job.shard_dir)
	job^ = {}
}

destroy_storage_service_result :: proc(result: ^Storage_Service_Result) {
	if result == nil do return
	context.allocator = result.allocator.procedure != nil ? result.allocator : context.allocator
	destroy_storage_lifecycle(result.lifecycle)
	result^ = {}
}

run_storage_service_job :: proc(job: Storage_Service_Job) -> Storage_Service_Result {
	context.allocator = job.allocator.procedure != nil ? job.allocator : context.allocator
	owned_job := job
	defer destroy_storage_service_job(&owned_job)
	if job.lifecycle != nil {
		run_storage_lifecycle(job.lifecycle)
		owned_job.lifecycle = nil
		return {allocator = context.allocator, owner_worker = job.owner_worker, shard = job.shard, lifecycle = job.lifecycle, ok = job.lifecycle.ok}
	}
	if job.message_remove_generation != 0 || job.message_source_generation != 0 do return run_message_seal_job(job)
	return {allocator = context.allocator, owner_worker = job.owner_worker, shard = job.shard}
}

process_storage_service_result :: proc(result: Storage_Service_Result) -> bool {
	owned_result := result
	defer destroy_storage_service_result(&owned_result)
	if td.server == nil do return false
	if result.lifecycle != nil do return process_storage_lifecycle_result(&owned_result)
	if result.message_source_generation != 0 do return process_message_seal_result(result)
	return true
}

process_storage_service_results :: proc() -> bool {
	if td.server == nil || td.thread_index < 0 || td.thread_index >= len(td.server.storage_service_results) do return false
	did_work := false
	for {
		result, received := spsc.try_pop(td.server.storage_service_results[td.thread_index])
		if !received do return did_work
		did_work = true
		if !process_storage_service_result(result) do return true
	}
}

discard_queued_storage_service_jobs :: proc(server: ^NRC_Server) {
	if server == nil do return
	for jobs in ([2]chan.Chan(Storage_Service_Job){server.storage_control_jobs, server.storage_bulk_jobs}) {
		if jobs.impl == nil do continue
		for {
			job, received := chan.try_recv(jobs)
			if !received do break
			destroy_storage_service_job(&job)
		}
	}
}

// Cheap freshness probes share this lane. A small count budget lets probes
// force many expensive seals ahead of an already-admitted publication.
STORAGE_CONTROL_BURST :: 64
STORAGE_BULK_EXECUTORS :: 2
MAX_STORAGE_BULK_EXECUTORS :: 64

// Bulk threads never publish to worker SPSC queues. The service retains refused
// completions in bounded slots so one slow owner cannot discard a seal result.
service_storage_bulk_results :: proc(server: ^NRC_Server) -> bool {
	did_work := false
	for &pending, i in server.storage_bulk_pending[:server.storage_bulk_executor_count] {
		if !server.storage_bulk_pending_valid[i] {
			received: bool
			pending, received = chan.try_recv(server.storage_bulk_results)
			if !received do continue
			server.storage_bulk_pending_valid[i] = true
			did_work = true
		}
		if pending.message_remove_generation != 0 || pending.owner_worker < 0 || pending.owner_worker >= len(server.storage_service_results) {
			destroy_storage_service_result(&pending)
		} else if spsc.try_push(server.storage_service_results[pending.owner_worker], pending) {
			pending = {}
		} else {
			continue
		}
		server.storage_bulk_pending_valid[i] = false
		did_work = true
	}
	return did_work
}

storage_bulk_thread :: proc(data: Storage_Service_Thread_Data) {
	defer sync.wait_group_done(&data.server.wg)
	// An explicit pool is reserved from workers; without one preserve the
	// original service-CPU sharing default.
	cpu := cpu_role_plan.service_cpu
	if storage_bulk_config.cpu_count > 0 do cpu = storage_bulk_config.cpus[data.bulk_index % storage_bulk_config.cpu_count]
	if !cpu_affinity_disabled() && cpu >= 0 {
		set_thread_cpu_affinity(cpu)
	}
	for !sync.atomic_load(&data.server.closing) {
		job, received := chan.try_recv(data.server.storage_bulk_jobs)
		if !received {time.sleep(time.Millisecond); continue}
		result := run_storage_service_job(job)
		transferred := false
		for !sync.atomic_load(&data.server.closing) {
			if chan.try_send(data.server.storage_bulk_results, result) {
				transferred = true
				break
			}
			time.sleep(time.Millisecond)
		}
		if !transferred do destroy_storage_service_result(&result)
	}
}

service_storage_job :: proc(server: ^NRC_Server) -> bool {
	if server == nil do return false
	// Without a bulk completion channel, synchronous fixtures/simulation retain
	// the bounded fair executor. Production bulk execution is independent.
	job: Storage_Service_Job
	received: bool
	did_work := false
	if server.storage_bulk_results.impl != nil {
		did_work = service_storage_bulk_results(server)
		job, received = chan.try_recv(server.storage_control_jobs)
	} else {
		if server.storage_control_streak < STORAGE_CONTROL_BURST && server.storage_control_jobs.impl != nil {
			job, received = chan.try_recv(server.storage_control_jobs)
			if received do server.storage_control_streak += 1
		}
		if !received && server.storage_bulk_jobs.impl != nil {
			job, received = chan.try_recv(server.storage_bulk_jobs)
			if received do server.storage_control_streak = 0
		}
		if !received && server.storage_control_jobs.impl != nil {
			job, received = chan.try_recv(server.storage_control_jobs)
			if received do server.storage_control_streak = min(server.storage_control_streak + 1, STORAGE_CONTROL_BURST)
		}
	}
	if !received do return did_work
	result := run_storage_service_job(job)
	if result.message_remove_generation != 0 {
		destroy_storage_service_result(&result)
		return true
	}
	if result.owner_worker >= 0 && result.owner_worker < len(server.storage_service_results) {
		if spsc.try_push(server.storage_service_results[result.owner_worker], result) do return true
		// Publication results are authoritative and cannot be dropped when the
		// queue is full. Shutdown is safe: owners then never rewrite manifests.
		if result.lifecycle != nil {
			for !sync.atomic_load(&server.closing) {
				if spsc.try_push(server.storage_service_results[result.owner_worker], result) do return true
				time.sleep(time.Millisecond)
			}
		}
	}
	destroy_storage_service_result(&result)
	return true
}

discard_queued_storage_service_results :: proc(server: ^NRC_Server) {
	if server == nil do return
	for &pending, i in server.storage_bulk_pending {
		if server.storage_bulk_pending_valid[i] {
			destroy_storage_service_result(&pending)
			server.storage_bulk_pending_valid[i] = false
		}
	}
	if server.storage_bulk_results.impl != nil {
		for {
			result, received := chan.try_recv(server.storage_bulk_results)
			if !received do break
			destroy_storage_service_result(&result)
		}
	}
	for result_queue in server.storage_service_results {
		for {
			result, received := spsc.try_pop(result_queue)
			if !received do break
			destroy_storage_service_result(&result)
		}
	}
}

storage_service_thread :: proc(data: Storage_Service_Thread_Data) {
	defer sync.wait_group_done(&data.server.wg)
	if !cpu_affinity_disabled() && cpu_role_plan.service_cpu >= 0 {
		set_thread_cpu_affinity(cpu_role_plan.service_cpu)
	}
	last_rss_update: time.Time
	for {
		if sync.atomic_load(&data.server.closing) {
			// Workers no longer need results once shutdown starts. Do not make
			// shutdown wait for every queued cleaning job, but release the
			// directory strings transferred with those jobs.
			discard_queued_storage_service_jobs(data.server)
			return
		}
		now := clock.now()
		if last_rss_update == (time.Time{}) || time.diff(last_rss_update, now) >= time.Second {
			sync.atomic_store(&data.server.cached_rss_mb, get_rss_memory_mb())
			last_rss_update = now
		}
		if service_storage_job(data.server) {
			continue
		}
		time.sleep(time.Millisecond)
	}
}
