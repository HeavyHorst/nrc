package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

func diskDefinition() checkDefinition {
	return checkDefinition{Kind: "victoriametrics", SourceID: "9", SourceRevision: "10", Query: "disk_free_percent", IdentityLabels: []string{"instance", "mountpoint"}, Trigger: &threshold{"<", json.Number("10")}, Recovery: &threshold{">", json.Number("15")}}
}

func TestVictoriaVectors(t *testing.T) {
	good := `{"status":"success","data":{"resultType":"vector","result":[{"metric":{"mountpoint":"/data","instance":"b","job":"ignored"},"value":[$TIME,"3"]},{"metric":{"instance":"a","mountpoint":"/"},"value":[$TIME,"20"]},{"metric":{"instance":"b","mountpoint":"/"},"value":[$TIME,"10"]}]}}`
	for _, kind := range []string{"victoriametrics", "victorialogs"} {
		t.Run(kind, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				r.ParseForm()
				wantPath := "/api/v1/query"
				parameter := "deny_partial_response"
				want := "1"
				if kind == "victorialogs" {
					wantPath = "/select/logsql/stats_query"
					parameter = "allow_partial_response"
					want = "0"
				}
				if r.Method != "POST" || r.URL.Path != wantPath || r.Form.Get(parameter) != want || r.Form.Get("query") != "disk_free_percent" || r.Header.Get("Authorization") != "" {
					t.Error("query request contract")
				}
				fmt.Fprint(w, strings.ReplaceAll(good, "$TIME", r.Form.Get("time")))
			}))
			defer server.Close()
			d := diskDefinition()
			d.Kind = kind
			rows, err := runQuery(context.Background(), d, p.MonitorSource{Kind: kind, BaseURL: server.URL})
			if err != nil || len(rows) != 3 {
				t.Fatalf("%+v %v", rows, err)
			}
			want := []p.MonitorObservation{
				{Identity: `{"instance":"a","mountpoint":"/"}`, Condition: 0, Value: 20},
				{Identity: `{"instance":"b","mountpoint":"/"}`, Condition: 2, Value: 10},
				{Identity: `{"instance":"b","mountpoint":"/data"}`, Condition: 1, Value: 3},
			}
			for i := range want {
				if rows[i] != want[i] {
					t.Fatalf("row %d: %+v", i, rows[i])
				}
			}
		})
	}
	for _, tc := range []struct {
		name, body string
		ok         bool
	}{
		{"empty", `{"status":"success","data":{"resultType":"vector","result":[]}}`, true},
		{"partial", strings.Replace(good, `"status":"success"`, `"status":"success","isPartial":true`, 1), false},
		{"warning", strings.Replace(good, `"status":"success"`, `"status":"success","warnings":["truncated"]`, 1), false},
		{"missing labels", strings.Replace(good, `"mountpoint":"/data",`, "", 1), false},
		{"duplicate identity", strings.Replace(good, `"mountpoint":"/data"`, `"mountpoint":"/"`, 1), false},
		{"NaN after valid rows", strings.Replace(good, `"10"`, `"NaN"`, 1), false},
		{"null label", strings.Replace(good, `"/data"`, `null`, 1), false},
		{"string timestamp", strings.ReplaceAll(good, "$TIME", `"$TIME"`), false},
		{"stale", strings.ReplaceAll(good, "$TIME", "1"), false},
		{"missing result", `{"status":"success","data":{"resultType":"vector"}}`, false},
		{"null result", `{"status":"success","data":{"resultType":"vector","result":null}}`, false},
		{"matrix", strings.Replace(good, "vector", "matrix", 1), false},
		{"malformed", good[:len(good)-2], false},
		{"oversize", strings.Repeat(" ", 4<<20) + good, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				r.ParseForm()
				fmt.Fprint(w, strings.ReplaceAll(tc.body, "$TIME", r.Form.Get("time")))
			}))
			defer s.Close()
			rows, err := runQuery(context.Background(), diskDefinition(), p.MonitorSource{BaseURL: s.URL})
			if (err == nil) != tc.ok || (!tc.ok && len(rows) != 0) {
				t.Fatalf("rows=%+v err=%v", rows, err)
			}
		})
	}
}

func TestVictoriaResultLimits(t *testing.T) {
	for _, tc := range []struct {
		name             string
		count, labelSize int
		ok               bool
	}{
		{"row limit", p.MaxMonitorInstances, 0, true},
		{"too many rows", p.MaxMonitorInstances + 1, 0, false},
		{"wire overflow", 40, 4000, false},
		{"identity overflow", 1, 4096, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				r.ParseForm()
				fmt.Fprint(w, `{"status":"success","data":{"resultType":"vector","result":[`)
				for i := 0; i < tc.count; i++ {
					if i != 0 {
						fmt.Fprint(w, ",")
					}
					fmt.Fprintf(w, `{"metric":{"instance":"%d%s","mountpoint":"/"},"value":[%s,"20"]}`, i, strings.Repeat("x", tc.labelSize), r.Form.Get("time"))
				}
				fmt.Fprint(w, `]}}`)
			}))
			defer s.Close()
			rows, err := runQuery(context.Background(), diskDefinition(), p.MonitorSource{BaseURL: s.URL})
			if (err == nil) != tc.ok || (tc.ok && len(rows) != tc.count) || (!tc.ok && len(rows) != 0) {
				t.Fatalf("got %d rows, error %v", len(rows), err)
			}
		})
	}
}

func TestVictoriaSecretsAndFailures(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer local-test-token" {
			t.Error("missing bearer")
		}
		w.WriteHeader(503)
	}))
	defer server.Close()
	source := p.MonitorSource{BaseURL: server.URL, SecretRef: "QUERY_TEST"}
	t.Setenv("NRC_MONITOR_SECRET_QUERY_TEST", "")
	if _, err := runQuery(context.Background(), diskDefinition(), source); err == nil || calls != 0 {
		t.Fatal("missing secret fell back to anonymous")
	}
	t.Setenv("NRC_MONITOR_SECRET_QUERY_TEST", "local-test-token")
	if rows, err := runQuery(context.Background(), diskDefinition(), source); err == nil || len(rows) != 0 {
		t.Fatal("HTTP error became results")
	}
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { r.ParseForm(); <-r.Context().Done() }))
	defer slow.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if rows, err := runQuery(ctx, diskDefinition(), p.MonitorSource{BaseURL: slow.URL}); err == nil || len(rows) != 0 {
		t.Fatal("timeout became results")
	}
}

func TestQueryDefinitionGuards(t *testing.T) {
	data, err := os.ReadFile("../../../protocol-go/testdata/monitor_source_validation.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases struct {
		References []struct {
			ID, Revision string
			Valid        bool
		}
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases.References {
		d := diskDefinition()
		d.SourceID, d.SourceRevision = tc.ID, tc.Revision
		if err := validateQuery(d); (err == nil) != tc.Valid {
			t.Errorf("%+v: %v", tc, err)
		}
	}
	for _, change := range []func(*checkDefinition){
		func(d *checkDefinition) { d.SourceRevision = "0" },
		func(d *checkDefinition) { d.URL = "http://unexpected" },
		func(d *checkDefinition) { d.IdentityLabels = []string{"instance", "instance"} },
		func(d *checkDefinition) { d.Recovery = &threshold{"<", json.Number("15")} },
		func(d *checkDefinition) { d.Recovery = &threshold{">", json.Number("5")} },
		func(d *checkDefinition) {
			d.Trigger = &threshold{"<=", json.Number("10")}
			d.Recovery = &threshold{">=", json.Number("10")}
		},
		func(d *checkDefinition) {
			d.Kind = "victorialogs"
			d.Query = "options(allow_partial_response=true) * | stats count()"
		},
	} {
		d := diskDefinition()
		change(&d)
		if validateQuery(d) == nil {
			t.Fatalf("invalid definition accepted: %+v", d)
		}
	}
	d := diskDefinition()
	if err := validateQuery(d); err != nil {
		t.Fatal(err)
	}
}

type querySource struct {
	testSource
	dataSource p.Asset
}

func (s *querySource) asset(context.Context, uint64) (p.Asset, error) { return s.dataSource, nil }

func TestQueryCyclePreservesEmptyVersusFailed(t *testing.T) {
	for _, failed := range []bool{false, true} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if failed {
				w.WriteHeader(503)
			} else {
				fmt.Fprint(w, `{"status":"success","data":{"resultType":"vector","result":[]}}`)
			}
		}))
		definition := diskDefinition()
		body, _ := json.Marshal(definition)
		sourceConfig, _ := json.Marshal(p.MonitorSource{Version: 1, Name: "logs", Kind: "victoriametrics", BaseURL: server.URL})
		asset := monitorAsset(server.URL)
		asset.Payload = string(body)
		source := &querySource{testSource: testSource{asset: asset}, dataSource: p.Asset{AssetType: p.AssetTypeMonitorSource, UpdatedAt: 10, Preview: string(sourceConfig)}}
		history := newHistoryWriter()
		cycle(context.Background(), source, history, "w", "checker", 2)
		if len(source.submitted) != 1 || source.submitted[0].Failed != failed || len(source.submitted[0].Observations) != 0 {
			t.Fatalf("wrong run: %+v", source.submitted)
		}
		h := <-history.queue
		if h.Run.Failed != failed {
			t.Fatal("history lost failed flag")
		}
		server.Close()
	}
}
