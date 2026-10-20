module github.com/heavyhorst/nrc/services/calls

go 1.26

require (
	github.com/coder/websocket v1.8.14
	github.com/heavyhorst/nrc/protocol-go v0.0.0
)

require github.com/klauspost/compress v1.18.4 // indirect

replace github.com/heavyhorst/nrc/protocol-go => ../../protocol-go
