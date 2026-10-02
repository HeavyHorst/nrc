package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/client"
	"github.com/heavyhorst/nrc/cli/pkg/conn"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestFileMetadataMerge(t *testing.T) {
	a := protocol.Asset{Preview: `{"version":1,"title":"Old","filename":"original.pdf","extra":18446744073709551615}`, Payload: `{"type":"file","version":1,"title":"Old","description":"Keep","category":"Contract","tags":["old"],"custom":18446744073709551615}`}
	a.PayloadRawLen = uint32(len(a.Payload))
	p, m, err := fileMetadata(a)
	if err != nil {
		t.Fatal(err)
	}
	c, _, _ := newFileCommand().Find([]string{"update"})
	_ = c.Flags().Set("title", " New ")
	_ = c.Flags().Set("category", "")
	_ = c.Flags().Set("tag", "")
	preview, payload, err := fileContent(c, p, m)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]json.RawMessage
	_ = json.Unmarshal([]byte(payload), &got)
	if string(got["custom"]) != "18446744073709551615" || string(got["title"]) != `"New"` || string(got["description"]) != `"Keep"` || string(got["tags"]) != "[]" || string(got["category"]) != `""` {
		t.Fatalf("bad merge: %s", payload)
	}
	if !strings.Contains(preview, `"filename":"original.pdf"`) || !strings.Contains(preview, "18446744073709551615") {
		t.Fatal(preview)
	}
	_ = c.Flags().Set("title", strings.Repeat("界", 1500))
	if _, _, err := fileContent(c, p, m); err == nil {
		t.Fatal("accepted oversized UTF-8 preview")
	}
}

func TestFileMetadataRejectsUnknownSchemaAndMutationFlags(t *testing.T) {
	for _, payload := range []string{`{}`, `{"type":"file","version":2,"title":"x"}`, `{"type":"note","version":1,"title":"x"}`} {
		if _, _, err := fileMetadata(protocol.Asset{Preview: `{"version":1,"title":"x"}`, Payload: payload, PayloadRawLen: uint32(len(payload))}); err == nil {
			t.Fatalf("accepted %s", payload)
		}
	}
	for _, action := range []string{"upload", "update"} {
		c, _, err := newFileCommand().Find([]string{action})
		if err != nil || c.Annotations["mutation"] != "true" {
			t.Fatalf("unmarked mutation %s", action)
		}
	}
}

func TestFilePostWriteFailuresAreNotRetryable(t *testing.T) {
	for _, readback := range []bool{false, true} {
		t.Run(map[bool]string{false: "lost create acknowledgement", true: "committed readback failure"}[readback], func(t *testing.T) {
			var received atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				ws, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer ws.Close()
				_, data, err := ws.ReadMessage()
				if err != nil {
					return
				}
				msg, err := protocol.ReadMessage(data)
				if err != nil {
					t.Error(err)
					return
				}
				expected := protocol.C_CreateAsset
				if readback {
					expected = protocol.C_GetAsset
				}
				if msg.Opcode != expected {
					t.Errorf("unexpected opcode: %d", msg.Opcode)
				}
				received.Add(1) // Drop the response, never retry the mutation.
			}))
			defer server.Close()
			c := client.New("ws"+strings.TrimPrefix(server.URL, "http")+"/", "test")
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := c.Connect(ctx); err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			s := &conn.Session{Client: c, RoomID: 2}
			var err error
			identifier := "att_recover"
			if readback {
				_, err = readCommittedFile(s, 123)
				identifier = "123"
			} else {
				_, err = createUploadedFile(s, []byte{1}, identifier)
			}
			if err == nil || conn.Classify(err).Retryable || !strings.Contains(err.Error(), identifier) {
				t.Fatalf("unsafe error: %v", err)
			}
			if received.Load() != 1 {
				t.Fatalf("requests: %d", received.Load())
			}
		})
	}
}
