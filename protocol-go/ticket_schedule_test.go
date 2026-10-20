package protocol

import (
	"encoding/json"
	"testing"
)

func TestTicketSchedulingContract(t *testing.T) {
	for _, tc := range []struct {
		wire  string
		valid bool
	}{
		{`{}`, true}, {`{"priority":"normal","follow_up_at":"1","future":true}`, true},
		{`{"priority":"urgent","follow_up_at":""}`, true},
		{`{"priority":""}`, false}, {`{"priority":null}`, false},
		{`{"follow_up_at":null}`, false}, {`{"follow_up_at":1}`, false},
		{`{"follow_up_at":"01"}`, false}, {`{"follow_up_at":"0"}`, false},
		{`{"follow_up_at":"-1"}`, false}, {`{"follow_up_at":"9223372036854775808"}`, false},
	} {
		var m map[string]json.RawMessage
		if err := json.Unmarshal([]byte(tc.wire), &m); err != nil {
			t.Fatal(err)
		}
		if err := ValidateTicketScheduling(m); (err == nil) != tc.valid {
			t.Errorf("%s: %v", tc.wire, err)
		}
	}
	if EffectiveTicketPriority("") != "normal" || EffectiveTicketPriority("urgent") != "urgent" {
		t.Fatal("effective priority")
	}
}
