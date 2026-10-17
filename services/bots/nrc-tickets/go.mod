module nrc-tickets

go 1.26

require (
	github.com/gorilla/websocket v1.5.3
	github.com/heavyhorst/nrc/protocol-go v0.0.0
	golang.org/x/crypto v0.53.0
)

require github.com/klauspost/compress v1.18.4 // indirect

replace github.com/heavyhorst/nrc/protocol-go => ../../../protocol-go
