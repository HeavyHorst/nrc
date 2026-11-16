package monitoring

import "core:testing"

@(test)
test_independent_episodes_and_consecutive_thresholds :: proc(t: ^testing.T) {
	policy := Policy {
		failures    = 5,
		recoveries  = 2,
		missing     = 3,
		stale_after = 190,
	}
	a, b: Instance
	for sequence in u64(1) ..= 5 {
		changes, result := evaluate(&a, policy, {sequence, i64(sequence), .Failing, 7.25})
		testing.expect_value(t, result, .Applied)
		testing.expect(t, (.Opened in changes) == (sequence == 5))
		evaluate(&b, policy, {sequence, i64(sequence), .Passing, 42})
	}
	testing.expect(t, a.incident_open && a.episode == 1 && !b.incident_open && b.episode == 0)
	changes, _ := evaluate(&a, policy, {6, 6, .Passing, 18})
	testing.expect(t, a.incident_open && changes == {})
	evaluate(&a, policy, {7, 7, .Between, 12})
	evaluate(&a, policy, {8, 8, .Passing, 19})
	testing.expect(t, a.incident_open, "hysteresis band interrupts recovery streak")
	changes, _ = evaluate(&a, policy, {9, 9, .Passing, 20})
	testing.expect(t, .Recovered in changes && !a.incident_open)
	for sequence in u64(10) ..= 14 {evaluate(&a, policy, {sequence, i64(sequence), .Failing, 6})}
	testing.expect(t, a.incident_open && a.episode == 2, "a later failure creates a new episode")
	testing.expect(t, !b.incident_open && b.last_value == 42)
}

@(test)
test_missing_and_errors_never_recover :: proc(t: ^testing.T) {
	policy := Policy{2, 2, 3, 190}
	s: Instance
	evaluate(&s, policy, {1, 1, .Failing, 6})
	evaluate(&s, policy, {2, 2, .Evaluation_Error, 0})
	evaluate(&s, policy, {3, 3, .Failing, 5})
	testing.expect(t, !s.incident_open && s.failures == 1)
	evaluate(&s, policy, {4, 4, .Failing, 4})
	evaluate(&s, policy, {5, 5, .Passing, 19})
	for sequence in u64(6) ..= 8 {
		changes, result := evaluate(&s, policy, {sequence, i64(sequence), .Absent, 999})
		testing.expect(t, result == .Applied && changes == {} && s.incident_open)
		testing.expect_value(t, s.freshness, sequence == 8 ? .No_Data : .Missing)
		testing.expect_value(t, s.last_observation, .Absent)
	}
	testing.expect(t, s.last_value == 19 && s.last_seen_at == 5 && s.recoveries == 0)
	evaluate(&s, policy, {9, 9, .Evaluation_Error, 0})
	testing.expect_value(t, s.last_observation, .Evaluation_Error)
	testing.expect(t, s.missing == 0 && s.freshness == .Evaluation_Error && s.incident_open)
	evaluate(&s, policy, {10, 10, .Passing, 22})
	testing.expect(t, s.incident_open && s.recoveries == 1)
	changes, _ := evaluate(&s, policy, {11, 11, .Passing, 23})
	testing.expect(t, .Recovered in changes && !s.incident_open)
}

@(test)
test_stale_boundary_pause_and_retirement :: proc(t: ^testing.T) {
	policy, valid := default_policy(60, 10)
	testing.expect(t, valid && policy.stale_after == 190)
	s: Instance
	for sequence in u64(1) ..= 5 {evaluate(&s, policy, {sequence, i64(sequence), .Failing, 3})}
	testing.expect(t, !mark_stale(&s, policy, 194))
	testing.expect(t, mark_stale(&s, policy, 195))
	testing.expect(t, s.incident_open && s.freshness == .No_Data && s.failures == 0 && s.last_value == 3)
	testing.expect(t, !mark_stale(&s, policy, 196))
	set_paused(&s, true)
	before := s
	_, result := evaluate(&s, policy, {6, 200, .Passing, 90})
	testing.expect(t, result == .Ignored && s == before)
	set_paused(&s, false)
	testing.expect(t, s.incident_open && s.freshness == .Unknown)
	testing.expect_value(t, retire(&s), Changes{.Removed})
	testing.expect(t, s.retired && !s.incident_open && s.episode == 1)
	testing.expect_value(t, retire(&s), Changes{})
	before = s
	for observation in ([]Observation{.Absent, .Evaluation_Error}) {
		_, result = evaluate(&s, policy, {6, 201, observation, 0})
		testing.expect(t, result == .Ignored && s == before)
	}
	changes, _ := evaluate(&s, policy, {6, 202, .Failing, 2})
	testing.expect(t, changes == {.Reactivated} && s.failures == 1 && !s.incident_open && s.episode == 1)
	for sequence in u64(7) ..= 10 {evaluate(&s, policy, {sequence, 202 + i64(sequence), .Failing, 1})}
	testing.expect(t, s.incident_open && s.episode == 2)
}

@(test)
test_rejected_evaluations_leave_state_unchanged :: proc(t: ^testing.T) {
	policy := Policy{2, 3, 3, 190}
	s: Instance
	evaluate(&s, policy, {10, 100, .Failing, 6})
	before := s
	for evaluation in ([]Evaluation{{10, 100, .Failing, 6}, {9, 99, .Passing, 99}}) {
		changes, result := evaluate(&s, policy, evaluation)
		testing.expect(t, result == .Ignored && changes == {} && s == before)
	}
	for evaluation in ([]Evaluation{{11, 99, .Passing, 20}, {0, 101, .Failing, 1}, {11, 0, .Passing, 20}, {11, 101, Observation(99), 0}}) {
		changes, result := evaluate(&s, policy, evaluation)
		testing.expect(t, result == .Invalid && changes == {} && s == before)
	}
	bad_policy := policy
	bad_policy.failures = 0
	_, result := evaluate(&s, bad_policy, {11, 101, .Failing, 1})
	testing.expect(t, result == .Invalid && s == before)
	_, valid := default_policy(max(i64), 10)
	testing.expect(t, !valid)
}

@(test)
test_observation_after_unobserved_gap_restarts_streak :: proc(t: ^testing.T) {
	policy := Policy{2, 2, 3, 190}
	for elapsed in ([]i64{189, 190, 191}) {
		s: Instance
		evaluate(&s, policy, {1, 100, .Failing, 4})
		changes, _ := evaluate(&s, policy, {2, 100 + elapsed, .Failing, 3})
		testing.expect(t, s.incident_open == (elapsed < 190))
		testing.expect(t, (.Opened in changes) == (elapsed < 190))
		if elapsed >= 190 do testing.expect_value(t, s.failures, u32(1))
	}
}

@(test)
test_default_and_legacy_thresholds :: proc(t: ^testing.T) {
	for policy in ([]Policy{{1, 1, 3, 190}, {5, 5, 3, 190}, {60, 2, 3, 190}}) {
		s: Instance
		for sequence in u64(1) ..= u64(policy.failures) {
			changes, result := evaluate(&s, policy, {sequence, i64(sequence), .Failing, 7})
			testing.expect(t, result == .Applied)
			testing.expect(t, (.Opened in changes) == (sequence == u64(policy.failures)))
		}
		for index in u64(1) ..= u64(policy.recoveries) {
			sequence := u64(policy.failures) + index
			changes, result := evaluate(&s, policy, {sequence, i64(sequence), .Passing, 23})
			testing.expect(t, result == .Applied)
			testing.expect(t, (.Recovered in changes) == (index == u64(policy.recoveries)))
		}
		testing.expect(t, s.episode == 1 && !s.incident_open)
	}
}

@(test)
test_absence_preserves_elapsed_staleness :: proc(t: ^testing.T) {
	policy := Policy{1, 2, 3, 190}
	for elapsed in ([]i64{189, 190, 191}) {
		for maintenance in ([]bool{false, true}) {
			s: Instance
			evaluate(&s, policy, {1, 100, .Failing, 7.25})
			if maintenance do mark_stale(&s, policy, 100 + elapsed)
			changes, result := evaluate(&s, policy, {2, 100 + elapsed, .Absent, 0})
			testing.expect(t, result == .Applied && changes == {} && s.incident_open)
			testing.expect_value(t, s.freshness, elapsed < 190 ? .Missing : .No_Data)
			testing.expect(t, s.missing == 1 && s.last_value == 7.25 && s.last_seen_at == 100)
			testing.expect_value(t, s.last_observation, .Absent)
		}
	}
}
