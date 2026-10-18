module nrc-tickets

go 1.26

require (
	github.com/emersion/go-imap/v2 v2.0.0-beta.8
	github.com/gorilla/websocket v1.5.3
	github.com/heavyhorst/nrc/protocol-go v0.0.0
	go.etcd.io/bbolt v1.4.0
	golang.org/x/crypto v0.53.0
	golang.org/x/net v0.55.0
	golang.org/x/oauth2 v0.36.0
)

require (
	github.com/emersion/go-message v0.18.2 // indirect
	github.com/emersion/go-sasl v0.0.0-20241020182733-b788ff22d5a6 // indirect
	github.com/klauspost/compress v1.18.4 // indirect
	golang.org/x/sys v0.46.0 // indirect
	golang.org/x/text v0.38.0 // indirect
)

replace github.com/heavyhorst/nrc/protocol-go => ../../../protocol-go
