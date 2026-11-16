// Instance evaluation owned by the NRC server, independent of storage and I/O.
package monitoring

Policy :: struct {
	failures:    u32,
	recoveries:  u32,
	missing:     u32,
	stale_after: i64, // Nanoseconds; normally three intervals plus request timeout.
}

default_policy :: proc(interval, timeout: i64) -> (Policy, bool) {
	if interval <= 0 || timeout < 0 || interval > (max(i64) - timeout) / 3 {
		return {}, false
	}
	return {5, 5, 3, 3 * interval + timeout}, true
}

Observation :: enum u8 {
	Passing,
	Failing,
	Between, // Valid value inside the hysteresis band; neither trigger nor recovery.
	Absent, // Only a successful, complete evaluation can establish absence.
	Evaluation_Error, // Includes incomplete query results; never establishes absence.
}

Freshness :: enum u8 {
	Unknown,
	Current,
	Missing,
	No_Data,
	Evaluation_Error,
}

Instance :: struct {
	last_sequence:                 u64,
	last_evaluated_at:             i64,
	last_seen_at:                  i64,
	last_value:                    f64,
	has_value:                     bool,
	last_observation:              Observation,
	freshness:                     Freshness,
	failures, recoveries, missing: u32,
	paused, retired:               bool,
	// A local episode ordinal, not an NRC asset ID. Persistence maps an opened
	// episode to its Incident asset atomically with the state transition.
	episode:                       u64,
	incident_open:                 bool,
}

Evaluation :: struct {
	sequence:    u64, // Strictly increasing per instance; assigned by the server/run contract.
	at:          i64, // Positive Unix nanoseconds, supplied by the caller.
	observation: Observation,
	value:       f64, // Used only for Passing, Failing and Between.
}

Change :: enum u8 {
	Reactivated,
	Opened,
	Recovered,
	Removed, // Closed because the target was retired, not because it recovered.
}
Changes :: bit_set[Change]

Result :: enum {
	Applied,
	Ignored, // Older/duplicate sequence, paused instance or absent retired instance.
	Invalid,
}

// Mutates one instance only. The caller must persist the state and returned
// events in the same transaction. This watermark is not a durable run receipt:
// conflicting duplicate payloads, identity and complete-run admission belong
// to the persistence/command layer, before calling evaluate.
evaluate :: proc(instance: ^Instance, policy: Policy, evaluation: Evaluation) -> (Changes, Result) {
	if policy.failures == 0 ||
	   policy.recoveries == 0 ||
	   policy.missing == 0 ||
	   policy.stale_after <= 0 ||
	   evaluation.sequence == 0 ||
	   evaluation.at <= 0 ||
	   evaluation.observation < min(Observation) ||
	   evaluation.observation > max(Observation) {
		return {}, .Invalid
	}
	if evaluation.sequence <= instance.last_sequence do return {}, .Ignored
	if evaluation.at < instance.last_evaluated_at do return {}, .Invalid
	present := evaluation.observation == .Passing || evaluation.observation == .Failing || evaluation.observation == .Between
	if present && (evaluation.value != evaluation.value || evaluation.value > max(f64) || evaluation.value < -max(f64)) {
		return {}, .Invalid
	}
	if instance.paused || (instance.retired && !present) do return {}, .Ignored
	// Work on a value copy so rejected changes cannot partially update counters.
	next := instance^
	changes: Changes
	// A maintenance tick may not have run during an outage. A new sample must
	// still break the old failure/recovery streak at the staleness boundary.
	if next.has_value && evaluation.at - next.last_seen_at >= policy.stale_after {
		next.failures, next.recoveries = 0, 0
	}
	if next.retired {
		next.retired = false
		reset_streaks(&next)
		changes += {.Reactivated}
	}
	next.last_sequence = evaluation.sequence
	next.last_evaluated_at = evaluation.at
	next.last_observation = evaluation.observation
	if present {
		next.has_value = true
		next.last_value = evaluation.value
		next.last_seen_at = evaluation.at
		next.freshness = .Current
		next.missing = 0
	} else {
		next.failures, next.recoveries = 0, 0
		if evaluation.observation == .Absent {
			if next.missing < policy.missing do next.missing += 1
			stale := next.has_value && evaluation.at - next.last_seen_at >= policy.stale_after
			next.freshness = next.missing >= policy.missing || stale ? .No_Data : .Missing
		} else {
			next.missing = 0
			next.freshness = .Evaluation_Error
		}
		instance^ = next
		return changes, .Applied
	}
	switch evaluation.observation {
	case .Failing:
		next.recoveries = 0
		if next.failures < policy.failures do next.failures += 1
		if next.failures >= policy.failures && !next.incident_open {
			if next.episode == max(u64) do return {}, .Invalid
			next.episode += 1
			next.incident_open = true
			changes += {.Opened}
		}
	case .Passing:
		next.failures = 0
		if next.incident_open {
			if next.recoveries < policy.recoveries do next.recoveries += 1
			if next.recoveries >= policy.recoveries {
				next.incident_open = false
				next.recoveries = 0
				changes += {.Recovered}
			}
		} else {
			next.recoveries = 0
		}
	case .Between:
		next.failures, next.recoveries = 0, 0
	case .Absent, .Evaluation_Error:
		unreachable()
	}
	instance^ = next
	return changes, .Applied
}

// Called by server maintenance even when the sidecar is unavailable. Retain
// the last value and incident, but never extend its freshness from an error.
mark_stale :: proc(instance: ^Instance, policy: Policy, now: i64) -> bool {
	// Resume requires a new observation, not an aging tick.
	if instance.paused ||
	   instance.retired ||
	   instance.freshness == .Unknown ||
	   !instance.has_value ||
	   policy.stale_after <= 0 ||
	   now < instance.last_seen_at ||
	   now - instance.last_seen_at < policy.stale_after {
		return false
	}
	if instance.freshness == .No_Data && instance.failures == 0 && instance.recoveries == 0 do return false
	instance.freshness = .No_Data
	instance.failures, instance.recoveries = 0, 0
	return true
}

// A pause never closes an episode. A resumed instance needs a new observation
// before it can be shown as current; old streaks do not survive the pause.
set_paused :: proc(instance: ^Instance, paused: bool) {
	if instance.paused == paused do return
	instance.paused = paused
	instance.freshness = .Unknown
	reset_streaks(instance)
}

retire :: proc(instance: ^Instance) -> Changes {
	if instance.retired do return {}
	instance.retired = true
	instance.freshness = .Unknown
	reset_streaks(instance)
	if instance.incident_open {
		instance.incident_open = false
		return {.Removed}
	}
	return {}
}

@(private)
reset_streaks :: proc(instance: ^Instance) {
	instance.failures, instance.recoveries, instance.missing = 0, 0, 0
}
