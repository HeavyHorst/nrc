package main

import "core:time"
import nbio "nbio/poly"

reserve_message_store_registry_capacity :: proc(registry: ^Message_Store_Registry, worker, worker_count: int) -> bool {
	if registry == nil || len(registry.stores) != 0 do return false
	owned_shards := 0
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		owner, ok := logical_shard_worker(shard, worker_count)
		if !ok do return false
		if owner == worker do owned_shards += 1
	}
	return reserve(&registry.stores, owned_shards) == nil
}

init_message_store_registry :: proc(registry: ^Message_Store_Registry, generation_dir: string, worker, worker_count: int) -> bool {
	if registry == nil do return false
	for &index in registry.store_index do index = -1
	retention, valid := configured_message_retention(); if !valid do return false
	dedup_window, dedup_valid := configured_message_dedup_window(); if !dedup_valid do return false
	active_cache_bytes, active_cache_valid := configured_message_active_cache_bytes(); if !active_cache_valid do return false
	sealed_index_cache_bytes, sealed_index_cache_valid := configured_message_sealed_index_cache_bytes(); if !sealed_index_cache_valid do return false
	write_batch_records, write_batch_records_valid := configured_message_write_batch_records(); if !write_batch_records_valid do return false
	registry.worker =
		worker; registry.worker_count = worker_count; registry.retention = retention; registry.dedup_window = dedup_window; registry.quota_bytes = configured_message_store_quota(); registry.write_batch_records = write_batch_records; registry.active_cache.limit_bytes = active_cache_bytes; registry.sealed_index_cache.limit_bytes = sealed_index_cache_bytes; registry.sealed_wal_cache.limit = MESSAGE_SEALED_WAL_CACHE_LIMIT
	if retention == 0 {
		now := nrc_time_unix_nanos()
		for shard in 0 ..< LOGICAL_SHARD_COUNT {
			owner, ok := logical_shard_worker(shard, worker_count); if !ok do return false; if owner != worker do continue
			shard_dir := sharded_shard_path(generation_dir, shard)
			updated := mark_message_store_disabled(shard_dir, shard, now); delete(shard_dir)
			if !updated do return false
		}
		return true
	}
	// Async fsyncs and cache entries retain store pointers. Arena controls have
	// separate stable allocation, but the registry itself must still not move.
	if !reserve_message_store_registry_capacity(registry, worker, worker_count) do return false
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		owner, ok := logical_shard_worker(shard, worker_count); if !ok do return false; if owner != worker do continue
		i := len(registry.stores); _, err := append(&registry.stores, Message_Store{}); if err != nil do return false
		shard_dir := sharded_shard_path(generation_dir, shard)
		initialized := init_message_store(
			&registry.stores[i],
			shard_dir,
			shard,
			retention,
			registry.quota_bytes,
			dedup_window,
			&registry.active_cache,
			&registry.sealed_index_cache,
			&registry.sealed_wal_cache,
		); delete(shard_dir)
		if !initialized {shutdown_message_store_registry(registry); return false}
		registry.store_index[shard] = i16(i)
	}
	registry.enabled = true
	return true
}

message_store_for_workspace :: proc(registry: ^Message_Store_Registry, workspace: []byte) -> ^Message_Store {
	if registry == nil || !registry.enabled || len(workspace) == 0 do return nil
	shard := int(shard_for_workspace(workspace)); i := registry.store_index[shard]
	if i < 0 || int(i) >= len(registry.stores) do return nil
	return &registry.stores[i]
}

maintain_message_store_registry :: proc(registry: ^Message_Store_Registry) -> (did_work, ok: bool) {
	if registry == nil || !registry.enabled do return false, true
	for &store in registry.stores {
		// Read failures also poison stores. They must trigger fatal shutdown,
		// not leave durability-gated outboxes waiting on an inactive store.
		if store.poisoned || !store.wal.enabled do return did_work, false
		if store.frozen_published && store.frozen.async_readers == 0 do destroy_frozen_message_store(&store, true)
		if store.frozen != nil && !store.frozen_published && !store.seal_in_flight {
			if !enqueue_message_seal(&store, nrc_time_unix_nanos()) do return did_work, false
		}
		if store.seal_ready || store.rotation_pending && store.frozen == nil && store.async_readers == 0 {
			retained_message_schedule_store_flush(&store)
			did_work = true
		}
		if schedule_retained_message_fsync(&store) do did_work = true
		if !maintain_message_store(&store, sync_wal = false) do return did_work, false
	}
	return did_work, true
}

shutdown_message_store_registry :: proc(registry: ^Message_Store_Registry) -> bool {
	if registry == nil do return true
	cancel_message_seals(registry)
	ok := true
	for {
		_, flushed := flush_pending_retained_message_writes(registry)
		if !flushed do ok = false
		leased := false
		for &store in registry.stores {
			if store.wal.pending_bytes > 0 {
				store.commit_pending = true
				store.commit_started = {}
				_ = schedule_retained_message_fsync(&store)
			}
			leased = leased || store.write_in_flight || store.fsync_in_flight
		}
		if !leased && registry.pending_write_count == 0 do break
		when NRC_SIMULATION {
			if nrc_sim_runtime != nil {
				for nrc_sim_run_next_file_write(nrc_sim_runtime) {}
				for nrc_sim_run_next_fsync_completion(nrc_sim_runtime) {}
				continue
			}
		}
		// Never destroy a descriptor or batch while the kernel can access it.
		err := nbio.tick(&td.io, time.Millisecond)
		assert(err == .NONE, "I/O failed while draining message WAL leases")
	}
	for &store in registry.stores {if !shutdown_message_store(&store) do ok = false}
	delete(registry.sealed_index_cache.entries); delete(registry.sealed_wal_cache.entries); delete(registry.stores); registry^ = {}; return ok
}
