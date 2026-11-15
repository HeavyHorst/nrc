package main

// Workspace and conversation registries still use worker-owned maps.
state_map_set :: proc(m: ^map[$K]$V, key: K, value: V) {
	_, value_ptr, _ := map_upsert(m, key, value)
	if value_ptr == nil do panic("failed to insert state map entry")
}
