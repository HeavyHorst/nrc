package main

import "core:strings"
import "core:testing"

init_dm_test_state :: proc() {
	td.thread_index = 99
	td.workspaces = make(map[string]^Workspace_State)
	strings.intern_init(&td.workspace_intern)
}

cleanup_dm_test_state :: proc() {
	cleanup_workspaces()
	strings.intern_destroy(&td.workspace_intern)
}

@(test)
test_dm_auth_index_tracks_authenticated_connections_unit :: proc(t: ^testing.T) {
	init_dm_test_state()
	defer cleanup_dm_test_state()

	ws := get_or_create_workspace("ws-auth-unit")
	username := intern_username("alice")

	on_user_connect(ws, username, false)
	testing.expect(t, !is_user_authenticated(ws, username), "unauthenticated connection should not mark user authenticated")

	on_user_connect(ws, username, true)
	testing.expect(t, is_user_authenticated(ws, username), "authenticated connection should mark user authenticated")

	on_user_disconnect(ws, username, false)
	testing.expect(t, is_user_authenticated(ws, username), "removing unauthenticated connection should not clear authenticated state")

	on_user_disconnect(ws, username, true)
	testing.expect(t, !is_user_authenticated(ws, username), "last authenticated connection should clear authenticated state")
}

@(test)
test_dm_auth_index_lifecycle_integration :: proc(t: ^testing.T) {
	init_dm_test_state()
	defer cleanup_dm_test_state()

	ws := get_or_create_workspace("ws-auth-e2e")
	username := intern_username("target-user")

	// Simulate three active connections for one user: two authenticated and one unauthenticated.
	on_user_connect(ws, username, true)
	on_user_connect(ws, username, true)
	on_user_connect(ws, username, false)

	testing.expect(t, find_user_in_workspace(ws, username), "user should exist while connected")
	testing.expect(t, is_user_online(ws, username), "user should be online while connected")
	testing.expect(t, is_user_authenticated(ws, username), "user should be authenticated while any authenticated connection exists")

	on_user_disconnect(ws, username, true)
	testing.expect(t, is_user_authenticated(ws, username), "one remaining authenticated connection should keep authenticated=true")
	testing.expect(t, is_user_online(ws, username), "user should remain online after one disconnect")

	on_user_disconnect(ws, username, true)
	testing.expect(t, !is_user_authenticated(ws, username), "no authenticated connections should set authenticated=false")
	testing.expect(t, is_user_online(ws, username), "unauthenticated connection should still keep user online")

	on_user_disconnect(ws, username, false)
	testing.expect(t, !is_user_online(ws, username), "user should be offline after all connections disconnect")
	testing.expect(t, !find_user_in_workspace(ws, username), "user should no longer exist in workspace when fully disconnected")
}
