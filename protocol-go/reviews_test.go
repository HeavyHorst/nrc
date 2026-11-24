package protocol

import (
	"encoding/binary"
	"encoding/json"
	"strings"
	"testing"
)

func reviewTestForm() ReviewForm {
	return ReviewForm{Version: 1, Title: "Release", Build: "v2", ReleasedAt: "1790000000000000000", Points: []ReviewPoint{{ID: "9007199254740993", Question: "Works?", Instruction: "Try", Expected: "Yes"}}}
}

func TestReviewRunRequestWire(t *testing.T) {
	for _, q := range []ReviewRequest{
		{Op: "run_list", Source: "portal", Identity: "anna@example.test", Name: "Anna", Cursor: "9007199254740993"},
		{Op: "run_get", RunID: "18446744073709551615", Source: "portal", Identity: "anna@example.test"},
		{Op: "invitation_info", Source: "guest", Token: strings.Repeat("a", 64)},
		{Op: "invitation_info", Source: "guest", Token: strings.Repeat("a", 64), GuestID: strings.Repeat("b", 64)},
		{Op: "guest_join", Source: "guest", Token: strings.Repeat("a", 64), GuestID: strings.Repeat("b", 64), Name: "Guest"},
		{Op: "answer", RunID: "7", PointID: "9007199254740993", Result: "unable", Comment: "Not yet", Source: "guest", Token: strings.Repeat("a", 64), GuestID: strings.Repeat("b", 64), Name: "Guest"},
		{Op: "close", RunID: "7", IfRevision: "1790000000000000000", Decision: "conditional", Comment: "One issue", Source: "portal", Identity: "anna@example.test"},
		{Op: "invite", RunID: "7", ExpiresAt: "1790000000000000000", CanClose: true},
		{Op: "revoke", RunID: "7", InviteID: "9"},
	} {
		t.Run(q.Op, func(t *testing.T) {
			b, err := EncodeReviewRequest(q, 0x10203040)
			if err != nil {
				t.Fatal(err)
			}
			if binary.BigEndian.Uint16(b) != C_Review || binary.BigEndian.Uint32(b[len(b)-4:]) != 0x10203040 {
				t.Fatal("incorrect framing")
			}
			var got ReviewRequest
			if err = json.Unmarshal(b[2:len(b)-4], &got); err != nil {
				t.Fatal(err)
			}
			want, _ := json.Marshal(q)
			actual, _ := json.Marshal(got)
			if string(want) != string(actual) {
				t.Fatalf("lossy request: %s", actual)
			}
		})
	}
}

func TestReviewResponseWire(t *testing.T) {
	f := reviewTestForm()
	run := ReviewRun{ID: "18446744073709551615", FormID: "9007199254740993", Title: f.Title, Label: "Team", Kind: "customer", Revision: "1790000000000000000", Participants: []ReviewParticipant{{ID: "8", Source: "portal", Name: "Anna", CanClose: true}}, Answers: []ReviewAnswer{{ID: "9", ParticipantID: "8", PointID: f.Points[0].ID, Result: "yes", Name: "Anna", UpdatedAt: "1790000000000000000"}}}
	for _, want := range []ReviewResponse{
		{Status: "ok", FormID: run.FormID, Revision: run.Revision, Form: f, Run: run, ParticipantID: "8"},
		{Status: "ok", Runs: []ReviewRun{run}, Cursor: run.ID, HasMore: true},
		{Status: "ok", Runs: []ReviewRun{}},
		{Status: "ok", Form: ReviewForm{Title: "Beträge & Steuern"}},
		{Status: "conflict"},
	} {
		b, _ := json.Marshal(want)
		b = append(binary.BigEndian.AppendUint32(nil, 42), b...)
		got, err := DecodeReviewResponse(b)
		if err != nil {
			t.Fatal(err)
		}
		if got.CorrelationID != 42 {
			t.Fatal("response correlation is leading")
		}
		got.CorrelationID = 0
		actual, _ := json.Marshal(got)
		expected, _ := json.Marshal(want)
		if string(actual) != string(expected) {
			t.Fatalf("lossy response: %s", actual)
		}
	}
}

func TestDecodeReviewDraftDeletion(t *testing.T) {
	for _, tc := range []struct {
		name, payload string
		valid         bool
	}{
		{"ack", `{"status":"ok","form_id":"9007199254740993","revision":"","form":{"version":0,"title":"","build":"","environment":"","released_at":"","points":null}}`, true},
		{"invalid ID", `{"status":"ok","form_id":"0"}`, false},
		{"missing revision on form", `{"status":"ok","form_id":"1","form":{"version":1,"title":"Draft"}}`, false},
		{"missing form on revision", `{"status":"ok","form_id":"1","revision":"2"}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := DecodeReviewResponse(append(binary.BigEndian.AppendUint32(nil, 42), tc.payload...))
			if !tc.valid {
				if err == nil {
					t.Fatal("invalid response accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.Status != "ok" || got.FormID != "9007199254740993" || got.CorrelationID != 42 {
				t.Fatalf("incorrect deletion acknowledgement: %+v", got)
			}
		})
	}
}

func TestReviewRejectsInvalidRequests(t *testing.T) {
	for _, q := range []ReviewRequest{
		{Op: "unknown"}, {Op: "run_get", RunID: "01"}, {Op: "run_get"},
		{Op: "close", RunID: "1", Decision: "accepted"},
		{Op: "close", RunID: "1", IfRevision: "2", Decision: "maybe"},
		{Op: "answer", RunID: "1", PointID: "2", Result: "maybe"},
		{Op: "answer", RunID: "1", PointID: "2", Result: "yes", Comment: strings.Repeat("a", 4097)},
		{Op: "run_list", Cursor: "1.5"}, {Op: "guest_join", Name: "a\x00b"},
		{Op: "create", Form: ReviewForm{Version: 1, Title: ""}},
	} {
		if _, err := EncodeReviewRequest(q, 1); err == nil {
			t.Fatalf("accepted invalid request: %+v", q)
		}
	}
}

func TestReviewFormValidationAndFraming(t *testing.T) {
	f := reviewTestForm()
	f.ReleasedAt = ""
	if _, err := EncodeReviewRequest(ReviewRequest{Op: "create", Form: f}, 5); err != nil {
		t.Fatal(err)
	}
	f.Points = append(f.Points, f.Points[0])
	if ValidateReviewForm(f, false) == nil {
		t.Fatal("duplicate point accepted")
	}
	for _, body := range [][]byte{nil, {0, 0, 0, 1}, {0, 0, 0, 1, '[', ']'}, append([]byte{0, 0, 0, 1}, []byte(`{"status":"ok","run":{"id":"01","form_id":"1","revision":"2"}}`)...)} {
		if _, err := DecodeReviewResponse(body); err == nil {
			t.Fatal("invalid response accepted")
		}
	}
}

func TestReviewOptionalSection(t *testing.T) {
	for _, section := range []string{"", "Beträge & Steuern", strings.Repeat("ä", 128), strings.Repeat("x", 256), strings.Repeat("ä", 129), "bad\x00label", string([]byte{0xff})} {
		f := reviewTestForm()
		f.Points[0].Section = section
		valid := section != "bad\x00label" && section != string([]byte{0xff}) && len(section) <= 256
		if (ValidateReviewForm(f, true) == nil) != valid {
			t.Fatalf("section validation: %q", section)
		}
		f.ReleasedAt = ""
		_, err := EncodeReviewRequest(ReviewRequest{Op: "create", Form: f}, 1)
		if (err == nil) != valid {
			t.Fatal("request validation differs")
		}
		if section == string([]byte{0xff}) {
			continue
		} // JSON marshal replaces invalid UTF-8.
		f.ReleasedAt = "1790000000000000000"
		for _, topID := range []string{"", "9"} {
			response := ReviewResponse{Status: "ok", FormID: topID, Revision: "1", Form: f, Run: ReviewRun{ID: "2", FormID: "9", Revision: "1"}}
			payload, _ := json.Marshal(response)
			got, err := DecodeReviewResponse(append(binary.BigEndian.AppendUint32(nil, 1), payload...))
			if (err == nil) != valid {
				t.Fatalf("response validation differs: %q %v", section, err)
			}
			if valid && got.Form.Points[0].Section != section {
				t.Fatal("section not preserved")
			}
		}
	}
	var old ReviewPoint
	if json.Unmarshal([]byte(`{"id":"1","question":"Old form"}`), &old) != nil || old.Section != "" {
		t.Fatal("legacy section required")
	}
	b, _ := json.Marshal(old)
	if strings.Contains(string(b), "section") {
		t.Fatal("empty section not omitted")
	}
}
