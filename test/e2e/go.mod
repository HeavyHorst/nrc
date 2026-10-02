module nrc-e2e

go 1.26

require (
	github.com/cespare/xxhash/v2 v2.3.0
	github.com/gorilla/websocket v1.5.1
	github.com/heavyhorst/nrc/protocol-go v0.0.0
)

replace github.com/heavyhorst/nrc/protocol-go => ../../protocol-go

require (
	github.com/klauspost/compress v1.18.4 // indirect
	golang.org/x/net v0.17.0 // indirect
)
