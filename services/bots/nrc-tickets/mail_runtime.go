package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

// Deployment-owned configuration; never customer-controlled or served by the
// portal. The SMTP password and gateway token are read only from this file.
type mailConfig struct {
	Journal       string          `json:"journal"`
	Address       string          `json:"address"`
	GatewaySecret string          `json:"gateway_secret"`
	IMAP          *mailIMAPConfig `json:"imap"`
	SMTP          struct {
		Address     string           `json:"address"`
		Username    string           `json:"username"`
		Password    string           `json:"password"`
		From        string           `json:"from"`
		ImplicitTLS bool             `json:"implicit_tls"`
		OAuth2      *mailOAuthConfig `json:"oauth2"`
	} `json:"smtp"`
}

func startMail(path, workspace string, portal *portal) error {
	if path == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return errors.New("mail configuration unavailable")
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 {
		return errors.New("mail configuration must be a private regular file")
	}
	var config mailConfig
	decoder := json.NewDecoder(io.LimitReader(f, 65536))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&config) != nil || decoder.Decode(new(any)) != io.EOF {
		return errors.New("invalid mail configuration")
	}
	host, _, err := net.SplitHostPort(config.SMTP.Address)
	if err != nil || host == "" || config.SMTP.From == "" || mailAddress(config.SMTP.From) != config.SMTP.From || strings.ContainsAny(host, "\r\n") {
		return errors.New("invalid SMTP mailbox or address")
	}
	if err := config.IMAP.validate(); err != nil {
		return err
	}
	if err := config.SMTP.OAuth2.validate(); err != nil {
		return err
	}
	if config.SMTP.OAuth2 != nil && (config.SMTP.Username == "" || config.SMTP.Password != "") {
		return errors.New("SMTP OAuth requires username and no password")
	}
	if config.Address == "" {
		config.Address = "127.0.0.1:8097"
	}
	c, err := openMailChannel(config.Journal, workspace, config.GatewaySecret, portal, smtpMailConfig{Address: config.SMTP.Address, Host: host, Username: config.SMTP.Username, Password: config.SMTP.Password, From: config.SMTP.From, ImplicitTLS: config.SMTP.ImplicitTLS, OAuth2: config.SMTP.OAuth2})
	if err != nil {
		return err
	}
	if config.IMAP != nil {
		if _, err := c.imapCursor(config.IMAP); err != nil {
			c.db.Close()
			return err
		}
	}
	// Establish the cutoff before accepting new mail. Never blast historical
	// public replies when enabling this optional module for the first time.
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if err = c.scan(ctx); err != nil {
		c.db.Close()
		return errors.New("cannot establish mail activation cutoff; NRC must be reachable")
	}
	listener, err := net.Listen("tcp", config.Address)
	if err != nil {
		c.db.Close()
		return err
	}
	server := &http.Server{Handler: c, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: time.Minute, WriteTimeout: 2 * time.Minute, MaxHeaderBytes: 16384}
	go func() {
		if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
			log.Fatal("private ticket mail listener stopped")
		}
	}()
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			err := c.tick(ctx)
			cancel()
			if err != nil {
				log.Print("ticket mail processing paused for this pass; inspect NRC and private journal")
			}
		}
	}()
	if config.IMAP != nil {
		go func() {
			for {
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
				err := c.pollIMAP(ctx, config.IMAP)
				cancel()
				if err != nil {
					log.Printf("ticket IMAP pass failed: %v; mailbox unchanged; retrying in 30 seconds", err)
				}
				time.Sleep(30 * time.Second)
			}
		}()
	}
	return nil
}
