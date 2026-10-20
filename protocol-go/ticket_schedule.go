package protocol

import (
	"encoding/json"
	"fmt"
	"strconv"
)

// ValidTicketPriority accepts explicit wire priorities, not the absent default.
func ValidTicketPriority(v string) bool {
	return v == "low" || v == "normal" || v == "high" || v == "urgent"
}

func EffectiveTicketPriority(v string) string {
	if v == "" {
		return "normal"
	}
	return v
}

// ValidTicketFollowUp accepts an unset value or canonical positive Unix milliseconds.
func ValidTicketFollowUp(v string) bool {
	if v == "" {
		return true
	}
	n, err := strconv.ParseInt(v, 10, 64)
	return err == nil && n > 0 && strconv.FormatInt(n, 10) == v
}

// ValidateTicketScheduling validates only optional scheduling fields, preserving
// compatibility with legacy previews and leaving unknown fields untouched.
func ValidateTicketScheduling(m map[string]json.RawMessage) error {
	for _, key := range []string{"priority", "follow_up_at"} {
		raw, ok := m[key]
		if !ok {
			continue
		}
		var v string
		if string(raw) == "null" || json.Unmarshal(raw, &v) != nil ||
			(key == "priority" && !ValidTicketPriority(v)) ||
			(key == "follow_up_at" && !ValidTicketFollowUp(v)) {
			return fmt.Errorf("invalid ticket %s", key)
		}
	}
	return nil
}
