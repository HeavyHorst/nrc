package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
)

type monitorHTTPCondition struct {
	Field string `json:"field"`
	Path  string `json:"path,omitempty"`
	Op    string `json:"op"`
	Value any    `json:"value"`
	Unit  string `json:"unit,omitempty"`
}

func buildNetworkMonitor(cmd *cobra.Command, d map[string]json.RawMessage, kind string, update bool) error {
	f := cmd.Flags()
	for _, name := range []string{"source", "refresh-source", "query", "query-file", "identity", "trigger", "recovery"} {
		if f.Changed(name) {
			return fmt.Errorf("--%s is for Victoria checks", name)
		}
	}
	set := func(key string, v any) { d[key], _ = json.Marshal(v) }
	for _, name := range []string{"url", "address"} {
		if f.Changed(name) {
			v, _ := f.GetString(name)
			set(name, v)
		}
	}
	for flag, key := range map[string]string{"insecure-tls": "insecure_tls", "follow-redirects": "follow_redirects"} {
		if f.Changed(flag) {
			v, _ := f.GetBool(flag)
			set(key, v)
		}
	}
	var target string
	if kind == "tcp" {
		for _, name := range []string{"url", "status", "max-latency", "certificate-valid-for", "conditions-file", "insecure-tls", "follow-redirects"} {
			if f.Changed(name) {
				return fmt.Errorf("--%s is for HTTP checks", name)
			}
		}
		_ = json.Unmarshal(d["address"], &target)
		host, port, err := net.SplitHostPort(target)
		n, e := strconv.Atoi(port)
		if err != nil || e != nil || host == "" || n < 1 || n > 65535 {
			return fmt.Errorf("--address must be host:port with port 1–65535")
		}
		return nil
	}
	if f.Changed("address") {
		return fmt.Errorf("--address is for TCP checks")
	}
	_ = json.Unmarshal(d["url"], &target)
	u, err := url.Parse(target)
	if err != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.Fragment != "" {
		return fmt.Errorf("--url must be an HTTP(S) URL without credentials or fragment")
	}
	var conditions []monitorHTTPCondition
	data := d["conditions"]
	if f.Changed("conditions-file") {
		path, _ := f.GetString("conditions-file")
		var reader io.Reader = cmd.InOrStdin()
		if path != "-" {
			file, e := os.Open(path)
			if e != nil {
				return e
			}
			defer file.Close()
			reader = file
		}
		data, err = io.ReadAll(io.LimitReader(reader, 32769))
		if err != nil {
			return err
		}
		if len(data) > 32768 {
			return fmt.Errorf("conditions file exceeds 32 KiB")
		}
	}
	if len(data) > 0 {
		decoder := json.NewDecoder(strings.NewReader(string(data)))
		decoder.UseNumber()
		decoder.DisallowUnknownFields()
		if decoder.Decode(&conditions) != nil || decoder.Decode(new(any)) != io.EOF {
			return fmt.Errorf("conditions must be a JSON array of field/path/op/value objects")
		}
	}
	replace := func(field, op string, value any) {
		kept := conditions[:0]
		for _, c := range conditions {
			if c.Field != field {
				kept = append(kept, c)
			}
		}
		conditions = kept
		if value != nil {
			conditions = append(conditions, monitorHTTPCondition{Field: field, Op: op, Value: value})
		}
	}
	if f.Changed("status") || !update && !f.Changed("conditions-file") {
		status, _ := f.GetInt("status")
		if status < 100 || status > 599 {
			return fmt.Errorf("--status must be 100–599")
		}
		replace("status", "==", json.Number(strconv.Itoa(status)))
	}
	for flag, field := range map[string]string{"max-latency": "latency_ns", "certificate-valid-for": "certificate_remaining_ns"} {
		if f.Changed(flag) {
			v, _ := f.GetDuration(flag)
			if v < 0 {
				return fmt.Errorf("--%s must not be negative", flag)
			}
			op := "<="
			if flag == "certificate-valid-for" {
				op = ">="
			}
			var value any
			if v != 0 {
				value = json.Number(strconv.FormatInt(int64(v), 10))
			}
			replace(field, op, value)
		}
	}
	if len(conditions) == 0 || len(conditions) > 32 {
		return fmt.Errorf("HTTP checks require 1–32 conditions")
	}
	for _, c := range conditions {
		if c.Unit != "" {
			if _, ok := c.Value.(json.Number); !ok {
				return fmt.Errorf("condition unit requires a numeric value")
			}
			switch c.Unit {
			case "number", "bytes", "bits", "nanoseconds", "microseconds", "milliseconds", "seconds", "percent", "percent_ratio":
			default:
				return fmt.Errorf("unsupported condition display unit %q", c.Unit)
			}
		}
		if c.Op != "==" && c.Op != "!=" && c.Op != "<" && c.Op != ">" && c.Op != "<=" && c.Op != ">=" {
			return fmt.Errorf("invalid condition operator")
		}
		switch c.Field {
		case "status", "latency_ns", "certificate_remaining_ns":
			if _, ok := c.Value.(json.Number); !ok || c.Path != "" {
				return fmt.Errorf("%s requires a number and no path", c.Field)
			}
		case "json":
			if c.Path != "" && !strings.HasPrefix(c.Path, "/") {
				return fmt.Errorf("JSON condition path must be a JSON Pointer")
			}
		default:
			return fmt.Errorf("unknown condition field %q", c.Field)
		}
		switch v := c.Value.(type) {
		case json.Number:
			if _, _, _, err := monitorComparison("<" + string(v)); err != nil {
				return err
			}
		case string, bool:
			if c.Op != "==" && c.Op != "!=" {
				return fmt.Errorf("strings and booleans require == or !=")
			}
		default:
			return fmt.Errorf("condition value must be a number, string or boolean")
		}
	}
	set("conditions", conditions)
	return nil
}
