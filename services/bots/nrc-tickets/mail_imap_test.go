package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type imapFixture struct {
	mu                                                 sync.Mutex
	validity, next                                     uint32
	messages                                           map[uint32]string
	oversize, drop                                     uint32
	bodyFirst, missing, vanish, wrongUID, largeLiteral bool
	commands                                           []string
	auth                                               string
}

func (f *imapFixture) serve(conn net.Conn, cert tls.Certificate, startTLS bool) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	r := bufio.NewReader(conn)
	fmt.Fprint(conn, "* OK [CAPABILITY IMAP4rev1 AUTH=XOAUTH2 SASL-IR STARTTLS] fixture\r\n")
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return
		}
		tag, command := fields[0], strings.ToUpper(fields[1])
		f.mu.Lock()
		f.commands = append(f.commands, strings.TrimSpace(strings.Join(fields[1:], " ")))
		validity, next := f.validity, f.next
		f.mu.Unlock()
		switch command {
		case "STARTTLS":
			if !startTLS {
				return
			}
			fmt.Fprintf(conn, "%s OK Begin TLS\r\n", tag)
			conn = tls.Server(conn, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
			r = bufio.NewReader(conn)
			startTLS = false
		case "CAPABILITY":
			fmt.Fprintf(conn, "* CAPABILITY IMAP4rev1 AUTH=XOAUTH2 SASL-IR\r\n%s OK capabilities\r\n", tag)
		case "LOGIN":
			if startTLS {
				return
			}
			fmt.Fprintf(conn, "%s OK authenticated\r\n", tag)
		case "AUTHENTICATE":
			if startTLS || len(fields) != 4 || fields[2] != "XOAUTH2" {
				return
			}
			value, err := base64.StdEncoding.DecodeString(fields[3])
			if err != nil {
				return
			}
			f.mu.Lock()
			f.auth = string(value)
			f.mu.Unlock()
			fmt.Fprintf(conn, "%s OK authenticated\r\n", tag)
		case "EXAMINE":
			fmt.Fprintf(conn, "* FLAGS (\\Seen)\r\n* 2 EXISTS\r\n* OK [UIDVALIDITY %d] valid\r\n* OK [UIDNEXT %d] next\r\n%s OK [READ-ONLY] examined\r\n", validity, next, tag)
		case "UID":
			if len(fields) < 4 {
				return
			}
			if fields[2] == "SEARCH" {
				bounds := strings.Split(fields[len(fields)-1], ":")
				lo, _ := strconv.ParseUint(bounds[0], 10, 32)
				hi := lo
				if len(bounds) == 2 {
					hi, _ = strconv.ParseUint(bounds[1], 10, 32)
				}
				f.mu.Lock()
				fmt.Fprint(conn, "* SEARCH")
				for uid := uint32(lo); uint64(uid) <= hi; uid++ {
					if _, ok := f.messages[uid]; ok {
						fmt.Fprintf(conn, " %d", uid)
					}
				}
				f.mu.Unlock()
				fmt.Fprintf(conn, "\r\n%s OK search\r\n", tag)
			} else if fields[2] == "FETCH" {
				n, _ := strconv.ParseUint(fields[3], 10, 32)
				uid := uint32(n)
				f.mu.Lock()
				raw, ok := f.messages[uid]
				oversize, drop := f.oversize, f.drop
				f.mu.Unlock()
				if uid == drop {
					return
				}
				if ok {
					size := len(raw)
					if uid == oversize {
						size = mailRawLimit + 1
					}
					fmt.Fprintf(conn, "* %d FETCH (UID %d RFC822.SIZE %d)\r\n", uid, uid, size)
				}
				fmt.Fprintf(conn, "%s OK metadata\r\n", tag)
			} else {
				return
			}
		case "FETCH":
			if !strings.Contains(line, "BODY.PEEK[]") {
				return
			}
			n, _ := strconv.ParseUint(fields[2], 10, 32)
			uid := uint32(n)
			f.mu.Lock()
			raw, ok := f.messages[uid]
			bodyFirst, missing, vanish, wrongUID, largeLiteral := f.bodyFirst, f.missing, f.vanish, f.wrongUID, f.largeLiteral
			if vanish {
				delete(f.messages, uid)
			}
			f.mu.Unlock()
			if wrongUID {
				uid++
			}
			if !missing && !vanish && ok {
				if largeLiteral {
					if bodyFirst {
						fmt.Fprintf(conn, "* %d FETCH (BODY[] {%d}\r\n", n, mailRawLimit+1)
					} else {
						fmt.Fprintf(conn, "* %d FETCH (UID %d BODY[] {%d}\r\n", n, uid, mailRawLimit+1)
					}
					r.ReadByte()
					return
				}
				if bodyFirst {
					fmt.Fprintf(conn, "* %d FETCH (BODY[] {%d}\r\n%s UID %d)\r\n", n, len(raw), raw, uid)
				} else {
					fmt.Fprintf(conn, "* %d FETCH (UID %d BODY[] {%d}\r\n%s)\r\n", n, uid, len(raw), raw)
				}
			}
			fmt.Fprintf(conn, "%s OK fetch\r\n", tag)
		default:
			return
		}
	}
}

func newIMAPFixture(t *testing.T, startTLS bool) (*imapFixture, *mailIMAPConfig) {
	t.Helper()
	certServer := httptest.NewTLSServer(nil)
	cert := certServer.TLS.Certificates[0]
	certServer.Close()
	var listener net.Listener
	var err error
	if startTLS {
		listener, err = net.Listen("tcp", "127.0.0.1:0")
	} else {
		listener, err = tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	}
	if err != nil {
		t.Fatal(err)
	}
	f := &imapFixture{validity: 41, next: 1, messages: map[uint32]string{}}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			wg.Add(1)
			go func() { defer wg.Done(); f.serve(conn, cert, startTLS) }()
		}
	}()
	t.Cleanup(func() { listener.Close(); wg.Wait() })
	config := &mailIMAPConfig{Address: listener.Addr().String(), Username: "support@our.test", Password: "fixture-password", Mailbox: "INBOX", StartTLS: startTLS}
	return f, config
}

func pollFixture(t *testing.T, c *mailChannel, config *mailIMAPConfig) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return c.pollIMAP(ctx, config)
}

func TestIMAPReceiver(t *testing.T) {
	if os.Getenv("NRC_IMAP_FIXTURE_CHILD") != "1" {
		server := httptest.NewTLSServer(nil)
		defer server.Close()
		ca := filepath.Join(t.TempDir(), "ca.pem")
		if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.TLS.Certificates[0].Certificate[0]}), 0600); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(os.Args[0], "-test.run=^TestIMAPReceiver$", "-test.v", "-test.timeout=20s")
		cmd.Env = append(os.Environ(), "NRC_IMAP_FIXTURE_CHILD=1", "SSL_CERT_FILE="+ca)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%v\n%s", err, out)
		}
		t.Log(string(out))
		return
	}
	for _, startTLS := range []bool{false, true} {
		t.Run(fmt.Sprintf("starttls=%v", startTLS), func(t *testing.T) {
			c, s, sent := mailFixture(t)
			f, config := newIMAPFixture(t, startTLS)
			if err := config.validate(); err != nil {
				t.Fatal(err)
			}
			raw := "From: Anna <anna@customer.test>\r\nMessage-ID: <imap-new@customer.test>\r\n\r\nHelp from IMAP"
			f.messages[2] = raw
			f.next = 3
			if err := pollFixture(t, c, config); err != nil {
				t.Fatal(err)
			}
			jobs, _ := c.jobs()
			if len(jobs) != 0 {
				t.Fatal("imported historical mail by default")
			}
			f.mu.Lock()
			f.messages[4] = strings.Replace(raw, "imap-new", "imap-live", 1)
			f.next = 5
			f.mu.Unlock()
			if err := pollFixture(t, c, config); err != nil {
				t.Fatal(err)
			}
			mailTick(t, c)
			mailTick(t, c)
			tickets, _ := s.list(context.Background(), ticketType)
			if len(tickets) != 1 || tickets[0].Payload != "Help from IMAP" || len(*sent) != 1 {
				t.Fatalf("wrong roundtrip tickets=%+v sent=%d", tickets, len(*sent))
			}
			// Replaying after a lost cursor write or a UIDVALIDITY rebuild must not
			// create a second ticket from the same raw message.
			c.saveIMAPCursor(mailIMAPCursor{Validity: 41, Last: 3})
			if err := pollFixture(t, c, config); err != nil {
				t.Fatal(err)
			}
			f.mu.Lock()
			f.validity = 42
			delete(f.messages, 2)
			f.mu.Unlock()
			if err := pollFixture(t, c, config); err == nil {
				t.Fatal("silently rescanned changed UID namespace")
			}
			cursor, _ := c.imapCursor(config)
			if cursor.Validity != 41 || cursor.Last != 4 {
				t.Fatal("changed cursor without approval", cursor)
			}
			config.ImportExisting = true
			if err := pollFixture(t, c, config); err != nil {
				t.Fatal(err)
			}
			mailTick(t, c)
			tickets, _ = s.list(context.Background(), ticketType)
			if len(tickets) != 1 || len(*sent) != 1 {
				t.Fatal("duplicate ticket/mail on replay")
			}
			f.mu.Lock()
			commands := append([]string(nil), f.commands...)
			f.mu.Unlock()
			for _, command := range commands {
				if strings.Contains(command, "STORE") || strings.Contains(command, "EXPUNGE") || strings.HasPrefix(command, "SELECT") {
					t.Fatal("mutated mailbox", command)
				}
			}
			config.Mailbox = "Other"
			if _, err := c.imapCursor(config); err == nil {
				t.Fatal("silently rebound journal")
			}
		})
	}
	t.Run("poison-retry-and-oauth", func(t *testing.T) {
		c, _, _ := mailFixture(t)
		f, config := newIMAPFixture(t, false)
		config.ImportExisting = true
		var tokenCalls atomic.Int32
		tokens := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			r.ParseForm()
			if r.Form.Get("grant_type") != "client_credentials" || r.Form.Get("scope") != "https://outlook.office365.com/.default" || r.Form.Get("client_secret") != "fixture-secret" {
				t.Error("wrong token request")
			}
			tokenCalls.Add(1)
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"access_token":"fixture-token","token_type":"Bearer","expires_in":3600}`)
		}))
		defer tokens.Close()
		config.Password = ""
		config.OAuth2 = &mailOAuthConfig{TokenURL: tokens.URL, ClientID: "fixture-client", ClientSecret: "fixture-secret", Scopes: []string{"https://outlook.office365.com/.default"}}
		f.messages = map[uint32]string{1: "malformed", 2: "oversize", 3: "From: anna@customer.test\r\nTo: support+unknown@our.test\r\nAuthentication-Results: attacker; dmarc=pass\r\n\r\nUnknown reply address"}
		f.oversize = 2
		f.drop = 3
		f.next = 4
		if err := config.validate(); err != nil {
			t.Fatal(err)
		}
		if err := pollFixture(t, c, config); err != nil {
			t.Fatal(err)
		} // Stops cleanly after rejecting oversized literal.
		cursor, _ := c.imapCursor(config)
		if cursor.Last != 2 {
			t.Fatal("wrong oversize checkpoint", cursor)
		}
		if err := pollFixture(t, c, config); err == nil {
			t.Fatal("lost fetch accepted")
		}
		cursor, _ = c.imapCursor(config)
		if cursor.Last != 2 {
			t.Fatal("advanced past failed fetch")
		}
		f.mu.Lock()
		f.drop = 0
		f.mu.Unlock()
		if err := pollFixture(t, c, config); err != nil {
			t.Fatal(err)
		}
		jobs, _ := c.jobs()
		if len(jobs) != 3 {
			t.Fatalf("lost poison records %+v", jobs)
		}
		mailTick(t, c)
		jobs, _ = c.jobs()
		for _, job := range jobs {
			if job.State != "quarantine" {
				t.Fatal("invalid mail accepted")
			}
		}
		f.mu.Lock()
		auth := f.auth
		f.mu.Unlock()
		if auth != "user=support@our.test\x01auth=Bearer fixture-token\x01\x01" || tokenCalls.Load() != 1 {
			t.Fatalf("wrong OAuth/caching calls=%d", tokenCalls.Load())
		}
		// Same OAuth configuration also works for SMTP, tested by the relay suite.
	})
	for _, mode := range []string{"body-first", "missing", "vanished", "wrong-uid", "oversize-body-first", "oversize-uid-first"} {
		t.Run(mode, func(t *testing.T) {
			c, s, _ := mailFixture(t)
			f, config := newIMAPFixture(t, false)
			config.ImportExisting = true
			f.messages[1] = "From: anna@customer.test\r\n\r\nBody before UID"
			f.next = 2
			f.bodyFirst = mode == "body-first" || mode == "oversize-body-first"
			f.missing, f.vanish, f.wrongUID = mode == "missing", mode == "vanished", mode == "wrong-uid"
			f.largeLiteral = strings.HasPrefix(mode, "oversize-")
			err := pollFixture(t, c, config)
			wantFailure := mode == "missing" || mode == "wrong-uid" || mode == "oversize-body-first"
			if (err != nil) != wantFailure {
				t.Fatalf("unexpected result: %v", err)
			}
			cursor, _ := c.imapCursor(config)
			if wantFailure && cursor.Last != 0 || !wantFailure && cursor.Last != 1 {
				t.Fatal("unsafe checkpoint", cursor)
			}
			mailTick(t, c)
			tickets, _ := s.list(context.Background(), ticketType)
			if mode == "body-first" {
				if len(tickets) != 1 || tickets[0].Payload != "Body before UID" {
					t.Fatalf("lost body-first message: %+v", tickets)
				}
			} else if len(tickets) != 0 {
				t.Fatal("accepted incorrect/absent message")
			}
		})
	}
}
