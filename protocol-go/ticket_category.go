package protocol

// Empty is unclassified; unclear is an explicit category, including when manual.
func ValidTicketCategory(value string) bool {
	switch value {
	case "", "bug", "support", "feature", "unclear":
		return true
	default:
		return false
	}
}
