module nrc-publish

go 1.26

require (
	github.com/gorilla/websocket v1.5.3
	github.com/heavyhorst/nrc/protocol-go v0.0.0
	github.com/yuin/goldmark v1.7.16
	go.etcd.io/bbolt v1.4.0
	golang.org/x/net v0.58.0
)

require (
	github.com/klauspost/compress v1.18.4 // indirect
	golang.org/x/sys v0.47.0 // indirect
)

replace github.com/heavyhorst/nrc/protocol-go => ../../../protocol-go
