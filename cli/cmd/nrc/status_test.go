package main

import (
	"encoding/json"
	"testing"
)

func TestStatusResponseNamesServerTimestampUnit(t *testing.T) {
	data, err := json.Marshal(statusResponse{ServerTimestampNS: 123})
	if err != nil {
		t.Fatal(err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["server_timestamp_ns"] != float64(123) {
		t.Fatalf("server_timestamp_ns = %v, want 123", decoded["server_timestamp_ns"])
	}
	if _, exists := decoded["uptime_ms"]; exists {
		t.Fatal("status response must not expose server timestamp as uptime_ms")
	}
}
