package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	p "github.com/heavyhorst/nrc/protocol-go"
)

// A synthetic bcrypt encoding, never used as an actual account credential.
const testPortalHash = "$2a$12$....................................................."

func TestPortalAccountImportValidation(t *testing.T) {
	row := fmt.Sprintf(`{"login":"customer","requester":"customer@example.com","name":"Customer","company_id":"1","contact_id":"2","password_hash":%q}`, testPortalHash)
	for name, data := range map[string]string{
		"empty":             `[]`,
		"duplicate account": "[" + row + "," + row + "]",
		"duplicate key":     "[{\"login\":\"first\"," + row[1:] + "]",
		"plaintext field":   "[{\"password\":\"secret-marker\"," + row[1:] + "]",
		"null field":        "[" + strings.Replace(row, `"1"`, `null`, 1) + "]",
		"malformed hash":    "[" + strings.Replace(row, "$2a$12$.", "$2a$12$!", 1) + "]",
		"trailing document": "[" + row + "] []",
	} {
		t.Run(name, func(t *testing.T) {
			_, err := decodePortalAccountImport([]byte(data))
			if err == nil || strings.Contains(err.Error(), "secret-marker") || strings.Contains(err.Error(), "$2a$") {
				t.Fatal("expected a sanitized rejection")
			}
		})
	}
	path := filepath.Join(t.TempDir(), "accounts.json")
	if err := os.WriteFile(path, []byte("["+row+"]"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := readPortalAccountImport(path)
	if err != nil || len(got) != 1 || got[0].PasswordHash != testPortalHash {
		t.Fatal("valid protected file was not read:", err)
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := readPortalAccountImport(path); err == nil {
		t.Fatal("accepted a public file")
	}
	rows := make([]p.PortalAccount, p.PortalAccountImportLimit+1)
	for i := range rows {
		login := fmt.Sprintf("customer%d", i)
		rows[i] = p.PortalAccount{Login: login, Requester: login, Name: "Customer", PasswordHash: testPortalHash}
	}
	for _, n := range []int{p.PortalAccountImportLimit, len(rows)} {
		data, _ := json.Marshal(rows[:n])
		if _, err := decodePortalAccountImport(data); (err == nil) != (n == p.PortalAccountImportLimit) {
			t.Fatalf("unexpected result for row count %d: %v", n, err)
		}
	}
}

func TestPortalAccountWireAndRedaction(t *testing.T) {
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		account := p.PortalAccount{ID: "42", Revision: "23", Login: "customer", PasswordHash: testPortalHash}
		for {
			_, wire, err := c.ReadMessage()
			if err != nil {
				return
			}
			var q p.PortalAccountRequest
			if len(wire) < 6 || binary.BigEndian.Uint16(wire) != p.C_PortalAccount || json.Unmarshal(wire[2:len(wire)-4], &q) != nil {
				t.Error("invalid portal account request")
				return
			}
			resp := p.PortalAccountResponse{Status: "ok", Account: &account}
			switch q.Op {
			case "get":
				if q.ID != account.ID {
					t.Error("get did not identify the account")
				}
			case "disable":
				if q.ID != account.ID || q.IfRevision != account.Revision {
					t.Error("disable did not pin the current revision")
				}
			case "list":
				if q.Cursor != "previous" {
					t.Error("list did not forward the cursor")
				}
				resp.Accounts, resp.Cursor = []p.PortalAccount{account}, "next"
			case "import":
				if !q.DryRun || len(q.Accounts) != 1 || q.Accounts[0].PasswordHash != testPortalHash {
					t.Error("dry-run did not send the account data")
				}
				resp.Accounts = []p.PortalAccount{account}
			case "enable":
				resp.Status = testPortalHash // Simulate an unsafe server error.
			default:
				t.Error("unexpected account operation")
			}
			payload, _ := json.Marshal(resp)
			frame := binary.BigEndian.AppendUint16(nil, p.S_PortalAccount)
			frame = append(frame, wire[len(wire)-4:]...)
			if err := c.WriteMessage(websocket.BinaryMessage, append(frame, payload...)); err != nil {
				t.Error(err)
				return
			}
		}
	}))
	defer server.Close()
	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{Server: "ws" + strings.TrimPrefix(server.URL, "http") + "/", WorkspaceID: "test"}).Save(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "accounts.json")
	data := fmt.Sprintf(`[{"login":"customer","requester":"customer@example.com","name":"Customer","password_hash":%q}]`, testPortalHash)
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	_ = output.Configure(false, false, "")
	for _, args := range [][]string{{"list", "--cursor", "previous"}, {"get", "42"}, {"disable", "42"}, {"import", "--file", path, "--dry-run"}} {
		cmd := ticketAccountCommand()
		cmd.SetArgs(args)
		got := captureStdout(t, func() {
			if err := cmd.Execute(); err != nil {
				t.Fatal(err)
			}
		})
		if !json.Valid([]byte(got)) || !strings.Contains(got, `"customer"`) || strings.Contains(got, "$2a$") || strings.Contains(got, "password_hash") {
			t.Fatal("expected metadata-only JSON for", args[0])
		}
	}
	for _, args := range [][]string{{"enable", "42"}, {"create"}, {"import", "--file", path}, {"import", "--file", path, "--dry-run", "--apply"}} {
		cmd := ticketAccountCommand()
		cmd.SetOut(io.Discard)
		cmd.SetErr(io.Discard)
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil || strings.Contains(err.Error(), "$2a$") {
			t.Fatal("expected sanitized rejection for", args[0])
		}
	}
	for _, args := range [][]string{
		{"create", "--login", "customer", "--requester", "customer@example.com", "--name", "Customer", "--confirm"},
		{"reset-password", "42"},
	} {
		cmd := ticketAccountCommand()
		cmd.SetIn(strings.NewReader("not allowed through stdin"))
		cmd.SetOut(io.Discard)
		cmd.SetErr(io.Discard)
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "interactive terminal") {
			t.Fatal("expected terminal requirement for", args[0], err)
		}
	}
}
