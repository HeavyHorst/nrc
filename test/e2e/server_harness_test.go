package e2e

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const serverHost = "127.0.0.1"

// Fixed generation-1 Sharded_V1 manifest. Keeping startup strict while seeding
// disposable test installations exercises the same layout gate as production.
const emptyShardedManifestBase64 = "TlJDTAABAAAAAAAAAAAAAQIBAAAAAAAAAAABAAABAACsNnTeRP92XA=="

var serverPort int

type serverProcess struct {
	cmd    *exec.Cmd
	logs   bytes.Buffer
	shared bool
	exited bool
}

var (
	serverBuildOnce sync.Once
	serverBuildPath string
	serverBuildErr  error
	serverBuildLogs string

	sharedServerMu      sync.Mutex
	sharedServerProc    *serverProcess
	sharedServerWorkDir string
)

func TestMain(m *testing.M) {
	port, err := allocateServerPort()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to allocate e2e server port: %v\n", err)
		os.Exit(1)
	}
	serverPort = port

	code := m.Run()
	cleanupSharedServer()
	os.Exit(code)
}

func wsURLForWorkspace(workspace string) string {
	u := url.URL{
		Scheme: "ws",
		Host:   fmt.Sprintf("%s:%d", serverHost, serverPort),
		Path:   "/" + workspace,
	}
	return u.String()
}

func startServer(t *testing.T) *serverProcess {
	t.Helper()
	sharedServerMu.Lock()
	defer sharedServerMu.Unlock()

	if sharedServerProc != nil {
		return sharedServerProc
	}

	sharedWorkDir, err := os.MkdirTemp("", "nrc-e2e-shared-")
	if err != nil {
		t.Fatalf("failed to create shared server work dir: %v", err)
	}

	proc, err := startServerProcess(buildServerBinaryOnce(t), sharedWorkDir)
	if err != nil {
		_ = os.RemoveAll(sharedWorkDir)
		t.Fatalf("failed to start shared server: %v", err)
	}

	proc.shared = true
	sharedServerProc = proc
	sharedServerWorkDir = sharedWorkDir

	return sharedServerProc
}

func startServerInWorkDir(t *testing.T, serverWorkDir string) *serverProcess {
	t.Helper()
	return startServerInWorkDirWithEnv(t, serverWorkDir, nil)
}

func startServerInWorkDirWithEnv(t *testing.T, serverWorkDir string, extraEnv map[string]string) *serverProcess {
	t.Helper()

	stopSharedServerIfRunning()

	proc, err := startServerProcessWithEnv(buildServerBinaryOnce(t), serverWorkDir, extraEnv)
	if err != nil {
		t.Fatalf("failed to start server in work dir %q: %v", serverWorkDir, err)
	}

	return proc
}

func startServerProcess(binPath, workDir string) (*serverProcess, error) {
	return startServerProcessWithEnv(binPath, workDir, nil)
}

func startServerProcessWithEnv(binPath, workDir string, extraEnv map[string]string) (*serverProcess, error) {
	if err := initializeEmptyShardedLayout(workDir); err != nil {
		return nil, fmt.Errorf("failed to initialize sharded test layout: %w", err)
	}

	cmd := exec.Command(binPath)
	cmd.Dir = workDir
	cmd.Env = append(
		os.Environ(),
		"NRC_JWT_SECRET="+e2eJWTSecret,
		"NRC_BOT_SECRET="+metricsBotSecret,
		fmt.Sprintf("NRC_PORT=%d", serverPort),
	)
	for key, value := range extraEnv {
		cmd.Env = append(cmd.Env, key+"="+value)
	}

	proc := &serverProcess{cmd: cmd}
	cmd.Stdout = &proc.logs
	cmd.Stderr = &proc.logs

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start server process: %w", err)
	}

	if err := waitForServerReady(proc.cmd, 10*time.Second); err != nil {
		stopServerProcess(proc)
		return nil, fmt.Errorf("server did not become ready: %v\nserver logs:\n%s", err, proc.logs.String())
	}

	return proc, nil
}

func initializeEmptyShardedLayout(workDir string) error {
	dataDir := filepath.Join(workDir, "data")
	manifestPath := filepath.Join(dataDir, "storage-layout.manifest")
	if _, err := os.Stat(manifestPath); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	generationDir := filepath.Join(dataDir, "sharded-00000000000000000001")
	for shard := 0; shard < 256; shard++ {
		shardDir := filepath.Join(generationDir, fmt.Sprintf("shard_%03d", shard))
		if err := os.MkdirAll(shardDir, 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(shardDir, "active.wal"), nil, 0o644); err != nil {
			return err
		}
	}

	manifest, err := base64.StdEncoding.DecodeString(emptyShardedManifestBase64)
	if err != nil {
		return err
	}
	return os.WriteFile(manifestPath, manifest, 0o644)
}

func buildServerBinaryOnce(t *testing.T) string {
	t.Helper()

	repoRoot := repoRootFromThisFile(t)
	odinBin := discoverOdinBinary()

	serverBuildOnce.Do(func() {
		buildDir, err := os.MkdirTemp("", "nrc-e2e-bin-")
		if err != nil {
			serverBuildErr = fmt.Errorf("failed to create temp build dir: %w", err)
			return
		}

		serverBuildPath = filepath.Join(buildDir, "nrc-server-e2e")
		buildCmd := exec.Command(odinBin, "build", ".", "-o:speed", "-define:NRC_SHARD_COMPACTION_SIZE_THRESHOLD=8192", "-define:NRC_MESSAGE_SEGMENT_BYTES=128", "-out:"+serverBuildPath)
		buildCmd.Dir = repoRoot
		buildOutput, err := buildCmd.CombinedOutput()
		serverBuildLogs = string(buildOutput)
		if err != nil {
			serverBuildErr = fmt.Errorf("failed to build server with %q: %w", odinBin, err)
		}
	})

	if serverBuildErr != nil {
		t.Fatalf("%v\n%s", serverBuildErr, serverBuildLogs)
	}

	return serverBuildPath
}

func (p *serverProcess) stop(t *testing.T) {
	t.Helper()

	if p != nil && p.shared {
		return
	}

	stopServerProcess(p)
}

func (p *serverProcess) stopGracefully(t *testing.T) {
	t.Helper()
	if p == nil || p.cmd == nil || p.cmd.Process == nil || p.exited {
		return
	}
	if err := p.cmd.Process.Signal(syscall.SIGINT); err != nil {
		t.Fatalf("failed to signal server for graceful stop: %v", err)
	}
	done := make(chan error, 1)
	go func() { done <- p.cmd.Wait() }()
	select {
	case err := <-done:
		p.exited = true
		if err != nil {
			t.Fatalf("server exited unsuccessfully during graceful stop: %v\nlogs:\n%s", err, p.logs.String())
		}
	case <-time.After(5 * time.Second):
		_ = p.cmd.Process.Kill()
		<-done
		p.exited = true
		t.Fatalf("server did not complete graceful stop within 5 seconds\nlogs:\n%s", p.logs.String())
	}
}

func (p *serverProcess) killAndWait(t *testing.T) {
	t.Helper()
	if p == nil || p.cmd == nil || p.cmd.Process == nil || p.exited {
		return
	}
	if err := p.cmd.Process.Kill(); err != nil {
		t.Fatalf("failed to kill server process: %v", err)
	}
	err := p.cmd.Wait()
	p.exited = true
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			t.Fatalf("failed to wait for killed server process: %v", err)
		}
	}
}

func stopServerProcess(p *serverProcess) {
	if p == nil || p.cmd == nil || p.cmd.Process == nil || p.exited {
		return
	}

	_ = p.cmd.Process.Signal(syscall.SIGINT)

	done := make(chan error, 1)
	go func() {
		done <- p.cmd.Wait()
	}()

	select {
	case <-time.After(5 * time.Second):
		_ = p.cmd.Process.Kill()
		<-done
	case <-done:
	}
	p.exited = true
}

func stopSharedServerIfRunning() {
	sharedServerMu.Lock()
	defer sharedServerMu.Unlock()

	if sharedServerProc != nil {
		stopServerProcess(sharedServerProc)
		sharedServerProc = nil
	}

	if sharedServerWorkDir != "" {
		_ = os.RemoveAll(sharedServerWorkDir)
		sharedServerWorkDir = ""
	}
}

func cleanupSharedServer() {
	stopSharedServerIfRunning()
}

func waitForServerReady(cmd *exec.Cmd, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	lastErr := error(nil)

	for time.Now().Before(deadline) {
		if cmd.ProcessState != nil && cmd.ProcessState.Exited() {
			return fmt.Errorf("server exited early")
		}

		remaining := time.Until(deadline)
		if remaining <= 0 {
			break
		}
		probeTimeout := min(remaining, 500*time.Millisecond)
		if err := probeServerReady(probeTimeout); err == nil {
			return nil
		} else {
			lastErr = err
		}

		time.Sleep(100 * time.Millisecond)
	}

	if lastErr != nil {
		return fmt.Errorf("timeout waiting for websocket server ready: %w", lastErr)
	}
	return fmt.Errorf("timeout waiting for websocket server ready")
}

func probeServerReady(timeout time.Duration) error {
	if timeout <= 0 {
		timeout = 250 * time.Millisecond
	}

	token, err := buildProxyStyleJWT("e2e-ready-probe", time.Now(), "e2e-ready-probe")
	if err != nil {
		return fmt.Errorf("build readiness auth token: %w", err)
	}

	headers := make(http.Header)
	headers.Set("X-NRC-Auth", token)

	dialer := *websocket.DefaultDialer
	dialer.HandshakeTimeout = timeout

	conn, _, err := dialer.Dial(wsURLForWorkspace("e2e-ready-probe"), headers)
	if err != nil {
		return fmt.Errorf("readiness websocket dial: %w", err)
	}
	defer conn.Close()

	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return fmt.Errorf("set readiness read deadline: %w", err)
	}

	frameType, wireData, err := conn.ReadMessage()
	if err != nil {
		return fmt.Errorf("read readiness websocket message: %w", err)
	}
	if frameType != websocket.BinaryMessage {
		return fmt.Errorf("readiness expected binary frame, got frame type %d", frameType)
	}

	msg, err := protocol.ReadMessage(wireData)
	if err != nil {
		return fmt.Errorf("parse readiness protocol message: %w", err)
	}
	if msg.Opcode != protocol.S_ServerReady {
		return fmt.Errorf("readiness expected opcode %d (ServerReady), got %d", protocol.S_ServerReady, msg.Opcode)
	}

	return nil
}

func repoRootFromThisFile(t *testing.T) string {
	t.Helper()

	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("failed to resolve current file path")
	}

	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
	if _, err := os.Stat(filepath.Join(root, "server.odin")); err != nil {
		t.Fatalf("failed to validate repo root %q: %v", root, err)
	}

	return root
}

func discoverOdinBinary() string {
	if custom := os.Getenv("NRC_ODIN_BIN"); custom != "" {
		return custom
	}

	const configuredOdinPath = "/home/rene/Code/Odin/odin"
	if _, err := os.Stat(configuredOdinPath); err == nil {
		return configuredOdinPath
	}

	return "odin"
}

func allocateServerPort() (int, error) {
	ln, err := net.Listen("tcp", net.JoinHostPort(serverHost, "0"))
	if err != nil {
		return 0, err
	}
	defer ln.Close()

	address, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		return 0, fmt.Errorf("unexpected listener address %T", ln.Addr())
	}
	return address.Port, nil
}

func isConnClosed(err error) bool {
	if err == nil {
		return false
	}

	return errors.Is(err, net.ErrClosed)
}
