package e2e

import (
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/url"
	"os"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const (
	faultCampaignRoomID   = int64(protocol.WorkspaceDataConvID)
	faultCampaignSteps    = 14
	faultCampaignTimeout  = 5 * time.Second
	faultObservationLimit = time.Second
)

type tcpFaultProxy struct {
	listener net.Listener
	backend  string
	delayNS  atomic.Int64

	mu          sync.Mutex
	connections map[*tcpProxyConnection]struct{}
	closed      bool
	wg          sync.WaitGroup
}

type tcpProxyConnection struct {
	client          net.Conn
	backend         net.Conn
	clientBytes     atomic.Uint64
	forwardedMu     sync.Mutex
	forwardedNotify chan struct{}
	delayNS         atomic.Int64
	delayMu         sync.Mutex
	delayGate       *tcpProxyDelayGate
	once            sync.Once
}

type tcpProxyDelayGate struct {
	clientToServerEntered chan struct{}
	serverToClientEntered chan struct{}
	clientToServerOnce    sync.Once
	serverToClientOnce    sync.Once
	release               *tcpProxyDelayRelease
}

type tcpProxyDelayRelease struct {
	done chan struct{}
	once sync.Once
}

func startTCPFaultProxy(backend string) (*tcpFaultProxy, error) {
	listener, err := net.Listen("tcp", net.JoinHostPort(serverHost, "0"))
	if err != nil {
		return nil, fmt.Errorf("listen: %w", err)
	}

	proxy := &tcpFaultProxy{
		listener:    listener,
		backend:     backend,
		connections: make(map[*tcpProxyConnection]struct{}),
	}
	proxy.wg.Add(1)
	go proxy.acceptLoop()
	return proxy, nil
}

func (p *tcpFaultProxy) port() int {
	return p.listener.Addr().(*net.TCPAddr).Port
}

func (p *tcpFaultProxy) setDelay(delay time.Duration) {
	p.delayNS.Store(int64(delay))
}

func (p *tcpFaultProxy) resetConnections() (int, error) {
	connections := p.activeConnections()

	resetCount := 0
	var resetErrors []error
	for _, connection := range connections {
		reset, err := connection.reset()
		if reset {
			resetCount++
		}
		if err != nil {
			resetErrors = append(resetErrors, err)
		}
	}
	return resetCount, errors.Join(resetErrors...)
}

func (p *tcpFaultProxy) halfCloseClientWrites() (int, error) {
	connections := p.activeConnections()

	halfClosedCount := 0
	var halfCloseErrors []error
	for _, connection := range connections {
		if err := connection.halfCloseClientWrites(); err != nil {
			halfCloseErrors = append(halfCloseErrors, err)
			continue
		}
		halfClosedCount++
	}
	return halfClosedCount, errors.Join(halfCloseErrors...)
}

func (p *tcpFaultProxy) activeConnections() []*tcpProxyConnection {
	p.mu.Lock()
	defer p.mu.Unlock()
	connections := make([]*tcpProxyConnection, 0, len(p.connections))
	for connection := range p.connections {
		connections = append(connections, connection)
	}
	return connections
}

func (p *tcpFaultProxy) soleActiveConnection() (*tcpProxyConnection, error) {
	connections := p.activeConnections()
	if len(connections) != 1 {
		return nil, fmt.Errorf("found %d active proxy connections, want 1", len(connections))
	}
	return connections[0], nil
}

func (p *tcpFaultProxy) connectionForClient(conn *websocket.Conn) (*tcpProxyConnection, error) {
	clientAddress := conn.UnderlyingConn().LocalAddr().String()
	p.mu.Lock()
	defer p.mu.Unlock()
	for connection := range p.connections {
		if connection.client.RemoteAddr().String() == clientAddress {
			return connection, nil
		}
	}
	return nil, fmt.Errorf("no active proxy connection for client address %s", clientAddress)
}

func (p *tcpFaultProxy) close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	p.mu.Unlock()

	_ = p.listener.Close()
	_, _ = p.resetConnections()
	p.wg.Wait()
}

func (p *tcpFaultProxy) acceptLoop() {
	defer p.wg.Done()
	for {
		client, err := p.listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}

		backend, err := net.DialTimeout("tcp", p.backend, time.Second)
		if err != nil {
			_ = client.Close()
			continue
		}

		connection := &tcpProxyConnection{
			client:          client,
			backend:         backend,
			forwardedNotify: make(chan struct{}),
		}
		p.mu.Lock()
		if p.closed {
			p.mu.Unlock()
			connection.close()
			return
		}
		p.connections[connection] = struct{}{}
		p.mu.Unlock()

		p.wg.Add(1)
		go p.serve(connection)
	}
}

func (p *tcpFaultProxy) serve(connection *tcpProxyConnection) {
	defer p.wg.Done()
	defer func() {
		connection.close()
		p.mu.Lock()
		delete(p.connections, connection)
		p.mu.Unlock()
	}()

	done := make(chan struct{}, 2)
	go func() {
		p.copy(connection, connection.backend, connection.client, &connection.clientBytes, true)
		done <- struct{}{}
	}()
	go func() {
		p.copy(connection, connection.client, connection.backend, nil, false)
		done <- struct{}{}
	}()

	<-done
	connection.close()
	<-done
}

func (p *tcpFaultProxy) copy(connection *tcpProxyConnection, dst, src net.Conn, forwarded *atomic.Uint64, clientToServer bool) {
	buffer := make([]byte, 32*1024)
	for {
		count, readErr := src.Read(buffer)
		if count > 0 {
			if delay := time.Duration(p.delayNS.Load() + connection.delayNS.Load()); delay > 0 {
				time.Sleep(delay)
			}
			connection.waitAtDelayGate(clientToServer)
			written, writeErr := writeAll(dst, buffer[:count])
			if forwarded != nil {
				forwarded.Add(uint64(written))
				connection.notifyForwardedBytes()
			}
			if writeErr != nil {
				return
			}
		}
		if readErr != nil {
			return
		}
	}
}

func writeAll(dst io.Writer, data []byte) (int, error) {
	written := 0
	for written < len(data) {
		count, err := dst.Write(data[written:])
		written += count
		if err != nil {
			return written, err
		}
		if count == 0 {
			return written, io.ErrShortWrite
		}
	}
	return written, nil
}

func (c *tcpProxyConnection) close() {
	_, _ = c.closeConnection(false)
}

func (c *tcpProxyConnection) reset() (bool, error) {
	return c.closeConnection(true)
}

func (c *tcpProxyConnection) halfCloseClientWrites() error {
	backend, ok := c.backend.(*net.TCPConn)
	if !ok {
		return fmt.Errorf("backend connection %T does not support TCP half-close", c.backend)
	}
	if err := backend.CloseWrite(); err != nil {
		return fmt.Errorf("half-close client-to-server stream: %w", err)
	}
	return nil
}

func (c *tcpProxyConnection) setDelay(delay time.Duration) {
	c.delayNS.Store(int64(delay))
}

func (c *tcpProxyConnection) installDelayGate() *tcpProxyDelayGate {
	return c.installDelayGateWithRelease(&tcpProxyDelayRelease{done: make(chan struct{})})
}

func (c *tcpProxyConnection) installDelayGateWithRelease(release *tcpProxyDelayRelease) *tcpProxyDelayGate {
	gate := &tcpProxyDelayGate{
		clientToServerEntered: make(chan struct{}),
		serverToClientEntered: make(chan struct{}),
		release:               release,
	}
	c.delayMu.Lock()
	c.delayGate = gate
	c.delayMu.Unlock()
	return gate
}

func (c *tcpProxyConnection) waitAtDelayGate(clientToServer bool) {
	c.delayMu.Lock()
	gate := c.delayGate
	c.delayMu.Unlock()
	if gate == nil {
		return
	}
	if clientToServer {
		gate.clientToServerOnce.Do(func() { close(gate.clientToServerEntered) })
	} else {
		gate.serverToClientOnce.Do(func() { close(gate.serverToClientEntered) })
	}
	<-gate.release.done
}

func (g *tcpProxyDelayGate) releaseDelay() {
	g.release.releaseDelay()
}

func (r *tcpProxyDelayRelease) releaseDelay() {
	r.once.Do(func() { close(r.done) })
}

func (c *tcpProxyConnection) notifyForwardedBytes() {
	c.forwardedMu.Lock()
	close(c.forwardedNotify)
	c.forwardedNotify = make(chan struct{})
	c.forwardedMu.Unlock()
}

func (c *tcpProxyConnection) closeConnection(reset bool) (bool, error) {
	closed := false
	var closeErrors []error
	c.once.Do(func() {
		closed = true
		if reset {
			if client, ok := c.client.(*net.TCPConn); ok {
				if err := client.SetLinger(0); err != nil {
					closeErrors = append(closeErrors, fmt.Errorf("set client reset linger: %w", err))
				}
			}
			if backend, ok := c.backend.(*net.TCPConn); ok {
				if err := backend.SetLinger(0); err != nil {
					closeErrors = append(closeErrors, fmt.Errorf("set backend reset linger: %w", err))
				}
			}
		}
		if err := c.client.Close(); err != nil {
			closeErrors = append(closeErrors, fmt.Errorf("close client connection: %w", err))
		}
		if err := c.backend.Close(); err != nil {
			closeErrors = append(closeErrors, fmt.Errorf("close backend connection: %w", err))
		}
	})
	return closed, errors.Join(closeErrors...)
}

type faultCampaignAction uint8

const (
	faultCampaignReset faultCampaignAction = iota
	faultCampaignHalfClose
	faultCampaignDelay
	faultCampaignPause
	faultCampaignKillRace
	faultCampaignReconnect
)

type faultCampaignCreate struct {
	title       string
	description string
	priority    uint8
	project     string
}

func (a faultCampaignAction) String() string {
	switch a {
	case faultCampaignReset:
		return "tcp-reset"
	case faultCampaignHalfClose:
		return "tcp-half-close"
	case faultCampaignDelay:
		return "network-delay"
	case faultCampaignPause:
		return "process-pause"
	case faultCampaignKillRace:
		return "process-kill-race"
	case faultCampaignReconnect:
		return "client-reconnect"
	default:
		return "unknown"
	}
}

// TestOutsideInFaultCampaign exercises production networking and process
// boundaries that the deterministic simulation intentionally replaces. Replay
// a failure with NRC_FAULT_CAMPAIGN_SEED=<logged seed>; increase coverage with
// NRC_FAULT_CAMPAIGN_STEPS=<count> and NRC_FAULT_CAMPAIGN_RUNS=<count>.
func TestOutsideInFaultCampaign(t *testing.T) {
	baseSeed := faultCampaignSeed(t)
	runs := faultCampaignRunCount(t)
	for run := 0; run < runs; run++ {
		seed := baseSeed + int64(run)
		t.Run(fmt.Sprintf("seed-%d", seed), func(t *testing.T) {
			runOutsideInFaultCampaign(t, seed)
		})
	}
}

func runOutsideInFaultCampaign(t *testing.T, seed int64) {
	rng := rand.New(rand.NewSource(seed))
	steps := faultCampaignStepCount(t)
	t.Logf("outside-in fault campaign seed=%d steps=%d", seed, steps)

	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-outside-in-%d", seed)
	server := startServerInWorkDir(t, serverWorkDir)
	proxy, err := startTCPFaultProxy(net.JoinHostPort(serverHost, strconv.Itoa(serverPort)))
	if err != nil {
		server.stop(t)
		t.Fatalf("seed=%d: start TCP fault proxy: %v", seed, err)
	}
	defer func() {
		proxy.close()
		server.stop(t)
	}()

	conn, err := dialFaultCampaignClient(proxy.port(), workspace)
	if err != nil {
		t.Fatalf("seed=%d: initial client connection: %v", seed, err)
	}
	defer func() {
		if conn != nil {
			_ = conn.Close()
		}
	}()

	actions := make([]faultCampaignAction, steps)
	for i := range actions {
		actions[i] = faultCampaignAction(i % 6)
	}
	rng.Shuffle(len(actions), func(i, j int) {
		actions[i], actions[j] = actions[j], actions[i]
	})

	expectedTasks := make([]protocol.Task, 0, steps)
	expectedAssets := make([]protocol.Asset, 0, 4)
	expectedEdges := make([]protocol.Edge, 0, 4)
	for step, action := range actions {
		var taskMutation string
		expectedTasks, taskMutation, err = applyConfirmedFaultCampaignMutation(conn, expectedTasks, rng, seed, step, action)
		if err != nil {
			t.Fatalf("seed=%d step=%d task-mutation=%s action=%s: %v", seed, step, taskMutation, action, err)
		}
		var graphMutation string
		expectedAssets, expectedEdges, graphMutation, err = applyConfirmedAssetEdgeMutation(
			conn,
			expectedAssets,
			expectedEdges,
			seed,
			step,
		)
		if err != nil {
			t.Fatalf("seed=%d step=%d graph-mutation=%s action=%s: %v", seed, step, graphMutation, action, err)
		}

		t.Logf("seed=%d step=%d task-mutation=%s graph-mutation=%s action=%s", seed, step, taskMutation, graphMutation, action)
		var uncertainCreate *faultCampaignCreate
		switch action {
		case faultCampaignReset:
			resetCount, resetErr := proxy.resetConnections()
			if resetErr != nil {
				err = resetErr
			} else if resetCount != 1 {
				err = fmt.Errorf("reset %d active proxy connections, want 1", resetCount)
			} else {
				err = awaitFaultCampaignDisconnect(conn, "TCP reset")
			}
			_ = conn.Close()
			if err == nil {
				conn, err = dialFaultCampaignClient(proxy.port(), workspace)
			}
		case faultCampaignHalfClose:
			halfClosedCount, halfCloseErr := proxy.halfCloseClientWrites()
			if halfCloseErr != nil {
				err = halfCloseErr
			} else if halfClosedCount != 1 {
				err = fmt.Errorf("half-closed %d active proxy connections, want 1", halfClosedCount)
			} else {
				err = awaitFaultCampaignDisconnect(conn, "TCP half-close")
			}
			_ = conn.Close()
			if err == nil {
				conn, err = dialFaultCampaignClient(proxy.port(), workspace)
			}
		case faultCampaignDelay:
			_ = conn.Close()
			proxy.setDelay(time.Duration(1+rng.Intn(8)) * time.Millisecond)
			conn, err = dialFaultCampaignClient(proxy.port(), workspace)
		case faultCampaignPause:
			err = sendQueryWhileServerStopped(
				server,
				proxy,
				conn,
				time.Duration(5+rng.Intn(20))*time.Millisecond,
			)
		case faultCampaignKillRace:
			uncertainCreate = &faultCampaignCreate{
				title:       fmt.Sprintf("fault-racing-create-%d-%d", seed, step),
				description: "outcome resolved after process kill",
				priority:    uint8(1 + rng.Intn(4)),
				project:     fmt.Sprintf("fault-project-%d", rng.Intn(3)),
			}
			createPayload := protocol.EncodeTaskCreateFullWithCorrelation(
				faultCampaignRoomID,
				uncertainCreate.title,
				uncertainCreate.description,
				int32(uncertainCreate.priority),
				uncertainCreate.project,
				nil,
				uint32(0x80000000+step),
			)
			proxyConnection, forwardedTarget, barrierErr := faultCampaignForwardingBarrier(
				proxy,
				protocol.C_CreateTask,
				createPayload,
			)
			if barrierErr != nil {
				err = barrierErr
			}
			if err == nil {
				err = sendFaultCampaignMessage(conn, protocol.C_CreateTask, createPayload)
			}
			if err == nil {
				err = waitForForwardedClientBytes(
					proxyConnection,
					forwardedTarget,
					faultObservationLimit,
					"complete racing create frame",
				)
			}
			if err == nil {
				server.killAndWait(t)
				_ = conn.Close()
				conn = nil
				_, _ = proxy.resetConnections()
				server = startServerInWorkDir(t, serverWorkDir)
				conn, err = dialFaultCampaignClient(proxy.port(), workspace)
			}
		case faultCampaignReconnect:
			_ = conn.Close()
			conn, err = dialFaultCampaignClient(proxy.port(), workspace)
		}
		if err != nil {
			t.Fatalf("seed=%d step=%d action=%s: inject fault: %v", seed, step, action, err)
		}

		var tasks []protocol.Task
		if action == faultCampaignPause {
			tasks, err = readFaultCampaignTaskList(conn)
		} else {
			tasks, err = listFaultCampaignTasks(conn)
		}
		proxy.setDelay(0)
		if err != nil {
			t.Fatalf("seed=%d step=%d action=%s: liveness query: %v", seed, step, action, err)
		}
		if uncertainCreate != nil {
			recovered, found, resolveErr := resolveFaultCampaignCreate(tasks, *uncertainCreate)
			if resolveErr != nil {
				t.Fatalf("seed=%d step=%d action=%s: resolve racing create: %v", seed, step, action, resolveErr)
			}
			if found {
				expectedTasks = append(expectedTasks, recovered)
			}
			t.Logf("seed=%d step=%d racing-create-recovered=%t", seed, step, found)
		}
		if err := checkFaultCampaignModel(tasks, expectedTasks); err != nil {
			t.Fatalf("seed=%d step=%d action=%s: %v", seed, step, action, err)
		}
		assets, err := listFaultCampaignAssets(conn)
		if err != nil {
			t.Fatalf("seed=%d step=%d action=%s: asset liveness query: %v", seed, step, action, err)
		}
		if err := checkFaultCampaignAssets(assets, expectedAssets); err != nil {
			t.Fatalf("seed=%d step=%d action=%s: %v", seed, step, action, err)
		}
		edges, err := listFaultCampaignEdges(conn)
		if err != nil {
			t.Fatalf("seed=%d step=%d action=%s: edge liveness query: %v", seed, step, action, err)
		}
		if err := checkFaultCampaignEdges(edges, expectedEdges); err != nil {
			t.Fatalf("seed=%d step=%d action=%s: %v", seed, step, action, err)
		}
	}

	// This proves immediate process-crash recovery of bytes retained by the
	// running kernel. It intentionally makes no stable-storage/fsync claim.
	_ = conn.Close()
	conn = nil
	server.killAndWait(t)
	_, _ = proxy.resetConnections()
	server = startServerInWorkDir(t, serverWorkDir)

	conn, err = dialFaultCampaignClient(proxy.port(), workspace)
	if err != nil {
		t.Fatalf("seed=%d: reconnect after SIGKILL restart: %v", seed, err)
	}
	tasks, err := listFaultCampaignTasks(conn)
	if err != nil {
		t.Fatalf("seed=%d: liveness query after SIGKILL restart: %v", seed, err)
	}
	if err := checkFaultCampaignModel(tasks, expectedTasks); err != nil {
		t.Fatalf("seed=%d after SIGKILL restart: %v", seed, err)
	}
	assets, err := listFaultCampaignAssets(conn)
	if err != nil {
		t.Fatalf("seed=%d: asset query after SIGKILL restart: %v", seed, err)
	}
	if err := checkFaultCampaignAssets(assets, expectedAssets); err != nil {
		t.Fatalf("seed=%d after SIGKILL restart: %v", seed, err)
	}
	edges, err := listFaultCampaignEdges(conn)
	if err != nil {
		t.Fatalf("seed=%d: edge query after SIGKILL restart: %v", seed, err)
	}
	if err := checkFaultCampaignEdges(edges, expectedEdges); err != nil {
		t.Fatalf("seed=%d after SIGKILL restart: %v", seed, err)
	}
}

type multiClientFaultConnection struct {
	websocket *websocket.Conn
	proxy     *tcpProxyConnection
}

type multiClientCreateResult struct {
	workspace  string
	title      string
	task       protocol.Task
	broadcasts map[string]protocol.Task
	err        error
}

func TestOutsideInMultiClientFaultCampaign(t *testing.T) {
	server := startServerInWorkDir(t, t.TempDir())
	proxy, err := startTCPFaultProxy(net.JoinHostPort(serverHost, strconv.Itoa(serverPort)))
	if err != nil {
		server.stop(t)
		t.Fatalf("start TCP fault proxy: %v", err)
	}
	defer func() {
		proxy.close()
		server.stop(t)
	}()

	workspace := fmt.Sprintf("e2e-outside-in-multi-%d", time.Now().UnixNano())
	isolatedWorkspace := workspace + "-isolated"
	dialClient := func(username, clientWorkspace string) multiClientFaultConnection {
		conn, dialErr := dialNamedFaultCampaignClient(proxy.port(), clientWorkspace, username)
		if dialErr != nil {
			t.Fatalf("dial %s: %v", username, dialErr)
		}
		proxyConnection, lookupErr := proxy.connectionForClient(conn)
		if lookupErr != nil {
			_ = conn.Close()
			t.Fatalf("identify proxy connection for %s: %v", username, lookupErr)
		}
		return multiClientFaultConnection{websocket: conn, proxy: proxyConnection}
	}

	target := dialClient("multi-target", workspace)
	healthyA := dialClient("multi-healthy-a", workspace)
	healthyB := dialClient("multi-healthy-b", workspace)
	isolated := dialClient("multi-isolated", isolatedWorkspace)
	defer func() {
		_ = target.websocket.Close()
		_ = healthyA.websocket.Close()
		_ = healthyB.websocket.Close()
		_ = isolated.websocket.Close()
	}()

	for name, conn := range map[string]*websocket.Conn{
		"target":    target.websocket,
		"healthy-a": healthyA.websocket,
		"healthy-b": healthyB.websocket,
		"isolated":  isolated.websocket,
	} {
		if err := subscribeFaultCampaignClient(conn); err != nil {
			t.Fatalf("subscribe %s: %v", name, err)
		}
	}

	expectedTasks := make([]protocol.Task, 0, 6)
	expectedIsolatedTasks := make([]protocol.Task, 0, 3)
	faults := []string{"tcp-reset", "tcp-half-close", "network-delay"}
	for phase, fault := range faults {
		t.Logf("multi-client fault phase=%d action=%s", phase, fault)
		switch fault {
		case "tcp-reset":
			reset, resetErr := target.proxy.reset()
			if resetErr != nil || !reset {
				t.Fatalf("targeted TCP reset: reset=%t err=%v", reset, resetErr)
			}
			if err := awaitFaultCampaignDisconnect(target.websocket, fault); err != nil {
				t.Fatal(err)
			}
			_ = target.websocket.Close()
		case "tcp-half-close":
			if err := target.proxy.halfCloseClientWrites(); err != nil {
				t.Fatalf("targeted TCP half-close: %v", err)
			}
			if err := awaitFaultCampaignDisconnect(target.websocket, fault); err != nil {
				t.Fatal(err)
			}
			_ = target.websocket.Close()
		case "network-delay":
			gate := target.proxy.installDelayGate()
			defer gate.releaseDelay()
			pong := make(chan error, 1)
			go func() {
				timestamp := time.Now().UnixNano()
				if sendErr := sendFaultCampaignMessage(target.websocket, protocol.C_Ping, protocol.EncodePing(timestamp)); sendErr != nil {
					pong <- sendErr
					return
				}
				msg, readErr := readFaultCampaignUntil(target.websocket, protocol.S_Pong, 32)
				if readErr != nil {
					pong <- readErr
					return
				}
				response, decodeErr := protocol.DecodePongResponse(msg.Data)
				if decodeErr == nil && response.Timestamp != timestamp {
					decodeErr = fmt.Errorf("pong timestamp mismatch: got %d want %d", response.Timestamp, timestamp)
				}
				pong <- decodeErr
			}()
			if err := waitForProxyDelayGate(gate.clientToServerEntered, "client-to-server"); err != nil {
				t.Fatal(err)
			}

			mainTasks, isolatedTask, createErr := runConcurrentHealthyFaultCampaignCreates(
				healthyA.websocket,
				healthyB.websocket,
				isolated.websocket,
				workspace,
				isolatedWorkspace,
				phase,
			)
			if createErr != nil {
				t.Fatalf("healthy clients during %s: %v", fault, createErr)
			}
			expectedTasks = append(expectedTasks, mainTasks...)
			expectedIsolatedTasks = append(expectedIsolatedTasks, isolatedTask)
			if err := waitForProxyDelayGate(gate.serverToClientEntered, "server-to-client"); err != nil {
				t.Fatal(err)
			}
			select {
			case pingErr := <-pong:
				t.Fatalf("targeted delayed client completed before healthy clients: %v", pingErr)
			default:
			}
			gate.releaseDelay()
			if pingErr := <-pong; pingErr != nil {
				t.Fatalf("delayed client did not recover: %v", pingErr)
			}
		}

		if fault != "network-delay" {
			mainTasks, isolatedTask, createErr := runConcurrentHealthyFaultCampaignCreates(
				healthyA.websocket,
				healthyB.websocket,
				isolated.websocket,
				workspace,
				isolatedWorkspace,
				phase,
			)
			if createErr != nil {
				t.Fatalf("healthy clients during %s: %v", fault, createErr)
			}
			expectedTasks = append(expectedTasks, mainTasks...)
			expectedIsolatedTasks = append(expectedIsolatedTasks, isolatedTask)

			target = dialClient("multi-target", workspace)
			if err := subscribeFaultCampaignClient(target.websocket); err != nil {
				t.Fatalf("resubscribe target after %s: %v", fault, err)
			}
		}

		actualTasks, listErr := listFaultCampaignTasks(target.websocket)
		if listErr != nil {
			t.Fatalf("resync target after %s: %v", fault, listErr)
		}
		if err := checkFaultCampaignModel(actualTasks, expectedTasks); err != nil {
			t.Fatalf("target model after %s: %v", fault, err)
		}
		actualIsolatedTasks, listErr := listFaultCampaignTasksRejectingBroadcasts(isolated.websocket)
		if listErr != nil {
			t.Fatalf("query isolated workspace after %s: %v", fault, listErr)
		}
		if err := checkFaultCampaignModel(actualIsolatedTasks, expectedIsolatedTasks); err != nil {
			t.Fatalf("isolated workspace model after %s: %v", fault, err)
		}
	}
}

type concurrentCrashCreate struct {
	client          multiClientFaultConnection
	workspace       string
	username        string
	title           string
	correlationID   uint32
	payload         []byte
	forwardedTarget uint64
}

func TestOutsideInConcurrentMultiWorkspaceCrash(t *testing.T) {
	serverWorkDir := t.TempDir()
	serverEnv := map[string]string{"NRC_THREAD_COUNT": "2"}
	workspace := mustFindE2EWorkspaceForLogicalShard(t, "e2e-concurrent-crash-primary", 0)
	isolatedWorkspace := mustFindE2EWorkspaceForLogicalShard(t, "e2e-concurrent-crash-isolated", 1)
	server := startServerInWorkDirWithEnv(t, serverWorkDir, serverEnv)
	proxy, err := startTCPFaultProxy(net.JoinHostPort(serverHost, strconv.Itoa(serverPort)))
	if err != nil {
		server.stop(t)
		t.Fatalf("start TCP fault proxy: %v", err)
	}
	defer func() {
		proxy.close()
		server.stop(t)
	}()

	allConnections := make([]*websocket.Conn, 0, 8)
	dialClient := func(username, clientWorkspace string) multiClientFaultConnection {
		client, dialErr := dialNamedFaultCampaignClient(proxy.port(), clientWorkspace, username)
		if dialErr != nil {
			t.Fatalf("dial %s: %v", username, dialErr)
		}
		proxyConnection, lookupErr := proxy.connectionForClient(client)
		if lookupErr != nil {
			_ = client.Close()
			t.Fatalf("identify proxy connection for %s: %v", username, lookupErr)
		}
		allConnections = append(allConnections, client)
		return multiClientFaultConnection{websocket: client, proxy: proxyConnection}
	}
	defer func() {
		for _, connection := range allConnections {
			_ = connection.Close()
		}
	}()

	operations := []concurrentCrashCreate{
		{client: dialClient("crash-target", workspace), workspace: workspace, username: "crash-target", title: "concurrent-crash-target", correlationID: 0x62000001},
		{client: dialClient("crash-healthy-a", workspace), workspace: workspace, username: "crash-healthy-a", title: "concurrent-crash-healthy-a", correlationID: 0x62000002},
		{client: dialClient("crash-healthy-b", workspace), workspace: workspace, username: "crash-healthy-b", title: "concurrent-crash-healthy-b", correlationID: 0x62000003},
		{client: dialClient("crash-isolated", isolatedWorkspace), workspace: isolatedWorkspace, username: "crash-isolated", title: "concurrent-crash-isolated", correlationID: 0x62000004},
	}
	primaryStats := requestStatsResponse(t, operations[0].client.websocket, time.Now().UnixNano())
	isolatedStats := requestStatsResponse(t, operations[3].client.websocket, time.Now().UnixNano())
	if primaryStats.TotalThreads != 2 || primaryStats.ThreadID != 0 {
		t.Fatalf("primary workspace routing mismatch: thread=%d total=%d", primaryStats.ThreadID, primaryStats.TotalThreads)
	}
	if isolatedStats.TotalThreads != 2 || isolatedStats.ThreadID != 1 {
		t.Fatalf("isolated workspace routing mismatch: thread=%d total=%d", isolatedStats.ThreadID, isolatedStats.TotalThreads)
	}
	baselinePrimary, _, err := createAndObserveFaultCampaignTask(
		operations[0].client.websocket,
		operations[0].username,
		"concurrent-crash-baseline-primary",
		0x62000010,
		nil,
	)
	if err != nil {
		t.Fatalf("create primary baseline: %v", err)
	}
	baselineIsolated, _, err := createAndObserveFaultCampaignTask(
		operations[3].client.websocket,
		operations[3].username,
		"concurrent-crash-baseline-isolated",
		0x62000011,
		nil,
	)
	if err != nil {
		t.Fatalf("create isolated baseline: %v", err)
	}

	sharedRelease := &tcpProxyDelayRelease{done: make(chan struct{})}
	defer sharedRelease.releaseDelay()
	gates := make([]*tcpProxyDelayGate, len(operations))
	for i := range operations {
		operation := &operations[i]
		gates[i] = operation.client.proxy.installDelayGateWithRelease(sharedRelease)
		operation.payload = protocol.EncodeTaskCreateWithCorrelation(
			faultCampaignRoomID,
			operation.title,
			"concurrent multi-client fault mutation",
			1,
			operation.correlationID,
		)
		operation.forwardedTarget, err = faultCampaignForwardingTarget(
			operation.client.proxy,
			protocol.C_CreateTask,
			operation.payload,
		)
		if err != nil {
			t.Fatalf("build forwarding barrier for %s: %v", operation.username, err)
		}
	}

	start := make(chan struct{})
	sendResults := make(chan error, len(operations))
	for i := range operations {
		operation := &operations[i]
		go func() {
			<-start
			sendResults <- sendFaultCampaignMessage(operation.client.websocket, protocol.C_CreateTask, operation.payload)
		}()
	}
	close(start)
	for range operations {
		if sendErr := <-sendResults; sendErr != nil {
			t.Fatalf("send concurrent pre-crash create: %v", sendErr)
		}
	}
	for i, gate := range gates {
		if err := waitForProxyDelayGate(gate.clientToServerEntered, "client-to-server"); err != nil {
			t.Fatalf("%s: %v", operations[i].username, err)
		}
	}
	type forwardingResult struct {
		username string
		err      error
	}
	forwardResults := make(chan forwardingResult, len(operations))
	for i := range operations {
		operation := &operations[i]
		go func() {
			forwardResults <- forwardingResult{
				username: operation.username,
				err: waitForForwardedClientBytes(
					operation.client.proxy,
					operation.forwardedTarget,
					faultObservationLimit,
					"complete concurrent crash-racing create frame",
				),
			}
		}()
	}
	gates[0].releaseDelay()
	for range operations {
		result := <-forwardResults
		if result.err != nil {
			t.Fatalf("%s: %v", result.username, result.err)
		}
	}

	// Every complete frame has crossed the proxy, but none of its outcomes is
	// assumed. The restart resolves each create as atomically present or absent.
	// This exercises same-kernel process-crash recovery, not power-loss durability.
	server.killAndWait(t)
	_, _ = proxy.resetConnections()
	server = startServerInWorkDirWithEnv(t, serverWorkDir, serverEnv)

	target := dialClient("crash-target", workspace)
	healthyA := dialClient("multi-healthy-a", workspace)
	healthyB := dialClient("multi-healthy-b", workspace)
	isolated := dialClient("multi-isolated", isolatedWorkspace)

	actualTasks, err := listFaultCampaignTasks(target.websocket)
	if err != nil {
		t.Fatalf("list primary workspace after concurrent crash: %v", err)
	}
	expectedTasks, err := resolveConcurrentCrashCreates(actualTasks, operations, workspace, baselinePrimary)
	if err != nil {
		t.Fatalf("resolve primary workspace after concurrent crash: %v", err)
	}
	actualIsolatedTasks, err := listFaultCampaignTasks(isolated.websocket)
	if err != nil {
		t.Fatalf("list isolated workspace after concurrent crash: %v", err)
	}
	expectedIsolatedTasks, err := resolveConcurrentCrashCreates(actualIsolatedTasks, operations, isolatedWorkspace, baselineIsolated)
	if err != nil {
		t.Fatalf("resolve isolated workspace after concurrent crash: %v", err)
	}

	for name, connection := range map[string]*websocket.Conn{
		"target":    target.websocket,
		"healthy-a": healthyA.websocket,
		"healthy-b": healthyB.websocket,
		"isolated":  isolated.websocket,
	} {
		if err := subscribeFaultCampaignClient(connection); err != nil {
			t.Fatalf("subscribe %s after concurrent crash: %v", name, err)
		}
	}
	continuedTasks, continuedIsolatedTask, err := runConcurrentHealthyFaultCampaignCreates(
		healthyA.websocket,
		healthyB.websocket,
		isolated.websocket,
		workspace,
		isolatedWorkspace,
		100,
	)
	if err != nil {
		t.Fatalf("continued concurrent writes after crash: %v", err)
	}
	expectedTasks = append(expectedTasks, continuedTasks...)
	expectedIsolatedTasks = append(expectedIsolatedTasks, continuedIsolatedTask)
	targetBroadcasts := make(map[string]protocol.Task, len(continuedTasks))
	for _, task := range continuedTasks {
		targetBroadcasts[task.Title] = task
	}
	actualTasks, err = fenceFaultCampaignTaskBroadcasts(target.websocket, targetBroadcasts)
	if err != nil {
		t.Fatalf("target broadcasts after continued writes: %v", err)
	}
	if err := checkFaultCampaignModel(actualTasks, expectedTasks); err != nil {
		t.Fatalf("primary workspace after continued writes: %v", err)
	}
	actualIsolatedTasks, err = listFaultCampaignTasksRejectingBroadcasts(isolated.websocket)
	if err != nil {
		t.Fatalf("resync isolated workspace after continued writes: %v", err)
	}
	if err := checkFaultCampaignModel(actualIsolatedTasks, expectedIsolatedTasks); err != nil {
		t.Fatalf("isolated workspace after continued writes: %v", err)
	}
}

func resolveConcurrentCrashCreates(
	actual []protocol.Task,
	operations []concurrentCrashCreate,
	workspace string,
	baseline protocol.Task,
) ([]protocol.Task, error) {
	operationsByTitle := make(map[string]concurrentCrashCreate)
	for _, operation := range operations {
		if operation.workspace == workspace {
			operationsByTitle[operation.title] = operation
		}
	}
	seenTitles := make(map[string]struct{}, len(actual))
	seenIDs := make(map[uint64]struct{}, len(actual))
	foundBaseline := false
	for _, task := range actual {
		if task.Title == baseline.Title {
			if foundBaseline || !reflect.DeepEqual(task, baseline) {
				return nil, fmt.Errorf("baseline task mismatch after concurrent crash: got=%+v want=%+v", task, baseline)
			}
			foundBaseline = true
		} else {
			operation, ok := operationsByTitle[task.Title]
			if !ok {
				return nil, fmt.Errorf("unexpected task after concurrent crash: %+v", task)
			}
			if err := validateMultiClientFaultCampaignCreation(task, operation.username, operation.title); err != nil {
				return nil, err
			}
		}
		if _, duplicate := seenTitles[task.Title]; duplicate {
			return nil, fmt.Errorf("duplicate task title after concurrent crash: %q", task.Title)
		}
		seenTitles[task.Title] = struct{}{}
		if _, duplicate := seenIDs[task.ID]; duplicate {
			return nil, fmt.Errorf("duplicate task id after concurrent crash: %d", task.ID)
		}
		seenIDs[task.ID] = struct{}{}
	}
	if !foundBaseline {
		return nil, fmt.Errorf("acknowledged baseline task %q missing after concurrent crash", baseline.Title)
	}
	seenOrderIndexes := make(map[uint16]struct{}, len(actual))
	for _, task := range actual {
		seenOrderIndexes[task.OrderIndex] = struct{}{}
	}
	for orderIndex := 0; orderIndex < len(actual); orderIndex++ {
		if _, ok := seenOrderIndexes[uint16(orderIndex)]; !ok {
			return nil, fmt.Errorf("task order indexes are not contiguous: missing %d in %+v", orderIndex, actual)
		}
	}
	return append([]protocol.Task(nil), actual...), nil
}

func subscribeFaultCampaignClient(conn *websocket.Conn) error {
	if err := sendFaultCampaignMessage(conn, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(faultCampaignRoomID)); err != nil {
		return err
	}
	// Scope zero has no presence; fence delivery subscription with a round trip.
	if err := sendFaultCampaignMessage(conn, protocol.C_Ping, protocol.EncodePing(1)); err != nil {
		return err
	}
	_, err := readFaultCampaignUntil(conn, protocol.S_Pong, 16)
	return err
}

func runConcurrentHealthyFaultCampaignCreates(
	healthyA, healthyB, isolated *websocket.Conn,
	workspace, isolatedWorkspace string,
	phase int,
) ([]protocol.Task, protocol.Task, error) {
	titleA := fmt.Sprintf("multi-healthy-a-%d", phase)
	titleB := fmt.Sprintf("multi-healthy-b-%d", phase)
	titleIsolated := fmt.Sprintf("multi-isolated-%d", phase)
	start := make(chan struct{})
	results := make(chan multiClientCreateResult, 3)
	operations := []struct {
		conn               *websocket.Conn
		workspace          string
		username           string
		title              string
		correlationID      uint32
		expectedBroadcasts map[string]struct{}
	}{
		{healthyA, workspace, "multi-healthy-a", titleA, uint32(0x61000000 + phase*4), map[string]struct{}{titleB: {}}},
		{healthyB, workspace, "multi-healthy-b", titleB, uint32(0x61000001 + phase*4), map[string]struct{}{titleA: {}}},
		{isolated, isolatedWorkspace, "multi-isolated", titleIsolated, uint32(0x61000002 + phase*4), nil},
	}
	for _, operation := range operations {
		operation := operation
		go func() {
			<-start
			task, broadcasts, err := createAndObserveFaultCampaignTask(
				operation.conn,
				operation.username,
				operation.title,
				operation.correlationID,
				operation.expectedBroadcasts,
			)
			results <- multiClientCreateResult{
				workspace:  operation.workspace,
				title:      operation.title,
				task:       task,
				broadcasts: broadcasts,
				err:        err,
			}
		}()
	}
	close(start)

	mainTasks := make([]protocol.Task, 0, 2)
	mainResults := make([]multiClientCreateResult, 0, 2)
	var isolatedTask protocol.Task
	for range operations {
		result := <-results
		if result.err != nil {
			return nil, protocol.Task{}, result.err
		}
		if result.workspace == isolatedWorkspace {
			isolatedTask = result.task
		} else {
			mainTasks = append(mainTasks, result.task)
			mainResults = append(mainResults, result)
		}
	}
	acknowledgedByTitle := make(map[string]protocol.Task, len(mainResults))
	for _, result := range mainResults {
		acknowledgedByTitle[result.title] = result.task
	}
	for _, result := range mainResults {
		for title, broadcast := range result.broadcasts {
			acknowledged, ok := acknowledgedByTitle[title]
			if !ok {
				return nil, protocol.Task{}, fmt.Errorf("%q observed unacknowledged broadcast %q", result.title, title)
			}
			if !reflect.DeepEqual(broadcast, acknowledged) {
				return nil, protocol.Task{}, fmt.Errorf("broadcast %q differs from acknowledgment: got=%+v want=%+v", title, broadcast, acknowledged)
			}
		}
	}
	for _, operation := range operations {
		if _, err := fenceFaultCampaignTaskBroadcasts(operation.conn, nil); err != nil {
			return nil, protocol.Task{}, fmt.Errorf("post-create fence for %q: %w", operation.title, err)
		}
	}
	return mainTasks, isolatedTask, nil
}

func createAndObserveFaultCampaignTask(
	conn *websocket.Conn,
	username string,
	title string,
	correlationID uint32,
	expectedBroadcasts map[string]struct{},
) (protocol.Task, map[string]protocol.Task, error) {
	if err := conn.SetReadDeadline(time.Now().Add(faultCampaignTimeout)); err != nil {
		return protocol.Task{}, nil, err
	}
	payload := protocol.EncodeTaskCreateWithCorrelation(faultCampaignRoomID, title, "concurrent multi-client fault mutation", 1, correlationID)
	if err := sendFaultCampaignMessage(conn, protocol.C_CreateTask, payload); err != nil {
		return protocol.Task{}, nil, err
	}
	seenBroadcasts := make(map[string]protocol.Task, len(expectedBroadcasts))
	var acknowledged protocol.Task
	acknowledgedTask := false
	for reads := 0; reads < 32; reads++ {
		msg, err := readFaultCampaignMessage(conn)
		if err != nil {
			return protocol.Task{}, nil, err
		}
		if msg.Opcode != protocol.S_TaskCreated {
			continue
		}
		created, err := protocol.DecodeTaskCreated(msg.Data)
		if err != nil {
			return protocol.Task{}, nil, err
		}
		if created.CorrelationID == correlationID {
			if created.Task.Title != title {
				return protocol.Task{}, nil, fmt.Errorf("acknowledged title mismatch: got %q want %q", created.Task.Title, title)
			}
			if err := validateMultiClientFaultCampaignCreation(*created.Task, username, title); err != nil {
				return protocol.Task{}, nil, err
			}
			acknowledged = *created.Task
			acknowledgedTask = true
		} else {
			if created.CorrelationID != 0 {
				return protocol.Task{}, nil, fmt.Errorf("unexpected task correlation id 0x%08X", created.CorrelationID)
			}
			if _, expected := expectedBroadcasts[created.Task.Title]; !expected {
				return protocol.Task{}, nil, fmt.Errorf("unexpected task broadcast %q", created.Task.Title)
			}
			if _, duplicate := seenBroadcasts[created.Task.Title]; duplicate {
				return protocol.Task{}, nil, fmt.Errorf("duplicate task broadcast %q", created.Task.Title)
			}
			seenBroadcasts[created.Task.Title] = *created.Task
		}
		if acknowledgedTask && len(seenBroadcasts) == len(expectedBroadcasts) {
			return acknowledged, seenBroadcasts, nil
		}
	}
	return protocol.Task{}, nil, fmt.Errorf("task acknowledgment/broadcast set incomplete for %q", title)
}

func fenceFaultCampaignTaskBroadcasts(conn *websocket.Conn, expected map[string]protocol.Task) ([]protocol.Task, error) {
	if err := sendFaultCampaignMessage(conn, protocol.C_GetTasks, protocol.EncodeGetTasks(faultCampaignRoomID)); err != nil {
		return nil, err
	}
	if err := conn.SetReadDeadline(time.Now().Add(faultCampaignTimeout)); err != nil {
		return nil, err
	}
	seen := make(map[string]struct{}, len(expected))
	for reads := 0; reads < 32; reads++ {
		msg, err := readFaultCampaignMessage(conn)
		if err != nil {
			return nil, err
		}
		switch msg.Opcode {
		case protocol.S_TaskCreated:
			created, decodeErr := protocol.DecodeTaskCreated(msg.Data)
			if decodeErr != nil {
				return nil, decodeErr
			}
			if created.CorrelationID != 0 {
				return nil, fmt.Errorf("unexpected fenced task correlation id 0x%08X", created.CorrelationID)
			}
			want, ok := expected[created.Task.Title]
			if !ok {
				return nil, fmt.Errorf("unexpected fenced task broadcast %q", created.Task.Title)
			}
			if _, duplicate := seen[created.Task.Title]; duplicate {
				return nil, fmt.Errorf("duplicate fenced task broadcast %q", created.Task.Title)
			}
			if !reflect.DeepEqual(*created.Task, want) {
				return nil, fmt.Errorf("fenced task broadcast %q differs from acknowledgment: got=%+v want=%+v", created.Task.Title, *created.Task, want)
			}
			seen[created.Task.Title] = struct{}{}
		case protocol.S_TaskListResponse:
			response, decodeErr := protocol.DecodeTaskListResponse(msg.Data)
			if decodeErr != nil {
				return nil, decodeErr
			}
			if response.ConvID != uint64(faultCampaignRoomID) {
				return nil, fmt.Errorf("fence task list room mismatch: got %d want %d", response.ConvID, faultCampaignRoomID)
			}
			if len(seen) != len(expected) {
				return nil, fmt.Errorf("fenced task broadcast set incomplete: got %d want %d", len(seen), len(expected))
			}
			tasks := make([]protocol.Task, 0, len(response.Tasks))
			for _, task := range response.Tasks {
				tasks = append(tasks, *task)
			}
			return tasks, nil
		}
	}
	return nil, fmt.Errorf("task broadcast fence did not receive task list within 32 messages")
}

func validateMultiClientFaultCampaignCreation(task protocol.Task, username, title string) error {
	if task.ID == 0 ||
		task.ConvID != faultCampaignRoomID ||
		task.Title != title ||
		task.Description != "concurrent multi-client fault mutation" ||
		task.Priority != 1 ||
		task.Project != "" ||
		task.Status != protocol.TaskStatusBacklog ||
		task.Assignee != "" ||
		task.Color != protocol.TaskColorNone ||
		task.CreatedBy != username ||
		task.CreatedAt <= 0 ||
		task.UpdatedAt != task.CreatedAt ||
		task.ExternalRef != "" ||
		task.DueAt != 0 ||
		task.BlockedBy != 0 ||
		task.CompletedAt != 0 ||
		task.CompletedBy != "" ||
		len(task.Attachments) != 0 {
		return fmt.Errorf("multi-client creation acknowledgment differs from requested/default state: got=%+v", task)
	}
	return nil
}

func waitForProxyDelayGate(entered <-chan struct{}, direction string) error {
	select {
	case <-entered:
		return nil
	case <-time.After(faultObservationLimit):
		return fmt.Errorf("target connection did not enter %s delay gate within %s", direction, faultObservationLimit)
	}
}

func faultCampaignSeed(t *testing.T) int64 {
	t.Helper()
	value := os.Getenv("NRC_FAULT_CAMPAIGN_SEED")
	if value == "" {
		return time.Now().UnixNano()
	}
	seed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		t.Fatalf("invalid NRC_FAULT_CAMPAIGN_SEED %q: %v", value, err)
	}
	return seed
}

func faultCampaignStepCount(t *testing.T) int {
	t.Helper()
	value := os.Getenv("NRC_FAULT_CAMPAIGN_STEPS")
	if value == "" {
		return faultCampaignSteps
	}
	steps, err := strconv.Atoi(value)
	if err != nil || steps < 7 {
		t.Fatalf("invalid NRC_FAULT_CAMPAIGN_STEPS %q: expected an integer of at least 7", value)
	}
	return steps
}

func faultCampaignRunCount(t *testing.T) int {
	t.Helper()
	value := os.Getenv("NRC_FAULT_CAMPAIGN_RUNS")
	if value == "" {
		return 1
	}
	runs, err := strconv.Atoi(value)
	if err != nil || runs < 1 {
		t.Fatalf("invalid NRC_FAULT_CAMPAIGN_RUNS %q: expected a positive integer", value)
	}
	return runs
}

func dialFaultCampaignClient(port int, workspace string) (*websocket.Conn, error) {
	return dialNamedFaultCampaignClient(port, workspace, "outside-in-client")
}

func dialNamedFaultCampaignClient(port int, workspace, username string) (*websocket.Conn, error) {
	u := url.URL{
		Scheme: "ws",
		Host:   net.JoinHostPort(serverHost, strconv.Itoa(port)),
		Path:   "/" + workspace,
	}
	token, err := buildProxyStyleJWT(username, time.Now())
	if err != nil {
		return nil, err
	}
	header := make(http.Header)
	header.Set("X-NRC-Auth", token)

	dialer := *websocket.DefaultDialer
	dialer.HandshakeTimeout = 5 * time.Second
	conn, _, err := dialer.Dial(u.String(), header)
	if err != nil {
		return nil, err
	}
	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		_ = conn.Close()
		return nil, err
	}
	msg, err := readFaultCampaignMessage(conn)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	if msg.Opcode != protocol.S_ServerReady {
		_ = conn.Close()
		return nil, fmt.Errorf("expected ServerReady opcode %d, got %d", protocol.S_ServerReady, msg.Opcode)
	}
	return conn, nil
}

func applyConfirmedAssetEdgeMutation(
	conn *websocket.Conn,
	assets []protocol.Asset,
	edges []protocol.Edge,
	seed int64,
	step int,
) ([]protocol.Asset, []protocol.Edge, string, error) {
	phase := step % 7
	switch phase {
	case 0, 1:
		parentType := protocol.ParentTypeNone
		parentID := uint64(0)
		assetType := protocol.AssetTypeDocument
		mutation := "create-asset-root"
		if phase == 1 {
			if len(assets) != 1 {
				return assets, edges, "create-asset-child", fmt.Errorf("need one parent asset, got %d", len(assets))
			}
			parentType = protocol.ParentTypeAsset
			parentID = assets[0].AssetID
			assetType = protocol.AssetTypeNote
			mutation = "create-asset-child"
		}
		preview := fmt.Sprintf("fault-asset-%d-%d", seed, step)
		payload := fmt.Sprintf("fault asset payload at step %d", step)
		correlationID := uint32(0x30000000 + step)
		request := protocol.EncodeCreateAssetWithCorrelation(
			faultCampaignRoomID,
			assetType,
			parentType,
			parentID,
			preview,
			payload,
			correlationID,
		)
		if err := sendFaultCampaignMessage(conn, protocol.C_CreateAsset, request); err != nil {
			return assets, edges, mutation, err
		}
		msg, err := readFaultCampaignUntil(conn, protocol.S_AssetCreated, 12)
		if err != nil {
			return assets, edges, mutation, err
		}
		created, err := protocol.DecodeAssetCreated(msg.Data)
		if err != nil {
			return assets, edges, mutation, err
		}
		if created.CorrelationID != correlationID {
			return assets, edges, mutation, fmt.Errorf("correlation id mismatch: got %d want %d", created.CorrelationID, correlationID)
		}
		if err := validateFaultCampaignAssetCreation(created.Asset, assetType, parentType, parentID, preview, payload); err != nil {
			return assets, edges, mutation, fmt.Errorf("invalid acknowledgment: %w", err)
		}
		return append(assets, created.Asset), edges, mutation, nil

	case 2:
		if len(assets) != 2 {
			return assets, edges, "update-asset", fmt.Errorf("need root and child assets, got %d", len(assets))
		}
		index := 1
		old := assets[index]
		preview := fmt.Sprintf("fault-asset-updated-%d-%d", seed, step)
		payload := fmt.Sprintf("updated fault asset payload at step %d", step)
		correlationID := uint32(0x31000000 + step)
		request := protocol.EncodeUpdateAssetWithCorrelation(
			faultCampaignRoomID,
			old.AssetID,
			preview,
			payload,
			correlationID,
		)
		if err := sendFaultCampaignMessage(conn, protocol.C_UpdateAsset, request); err != nil {
			return assets, edges, "update-asset", err
		}
		msg, err := readFaultCampaignUntil(conn, protocol.S_AssetUpdated, 12)
		if err != nil {
			return assets, edges, "update-asset", err
		}
		updated, err := protocol.DecodeAssetUpdated(msg.Data)
		if err != nil {
			return assets, edges, "update-asset", err
		}
		if updated.CorrelationID != correlationID {
			return assets, edges, "update-asset", fmt.Errorf("correlation id mismatch: got %d want %d", updated.CorrelationID, correlationID)
		}
		if err := validateFaultCampaignAssetUpdate(old, updated.Asset, preview, payload); err != nil {
			return assets, edges, "update-asset", fmt.Errorf("invalid acknowledgment: %w", err)
		}
		nextAssets := append([]protocol.Asset(nil), assets...)
		nextAssets[index] = updated.Asset
		return nextAssets, edges, "update-asset", nil

	case 3, 4:
		if len(assets) != 2 {
			return assets, edges, "create-edge", fmt.Errorf("need two assets, got %d", len(assets))
		}
		relation := protocol.RelationRelatedTo
		if phase == 4 {
			relation = protocol.RelationDependsOn
		}
		correlationID := uint32(0x40000000 + step)
		request := protocol.EncodeCreateEdgeWithCorrelation(
			faultCampaignRoomID,
			protocol.TargetTypeAsset,
			assets[0].AssetID,
			protocol.TargetTypeAsset,
			assets[1].AssetID,
			relation,
			correlationID,
		)
		if err := sendFaultCampaignMessage(conn, protocol.C_CreateEdge, request); err != nil {
			return assets, edges, "create-edge", err
		}
		msg, err := readFaultCampaignUntil(conn, protocol.S_EdgeCreated, 12)
		if err != nil {
			return assets, edges, "create-edge", err
		}
		created, err := protocol.DecodeEdgeCreated(msg.Data)
		if err != nil {
			return assets, edges, "create-edge", err
		}
		if created.CorrelationID != correlationID {
			return assets, edges, "create-edge", fmt.Errorf("correlation id mismatch: got %d want %d", created.CorrelationID, correlationID)
		}
		if err := validateFaultCampaignEdgeCreation(created.Edge, assets[0].AssetID, assets[1].AssetID, relation); err != nil {
			return assets, edges, "create-edge", fmt.Errorf("invalid acknowledgment: %w", err)
		}
		return assets, append(edges, created.Edge), "create-edge", nil

	case 5:
		if len(edges) != 2 {
			return assets, edges, "delete-edge", fmt.Errorf("need two edges, got %d", len(edges))
		}
		deletedEdge := edges[0]
		correlationID := uint32(0x41000000 + step)
		request := protocol.EncodeDeleteEdgeWithCorrelation(faultCampaignRoomID, deletedEdge.EdgeID, correlationID)
		if err := sendFaultCampaignMessage(conn, protocol.C_DeleteEdge, request); err != nil {
			return assets, edges, "delete-edge", err
		}
		msg, err := readFaultCampaignUntil(conn, protocol.S_EdgeDeleted, 12)
		if err != nil {
			return assets, edges, "delete-edge", err
		}
		deleted, err := protocol.DecodeEdgeDeleted(msg.Data)
		if err != nil {
			return assets, edges, "delete-edge", err
		}
		if deleted.ConvID != uint64(faultCampaignRoomID) || deleted.EdgeID != deletedEdge.EdgeID || deleted.CorrelationID != correlationID {
			return assets, edges, "delete-edge", fmt.Errorf("acknowledgment mismatch: got=%+v", deleted)
		}
		return assets, append([]protocol.Edge(nil), edges[1:]...), "delete-edge", nil

	default:
		if len(assets) != 2 || len(edges) != 1 {
			return assets, edges, "delete-asset-cascade", fmt.Errorf("need two assets and one edge, got assets=%d edges=%d", len(assets), len(edges))
		}
		rootID := assets[0].AssetID
		correlationID := uint32(0x32000000 + step)
		request := protocol.EncodeDeleteAssetWithCorrelation(faultCampaignRoomID, rootID, correlationID)
		if err := sendFaultCampaignMessage(conn, protocol.C_DeleteAsset, request); err != nil {
			return assets, edges, "delete-asset-cascade", err
		}
		msg, err := readFaultCampaignUntil(conn, protocol.S_AssetDeleted, 12)
		if err != nil {
			return assets, edges, "delete-asset-cascade", err
		}
		deleted, err := protocol.DecodeAssetDeleted(msg.Data)
		if err != nil {
			return assets, edges, "delete-asset-cascade", err
		}
		if deleted.ConvID != uint64(faultCampaignRoomID) || deleted.AssetID != rootID || deleted.CorrelationID != correlationID {
			return assets, edges, "delete-asset-cascade", fmt.Errorf("acknowledgment mismatch: got=%+v", deleted)
		}
		return nil, nil, "delete-asset-cascade", nil
	}
}

func applyConfirmedFaultCampaignMutation(
	conn *websocket.Conn,
	expected []protocol.Task,
	rng *rand.Rand,
	seed int64,
	step int,
	action faultCampaignAction,
) ([]protocol.Task, string, error) {
	mutation := step % 4
	if len(expected) == 0 {
		mutation = 0
	}
	switch mutation {
	case 0, 1:
		title := fmt.Sprintf("fault-task-%d-%d", seed, step)
		description := fmt.Sprintf("created before %s at step %d", action, step)
		priority := uint8(1 + rng.Intn(4))
		project := fmt.Sprintf("fault-project-%d", rng.Intn(3))
		created, err := createFaultCampaignTask(conn, title, description, priority, project, uint32(step+1))
		if err != nil {
			return expected, "create", err
		}
		if err := validateFaultCampaignCreation(created, title, description, priority, project); err != nil {
			return expected, "create", fmt.Errorf("invalid acknowledgment: %w", err)
		}
		return append(expected, created), "create", nil

	case 2:
		index := rng.Intn(len(expected))
		old := expected[index]
		title := fmt.Sprintf("fault-task-updated-%d-%d", seed, step)
		description := fmt.Sprintf("updated before %s at step %d", action, step)
		assignee := "outside-in-client"
		priority := uint8(1 + rng.Intn(4))
		color := uint8(1 + rng.Intn(int(protocol.TaskColorGold)))
		externalRef := fmt.Sprintf("FAULT-%d-%d", seed, step)
		dueAt := int64(4_100_000_000 + step)
		project := fmt.Sprintf("updated-project-%d", rng.Intn(3))
		correlationID := uint32(0x10000000 + step)
		payload := protocol.EncodeTaskUpdateFullWithProjectAndCorrelation(
			faultCampaignRoomID,
			int64(old.ID),
			title,
			description,
			protocol.TaskStatusInProgress,
			assignee,
			priority,
			color,
			externalRef,
			dueAt,
			0,
			nil,
			project,
			correlationID,
		)
		if err := sendFaultCampaignMessage(conn, protocol.C_UpdateTask, payload); err != nil {
			return expected, "update", err
		}
		msg, err := readFaultCampaignUntil(conn, protocol.S_TaskUpdated, 12)
		if err != nil {
			return expected, "update", err
		}
		updated, err := protocol.DecodeTaskUpdated(msg.Data)
		if err != nil {
			return expected, "update", err
		}
		if updated.CorrelationID != correlationID {
			return expected, "update", fmt.Errorf("correlation id mismatch: got %d want %d", updated.CorrelationID, correlationID)
		}
		if err := validateFaultCampaignUpdate(
			old,
			*updated.Task,
			title,
			description,
			assignee,
			priority,
			color,
			externalRef,
			dueAt,
			project,
		); err != nil {
			return expected, "update", fmt.Errorf("invalid acknowledgment: %w", err)
		}
		next := append([]protocol.Task(nil), expected...)
		next[index] = *updated.Task
		return next, "update", nil

	default:
		index := rng.Intn(len(expected))
		deletedTask := expected[index]
		correlationID := uint32(0x20000000 + step)
		payload := protocol.EncodeTaskDeleteWithCorrelation(faultCampaignRoomID, int64(deletedTask.ID), correlationID)
		if err := sendFaultCampaignMessage(conn, protocol.C_DeleteTask, payload); err != nil {
			return expected, "delete", err
		}
		msg, err := readFaultCampaignUntil(conn, protocol.S_TaskDeleted, 12)
		if err != nil {
			return expected, "delete", err
		}
		deleted, err := protocol.DecodeTaskDeleted(msg.Data)
		if err != nil {
			return expected, "delete", err
		}
		if deleted.TaskID != deletedTask.ID ||
			deleted.ConvID != uint64(faultCampaignRoomID) ||
			deleted.CorrelationID != correlationID {
			return expected, "delete", fmt.Errorf("acknowledgment mismatch: got=%+v", deleted)
		}
		next := make([]protocol.Task, 0, len(expected)-1)
		next = append(next, expected[:index]...)
		next = append(next, expected[index+1:]...)
		return next, "delete", nil
	}
}

func createFaultCampaignTask(conn *websocket.Conn, title, description string, priority uint8, project string, correlationID uint32) (protocol.Task, error) {
	payload := protocol.EncodeTaskCreateFullWithCorrelation(
		faultCampaignRoomID,
		title,
		description,
		int32(priority),
		project,
		nil,
		correlationID,
	)
	if err := sendFaultCampaignMessage(conn, protocol.C_CreateTask, payload); err != nil {
		return protocol.Task{}, err
	}
	msg, err := readFaultCampaignUntil(conn, protocol.S_TaskCreated, 12)
	if err != nil {
		return protocol.Task{}, err
	}
	created, err := protocol.DecodeTaskCreated(msg.Data)
	if err != nil {
		return protocol.Task{}, err
	}
	if created.CorrelationID != correlationID {
		return protocol.Task{}, fmt.Errorf("correlation id mismatch: got %d want %d", created.CorrelationID, correlationID)
	}
	return *created.Task, nil
}

func listFaultCampaignTasks(conn *websocket.Conn) ([]protocol.Task, error) {
	if err := sendFaultCampaignMessage(conn, protocol.C_GetTasks, protocol.EncodeGetTasks(faultCampaignRoomID)); err != nil {
		return nil, err
	}
	return readFaultCampaignTaskList(conn)
}

func listFaultCampaignTasksRejectingBroadcasts(conn *websocket.Conn) ([]protocol.Task, error) {
	if err := sendFaultCampaignMessage(conn, protocol.C_GetTasks, protocol.EncodeGetTasks(faultCampaignRoomID)); err != nil {
		return nil, err
	}
	if err := conn.SetReadDeadline(time.Now().Add(faultCampaignTimeout)); err != nil {
		return nil, err
	}
	for reads := 0; reads < 24; reads++ {
		msg, err := readFaultCampaignMessage(conn)
		if err != nil {
			return nil, err
		}
		if msg.Opcode == protocol.S_TaskCreated {
			created, decodeErr := protocol.DecodeTaskCreated(msg.Data)
			if decodeErr != nil {
				return nil, decodeErr
			}
			return nil, fmt.Errorf("isolated workspace received task broadcast %q", created.Task.Title)
		}
		if msg.Opcode != protocol.S_TaskListResponse {
			continue
		}
		response, decodeErr := protocol.DecodeTaskListResponse(msg.Data)
		if decodeErr != nil {
			return nil, decodeErr
		}
		if response.ConvID != uint64(faultCampaignRoomID) {
			return nil, fmt.Errorf("task list room mismatch: got %d want %d", response.ConvID, faultCampaignRoomID)
		}
		tasks := make([]protocol.Task, 0, len(response.Tasks))
		for _, task := range response.Tasks {
			tasks = append(tasks, *task)
		}
		return tasks, nil
	}
	return nil, fmt.Errorf("task list response not received within 24 messages")
}

func listFaultCampaignAssets(conn *websocket.Conn) ([]protocol.Asset, error) {
	const correlationID = uint32(0x50000001)
	payload := protocol.EncodeListAssetsWithCorrelation(faultCampaignRoomID, false, 0, true, correlationID)
	if err := sendFaultCampaignMessage(conn, protocol.C_ListAssets, payload); err != nil {
		return nil, err
	}
	msg, err := readFaultCampaignUntil(conn, protocol.S_AssetList, 24)
	if err != nil {
		return nil, err
	}
	response, err := protocol.DecodeAssetListResponse(msg.Data)
	if err != nil {
		return nil, err
	}
	if response.ConvID != uint64(faultCampaignRoomID) || !response.FullContent || response.CorrelationID != correlationID {
		return nil, fmt.Errorf("asset list response metadata mismatch: got=%+v", response)
	}
	return response.Assets, nil
}

func listFaultCampaignEdges(conn *websocket.Conn) ([]protocol.Edge, error) {
	const correlationID = uint32(0x50000002)
	payload := protocol.EncodeListAllEdgesWithCorrelation(faultCampaignRoomID, correlationID)
	if err := sendFaultCampaignMessage(conn, protocol.C_ListAllEdges, payload); err != nil {
		return nil, err
	}
	msg, err := readFaultCampaignUntil(conn, protocol.S_AllEdgeList, 24)
	if err != nil {
		return nil, err
	}
	response, err := protocol.DecodeAllEdgeListResponse(msg.Data)
	if err != nil {
		return nil, err
	}
	if response.ConvID != uint64(faultCampaignRoomID) || response.CorrelationID != correlationID {
		return nil, fmt.Errorf("edge list response metadata mismatch: got=%+v", response)
	}
	return response.Edges, nil
}

func sendFaultCampaignMessage(conn *websocket.Conn, opcode uint16, payload []byte) error {
	if err := conn.SetWriteDeadline(time.Now().Add(faultCampaignTimeout)); err != nil {
		return err
	}
	return sendProtocolMessage(conn, opcode, payload)
}

func readFaultCampaignTaskList(conn *websocket.Conn) ([]protocol.Task, error) {
	msg, err := readFaultCampaignUntil(conn, protocol.S_TaskListResponse, 24)
	if err != nil {
		return nil, err
	}
	response, err := protocol.DecodeTaskListResponse(msg.Data)
	if err != nil {
		return nil, err
	}
	if response.ConvID != uint64(faultCampaignRoomID) {
		return nil, fmt.Errorf("task list room mismatch: got %d want %d", response.ConvID, faultCampaignRoomID)
	}
	tasks := make([]protocol.Task, 0, len(response.Tasks))
	for _, task := range response.Tasks {
		tasks = append(tasks, *task)
	}
	return tasks, nil
}

func readFaultCampaignUntil(conn *websocket.Conn, opcode uint16, maxReads int) (*protocol.Message, error) {
	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return nil, err
	}
	for i := 0; i < maxReads; i++ {
		msg, err := readFaultCampaignMessage(conn)
		if err != nil {
			return nil, err
		}
		if msg.Opcode == opcode {
			return msg, nil
		}
	}
	return nil, fmt.Errorf("opcode %d not received within %d messages", opcode, maxReads)
}

func readFaultCampaignMessage(conn *websocket.Conn) (*protocol.Message, error) {
	frameType, wireData, err := conn.ReadMessage()
	if err != nil {
		return nil, err
	}
	if frameType != websocket.BinaryMessage {
		return nil, fmt.Errorf("expected binary WebSocket frame, got %d", frameType)
	}
	return protocol.ReadMessage(wireData)
}

func awaitFaultCampaignDisconnect(conn *websocket.Conn, fault string) error {
	deadline := time.Now().Add(faultObservationLimit)
	if err := conn.SetReadDeadline(deadline); err != nil {
		return err
	}
	for {
		_, _, err := conn.ReadMessage()
		if err == nil {
			continue
		}
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			return fmt.Errorf("timed out waiting to observe injected %s", fault)
		}
		return nil
	}
}

func sendQueryWhileServerStopped(server *serverProcess, proxy *tcpFaultProxy, conn *websocket.Conn, hold time.Duration) error {
	if server == nil || server.cmd == nil || server.cmd.Process == nil || server.exited {
		return fmt.Errorf("server is not running")
	}
	if err := server.cmd.Process.Signal(syscall.SIGSTOP); err != nil {
		return fmt.Errorf("SIGSTOP: %w", err)
	}
	resumed := false
	defer func() {
		if !resumed {
			_ = server.cmd.Process.Signal(syscall.SIGCONT)
		}
	}()

	if err := waitForProcessStopped(server.cmd.Process.Pid, faultObservationLimit); err != nil {
		return err
	}
	payload := protocol.EncodeGetTasks(faultCampaignRoomID)
	proxyConnection, forwardedTarget, err := faultCampaignForwardingBarrier(proxy, protocol.C_GetTasks, payload)
	if err != nil {
		return err
	}
	if err := sendFaultCampaignMessage(conn, protocol.C_GetTasks, payload); err != nil {
		return fmt.Errorf("send query while stopped: %w", err)
	}
	if err := waitForForwardedClientBytes(
		proxyConnection,
		forwardedTarget,
		faultObservationLimit,
		"complete stopped-process query frame",
	); err != nil {
		return err
	}
	time.Sleep(hold)
	if err := server.cmd.Process.Signal(syscall.SIGCONT); err != nil {
		return fmt.Errorf("SIGCONT: %w", err)
	}
	resumed = true
	return nil
}

func waitForProcessStopped(pid int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	statusPath := fmt.Sprintf("/proc/%d/status", pid)
	for time.Now().Before(deadline) {
		status, err := os.ReadFile(statusPath)
		if err != nil {
			return fmt.Errorf("read stopped process status: %w", err)
		}
		for _, line := range strings.Split(string(status), "\n") {
			if !strings.HasPrefix(line, "State:") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) >= 2 && (fields[1] == "T" || fields[1] == "t") {
				return nil
			}
		}
		time.Sleep(time.Millisecond)
	}
	return fmt.Errorf("process %d did not enter stopped state within %s", pid, timeout)
}

func faultCampaignForwardingBarrier(proxy *tcpFaultProxy, opcode uint16, payload []byte) (*tcpProxyConnection, uint64, error) {
	connection, err := proxy.soleActiveConnection()
	if err != nil {
		return nil, 0, err
	}
	target, err := faultCampaignForwardingTarget(connection, opcode, payload)
	return connection, target, err
}

func faultCampaignForwardingTarget(connection *tcpProxyConnection, opcode uint16, payload []byte) (uint64, error) {
	// Campaign clients use Gorilla's uncompressed single-frame writes and do
	// not issue competing application writes on the measured connection.
	message := &protocol.Message{Opcode: opcode, Data: payload}
	wireData, err := message.Write()
	if err != nil {
		return 0, fmt.Errorf("encode forwarding barrier message: %w", err)
	}
	frameBytes := len(wireData) + 6 // Base header plus the mandatory client mask.
	if len(wireData) > 125 {
		frameBytes += 2
	}
	if len(wireData) > 65535 {
		frameBytes += 6
	}
	return connection.clientBytes.Load() + uint64(frameBytes), nil
}

func waitForForwardedClientBytes(connection *tcpProxyConnection, target uint64, timeout time.Duration, label string) error {
	deadline := time.Now().Add(timeout)
	for {
		if connection.clientBytes.Load() >= target {
			return nil
		}
		connection.forwardedMu.Lock()
		if connection.clientBytes.Load() >= target {
			connection.forwardedMu.Unlock()
			return nil
		}
		notify := connection.forwardedNotify
		connection.forwardedMu.Unlock()
		remaining := time.Until(deadline)
		if remaining <= 0 {
			break
		}
		select {
		case <-notify:
		case <-time.After(remaining):
			break
		}
		if time.Now().After(deadline) {
			break
		}
	}
	return fmt.Errorf(
		"proxy did not forward %s within %s: got %d bytes, want at least %d",
		label,
		timeout,
		connection.clientBytes.Load(),
		target,
	)
}

func validateFaultCampaignAssetCreation(
	asset protocol.Asset,
	assetType, parentType uint16,
	parentID uint64,
	preview, payload string,
) error {
	if asset.AssetID == 0 ||
		asset.AssetType != assetType ||
		asset.ParentType != parentType ||
		asset.ParentID != parentID ||
		asset.Owner != "outside-in-client" ||
		asset.CreatedAt <= 0 ||
		asset.UpdatedAt != asset.CreatedAt ||
		asset.ConvID != uint64(faultCampaignRoomID) ||
		asset.PayloadEncoding != protocol.AssetPayloadEncodingPlain ||
		asset.PayloadRawLen != uint32(len(payload)) ||
		asset.Preview != preview ||
		asset.Payload != payload ||
		len(asset.Attachments) != 0 {
		return fmt.Errorf("asset differs from requested/default state: got=%+v", asset)
	}
	return nil
}

func validateFaultCampaignAssetUpdate(old, updated protocol.Asset, preview, payload string) error {
	if updated.AssetID != old.AssetID ||
		updated.AssetType != old.AssetType ||
		updated.ParentType != old.ParentType ||
		updated.ParentID != old.ParentID ||
		updated.Owner != old.Owner ||
		updated.CreatedAt != old.CreatedAt ||
		updated.UpdatedAt < old.UpdatedAt ||
		updated.ConvID != old.ConvID ||
		updated.PayloadEncoding != protocol.AssetPayloadEncodingPlain ||
		updated.PayloadRawLen != uint32(len(payload)) ||
		updated.Preview != preview ||
		updated.Payload != payload ||
		len(updated.Attachments) != 0 {
		return fmt.Errorf("updated asset differs from requested/immutable state: old=%+v updated=%+v", old, updated)
	}
	return nil
}

func validateFaultCampaignEdgeCreation(edge protocol.Edge, sourceID, targetID uint64, relation uint16) error {
	if edge.EdgeID == 0 ||
		edge.ConvID != uint64(faultCampaignRoomID) ||
		edge.SourceType != protocol.TargetTypeAsset ||
		edge.SourceID != sourceID ||
		edge.TargetType != protocol.TargetTypeAsset ||
		edge.TargetID != targetID ||
		edge.Relation != relation ||
		edge.CreatedAt <= 0 ||
		edge.CreatedBy != "outside-in-client" {
		return fmt.Errorf("edge differs from requested/default state: got=%+v", edge)
	}
	return nil
}

func validateFaultCampaignCreation(task protocol.Task, title, description string, priority uint8, project string) error {
	if task.ID == 0 {
		return fmt.Errorf("task id is zero")
	}
	if task.ConvID != faultCampaignRoomID ||
		task.Title != title ||
		task.Description != description ||
		task.Priority != priority ||
		task.Project != project ||
		task.Status != protocol.TaskStatusBacklog ||
		task.Assignee != "" ||
		task.Color != protocol.TaskColorNone ||
		task.CreatedBy != "outside-in-client" ||
		task.CreatedAt <= 0 ||
		task.UpdatedAt != task.CreatedAt ||
		task.ExternalRef != "" ||
		task.DueAt != 0 ||
		task.BlockedBy != 0 ||
		task.CompletedAt != 0 ||
		task.CompletedBy != "" ||
		len(task.Attachments) != 0 {
		return fmt.Errorf(
			"creation acknowledgment differs from requested/default state: got=%+v",
			task,
		)
	}
	return nil
}

func validateFaultCampaignUpdate(
	old, updated protocol.Task,
	title, description, assignee string,
	priority, color uint8,
	externalRef string,
	dueAt int64,
	project string,
) error {
	if updated.ID != old.ID ||
		updated.ConvID != old.ConvID ||
		updated.Title != title ||
		updated.Description != description ||
		updated.Status != protocol.TaskStatusInProgress ||
		updated.OrderIndex != old.OrderIndex ||
		updated.Assignee != assignee ||
		updated.Priority != priority ||
		updated.Color != color ||
		updated.CreatedBy != old.CreatedBy ||
		updated.CreatedAt != old.CreatedAt ||
		updated.UpdatedAt < old.UpdatedAt ||
		updated.ExternalRef != externalRef ||
		updated.DueAt != dueAt ||
		updated.BlockedBy != 0 ||
		updated.CompletedAt != 0 ||
		updated.CompletedBy != "" ||
		updated.Project != project ||
		!reflect.DeepEqual(updated.Attachments, old.Attachments) {
		return fmt.Errorf("updated task differs from requested/immutable state: old=%+v updated=%+v", old, updated)
	}
	return nil
}

func resolveFaultCampaignCreate(tasks []protocol.Task, create faultCampaignCreate) (protocol.Task, bool, error) {
	var recovered protocol.Task
	found := false
	for _, task := range tasks {
		if task.Title != create.title {
			continue
		}
		if found {
			return protocol.Task{}, false, fmt.Errorf("multiple tasks recovered with racing title %q", create.title)
		}
		recovered = task
		found = true
	}
	if !found {
		return protocol.Task{}, false, nil
	}
	if err := validateFaultCampaignCreation(
		recovered,
		create.title,
		create.description,
		create.priority,
		create.project,
	); err != nil {
		return protocol.Task{}, false, err
	}
	return recovered, true, nil
}

func checkFaultCampaignModel(actual, expected []protocol.Task) error {
	if len(actual) != len(expected) {
		return fmt.Errorf("task count differs from model: got %d want %d", len(actual), len(expected))
	}
	actualByID := make(map[uint64]protocol.Task, len(actual))
	for _, task := range actual {
		if _, duplicate := actualByID[task.ID]; duplicate {
			return fmt.Errorf("duplicate actual task id %d", task.ID)
		}
		actualByID[task.ID] = task
	}
	expectedIDs := make(map[uint64]struct{}, len(expected))
	for _, want := range expected {
		if _, duplicate := expectedIDs[want.ID]; duplicate {
			return fmt.Errorf("duplicate acknowledged task id %d", want.ID)
		}
		expectedIDs[want.ID] = struct{}{}
		got, ok := actualByID[want.ID]
		if !ok {
			return fmt.Errorf("task %d (%q) missing from model result", want.ID, want.Title)
		}
		if !reflect.DeepEqual(got, want) {
			return fmt.Errorf("task %d differs from complete acknowledged state: got=%+v want=%+v", want.ID, got, want)
		}
	}
	return nil
}

func checkFaultCampaignAssets(actual, expected []protocol.Asset) error {
	if len(actual) != len(expected) {
		return fmt.Errorf("asset count differs from model: got %d want %d", len(actual), len(expected))
	}
	actualByID := make(map[uint64]protocol.Asset, len(actual))
	for _, asset := range actual {
		if _, duplicate := actualByID[asset.AssetID]; duplicate {
			return fmt.Errorf("duplicate actual asset id %d", asset.AssetID)
		}
		actualByID[asset.AssetID] = asset
	}
	expectedIDs := make(map[uint64]struct{}, len(expected))
	for _, want := range expected {
		if _, duplicate := expectedIDs[want.AssetID]; duplicate {
			return fmt.Errorf("duplicate acknowledged asset id %d", want.AssetID)
		}
		expectedIDs[want.AssetID] = struct{}{}
		got, ok := actualByID[want.AssetID]
		if !ok {
			return fmt.Errorf("asset %d (%q) missing from model result", want.AssetID, want.Preview)
		}
		if !reflect.DeepEqual(got, want) {
			return fmt.Errorf("asset %d differs from complete acknowledged state: got=%+v want=%+v", want.AssetID, got, want)
		}
	}
	return nil
}

func checkFaultCampaignEdges(actual, expected []protocol.Edge) error {
	if len(actual) != len(expected) {
		return fmt.Errorf("edge count differs from model: got %d want %d", len(actual), len(expected))
	}
	actualByID := make(map[uint64]protocol.Edge, len(actual))
	for _, edge := range actual {
		if _, duplicate := actualByID[edge.EdgeID]; duplicate {
			return fmt.Errorf("duplicate actual edge id %d", edge.EdgeID)
		}
		actualByID[edge.EdgeID] = edge
	}
	expectedIDs := make(map[uint64]struct{}, len(expected))
	for _, want := range expected {
		if _, duplicate := expectedIDs[want.EdgeID]; duplicate {
			return fmt.Errorf("duplicate acknowledged edge id %d", want.EdgeID)
		}
		expectedIDs[want.EdgeID] = struct{}{}
		got, ok := actualByID[want.EdgeID]
		if !ok {
			return fmt.Errorf("edge %d missing from model result", want.EdgeID)
		}
		if got != want {
			return fmt.Errorf("edge %d differs from complete acknowledged state: got=%+v want=%+v", want.EdgeID, got, want)
		}
	}
	return nil
}
