// auth.odin - Authentication and user identity helpers
//
// This file provides user identity management for connections authenticated via proxy-issued JWTs.
//
package main

// Get effective display identity for a connection.
// Authenticated users resolve to verified_username
// (JWT username for humans, validated service nickname for bots/system/admin).
get_connection_nickname :: proc(c: ^NRC_Connection) -> string {
	return c.verified_username
}

// Helper to check if connection is authenticated
is_connection_authenticated :: proc(c: ^NRC_Connection) -> bool {
	return c.authenticated
}
