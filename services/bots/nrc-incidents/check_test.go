package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMonitorDisplayUnit(t *testing.T) {
	for _, tc := range []struct {
		field string
		unit  string
		valid bool
	}{
		{"", "", true},
		{`,"unit":""`, "", true},
		{`,"unit":"number"`, "number", true},
		{`,"unit":"percent"`, "percent", true},
		{`,"unit":"bytes"`, "bytes", true},
		{`,"unit":"Bytes"`, "", false},
		{`,"unit":"kilobytes"`, "", false},
		{`,"unit":100`, "", false},
		{`,"unit":null`, "", false},
		{`,"unit":true`, "", false},
	} {
		t.Run(tc.field, func(t *testing.T) {
			a := monitorAsset("https://example.com")
			a.Preview = strings.TrimSuffix(a.Preview, "}") + tc.field + "}"
			a.Payload = `{"kind":"victoriametrics","source_id":"1","source_revision":"2","query":"disk_free_bytes","identity_labels":["instance"],"trigger":{"op":"<","value":1073741824},"recovery":{"op":">","value":2147483648}}`
			c, d, err := parseMonitor(a)
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v, error=%v", tc.valid, err)
			}
			if tc.valid && (c.Unit != tc.unit || d.Trigger.Value != "1073741824" || d.Recovery.Value != "2147483648" || d.Query != "disk_free_bytes") {
				t.Fatalf("unit or raw check values changed: %+v %+v", c, d)
			}
		})
	}
}

func TestConditionDisplayUnits(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"n":1536}`)
	}))
	defer s.Close()
	for _, unit := range []string{"", "number", "bytes", "bits", "nanoseconds", "microseconds", "milliseconds", "seconds", "percent", "percent_ratio", "kilobytes"} {
		a := monitorAsset(s.URL)
		a.Payload = fmt.Sprintf(`{"kind":"http","url":%q,"conditions":[{"field":"json","path":"/n","op":">","value":1024,"unit":%q}]}`, s.URL, unit)
		_, d, err := parseMonitor(a)
		if unit == "kilobytes" {
			if err == nil {
				t.Fatal("unsupported display unit accepted")
			}
			continue
		}
		if err != nil {
			t.Fatal(unit, err)
		}
		r := runCheck(context.Background(), d)
		row := r.Diagnostics.Conditions[0]
		if r.Observation.Condition != 0 || row.State != "pass" || row.Actual != "1536" || row.ExpectedNumber != "1024" {
			t.Fatalf("%s changed raw evaluation: %+v %+v", unit, r, row)
		}
	}
	a := monitorAsset(s.URL)
	a.Payload = fmt.Sprintf(`{"kind":"http","url":%q,"conditions":[{"field":"json","path":"/n","op":"==","value":true,"unit":"bytes"}]}`, s.URL)
	if _, _, err := parseMonitor(a); err == nil {
		t.Fatal("display unit on boolean accepted")
	}
}

func TestConditionDiagnostics(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
		fmt.Fprint(w, `{"status":"OK","n":9007199254740993,"secret":"unselected-secret","object":{"secret":"nested-secret"},"long":"`+strings.Repeat("ü", 300)+`"}`)
	}))
	defer s.Close()
	d := checkDefinition{Kind: "http", URL: s.URL, Conditions: []condition{
		{Field: "status", Op: "==", Value: json.Number("200")},
		{Field: "json", Path: "/status", Op: "==", Value: "OK"},
		{Field: "json", Path: "/n", Op: ">", Value: json.Number("9007199254740992")},
		{Field: "json", Path: "/missing", Op: "!=", Value: true},
		{Field: "certificate_remaining_ns", Op: ">", Value: json.Number("0")},
		{Field: "json", Path: "/object", Op: "!=", Value: "x"},
		{Field: "json", Path: "/long", Op: "==", Value: strings.Repeat("ü", 300)},
	}}
	r := runCheck(context.Background(), d)
	rows := r.Diagnostics.Conditions
	if r.Observation.Condition != 1 || len(rows) != 7 {
		t.Fatal(r)
	}
	for i, state := range []string{"fail", "pass", "pass", "unavailable", "unavailable", "fail", "pass"} {
		if rows[i].Index != i || rows[i].State != state {
			t.Fatalf("row %d: %+v", i, rows[i])
		}
	}
	if rows[0].Actual != "503" || rows[2].Actual != "9007199254740993" || rows[2].ActualType != "number" || rows[3].Reason != "missing_field" || rows[4].Reason != "certificate_unavailable" || rows[5].ActualType != "non_scalar" || !rows[6].Truncated || len([]rune(rows[6].Actual)) != 256 {
		t.Fatal(rows)
	}
	if rows[2].ExpectedNumber != "9007199254740992" {
		t.Fatal("numeric threshold lost its decimal representation", rows[2])
	}
	body, _ := json.Marshal(r.Diagnostics)
	if strings.Contains(string(body), "secret") {
		t.Fatal("unselected or nested data retained", string(body))
	}
	s.Close()
	r = runCheck(context.Background(), d)
	if r.Diagnostics.Error != "request_failed" {
		t.Fatal(r)
	}
	for _, row := range r.Diagnostics.Conditions {
		if row.State != "unavailable" || row.ActualType != "" {
			t.Fatal(row)
		}
	}
}

func TestHTTPConditions(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "/", 302)
			return
		}
		if r.URL.Path == "/large" {
			fmt.Fprint(w, strings.Repeat("x", (1<<20)+1))
			return
		}
		w.WriteHeader(400)
		fmt.Fprint(w, `{"a/b":[{"ok":true,"n":7}]}`)
	}))
	defer server.Close()
	for _, tc := range []struct {
		name, path   string
		conditions   []condition
		follow, pass bool
	}{
		{"no implicit 2xx", "/", []condition{{Field: "json", Path: "/a~1b/0/ok", Op: "==", Value: true}}, false, true},
		{"all conditions", "/", []condition{{Field: "status", Op: "==", Value: json.Number("400")}, {Field: "json", Path: "/a~1b/0/n", Op: ">", Value: json.Number("7")}}, false, false},
		{"inclusive boundary", "/", []condition{{Field: "json", Path: "/a~1b/0/n", Op: ">=", Value: json.Number("7")}}, false, true},
		{"missing is not unequal", "/", []condition{{Field: "json", Path: "/missing", Op: "!=", Value: true}}, false, false},
		{"type mismatch", "/", []condition{{Field: "json", Path: "/a~1b/0/n", Op: "!=", Value: "7"}}, false, false},
		{"redirect refused", "/redirect", []condition{{Field: "status", Op: "==", Value: json.Number("400")}}, false, false},
		{"redirect followed", "/redirect", []condition{{Field: "status", Op: "==", Value: json.Number("400")}}, true, true},
		{"bounded body", "/large", []condition{{Field: "status", Op: "==", Value: json.Number("200")}}, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			result := runCheck(ctx, checkDefinition{Kind: "http", URL: server.URL + tc.path, Conditions: tc.conditions, FollowRedirects: tc.follow})
			if (result.Observation.Condition == 0) != tc.pass {
				t.Fatalf("unexpected result: %+v", result)
			}
		})
	}
}

func TestTLSAndTCPFailures(t *testing.T) {
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "ok") }))
	defer s.Close()
	d := checkDefinition{Kind: "http", URL: s.URL, Conditions: []condition{{Field: "certificate_remaining_ns", Op: ">", Value: json.Number("3600000000000")}}}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if runCheck(ctx, d).Observation.Condition != 1 {
		t.Fatal("untrusted certificate accepted")
	}
	d.InsecureTLS = true
	if runCheck(ctx, d).Observation.Condition != 0 {
		t.Fatal("explicit TLS opt-out failed")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	d = checkDefinition{Kind: "tcp", Address: listener.Addr().String()}
	if runCheck(ctx, d).Observation.Condition != 0 {
		t.Fatal("open TCP failed")
	}
	listener.Close()
	if runCheck(ctx, d).Observation.Condition != 1 {
		t.Fatal("closed TCP passed")
	}
}

func TestHTTPExactJSONNumbers(t *testing.T) {
	for _, tc := range []struct {
		actual, op, expected string
		pass, invalidRule    bool
	}{
		{"9007199254740993", ">", "9007199254740992", true, false},
		{"9007199254740993", "==", "9007199254740992", false, false},
		{"-9007199254740993", "<", "-9007199254740992", true, false},
		{"90071992547409930e-1", "==", "9007199254740993", true, false},
		{"0.10000000000000001", ">", "0.1", true, false},
		{"18446744073709551615", "==", "18446744073709551615", true, false},
		{"1", "==", "1e309", false, true},
		{"1e-1000000000", "!=", "0", false, false},
		{strings.Repeat("9", 129), "!=", "0", false, false},
	} {
		t.Run(tc.actual+tc.op+tc.expected, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprintf(w, `{"counter":%s}`, tc.actual) }))
			defer s.Close()
			a := monitorAsset(s.URL)
			a.Payload = fmt.Sprintf(`{"kind":"http","url":%q,"conditions":[{"field":"json","path":"/counter","op":%q,"value":%s}]}`, s.URL, tc.op, tc.expected)
			_, d, err := parseMonitor(a)
			if tc.invalidRule {
				if err == nil {
					t.Fatal("unbounded numeric rule accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if r := runCheck(ctx, d); (r.Observation.Condition == 0) != tc.pass {
				t.Fatalf("unexpected result: %+v", r)
			}
		})
	}
}
