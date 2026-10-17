module nrc-newsletter

go 1.26

require (
	github.com/gorilla/websocket v1.5.3
	github.com/heavyhorst/nrc/protocol-go v0.0.0
	go.etcd.io/bbolt v1.4.0
)

require (
	github.com/klauspost/compress v1.18.4 // indirect
	golang.org/x/sys v0.29.0 // indirect
)

replace github.com/heavyhorst/nrc/protocol-go => ../../../protocol-go
