package main

import (
	"github.com/heavyhorst/nrc/cli/pkg/output"
	"os"
	"strconv"
	"strings"
)

func earlyOutputMode(args []string) (human, pretty bool) {
	jsonMode := false
	for _, arg := range args {
		if arg == "--" {
			break
		}
		for _, flag := range []struct {
			name   string
			target *bool
		}{{"human", &human}, {"json", &jsonMode}, {"pretty", &pretty}} {
			prefix := "--" + flag.name
			if arg == prefix {
				*flag.target = true
			} else if strings.HasPrefix(arg, prefix+"=") {
				if value, err := strconv.ParseBool(strings.TrimPrefix(arg, prefix+"=")); err == nil {
					*flag.target = value
				}
			}
		}
	}
	return human && !jsonMode, pretty
}

func main() {
	human, pretty := earlyOutputMode(os.Args[1:])
	_ = output.Configure(human, pretty, "")
	if err := rootCmd.Execute(); err != nil {
		output.Error("invalid_argument", err.Error(), false)
	}
}
