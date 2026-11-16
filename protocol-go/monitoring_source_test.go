package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestMonitoringSourceURLContract(t *testing.T) {
	data, err := os.ReadFile("testdata/monitor_source_validation.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases struct {
		URLs []struct {
			Value string
			Valid bool
		}
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases.URLs {
		body, _ := json.Marshal(MonitorSource{Version: 1, Name: "test", Kind: "victorialogs", BaseURL: tc.Value})
		_, err := DecodeMonitorSource(Asset{AssetType: AssetTypeMonitorSource, Preview: string(body)})
		if (err == nil) != tc.Valid {
			t.Errorf("%s: %v", tc.Value, err)
		}
	}
}

func TestMonitoringSourceOptionalSecret(t *testing.T) {
	valid := MonitorSource{Version: 1, Name: "long-term", Kind: "victorialogs", BaseURL: "http://logs.tailnet:9428", Retention: "90d"}
	for _, ref := range []string{"", "READ_LOGS"} {
		v := valid
		v.SecretRef = ref
		body, _ := json.Marshal(v)
		got, err := DecodeMonitorSource(Asset{AssetType: AssetTypeMonitorSource, Preview: string(body)})
		if err != nil || got != v {
			t.Fatalf("%+v %v", got, err)
		}
	}
	for _, change := range []func(*MonitorSource){
		func(s *MonitorSource) { s.BaseURL = "http://user:secret@host" },
		func(s *MonitorSource) { s.BaseURL = "https://host?token=secret" },
		func(s *MonitorSource) { s.Kind = "unsupported" },
		func(s *MonitorSource) { s.SecretRef = "path/to/secret" },
	} {
		v := valid
		change(&v)
		body, _ := json.Marshal(v)
		if _, err := DecodeMonitorSource(Asset{AssetType: AssetTypeMonitorSource, Preview: string(body)}); err == nil {
			t.Fatalf("accepted %+v", v)
		}
	}
}

func TestWebhookSource(t *testing.T) {
	for _, retention := range []string{"", "7d"} {
		body, _ := json.Marshal(MonitorSource{Version: 1, Name: "ops", Kind: "webhook", BaseURL: "https://receiver/hook", Retention: retention})
		_, err := DecodeMonitorSource(Asset{AssetType: AssetTypeMonitorSource, Preview: string(body)})
		if (err == nil) != (retention == "") {
			t.Fatalf("retention %q: %v", retention, err)
		}
	}
}
