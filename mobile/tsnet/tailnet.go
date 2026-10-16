// Package tailnet provides a narrow gomobile bridge, not a device-wide VPN.
package tailnet

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"

	"tailscale.com/tsnet"
)

// Node owns an embedded Tailscale identity and a loopback CONNECT proxy limited
// to one NRC endpoint. The original URL stays in OkHttp, preserving DNS authority,
// TLS SNI, certificate verification and the WebSocket handshake.
type Node struct {
	server           tsnet.Server
	proxy            *http.Server
	address          string
	password         string
	target           string
	ctx              context.Context
	cancel           context.CancelFunc
	mu               sync.Mutex
	closed           bool
	tunnels          map[net.Conn]bool
	dialFailure      string
	dialFailureCount int64
}

// Start uses browser enrollment (no auth key in an APK). State must be stored in
// an app-private directory. controlURL may be empty for Tailscale's hosted control.
func Start(directory, controlURL, target string) (*Node, error) {
	if directory == "" {
		return nil, fmt.Errorf("private state directory required")
	}
	if _, _, err := net.SplitHostPort(target); err != nil {
		return nil, err
	}
	if controlURL != "" {
		u, err := url.Parse(controlURL)
		if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil {
			return nil, fmt.Errorf("invalid control URL")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	n := &Node{target: target, ctx: ctx, cancel: cancel, tunnels: make(map[net.Conn]bool)}
	n.server = tsnet.Server{Dir: directory, Hostname: "nrc-mobile", ControlURL: controlURL,
		Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {}}
	if _, err := n.server.LocalClient(); err != nil {
		cancel()
		n.server.Close()
		return nil, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		n.Close()
		return nil, err
	}
	n.address = listener.Addr().String()
	n.password = rand.Text()
	n.proxy = &http.Server{Handler: http.HandlerFunc(n.connect), ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 8192}
	go n.proxy.Serve(listener)
	return n, nil
}

func (n *Node) Address() string  { return n.address }
func (n *Node) Password() string { return n.password }

// DialFailure returns only a fixed diagnostic code, never an address or raw
// error. It describes the most recently completed dial and clears on success.
func (n *Node) DialFailure() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.dialFailure
}

// DialFailureCount lets the host report each failed attempt, including a retry
// after the user clears the system log. It never includes error text.
func (n *Node) DialFailureCount() int64 {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.dialFailureCount
}

// Logout removes the active embedded login/profile, not the application's data
// directory. The host closes this node before starting the next browser login.
func (n *Node) Logout() error {
	lc, err := n.server.LocalClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(n.ctx, 10*time.Second)
	defer cancel()
	return lc.Logout(ctx)
}

// Login requests a fresh interactive URL, including after node-key expiry.
func (n *Node) Login() error {
	lc, err := n.server.LocalClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(n.ctx, 5*time.Second)
	defer cancel()
	return lc.StartLoginInteractive(ctx)
}

func (n *Node) Status() (string, error) {
	lc, err := n.server.LocalClient()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(n.ctx, 5*time.Second)
	defer cancel()
	status, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return "", err
	}
	return status.BackendState, nil
}

func (n *Node) AuthURL() (string, error) {
	lc, err := n.server.LocalClient()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(n.ctx, 5*time.Second)
	defer cancel()
	status, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return "", err
	}
	return status.AuthURL, nil
}

func (n *Node) connect(w http.ResponseWriter, r *http.Request) {
	expected := "Basic " + base64.StdEncoding.EncodeToString([]byte("nrc:"+n.password))
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Proxy-Authorization")), []byte(expected)) != 1 {
		w.Header().Set("Proxy-Authenticate", `Basic realm="nrc-tailnet"`)
		w.WriteHeader(http.StatusProxyAuthRequired)
		return
	}
	if r.Method != http.MethodConnect || r.Host != n.target {
		http.Error(w, "endpoint refused", http.StatusForbidden)
		return
	}
	ctx, cancel := context.WithTimeout(n.ctx, 15*time.Second)
	defer cancel()
	upstream, err := n.server.Dial(ctx, "tcp", n.target)
	if err != nil {
		var dns *net.DNSError
		var network net.Error
		code := "other"
		switch {
		case errors.As(err, &dns):
			code = "dns"
		case errors.Is(err, context.Canceled):
			code = "canceled"
		case errors.Is(err, context.DeadlineExceeded), errors.As(err, &network) && network.Timeout():
			code = "timeout"
		case errors.Is(err, syscall.ECONNREFUSED), strings.HasSuffix(err.Error(), "connection was refused"):
			code = "refused"
		case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH):
			code = "unreachable"
		case errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
			code = "permission"
		}
		n.mu.Lock()
		n.dialFailure = code
		n.dialFailureCount++
		n.mu.Unlock()
		http.Error(w, "tailnet unavailable", http.StatusBadGateway)
		return
	}
	n.mu.Lock()
	n.dialFailure = ""
	n.mu.Unlock()
	client, buffered, err := w.(http.Hijacker).Hijack()
	if err != nil {
		upstream.Close()
		return
	}
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		client.Close()
		upstream.Close()
		return
	}
	n.tunnels[client], n.tunnels[upstream] = true, true
	n.mu.Unlock()
	defer func() {
		client.Close()
		upstream.Close()
		n.mu.Lock()
		delete(n.tunnels, client)
		delete(n.tunnels, upstream)
		n.mu.Unlock()
	}()
	if _, err := buffered.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	if err := buffered.Flush(); err != nil {
		return
	}
	done := make(chan struct{})
	go func() { io.Copy(upstream, buffered); upstream.Close(); close(done) }()
	io.Copy(client, upstream)
	client.Close()
	<-done
}

// Close also tears down hijacked WebSocket connections; http.Server.Close alone
// deliberately leaves hijacked connections open.
func (n *Node) Close() error {
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		return nil
	}
	n.closed = true
	n.cancel()
	for conn := range n.tunnels {
		conn.Close()
	}
	n.mu.Unlock()
	if n.proxy != nil {
		n.proxy.Close()
	}
	return n.server.Close()
}
