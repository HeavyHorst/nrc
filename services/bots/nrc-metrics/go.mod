module nrc-metrics

go 1.26

require (
	github.com/VictoriaMetrics/metrics v1.42.0
	github.com/cespare/xxhash/v2 v2.3.0
	github.com/gorilla/websocket v1.5.3
	github.com/heavyhorst/nrc/protocol-go v0.0.0
)

require (
	github.com/klauspost/compress v1.18.4 // indirect
	github.com/valyala/fastrand v1.1.0 // indirect
	github.com/valyala/histogram v1.2.0 // indirect
	golang.org/x/sys v0.38.0 // indirect
)

replace github.com/heavyhorst/nrc/protocol-go => ../../../protocol-go
