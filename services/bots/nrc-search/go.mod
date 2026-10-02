module nrc-search

go 1.26

require (
	github.com/daulet/tokenizers v1.25.0
	github.com/gorilla/websocket v1.5.3
	github.com/heavyhorst/nrc/protocol-go v0.0.0
	github.com/viterin/vek v0.4.2
	github.com/yalue/onnxruntime_go v1.25.0
	go.etcd.io/bbolt v1.4.0
	golang.org/x/net v0.58.0
)

require (
	github.com/chewxy/math32 v1.10.1 // indirect
	github.com/klauspost/compress v1.18.4 // indirect
	github.com/viterin/partial v1.1.0 // indirect
	golang.org/x/exp v0.0.0-20230817173708-d852ddb80c63 // indirect
	golang.org/x/sys v0.47.0 // indirect
)

replace github.com/heavyhorst/nrc/protocol-go => ../../../protocol-go
