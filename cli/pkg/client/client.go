package client

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/protocol-go"
)

type Client struct {
	url         string
	workspaceID string
	conn        *websocket.Conn
	mu          sync.RWMutex
	connected   bool
	done        chan struct{}
	inbox       chan *protocol.Message
}

func New(url, workspaceID string) *Client {
	return &Client{
		url:         url,
		workspaceID: workspaceID,
		done:        make(chan struct{}),
		inbox:       make(chan *protocol.Message, 100),
	}
}

// Connect establishes WebSocket connection
func (c *Client) Connect(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	wsURL := fmt.Sprintf("%s%s", c.url, c.workspaceID)

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
	}

	conn, _, err := dialer.DialContext(ctx, wsURL, nil)
	if err != nil {
		return fmt.Errorf("failed to connect: %w", err)
	}

	c.conn = conn
	c.connected = true

	// Start message reading loop
	go c.readLoop()

	return nil
}

// Close closes the connection
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		return nil
	}

	c.connected = false
	close(c.done)
	return c.conn.Close()
}

// IsConnected returns connection status
func (c *Client) IsConnected() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.connected
}

// Send sends a message to the server
func (c *Client) Send(msg *protocol.Message) error {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if !c.connected {
		return fmt.Errorf("not connected")
	}

	data, err := msg.Write()
	if err != nil {
		return err
	}

	return c.conn.WriteMessage(websocket.BinaryMessage, data)
}

// Recv receives a message from the inbox
func (c *Client) Recv() (*protocol.Message, bool) {
	msg, ok := <-c.inbox
	return msg, ok
}

// RecvSkipServerReady receives a message, skipping S_ServerReady if present
func (c *Client) RecvSkipServerReady(expectedOpcode uint16) (*protocol.Message, bool) {
	msg, ok := <-c.inbox
	if !ok {
		return nil, false
	}

	// Skip S_ServerReady (100) if we get it
	if msg.Opcode == 100 {
		msg, ok = <-c.inbox
		if !ok {
			return nil, false
		}
	}

	return msg, ok
}

// readLoop reads messages from WebSocket
func (c *Client) readLoop() {
	defer close(c.inbox)

	for {
		select {
		case <-c.done:
			return
		default:
		}

		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}

		msg, err := protocol.ReadMessage(data)
		if err != nil {
			continue
		}

		select {
		case c.inbox <- msg:
		case <-c.done:
			return
		}
	}
}
