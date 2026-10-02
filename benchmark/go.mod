module github.com/nrc/benchmark

go 1.26

require (
	github.com/HdrHistogram/hdrhistogram-go v1.1.2
	github.com/gorilla/websocket v1.5.3
	github.com/heavyhorst/nrc/protocol-go v0.0.0
	hegel.dev/go/hegel v0.6.30
)

require (
	github.com/ebitengine/purego v0.11.0-alpha.6.0.20260707033313-5f49e7c49322 // indirect
	golang.org/x/sys v0.44.0 // indirect
)

require (
	github.com/cespare/xxhash/v2 v2.3.0
	github.com/klauspost/compress v1.18.4 // indirect
)

replace github.com/heavyhorst/nrc/protocol-go => ../protocol-go
