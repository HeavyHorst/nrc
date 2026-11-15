package main

when NRC_SIMULATION {
	handler_equivalence_deliver_wire :: proc(sim: ^Sim_Runtime, client: ^NRC_Connection, payload: []byte, split_selector_a, split_selector_b: int) -> bool {
		frame := make_test_ws_frame(payload, .opBinary, true)
		defer delete(frame)
		if len(frame) < 3 do return false
		first := 1 + split_selector_a % (len(frame) - 1)
		second := 1 + split_selector_b % (len(frame) - 1)
		if first == second {
			second = first == len(frame) - 1 ? first - 1 : first + 1
		}
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(sim, client, frame[start:end]) do return false
		}
		nrc_sim_run_all_receives(sim)
		return true
	}
}
