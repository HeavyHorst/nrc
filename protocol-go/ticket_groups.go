package protocol

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// TicketGroup is an explicit, non-transitive sharing set on a CustomerCompany's
// version-1 preview. Members are decimal CustomerContact asset IDs, not emails.
// Every consumer must also verify current contact/company MemberOf edges.
type TicketGroup struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	ContactIDs []string `json:"contact_ids"`
}

// DecodeTicketGroups reads only the exact metadata keys. Missing groups mean
// private-by-default; malformed groups must never grant portal access.
func DecodeTicketGroups(preview string) ([]TicketGroup, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(preview), &m); err != nil || m == nil {
		return nil, fmt.Errorf("invalid company metadata")
	}
	var version int
	if json.Unmarshal(m["version"], &version) != nil || version != 1 {
		return nil, fmt.Errorf("unsupported company metadata version")
	}
	raw, ok := m["ticket_groups"]
	if !ok {
		return []TicketGroup{}, nil
	}
	var objects []map[string]json.RawMessage
	if json.Unmarshal(raw, &objects) != nil || objects == nil {
		return nil, fmt.Errorf("ticket_groups must be an array")
	}
	groups := make([]TicketGroup, 0, len(objects))
	for _, object := range objects {
		var g TicketGroup
		if len(object) != 3 || json.Unmarshal(object["id"], &g.ID) != nil || json.Unmarshal(object["name"], &g.Name) != nil || json.Unmarshal(object["contact_ids"], &g.ContactIDs) != nil || g.ContactIDs == nil {
			return nil, fmt.Errorf("invalid ticket group fields")
		}
		groups = append(groups, g)
	}
	return groups, ValidateTicketGroups(groups)
}

func ValidateTicketGroups(groups []TicketGroup) error {
	seen := map[string]bool{}
	for _, g := range groups {
		if g.ID == "" || len(g.ID) > 64 || seen[g.ID] || strings.TrimSpace(g.Name) != g.Name || g.Name == "" || len(g.Name) > 256 || !utf8.ValidString(g.Name) || strings.ContainsAny(g.Name, "\r\n\x00") {
			return fmt.Errorf("invalid or duplicate ticket group")
		}
		for _, c := range g.ID {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
				return fmt.Errorf("invalid ticket group ID")
			}
		}
		seen[g.ID] = true
		members := map[string]bool{}
		if g.ContactIDs == nil {
			return fmt.Errorf("ticket group contact_ids must be an array")
		}
		for _, id := range g.ContactIDs {
			n, err := strconv.ParseUint(id, 10, 64)
			if err != nil || n == 0 || strconv.FormatUint(n, 10) != id || members[id] {
				return fmt.Errorf("invalid or duplicate ticket group contact ID")
			}
			members[id] = true
		}
	}
	return nil
}
