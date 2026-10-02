package client

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// ConnectionState represents the client's connection state machine
type ConnectionState int

const (
	StateDisconnected ConnectionState = iota
	StateConnecting
	StateWaitingServerReady
	StateSettingNickname
	StateSubscribing
	StateActive
	StateClosing
)

func (s ConnectionState) String() string {
	switch s {
	case StateDisconnected:
		return "Disconnected"
	case StateConnecting:
		return "Connecting"
	case StateWaitingServerReady:
		return "WaitingServerReady"
	case StateSettingNickname:
		return "SettingNickname"
	case StateSubscribing:
		return "Subscribing"
	case StateActive:
		return "Active"
	case StateClosing:
		return "Closing"
	default:
		return "Unknown"
	}
}

// ClientConfig holds configuration for a benchmark client
type ClientConfig struct {
	ServerURL        string
	WorkspaceID      string
	Nickname         string
	AuthHeader       http.Header
	Conversations    []int64
	RandomSeed       int64
	FanoutSampleRate int
	MessageInterval  time.Duration
	PingInterval     time.Duration
	MessageSize      int
	ReadTimeout      time.Duration
	WriteTimeout     time.Duration
}

// ClientMetrics holds per-client metrics
type ClientMetrics struct {
	ConnectTime      time.Duration
	MessagesSent     uint64
	MessagesReceived uint64
	BytesSent        uint64
	BytesReceived    uint64
	Errors           uint64

	// Latency tracking (atomics for concurrent access)
	lastMsgSendTime sync.Map // clientReqID -> time.Time
}

// Client represents a single benchmark WebSocket client
type Client struct {
	id      int
	config  ClientConfig
	conn    *websocket.Conn
	state   ConnectionState
	stateMu sync.RWMutex
	metrics ClientMetrics

	// Callbacks for metrics collection
	onMessageAck      func(clientID int, observedRTT time.Duration, ackTimestamp int64)
	onPongReceived    func(clientID int, rtt time.Duration, pong *protocol.StatsResponse)
	onMessageReceived func(clientID int, payload []byte)
	onError           func(clientID int, err error)
	onDisconnect      func(clientID int, err error, countAsError bool)
	onStateChange     func(clientID int, oldState, newState ConnectionState)

	// Control
	stopCh         chan struct{}
	doneCh         chan struct{}
	stopOnce       sync.Once
	doneOnce       sync.Once
	disconnectOnce sync.Once
	wg             sync.WaitGroup
	rng            *rand.Rand

	// Request ID generator
	reqIDCounter uint32

	// Fanout sampling
	fanoutSampleCounter uint64

	// Server info
	serverReady *protocol.ServerReady
}

// NewClient creates a new benchmark client
func NewClient(id int, config ClientConfig) *Client {
	return &Client{
		id:     id,
		config: config,
		state:  StateDisconnected,
		stopCh: make(chan struct{}),
		doneCh: make(chan struct{}),
		rng:    rand.New(rand.NewSource(config.RandomSeed)),
	}
}

// SetCallbacks configures the metric callbacks
func (c *Client) SetCallbacks(
	onMessageAck func(clientID int, observedRTT time.Duration, ackTimestamp int64),
	onPongReceived func(clientID int, rtt time.Duration, pong *protocol.StatsResponse),
	onMessageReceived func(clientID int, payload []byte),
	onError func(clientID int, err error),
	onDisconnect func(clientID int, err error, countAsError bool),
	onStateChange func(clientID int, oldState, newState ConnectionState),
) {
	c.onMessageAck = onMessageAck
	c.onPongReceived = onPongReceived
	c.onMessageReceived = onMessageReceived
	c.onError = onError
	c.onDisconnect = onDisconnect
	c.onStateChange = onStateChange
}

// ID returns the client ID
func (c *Client) ID() int {
	return c.id
}

// State returns the current connection state
func (c *Client) State() ConnectionState {
	c.stateMu.RLock()
	defer c.stateMu.RUnlock()
	return c.state
}

// Metrics returns a copy of the client metrics
func (c *Client) Metrics() ClientMetrics {
	return ClientMetrics{
		ConnectTime:      c.metrics.ConnectTime,
		MessagesSent:     atomic.LoadUint64(&c.metrics.MessagesSent),
		MessagesReceived: atomic.LoadUint64(&c.metrics.MessagesReceived),
		BytesSent:        atomic.LoadUint64(&c.metrics.BytesSent),
		BytesReceived:    atomic.LoadUint64(&c.metrics.BytesReceived),
		Errors:           atomic.LoadUint64(&c.metrics.Errors),
	}
}

func (c *Client) setState(newState ConnectionState) {
	c.stateMu.Lock()
	oldState := c.state
	c.state = newState
	c.stateMu.Unlock()

	if c.onStateChange != nil && oldState != newState {
		c.onStateChange(c.id, oldState, newState)
	}
}

func (c *Client) nextReqID() uint32 {
	return atomic.AddUint32(&c.reqIDCounter, 1)
}

func (c *Client) reportError(err error) {
	atomic.AddUint64(&c.metrics.Errors, 1)
	if c.onError != nil {
		c.onError(c.id, err)
	}
}

func (c *Client) reportUnexpectedDisconnect(err error, countAsError bool) {
	c.disconnectOnce.Do(func() {
		c.stopOnce.Do(func() {
			close(c.stopCh)
		})
		if countAsError {
			atomic.AddUint64(&c.metrics.Errors, 1)
		}
		if c.onDisconnect != nil {
			c.onDisconnect(c.id, err, countAsError)
		}
	})
}

// Connect establishes the WebSocket connection and runs the client
func (c *Client) Connect() error {
	return c.ConnectContext(context.Background())
}

// ConnectContext establishes the WebSocket connection with a cancellable dial.
func (c *Client) ConnectContext(ctx context.Context) error {
	c.setState(StateConnecting)

	connectStart := time.Now()

	url := fmt.Sprintf("%s/%s", c.config.ServerURL, c.config.WorkspaceID)

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
		ReadBufferSize:   65536,
		WriteBufferSize:  65536,
	}

	conn, _, err := dialer.DialContext(ctx, url, c.config.AuthHeader)
	if err != nil {
		c.setState(StateDisconnected)
		return fmt.Errorf("dial failed: %w", err)
	}

	c.conn = conn
	connectDone := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-connectDone:
		}
	}()
	defer close(connectDone)
	c.setState(StateWaitingServerReady)

	// Wait for S_ServerReady
	if err := c.waitForServerReady(); err != nil {
		c.conn.Close()
		c.setState(StateDisconnected)
		return fmt.Errorf("server ready failed: %w", err)
	}

	// Subscribe to conversations
	c.setState(StateSubscribing)
	if err := c.subscribe(); err != nil {
		c.conn.Close()
		c.setState(StateDisconnected)
		return fmt.Errorf("subscribe failed: %w", err)
	}

	c.metrics.ConnectTime = time.Since(connectStart)
	c.setState(StateActive)

	// Start read/write loops
	c.wg.Add(2)
	go c.readLoop()
	go c.writeLoop()

	return nil
}

// Stop gracefully shuts down the client
func (c *Client) Stop() {
	c.stateMu.Lock()
	if c.state == StateDisconnected {
		c.stateMu.Unlock()
		return
	}
	if c.state == StateClosing {
		c.stateMu.Unlock()
		<-c.doneCh
		return
	}
	c.state = StateClosing
	c.stateMu.Unlock()

	c.stopOnce.Do(func() {
		close(c.stopCh)
	})

	if c.conn != nil {
		c.conn.WriteControl(
			websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
			time.Now().Add(time.Second),
		)
		c.conn.Close()
	}

	c.wg.Wait()
	c.setState(StateDisconnected)
	c.doneOnce.Do(func() {
		close(c.doneCh)
	})
}

// Done returns a channel that's closed when the client has stopped
func (c *Client) Done() <-chan struct{} {
	return c.doneCh
}

func (c *Client) waitForServerReady() error {
	c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))

	_, data, err := c.conn.ReadMessage()
	if err != nil {
		return err
	}

	msg, err := protocol.ReadMessage(data)
	if err != nil {
		return err
	}

	if msg.Opcode != protocol.S_ServerReady {
		return fmt.Errorf("expected S_ServerReady, got %d", msg.Opcode)
	}

	c.serverReady, err = protocol.ParseServerReady(data)
	if err != nil {
		return err
	}

	atomic.AddUint64(&c.metrics.BytesReceived, uint64(len(data)))
	return nil
}

func (c *Client) subscribe() error {
	if len(c.config.Conversations) == 0 {
		return nil
	}

	return c.sendProtocolMessage(protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(c.config.Conversations...))
}

func (c *Client) sendProtocolMessage(opcode uint16, payload []byte) error {
	msg := &protocol.Message{Opcode: opcode, Data: payload}
	wire, err := msg.Write()
	if err != nil {
		c.reportError(err)
		return err
	}
	return c.sendMessage(wire)
}

func (c *Client) sendMessage(data []byte) error {
	if c.config.WriteTimeout > 0 {
		c.conn.SetWriteDeadline(time.Now().Add(c.config.WriteTimeout))
	}

	err := c.conn.WriteMessage(websocket.BinaryMessage, data)
	if err != nil {
		c.reportError(err)
		return err
	}

	atomic.AddUint64(&c.metrics.BytesSent, uint64(len(data)))
	return nil
}

func (c *Client) readLoop() {
	defer c.wg.Done()

	for {
		select {
		case <-c.stopCh:
			return
		default:
		}

		if c.config.ReadTimeout > 0 {
			c.conn.SetReadDeadline(time.Now().Add(c.config.ReadTimeout))
		}

		_, data, err := c.conn.ReadMessage()
		if err != nil {
			select {
			case <-c.stopCh:
				return
			default:
				countAsError := !websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway)
				c.reportUnexpectedDisconnect(err, countAsError)
				return // WebSocket read errors are fatal - cannot retry
			}
		}

		atomic.AddUint64(&c.metrics.BytesReceived, uint64(len(data)))
		c.handleMessage(data)
	}
}

func (c *Client) handleMessage(data []byte) {
	msg, err := protocol.ReadMessage(data)
	if err != nil {
		c.reportError(err)
		return
	}

	switch msg.Opcode {
	case protocol.S_AckSendMessage:
		c.handleAckSendMessage(msg.Data)
	case protocol.S_NewMessage:
		c.handleNewMessage(msg.Data)
	case protocol.S_StatsResponse:
		c.handlePong(msg.Data)
	case protocol.S_RoomPresenceUpdate:
		// Ignore presence updates for now
	case protocol.S_ErrorResponse:
		c.handleErrorResponse(msg.Data)
	default:
		// Unknown opcode, ignore
	}
}

func (c *Client) handleAckSendMessage(payload []byte) {
	ack, err := protocol.DecodeAckSendMessage(payload)
	if err != nil {
		c.reportError(err)
		return
	}

	sentTime, ok := c.metrics.lastMsgSendTime.LoadAndDelete(ack.ClientReqID)
	if ok && c.onMessageAck != nil {
		c.onMessageAck(c.id, time.Since(sentTime.(time.Time)), ack.Timestamp)
	}
}

func (c *Client) handleNewMessage(payload []byte) {
	atomic.AddUint64(&c.metrics.MessagesReceived, 1)

	if c.onMessageReceived == nil {
		return
	}

	if c.config.FanoutSampleRate <= 0 {
		return
	}

	rate := uint64(c.config.FanoutSampleRate)
	if rate == 1 {
		c.onMessageReceived(c.id, payload)
		return
	}

	n := atomic.AddUint64(&c.fanoutSampleCounter, 1)
	if n%rate == 0 {
		c.onMessageReceived(c.id, payload)
	}
}

func (c *Client) handlePong(payload []byte) {
	pong, err := protocol.DecodeStatsResponse(payload)
	if err != nil {
		c.reportError(err)
		return
	}

	sentTime := time.UnixMicro(pong.Timestamp)
	rtt := time.Since(sentTime)

	if c.onPongReceived != nil {
		c.onPongReceived(c.id, rtt, pong)
	}
}

func (c *Client) handleErrorResponse(payload []byte) {
	errResp, err := protocol.DecodeErrorResponse(payload)
	if err != nil {
		c.reportError(err)
		return
	}
	c.reportError(fmt.Errorf("server error (opcode %d): %s",
		errResp.OriginOpcode, errResp.ErrorMessage))
}

func (c *Client) writeLoop() {
	defer c.wg.Done()

	// Use randomized intervals for realistic traffic patterns (exponential distribution)
	// This models a Poisson process where messages arrive randomly with the configured average rate
	nextMsgDelay := func() time.Duration {
		// Exponential distribution: -ln(U) * mean, where U is uniform(0,1)
		// Add small minimum to avoid zero delays
		avgInterval := float64(c.config.MessageInterval)
		delay := time.Duration(-avgInterval * c.rng.Float64() * 2) // uniform [0, 2*avg] approximation
		if delay < 0 {
			delay = -delay
		}
		if delay < 10*time.Millisecond {
			delay = 10 * time.Millisecond
		}
		return delay
	}

	// Start with random initial delay to spread out first messages
	msgTimer := time.NewTimer(time.Duration(c.rng.Float64() * float64(c.config.MessageInterval)))
	defer msgTimer.Stop()

	var pingTicker *time.Ticker
	var pingCh <-chan time.Time
	if c.config.PingInterval > 0 {
		pingTicker = time.NewTicker(c.config.PingInterval)
		pingCh = pingTicker.C
		defer pingTicker.Stop()
	}

	for {
		select {
		case <-c.stopCh:
			return

		case <-msgTimer.C:
			c.sendRandomMessage()
			msgTimer.Reset(nextMsgDelay())

		case <-pingCh:
			c.sendPing()
		}
	}
}

func (c *Client) sendRandomMessage() {
	if len(c.config.Conversations) == 0 {
		return
	}

	if c.State() != StateActive {
		return
	}

	convID := c.config.Conversations[c.rng.Intn(len(c.config.Conversations))]
	reqID := c.nextReqID()

	content := make([]byte, c.config.MessageSize)
	for i := range content {
		content[i] = byte('a' + (i % 26))
	}

	c.metrics.lastMsgSendTime.Store(reqID, time.Now())

	payload := protocol.EncodeSendMessage(convID, reqID, string(content), protocol.ContentTypePlainText)
	if err := c.sendProtocolMessage(protocol.C_SendMessage, payload); err != nil {
		c.metrics.lastMsgSendTime.Delete(reqID)
		return
	}

	atomic.AddUint64(&c.metrics.MessagesSent, 1)
}

func (c *Client) sendPing() {
	payload := protocol.EncodeStats(time.Now().UnixMicro())
	c.sendProtocolMessage(protocol.C_Stats, payload)
}
