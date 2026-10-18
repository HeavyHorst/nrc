package protocol

import (
	"testing"
)

func TestTicketGroupMetadata(t *testing.T) {
	for _, tc := range []struct {
		name, preview string
		valid         bool
		count         int
	}{
		{"absent", `{"version":1,"title":"Company"}`, true, 0},
		{"empty", `{"version":1,"ticket_groups":[]}`, true, 0},
		{"large_ids", `{"version":1,"ticket_groups":[{"id":"team-1","name":"Technik","contact_ids":["18446744073709551615","42"]}]}`, true, 1},
		{"null", `{"version":1,"ticket_groups":null}`, false, 0},
		{"noncanonical", `{"version":1,"ticket_groups":[{"id":"team","name":"Tech","contact_ids":["042"]}]}`, false, 0},
		{"numeric_ids", `{"version":1,"ticket_groups":[{"id":"team","name":"Tech","contact_ids":[42]}]}`, false, 0},
		{"duplicate_contact", `{"version":1,"ticket_groups":[{"id":"team","name":"Tech","contact_ids":["42","42"]}]}`, false, 0},
		{"duplicate_group", `{"version":1,"ticket_groups":[{"id":"team","name":"Tech","contact_ids":[]},{"id":"team","name":"Other","contact_ids":[]}]}`, false, 0},
		{"wrong_case", `{"version":1,"ticket_groups":[{"id":"team","name":"Tech","Contact_IDs":["42"]}]}`, false, 0},
		{"future_version", `{"version":2,"ticket_groups":[]}`, false, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			groups, err := DecodeTicketGroups(tc.preview)
			if (err == nil) != tc.valid || tc.valid && len(groups) != tc.count {
				t.Fatal(groups, err)
			}
			if tc.name == "large_ids" && groups[0].ContactIDs[0] != "18446744073709551615" {
				t.Fatal("ID lost precision", groups)
			}
		})
	}
}
