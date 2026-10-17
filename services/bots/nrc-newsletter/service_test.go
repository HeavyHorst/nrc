package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

type serviceTestSource struct {
	*fakeSource
	companies []customer
}

func (s *serviceTestSource) customers(context.Context) ([]customer, error) {
	return s.companies, nil
}

func (s *serviceTestSource) directory(context.Context) ([]customer, error) {
	return s.companies, nil
}

func TestSubscriberCompaniesDoNotRequireServiceRole(t *testing.T) {
	f := setup(t)
	ct := f.src.rows[0]
	f.a.source = &serviceTestSource{f.src, []customer{
		{ID: "10", Name: "First", Members: []contact{ct}},
		{ID: "20", Name: "Second", Members: []contact{ct}},
	}}
	r := f.req("GET", "/api/state", "")
	expect(t, r, 200)
	var state struct {
		Subscribers []struct {
			ID        string `json:"contact_id"`
			Companies []struct {
				ID   string `json:"customer_id"`
				Name string `json:"name"`
			} `json:"companies"`
		} `json:"subscribers"`
	}
	if err := json.Unmarshal(r.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	if len(state.Subscribers[0].Companies) != 2 || state.Subscribers[0].Companies[0].ID != "10" || state.Subscribers[0].Companies[1].Name != "Second" || len(state.Subscribers[1].Companies) != 0 {
		t.Fatalf("wrong memberships: %s", r.Body.String())
	}
	if len(f.calls) != 0 {
		t.Fatal("reading subscriber companies sent mail")
	}
}

func serviceDraft() draft {
	return draft{Kind: "service", Audience: "selected_customers", CustomerIDs: []string{"10"}, ServiceReason: "Scheduled maintenance", Title: "Service", TemplateID: "42", Subject: "Update", Variables: map[string]any{"name": "Friend"}}
}

func serviceJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func createService(t *testing.T, f *fixture, d draft) campaign {
	t.Helper()
	w := f.req("POST", "/api/campaigns", serviceJSON(t, d))
	expect(t, w, 201)
	var c campaign
	if err := json.Unmarshal(w.Body.Bytes(), &c); err != nil {
		t.Fatal(err)
	}
	if c.Kind != d.Kind || c.Audience != d.Audience || c.ServiceReason != d.ServiceReason || strings.Join(c.CustomerIDs, ",") != strings.Join(d.CustomerIDs, ",") {
		t.Fatalf("draft fields lost: %+v", c)
	}
	return c
}

func serviceAudience(t *testing.T, f *fixture, c campaign) (audienceReport, string) {
	t.Helper()
	w := f.req("POST", "/api/campaigns/"+c.ID+"/audience", serviceJSON(t, map[string]any{"revision": c.Revision}))
	expect(t, w, 200)
	var v struct {
		Audience audienceReport `json:"audience"`
		Token    string         `json:"token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil || v.Token == "" {
		t.Fatalf("invalid audience response: %s", w.Body.String())
	}
	return v.Audience, v.Token
}

func TestServiceDraftValidation(t *testing.T) {
	f := setup(t)
	c := createService(t, f, serviceDraft())
	cases := map[string]func(*draft){
		"missing reason":                 func(d *draft) { d.ServiceReason = "" },
		"blank reason":                   func(d *draft) { d.ServiceReason = " \n " },
		"long reason":                    func(d *draft) { d.ServiceReason = strings.Repeat("x", 2001) },
		"unknown kind":                   func(d *draft) { d.Kind = "transactional" },
		"unknown audience":               func(d *draft) { d.Audience = "everyone" },
		"empty selected":                 func(d *draft) { d.CustomerIDs = nil },
		"all with selection":             func(d *draft) { d.Audience = "all_customers" },
		"duplicate ids":                  func(d *draft) { d.CustomerIDs = []string{"10", "10"} },
		"noncanonical id":                func(d *draft) { d.CustomerIDs = []string{"010"} },
		"zero id":                        func(d *draft) { d.CustomerIDs = []string{"0"} },
		"invalid id":                     func(d *draft) { d.CustomerIDs = []string{"company"} },
		"newsletter with service fields": func(d *draft) { d.Kind = "newsletter" },
		"implicit newsletter with service fields": func(d *draft) { d.Kind = "" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			d := serviceDraft()
			mutate(&d)
			expect(t, f.req("POST", "/api/campaigns", serviceJSON(t, d)), 400)
			d.Revision = 1
			expect(t, f.req("PUT", "/api/campaigns/"+c.ID, serviceJSON(t, d)), 400)
		})
	}
	if f.a.s.Campaigns[c.ID].Revision != 1 || len(f.calls) != 0 {
		t.Fatal("invalid drafts mutated campaign or sent mail")
	}
}

func TestServiceAndNewsletterAudiences(t *testing.T) {
	f := setup(t)
	rows := []contact{{"1", "One", "one@example.com"}, {"2", "Duplicate", "ONE@example.com"}, {"3", "Blocked", "blocked@example.com"}, {"4", "New", "new@example.com"}}
	f.src.rows = rows
	f.a.source = &serviceTestSource{f.src, []customer{{ID: "10", Name: "Selected", Contacts: rows[:3]}, {ID: "20", Name: "Empty"}, {ID: "30", Name: "Blocked only", Contacts: rows[2:3]}, {ID: "40", Name: "Other", Contacts: rows[3:]}}}
	f.a.s.Consent["one@example.com"] = &consent{Status: "unsubscribed"}
	f.a.s.Consent["blocked@example.com"] = &consent{Status: "blocked"}
	c := createService(t, f, serviceDraft())
	r, _ := serviceAudience(t, f, c)
	if r.Customers != 1 || len(r.Missing) != 0 || r.Excluded != 1 || r.Duplicates != 1 || len(r.Recipients) != 1 || r.Recipients[0].Email != "one@example.com" {
		t.Fatalf("selected audience: %+v", r)
	}
	d := serviceDraft()
	d.Audience, d.CustomerIDs = "all_customers", nil
	c = createService(t, f, d)
	r, _ = serviceAudience(t, f, c)
	if r.Customers != 4 || len(r.Missing) != 2 || r.Missing[0].ID != "20" || r.Missing[1].ID != "30" || r.Excluded != 2 || r.Duplicates != 1 || len(r.Recipients) != 2 {
		t.Fatalf("all customers audience: %+v", r)
	}
	n := f.create(t)
	r, _ = serviceAudience(t, f, n)
	if len(r.Recipients) != 0 || r.Excluded != 4 {
		t.Fatalf("newsletter bypassed consent: %+v", r)
	}
	d = serviceDraft()
	d.CustomerIDs = []string{"999"}
	c = createService(t, f, d)
	expect(t, f.req("POST", "/api/campaigns/"+c.ID+"/audience", `{"revision":1}`), 503)
}

func TestServiceSendReviewGateAndLiveRoleRemoval(t *testing.T) {
	f := setup(t)
	src := &serviceTestSource{f.src, []customer{{ID: "10", Name: "Customer", Contacts: []contact{f.src.rows[0]}}}}
	f.a.source = src
	c := createService(t, f, serviceDraft())
	path := "/api/campaigns/" + c.ID
	_, token := serviceAudience(t, f, c)
	send := func(token string) string {
		return serviceJSON(t, map[string]any{"revision": 1, "confirmation": "Update", "audience_token": token})
	}
	expect(t, f.req("POST", path+"/send", send(token)), 409)
	f.outcome = "error"
	expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"test@example.com"}`), 502)
	expect(t, f.req("POST", path+"/send", send(token)), 409)
	f.outcome = "success"
	expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"test@example.com"}`), 200)
	expect(t, f.req("POST", path+"/send", send("")), 409)
	src.companies[0].Contacts = append(src.companies[0].Contacts, f.src.rows[2])
	expect(t, f.req("POST", path+"/send", send(token)), 409)
	_, fresh := serviceAudience(t, f, c)
	if fresh == token {
		t.Fatal("changed audience retained token")
	}
	expect(t, f.req("POST", path+"/send", send(fresh)), 202)
	n := len(f.calls)
	src.companies[0].Contacts = nil // Roles removed after queueing, while company remains active.
	f.a.dispatch(context.Background())
	job := f.a.s.Campaigns[c.ID]
	if len(f.calls) != n || job.Status != "sent" || len(job.Recipients) != 2 {
		t.Fatalf("removed roles delivered: %+v", job)
	}
	for _, rc := range job.Recipients {
		if rc.Status != "skipped" {
			t.Fatalf("removed role: %+v", rc)
		}
	}
}

func TestServiceProviderPayloadAndTestSuppression(t *testing.T) {
	for _, kind := range []string{"service", "newsletter"} {
		t.Run(kind, func(t *testing.T) {
			f := setup(t)
			f.a.source = &serviceTestSource{f.src, []customer{{ID: "10", Name: "Customer", Contacts: []contact{f.src.rows[0]}}}}
			var c campaign
			if kind == "service" {
				c = createService(t, f, serviceDraft())
			} else {
				c = f.create(t)
			}
			path := "/api/campaigns/" + c.ID
			f.a.s.Consent["one@example.com"] = &consent{Status: "unsubscribed"}
			status := 422
			if kind == "service" {
				status = 200
			}
			expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"ONE@example.com"}`), status)
			f.a.s.Consent["blocked@example.com"] = &consent{Status: "blocked"}
			n := len(f.calls)
			expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"blocked@example.com"}`), 422)
			if len(f.calls) != n {
				t.Fatal("blocked test sent mail")
			}
			expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"test@example.com"}`), 200)
			f.a.s.Consent["one@example.com"] = &consent{Status: "subscribed"}
			_, token := serviceAudience(t, f, c)
			expect(t, f.req("POST", path+"/send", serviceJSON(t, map[string]any{"revision": 1, "confirmation": "Update", "audience_token": token})), 202)
			f.a.dispatch(context.Background())
			for _, call := range f.calls {
				msg := call["Messages"].([]any)[0].(map[string]any)
				html, text := msg["HTMLPart"].(string), msg["TextPart"].(string)
				if kind == "service" {
					if _, ok := msg["Headers"]; ok {
						t.Fatal("service includes unsubscribe headers")
					}
					if html != "<p>Hello {{var:name}}</p>" || text != "Hello {{var:name}}" {
						t.Fatalf("service content modified: %+v", msg)
					}
				} else {
					headers, ok := msg["Headers"].(map[string]any)
					if !ok || !strings.Contains(headers["List-Unsubscribe"].(string), "/unsubscribe?token=") || !strings.Contains(html, "Newsletter abmelden") || !strings.Contains(text, "Newsletter abmelden: https://") {
						t.Fatalf("newsletter unsubscribe missing: %+v", msg)
					}
				}
			}
		})
	}
}

func TestDispatchPreservesSnapshotEligibility(t *testing.T) {
	for _, scenario := range []string{"company removed", "duplicate reordered"} {
		t.Run(scenario, func(t *testing.T) {
			f := setup(t)
			first, other := f.src.rows[0], f.src.rows[2]
			src := &serviceTestSource{f.src, []customer{{ID: "10", Name: "First", Contacts: []contact{first}}, {ID: "20", Name: "Other", Contacts: []contact{other}}}}
			f.a.source = src
			d := serviceDraft()
			d.CustomerIDs = []string{"10", "20"}
			c := createService(t, f, d)
			path := "/api/campaigns/" + c.ID
			expect(t, f.req("POST", path+"/test", `{"revision":1,"email":"test@example.com"}`), 200)
			_, token := serviceAudience(t, f, c)
			expect(t, f.req("POST", path+"/send", serviceJSON(t, map[string]any{"revision": 1, "confirmation": "Update", "audience_token": token})), 202)
			before := len(f.calls)
			if scenario == "company removed" {
				src.companies = src.companies[1:]
			} else {
				duplicate := contact{"9", "Recently edited duplicate", first.Email}
				src.companies[0].Contacts = []contact{duplicate, first}
			}
			for i := 0; i < 3; i++ {
				f.a.dispatch(context.Background())
			}
			job := f.a.s.Campaigns[c.ID]
			want := 2
			if scenario == "company removed" {
				want = 1
				if job.Recipients[0].Status != "skipped" {
					t.Fatal("departed company not skipped")
				}
			}
			if job.Status != "sent" || len(f.calls)-before != want {
				t.Fatalf("snapshot delivery: status=%s sends=%d want=%d recipients=%+v", job.Status, len(f.calls)-before, want, job.Recipients)
			}
		})
	}
}
