package main

import "core:c"
import "core:log"
import "core:testing"

when ODIN_OS == .Linux {
	@(default_calling_convention = "c")
	foreign _ {
		@(link_name = "getpagesize")
		test_getpagesize :: proc() -> c.int ---
	}
}

@(test)
test_getpagesize_returns_valid_value :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		page_size := int(test_getpagesize())

		testing.expectf(t, page_size > 0, "page size should be positive, got %d", page_size)
		testing.expectf(t, page_size >= 4096, "page size should be at least 4KB, got %d", page_size)
		testing.expectf(t, page_size <= 65536, "page size should be at most 64KB, got %d", page_size)

		is_power_of_two := (page_size & (page_size - 1)) == 0
		testing.expect(t, is_power_of_two, "page size should be a power of 2")

		log.infof("System page size: %d bytes", page_size)
	}
}

@(test)
test_rss_calculation_with_page_size :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		page_size := int(test_getpagesize())

		pages := 1024
		bytes := pages * page_size
		mb := bytes / (1024 * 1024)

		if page_size == 4096 {
			testing.expectf(t, mb == 4, "1024 pages @ 4KB = 4MB, got %d", mb)
		} else if page_size == 16384 {
			testing.expectf(t, mb == 16, "1024 pages @ 16KB = 16MB, got %d", mb)
		} else if page_size == 65536 {
			testing.expectf(t, mb == 64, "1024 pages @ 64KB = 64MB, got %d", mb)
		}

		log.infof("1024 pages @ %d bytes = %d MB", page_size, mb)
	}
}
