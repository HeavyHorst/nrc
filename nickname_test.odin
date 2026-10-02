package main

import "core:testing"

@(test)
test_is_nickname_valid_rejects_invalid :: proc(t: ^testing.T) {
	testing.expect(t, !is_nickname_valid(""), "empty nickname must be rejected")
	testing.expect(t, !is_nickname_valid("invalid name"), "spaces are not allowed")
	testing.expect(t, !is_nickname_valid("name!"), "special punctuation is not allowed")
}

@(test)
test_is_nickname_valid_accepts_expected :: proc(t: ^testing.T) {
	testing.expect(t, is_nickname_valid("agent"), "plain alphanumeric nickname should be valid")
	testing.expect(t, is_nickname_valid("agent_1.test-bot"), "allowed punctuation should be valid")
}
