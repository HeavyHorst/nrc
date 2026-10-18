package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/pem"
	"net"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/oauth2"
)

func TestBuildMailRoundTrip(t *testing.T) {
	data := bytes.Repeat([]byte{0, 255, 128, 13, 10}, 100)
	raw, err := buildMail("Änne <a@example.com>", "b@example.com", "a+token@example.com", "Grüße 世界", "<one@example.com>", []string{"<old@example.com>"}, "Hallo 世界\nGrüße", []mailAttachment{{"Übung.bin", "application/octet-stream", data}})
	if err != nil {
		t.Fatal(err)
	}
	m, err := parseMail(raw)
	if err != nil {
		t.Fatal(err)
	}
	if m.ReplyTo != "a+token@example.com" || m.Name != "Änne" || m.Subject != "Grüße 世界" || m.Body != "Hallo 世界\nGrüße" || m.ID != "<one@example.com>" || len(m.References) != 1 || len(m.Files) != 1 || m.Files[0].Name != "Übung.bin" || !bytes.Equal(m.Files[0].Data, data) {
		t.Fatalf("bad roundtrip: %+v", m)
	}
	for _, line := range strings.Split(string(raw), "\r\n") {
		if len(line) > 76 && !strings.Contains(line, ":") {
			t.Fatalf("unwrapped base64: %d", len(line))
		}
	}
}

func TestBuildMailRejects(t *testing.T) {
	for _, field := range []string{"from", "to", "reply-to", "subject", "id", "reference", "filename", "type", "body", "size"} {
		t.Run(field, func(t *testing.T) {
			from, to, subject, id, body := "a@example.com", "b@example.com", "subject", "<id@example.com>", "body"
			replyTo := "a+token@example.com"
			refs := []string{"<old@example.com>"}
			files := []mailAttachment{{"a.bin", "application/octet-stream", []byte{1}}}
			switch field {
			case "from":
				from += "\r\nBcc: x@example.com"
			case "to":
				to += "\nBcc: x@example.com"
			case "reply-to":
				replyTo += "\r\nBcc: x@example.com"
			case "subject":
				subject += "\r\nBcc: x@example.com"
			case "id":
				id = "<a> <b>"
			case "reference":
				refs[0] = "<x>\r\nBcc: x"
			case "filename":
				files[0].Name = "x\r\nBcc: x"
			case "type":
				files[0].Type = "text/plain\r\nBcc: x"
			case "body":
				body = strings.Repeat("ü", 16001)
			case "size":
				files[0].Data = make([]byte, 25<<20)
			}
			if _, err := buildMail(from, to, replyTo, subject, id, refs, body, files); err == nil {
				t.Fatal("accepted invalid mail")
			}
		})
	}
}

func TestSMTPRequiresTLS(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(5 * time.Second))
		c.Write([]byte("220 fixture\r\n"))
		r := bufio.NewReader(c)
		if _, err := r.ReadString('\n'); err != nil {
			return
		}
		c.Write([]byte("250 fixture\r\n"))
	}()
	state, err := sendSMTP(context.Background(), smtpMailConfig{Address: l.Addr().String(), Host: "localhost", From: "a@example.com"}, "b@example.com", []byte("test"))
	if state != "failed" || err == nil {
		t.Fatalf("%s %v", state, err)
	}
	<-done
}

func TestSMTPRejectsUntrustedImplicitTLS(t *testing.T) {
	fixture := httptest.NewTLSServer(nil)
	defer fixture.Close()
	// The fixture certificate is intentionally not trusted by production TLS.
	state, err := sendSMTP(context.Background(), smtpMailConfig{Address: fixture.Listener.Addr().String(), Host: "localhost", From: "a@example.com", ImplicitTLS: true}, "b@example.com", nil)
	if state != "failed" || err == nil {
		t.Fatalf("%s %v", state, err)
	}
}

// A fresh process loads a fixture CA through the real system trust loader. The
// production transport is exercised unchanged, never InsecureSkipVerify.
func TestSMTPVerifiedRelayOutcomes(t *testing.T) {
	if os.Getenv("NRC_SMTP_FIXTURE_CHILD") == "1" {
		want := os.Getenv("NRC_SMTP_FIXTURE_STATE")
		config := smtpMailConfig{Address: os.Getenv("NRC_SMTP_FIXTURE_ADDRESS"), Host: "127.0.0.1", From: "support@our.test", ImplicitTLS: true}
		if want == "oauth" {
			config.Username = "support@our.test"
			config.OAuth2 = &mailOAuthConfig{cached: &oauth2.Token{AccessToken: "fixture-token", Expiry: time.Now().Add(time.Hour)}}
			want = "sent"
		}
		state, err := sendSMTP(context.Background(), config, "anna@customer.test", []byte("Subject: Test\r\n\r\nHello"))
		if state != want || (err == nil) != (want == "sent") {
			t.Fatalf("got %s %v, want %s", state, err, want)
		}
		return
	}
	certServer := httptest.NewTLSServer(nil)
	cert := certServer.TLS.Certificates[0]
	certServer.Close()
	ca := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]}), 0600); err != nil {
		t.Fatal(err)
	}
	for _, outcome := range []string{"sent", "failed", "unknown", "oauth"} {
		t.Run(outcome, func(t *testing.T) {
			listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			done := make(chan string, 1)
			go func() {
				conn, e := listener.Accept()
				if e != nil {
					done <- "accept failed"
					return
				}
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(10 * time.Second))
				r := bufio.NewReader(conn)
				conn.Write([]byte("220 relay\r\n"))
				authOK := false
				for {
					line, e := r.ReadString('\n')
					if e != nil {
						done <- "read failed"
						return
					}
					if outcome == "oauth" && strings.HasPrefix(line, "EHLO ") {
						conn.Write([]byte("250-relay\r\n250 AUTH XOAUTH2\r\n"))
						continue
					}
					if strings.HasPrefix(line, "AUTH ") {
						parts := strings.Fields(line)
						if len(parts) != 3 || parts[1] != "XOAUTH2" {
							done <- "wrong auth mechanism"
							return
						}
						value, err := base64.StdEncoding.DecodeString(parts[2])
						if err != nil || string(value) != "user=support@our.test\x01auth=Bearer fixture-token\x01\x01" {
							done <- "wrong OAuth credentials"
							return
						}
						authOK = true
						conn.Write([]byte("235 authenticated\r\n"))
						continue
					}
					if strings.HasPrefix(line, "DATA") {
						if outcome == "oauth" && !authOK {
							done <- "missing OAuth authentication"
							return
						}
						conn.Write([]byte("354 send mail\r\n"))
						var data strings.Builder
						for {
							line, e = r.ReadString('\n')
							if e != nil {
								done <- "DATA failed"
								return
							}
							if line == ".\r\n" {
								break
							}
							data.WriteString(line)
						}
						if !strings.Contains(data.String(), "Hello") {
							done <- "wrong message"
							return
						}
						if outcome == "sent" || outcome == "oauth" {
							conn.Write([]byte("250 accepted\r\n"))
						} else if outcome == "failed" {
							conn.Write([]byte("550 rejected\r\n"))
						}
						done <- "ok"
						return
					}
					conn.Write([]byte("250 relay\r\n"))
				}
			}()
			cmd := exec.Command(os.Args[0], "-test.run=^TestSMTPVerifiedRelayOutcomes$")
			cmd.Env = append(os.Environ(), "NRC_SMTP_FIXTURE_CHILD=1", "NRC_SMTP_FIXTURE_ADDRESS="+listener.Addr().String(), "NRC_SMTP_FIXTURE_STATE="+outcome, "SSL_CERT_FILE="+ca)
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("%v: %s", err, output)
			}
			if result := <-done; result != "ok" {
				t.Fatal(result)
			}
		})
	}
}
