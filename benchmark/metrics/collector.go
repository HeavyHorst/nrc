package metrics

import (
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/HdrHistogram/hdrhistogram-go"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// Collector aggregates metrics from all benchmark clients
type Collector struct {
	mu sync.RWMutex

	// Connection metrics
	totalConnections  uint64
	failedConnections uint64
	connectTimeHist   *hdrhistogram.Histogram

	// Message metrics
	messagesSent         uint64
	messagesAcknowledged uint64
	messagesReceived     uint64
	messageAckHist       *hdrhistogram.Histogram // Client-observed RTT for message acknowledgments
	messageAckLagHist    *hdrhistogram.Histogram // Delivery lag from server ack timestamp to client receive
	fanoutLagHist        *hdrhistogram.Histogram // Delivery lag from server message timestamp to client receive

	// Ping metrics
	pingsSent     uint64
	pongsReceived uint64
	pingRTTHist   *hdrhistogram.Histogram

	// Phase tracking separates benchmark behavior from intentional client teardown.
	teardown               bool
	steadyStateDisconnects uint64
	teardownDisconnects    uint64
	firstSteadyDisconnect  time.Duration
	lastSteadyDisconnect   time.Duration
	disconnectReasons      map[string]uint64
	totalErrors            uint64
	teardownErrors         uint64
	errorsByType           map[string]uint64
	teardownErrorsByType   map[string]uint64

	// Throughput tracking
	bytesSent     uint64
	bytesReceived uint64

	// Server stats from pong responses
	lastServerStats *protocol.StatsResponse
	serverStatsTime time.Time

	// Time tracking
	startTime time.Time
}

// NewCollector creates a new metrics collector
func NewCollector() *Collector {
	return &Collector{
		// Histograms track values in microseconds, range 1us to 60s
		connectTimeHist:      hdrhistogram.New(1, 60_000_000, 3),
		messageAckHist:       hdrhistogram.New(1, 60_000_000, 3),
		messageAckLagHist:    hdrhistogram.New(1, 60_000_000, 3),
		fanoutLagHist:        hdrhistogram.New(1, 60_000_000, 3),
		pingRTTHist:          hdrhistogram.New(1, 60_000_000, 3),
		errorsByType:         make(map[string]uint64),
		disconnectReasons:    make(map[string]uint64),
		teardownErrorsByType: make(map[string]uint64),
		startTime:            time.Now(),
	}
}

// RecordUnexpectedDisconnect records one terminal read event atomically so its
// disconnect and optional error cannot land on opposite sides of the teardown boundary.
func (c *Collector) RecordUnexpectedDisconnect(err error, countAsError bool) {
	c.mu.Lock()
	if c.teardown {
		c.teardownDisconnects++
		if countAsError {
			c.teardownErrors++
			c.teardownErrorsByType[fmt.Sprintf("%T", err)]++
		}
	} else {
		c.steadyStateDisconnects++
		elapsed := time.Since(c.startTime)
		if c.firstSteadyDisconnect == 0 {
			c.firstSteadyDisconnect = elapsed
		}
		c.lastSteadyDisconnect = elapsed
		c.disconnectReasons[fmt.Sprint(err)]++
		if countAsError {
			c.totalErrors++
			c.errorsByType[fmt.Sprintf("%T", err)]++
		}
	}
	c.mu.Unlock()
}

// Start records the benchmark start time
func (c *Collector) Start() {
	c.startTime = time.Now()
}

// RecordConnect records a successful connection
func (c *Collector) RecordConnect(connectTime time.Duration) {
	atomic.AddUint64(&c.totalConnections, 1)

	c.mu.Lock()
	c.connectTimeHist.RecordValue(connectTime.Microseconds())
	c.mu.Unlock()
}

// RecordConnectFailed records a failed connection attempt
func (c *Collector) RecordConnectFailed() {
	atomic.AddUint64(&c.failedConnections, 1)
}

// SetMessagesSent publishes the aggregate client-local send count.
func (c *Collector) SetMessagesSent(total uint64) {
	atomic.StoreUint64(&c.messagesSent, total)
}

// RecordMessageAck records message acknowledgment RTT
func (c *Collector) RecordMessageAck(rtt time.Duration) {
	atomic.AddUint64(&c.messagesAcknowledged, 1)
	if rtt <= 0 {
		return
	}
	c.mu.Lock()
	c.messageAckHist.RecordValue(rtt.Microseconds())
	c.mu.Unlock()
}

// RecordMessageAckLag records delivery lag from server ack timestamp to receive time.
func (c *Collector) RecordMessageAckLag(lag time.Duration) {
	if lag <= 0 {
		return
	}
	c.mu.Lock()
	c.messageAckLagHist.RecordValue(lag.Microseconds())
	c.mu.Unlock()
}

// RecordFanoutLag records delivery lag from server message timestamp to receive time.
func (c *Collector) RecordFanoutLag(lag time.Duration) {
	if lag <= 0 {
		return
	}
	c.mu.Lock()
	c.fanoutLagHist.RecordValue(lag.Microseconds())
	c.mu.Unlock()
}

// RecordMessageReceived records a received broadcast message
func (c *Collector) RecordMessageReceived() {
	atomic.AddUint64(&c.messagesReceived, 1)
}

// SetMessagesReceived replaces the aggregate received message count.
// Used by the scenario runner to publish low-overhead totals from client-local counters.
func (c *Collector) SetMessagesReceived(total uint64) {
	atomic.StoreUint64(&c.messagesReceived, total)
}

// RecordPing records a ping sent
func (c *Collector) RecordPing() {
	atomic.AddUint64(&c.pingsSent, 1)
}

// RecordPong records a pong received with RTT
func (c *Collector) RecordPong(rtt time.Duration, pong *protocol.StatsResponse) {
	atomic.AddUint64(&c.pongsReceived, 1)

	c.mu.Lock()
	c.pingRTTHist.RecordValue(rtt.Microseconds())
	c.lastServerStats = pong
	c.serverStatsTime = time.Now()
	c.mu.Unlock()
}

// RecordError records an error occurrence
func (c *Collector) RecordError(err error) {
	errType := fmt.Sprintf("%T", err)
	c.mu.Lock()
	if c.teardown {
		c.teardownErrors++
		c.teardownErrorsByType[errType]++
	} else {
		c.totalErrors++
		c.errorsByType[errType]++
	}
	c.mu.Unlock()
}

// SetBytes publishes aggregate client-local byte counts.
func (c *Collector) SetBytes(sent, received uint64) {
	atomic.StoreUint64(&c.bytesSent, sent)
	atomic.StoreUint64(&c.bytesReceived, received)
}

// Snapshot returns a point-in-time snapshot of all metrics
type Snapshot struct {
	Timestamp time.Time     `json:"timestamp"`
	Duration  time.Duration `json:"duration"`

	// Connections
	TotalConnections  uint64  `json:"total_connections"`
	ActiveConnections uint64  `json:"active_connections"`
	FailedConnections uint64  `json:"failed_connections"`
	ConnectTimeP50    float64 `json:"connect_time_p50_ms"`
	ConnectTimeP95    float64 `json:"connect_time_p95_ms"`
	ConnectTimeP99    float64 `json:"connect_time_p99_ms"`

	// Messages
	MessagesSent         uint64  `json:"messages_sent"`
	MessagesAcknowledged uint64  `json:"messages_acknowledged"`
	MessagesReceived     uint64  `json:"messages_received"`
	MessageRTTP50        float64 `json:"message_rtt_p50_ms"`
	MessageRTTP95        float64 `json:"message_rtt_p95_ms"`
	MessageRTTP99        float64 `json:"message_rtt_p99_ms"`
	MessageRTTMax        float64 `json:"message_rtt_max_ms"`
	AckLagP50            float64 `json:"ack_lag_p50_ms"`
	AckLagP95            float64 `json:"ack_lag_p95_ms"`
	AckLagP99            float64 `json:"ack_lag_p99_ms"`
	AckLagMax            float64 `json:"ack_lag_max_ms"`
	FanoutLagP50         float64 `json:"fanout_lag_p50_ms"`
	FanoutLagP95         float64 `json:"fanout_lag_p95_ms"`
	FanoutLagP99         float64 `json:"fanout_lag_p99_ms"`
	FanoutLagMax         float64 `json:"fanout_lag_max_ms"`

	// Throughput
	MessagesSentPerSec     float64 `json:"messages_sent_per_sec"`
	MessagesReceivedPerSec float64 `json:"messages_received_per_sec"`
	BytesSentPerSec        float64 `json:"bytes_sent_per_sec"`
	BytesReceivedPerSec    float64 `json:"bytes_received_per_sec"`

	// Ping
	PingsSent     uint64  `json:"pings_sent"`
	PongsReceived uint64  `json:"pongs_received"`
	PingRTTP50    float64 `json:"ping_rtt_p50_ms"`
	PingRTTP95    float64 `json:"ping_rtt_p95_ms"`
	PingRTTP99    float64 `json:"ping_rtt_p99_ms"`

	// Errors
	TotalErrors            uint64            `json:"total_errors"`
	ErrorsByType           map[string]uint64 `json:"errors_by_type"`
	SteadyStateDisconnects uint64            `json:"steady_state_disconnects"`
	TeardownDisconnects    uint64            `json:"teardown_disconnects"`
	TeardownErrors         uint64            `json:"teardown_errors"`
	TeardownErrorsByType   map[string]uint64 `json:"teardown_errors_by_type"`
	FirstSteadyDisconnect  time.Duration     `json:"first_steady_state_disconnect"`
	LastSteadyDisconnect   time.Duration     `json:"last_steady_state_disconnect"`
	DisconnectReasons      map[string]uint64 `json:"steady_state_disconnect_reasons"`

	// Server stats
	ServerStats *ServerStatsSnapshot `json:"server_stats,omitempty"`
}

type ServerStatsSnapshot struct {
	ThreadID          uint32 `json:"thread_id"`
	TotalThreads      uint32 `json:"total_threads"`
	Connections       uint32 `json:"connections"`
	MemoryMB          uint32 `json:"memory_mb"`
	BufferPoolPercent uint32 `json:"buffer_pool_percent"`
	IOPending         uint32 `json:"io_pending"`
	IORingAvailable   uint32 `json:"io_ring_available"`
	SendQueueDepth    uint32 `json:"send_queue_depth"`
	SendBackpressure  bool   `json:"send_backpressure"`
}

// Snapshot returns current metrics without changing the collection phase.
func (c *Collector) Snapshot() *Snapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.snapshotLocked()
}

// EndSteadyState atomically changes phase and returns the final steady-state snapshot.
// Terminal read events are recorded under the same lock, so none can be omitted or split.
func (c *Collector) EndSteadyState() *Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.teardown = true
	return c.snapshotLocked()
}

func (c *Collector) snapshotLocked() *Snapshot {
	now := time.Now()
	duration := now.Sub(c.startTime)
	durationSec := duration.Seconds()
	if durationSec == 0 {
		durationSec = 1
	}

	messagesSent := atomic.LoadUint64(&c.messagesSent)
	messagesAcknowledged := atomic.LoadUint64(&c.messagesAcknowledged)
	messagesReceived := atomic.LoadUint64(&c.messagesReceived)
	bytesSent := atomic.LoadUint64(&c.bytesSent)
	bytesReceived := atomic.LoadUint64(&c.bytesReceived)

	totalConnections := atomic.LoadUint64(&c.totalConnections)
	activeConnections := uint64(0)
	if c.steadyStateDisconnects <= totalConnections {
		activeConnections = totalConnections - c.steadyStateDisconnects
	}

	snap := &Snapshot{
		Timestamp: now,
		Duration:  duration,

		TotalConnections:  totalConnections,
		ActiveConnections: activeConnections,
		FailedConnections: atomic.LoadUint64(&c.failedConnections),
		ConnectTimeP50:    float64(c.connectTimeHist.ValueAtQuantile(50)) / 1000.0,
		ConnectTimeP95:    float64(c.connectTimeHist.ValueAtQuantile(95)) / 1000.0,
		ConnectTimeP99:    float64(c.connectTimeHist.ValueAtQuantile(99)) / 1000.0,

		MessagesSent:         messagesSent,
		MessagesAcknowledged: messagesAcknowledged,
		MessagesReceived:     messagesReceived,
		MessageRTTP50:        float64(c.messageAckHist.ValueAtQuantile(50)) / 1000.0,
		MessageRTTP95:        float64(c.messageAckHist.ValueAtQuantile(95)) / 1000.0,
		MessageRTTP99:        float64(c.messageAckHist.ValueAtQuantile(99)) / 1000.0,
		MessageRTTMax:        float64(c.messageAckHist.Max()) / 1000.0,
		AckLagP50:            float64(c.messageAckLagHist.ValueAtQuantile(50)) / 1000.0,
		AckLagP95:            float64(c.messageAckLagHist.ValueAtQuantile(95)) / 1000.0,
		AckLagP99:            float64(c.messageAckLagHist.ValueAtQuantile(99)) / 1000.0,
		AckLagMax:            float64(c.messageAckLagHist.Max()) / 1000.0,
		FanoutLagP50:         float64(c.fanoutLagHist.ValueAtQuantile(50)) / 1000.0,
		FanoutLagP95:         float64(c.fanoutLagHist.ValueAtQuantile(95)) / 1000.0,
		FanoutLagP99:         float64(c.fanoutLagHist.ValueAtQuantile(99)) / 1000.0,
		FanoutLagMax:         float64(c.fanoutLagHist.Max()) / 1000.0,

		MessagesSentPerSec:     float64(messagesSent) / durationSec,
		MessagesReceivedPerSec: float64(messagesReceived) / durationSec,
		BytesSentPerSec:        float64(bytesSent) / durationSec,
		BytesReceivedPerSec:    float64(bytesReceived) / durationSec,

		PingsSent:     atomic.LoadUint64(&c.pingsSent),
		PongsReceived: atomic.LoadUint64(&c.pongsReceived),
		PingRTTP50:    float64(c.pingRTTHist.ValueAtQuantile(50)) / 1000.0,
		PingRTTP95:    float64(c.pingRTTHist.ValueAtQuantile(95)) / 1000.0,
		PingRTTP99:    float64(c.pingRTTHist.ValueAtQuantile(99)) / 1000.0,

		TotalErrors:            c.totalErrors,
		ErrorsByType:           make(map[string]uint64),
		SteadyStateDisconnects: c.steadyStateDisconnects,
		TeardownDisconnects:    c.teardownDisconnects,
		TeardownErrors:         c.teardownErrors,
		TeardownErrorsByType:   make(map[string]uint64),
		FirstSteadyDisconnect:  c.firstSteadyDisconnect,
		LastSteadyDisconnect:   c.lastSteadyDisconnect,
		DisconnectReasons:      make(map[string]uint64),
	}

	for k, v := range c.errorsByType {
		snap.ErrorsByType[k] = v
	}
	for k, v := range c.teardownErrorsByType {
		snap.TeardownErrorsByType[k] = v
	}
	for k, v := range c.disconnectReasons {
		snap.DisconnectReasons[k] = v
	}

	if c.lastServerStats != nil {
		snap.ServerStats = &ServerStatsSnapshot{
			ThreadID:          c.lastServerStats.ThreadID,
			TotalThreads:      c.lastServerStats.TotalThreads,
			Connections:       c.lastServerStats.Connections,
			MemoryMB:          c.lastServerStats.MemoryTotalMB,
			BufferPoolPercent: c.lastServerStats.BufferPoolPercent,
			IOPending:         c.lastServerStats.IOPending,
			IORingAvailable:   c.lastServerStats.IORingAvailable,
			SendQueueDepth:    c.lastServerStats.SendQueueDepth,
			SendBackpressure:  c.lastServerStats.SendBackpressure,
		}
	}

	return snap
}

// JSON returns the snapshot as JSON
func (s *Snapshot) JSON() ([]byte, error) {
	return json.MarshalIndent(s, "", "  ")
}

// String returns a formatted string representation
func (s *Snapshot) String() string {
	return fmt.Sprintf(`
=== NRC Benchmark Results ===
Duration: %v

CONNECTIONS
  Total:   %d
  Active:  %d
  Failed:  %d
  Connect Time: p50=%.2fms p95=%.2fms p99=%.2fms

MESSAGES
  Sent:     %d (%.1f/sec)
  Acknowledged: %d
  Received: %d (%.1f/sec)
  ACK Observed RTT: p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms
  ACK Lag: p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms
  Fanout Lag: p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms

THROUGHPUT
  Sent:     %.2f KB/s
  Received: %.2f KB/s

PING/PONG
  Sent: %d  Received: %d
  RTT: p50=%.2fms p95=%.2fms p99=%.2fms

ERRORS
  Steady-state: %d  Disconnects: %d
  First/last steady-state disconnect: %v / %v
  Teardown: %d  Disconnects: %d
`,
		s.Duration.Round(time.Second),
		s.TotalConnections, s.ActiveConnections, s.FailedConnections,
		s.ConnectTimeP50, s.ConnectTimeP95, s.ConnectTimeP99,
		s.MessagesSent, s.MessagesSentPerSec,
		s.MessagesAcknowledged,
		s.MessagesReceived, s.MessagesReceivedPerSec,
		s.MessageRTTP50, s.MessageRTTP95, s.MessageRTTP99, s.MessageRTTMax,
		s.AckLagP50, s.AckLagP95, s.AckLagP99, s.AckLagMax,
		s.FanoutLagP50, s.FanoutLagP95, s.FanoutLagP99, s.FanoutLagMax,
		s.BytesSentPerSec/1024, s.BytesReceivedPerSec/1024,
		s.PingsSent, s.PongsReceived,
		s.PingRTTP50, s.PingRTTP95, s.PingRTTP99,
		s.TotalErrors, s.SteadyStateDisconnects,
		s.FirstSteadyDisconnect.Round(time.Millisecond), s.LastSteadyDisconnect.Round(time.Millisecond),
		s.TeardownErrors, s.TeardownDisconnects,
	)
}
