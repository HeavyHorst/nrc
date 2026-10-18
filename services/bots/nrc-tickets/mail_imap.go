package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sort"
	"strings"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	bolt "go.etcd.io/bbolt"
)

type mailIMAPConfig struct {
	Address        string           `json:"address"`
	Username       string           `json:"username"`
	Password       string           `json:"password"`
	OAuth2         *mailOAuthConfig `json:"oauth2"`
	StartTLS       bool             `json:"start_tls"` // Otherwise implicit TLS, normally port 993.
	Mailbox        string           `json:"mailbox"`
	ImportExisting bool             `json:"import_existing"`
}

func (c *mailIMAPConfig) validate() error {
	if c == nil {
		return nil
	}
	host, _, err := net.SplitHostPort(c.Address)
	if err != nil || host == "" || c.Username == "" || !safeMailHeader(c.Username) || !safeMailHeader(c.Password) || strings.ContainsAny(host, "\r\n") || len(c.Mailbox) > 1024 || !safeMailHeader(c.Mailbox) || c.OAuth2 == nil && c.Password == "" || c.OAuth2 != nil && c.Password != "" {
		return errors.New("IMAP requires host:port, username, one authentication method and valid mailbox")
	}
	if c.Mailbox == "" {
		c.Mailbox = "INBOX"
	}
	return c.OAuth2.validate()
}

type mailIMAPCursor struct {
	Validity uint32
	Last     uint32
}

func (c *mailChannel) imapCursor(config *mailIMAPConfig) (mailIMAPCursor, error) {
	var cursor mailIMAPCursor
	err := c.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("mail-v1"))
		binding := config.Address + "\n" + config.Username + "\n" + config.Mailbox
		if old := b.Get([]byte("imap-binding")); old != nil && string(old) != binding {
			return errors.New("journal IMAP mailbox binding changed; use a separate journal")
		}
		if err := b.Put([]byte("imap-binding"), []byte(binding)); err != nil {
			return err
		}
		if raw := b.Get([]byte("imap-cursor")); raw != nil {
			return json.Unmarshal(raw, &cursor)
		}
		return nil
	})
	return cursor, err
}
func (c *mailChannel) saveIMAPCursor(cursor mailIMAPCursor) error {
	return c.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte("mail-v1")).Put([]byte("imap-cursor"), []byte(mailJSON(cursor)))
	})
}

var errIMAPOversize = errors.New("IMAP message exceeds 32 MiB; original retained in mailbox")

// Unlike Collect, Next exposes the literal before buffering it. A size-policy
// rejection closes the connection rather than draining an unbounded literal.
func fetchIMAP(c *imapclient.Client, uid imap.UID, abort func()) (raw []byte, found bool, err error) {
	// The pinned client routes UID FETCH literals only when UID precedes BODY.
	// Resolve metadata first, then stream by sequence number and verify the UID
	// afterward: an intervening EXPUNGE must fail, never accept another message.
	rows, err := c.Fetch(imap.UIDSetNum(uid), &imap.FetchOptions{UID: true, RFC822Size: true}).Collect()
	if err != nil || len(rows) == 0 {
		return nil, false, err
	}
	if len(rows) != 1 || rows[0].UID != uid || rows[0].SeqNum == 0 {
		return nil, false, errors.New("unexpected IMAP metadata identity")
	}
	if rows[0].RFC822Size > mailRawLimit {
		return nil, false, errIMAPOversize
	}
	section := &imap.FetchItemBodySection{Peek: true}
	cmd := c.Fetch(imap.SeqSetNum(rows[0].SeqNum), &imap.FetchOptions{UID: true, BodySection: []*imap.FetchItemBodySection{section}})
	defer func() {
		// Client.Close waits for the decoder, which itself waits for literal
		// consumption. Close the socket first, then drain the failed command.
		if err != nil {
			abort()
		}
		if closeErr := cmd.Close(); err == nil {
			err = closeErr
		}
		if err == nil && !found {
			// An absent body is not proof of expunge. Only skip a UID that a
			// successful second lookup confirms is no longer in this mailbox.
			remaining, lookupErr := c.Fetch(imap.UIDSetNum(uid), &imap.FetchOptions{UID: true}).Collect()
			if lookupErr != nil {
				err = lookupErr
			} else if len(remaining) != 0 {
				err = errors.New("IMAP message still exists but body was not returned")
			}
		}
	}()
	for msg := cmd.Next(); msg != nil; msg = cmd.Next() {
		var actual imap.UID
		var body []byte
		bodyFound := false
		for item := msg.Next(); item != nil; item = msg.Next() {
			switch item := item.(type) {
			case imapclient.FetchItemDataUID:
				actual = item.UID
			case imapclient.FetchItemDataBodySection:
				if !item.MatchCommand(section) || item.Literal == nil {
					continue
				}
				if item.Literal.Size() > mailRawLimit {
					if actual != uid {
						return nil, false, errors.New("unexpected oversized IMAP body identity")
					}
					return nil, false, errIMAPOversize
				}
				if bodyFound {
					return nil, false, errors.New("duplicate IMAP body")
				}
				var err error
				body, err = io.ReadAll(io.LimitReader(item.Literal, mailRawLimit+1))
				if err != nil {
					return nil, false, err
				}
				if len(body) > mailRawLimit {
					return nil, false, errIMAPOversize
				}
				bodyFound = true
			}
		}
		if bodyFound {
			if actual != uid || found {
				return nil, false, errors.New("unexpected IMAP body identity")
			}
			raw, found = body, true
		}
	}
	return raw, found, nil
}

func (c *mailChannel) pollIMAP(ctx context.Context, config *mailIMAPConfig) error {
	cursor, err := c.imapCursor(config)
	if err != nil {
		return err
	}
	host, _, _ := net.SplitHostPort(config.Address)
	conn, err := (&net.Dialer{Timeout: 15 * time.Second}).DialContext(ctx, "tcp", config.Address)
	if err != nil {
		return errors.New("IMAP connection failed")
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(2 * time.Minute)
	}
	conn.SetDeadline(deadline)
	tlsConfig := &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}
	var client *imapclient.Client
	if config.StartTLS {
		client, err = imapclient.NewStartTLS(conn, &imapclient.Options{TLSConfig: tlsConfig})
	} else {
		secure := tls.Client(conn, tlsConfig)
		if err = secure.HandshakeContext(ctx); err == nil {
			client = imapclient.New(secure, nil)
		}
	}
	if err != nil {
		return errors.New("IMAP verified TLS failed")
	}
	defer client.Close()
	if err := client.WaitGreeting(); err != nil {
		return errors.New("IMAP greeting failed")
	}
	if config.OAuth2 != nil {
		token, err := config.OAuth2.token(ctx)
		if err != nil {
			return err
		}
		err = client.Authenticate(mailXOAUTH2{config.Username, token})
		if err != nil {
			return errors.New("IMAP OAuth authentication failed")
		}
	} else if err := client.Login(config.Username, config.Password).Wait(); err != nil {
		return errors.New("IMAP password authentication failed")
	}
	selected, err := client.Select(config.Mailbox, &imap.SelectOptions{ReadOnly: true}).Wait()
	if err != nil || selected.UIDValidity == 0 || selected.UIDNext == 0 {
		return errors.New("IMAP selection lacks valid UID namespace")
	}
	upper := uint32(selected.UIDNext) - 1
	if cursor.Validity == 0 {
		cursor.Validity = selected.UIDValidity
		if !config.ImportExisting {
			cursor.Last = upper
		}
		if err := c.saveIMAPCursor(cursor); err != nil {
			return err
		}
	} else if cursor.Validity != selected.UIDValidity {
		if !config.ImportExisting {
			return errors.New("IMAP UIDVALIDITY changed; explicit import_existing approval required to rescan mailbox")
		}
		// Re-scan the new namespace; shared Message-ID/raw deduplication prevents
		// ordinary mailbox rebuilds from creating the same ticket twice.
		cursor = mailIMAPCursor{Validity: selected.UIDValidity}
		if err := c.saveIMAPCursor(cursor); err != nil {
			return err
		}
	}
	processed := 0
	for cursor.Last < upper && processed < 200 {
		if err := ctx.Err(); err != nil {
			return err
		}
		lo := cursor.Last + 1
		hi := uint32(min(uint64(lo)+999, uint64(upper)))
		var set imap.UIDSet
		set.AddRange(imap.UID(lo), imap.UID(hi))
		result, err := client.UIDSearch(&imap.SearchCriteria{UID: []imap.UIDSet{set}}, nil).Wait()
		if err != nil {
			return errors.New("IMAP UID search failed")
		}
		uids := result.AllUIDs()
		sort.Slice(uids, func(i, j int) bool { return uids[i] < uids[j] })
		for _, uid := range uids {
			if uint32(uid) < lo || uint32(uid) > hi {
				return errors.New("IMAP returned UID outside requested window")
			}
			if uint32(uid) <= cursor.Last {
				continue
			}
			raw, found, fetchErr := fetchIMAP(client, uid, func() { conn.Close() })
			if fetchErr != nil && !errors.Is(fetchErr, errIMAPOversize) {
				return errors.New("IMAP message fetch failed")
			}
			c.mu.Lock()
			var receiveErr error
			status := 0
			if found {
				_, status, receiveErr = c.receive(raw)
			}
			if errors.Is(fetchErr, errIMAPOversize) || receiveErr != nil && status < 500 {
				// A durable rejection keeps a poison message from blocking the
				// mailbox. Oversized originals remain on IMAP; never deleted.
				reason := "invalid MIME or Message-ID collision; inspect original"
				if fetchErr != nil {
					reason = errIMAPOversize.Error()
				}
				receiveErr = c.put(mailJob{ID: fmt.Sprintf("imap-%d-%d", cursor.Validity, uid), Direction: "in", State: "quarantine", Reason: reason, Raw: raw})
			}
			if receiveErr == nil {
				cursor.Last = uint32(uid)
				receiveErr = c.saveIMAPCursor(cursor)
			}
			c.mu.Unlock()
			if receiveErr != nil {
				return receiveErr
			}
			processed++
			if fetchErr != nil || processed >= 200 {
				return nil
			}
		}
		cursor.Last = hi
		if err := c.saveIMAPCursor(cursor); err != nil {
			return err
		}
	}
	return nil
}
