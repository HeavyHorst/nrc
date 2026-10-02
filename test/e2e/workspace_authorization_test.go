package e2e

import (
	"net/http"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestWorkspaceScopedAuthorization(t *testing.T) {
	server := startServerInWorkDirWithEnv(t, t.TempDir(), map[string]string{
		"NRC_WORKSPACE_ACCESS": `{"alice-private":{"owner":"alice@example.com"}}`,
	})
	defer server.stop(t)
	header := func(username, workspace string) http.Header {
		t.Helper()
		token, err := buildProxyStyleJWT(username, time.Now(), workspace)
		if err != nil {
			t.Fatal(err)
		}
		return http.Header{"X-NRC-Auth": []string{token}}
	}
	connect := func(workspace, username string) *websocket.Conn {
		t.Helper()
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), header(username, workspace))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		mustSetReadDeadline(t, c, 5*time.Second)
		mustExpectServerReady(t, c)
		mustSubscribeWorkspaceData(t, c)
		return c
	}
	alice := connect("alice-private", "alice")
	bob := connect("workspace1", "bob")
	if err := sendProtocolMessage(alice, protocol.C_CreateTask, protocol.EncodeTaskCreate(0, "private title", "private contents", 1)); err != nil {
		t.Fatal(err)
	}
	created, err := protocol.DecodeTaskCreated(mustReadUntilOpcode(t, alice, protocol.S_TaskCreated, 16))
	if err != nil {
		t.Fatal(err)
	}

	// A token authorized for the open workspace cannot open a known private
	// workspace, and old unscoped tokens cannot bypass the proxy's decision.
	for _, headers := range []http.Header{header("bob", "workspace1"), header("bob", "")} {
		c, response, err := websocket.DefaultDialer.Dial(wsURLForWorkspace("alice-private"), headers)
		if c != nil {
			c.Close()
		}
		if err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("foreign/unscoped token accepted: response=%v err=%v", response, err)
		}
		response.Body.Close()
	}
	if err := sendProtocolMessage(bob, protocol.C_GetTask, protocol.EncodeGetTask(0, created.Task.ID, 41)); err != nil {
		t.Fatal(err)
	}
	foreign, err := protocol.DecodeTaskFull(mustReadUntilOpcode(t, bob, protocol.S_TaskFull, 16))
	if err == nil || foreign == nil || foreign.Success || foreign.Task != nil || foreign.ErrorMessage != "Task not found" {
		t.Fatalf("foreign task read: %+v err=%v", foreign, err)
	}
	if err := sendProtocolMessage(bob, protocol.C_UpdateTask, protocol.EncodeTaskUpdate(0, int64(created.Task.ID), "stolen", "changed", 1, 1, 0)); err != nil {
		t.Fatal(err)
	}
	mutation, err := protocol.DecodeTaskListResponse(mustReadUntilOpcode(t, bob, protocol.S_TaskListResponse, 16))
	if err == nil || mutation == nil || mutation.Success || mutation.ErrorMessage != "Task not found" {
		t.Fatalf("foreign mutation: %+v err=%v", mutation, err)
	}
	if err := sendProtocolMessage(alice, protocol.C_GetTask, protocol.EncodeGetTask(0, created.Task.ID, 42)); err != nil {
		t.Fatal(err)
	}
	unchanged, err := protocol.DecodeTaskFull(mustReadUntilOpcode(t, alice, protocol.S_TaskFull, 16))
	if err != nil || !unchanged.Success || unchanged.Task.Title != "private title" || unchanged.Task.Description != "private contents" {
		t.Fatalf("owner task changed: %+v err=%v", unchanged, err)
	}
}

func TestEmptyWorkspacePolicyKeepsLegacyAuthentication(t *testing.T) {
	for _, config := range []string{"{}", " \n{ \t } "} {
		server := startServerInWorkDirWithEnv(t, t.TempDir(), map[string]string{"NRC_WORKSPACE_ACCESS": config})
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace("workspace1"), mustAuthHeader(t, "legacy-user"))
		if err != nil {
			server.stop(t)
			t.Fatalf("empty policy %q rejected unscoped token: %v", config, err)
		}
		mustSetReadDeadline(t, c, 5*time.Second)
		mustExpectServerReady(t, c)
		c.Close()
		server.stop(t)
	}
}
