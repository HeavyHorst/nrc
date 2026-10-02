module github.com/heavyhorst/nrc/cli

go 1.26

require (
	github.com/cespare/xxhash/v2 v2.3.0
	github.com/gorilla/websocket v1.5.1
	github.com/heavyhorst/nrc/protocol-go v0.0.0
	github.com/olekukonko/tablewriter v1.1.2
	github.com/spf13/cobra v1.10.2
	golang.org/x/net v0.17.0
	gopkg.in/yaml.v3 v3.0.1
)

replace github.com/heavyhorst/nrc/protocol-go => ../protocol-go

require (
	github.com/clipperhouse/displaywidth v0.6.0 // indirect
	github.com/clipperhouse/stringish v0.1.1 // indirect
	github.com/clipperhouse/uax29/v2 v2.3.0 // indirect
	github.com/fatih/color v1.15.0 // indirect
	github.com/inconshreveable/mousetrap v1.1.0 // indirect
	github.com/klauspost/compress v1.18.4 // indirect
	github.com/mattn/go-colorable v0.1.13 // indirect
	github.com/mattn/go-isatty v0.0.19 // indirect
	github.com/mattn/go-runewidth v0.0.19 // indirect
	github.com/olekukonko/cat v0.0.0-20250911104152-50322a0618f6 // indirect
	github.com/olekukonko/errors v1.1.0 // indirect
	github.com/olekukonko/ll v0.1.3 // indirect
	github.com/spf13/pflag v1.0.9 // indirect
	golang.org/x/sys v0.13.0 // indirect
)
