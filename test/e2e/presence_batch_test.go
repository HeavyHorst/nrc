package e2e

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestPresenceDisconnectWavePreservesEveryEvent(t *testing.T) {
	server := startServerInWorkDirWithEnv(t, t.TempDir(), map[string]string{"NRC_THREAD_COUNT": "4"})
	defer server.stop(t)
	const departing = 600 // Exceeds the old 512-entry per-recipient send queue.
	workspace := fmt.Sprintf("presence-wave-%d", time.Now().UnixNano())
	var connections []*websocket.Conn
	var readers sync.WaitGroup
	defer func() {
		for _, c := range connections {
			c.Close()
		}
		readers.Wait()
	}()
	connect := func(name string) *websocket.Conn {
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, name))
		if err != nil {
			t.Fatal(err)
		}
		connections = append(connections, c)
		mustSetReadDeadline(t, c, 30*time.Second)
		mustExpectServerReady(t, c)
		if err := sendProtocolMessage(c, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(1)); err != nil {
			t.Fatal(err)
		}
		mustWaitForPresenceUpdate(t, c, 4)
		return c
	}
	observers := []*websocket.Conn{connect("observer-a"), connect("observer-b")}
	peers := make([]*websocket.Conn, departing)
	expected := make(map[string]bool, departing)
	for i := range peers {
		name := fmt.Sprintf("departing-%03d", i)
		expected[name] = true
		peers[i] = connect(name)
		if err := peers[i].SetReadDeadline(time.Time{}); err != nil {
			t.Fatal(err)
		}
		readers.Add(1)
		go func(c *websocket.Conn) {
			defer readers.Done()
			for {
				if _, _, err := c.ReadMessage(); err != nil {
					return
				}
			}
		}(peers[i])
	}
	lastSequence := make([]int64, len(observers))
	readPresence := func(index int) *protocol.PresenceUpdate {
		msg := mustReadProtocolMessage(t, observers[index])
		if msg.Opcode != protocol.S_RoomPresenceUpdate {
			t.Fatalf("unexpected opcode %d", msg.Opcode)
		}
		update, err := protocol.DecodePresenceUpdate(msg.Data)
		if err != nil {
			t.Fatal(err)
		}
		if update.ConvID != 1 || update.Sequence <= lastSequence[index] {
			t.Fatalf("wrong room or non-increasing presence sequence: %+v", update)
		}
		lastSequence[index] = update.Sequence
		return update
	}
	for index := range observers {
		mustSetReadDeadline(t, observers[index], 30*time.Second)
		joined := make(map[string]bool, departing)
		for len(joined) < departing {
			update := readPresence(index)
			if expected[update.Username] {
				if update.EventType != 0 || joined[update.Username] {
					t.Fatalf("unexpected/duplicate join: %+v", update)
				}
				joined[update.Username] = true
			}
		}
	}
	start := make(chan struct{})
	var closed sync.WaitGroup
	for _, c := range peers {
		closed.Add(1)
		go func(c *websocket.Conn) {
			defer closed.Done()
			<-start
			c.Close()
		}(c)
	}
	close(start)
	closed.Wait()
	for index, observer := range observers {
		mustSetReadDeadline(t, observer, 30*time.Second)
		left := make(map[string]bool, departing)
		for len(left) < departing {
			update := readPresence(index)
			if update.EventType != 1 || !expected[update.Username] || left[update.Username] {
				t.Fatalf("unexpected/duplicate departure: %+v", update)
			}
			left[update.Username] = true
		}
		if err := sendProtocolMessage(observer, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(1)); err != nil {
			t.Fatal(err)
		}
		update := readPresence(index) // Also rejects trailing duplicate departures.
		if update.EventType != 2 || len(update.Users) != 2 {
			t.Fatalf("expected authoritative sync with two survivors, got %+v", update)
		}
		users := map[string]bool{}
		for _, user := range update.Users {
			users[user.Username] = true
		}
		if !users["observer-a"] || !users["observer-b"] {
			t.Fatalf("wrong surviving users: %v", users)
		}
	}
	server.stop(t) // Read logs only after the process and log writer have stopped.
	if strings.Contains(server.logs.String(), "send queue full") {
		t.Fatal("disconnect wave overflowed a send queue")
	}
	t.Logf("both observers received all %d ordered departure events and the final two-user snapshot", departing)
}
