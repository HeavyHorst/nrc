//
// cpu.odin - CPU Model and Usage tracking (Platform: Linux)
//
package main

import "core:log"
import "core:os"
import "core:strings"

// Global CPU Model Name (read once)
CPU_MODEL_NAME: string = "Unknown CPU"

parse_cpu_model_name :: proc(content: string) -> (string, bool) {
	c := content
	for line in strings.split_iterator(&c, "\n") {
		if strings.contains(line, "model name") {
			// Format: "model name	: Intel(R) Core(TM) i7-..."
			colon_idx := strings.index(line, ":")
			if colon_idx >= 0 && colon_idx + 1 < len(line) {
				return strings.trim_space(line[colon_idx + 1:]), true
			}
		}
	}
	return "", false
}

// Helper to read files like /proc/cpuinfo that report size 0
read_proc_file :: proc(path: string) -> ([]byte, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil, false
	}
	return data, true
}

init_cpu_info :: proc() {
	// Read CPU Model from /proc/cpuinfo
	data, ok := read_proc_file("/proc/cpuinfo")
	if ok {
		defer delete(data)
		content := string(data)
		when ODIN_DEBUG do debug_log("Read /proc/cpuinfo, size: %d bytes", len(data))

		if name, found := parse_cpu_model_name(content); found {
			CPU_MODEL_NAME = strings.clone(name)
			log.infof("CPU Model detected: %s", CPU_MODEL_NAME)
		} else {
			log.warn("Could not parse model name from /proc/cpuinfo")
		}
	} else {
		log.error("Failed to read /proc/cpuinfo")
	}
}
