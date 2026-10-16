package tailnet

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"tailscale.com/tsnet"
)

// This is a real two-node tailnet integration test, not a mocked dialer. Point
// it ONLY at a disposable Headscale lab, with pre-created nrc-lab and
// nrc-lab-switch users.
func TestHeadscale(t *testing.T) {
	binary, config := os.Getenv("NRC_HEADSCALE_BINARY"), os.Getenv("NRC_HEADSCALE_CONFIG")
	if binary == "" || config == "" {
		t.Skip("set NRC_HEADSCALE_BINARY and NRC_HEADSCALE_CONFIG for disposable lab")
	}
	// Enrollment must not accidentally use a credential inherited by the orb.
	for _, name := range []string{"TS_AUTHKEY", "TS_CLIENT_ID", "TS_CLIENT_SECRET", "TS_ID_TOKEN"} {
		t.Setenv(name, "")
	}
	control := "http://127.0.0.1:18080"
	serverName := fmt.Sprintf("nrc-fixture-%d", time.Now().UnixNano())
	host := serverName + ".nrc-lab.test"
	target := host + ":8443"
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	approveUser := "nrc-lab"
	approve := func(authURL string) {
		u, err := url.Parse(authURL)
		if err != nil || !strings.HasPrefix(authURL, control+"/register/") {
			t.Fatal("unexpected enrollment URL")
		}
		cmd := exec.CommandContext(ctx, binary, "-c", config, "auth", "register", "--user", approveUser, "--auth-id", filepath.Base(u.Path), "--output", "json")
		cmd.Dir = filepath.Dir(config) // fixture paths, including the admin socket, are relative
		output, err := cmd.Output()
		if err != nil {
			t.Fatal("Headscale enrollment failed")
		}
		var registered struct {
			ID uint64 `json:"id"`
		}
		if err := json.Unmarshal(output, &registered); err != nil || registered.ID == 0 {
			t.Fatal("invalid Headscale enrollment response")
		}
		t.Cleanup(func() {
			cmd := exec.Command(binary, "-c", config, "nodes", "delete", "--identifier", fmt.Sprint(registered.ID), "--force")
			cmd.Dir = filepath.Dir(config)
			if err := cmd.Run(); err != nil {
				t.Error("could not remove disposable test node")
			}
		})
	}
	server := &tsnet.Server{Dir: t.TempDir(), Hostname: serverName, ControlURL: control,
		Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {}}
	defer server.Close()
	lc, err := server.LocalClient()
	if err != nil {
		t.Fatal(err)
	}
	approved := false
	for {
		status, err := lc.StatusWithoutPeers(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if status.BackendState == "Running" {
			break
		}
		if status.AuthURL != "" && !approved {
			approve(status.AuthURL)
			approved = true
		}
		select {
		case <-ctx.Done():
			t.Fatal("server enrollment timed out")
		case <-time.After(100 * time.Millisecond):
		}
	}
	cert, certPEM := labCertificate(t, host)
	listener, err := server.Listen("tcp", ":8443")
	if err != nil {
		t.Fatal(err)
	}
	fixture := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		who, err := lc.WhoIs(r.Context(), r.RemoteAddr)
		if err != nil {
			http.Error(w, "identity unavailable", 403)
			return
		}
		identity := who.UserProfile.LoginName + "/" + string(who.Node.StableID)
		if r.URL.Path == "/socket" {
			conn, err := websocket.Accept(w, r, nil)
			if err != nil {
				return
			}
			defer conn.CloseNow()
			for {
				kind, data, err := conn.Read(r.Context())
				if err != nil {
					return
				}
				if err := conn.Write(r.Context(), kind, data); err != nil {
					return
				}
			}
		}
		io.WriteString(w, identity)
	}), TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}}, ErrorLog: nil}
	go fixture.Serve(tls.NewListener(listener, fixture.TLSConfig))
	defer fixture.Close()
	stateDir := t.TempDir()
	node, err := Start(stateDir, control, target)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { node.Close() }()
	if err := node.Login(); err != nil {
		t.Fatal(err)
	}
	awaitEnrollment := func() {
		approved := false
		for {
			status, err := node.Status()
			if err != nil {
				t.Fatal(err)
			}
			if status == "Running" {
				if !approved {
					t.Fatal("client became Running without requested enrollment")
				}
				break
			}
			authURL, err := node.AuthURL()
			if err != nil {
				t.Fatal(err)
			}
			if authURL != "" && !approved {
				approve(authURL)
				approved = true
			}
			select {
			case <-ctx.Done():
				t.Fatal("client enrollment timed out")
			case <-time.After(100 * time.Millisecond):
			}
		}
	}
	awaitEnrollment()
	t.Log("interactive enrollment: server and embedded client Running")
	// Running can precede delivery of this fixture peer in the network map.
	// Establish fixture readiness explicitly before testing target behavior.
	awaitPeer := func() {
		lc, err := node.server.LocalClient()
		if err != nil {
			t.Fatal(err)
		}
		for {
			status, err := lc.Status(ctx)
			if err != nil {
				t.Fatal(err)
			}
			for _, peer := range status.Peer {
				if strings.TrimSuffix(peer.DNSName, ".") == host {
					return
				}
			}
			select {
			case <-ctx.Done():
				t.Fatal("fixture peer did not arrive in client network map")
			case <-time.After(100 * time.Millisecond):
			}
		}
	}
	awaitPeer()
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(certPEM)
	proxyURL, _ := url.Parse("http://" + node.Address())
	proxyURL.User = url.UserPassword("nrc", node.Password())
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSClientConfig: &tls.Config{RootCAs: roots}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	endpoint := "https://" + target
	expectedUser := "nrc-lab@example.test/"
	readIdentity := func() string {
		response, err := client.Get(endpoint)
		if err != nil {
			t.Fatalf("HTTPS fixture failed: %v (dial diagnostic: %s)", err, node.DialFailure())
		}
		defer response.Body.Close()
		body, _ := io.ReadAll(response.Body)
		if response.StatusCode != 200 || !strings.HasPrefix(string(body), expectedUser) {
			t.Fatalf("unexpected verified identity: %q", body)
		}
		return string(body)
	}
	identity := readIdentity()
	t.Log("HTTPS through CONNECT: verified Headscale user and node identity")
	direct := &http.Client{Transport: &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{RootCAs: roots}}, Timeout: 2 * time.Second}
	if response, err := direct.Get(endpoint); err == nil {
		response.Body.Close()
		t.Fatal("endpoint unexpectedly reachable without embedded tailnet")
	}
	t.Log("control: same URL without embedded tailnet fails")
	untrustedTransport := &http.Transport{Proxy: http.ProxyURL(proxyURL)}
	defer untrustedTransport.CloseIdleConnections()
	if response, err := (&http.Client{Transport: untrustedTransport, Timeout: 10 * time.Second}).Get(endpoint); err == nil {
		response.Body.Close()
		t.Fatal("untrusted TLS certificate accepted")
	}
	wrongHostTransport := &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSClientConfig: &tls.Config{RootCAs: roots, ServerName: "wrong.nrc-lab.test"}}
	defer wrongHostTransport.CloseIdleConnections()
	if response, err := (&http.Client{Transport: wrongHostTransport, Timeout: 10 * time.Second}).Get(endpoint); err == nil {
		response.Body.Close()
		t.Fatal("wrong TLS hostname accepted")
	}
	for _, test := range []struct {
		password, authority string
		expected            int
	}{{"wrong", target, 407}, {node.Password(), "other.nrc-lab.test:443", 403}} {
		request, _ := http.NewRequestWithContext(ctx, "CONNECT", "http://"+node.Address(), nil)
		request.Host = test.authority
		request.Header.Set("Proxy-Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte("nrc:"+test.password)))
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != test.expected {
			t.Fatalf("proxy control: got %d, expected %d", response.StatusCode, test.expected)
		}
	}
	t.Log("security controls: bad proxy credential, foreign destination, untrusted TLS and wrong TLS hostname rejected")
	conn, _, err := websocket.Dial(ctx, "wss://"+target+"/socket", &websocket.DialOptions{HTTPClient: client})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	payload := []byte{0, 128, 255, 1, 42}
	if err := conn.Write(ctx, websocket.MessageBinary, payload); err != nil {
		t.Fatal(err)
	}
	kind, data, err := conn.Read(ctx)
	if err != nil || kind != websocket.MessageBinary || string(data) != string(payload) {
		t.Fatal("binary WebSocket echo differs")
	}
	t.Log("WSS: exact binary roundtrip passed")
	if classPath := os.Getenv("NRC_OKHTTP_CLASSPATH"); classPath != "" {
		properties := fmt.Sprintf("proxy=%s\npassword=%s\ntarget=%s\ncertificate=%s\n", node.Address(), node.Password(), target, base64.StdEncoding.EncodeToString(certPEM))
		path := filepath.Join(t.TempDir(), "probe.properties")
		if err := os.WriteFile(path, []byte(properties), 0600); err != nil {
			t.Fatal(err)
		}
		cmd := exec.CommandContext(ctx, "java", "-cp", classPath, "OkHttpProbe", path)
		output, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("OkHttp probe failed: %s", output)
		}
		t.Log(strings.TrimSpace(string(output)))
	} else {
		t.Log("OkHttp JVM probe not requested (NRC_OKHTTP_CLASSPATH unset)")
	}
	oldAddress := node.Address()
	if err := node.Close(); err != nil {
		t.Fatal(err)
	}
	readCtx, readCancel := context.WithTimeout(ctx, 3*time.Second)
	defer readCancel()
	if _, _, err := conn.Read(readCtx); err == nil || readCtx.Err() != nil {
		t.Fatal("closing node did not promptly close active WSS tunnel")
	}
	transport.CloseIdleConnections()
	node, err = Start(stateDir, control, target)
	if err != nil {
		t.Fatal(err)
	}
	for {
		status, err := node.Status()
		if err != nil {
			t.Fatal(err)
		}
		if status == "Running" {
			break
		}
		authURL, err := node.AuthURL()
		if err != nil {
			t.Fatal(err)
		}
		if authURL != "" {
			t.Fatal("persistent state unexpectedly requires re-enrollment")
		}
		select {
		case <-ctx.Done():
			t.Fatal("restart timed out")
		case <-time.After(100 * time.Millisecond):
		}
	}
	proxyURL, _ = url.Parse("http://" + node.Address())
	proxyURL.User = url.UserPassword("nrc", node.Password())
	transport.Proxy = http.ProxyURL(proxyURL)
	awaitPeer()
	if got := readIdentity(); got != identity {
		t.Fatal("restart changed tailnet identity")
	}
	if _, err := (&http.Client{Timeout: time.Second}).Get("http://" + oldAddress); err == nil {
		t.Fatal("old proxy still listening")
	}
	t.Log("lifecycle: active WSS closed, old proxy stopped, persisted identity reconnects without enrollment")

	// The public bridge must preserve failure categories even though CONNECT
	// deliberately returns only 502, never native error text or private addresses.
	for _, test := range []struct{ target, code string }{
		{host + ":8444", "refused"},
		{serverName + ".invalid:8443", "dns"},
	} {
		transport.CloseIdleConnections()
		if err := node.Close(); err != nil {
			t.Fatal(err)
		}
		node, err = Start(stateDir, control, test.target)
		if err != nil {
			t.Fatal(err)
		}
		awaitPeer()
		proxyURL, _ = url.Parse("http://" + node.Address())
		proxyURL.User = url.UserPassword("nrc", node.Password())
		transport.Proxy = http.ProxyURL(proxyURL)
		endpoint = "https://" + test.target
		if response, err := client.Get(endpoint); err == nil {
			response.Body.Close()
			t.Fatal("unavailable endpoint unexpectedly connected")
		}
		if got := node.DialFailure(); got != test.code {
			t.Fatalf("dial diagnostic: got %q, expected %q", got, test.code)
		}
		if node.DialFailureCount() != 1 {
			t.Fatal("failed dial must advance the diagnostic counter once")
		}
		if test.code == "refused" {
			listener, err := server.Listen("tcp", ":8444")
			if err != nil {
				t.Fatal(err)
			}
			go fixture.Serve(tls.NewListener(listener, fixture.TLSConfig))
			if got := readIdentity(); got != identity || node.DialFailure() != "" || node.DialFailureCount() != 1 {
				t.Fatal("recovered dial must preserve identity and clear its diagnostic")
			}
		}
	}
	t.Log("dial diagnostics: refused port, recovery and missing DNS name classified without raw error text")
	if err := node.Logout(); err != nil {
		t.Fatal(err)
	}
	if status, err := node.Status(); err != nil || status == "Running" {
		t.Fatalf("logout left an authenticated backend: %s %v", status, err)
	}
	transport.CloseIdleConnections()
	if err := node.Close(); err != nil {
		t.Fatal(err)
	}
	node, err = Start(stateDir, control, target)
	if err != nil {
		t.Fatal(err)
	}
	approveUser = "nrc-lab-switch"
	expectedUser = "nrc-lab-switch@example.test/"
	if err := node.Login(); err != nil {
		t.Fatal(err)
	}
	awaitEnrollment()
	awaitPeer()
	proxyURL, _ = url.Parse("http://" + node.Address())
	proxyURL.User = url.UserPassword("nrc", node.Password())
	transport.Proxy = http.ProxyURL(proxyURL)
	endpoint = "https://" + target
	if got := readIdentity(); got == identity {
		t.Fatal("logout and re-enrollment retained the previous identity")
	}
	t.Log("account switch: same state directory re-enrolled as a different verified user after logout")
}

func labCertificate(t *testing.T, hostname string) (tls.Certificate, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "NRC disposable lab"}, DNSNames: []string{hostname}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, _ := x509.MarshalECPrivateKey(key)
	cert, err := tls.X509KeyPair(certPEM, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}))
	if err != nil {
		t.Fatal(err)
	}
	return cert, certPEM
}
