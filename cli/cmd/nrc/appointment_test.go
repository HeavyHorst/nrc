package main

import (
	"encoding/json"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestAppointmentPreviewContractAndValidation(t *testing.T) {
	raw, err := appointmentPreviewJSON(appointmentPreview{Title: " Review ", StartAt: "2026-09-27T10:00:00+02:00", EndAt: "2026-09-27T11:00:00+02:00", Description: "d"})
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatal(err)
	}
	if got["version"] != float64(1) || got["title"] != "Review" || got["start_at"] != "1790496000000000000" {
		t.Fatalf("preview=%s", raw)
	}
	for _, p := range []appointmentPreview{{Title: "", StartAt: "1"}, {Title: "x", StartAt: "2026-09-27T10:00:00"}, {Title: "x", StartAt: "2", EndAt: "1"}} {
		if _, err := appointmentPreviewJSON(p); err == nil {
			t.Fatalf("accepted %+v", p)
		}
	}
}

func TestAppointmentDecodeAndCommandFlags(t *testing.T) {
	a := protocol.Asset{AssetType: protocol.AssetTypeAppointment, AssetID: 9, PayloadEncoding: protocol.AssetPayloadEncodingPlain, Preview: `{"version":1,"title":"Meet","start_at":"10","project":"NRC"}`}
	r, _, err := decodeAppointment(a)
	if err != nil || r.ID != 9 || r.StartAt != "10" {
		t.Fatalf("record=%+v err=%v", r, err)
	}
	for _, name := range []string{"from", "to", "assignee", "project"} {
		if appointmentListCmd.Flags().Lookup(name) == nil {
			t.Errorf("list missing --%s", name)
		}
	}
	for _, name := range []string{"title", "start", "end", "description", "assignee", "project", "url"} {
		if appointmentUpdateCmd.Flags().Lookup(name) == nil {
			t.Errorf("update missing --%s", name)
		}
	}
}

func TestAppointmentTimeRejectsOverflow(t *testing.T) {
	for _, raw := range []string{"3000-01-01T00:00:00Z", "2262-04-11T23:47:16.854775808Z", "9223372036854775808", "0", "-1",
		"2026-09-27T10:00:00+24:00", "2026-09-27T10:00:00+00:60", "2026-09-27T10:00:00-24:00",
		"2026-02-30T10:00:00Z", "2026-09-27T25:00:00Z", "2026-09-27T10:00:00.1234567891Z"} {
		if _, err := parseAppointmentTime(raw); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	if got, err := parseAppointmentTime("2262-04-11T23:47:16.854775807Z"); err != nil || got != 9223372036854775807 {
		t.Fatalf("max time: %d %v", got, err)
	}
}

func TestAppointmentV2EditPreservesRecurrenceAndExceptions(t *testing.T) {
	a := protocol.Asset{AssetType: protocol.AssetTypeAppointment, PayloadEncoding: protocol.AssetPayloadEncodingPlain, Preview: `{"version":2,"title":"Before","start_at":"1792404000000000000","timezone":"Europe/Berlin","repeat":"weekly","weekdays":[1,3],"until":"","participants":["bob"],"conference":"nrc","exceptions":[{"at":"1792404000000000000","cancelled":false,"participants":[]}]}`}
	r, p, err := decodeAppointment(a)
	if err != nil {
		t.Fatal(err)
	}
	if r.Timezone != "Europe/Berlin" || r.Conference != "nrc" {
		t.Fatalf("record=%+v", r)
	}
	p.Title = "After"
	raw, err := appointmentPreviewJSON(p)
	if err != nil {
		t.Fatal(err)
	}
	var before, after map[string]json.RawMessage
	if err := json.Unmarshal([]byte(a.Preview), &before); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(raw), &after); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"version", "timezone", "repeat", "weekdays", "until", "participants", "conference", "exceptions"} {
		if string(before[key]) != string(after[key]) {
			t.Fatalf("%s changed: %s -> %s", key, before[key], after[key])
		}
	}
}
