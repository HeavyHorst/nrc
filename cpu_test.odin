package main

import "core:testing"

cpu_test_topology_entry :: proc(cpu, core_id: int, core_class := Cpu_Core_Class.Unknown, numa_node := 0, die_id := 0, capacity := 0) -> Cpu_Topology_Entry {
	return {cpu = cpu, package_id = 0, die_id = die_id, core_id = core_id, numa_node = numa_node, capacity = capacity, core_class = core_class}
}

@(test)
test_default_worker_count_reserves_service_cpu_except_on_single_core :: proc(t: ^testing.T) {
	testing.expect_value(t, default_worker_thread_count(1), 1)
	testing.expect_value(t, default_worker_thread_count(2), 1)
	testing.expect_value(t, default_worker_thread_count(8), 7)
	testing.expect_value(t, default_worker_thread_count(258), MAX_SERVER_WORKER_COUNT)
}

@(test)
test_cpu_role_plan_reserves_spare_service_cpu :: proc(t: ^testing.T) {
	allowed := [3]int{2, 4, 9}
	plan := build_cpu_role_plan(allowed[:], 2)

	testing.expect_value(t, plan.allowed_cpu_count, 3)
	testing.expect_value(t, plan.worker_cpu_count, 2)
	testing.expect_value(t, plan.service_cpu, 9)
	testing.expect_value(t, plan.dedicated_service_core, false)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 0), 2)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 1), 4)
}

@(test)
test_cpu_role_plan_single_cpu_fallback :: proc(t: ^testing.T) {
	allowed := [1]int{7}
	plan := build_cpu_role_plan(allowed[:], 1)

	testing.expect_value(t, plan.worker_cpu_count, 1)
	testing.expect_value(t, plan.service_cpu, 7)
	testing.expect_value(t, plan.dedicated_service_core, false)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 0), 7)
}

@(test)
test_cpu_role_plan_never_uses_disallowed_cpu :: proc(t: ^testing.T) {
	allowed := [2]int{3, 11}
	plan := build_cpu_role_plan(allowed[:], 4)

	testing.expect_value(t, plan.dedicated_service_core, false)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 0), 3)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 1), 11)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 2), 3)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 3), 11)
}

@(test)
test_incomplete_topology_fallback_honors_allowed_service_override :: proc(t: ^testing.T) {
	topology := Cpu_Topology {
		entry_count = 3,
		complete    = false,
	}
	topology.entries[0].cpu = 2
	topology.entries[1].cpu = 4
	topology.entries[2].cpu = 9

	plan := build_topology_cpu_role_plan(&topology, 2, 4)
	testing.expect_value(t, plan.service_cpu, 4)
	testing.expect_value(t, plan.topology_aware, false)
	testing.expect_value(t, plan.dedicated_service_core, false)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 0), 2)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 1), 9)
}

@(test)
test_topology_plan_reserves_whole_p_core_and_uses_physical_cores_before_smt :: proc(t: ^testing.T) {
	topology := Cpu_Topology {
		entry_count            = 6,
		physical_core_count    = 4,
		numa_node_count        = 2,
		performance_core_count = 2,
		efficiency_core_count  = 2,
		complete               = true,
	}
	topology.entries[0] = cpu_test_topology_entry(0, 0, .Performance)
	topology.entries[1] = cpu_test_topology_entry(1, 0, .Performance)
	topology.entries[2] = cpu_test_topology_entry(2, 1, .Performance)
	topology.entries[3] = cpu_test_topology_entry(3, 1, .Performance)
	topology.entries[4] = cpu_test_topology_entry(4, 2, .Efficiency, numa_node = 1)
	topology.entries[5] = cpu_test_topology_entry(5, 3, .Efficiency, numa_node = 1)

	plan := build_topology_cpu_role_plan(&topology, 4)
	testing.expect_value(t, plan.service_cpu, 2)
	testing.expect_value(t, plan.dedicated_service_core, true)
	testing.expect_value(t, plan.physical_core_count, 4)
	testing.expect_value(t, plan.numa_node_count, 2)
	// CPU 3 is the SMT sibling of the service CPU and must never be a worker.
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 0), 0)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 1), 4)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 2), 5)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 3), 1)
}

@(test)
test_topology_plan_service_override_excludes_overridden_core :: proc(t: ^testing.T) {
	topology := Cpu_Topology {
		entry_count            = 4,
		physical_core_count    = 3,
		performance_core_count = 2,
		efficiency_core_count  = 1,
		numa_node_count        = 1,
		complete               = true,
	}
	topology.entries[0] = cpu_test_topology_entry(0, 0, .Performance)
	topology.entries[1] = cpu_test_topology_entry(1, 0, .Performance)
	topology.entries[2] = cpu_test_topology_entry(2, 1, .Performance)
	topology.entries[3] = cpu_test_topology_entry(4, 2, .Efficiency)

	plan := build_topology_cpu_role_plan(&topology, 2, 4)
	testing.expect_value(t, plan.service_cpu, 4)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 0), 0)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 1), 2)
}

@(test)
test_topology_plan_single_physical_core_shares_smt_threads :: proc(t: ^testing.T) {
	topology := Cpu_Topology {
		entry_count         = 2,
		physical_core_count = 1,
		numa_node_count     = 1,
		complete            = true,
	}
	topology.entries[0] = cpu_test_topology_entry(7, 3)
	topology.entries[1] = cpu_test_topology_entry(9, 3)

	plan := build_topology_cpu_role_plan(&topology, 2)
	testing.expect_value(t, plan.service_cpu, 7)
	testing.expect_value(t, plan.dedicated_service_core, false)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 0), 9)
	testing.expect_value(t, cpu_role_worker_cpu(&plan, 1), 7)
}

@(test)
test_topology_capacity_classification_and_die_identity :: proc(t: ^testing.T) {
	topology := Cpu_Topology {
		entry_count = 4,
		complete    = true,
	}
	topology.entries[0] = cpu_test_topology_entry(0, 0, capacity = 1024)
	topology.entries[1] = cpu_test_topology_entry(1, 0, capacity = 1024)
	// Repeated core_id on another die must remain a distinct physical core.
	topology.entries[2] = cpu_test_topology_entry(2, 0, numa_node = 1, die_id = 1, capacity = 512)
	topology.entries[3] = cpu_test_topology_entry(3, 1, numa_node = 1, die_id = 1, capacity = 512)

	cpu_topology_finalize(&topology)
	testing.expect_value(t, topology.physical_core_count, 3)
	testing.expect_value(t, topology.numa_node_count, 2)
	testing.expect_value(t, topology.performance_core_count, 1)
	testing.expect_value(t, topology.efficiency_core_count, 2)
	testing.expect_value(t, topology.entries[0].core_class, Cpu_Core_Class.Performance)
	testing.expect_value(t, topology.entries[1].core_class, Cpu_Core_Class.Performance)
	testing.expect_value(t, topology.entries[2].core_class, Cpu_Core_Class.Efficiency)
}

@(test)
test_cpu_name_extraction :: proc(t: ^testing.T) {
	sample_cpuinfo := `processor	: 0
vendor_id	: GenuineIntel
cpu family	: 6
model		: 158
model name	: Intel(R) Core(TM) i7-8700K CPU @ 3.70GHz
stepping	: 10
microcode	: 0xde
cpu MHz		: 3700.000
cache size	: 12288 KB
physical id	: 0
siblings	: 12
core id		: 0
cpu cores	: 6
apicid		: 0
initial apicid	: 0
fpu		: yes
fpu_exception	: yes
cpuid level	: 22
wp		: yes`


	name, found := parse_cpu_model_name(sample_cpuinfo)
	testing.expect(t, found, "Should find model name")
	testing.expect_value(t, name, "Intel(R) Core(TM) i7-8700K CPU @ 3.70GHz")
}

@(test)
test_cpu_name_extraction_missing :: proc(t: ^testing.T) {
	sample_cpuinfo := `processor	: 0
vendor_id	: GenuineIntel
cpu family	: 6`


	_, found := parse_cpu_model_name(sample_cpuinfo)
	testing.expect(t, !found, "Should not find model name")
}

@(test)
test_cpu_name_extraction_amd_soc :: proc(t: ^testing.T) {
	sample_cpuinfo := `processor	: 0
vendor_id	: AuthenticAMD
cpu family	: 22
model		: 0
model name	: AMD GX-217GA SOC with Radeon(tm) HD Graphics
stepping	: 1
microcode	: 0x700010f`


	name, found := parse_cpu_model_name(sample_cpuinfo)
	testing.expect(t, found, "Should find model name for AMD SOC")
	testing.expect_value(t, name, "AMD GX-217GA SOC with Radeon(tm) HD Graphics")
}
