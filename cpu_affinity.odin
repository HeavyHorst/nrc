//
// cpu_affinity.odin - CPU Core Affinity Management
//
// This file provides CPU core pinning functionality for worker threads to:
// - Improve cache locality by keeping threads on specific cores
// - Reduce context switching overhead
// - Provide more predictable performance characteristics
// - Detect SMT, hybrid-core, die, and NUMA topology for role placement/logging
//
package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

Cpu_Core_Class :: enum {
	Unknown,
	Efficiency,
	Performance,
}

Cpu_Topology_Entry :: struct {
	cpu:        int,
	package_id: int,
	die_id:     int,
	core_id:    int,
	numa_node:  int,
	capacity:   int,
	core_class: Cpu_Core_Class,
}

Cpu_Topology :: struct {
	entries:                [1024]Cpu_Topology_Entry,
	entry_count:            int,
	physical_core_count:    int,
	numa_node_count:        int,
	performance_core_count: int,
	efficiency_core_count:  int,
	complete:               bool,
}

Cpu_Role_Plan :: struct {
	allowed_cpus:           [1024]int,
	allowed_cpu_count:      int,
	worker_cpu_count:       int,
	service_cpu:            int,
	physical_core_count:    int,
	numa_node_count:        int,
	performance_cores:      int,
	efficiency_cores:       int,
	dedicated_service_core: bool,
	topology_aware:         bool,
}

cpu_role_plan: Cpu_Role_Plan

build_cpu_role_plan :: proc(allowed_cpus: []int, worker_count: int) -> Cpu_Role_Plan {
	plan := Cpu_Role_Plan {
		service_cpu = -1,
	}
	plan.allowed_cpu_count = min(len(allowed_cpus), len(plan.allowed_cpus))
	copy(plan.allowed_cpus[:plan.allowed_cpu_count], allowed_cpus[:plan.allowed_cpu_count])
	if plan.allowed_cpu_count == 0 {
		return plan
	}

	plan.worker_cpu_count = min(plan.allowed_cpu_count, max(worker_count, 1))
	plan.service_cpu = plan.allowed_cpus[plan.allowed_cpu_count - 1]

	// A single-CPU machine must keep one CPU available to every role.
	if plan.worker_cpu_count == 0 {
		plan.worker_cpu_count = 1
		plan.dedicated_service_core = false
	}
	return plan
}

cpu_topology_same_core :: #force_inline proc(a, b: Cpu_Topology_Entry) -> bool {
	return a.package_id == b.package_id && a.die_id == b.die_id && a.core_id == b.core_id
}

cpu_topology_is_primary_thread :: proc(entries: []Cpu_Topology_Entry, index: int) -> bool {
	for previous in 0 ..< index {
		if cpu_topology_same_core(entries[previous], entries[index]) do return false
	}
	return true
}

cpu_topology_finalize :: proc(topology: ^Cpu_Topology) {
	if topology == nil do return
	topology.physical_core_count = 0
	topology.numa_node_count = 0
	topology.performance_core_count = 0
	topology.efficiency_core_count = 0

	min_capacity, max_capacity := max(int), 0
	for entry in topology.entries[:topology.entry_count] {
		if entry.capacity > 0 {
			min_capacity = min(min_capacity, entry.capacity)
			max_capacity = max(max_capacity, entry.capacity)
		}
	}
	if max_capacity > 0 && min_capacity < max_capacity {
		for &entry in topology.entries[:topology.entry_count] {
			entry.core_class = entry.capacity == max_capacity ? .Performance : .Efficiency
		}
	}

	entries := topology.entries[:topology.entry_count]
	for entry, i in entries {
		if cpu_topology_is_primary_thread(entries, i) {
			topology.physical_core_count += 1
			switch entry.core_class {
			case .Performance:
				topology.performance_core_count += 1
			case .Efficiency:
				topology.efficiency_core_count += 1
			case .Unknown:
			}
		}
		node_seen := false
		for previous in 0 ..< i {
			if entries[previous].numa_node == entry.numa_node do node_seen = true
		}
		if !node_seen do topology.numa_node_count += 1
	}
}

build_topology_cpu_role_plan :: proc(topology: ^Cpu_Topology, worker_count: int, service_cpu_override := -1) -> Cpu_Role_Plan {
	if topology == nil || !topology.complete || topology.entry_count == 0 {
		allowed: [1024]int
		count := 0
		if topology != nil {
			count = topology.entry_count
			for entry, i in topology.entries[:count] do allowed[i] = entry.cpu
		}
		// Without physical topology we can still honor an allowed service CPU by
		// moving it to the fallback plan's service slot. We cannot claim that its
		// SMT siblings are isolated in this mode.
		if service_cpu_override >= 0 {
			for cpu, i in allowed[:count] {
				if cpu == service_cpu_override {
					allowed[i], allowed[count - 1] = allowed[count - 1], allowed[i]
					break
				}
			}
		}
		return build_cpu_role_plan(allowed[:count], worker_count)
	}

	entries := topology.entries[:topology.entry_count]
	plan := Cpu_Role_Plan {
		allowed_cpu_count   = topology.entry_count,
		physical_core_count = topology.physical_core_count,
		numa_node_count     = topology.numa_node_count,
		performance_cores   = topology.performance_core_count,
		efficiency_cores    = topology.efficiency_core_count,
		topology_aware      = true,
		service_cpu         = -1,
	}

	service_index := -1
	if service_cpu_override >= 0 {
		for entry, i in entries {
			if entry.cpu == service_cpu_override {
				service_index = i
				break
			}
		}
	}

	// Main/auth and compaction can both be CPU-heavy. Prefer a P-core for the
	// service role, then an unclassified core, and use an E-core only when that
	// is all the allowed cpuset contains.
	classes := [3]Cpu_Core_Class{.Performance, .Unknown, .Efficiency}
	if service_index < 0 {
		for class in classes {
			for entry, i in entries {
				if cpu_topology_is_primary_thread(entries, i) && entry.core_class == class {
					service_index = i
				}
			}
			if service_index >= 0 do break
		}
	}
	if service_index < 0 do service_index = 0
	plan.service_cpu = entries[service_index].cpu
	plan.dedicated_service_core = topology.physical_core_count > 1

	worker_candidates: [1024]int
	candidate_count := 0
	// Fill one scheduling thread per physical core first (P, unknown, E), then
	// add SMT siblings in the same class order. The complete service core is
	// excluded unless it is the only physical core available.
	primary_passes := [2]bool{true, false}
	for primary in primary_passes {
		for class in classes {
			for entry, i in entries {
				is_primary := cpu_topology_is_primary_thread(entries, i)
				if is_primary != primary || entry.core_class != class do continue
				if plan.dedicated_service_core && cpu_topology_same_core(entry, entries[service_index]) do continue
				if !plan.dedicated_service_core && entry.cpu == plan.service_cpu do continue
				worker_candidates[candidate_count] = entry.cpu
				candidate_count += 1
			}
		}
	}
	// With one physical core but multiple allowed SMT threads, keep main and the
	// first worker on separate scheduling threads. They still share the core's
	// execution resources, but need not time-slice on one logical CPU.
	if !plan.dedicated_service_core && candidate_count > 0 {
		worker_candidates[candidate_count] = plan.service_cpu
		candidate_count += 1
	}

	if candidate_count == 0 {
		worker_candidates[0] = plan.service_cpu
		candidate_count = 1
		plan.dedicated_service_core = false
	}
	plan.worker_cpu_count = min(candidate_count, max(worker_count, 1))
	copy(plan.allowed_cpus[:plan.worker_cpu_count], worker_candidates[:plan.worker_cpu_count])
	return plan
}

cpu_role_worker_cpu :: proc(plan: ^Cpu_Role_Plan, worker_index: int) -> int {
	if plan == nil || plan.worker_cpu_count <= 0 || worker_index < 0 {
		return -1
	}
	return plan.allowed_cpus[worker_index % plan.worker_cpu_count]
}

cpu_affinity_disabled :: proc() -> bool {
	value := os.get_env_alloc("NRC_DISABLE_CPU_AFFINITY", context.allocator)
	defer delete(value)
	return value == "1"
}

when ODIN_OS == .Linux {
	// Foreign function interface to Linux pthread_setaffinity_np
	foreign import libc "system:pthread"

	// CPU set size - Linux typically uses 1024 bits for CPU sets
	CPU_SETSIZE :: 1024
	CPU_SET_T_SIZE :: CPU_SETSIZE / 8 // 128 bytes

	// Opaque CPU set type (actual implementation is a bitset)
	cpu_set_t :: struct {
		__bits: [CPU_SET_T_SIZE / size_of(c.ulong)]c.ulong,
	}

	foreign libc {
		pthread_setaffinity_np :: proc(thread: posix.pthread_t, cpusetsize: c.size_t, cpuset: ^cpu_set_t) -> c.int ---
	}

	// CPU set manipulation macros implemented as procedures
	cpu_zero :: proc(set: ^cpu_set_t) {
		for i in 0 ..< len(set.__bits) {
			set.__bits[i] = 0
		}
	}

	cpu_set :: proc(cpu: c.int, set: ^cpu_set_t) {
		if cpu >= 0 && cpu < CPU_SETSIZE {
			word_index := cpu / (8 * size_of(c.ulong))
			bit_index := cpu % (8 * size_of(c.ulong))
			set.__bits[word_index] |= c.ulong(1) << c.ulong(bit_index)
		}
	}

	cpu_isset :: proc(cpu: c.int, set: ^cpu_set_t) -> bool {
		if cpu >= 0 && cpu < CPU_SETSIZE {
			word_index := cpu / (8 * size_of(c.ulong))
			bit_index := cpu % (8 * size_of(c.ulong))
			return (set.__bits[word_index] & (c.ulong(1) << c.ulong(bit_index))) != 0
		}
		return false
	}

	read_cpu_sysfs_int :: proc(path: string) -> (int, bool) {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil do return 0, false
		defer delete(data)
		value, ok := strconv.parse_int(strings.trim_space(string(data)))
		return int(value), ok
	}

	detect_cpu_topology :: proc() -> Cpu_Topology {
		cpuset: cpu_set_t
		cpuset_size, err := linux.sched_getaffinity(0, size_of(cpu_set_t), &cpuset)
		if err != .NONE {
			log.warnf("Failed to read process CPU affinity (errno: %v); worker pinning disabled", err)
			return {}
		}

		topology := Cpu_Topology {
			complete = true,
		}
		cpu_limit := min(CPU_SETSIZE, cpuset_size * 8)
		for cpu in 0 ..< cpu_limit {
			if !cpu_isset(c.int(cpu), &cpuset) do continue
			entry := &topology.entries[topology.entry_count]
			entry.cpu = cpu
			entry.numa_node = 0
			package_path := fmt.tprintf("/sys/devices/system/cpu/cpu%d/topology/physical_package_id", cpu)
			die_path := fmt.tprintf("/sys/devices/system/cpu/cpu%d/topology/die_id", cpu)
			core_path := fmt.tprintf("/sys/devices/system/cpu/cpu%d/topology/core_id", cpu)
			package_id, package_ok := read_cpu_sysfs_int(package_path)
			die_id, _ := read_cpu_sysfs_int(die_path)
			core_id, core_ok := read_cpu_sysfs_int(core_path)
			entry.package_id = package_id
			entry.die_id = die_id
			entry.core_id = core_id
			if !package_ok || !core_ok do topology.complete = false
			capacity_path := fmt.tprintf("/sys/devices/system/cpu/cpu%d/cpu_capacity", cpu)
			entry.capacity, _ = read_cpu_sysfs_int(capacity_path)
			topology.entry_count += 1
		}
		// NUMA node IDs are normally compact but need not match package IDs.
		// Probe nodes once, then assign every allowed CPU found under that node.
		MAX_NUMA_NODES_TO_PROBE :: 256
		for node in 0 ..< MAX_NUMA_NODES_TO_PROBE {
			node_root := fmt.tprintf("/sys/devices/system/node/node%d", node)
			if !os.exists(node_root) do continue
			for &entry in topology.entries[:topology.entry_count] {
				node_cpu_path := fmt.tprintf("/sys/devices/system/cpu/cpu%d/node%d", entry.cpu, node)
				if os.exists(node_cpu_path) do entry.numa_node = node
			}
		}

		cpu_topology_finalize(&topology)
		return topology
	}

	// Set CPU affinity for the calling thread to a specific core
	set_thread_cpu_affinity :: proc(core_id: int) -> bool {
		if core_id < 0 {
			log.warnf("Invalid core_id %d, skipping CPU affinity", core_id)
			return false
		}

		// Create and initialize CPU set
		cpuset: cpu_set_t
		cpu_zero(&cpuset)
		cpu_set(c.int(core_id), &cpuset)

		// Get current thread handle and set affinity
		current_thread := posix.pthread_self()
		result := pthread_setaffinity_np(current_thread, size_of(cpu_set_t), &cpuset)

		if result == 0 {
			when ODIN_DEBUG do debug_log("Successfully pinned thread to CPU core %d", core_id)
			return true
		} else {
			log.warnf("Failed to set CPU affinity to core %d (errno: %d)", core_id, result)
			return false
		}
	}

} else {
	detect_cpu_topology :: proc() -> Cpu_Topology {
		return {}
	}

	// Stub implementation for non-Linux platforms
	set_thread_cpu_affinity :: proc(core_id: int) -> bool {
		log.warnf("CPU affinity not supported on %v, skipping", ODIN_OS)
		return false
	}
}
